package com.tiltastech.castcircle

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * FEASIBILITY PROBE for Android live line-matching.
 *
 * Rehearsal on Android cannot currently match words: SpeechRecognizer and
 * MediaRecorder each open the microphone directly, so `startRecording` has to
 * destroy the recognizer first. The proposed fix is to own the mic ourselves
 * (one AudioRecord) and hand the recognizer its audio through
 * RecognizerIntent.EXTRA_AUDIO_SOURCE, so it never touches the mic and both
 * matching and capture can run together.
 *
 * That hinges on one unknown: the docs say that if the recognizer does not
 * support EXTRA_AUDIO_SOURCE it silently "opens the mic for audio" instead —
 * which on an OEM recognizer would mean two consumers fighting over the mic.
 * This probe answers it empirically on the actual device:
 *
 *  1. Synthesize a known phrase with the platform TTS (no fixture to push).
 *  2. Feed that PCM to SpeechRecognizer through EXTRA_AUDIO_SOURCE.
 *  3. Report what came back — and whether the mic stayed free the whole time.
 *
 * Registered only so the probe can be driven from an integration test; it has
 * no role in the shipping app and should be deleted once the question is
 * settled.
 */
class AudioSourcePlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    companion object {
        const val CHANNEL = "com.lineguide/audio_source_probe"
        const val PHRASE = "any savage can dance sir"
        const val RATE = 16000
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "probe") probe(result) else result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun probe(result: MethodChannel.Result) {
        val ctx = context ?: return result.error("NO_CTX", "no context", null)
        val out = HashMap<String, Any?>()
        out["sdkInt"] = Build.VERSION.SDK_INT
        out["extraAudioSourceRequiresApi"] = 31
        out["recognitionAvailable"] = SpeechRecognizer.isRecognitionAvailable(ctx)
        if (Build.VERSION.SDK_INT >= 33) {
            out["onDeviceRecognitionAvailable"] =
                SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)
        }

        thread {
            try {
                val wav = synthesize(ctx)
                out["ttsWavBytes"] = wav?.length() ?: 0
                if (wav == null || wav.length() < 1000) {
                    out["verdict"] = "INCONCLUSIVE: platform TTS produced no audio"
                    post(result, out); return@thread
                }
                val pcm = pcmPayload(wav)
                out["pcmBytes"] = pcm.size

                val recog = runRecognition(ctx, pcm, out)
                out["transcript"] = recog

                // The whole point: did the recognizer leave the mic alone?
                out["micFreeDuringRecognition"] = micWasFree

                val heard = (recog ?: "").lowercase()
                val hit = PHRASE.split(" ").count { heard.contains(it) }
                out["phraseWordsMatched"] = hit
                out["phraseWordCount"] = PHRASE.split(" ").size
                out["verdict"] = when {
                    recog == null -> "NOT SUPPORTED / no result — fall back to mode switch"
                    hit >= 3 && micWasFree == true ->
                        "SUPPORTED: recognizer consumed our audio and left the mic free"
                    hit >= 3 -> "PARTIAL: transcribed, but mic was NOT free"
                    else -> "NOT SUPPORTED: result did not match the spoken phrase"
                }
            } catch (e: Throwable) {
                out["error"] = e.toString()
                out["verdict"] = "ERROR"
            }
            post(result, out)
        }
    }

    private fun post(result: MethodChannel.Result, out: Map<String, Any?>) {
        Handler(Looper.getMainLooper()).post { result.success(out) }
    }

    /** Platform TTS → 16-bit PCM WAV of [PHRASE]. */
    private fun synthesize(ctx: Context): File? {
        val file = File(ctx.cacheDir, "probe_tts.wav")
        if (file.exists()) file.delete()
        val done = java.util.concurrent.CountDownLatch(1)
        var tts: TextToSpeech? = null
        tts = TextToSpeech(ctx) { status ->
            if (status != TextToSpeech.SUCCESS) { done.countDown(); return@TextToSpeech }
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(id: String?) {}
                override fun onDone(id: String?) = done.countDown()
                @Deprecated("legacy") override fun onError(id: String?) = done.countDown()
            })
            tts?.synthesizeToFile(PHRASE, Bundle(), file, "probe")
        }
        done.await(20, java.util.concurrent.TimeUnit.SECONDS)
        tts?.shutdown()
        return if (file.exists()) file else null
    }

    /** Strip the RIFF header; the recognizer wants raw PCM. */
    private fun pcmPayload(wav: File): ByteArray {
        val all = wav.readBytes()
        var i = 12
        while (i + 8 <= all.size) {
            val id = String(all, i, 4, Charsets.US_ASCII)
            val sz = (all[i + 4].toInt() and 0xff) or ((all[i + 5].toInt() and 0xff) shl 8) or
                ((all[i + 6].toInt() and 0xff) shl 16) or ((all[i + 7].toInt() and 0xff) shl 24)
            if (id == "data") return all.copyOfRange(i + 8, minOf(i + 8 + sz, all.size))
            i += 8 + sz
        }
        return all.copyOfRange(minOf(44, all.size), all.size)
    }

    private var micWasFree: Boolean? = null

    private fun runRecognition(ctx: Context, pcm: ByteArray, out: HashMap<String, Any?>): String? {
        if (Build.VERSION.SDK_INT < 31) {
            out["skipped"] = "EXTRA_AUDIO_SOURCE needs API 31+"
            return null
        }
        val pipe = ParcelFileDescriptor.createPipe()
        val readEnd = pipe[0]
        val writeEnd = pipe[1]

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            // The extras under test.
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, readEnd)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING,
                AudioFormat.ENCODING_PCM_16BIT)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, RATE)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
        }

        val latch = java.util.concurrent.CountDownLatch(1)
        var transcript: String? = null
        var errCode: Int? = null
        val finished = AtomicBoolean(false)

        Handler(Looper.getMainLooper()).post {
            // Prefer Google's recognizer: OEM ones are the ones likely to ignore
            // EXTRA_AUDIO_SOURCE and grab the mic instead.
            val google = ComponentName(
                "com.google.android.googlequicksearchbox",
                "com.google.android.voicesearch.serviceapi.GoogleRecognitionService")
            val sr = try {
                SpeechRecognizer.createSpeechRecognizer(ctx, google)
            } catch (_: Throwable) {
                SpeechRecognizer.createSpeechRecognizer(ctx)
            }
            out["recognizerComponent"] = google.packageName
            sr.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(p: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(v: Float) {}
                override fun onBufferReceived(b: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onError(error: Int) {
                    errCode = error
                    if (finished.compareAndSet(false, true)) latch.countDown()
                }
                override fun onResults(results: Bundle?) {
                    transcript = results
                        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()
                    if (finished.compareAndSet(false, true)) latch.countDown()
                }
                override fun onPartialResults(p: Bundle?) {
                    val t = p?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()
                    if (!t.isNullOrBlank()) transcript = t
                }
                override fun onEvent(t: Int, p: Bundle?) {}
            })
            sr.startListening(intent)
        }

        // Feed the audio, then close — the session ends when the audio closes.
        thread {
            try {
                FileOutputStream(writeEnd.fileDescriptor).use { os ->
                    var off = 0
                    val chunk = RATE / 5 * 2 // ~200ms of 16-bit mono
                    while (off < pcm.size) {
                        val n = minOf(chunk, pcm.size - off)
                        os.write(pcm, off, n); os.flush()
                        off += n
                        Thread.sleep(100)
                    }
                }
            } catch (_: Throwable) {
            } finally {
                try { writeEnd.close() } catch (_: Throwable) {}
            }
        }

        // While that runs, can we still open the mic? If the recognizer grabbed
        // it, this fails — which is precisely the scenario that would break
        // simultaneous capture + matching.
        thread {
            Thread.sleep(700)
            micWasFree = try {
                val min = AudioRecord.getMinBufferSize(
                    RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                val ar = AudioRecord(MediaRecorder.AudioSource.MIC, RATE,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                    maxOf(min, 4096))
                val ok = ar.state == AudioRecord.STATE_INITIALIZED
                if (ok) {
                    ar.startRecording()
                    val buf = ShortArray(1024)
                    val read = ar.read(buf, 0, buf.size)
                    ar.stop()
                    out["micReadSamples"] = read
                }
                ar.release()
                ok
            } catch (e: Throwable) {
                out["micError"] = e.toString()
                false
            }
        }

        latch.await(45, java.util.concurrent.TimeUnit.SECONDS)
        out["recognizerErrorCode"] = errCode
        try { readEnd.close() } catch (_: Throwable) {}
        return transcript
    }
}

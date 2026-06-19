package com.tiltastech.castcircle

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android implementation of the com.lineguide/apple_stt channel.
 *
 * Uses Android's SpeechRecognizer for real-time streaming STT,
 * matching the same method contract as the iOS AppleSttPlugin.
 */
class AndroidSttPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    private lateinit var channel: MethodChannel
    private var context: Context? = null
    private var activity: Activity? = null
    private var speechRecognizer: SpeechRecognizer? = null
    private var isListening = false
    private var locale: String = "en-US"

    // Rehearsal-mode audio capture. Android can't run SpeechRecognizer and a
    // recorder on the mic at the same time, so capture is mutually exclusive
    // with listening — startRecording stops any recognizer first.
    private var mediaRecorder: MediaRecorder? = null
    private var recordingPath: String? = null
    private var recordingStartMs: Long = 0
    private val amplitudeHandler = Handler(Looper.getMainLooper())
    private var amplitudeRunnable: Runnable? = null

    companion object {
        private const val CHANNEL_NAME = "com.lineguide/apple_stt"
        private const val REQUEST_RECORD_AUDIO = 1001
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        destroyRecognizer()
        releaseRecorder()
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                locale = call.argument<String>("locale") ?: "en-US"
                val available = SpeechRecognizer.isRecognitionAvailable(context!!)
                result.success(available)
            }
            "listen" -> startListening(call, result)
            "stop" -> stopListening(result)
            "startRecording" -> startRecording(call, result)
            "stopRecording" -> stopRecording(result)
            "isAvailable" -> {
                result.success(SpeechRecognizer.isRecognitionAvailable(context!!))
            }
            else -> result.notImplemented()
        }
    }

    private fun startListening(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: run {
            result.success(false)
            return
        }

        if (!SpeechRecognizer.isRecognitionAvailable(ctx)) {
            result.success(false)
            return
        }

        // Check microphone permission
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED) {
            activity?.let {
                ActivityCompat.requestPermissions(
                    it,
                    arrayOf(Manifest.permission.RECORD_AUDIO),
                    REQUEST_RECORD_AUDIO
                )
            }
            result.success(false)
            return
        }

        // Stop any existing session
        destroyRecognizer()

        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(ctx)
        speechRecognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}

            override fun onRmsChanged(rmsdB: Float) {
                // Map Android's relative dB scale (~-2..10) onto the same
                // 0..1 pseudo-linear scale iOS reports (speech ≈ 0.05-0.3,
                // silence ≈ 0) so Dart-side endpointing thresholds match.
                val level = ((rmsdB - 2f) / 8f).coerceIn(0f, 1f) * 0.3f
                channel.invokeMethod("onLevel", level.toDouble())
            }

            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}

            override fun onPartialResults(partialResults: Bundle?) {
                val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = matches?.firstOrNull() ?: return
                channel.invokeMethod("onResult", mapOf("text" to text, "isFinal" to false))
            }

            override fun onResults(results: Bundle?) {
                val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = matches?.firstOrNull() ?: ""
                isListening = false
                channel.invokeMethod("onResult", mapOf("text" to text, "isFinal" to true))
                channel.invokeMethod("onDone", null)
            }

            override fun onError(error: Int) {
                isListening = false
                val message = when (error) {
                    SpeechRecognizer.ERROR_AUDIO -> "Audio recording error"
                    SpeechRecognizer.ERROR_CLIENT -> "Client error"
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Insufficient permissions"
                    SpeechRecognizer.ERROR_NETWORK -> "Network error"
                    SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Network timeout"
                    SpeechRecognizer.ERROR_NO_MATCH -> "No speech match"
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Recognizer busy"
                    SpeechRecognizer.ERROR_SERVER -> "Server error"
                    SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "Speech timeout"
                    else -> "Unknown error ($error)"
                }
                // NO_MATCH and SPEECH_TIMEOUT are normal end-of-speech events
                if (error == SpeechRecognizer.ERROR_NO_MATCH ||
                    error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                    channel.invokeMethod("onDone", null)
                } else {
                    channel.invokeMethod("onError", message)
                    // Match iOS: always end the session so the Dart side can
                    // restart continuous listening instead of hanging.
                    channel.invokeMethod("onDone", null)
                }
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            // Prefer on-device recognition when available
            val onDevice = call.argument<Boolean>("onDevice") ?: false
            if (onDevice) {
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            }
        }

        speechRecognizer?.startListening(intent)
        isListening = true
        result.success(true)
    }

    private fun stopListening(result: MethodChannel.Result) {
        speechRecognizer?.stopListening()
        isListening = false
        // Safety net: if the screen closes mid-capture, stop() is called without
        // a matching stopRecording — release the recorder so it doesn't leak the
        // mic. In the normal flow stopRecording already cleared it, so this is a
        // no-op then.
        releaseRecorder()
        result.success(null)
    }

    // ── Rehearsal audio capture (MediaRecorder → AAC .m4a) ──────────────
    //
    // On iOS the same mic tap feeds STT and the recording; Android can't share
    // the mic, so recording and SpeechRecognizer are mutually exclusive. The
    // rehearsal screen drives a record-only path on Android and advances on
    // mic-silence (amplitude reported via onLevel) instead of word-matching.

    private fun startRecording(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: run {
            result.error("NO_CONTEXT", "STT plugin not attached", null)
            return
        }
        val path = call.argument<String>("path") ?: run {
            result.error("NO_PATH", "Missing recording path", null)
            return
        }

        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED) {
            activity?.let {
                ActivityCompat.requestPermissions(
                    it, arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_RECORD_AUDIO
                )
            }
            // Fail loudly — never return a silent false the caller can't see.
            result.error("NO_PERMISSION", "Microphone permission not granted", null)
            return
        }

        // SpeechRecognizer and MediaRecorder can't share the mic — free it first.
        destroyRecognizer()

        try {
            val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(ctx)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioSamplingRate(44100)
            recorder.setAudioEncodingBitRate(128000)
            recorder.setOutputFile(path)
            recorder.prepare()
            recorder.start()

            mediaRecorder = recorder
            recordingPath = path
            recordingStartMs = System.currentTimeMillis()
            startAmplitudePolling()
            result.success(true)
        } catch (e: Exception) {
            try { mediaRecorder?.release() } catch (_: Exception) {}
            mediaRecorder = null
            recordingPath = null
            // Fail loudly — surface the real reason to Dart, don't swallow it.
            result.error("RECORD_FAILED", "Could not start recording: ${e.message}", null)
        }
    }

    private fun stopRecording(result: MethodChannel.Result) {
        stopAmplitudePolling()
        val recorder = mediaRecorder
        val path = recordingPath
        mediaRecorder = null
        recordingPath = null
        if (recorder == null || path == null) {
            result.success(null)
            return
        }

        val durationMs = (System.currentTimeMillis() - recordingStartMs).toInt()
        try {
            recorder.stop()
        } catch (e: Exception) {
            // stop() throws if the clip is too short / had no frames. Treat as a
            // discarded (empty) capture rather than crashing.
            try { recorder.release() } catch (_: Exception) {}
            result.success(null)
            return
        }
        try { recorder.release() } catch (_: Exception) {}
        result.success(mapOf("path" to path, "durationMs" to durationMs))
    }

    private fun startAmplitudePolling() {
        stopAmplitudePolling()
        val runnable = object : Runnable {
            override fun run() {
                val r = mediaRecorder ?: return
                try {
                    // getMaxAmplitude() is 0..32767 (peak since last read). Map
                    // onto the 0..1 scale the rest of the app expects so the mic
                    // indicator and silence endpointing work (speech ≈ 0.05+).
                    val level = (r.maxAmplitude / 32767.0).coerceIn(0.0, 1.0)
                    channel.invokeMethod("onLevel", level)
                } catch (_: Exception) {}
                amplitudeHandler.postDelayed(this, 100)
            }
        }
        amplitudeRunnable = runnable
        amplitudeHandler.postDelayed(runnable, 100)
    }

    private fun stopAmplitudePolling() {
        amplitudeRunnable?.let { amplitudeHandler.removeCallbacks(it) }
        amplitudeRunnable = null
    }

    private fun releaseRecorder() {
        stopAmplitudePolling()
        try { mediaRecorder?.release() } catch (_: Exception) {}
        mediaRecorder = null
        recordingPath = null
    }

    private fun destroyRecognizer() {
        try {
            speechRecognizer?.cancel()
            speechRecognizer?.destroy()
        } catch (_: Exception) {}
        speechRecognizer = null
        isListening = false
    }
}

package com.tiltastech.castcircle

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
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
    private var recognizerGeneration = 0

    // Rehearsal-mode audio capture. Android can't run SpeechRecognizer and a
    // recorder on the mic at the same time, so the app owns the mic itself:
    // one AudioRecord, fanned out to an AAC/.m4a encoder (the shared
    // recording) and, as raw PCM chunks, up to Dart for the on-device
    // streaming recognizer (see docs/ANDROID_LIVE_MATCHING.md).
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    @Volatile private var capturing = false
    private var recordingPath: String? = null
    @Volatile private var recordingSessionId: Int? = null
    private var recordingStartMs: Long = 0
    @Volatile private var captureFailure: String? = null
    @Volatile private var finalizingRecording = false
    @Volatile private var pendingRecorderDiscard = false
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val CHANNEL_NAME = "com.lineguide/apple_stt"
        private const val REQUEST_RECORD_AUDIO = 1001

        // Rehearsal capture: 16 kHz mono — the streaming recognizer's native
        // rate, and plenty for speech in the shared .m4a.
        private const val SAMPLE_RATE = 16000
        private const val CHUNK_SAMPLES = 1600 // 100 ms
        private const val AAC_BITRATE = 48000  // speech at 16 kHz mono
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        destroyRecognizer()
        releaseRecorderAsync() // main thread — never block it on the capture join
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
                val ctx = context!!
                // Ask for the mic NOW (rehearsal start, while the opening
                // lines play) — deferring to the first line capture put the
                // permission dialog in the middle of the actor's turn and the
                // capture had already failed by the time they answered.
                if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO)
                    != PackageManager.PERMISSION_GRANTED) {
                    activity?.let {
                        ActivityCompat.requestPermissions(
                            it, arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_RECORD_AUDIO
                        )
                    }
                }
                val available = SpeechRecognizer.isRecognitionAvailable(ctx)
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
        val onDevice = call.argument<Boolean>("onDevice") ?: false
        if (onDevice) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                !SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)) {
                result.error(
                    "ON_DEVICE_UNAVAILABLE",
                    "On-device speech recognition is not available",
                    null,
                )
                return
            }
        } else if (!SpeechRecognizer.isRecognitionAvailable(ctx)) {
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

        val sessionId = call.argument<Int>("sessionId") ?: run {
            result.error("INVALID_ARGS", "Missing sessionId", null)
            return
        }
        val callbackGeneration = recognizerGeneration
        speechRecognizer = try {
            if (onDevice) {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx)
            } else {
                SpeechRecognizer.createSpeechRecognizer(ctx)
            }
        } catch (e: Exception) {
            result.error(
                "RECOGNIZER_CREATE_FAILED",
                e.message ?: "Could not create speech recognizer",
                null,
            )
            return
        }
        speechRecognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}

            override fun onRmsChanged(rmsdB: Float) {
                if (!isListening || recognizerGeneration != callbackGeneration) return
                // Map Android's relative dB scale (~-2..10) onto the same
                // 0..1 pseudo-linear scale iOS reports (speech ≈ 0.05-0.3,
                // silence ≈ 0) so Dart-side endpointing thresholds match.
                val level = ((rmsdB - 2f) / 8f).coerceIn(0f, 1f) * 0.3f
                channel.invokeMethod(
                    "onLevel",
                    mapOf("level" to level.toDouble(), "sessionId" to sessionId),
                )
            }

            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}

            override fun onPartialResults(partialResults: Bundle?) {
                if (!isListening || recognizerGeneration != callbackGeneration) return
                val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = matches?.firstOrNull() ?: return
                channel.invokeMethod(
                    "onResult",
                    mapOf("text" to text, "isFinal" to false, "sessionId" to sessionId),
                )
            }

            override fun onResults(results: Bundle?) {
                if (!isListening || recognizerGeneration != callbackGeneration) return
                val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = matches?.firstOrNull() ?: ""
                isListening = false
                channel.invokeMethod(
                    "onResult",
                    mapOf("text" to text, "isFinal" to true, "sessionId" to sessionId),
                )
                channel.invokeMethod("onDone", mapOf("sessionId" to sessionId))
            }

            override fun onError(error: Int) {
                if (!isListening || recognizerGeneration != callbackGeneration) return
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
                    channel.invokeMethod("onDone", mapOf("sessionId" to sessionId))
                } else {
                    channel.invokeMethod(
                        "onError",
                        mapOf("error" to message, "sessionId" to sessionId),
                    )
                    // Match iOS: always end the session so the Dart side can
                    // restart continuous listening instead of hanging.
                    channel.invokeMethod("onDone", mapOf("sessionId" to sessionId))
                }
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            // `onDevice` selects the recognizer instance above. Do not use
            // EXTRA_PREFER_OFFLINE: it is advisory and may still use network.
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
        // no-op then. Async: this runs on the platform main thread.
        releaseRecorderAsync()
        result.success(null)
    }

    // ── Rehearsal audio capture (AudioRecord → AAC .m4a + PCM fan-out) ──
    //
    // On iOS the same mic tap feeds STT and the recording. Android's platform
    // recognizer refuses to share the mic (and ignores app-supplied audio —
    // measured, see docs/ANDROID_LIVE_MATCHING.md), so the app owns the mic:
    // one 16 kHz mono AudioRecord whose buffers are (1) AAC-encoded into the
    // same .m4a contract as before, (2) forwarded to Dart as "onPcm" chunks
    // for the on-device streaming recognizer, and (3) peak-measured for the
    // existing "onLevel" scale (0..1, speech ≈ 0.05+), which mic-silence
    // endpointing is tuned against.

    private fun startRecording(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: run {
            result.error("NO_CONTEXT", "STT plugin not attached", null)
            return
        }
        val path = call.argument<String>("path") ?: run {
            result.error("NO_PATH", "Missing recording path", null)
            return
        }
        val sessionId = call.argument<Int>("sessionId") ?: run {
            result.error("INVALID_ARGS", "Missing sessionId", null)
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

        // A platform-recognizer session would fight over the mic — end it.
        destroyRecognizer()
        if (finalizingRecording || !releaseRecorder()) {
            result.error(
                "RECORD_BUSY",
                "The previous recording is still releasing the microphone",
                null,
            )
            return
        }
        var record: AudioRecord? = null
        var encoder: MediaCodec? = null
        var encoderStarted = false
        var muxer: MediaMuxer? = null
        try {
            val minBuf = AudioRecord.getMinBufferSize(
                SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            if (minBuf <= 0) throw IllegalStateException("16 kHz mono not supported ($minBuf)")
            val createdRecord = AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf * 2, CHUNK_SAMPLES * 2 * 4))
            record = createdRecord
            if (createdRecord.state != AudioRecord.STATE_INITIALIZED) {
                throw IllegalStateException("AudioRecord failed to initialize")
            }

            val createdEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            encoder = createdEncoder
            val format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1).apply {
                setInteger(
                    MediaFormat.KEY_AAC_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AACObjectLC,
                )
                setInteger(MediaFormat.KEY_BIT_RATE, AAC_BITRATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, CHUNK_SAMPLES * 2)
            }
            createdEncoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val createdMuxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = createdMuxer

            createdEncoder.start()
            encoderStarted = true
            createdRecord.startRecording()
            if (createdRecord.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                throw IllegalStateException("Mic busy — recording did not start")
            }

            audioRecord = createdRecord
            recordingPath = path
            recordingSessionId = sessionId
            recordingStartMs = System.currentTimeMillis()
            captureFailure = null
            finalizingRecording = false
            capturing = true
            val thread = Thread(
                { captureLoop(createdRecord, createdEncoder, createdMuxer, sessionId) },
                "RehearsalCapture",
            )
            captureThread = thread
            thread.start()

            // Ownership transferred to captureLoop.
            record = null
            encoder = null
            muxer = null
            result.success(true)
        } catch (e: Exception) {
            capturing = false
            captureThread = null
            audioRecord = null
            recordingPath = null
            recordingSessionId = null
            try { record?.stop() } catch (_: Exception) {}
            try { record?.release() } catch (_: Exception) {}
            if (encoderStarted) {
                try { encoder?.stop() } catch (_: Exception) {}
            }
            try { encoder?.release() } catch (_: Exception) {}
            try { muxer?.release() } catch (_: Exception) {}
            // Fail loudly — surface the real reason to Dart, don't swallow it.
            result.error("RECORD_FAILED", "Could not start recording: ${e.message}", null)
        }
    }

    /** Runs on [captureThread]: mic → AAC muxer + PCM/level events to Dart. */
    private fun captureLoop(
        record: AudioRecord,
        encoder: MediaCodec,
        muxer: MediaMuxer,
        sessionId: Int,
    ) {
        val pcm = ShortArray(CHUNK_SAMPLES)
        val bufInfo = MediaCodec.BufferInfo()
        var muxerTrack = -1
        var muxerStarted = false
        var samplesFed = 0L

        fun drainEncoder(endOfStream: Boolean): Boolean {
            // While flushing, keep waiting (bounded) until the EOS buffer
            // arrives — bailing on the first TRY_AGAIN would drop the tail of
            // the recording.
            val deadline = System.currentTimeMillis() + 1000
            while (true) {
                val outIndex =
                    encoder.dequeueOutputBuffer(bufInfo, if (endOfStream) 10_000 else 0)
                when {
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        muxerTrack = muxer.addTrack(encoder.outputFormat)
                        muxer.start()
                        muxerStarted = true
                    }
                    outIndex >= 0 -> {
                        val out = encoder.getOutputBuffer(outIndex)
                            ?: throw IllegalStateException("AAC output buffer unavailable")
                        if (bufInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 &&
                            bufInfo.size > 0 && muxerStarted) {
                            muxer.writeSampleData(muxerTrack, out, bufInfo)
                        }
                        encoder.releaseOutputBuffer(outIndex, false)
                        if (bufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            return true
                        }
                    }
                    // TRY_AGAIN (or legacy BUFFERS_CHANGED): done for now unless
                    // we're flushing and still inside the deadline.
                    else -> if (!endOfStream || System.currentTimeMillis() > deadline) {
                        return !endOfStream
                    }
                }
            }
        }

        try {
            while (capturing) {
                val n = record.read(pcm, 0, CHUNK_SAMPLES)
                if (n < 0) {
                    throw IllegalStateException("AudioRecord.read failed with code $n")
                }
                if (n == 0) {
                    Thread.sleep(5)
                    continue
                }

                // Peak level for the mic indicator / silence endpointing.
                var peak = 0
                for (i in 0 until n) {
                    val v = pcm[i].toInt(); val a = if (v < 0) -v else v
                    if (a > peak) peak = a
                }
                val level = (peak / 32767.0).coerceIn(0.0, 1.0)

                // PCM bytes for the streaming recognizer (little-endian 16-bit).
                val bytes = ByteArray(n * 2)
                for (i in 0 until n) {
                    val v = pcm[i].toInt()
                    bytes[i * 2] = (v and 0xff).toByte()
                    bytes[i * 2 + 1] = ((v shr 8) and 0xff).toByte()
                }
                mainHandler.post {
                    // Old buffers must not enter a later recording session.
                    if (capturing && recordingSessionId == sessionId) {
                        channel.invokeMethod(
                            "onLevel",
                            mapOf("level" to level, "sessionId" to sessionId),
                        )
                        channel.invokeMethod("onPcm", bytes)
                    }
                }

                // Feed the AAC encoder (blocking is fine — this is our thread).
                val inIndex = encoder.dequeueInputBuffer(10_000)
                if (inIndex >= 0) {
                    val inBuf = encoder.getInputBuffer(inIndex)!!
                    inBuf.clear()
                    inBuf.put(bytes, 0, n * 2)
                    val ptsUs = samplesFed * 1_000_000L / SAMPLE_RATE
                    encoder.queueInputBuffer(inIndex, 0, n * 2, ptsUs, 0)
                    samplesFed += n
                }
                drainEncoder(false)
            }

            // Flush: retry briefly until the codec accepts the end marker.
            val eosDeadline = System.currentTimeMillis() + 500
            var eosQueued = false
            while (!eosQueued && System.currentTimeMillis() <= eosDeadline) {
                val inIndex = encoder.dequeueInputBuffer(10_000)
                if (inIndex >= 0) {
                    encoder.queueInputBuffer(
                        inIndex,
                        0,
                        0,
                        samplesFed * 1_000_000L / SAMPLE_RATE,
                        MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                    )
                    eosQueued = true
                }
            }
            if (!eosQueued) throw IllegalStateException("AAC encoder did not accept end-of-stream")
            if (!drainEncoder(true)) {
                throw IllegalStateException("AAC encoder did not finish end-of-stream")
            }
        } catch (e: Exception) {
            reportCaptureFailure("Capture failed: ${e.message ?: e.javaClass.simpleName}")
        } finally {
            try { record.stop() } catch (_: Exception) {}
            try { record.release() } catch (_: Exception) {}
            try { encoder.stop() } catch (_: Exception) {}
            try { encoder.release() } catch (_: Exception) {}
            if (muxerStarted) {
                try {
                    muxer.stop()
                } catch (e: Exception) {
                    reportCaptureFailure(
                        "Recording finalization failed: ${e.message ?: e.javaClass.simpleName}",
                    )
                }
            }
            try { muxer.release() } catch (_: Exception) {}
        }
    }

    private fun reportCaptureFailure(message: String) {
        if (captureFailure == null) captureFailure = message
        mainHandler.post {
            if (context != null) channel.invokeMethod("onError", message)
        }
    }

    private fun stopRecording(result: MethodChannel.Result) {
        if (finalizingRecording) {
            result.error("STOP_IN_PROGRESS", "Recording finalization is already in progress", null)
            return
        }
        val path = recordingPath
        val thread = captureThread
        if (path == null || thread == null) {
            capturing = false
            result.success(null)
            return
        }
        val durationMs = (System.currentTimeMillis() - recordingStartMs).toInt()
        capturing = false
        finalizingRecording = true
        // Finalizing the muxer can block; join away from the platform thread.
        Thread({
            try {
                thread.join(3000)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            val stillFinalizing = thread.isAlive
            val failure = captureFailure
            mainHandler.post {
                finalizingRecording = false
                val file = java.io.File(path)
                if (stillFinalizing) {
                    // The timed-out stop can never expose this path later.
                    pendingRecorderDiscard = true
                    result.error(
                        "FINALIZE_TIMEOUT",
                        "Recording finalization did not complete in time",
                        null,
                    )
                    discardRecorderWhenReleased(thread, path)
                    return@post
                }

                val discard = pendingRecorderDiscard
                clearRecorderState(thread)
                if (discard) {
                    file.delete()
                    result.success(null)
                } else if (failure != null) {
                    file.delete()
                    result.error("CAPTURE_FAILED", failure, null)
                } else if (file.exists() && file.length() > 0) {
                    result.success(mapOf("path" to path, "durationMs" to durationMs))
                } else {
                    // Too short to produce frames — a discarded capture, not a crash.
                    result.success(null)
                }
            }
        }, "RehearsalCaptureStop").start()
    }

    /**
     * Stops and joins the current recorder before a new owner opens the mic.
     * Returns false without clearing the handle if native finalization stalls.
     */
    private fun releaseRecorder(): Boolean {
        capturing = false
        val thread = captureThread
        val discardedPath = recordingPath
        if (thread != null && thread !== Thread.currentThread()) {
            try {
                thread.join(3000)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        if (thread?.isAlive == true) return false
        clearRecorderState(thread)
        discardedPath?.let { java.io.File(it).delete() }
        return true
    }

    /**
     * Release without blocking the platform main thread. The capture-thread
     * handle remains published until its AudioRecord and muxer are closed, so
     * a subsequent start can still perform a safe mic handoff.
     */
    private fun releaseRecorderAsync() {
        capturing = false
        // Teardown owns discard even if stop is currently joining. The stop
        // callback will observe this before it can expose the path.
        if (finalizingRecording) {
            pendingRecorderDiscard = true
            return
        }
        // A timeout already scheduled the definitive join/clear/delete.
        if (pendingRecorderDiscard) return
        pendingRecorderDiscard = true
        val thread = captureThread
        val discardedPath = recordingPath
        recordingPath = null
        if (thread == null) {
            clearRecorderState(null)
            discardedPath?.let { java.io.File(it).delete() }
            return
        }
        discardRecorderWhenReleased(thread, discardedPath)
    }

    private fun discardRecorderWhenReleased(thread: Thread, path: String?) {
        Thread({
            var interrupted = false
            while (thread.isAlive) {
                try {
                    thread.join()
                } catch (_: InterruptedException) {
                    interrupted = true
                }
            }
            if (interrupted) Thread.currentThread().interrupt()
            mainHandler.post {
                // A synchronous handoff may already have cleared this old
                // owner and started a new recorder, possibly at the same path.
                if (captureThread === thread) {
                    clearRecorderState(thread)
                    path?.let { java.io.File(it).delete() }
                }
            }
        }, "RehearsalCaptureRelease").start()
    }

    private fun clearRecorderState(thread: Thread?) {
        if (captureThread !== thread) return
        captureThread = null
        audioRecord = null
        recordingPath = null
        captureFailure = null
        recordingSessionId = null
        pendingRecorderDiscard = false
    }

    private fun destroyRecognizer() {
        recognizerGeneration++
        try {
            speechRecognizer?.cancel()
            speechRecognizer?.destroy()
        } catch (_: Exception) {}
        speechRecognizer = null
        isListening = false
    }
}

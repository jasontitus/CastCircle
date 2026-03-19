package com.tiltastech.castcircle

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
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
            override fun onRmsChanged(rmsdB: Float) {}
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
        result.success(null)
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

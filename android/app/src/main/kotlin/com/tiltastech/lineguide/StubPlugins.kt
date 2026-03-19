package com.tiltastech.castcircle

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Stub plugin for Kokoro MLX TTS (com.lineguide/kokoro_mlx).
 *
 * MLX is Apple Silicon only. On Android, all methods return graceful failures
 * so the Dart TtsService falls back to system TTS (flutter_tts).
 */
class KokoroMlxStubPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.lineguide/kokoro_mlx")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadModel" -> result.success(false)
            "synthesize" -> result.error("UNAVAILABLE", "Kokoro MLX not available on Android", null)
            "unloadModel" -> result.success(null)
            "deleteModel" -> result.success(null)
            "getVoices" -> result.success(emptyList<String>())
            "getModelStatus" -> result.success(mapOf(
                "downloaded" to false,
                "loaded" to false
            ))
            else -> result.notImplemented()
        }
    }
}

/**
 * Stub plugin for MLX STT / Parakeet (com.lineguide/mlx_stt).
 *
 * Not available on Android. Returns graceful failures.
 */
class MlxSttStubPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.lineguide/mlx_stt")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> result.success(false)
            "transcribe" -> result.error("UNAVAILABLE", "MLX STT not available on Android", null)
            "transcribeStreaming" -> result.error("UNAVAILABLE", "MLX STT not available on Android", null)
            "loadAdapter" -> result.success(false)
            "unloadAdapter" -> result.success(null)
            "isModelDownloaded" -> result.success(false)
            "isReady" -> result.success(false)
            "dispose" -> result.success(null)
            else -> result.notImplemented()
        }
    }
}

/**
 * Stub plugin for media controls (com.lineguide/media_controls).
 *
 * Could be fully implemented with Android MediaSession later.
 * For now, accepts all calls gracefully.
 */
class MediaControlStubPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.lineguide/media_controls")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "activate" -> result.success(null)
            "deactivate" -> result.success(null)
            "updateNowPlaying" -> result.success(null)
            else -> result.notImplemented()
        }
    }
}

/**
 * Stub plugin for background downloads (com.lineguide/background_download).
 *
 * Kokoro models aren't usable on Android yet, so downloads are no-ops.
 * Could be implemented with Android DownloadManager later.
 */
class BackgroundDownloadStubPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.lineguide/background_download")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startDownload" -> result.error("UNAVAILABLE", "Background download not available on Android yet", null)
            "cancelDownload" -> result.success(null)
            else -> result.notImplemented()
        }
    }
}

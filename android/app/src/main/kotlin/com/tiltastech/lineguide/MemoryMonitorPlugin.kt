package com.tiltastech.castcircle

import android.app.ActivityManager
import android.content.Context
import android.os.Debug
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android implementation of the com.lineguide/memory_monitor channel.
 *
 * Uses Android's ActivityManager, Runtime, and process Debug.MemoryInfo to
 * distinguish whole-process PSS from Java heap usage.
 */
class MemoryMonitorPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var context: Context? = null

    companion object {
        private const val CHANNEL_NAME = "com.lineguide/memory_monitor"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getMemoryUsage" -> {
                val ctx = context ?: run {
                    result.error("NO_CONTEXT", "Context not available", null)
                    return
                }
                val activityManager = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val memoryInfo = ActivityManager.MemoryInfo()
                activityManager.getMemoryInfo(memoryInfo)

                val runtime = Runtime.getRuntime()
                val javaHeapUsedMB =
                    ((runtime.totalMemory() - runtime.freeMemory()) / (1024L * 1024L)).toInt()
                val processMemory = Debug.MemoryInfo()
                Debug.getMemoryInfo(processMemory)
                // totalPss includes Java, native, graphics, code, and other
                // proportional process memory. Keep physicalFootprintMB for
                // the existing cross-platform contract, but it is now backed
                // by a whole-process measurement rather than JVM heap alone.
                val processPssMB = processMemory.totalPss / 1024
                val availMemMB = (memoryInfo.availMem / (1024L * 1024L)).toInt()
                val totalMemMB = (memoryInfo.totalMem / (1024L * 1024L)).toInt()

                result.success(
                    mapOf(
                        "physicalFootprintMB" to processPssMB,
                        "processPssMB" to processPssMB,
                        "javaHeapUsedMB" to javaHeapUsedMB,
                        "availableMemoryMB" to availMemMB,
                        "totalPhysicalMemoryMB" to totalMemMB,
                    ),
                )
            }
            else -> result.notImplemented()
        }
    }
}

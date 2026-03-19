package com.tiltastech.castcircle

import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Android implementation of the com.lineguide/pdf_text channel.
 *
 * Uses Android's PdfRenderer to check for embedded text. For actual text
 * extraction, we rely on the ML Kit OCR pipeline in Dart since Android's
 * PdfRenderer only renders pages as bitmaps (no direct text extraction).
 *
 * For PDFs with embedded text, we use the iText-style approach of reading
 * the PDF content streams. As a pragmatic solution, we return null for
 * extractText/extractTextPerPage so the Dart layer falls through to OCR.
 */
class PdfTextPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel

    companion object {
        private const val CHANNEL_NAME = "com.lineguide/pdf_text"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "extractText" -> {
                // Android PdfRenderer can't extract text directly.
                // Return null so Dart falls through to ML Kit OCR pipeline.
                result.success(null)
            }
            "extractTextPerPage" -> {
                // Same — fall through to OCR
                result.success(null)
            }
            "hasEmbeddedText" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_PATH", "Path is required", null)
                    return
                }
                result.success(checkPdfReadable(path))
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Check if the PDF file is readable and has pages.
     * Returns false so the Dart layer always uses OCR on Android.
     */
    private fun checkPdfReadable(path: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists()) return false
            val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val renderer = PdfRenderer(fd)
            val hasPages = renderer.pageCount > 0
            renderer.close()
            fd.close()
            // Return false to force OCR path on Android (PdfRenderer can't extract text)
            false
        } catch (e: Exception) {
            false
        }
    }
}

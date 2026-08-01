package com.tiltastech.castcircle

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.FloatBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * On-device PaddleOCR (PP-OCRv5 small) via ONNX Runtime — the Android port of
 * ios/Runner/PaddleOcrPlugin.swift. Same channel contract
 * (`com.lineguide/paddle_ocr`: recognizeText / ocrPdf → pages → lines →
 * {text, confidence, left, width}), same pipeline, same Mac-validated
 * constants — so OCR quality no longer depends on which phone did the import.
 *
 * Pipeline per page: render (PdfRenderer) → DB detection ONNX → threshold +
 * connected-component boxes + unclip → crop each box → recognition ONNX →
 * CTC greedy decode against the PP-OCR dictionary.
 *
 * The Dart side falls back to ML Kit if this plugin errors or is unregistered.
 */
class PaddleOcrPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var env: OrtEnvironment? = null
    private var detSession: OrtSession? = null
    private var recSession: OrtSession? = null
    private var keys: List<String> = emptyList()
    @Volatile private var ready = false
    @Volatile private var loading = false

    // Detection / recognition constants — keep in lockstep with the Swift
    // plugin (Mac-validated: unclip 0.4 from a 9-scan corpus sweep, render
    // target 1800px long side).
    private val detLimitSide = 960
    private val detThresh = 0.3f
    private val detMinBoxArea = 16
    private val detUnclipRatio = 0.4f
    private val targetRenderLongPx = 1800.0
    private val recHeight = 48
    private val recMaxWidth = 1024
    private val detMean = floatArrayOf(0.485f, 0.456f, 0.406f)
    private val detStd = floatArrayOf(0.229f, 0.224f, 0.225f)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        channel = MethodChannel(binding.binaryMessenger, "com.lineguide/paddle_ocr")
        channel.setMethodCallHandler(this)
        // Load models off the main thread; `ready` gates the channel meanwhile.
        loading = true
        Thread({ loadModels(binding) }, "paddle-ocr-load").start()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        this.binding = null
        detSession?.close()
        recSession?.close()
        detSession = null
        recSession = null
        ready = false
    }

    private fun loadModels(binding: FlutterPlugin.FlutterPluginBinding) {
        try {
            val t0 = System.currentTimeMillis()
            val assets = binding.applicationContext.assets
            val fa = binding.flutterAssets
            fun readAsset(name: String): ByteArray =
                assets.open(fa.getAssetFilePathByName(name)).use { it.readBytes() }

            val e = OrtEnvironment.getEnvironment()
            val opts = OrtSession.SessionOptions()
            // Physical performance cores, capped — mirrors the Swift plugin's
            // finding that 0 (auto) under-threads and all-logical-cores
            // oversubscribes two sessions. Big.LITTLE phones report all cores,
            // so half of them approximates the performance cluster.
            val threads = max(2, min(Runtime.getRuntime().availableProcessors() / 2, 8))
            opts.setIntraOpNumThreads(threads)
            opts.addConfigEntry("session.intra_op.allow_spinning", "0")
            opts.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            detSession = e.createSession(readAsset("assets/paddle_ocr/det.onnx"), opts)
            recSession = e.createSession(readAsset("assets/paddle_ocr/rec.onnx"), opts)
            keys = String(readAsset("assets/paddle_ocr/keys.txt"), Charsets.UTF_8)
                .split("\n").dropLastWhile { it.isEmpty() }
            env = e
            ready = true
            Log.i(TAG, "models loaded in ${System.currentTimeMillis() - t0}ms — ${keys.size} keys, $threads threads")
        } catch (t: Throwable) {
            Log.e(TAG, "model load failed — Dart will fall back to ML Kit", t)
        } finally {
            loading = false
        }
    }

    // ── Channel ─────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!ready) {
            // Give an in-flight model load a moment before declaring NOT_READY
            // (imports right after launch land here; load takes ~1s).
            if (loading) {
                Thread {
                    val deadline = System.currentTimeMillis() + 15_000
                    while (loading && System.currentTimeMillis() < deadline) Thread.sleep(100)
                    mainHandler.post { onMethodCall(call, result) }
                }.start()
                return
            }
            result.error("NOT_READY", "PaddleOCR models not loaded", null)
            return
        }
        when (call.method) {
            "recognizeText" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGS", "Missing 'path'", null)
                    return
                }
                Thread({
                    val blocks = try {
                        BitmapFactory.decodeFile(path)?.let { ocrImage(it) } ?: emptyList()
                    } catch (t: Throwable) {
                        Log.e(TAG, "recognizeText failed", t)
                        emptyList()
                    }
                    mainHandler.post { result.success(mapOf("blocks" to blocks)) }
                }, "paddle-ocr-img").start()
            }
            "ocrPdf" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGS", "Missing 'path'", null)
                    return
                }
                Thread({ ocrPdf(path, result) }, "paddle-ocr-pdf").start()
            }
            else -> result.notImplemented()
        }
    }

    private fun ocrPdf(path: String, result: MethodChannel.Result) {
        val fd = try {
            ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        } catch (t: Throwable) {
            mainHandler.post { result.error("PDF_OPEN_FAILED", "Could not open PDF: $t", null) }
            return
        }
        try {
            PdfRenderer(fd).use { renderer ->
                val pageCount = renderer.pageCount
                val pages = ArrayList<Map<String, Any>>(pageCount)
                var failed = 0
                val jobStart = System.currentTimeMillis()
                for (i in 0 until pageCount) {
                    mainHandler.post {
                        channel.invokeMethod(
                            "ocrProgress", mapOf("page" to i + 1, "pageCount" to pageCount))
                    }
                    try {
                        val t0 = System.currentTimeMillis()
                        val lines = renderer.openPage(i).use { page ->
                            val bmp = renderPage(page)
                            try {
                                ocrImage(bmp)
                            } finally {
                                bmp.recycle()
                            }
                        }
                        pages.add(mapOf("page" to i + 1, "lines" to lines))
                        Log.i(TAG, "page ${i + 1}/$pageCount — ${lines.size} lines in ${System.currentTimeMillis() - t0}ms")
                    } catch (t: Throwable) {
                        Log.e(TAG, "page ${i + 1} failed", t)
                        failed++
                    }
                }
                val total = (System.currentTimeMillis() - jobStart) / 1000.0
                Log.i(TAG, "$pageCount pages in ${"%.1f".format(total)}s (${"%.2f".format(total / max(pageCount, 1))} s/page)")
                mainHandler.post {
                    result.success(
                        mapOf("pages" to pages, "pageCount" to pageCount, "failedPages" to failed))
                }
            }
        } catch (t: Throwable) {
            mainHandler.post { result.error("PDF_OCR_FAILED", "$t", null) }
        }
    }

    // ── PP-OCR pipeline ─────────────────────────────────────

    private fun renderPage(page: PdfRenderer.Page): Bitmap {
        // Auto-scale so the page long side ≈ targetRenderLongPx (clamped
        // 1–6×) — detection caps at 960 anyway; the scale feeds the rec crops.
        val longPt = max(page.width, page.height).toDouble()
        val autoScale = min(6.0, max(1.0, targetRenderLongPx / longPt))
        val w = (page.width * autoScale).roundToInt()
        val h = (page.height * autoScale).roundToInt()
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        bmp.eraseColor(Color.WHITE)
        val m = Matrix().apply {
            setScale(w.toFloat() / page.width, h.toFloat() / page.height)
        }
        page.render(bmp, null, m, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
        return bmp
    }

    private fun ocrImage(bmp: Bitmap): List<Map<String, Any>> {
        val det = detSession ?: return emptyList()
        val rec = recSession ?: return emptyList()
        val origW = bmp.width
        val origH = bmp.height
        // 1. Detection: resize to multiples of 32 (≤ limit), normalize, run.
        val ratio = min(detLimitSide.toFloat() / max(origW, origH).toFloat(), 1.0f)
        val newW = max(32, ((origW * ratio / 32).roundToInt()) * 32)
        val newH = max(32, ((origH * ratio / 32).roundToInt()) * 32)
        val detIn = imageToTensor(bmp, newW, newH, detMean, detStd)
        val (prob, pShape) = run(det, detIn, longArrayOf(1, 3, newH.toLong(), newW.toLong()))
            ?: return emptyList()
        if (pShape.size < 2) return emptyList()
        val mH = pShape[pShape.size - 2].toInt()
        val mW = pShape[pShape.size - 1].toInt()
        // 2. Threshold + connected-component boxes in original coords.
        val boxes = detectBoxes(prob, mW, mH, origW, origH)
        // 3. Recognize each box, sorted top-to-bottom (reading order).
        val lines = ArrayList<Map<String, Any>>()
        val fOrigW = max(origW, 1).toDouble()
        for (box in boxes.sortedBy { it.top }) {
            val crop = cropBitmap(bmp, box) ?: continue
            try {
                val (text, conf) = recognize(crop, rec) ?: continue
                if (text.isNotEmpty()) {
                    lines.add(
                        mapOf(
                            "text" to text, "confidence" to conf,
                            "left" to box.left / fOrigW,
                            "width" to box.width() / fOrigW,
                        ))
                }
            } finally {
                crop.recycle()
            }
        }
        return lines
    }

    /** Threshold the DB probability map and extract axis-aligned boxes via a
     * scanline connected-components pass, scaled back to original coords. */
    private fun detectBoxes(prob: FloatArray, mW: Int, mH: Int, origW: Int, origH: Int): List<Rect> {
        val label = IntArray(mW * mH)
        var next = 1
        val minX = ArrayList<Int>()
        val minY = ArrayList<Int>()
        val maxX = ArrayList<Int>()
        val maxY = ArrayList<Int>()
        val area = ArrayList<Int>()
        fun newComp() {
            minX.add(Int.MAX_VALUE); minY.add(Int.MAX_VALUE)
            maxX.add(0); maxY.add(0); area.add(0)
        }
        newComp() // index 0 unused
        val stack = ArrayDeque<Int>()
        for (sy in 0 until mH) {
            for (sx in 0 until mW) {
                val s = sy * mW + sx
                if (prob[s] <= detThresh || label[s] != 0) continue
                newComp()
                val id = next
                next++
                stack.clear()
                stack.addLast(s)
                label[s] = id
                while (stack.isNotEmpty()) {
                    val p = stack.removeLast()
                    val x = p % mW
                    val y = p / mW
                    if (x < minX[id]) minX[id] = x
                    if (x > maxX[id]) maxX[id] = x
                    if (y < minY[id]) minY[id] = y
                    if (y > maxY[id]) maxY[id] = y
                    area[id] = area[id] + 1
                    // 4-neighborhood
                    if (x > 0) { val np = p - 1; if (prob[np] > detThresh && label[np] == 0) { label[np] = id; stack.addLast(np) } }
                    if (x < mW - 1) { val np = p + 1; if (prob[np] > detThresh && label[np] == 0) { label[np] = id; stack.addLast(np) } }
                    if (y > 0) { val np = p - mW; if (prob[np] > detThresh && label[np] == 0) { label[np] = id; stack.addLast(np) } }
                    if (y < mH - 1) { val np = p + mW; if (prob[np] > detThresh && label[np] == 0) { label[np] = id; stack.addLast(np) } }
                }
            }
        }
        val sx = origW.toFloat() / mW
        val sy = origH.toFloat() / mH
        val boxes = ArrayList<Rect>()
        for (id in 1 until next) {
            if (area[id] < detMinBoxArea) continue
            // DBNet shrinks text regions — recover full glyphs with PP-OCR's
            // "unclip": expand by dist = area·ratio/perimeter before the ±1px
            // pad (Mac-verified: word accuracy 92% → 99%).
            val bw = maxX[id] - minX[id] + 1
            val bh = maxY[id] - minY[id] + 1
            val dist = ((bw * bh).toFloat() * detUnclipRatio / (2 * (bw + bh)).toFloat()).roundToInt()
            val mnx = minX[id] - dist
            val mny = minY[id] - dist
            val mxx = maxX[id] + dist
            val mxy = maxY[id] + dist
            val x0 = (max(0, mnx - 1) * sx).toInt()
            val y0 = (max(0, mny - 1) * sy).toInt()
            val x1 = (min(mW, mxx + 2) * sx).toInt()
            val y1 = (min(mH, mxy + 2) * sy).toInt()
            if (x1 > x0 && y1 > y0) boxes.add(Rect(x0, y0, x1, y1))
        }
        return boxes
    }

    private fun cropBitmap(src: Bitmap, box: Rect): Bitmap? {
        val x = max(0, box.left)
        val y = max(0, box.top)
        val w = min(src.width, box.right) - x
        val h = min(src.height, box.bottom) - y
        if (w <= 0 || h <= 0) return null
        return Bitmap.createBitmap(src, x, y, w, h)
    }

    /** Recognize one cropped text-line image → (text, confidence) via CTC greedy. */
    private fun recognize(crop: Bitmap, rec: OrtSession): Pair<String, Double>? {
        val h = crop.height
        val w = crop.width
        if (h == 0) return null
        var rw = (recHeight.toFloat() * w / h).roundToInt()
        rw = max(16, min(rw, recMaxWidth))
        val mean = floatArrayOf(0.5f, 0.5f, 0.5f)
        val std = floatArrayOf(0.5f, 0.5f, 0.5f)
        val inp = imageToTensor(crop, rw, recHeight, mean, std)
        val (out, shape) = run(rec, inp, longArrayOf(1, 3, recHeight.toLong(), rw.toLong()))
            ?: return null
        if (shape.size != 3) return null
        val T = shape[1].toInt()
        val C = shape[2].toInt()
        val sb = StringBuilder()
        var probSum = 0.0
        var emitted = 0
        var prev = -1
        for (t in 0 until T) {
            var best = 0
            var bestP = -1.0f
            val base = t * C
            for (c in 0 until C) {
                val p = out[base + c]
                if (p > bestP) { bestP = p; best = c }
            }
            if (best != 0 && best != prev) {
                val idx = best - 1
                if (idx < keys.size) sb.append(keys[idx]) else sb.append(' ')
                probSum += bestP
                emitted++
            }
            prev = best
        }
        val conf = if (emitted > 0) probSum / emitted else 0.0
        return Pair(sb.toString().trim(), conf)
    }

    // ── Helpers ─────────────────────────────────────────────

    /** Bitmap → NCHW float tensor (RGB), normalized `(p/255 - mean)/std`. */
    private fun imageToTensor(src: Bitmap, w: Int, h: Int, mean: FloatArray, std: FloatArray): FloatArray {
        val scaled = if (src.width == w && src.height == h) src
        else Bitmap.createScaledBitmap(src, w, h, true)
        try {
            val pixels = IntArray(w * h)
            scaled.getPixels(pixels, 0, w, 0, 0, w, h)
            val plane = w * h
            val out = FloatArray(3 * plane)
            for (i in 0 until plane) {
                val p = pixels[i]
                out[i] = (((p shr 16) and 0xFF) / 255f - mean[0]) / std[0]
                out[plane + i] = (((p shr 8) and 0xFF) / 255f - mean[1]) / std[1]
                out[2 * plane + i] = ((p and 0xFF) / 255f - mean[2]) / std[2]
            }
            return out
        } finally {
            if (scaled !== src) scaled.recycle()
        }
    }

    /** Run a single-input/single-output float model → (data, shape). */
    private fun run(session: OrtSession, data: FloatArray, shape: LongArray): Pair<FloatArray, LongArray>? {
        val e = env ?: return null
        val inName = session.inputNames.firstOrNull() ?: "x"
        OnnxTensor.createTensor(e, FloatBuffer.wrap(data), shape).use { tensor ->
            session.run(mapOf(inName to tensor)).use { results ->
                val value = results[0] as? OnnxTensor ?: return null
                val outShape = value.info.shape
                val buf = value.floatBuffer
                val floats = FloatArray(buf.remaining())
                buf.get(floats)
                return Pair(floats, outShape)
            }
        }
    }

    companion object {
        private const val TAG = "PaddleOCR"
    }
}

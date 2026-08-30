package com.tiltastech.castcircle

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
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
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
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
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lifecycleLock = Any()
    @Volatile private var attachment: Attachment? = null
    private var nextGeneration = 0L

    private class Attachment(val generation: Long) {
        val workerThread = AtomicReference<Thread?>()
        lateinit var executor: ThreadPoolExecutor
        @Volatile var detached = false
        @Volatile var loading = true
        @Volatile var ready = false
        var env: OrtEnvironment? = null
        var detSession: OrtSession? = null
        var recSession: OrtSession? = null
        var keys: List<String> = emptyList()
        val detScratch = TensorScratch()
        val recScratch = TensorScratch()
    }

    private class TensorScratch : AutoCloseable {
        private var pixels = IntArray(0)
        private var values = FloatArray(0)
        private var scaledBitmap: Bitmap? = null
        private var canvas: Canvas? = null
        private val paint = Paint(Paint.FILTER_BITMAP_FLAG)

        fun convert(
            src: Bitmap,
            width: Int,
            height: Int,
            mean: FloatArray,
            std: FloatArray,
        ): FloatBuffer {
            val plane = width * height
            if (pixels.size < plane) pixels = IntArray(plane)
            if (values.size < plane * 3) values = FloatArray(plane * 3)

            val image = if (src.width == width && src.height == height) {
                src
            } else {
                ensureBitmap(width, height)
                canvas!!.drawBitmap(src, null, Rect(0, 0, width, height), paint)
                scaledBitmap!!
            }
            image.getPixels(pixels, 0, width, 0, 0, width, height)
            for (i in 0 until plane) {
                val pixel = pixels[i]
                values[i] = (((pixel shr 16) and 0xFF) / 255f - mean[0]) / std[0]
                values[plane + i] =
                    (((pixel shr 8) and 0xFF) / 255f - mean[1]) / std[1]
                values[2 * plane + i] = ((pixel and 0xFF) / 255f - mean[2]) / std[2]
            }
            return FloatBuffer.wrap(values, 0, plane * 3)
        }

        private fun ensureBitmap(width: Int, height: Int) {
            val current = scaledBitmap
            if (current != null && current.width >= width && current.height >= height) return
            val newWidth = max(width, current?.width ?: 0)
            val newHeight = max(height, current?.height ?: 0)
            canvas?.setBitmap(null)
            current?.recycle()
            scaledBitmap = Bitmap.createBitmap(newWidth, newHeight, Bitmap.Config.ARGB_8888)
            canvas = Canvas(scaledBitmap!!)
        }

        override fun close() {
            canvas?.setBitmap(null)
            canvas = null
            scaledBitmap?.recycle()
            scaledBitmap = null
            pixels = IntArray(0)
            values = FloatArray(0)
        }
    }

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
    private val recMean = floatArrayOf(0.5f, 0.5f, 0.5f)
    private val recStd = floatArrayOf(0.5f, 0.5f, 0.5f)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val state = synchronized(lifecycleLock) {
            Attachment(++nextGeneration).also { created ->
                created.executor = ThreadPoolExecutor(
                    1,
                    1,
                    0L,
                    TimeUnit.MILLISECONDS,
                    ArrayBlockingQueue(MAX_PENDING_OCR_JOBS),
                    { runnable ->
                        Thread(runnable, "paddle-ocr-${created.generation}").also {
                            created.workerThread.set(it)
                        }
                    },
                    ThreadPoolExecutor.AbortPolicy(),
                )
                attachment = created
            }
        }
        channel = MethodChannel(binding.binaryMessenger, "com.lineguide/paddle_ocr")
        channel.setMethodCallHandler(this)
        // Loading is the executor's first task, so its FIFO queue is the
        // single shared completion barrier for requests arriving at startup.
        state.executor.execute { loadModels(state, binding) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        val state = synchronized(lifecycleLock) {
            val current = attachment ?: return
            attachment = null
            current.detached = true
            current.ready = false
            current
        }

        val cancelled = ArrayList<Runnable>()
        state.executor.queue.drainTo(cancelled)
        cancelled.filterIsInstance<OcrJob>().forEach { it.cancelSilently() }
        state.workerThread.get()?.interrupt()
        // Cleanup runs after any in-flight ORT call, so sessions are never
        // closed concurrently with inference. The executor is then terminal.
        state.executor.execute { closeAttachment(state) }
        state.executor.shutdown()
    }

    private fun loadModels(
        state: Attachment,
        binding: FlutterPlugin.FlutterPluginBinding,
    ) {
        var localDet: OrtSession? = null
        var localRec: OrtSession? = null
        try {
            val t0 = System.currentTimeMillis()
            val assets = binding.applicationContext.assets
            val flutterAssets = binding.flutterAssets
            fun readAsset(name: String): ByteArray =
                assets.open(flutterAssets.getAssetFilePathByName(name)).use { it.readBytes() }

            val detBytes = readAsset("assets/paddle_ocr/det.onnx")
            val recBytes = readAsset("assets/paddle_ocr/rec.onnx")
            val localKeys = String(
                readAsset("assets/paddle_ocr/keys.txt"),
                Charsets.UTF_8,
            ).split("\n").dropLastWhile { it.isEmpty() }
            val environment = OrtEnvironment.getEnvironment()
            val threads = max(
                2,
                min(Runtime.getRuntime().availableProcessors() / 2, 8),
            )
            OrtSession.SessionOptions().use { options ->
                options.setIntraOpNumThreads(threads)
                options.addConfigEntry("session.intra_op.allow_spinning", "0")
                options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
                localDet = environment.createSession(detBytes, options)
                localRec = environment.createSession(recBytes, options)
            }

            val published = synchronized(lifecycleLock) {
                if (attachment !== state || state.detached) {
                    false
                } else {
                    state.env = environment
                    state.detSession = localDet
                    state.recSession = localRec
                    state.keys = localKeys
                    state.ready = true
                    localDet = null
                    localRec = null
                    true
                }
            }
            if (published) {
                Log.i(
                    TAG,
                    "models loaded in ${System.currentTimeMillis() - t0}ms — " +
                        "${localKeys.size} keys, $threads threads",
                )
            }
        } catch (t: Throwable) {
            if (!state.detached) {
                Log.e(TAG, "model load failed — Dart will fall back to ML Kit", t)
            }
        } finally {
            state.loading = false
            closeSession(localRec, "unpublished recognition session")
            closeSession(localDet, "unpublished detection session")
        }
    }

    private fun closeAttachment(state: Attachment) {
        closeSession(state.recSession, "recognition session")
        state.recSession = null
        closeSession(state.detSession, "detection session")
        state.detSession = null
        state.detScratch.close()
        state.recScratch.close()
        state.env = null
        state.keys = emptyList()
        state.loading = false
        state.ready = false
    }

    private fun closeSession(session: OrtSession?, description: String) {
        if (session == null) return
        try {
            session.close()
        } catch (t: Throwable) {
            Log.w(TAG, "Could not close $description", t)
        }
    }

    // ── Channel ─────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "recognizeText" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGS", "Missing 'path'", null)
                    return
                }
                enqueue(result) { job -> recognizeText(path, job) }
            }
            "ocrPdf" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGS", "Missing 'path'", null)
                    return
                }
                enqueue(result) { job -> ocrPdf(path, job) }
            }
            "ocrPdfPage" -> {
                val path = call.argument<String>("path")
                val page = call.argument<Int>("page")
                if (path == null || page == null) {
                    result.error("INVALID_ARGS", "Missing 'path'/'page'", null)
                    return
                }
                enqueue(result) { job -> ocrPdfPage(path, page, job) }
            }
            else -> result.notImplemented()
        }
    }

    private fun enqueue(
        result: MethodChannel.Result,
        operation: (OcrJob) -> Unit,
    ) {
        val state = attachment
        if (state == null || state.detached) {
            result.error("DETACHED", "PaddleOCR is not attached", null)
            return
        }
        val job = OcrJob(state, result, operation)
        try {
            state.executor.execute(job)
        } catch (_: RejectedExecutionException) {
            if (isCurrent(state)) {
                job.error("BUSY", "PaddleOCR has too many pending requests")
            } else {
                job.cancelSilently()
            }
        }
    }

    private inner class OcrJob(
        private val state: Attachment,
        private val result: MethodChannel.Result,
        private val operation: (OcrJob) -> Unit,
    ) : Runnable {
        private val completed = AtomicBoolean(false)

        override fun run() {
            if (!isCurrent(state)) {
                cancelSilently()
                return
            }
            if (!state.ready) {
                error("NOT_READY", "PaddleOCR models not loaded")
                return
            }
            try {
                operation(this)
            } catch (t: Throwable) {
                if (isCurrent(state)) {
                    Log.e(TAG, "OCR job failed", t)
                    error("OCR_FAILED", t.toString())
                } else {
                    cancelSilently()
                }
            }
        }

        fun success(value: Any?) = complete { it.success(value) }

        fun error(code: String, message: String) =
            complete { it.error(code, message, null) }

        fun cancelSilently() {
            completed.set(true)
        }

        private fun complete(completion: (MethodChannel.Result) -> Unit) {
            if (!completed.compareAndSet(false, true)) return
            mainHandler.post {
                if (isCurrent(state)) completion(result)
            }
        }

        fun state(): Attachment = state
    }

    private fun isCurrent(state: Attachment): Boolean =
        attachment === state && !state.detached

    private fun recognizeText(path: String, job: OcrJob) {
        val bitmap = BitmapFactory.decodeFile(path)
        val blocks = if (bitmap == null) {
            emptyList()
        } else {
            try {
                ocrImage(job.state(), bitmap)
            } catch (t: Throwable) {
                Log.e(TAG, "recognizeText failed", t)
                emptyList()
            } finally {
                bitmap.recycle()
            }
        }
        job.success(mapOf("blocks" to blocks))
    }

    /** OCR a single 1-based page with full normalized rects — the page
     * viewer uses this to highlight where a flagged line's text sits. */
    private fun ocrPdfPage(path: String, pageNumber: Int, job: OcrJob) {
        try {
            if (Thread.currentThread().isInterrupted) throw InterruptedException()
            ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                PdfRenderer(fd).use { renderer ->
                    if (pageNumber < 1 || pageNumber > renderer.pageCount) {
                        job.error("PDF_PAGE_FAILED", "No page $pageNumber")
                        return
                    }
                    renderer.openPage(pageNumber - 1).use { page ->
                        val scale = min(
                            6.0,
                            max(
                                1.0,
                                targetRenderLongPx / max(page.width, page.height).toDouble(),
                            ),
                        )
                        val bitmap = Bitmap.createBitmap(
                            (page.width * scale).toInt(),
                            (page.height * scale).toInt(),
                            Bitmap.Config.ARGB_8888,
                        )
                        bitmap.eraseColor(Color.WHITE)
                        page.render(
                            bitmap,
                            null,
                            null,
                            PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY,
                        )
                        val lines = try {
                            ocrImage(job.state(), bitmap)
                        } finally {
                            bitmap.recycle()
                        }
                        job.success(mapOf("lines" to lines))
                    }
                }
            }
        } catch (t: Throwable) {
            job.error("PDF_PAGE_FAILED", t.toString())
        }
    }

    private fun ocrPdf(path: String, job: OcrJob) {
        val fd = try {
            ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        } catch (t: Throwable) {
            job.error("PDF_OPEN_FAILED", "Could not open PDF: $t")
            return
        }
        try {
            fd.use { openFd ->
                PdfRenderer(openFd).use { renderer ->
                    val pageCount = renderer.pageCount
                    val pages = ArrayList<Map<String, Any>>(pageCount)
                    var failed = 0
                    val jobStart = System.currentTimeMillis()
                    for (i in 0 until pageCount) {
                        if (Thread.currentThread().isInterrupted) throw InterruptedException()
                        postProgress(job.state(), i + 1, pageCount)
                        try {
                            val t0 = System.currentTimeMillis()
                            val lines = renderer.openPage(i).use { page ->
                                val bitmap = renderPage(page)
                                try {
                                    ocrImage(job.state(), bitmap)
                                } finally {
                                    bitmap.recycle()
                                }
                            }
                            pages.add(mapOf("page" to i + 1, "lines" to lines))
                            Log.i(
                                TAG,
                                "page ${i + 1}/$pageCount — ${lines.size} lines in " +
                                    "${System.currentTimeMillis() - t0}ms " +
                                    "(det ${lastDetMs}ms, rec ${lastRecMs}ms)",
                            )
                        } catch (t: Throwable) {
                            if (t is InterruptedException) throw t
                            Log.e(TAG, "page ${i + 1} failed", t)
                            failed++
                        }
                    }
                    val total = (System.currentTimeMillis() - jobStart) / 1000.0
                    Log.i(
                        TAG,
                        "$pageCount pages in ${"%.1f".format(total)}s " +
                            "(${"%.2f".format(total / max(pageCount, 1))} s/page)",
                    )
                    job.success(
                        mapOf(
                            "pages" to pages,
                            "pageCount" to pageCount,
                            "failedPages" to failed,
                        ),
                    )
                }
            }
        } catch (t: Throwable) {
            job.error("PDF_OCR_FAILED", t.toString())
        }
    }

    private fun postProgress(state: Attachment, page: Int, pageCount: Int) {
        mainHandler.post {
            if (isCurrent(state)) {
                channel.invokeMethod(
                    "ocrProgress",
                    mapOf("page" to page, "pageCount" to pageCount),
                )
            }
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

    // Per-page timing breakdown for the caller's log line. Measured on a
    // Galaxy A35: detection ~420ms, recognition ~3.8s (88%) at ~95ms per
    // text line. Recognition is COMPUTE-bound — batching crops through the
    // model's dynamic batch dim was tried and gave no speedup while padding
    // corrupted text (7/56 lines changed), so it was reverted. The real
    // levers are fewer/smaller crops or a lighter rec model.
    private var lastDetMs = 0L
    private var lastRecMs = 0L

    private fun ocrImage(state: Attachment, bmp: Bitmap): List<Map<String, Any>> {
        val det = state.detSession ?: return emptyList()
        val rec = state.recSession ?: return emptyList()
        val tDet0 = System.currentTimeMillis()
        val origW = bmp.width
        val origH = bmp.height
        // 1. Detection: resize to multiples of 32 (≤ limit), normalize, run.
        val ratio = min(detLimitSide.toFloat() / max(origW, origH).toFloat(), 1.0f)
        val newW = max(32, ((origW * ratio / 32).roundToInt()) * 32)
        val newH = max(32, ((origH * ratio / 32).roundToInt()) * 32)
        val detInput = state.detScratch.convert(bmp, newW, newH, detMean, detStd)
        val (prob, pShape) = run(
            state,
            det,
            detInput,
            longArrayOf(1, 3, newH.toLong(), newW.toLong()),
        ) ?: return emptyList()
        if (pShape.size < 2) return emptyList()
        val mH = pShape[pShape.size - 2].toInt()
        val mW = pShape[pShape.size - 1].toInt()
        // 2. Threshold + connected-component boxes in original coords.
        val boxes = detectBoxes(prob, mW, mH, origW, origH)
        lastDetMs = System.currentTimeMillis() - tDet0
        val tRec0 = System.currentTimeMillis()
        // 3. Recognize each box, sorted top-to-bottom (reading order).
        val lines = ArrayList<Map<String, Any>>()
        val fOrigW = max(origW, 1).toDouble()
        val fOrigH = max(origH, 1).toDouble()
        for (box in boxes.sortedBy { it.top }) {
            if (Thread.currentThread().isInterrupted) throw InterruptedException()
            val crop = cropBitmap(bmp, box) ?: continue
            try {
                val (text, conf) = recognize(state, crop, rec) ?: continue
                if (text.isNotEmpty()) {
                    lines.add(
                        mapOf(
                            "text" to text, "confidence" to conf,
                            "left" to box.left / fOrigW,
                            "width" to box.width() / fOrigW,
                            // Full normalized rect for the page viewer's
                            // flagged-line highlight.
                            "top" to box.top / fOrigH,
                            "height" to box.height() / fOrigH,
                        ))
                }
            } finally {
                crop.recycle()
            }
        }
        lastRecMs = System.currentTimeMillis() - tRec0
        return lines
    }

    /** Threshold the DB probability map and extract axis-aligned boxes via a
     * scanline connected-components pass, scaled back to original coords. */
    private fun detectBoxes(prob: FloatArray, mW: Int, mH: Int, origW: Int, origH: Int): List<Rect> {
        // All-primitive connected components: the previous version kept
        // per-component bounds in ArrayList<Int> and the DFS stack in
        // ArrayDeque<Int> — ~2 Integer autobox allocations per foreground
        // pixel (hundreds of thousands per dense page) of pure GC churn.
        // Each component completes before the next seed, so its bounds are
        // plain locals; the stack is a grow-by-doubling IntArray.
        val visited = BooleanArray(mW * mH)
        var stack = IntArray(4096)
        val sx = origW.toFloat() / mW
        val sy = origH.toFloat() / mH
        val boxes = ArrayList<Rect>()
        for (seedY in 0 until mH) {
            for (seedX in 0 until mW) {
                val s = seedY * mW + seedX
                if (prob[s] <= detThresh || visited[s]) continue
                var top = 0
                visited[s] = true
                stack[top++] = s
                var minX = Int.MAX_VALUE
                var minY = Int.MAX_VALUE
                var maxX = 0
                var maxY = 0
                var area = 0
                while (top > 0) {
                    val p = stack[--top]
                    val x = p % mW
                    val y = p / mW
                    if (x < minX) minX = x
                    if (x > maxX) maxX = x
                    if (y < minY) minY = y
                    if (y > maxY) maxY = y
                    area++
                    // 4-neighborhood; push() inlined with stack growth.
                    if (x > 0) {
                        val np = p - 1
                        if (!visited[np] && prob[np] > detThresh) {
                            visited[np] = true
                            if (top == stack.size) stack = stack.copyOf(stack.size * 2)
                            stack[top++] = np
                        }
                    }
                    if (x < mW - 1) {
                        val np = p + 1
                        if (!visited[np] && prob[np] > detThresh) {
                            visited[np] = true
                            if (top == stack.size) stack = stack.copyOf(stack.size * 2)
                            stack[top++] = np
                        }
                    }
                    if (y > 0) {
                        val np = p - mW
                        if (!visited[np] && prob[np] > detThresh) {
                            visited[np] = true
                            if (top == stack.size) stack = stack.copyOf(stack.size * 2)
                            stack[top++] = np
                        }
                    }
                    if (y < mH - 1) {
                        val np = p + mW
                        if (!visited[np] && prob[np] > detThresh) {
                            visited[np] = true
                            if (top == stack.size) stack = stack.copyOf(stack.size * 2)
                            stack[top++] = np
                        }
                    }
                }
                if (area < detMinBoxArea) continue
                // DBNet shrinks text regions — recover full glyphs with PP-OCR's
                // "unclip": expand by dist = area·ratio/perimeter before the ±1px
                // pad (Mac-verified: word accuracy 92% → 99%).
                val bw = maxX - minX + 1
                val bh = maxY - minY + 1
                val dist = ((bw * bh).toFloat() * detUnclipRatio / (2 * (bw + bh)).toFloat()).roundToInt()
                val x0 = (max(0, minX - dist - 1) * sx).toInt()
                val y0 = (max(0, minY - dist - 1) * sy).toInt()
                val x1 = (min(mW, maxX + dist + 2) * sx).toInt()
                val y1 = (min(mH, maxY + dist + 2) * sy).toInt()
                if (x1 > x0 && y1 > y0) boxes.add(Rect(x0, y0, x1, y1))
            }
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
    private fun recognize(
        state: Attachment,
        crop: Bitmap,
        rec: OrtSession,
    ): Pair<String, Double>? {
        val h = crop.height
        val w = crop.width
        if (h == 0) return null
        var rw = (recHeight.toFloat() * w / h).roundToInt()
        rw = max(16, min(rw, recMaxWidth))
        val input = state.recScratch.convert(crop, rw, recHeight, recMean, recStd)
        val (out, shape) = run(
            state,
            rec,
            input,
            longArrayOf(1, 3, recHeight.toLong(), rw.toLong()),
        ) ?: return null
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
                if (idx < state.keys.size) sb.append(state.keys[idx]) else sb.append(' ')
                probSum += bestP
                emitted++
            }
            prev = best
        }
        val conf = if (emitted > 0) probSum / emitted else 0.0
        return Pair(sb.toString().trim(), conf)
    }

    // ── Helpers ─────────────────────────────────────────────

    /** Run a single-input/single-output float model → (data, shape). */
    private fun run(
        state: Attachment,
        session: OrtSession,
        data: FloatBuffer,
        shape: LongArray,
    ): Pair<FloatArray, LongArray>? {
        val environment = state.env ?: return null
        val inputName = session.inputNames.firstOrNull() ?: "x"
        OnnxTensor.createTensor(environment, data, shape).use { tensor ->
            session.run(mapOf(inputName to tensor)).use { results ->
                val value = results[0] as? OnnxTensor ?: return null
                val outShape = value.info.shape
                val buffer = value.floatBuffer
                val floats = FloatArray(buffer.remaining())
                buffer.get(floats)
                return Pair(floats, outShape)
            }
        }
    }

    companion object {
        private const val TAG = "PaddleOCR"
        private const val MAX_PENDING_OCR_JOBS = 8
    }
}

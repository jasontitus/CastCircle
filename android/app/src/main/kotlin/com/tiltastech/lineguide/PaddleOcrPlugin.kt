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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

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
    private val lifecycleLock = Any()
    private var worker: ExecutorService? = null
    private var generation = 0

    private var env: OrtEnvironment? = null
    private var detSession: OrtSession? = null
    private var recSession: OrtSession? = null
    private var keys: List<String> = emptyList()
    @Volatile private var ready = false
    @Volatile private var loading = false

    private data class PendingCall(
        val call: MethodCall,
        val result: MethodChannel.Result,
        val generation: Int,
    )

    private val pendingCalls = mutableListOf<PendingCall>()
    private val activePdfRequests = mutableSetOf<String>()
    private val cancelledPdfRequests = mutableSetOf<String>()

    private class OcrCancelledException : RuntimeException()

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
        this.binding = binding
        channel = MethodChannel(binding.binaryMessenger, "com.lineguide/paddle_ocr")
        channel.setMethodCallHandler(this)
        val currentGeneration: Int
        val executor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "paddle-ocr-worker")
        }
        synchronized(lifecycleLock) {
            generation++
            currentGeneration = generation
            worker = executor
            ready = false
            loading = true
        }
        executor.execute { loadModels(binding, currentGeneration) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        val oldWorker: ExecutorService?
        val oldDet: OrtSession?
        val oldRec: OrtSession?
        val abandoned: List<PendingCall>
        synchronized(lifecycleLock) {
            this.binding = null
            generation++
            ready = false
            loading = false
            oldWorker = worker
            worker = null
            oldDet = detSession
            oldRec = recSession
            abandoned = pendingCalls.toList()
            pendingCalls.clear()
            activePdfRequests.clear()
            cancelledPdfRequests.clear()
        }
        abandoned.forEach {
            it.result.error("DETACHED", "PaddleOCR plugin detached", null)
        }
        if (oldWorker != null) {
            try {
                oldWorker.execute {
                    try { oldDet?.close() } catch (_: Exception) {}
                    try { oldRec?.close() } catch (_: Exception) {}
                    synchronized(lifecycleLock) {
                        if (detSession === oldDet) detSession = null
                        if (recSession === oldRec) recSession = null
                    }
                }
            } catch (_: RejectedExecutionException) {
                try { oldDet?.close() } catch (_: Exception) {}
                try { oldRec?.close() } catch (_: Exception) {}
            }
            oldWorker.shutdown()
        }
    }

    private fun loadModels(
        binding: FlutterPlugin.FlutterPluginBinding,
        loadGeneration: Int,
    ) {
        var loadedDet: OrtSession? = null
        var loadedRec: OrtSession? = null
        try {
            val t0 = System.currentTimeMillis()
            val assets = binding.applicationContext.assets
            val fa = binding.flutterAssets
            fun readAsset(name: String): ByteArray =
                assets.open(fa.getAssetFilePathByName(name)).use { it.readBytes() }

            val loadedEnv = OrtEnvironment.getEnvironment()
            val opts = OrtSession.SessionOptions()
            try {
                // Physical performance cores, capped — mirrors the Swift plugin.
                val threads = max(2, min(Runtime.getRuntime().availableProcessors() / 2, 8))
                opts.setIntraOpNumThreads(threads)
                opts.addConfigEntry("session.intra_op.allow_spinning", "0")
                opts.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
                loadedDet = loadedEnv.createSession(readAsset("assets/paddle_ocr/det.onnx"), opts)
                loadedRec = loadedEnv.createSession(readAsset("assets/paddle_ocr/rec.onnx"), opts)
                val loadedKeys = String(
                    readAsset("assets/paddle_ocr/keys.txt"),
                    Charsets.UTF_8,
                ).split("\n").dropLastWhile { it.isEmpty() }

                val published = synchronized(lifecycleLock) {
                    if (generation == loadGeneration && this.binding === binding) {
                        env = loadedEnv
                        detSession = loadedDet
                        recSession = loadedRec
                        keys = loadedKeys
                        ready = true
                        true
                    } else {
                        false
                    }
                }
                if (!published) return
                loadedDet = null
                loadedRec = null
                Log.i(
                    TAG,
                    "models loaded in ${System.currentTimeMillis() - t0}ms — " +
                        "${loadedKeys.size} keys, $threads threads",
                )
            } finally {
                opts.close()
            }
        } catch (t: Throwable) {
            Log.e(TAG, "model load failed — Dart will fall back to ML Kit", t)
        } finally {
            try { loadedDet?.close() } catch (_: Exception) {}
            try { loadedRec?.close() } catch (_: Exception) {}
            synchronized(lifecycleLock) {
                if (generation == loadGeneration) loading = false
            }
            mainHandler.post { finishPendingCalls(loadGeneration) }
        }
    }

    // ── Channel ─────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "cancelOcrPdf") {
            cancelPdf(call, result)
            return
        }
        val currentGeneration: Int
        synchronized(lifecycleLock) {
            currentGeneration = generation
            if (!ready) {
                if (loading && binding != null) {
                    val pending = PendingCall(call, result, currentGeneration)
                    pendingCalls.add(pending)
                    mainHandler.postDelayed({
                        val timedOut = synchronized(lifecycleLock) {
                            pendingCalls.remove(pending)
                        }
                        if (timedOut) {
                            result.error(
                                "NOT_READY",
                                "PaddleOCR model loading timed out",
                                null,
                            )
                        }
                    }, MODEL_LOAD_TIMEOUT_MS)
                    return
                }
                result.error("NOT_READY", "PaddleOCR models not loaded", null)
                return
            }
        }
        dispatchCall(call, result, currentGeneration)
    }

    private fun finishPendingCalls(loadGeneration: Int) {
        val pending = synchronized(lifecycleLock) {
            val matching = pendingCalls.filter { it.generation == loadGeneration }
            pendingCalls.removeAll(matching.toSet())
            matching
        }
        pending.forEach {
            if (isActive(it.generation) && ready) {
                dispatchCall(it.call, it.result, it.generation)
            } else {
                it.result.error("NOT_READY", "PaddleOCR models not loaded", null)
            }
        }
    }

    private fun dispatchCall(
        call: MethodCall,
        result: MethodChannel.Result,
        callGeneration: Int,
    ) {
        when (call.method) {
            "recognizeText" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGS", "Missing 'path'", null)
                    return
                }
                execute(callGeneration, result) {
                    try {
                        val bitmap = decodeImage(path)
                            ?: throw IllegalArgumentException("Could not decode image")
                        val blocks = try {
                            ocrImage(bitmap)
                        } finally {
                            bitmap.recycle()
                        }
                        postSuccess(callGeneration, result, mapOf("blocks" to blocks))
                    } catch (t: Throwable) {
                        Log.e(TAG, "recognizeText failed", t)
                        postError(
                            callGeneration,
                            result,
                            "IMAGE_OCR_FAILED",
                            t.message ?: t.javaClass.simpleName,
                        )
                    }
                }
            }
            "ocrPdf" -> {
                val path = call.argument<String>("path")
                val scale = call.argument<Number>("scale")?.toDouble()
                val requestId = call.argument<String>("requestId")
                if (path == null || scale == null || !scale.isFinite() || requestId == null) {
                    result.error(
                        "INVALID_ARGS",
                        "Missing or invalid 'path'/'scale'/'requestId'",
                        null,
                    )
                    return
                }
                val registered = synchronized(lifecycleLock) {
                    activePdfRequests.add(requestId)
                }
                if (!registered) {
                    result.error("INVALID_ARGS", "Duplicate OCR requestId", requestId)
                    return
                }
                val scheduled = execute(callGeneration, result) {
                    ocrPdf(path, scale, requestId, result, callGeneration)
                }
                if (!scheduled) {
                    synchronized(lifecycleLock) {
                        activePdfRequests.remove(requestId)
                        cancelledPdfRequests.remove(requestId)
                    }
                }
            }
            "ocrPdfPage" -> {
                val path = call.argument<String>("path")
                val page = call.argument<Int>("page")
                if (path == null || page == null) {
                    result.error("INVALID_ARGS", "Missing 'path'/'page'", null)
                    return
                }
                execute(callGeneration, result) {
                    ocrPdfPage(path, page, result, callGeneration)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun cancelPdf(call: MethodCall, result: MethodChannel.Result) {
        val requestId = call.argument<String>("requestId")
        if (requestId == null) {
            result.error("INVALID_ARGS", "Missing 'requestId'", null)
            return
        }
        val pending: List<PendingCall>
        val active: Boolean
        synchronized(lifecycleLock) {
            pending = pendingCalls.filter {
                it.call.method == "ocrPdf" &&
                    it.call.argument<String>("requestId") == requestId
            }
            pendingCalls.removeAll(pending.toSet())
            active = activePdfRequests.contains(requestId)
            if (active) cancelledPdfRequests.add(requestId)
        }
        pending.forEach {
            it.result.error(
                "ocr_cancelled",
                "PDF OCR was cancelled",
                requestId,
            )
        }
        result.success(pending.isNotEmpty() || active)
    }

    private fun execute(
        callGeneration: Int,
        result: MethodChannel.Result,
        task: () -> Unit,
    ): Boolean {
        val executor = synchronized(lifecycleLock) {
            worker.takeIf { generation == callGeneration }
        }
        if (executor == null) {
            result.error("DETACHED", "PaddleOCR plugin detached", null)
            return false
        }
        return try {
            executor.execute {
                if (isActive(callGeneration)) {
                    task()
                } else {
                    postError(
                        callGeneration,
                        result,
                        "DETACHED",
                        "PaddleOCR plugin detached",
                    )
                }
            }
            true
        } catch (_: RejectedExecutionException) {
            result.error("DETACHED", "PaddleOCR plugin detached", null)
            false
        }
    }

    private fun isActive(callGeneration: Int): Boolean = synchronized(lifecycleLock) {
        generation == callGeneration && binding != null
    }

    private fun postSuccess(
        callGeneration: Int,
        result: MethodChannel.Result,
        value: Any,
    ) {
        mainHandler.post {
            if (isActive(callGeneration)) {
                result.success(value)
            } else {
                result.error("DETACHED", "PaddleOCR plugin detached", null)
            }
        }
    }

    private fun postError(
        callGeneration: Int,
        result: MethodChannel.Result,
        code: String,
        message: String,
        details: Any? = null,
    ) {
        mainHandler.post {
            val actualCode = if (isActive(callGeneration)) code else "DETACHED"
            val actualMessage =
                if (actualCode == "DETACHED") "PaddleOCR plugin detached" else message
            val actualDetails = if (actualCode == "DETACHED") null else details
            result.error(actualCode, actualMessage, actualDetails)
        }
    }

    private fun decodeImage(path: String): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val sourceWidth = bounds.outWidth
        val sourceHeight = bounds.outHeight
        if (sourceWidth <= 0 || sourceHeight <= 0) return null

        var sampleSize = 1
        while (sampleSize < (1 shl 30)) {
            val sampledWidth = max(1, sourceWidth / sampleSize)
            val sampledHeight = max(1, sourceHeight / sampleSize)
            val sampledPixels = sampledWidth.toLong() * sampledHeight.toLong()
            if (max(sampledWidth, sampledHeight) <= MAX_IMAGE_DECODE_DIMENSION &&
                sampledPixels <= MAX_IMAGE_DECODE_PIXELS) {
                break
            }
            sampleSize *= 2
        }
        return BitmapFactory.decodeFile(
            path,
            BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            },
        )
    }

    /** OCR a single 1-based page with full normalized rects — the page
     * viewer uses this to highlight where a flagged line's text sits. */
    private fun ocrPdfPage(
        path: String,
        pageNumber: Int,
        result: MethodChannel.Result,
        callGeneration: Int,
    ) {
        try {
            ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                PdfRenderer(fd).use { renderer ->
                    if (pageNumber < 1 || pageNumber > renderer.pageCount) {
                        postError(
                            callGeneration,
                            result,
                            "PDF_PAGE_FAILED",
                            "No page $pageNumber",
                        )
                        return
                    }
                    renderer.openPage(pageNumber - 1).use { page ->
                        val bitmap = renderPage(page)
                        val lines = try {
                            ocrImage(bitmap)
                        } finally {
                            bitmap.recycle()
                        }
                        postSuccess(callGeneration, result, mapOf("lines" to lines))
                    }
                }
            }
        } catch (t: Throwable) {
            postError(callGeneration, result, "PDF_PAGE_FAILED", "$t")
        }
    }

    private fun ocrPdf(
        path: String,
        requestedScale: Double,
        requestId: String,
        result: MethodChannel.Result,
        callGeneration: Int,
    ) {
        try {
            throwIfPdfCancelled(requestId)
            val fd = try {
                ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
            } catch (t: Throwable) {
                if (isPdfCancelled(requestId)) throw OcrCancelledException()
                postError(
                    callGeneration,
                    result,
                    "PDF_OPEN_FAILED",
                    "Could not open PDF: $t",
                )
                return
            }
            // fd.use: if the PdfRenderer constructor throws on a corrupt PDF,
            // .use on the renderer never runs and the fd would otherwise leak.
            fd.use { openFd ->
                PdfRenderer(openFd).use { renderer ->
                    val pageCount = renderer.pageCount
                    if (pageCount > MAX_PDF_PAGES) {
                        throw IllegalArgumentException(
                            "PDF has $pageCount pages; maximum is $MAX_PDF_PAGES",
                        )
                    }
                    var failed = 0
                    val jobStart = System.currentTimeMillis()
                    for (i in 0 until pageCount) {
                        throwIfPdfCancelled(requestId)
                        if (!isActive(callGeneration)) {
                            postError(
                                callGeneration,
                                result,
                                "DETACHED",
                                "PaddleOCR plugin detached",
                            )
                            return
                        }
                        try {
                            val t0 = System.currentTimeMillis()
                            val lines = renderer.openPage(i).use { page ->
                                throwIfPdfCancelled(requestId)
                                val bitmap = renderPage(page, requestedScale)
                                try {
                                    throwIfPdfCancelled(requestId)
                                    ocrImage(bitmap) { isPdfCancelled(requestId) }
                                } finally {
                                    bitmap.recycle()
                                }
                            }
                            val pageLines = lines.map { line ->
                                mapOf(
                                    "text" to (line["text"] as String),
                                    "confidence" to (line["confidence"] as Number).toDouble(),
                                    "left" to (line["left"] as Number).toDouble(),
                                    "width" to (line["width"] as Number).toDouble(),
                                )
                            }
                            mainHandler.post {
                                if (isActive(callGeneration) && !isPdfCancelled(requestId)) {
                                    channel.invokeMethod(
                                        "ocrPage",
                                        mapOf(
                                            "requestId" to requestId,
                                            "pageIndex" to i + 1,
                                            "lines" to pageLines,
                                        ),
                                    )
                                }
                            }
                            Log.i(
                                TAG,
                                "page ${i + 1}/$pageCount — ${lines.size} lines in " +
                                    "${System.currentTimeMillis() - t0}ms " +
                                    "(det ${lastDetMs}ms, rec ${lastRecMs}ms)",
                            )
                        } catch (cancelled: OcrCancelledException) {
                            throw cancelled
                        } catch (e: Exception) {
                            Log.e(TAG, "page ${i + 1} failed", e)
                            failed++
                        }
                        throwIfPdfCancelled(requestId)
                        mainHandler.post {
                            if (isActive(callGeneration) && !isPdfCancelled(requestId)) {
                                channel.invokeMethod(
                                    "ocrProgress",
                                    mapOf(
                                        "requestId" to requestId,
                                        "page" to i + 1,
                                        "pageCount" to pageCount,
                                    ),
                                )
                            }
                        }
                    }
                    val total = (System.currentTimeMillis() - jobStart) / 1000.0
                    Log.i(
                        TAG,
                        "$pageCount pages in ${"%.1f".format(total)}s " +
                            "(${"%.2f".format(total / max(pageCount, 1))} s/page)",
                    )
                    synchronized(lifecycleLock) {
                        if (cancelledPdfRequests.contains(requestId)) {
                            throw OcrCancelledException()
                        }
                        activePdfRequests.remove(requestId)
                    }
                    postSuccess(
                        callGeneration,
                        result,
                        mapOf(
                            "pageCount" to pageCount,
                            "failedPages" to failed,
                        ),
                    )
                }
            }
        } catch (_: OcrCancelledException) {
            postError(
                callGeneration,
                result,
                "ocr_cancelled",
                "PDF OCR was cancelled",
                requestId,
            )
        } catch (t: Throwable) {
            if (isPdfCancelled(requestId)) {
                postError(
                    callGeneration,
                    result,
                    "ocr_cancelled",
                    "PDF OCR was cancelled",
                    requestId,
                )
            } else {
                postError(callGeneration, result, "PDF_OCR_FAILED", "$t")
            }
        } finally {
            val keepCancellationTombstone = synchronized(lifecycleLock) {
                activePdfRequests.remove(requestId)
                cancelledPdfRequests.contains(requestId)
            }
            if (keepCancellationTombstone) {
                // Queued page/progress callbacks must observe cancellation.
                // Remove the tombstone only after the cancellation reply.
                mainHandler.post {
                    synchronized(lifecycleLock) {
                        cancelledPdfRequests.remove(requestId)
                    }
                }
            } else {
                synchronized(lifecycleLock) {
                    cancelledPdfRequests.remove(requestId)
                }
            }
        }
    }

    private fun isPdfCancelled(requestId: String): Boolean = synchronized(lifecycleLock) {
        cancelledPdfRequests.contains(requestId)
    }

    private fun throwIfPdfCancelled(requestId: String) {
        if (isPdfCancelled(requestId)) throw OcrCancelledException()
    }

    // ── PP-OCR pipeline ─────────────────────────────────────

    private fun renderPage(page: PdfRenderer.Page, requestedScale: Double = 2.0): Bitmap {
        val pageWidth = page.width
        val pageHeight = page.height
        if (pageWidth <= 0 || pageHeight <= 0) {
            throw IllegalArgumentException("PDF page has invalid dimensions")
        }
        // scale=2.0 preserves the established 1800px target. Caller scale is
        // relative and bounded before applying the hard output caps.
        val effectiveTarget =
            targetRenderLongPx * requestedScale.coerceIn(0.5, 4.0) / 2.0
        val longSide = max(pageWidth, pageHeight).toDouble()
        val renderScale = min(6.0, effectiveTarget / longSide)
        val width = max(1, (pageWidth * renderScale).roundToInt())
        val height = max(1, (pageHeight * renderScale).roundToInt())
        val pixels = width.toLong() * height.toLong()
        if (width > MAX_RENDER_DIMENSION || height > MAX_RENDER_DIMENSION ||
            pixels > MAX_RENDER_PIXELS) {
            throw IllegalArgumentException(
                "PDF page render is too large: ${width}x$height",
            )
        }
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.WHITE)
        val matrix = Matrix().apply {
            setScale(width.toFloat() / pageWidth, height.toFloat() / pageHeight)
        }
        page.render(bitmap, null, matrix, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
        return bitmap
    }

    // Per-page timing breakdown for the caller's log line. Measured on a
    // Galaxy A35: detection ~420ms, recognition ~3.8s (88%) at ~95ms per
    // text line. Recognition is COMPUTE-bound — batching crops through the
    // model's dynamic batch dim was tried and gave no speedup while padding
    // corrupted text (7/56 lines changed), so it was reverted. The real
    // levers are fewer/smaller crops or a lighter rec model.
    private var lastDetMs = 0L
    private var lastRecMs = 0L

    private fun ocrImage(
        bmp: Bitmap,
        isCancelled: () -> Boolean = { false },
    ): List<Map<String, Any>> {
        val det = detSession ?: throw IllegalStateException("Detection model unavailable")
        val rec = recSession ?: throw IllegalStateException("Recognition model unavailable")
        val currentEnv = env ?: throw IllegalStateException("ONNX environment unavailable")
        val workspace = TensorWorkspace()
        val tDet0 = System.currentTimeMillis()
        val origW = bmp.width
        val origH = bmp.height
        if (isCancelled()) throw OcrCancelledException()
        // 1. Detection: resize to multiples of 32 (≤ limit), normalize, run.
        val ratio = min(detLimitSide.toFloat() / max(origW, origH).toFloat(), 1.0f)
        val newW = max(32, ((origW * ratio / 32).roundToInt()) * 32)
        val newH = max(32, ((origH * ratio / 32).roundToInt()) * 32)
        val detIn = imageToTensor(bmp, newW, newH, detMean, detStd, workspace)
        if (isCancelled()) throw OcrCancelledException()
        val (prob, probabilityShape) = runDetection(
            currentEnv,
            det,
            detIn,
            longArrayOf(1, 3, newH.toLong(), newW.toLong()),
        )
        if (isCancelled()) throw OcrCancelledException()
        if (probabilityShape.size < 2) {
            throw IllegalStateException("Detection model returned an invalid shape")
        }
        val mapHeight = probabilityShape[probabilityShape.size - 2].toInt()
        val mapWidth = probabilityShape[probabilityShape.size - 1].toInt()
        if (mapWidth <= 0 || mapHeight <= 0 ||
            mapWidth.toLong() * mapHeight.toLong() > prob.size) {
            throw IllegalStateException("Detection model returned invalid dimensions")
        }
        // 2. Threshold + connected-component boxes in original coords.
        val boxes = detectBoxes(prob, mapWidth, mapHeight, origW, origH)
        if (isCancelled()) throw OcrCancelledException()
        lastDetMs = System.currentTimeMillis() - tDet0
        val tRec0 = System.currentTimeMillis()
        // 3. Recognize each box, sorted top-to-bottom (reading order).
        val lines = ArrayList<Map<String, Any>>()
        val fOrigW = max(origW, 1).toDouble()
        val fOrigH = max(origH, 1).toDouble()
        for (box in boxes.sortedBy { it.top }) {
            if (isCancelled()) throw OcrCancelledException()
            val crop = cropBitmap(bmp, box) ?: continue
            try {
                val (text, confidence) = recognize(crop, rec, currentEnv, workspace)
                if (isCancelled()) throw OcrCancelledException()
                if (text.isNotEmpty()) {
                    lines.add(
                        mapOf(
                            "text" to text,
                            "confidence" to confidence,
                            "left" to box.left / fOrigW,
                            "width" to box.width() / fOrigW,
                            // Full normalized rect for the page viewer's
                            // flagged-line highlight.
                            "top" to box.top / fOrigH,
                            "height" to box.height() / fOrigH,
                        ),
                    )
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
        crop: Bitmap,
        rec: OrtSession,
        currentEnv: OrtEnvironment,
        workspace: TensorWorkspace,
    ): Pair<String, Double> {
        val height = crop.height
        val width = crop.width
        if (height <= 0) throw IllegalArgumentException("Invalid recognition crop")
        var resizedWidth = (recHeight.toFloat() * width / height).roundToInt()
        resizedWidth = max(16, min(resizedWidth, recMaxWidth))
        val input = imageToTensor(
            crop,
            resizedWidth,
            recHeight,
            recMean,
            recStd,
            workspace,
        )
        return runRecognizer(
            currentEnv,
            rec,
            input,
            longArrayOf(1, 3, recHeight.toLong(), resizedWidth.toLong()),
        )
    }

    // ── Helpers ─────────────────────────────────────────────

    private class TensorWorkspace {
        var pixels = IntArray(0)
        var floats = FloatArray(0)

        fun ensure(pixelCount: Int) {
            if (pixels.size < pixelCount) pixels = IntArray(pixelCount)
            val floatCount = pixelCount * 3
            if (floats.size < floatCount) floats = FloatArray(floatCount)
        }
    }

    /** Bitmap → NCHW float tensor (RGB), normalized `(p/255 - mean)/std`. */
    private fun imageToTensor(
        src: Bitmap,
        width: Int,
        height: Int,
        mean: FloatArray,
        std: FloatArray,
        workspace: TensorWorkspace,
    ): FloatBuffer {
        val scaled = if (src.width == width && src.height == height) {
            src
        } else {
            Bitmap.createScaledBitmap(src, width, height, true)
        }
        try {
            val plane = width * height
            workspace.ensure(plane)
            scaled.getPixels(workspace.pixels, 0, width, 0, 0, width, height)
            for (i in 0 until plane) {
                val pixel = workspace.pixels[i]
                workspace.floats[i] =
                    (((pixel shr 16) and 0xFF) / 255f - mean[0]) / std[0]
                workspace.floats[plane + i] =
                    (((pixel shr 8) and 0xFF) / 255f - mean[1]) / std[1]
                workspace.floats[2 * plane + i] =
                    ((pixel and 0xFF) / 255f - mean[2]) / std[2]
            }
            return FloatBuffer.wrap(workspace.floats, 0, 3 * plane).slice()
        } finally {
            if (scaled !== src) scaled.recycle()
        }
    }

    private fun runDetection(
        currentEnv: OrtEnvironment,
        session: OrtSession,
        data: FloatBuffer,
        shape: LongArray,
    ): Pair<FloatArray, LongArray> {
        val inputName = session.inputNames.firstOrNull()
            ?: throw IllegalStateException("Detection model has no input")
        OnnxTensor.createTensor(currentEnv, data, shape).use { tensor ->
            session.run(mapOf(inputName to tensor)).use { results ->
                val value = results[0] as? OnnxTensor
                    ?: throw IllegalStateException("Detection model returned no tensor")
                val buffer = value.floatBuffer
                val floats = FloatArray(buffer.remaining())
                buffer.get(floats)
                return Pair(floats, value.info.shape)
            }
        }
    }

    private fun runRecognizer(
        currentEnv: OrtEnvironment,
        session: OrtSession,
        data: FloatBuffer,
        shape: LongArray,
    ): Pair<String, Double> {
        val inputName = session.inputNames.firstOrNull()
            ?: throw IllegalStateException("Recognition model has no input")
        OnnxTensor.createTensor(currentEnv, data, shape).use { tensor ->
            session.run(mapOf(inputName to tensor)).use { results ->
                val value = results[0] as? OnnxTensor
                    ?: throw IllegalStateException("Recognition model returned no tensor")
                val outputShape = value.info.shape
                if (outputShape.size != 3) {
                    throw IllegalStateException("Recognition model returned an invalid shape")
                }
                val timeSteps = outputShape[1].toInt()
                val classes = outputShape[2].toInt()
                val buffer = value.floatBuffer
                if (timeSteps <= 0 || classes <= 0 ||
                    timeSteps.toLong() * classes.toLong() > buffer.remaining()) {
                    throw IllegalStateException("Recognition model returned invalid dimensions")
                }

                val start = buffer.position()
                val text = StringBuilder()
                var probabilitySum = 0.0
                var emitted = 0
                var previous = -1
                for (time in 0 until timeSteps) {
                    var best = 0
                    var bestProbability = -1.0f
                    val base = start + time * classes
                    for (candidate in 0 until classes) {
                        val probability = buffer.get(base + candidate)
                        if (probability > bestProbability) {
                            bestProbability = probability
                            best = candidate
                        }
                    }
                    if (best != 0 && best != previous) {
                        val keyIndex = best - 1
                        if (keyIndex < keys.size) text.append(keys[keyIndex]) else text.append(' ')
                        probabilitySum += bestProbability
                        emitted++
                    }
                    previous = best
                }
                val confidence = if (emitted > 0) probabilitySum / emitted else 0.0
                return Pair(text.toString().trim(), confidence)
            }
        }
    }

    companion object {
        private const val TAG = "PaddleOCR"
        private const val MODEL_LOAD_TIMEOUT_MS = 15_000L
        private const val MAX_PDF_PAGES = 500
        private const val MAX_IMAGE_DECODE_DIMENSION = 1920
        private const val MAX_IMAGE_DECODE_PIXELS = 4_000_000L
        private const val MAX_RENDER_DIMENSION = 4096
        private const val MAX_RENDER_PIXELS = 12_000_000L
    }
}

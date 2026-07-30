package com.zivigo.cameraapp

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import org.tensorflow.lite.nnapi.NnApiDelegate
import java.io.ByteArrayOutputStream
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.PI

/// TFLite neural filter inference plugin — Android equivalent of iOS CoreMLPlugin.
///
/// Method channel: "com.cameraapp/coreml" (same channel name, same API)
///
/// Hardware acceleration: GPU delegate → NNAPI delegate → CPU (4 threads)
class CoreMLPlugin : MethodChannel.MethodCallHandler {
    private var context: Context? = null
    private val modelCache = ConcurrentHashMap<String, Interpreter>()
    private val delegateCache = mutableListOf<Any>() // hold delegates to prevent GC
    private val executor = Executors.newSingleThreadExecutor()

    companion object {
        private const val TAG = "TFLitePlugin"
        private const val CHANNEL = "com.cameraapp/coreml"
        private const val PATCH_SIZE = 448
        private const val PADDING = 16
        private const val MODEL_INPUT_SIZE = 480 // PATCH_SIZE + 2 * PADDING

        fun register(activity: MainActivity, engine: FlutterEngine) {
            val plugin = CoreMLPlugin()
            plugin.context = activity.applicationContext
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler(plugin)
        }
    }

    // ── Method Dispatch ──

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(true)

            "loadModel" -> {
                val modelName = call.argument<String>("modelName")
                if (modelName == null) {
                    result.error("INVALID_ARGS", "Missing modelName", null)
                    return
                }
                executor.execute {
                    try {
                        loadInterpreter(modelName)
                        result.success(true)
                    } catch (e: Exception) {
                        Log.w(TAG, "loadModel failed: ${e.message}")
                        result.success(false)
                    }
                }
            }

            "applyFilter" -> {
                val imageBytes = call.argument<ByteArray>("imageBytes")
                val modelName = call.argument<String>("modelName")
                if (imageBytes == null || modelName == null) {
                    result.error("INVALID_ARGS", "Missing imageBytes or modelName", null)
                    return
                }
                val patchSize = call.argument<Int>("patchSize") ?: PATCH_SIZE
                val padding = call.argument<Int>("padding") ?: PADDING
                executor.execute {
                    try {
                        val interpreter = loadInterpreter(modelName)
                        val input = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
                            ?: throw RuntimeException("Cannot decode image")
                        val output = processTiled(input, interpreter, patchSize, padding)
                        result.success(bitmapToJpeg(output, 95))
                    } catch (e: Exception) {
                        Log.e(TAG, "applyFilter failed", e)
                        result.error("INFERENCE_FAILED", e.message, null)
                    }
                }
            }

            "applyFilterPreview" -> {
                val imageBytes = call.argument<ByteArray>("imageBytes")
                val modelName = call.argument<String>("modelName")
                if (imageBytes == null || modelName == null) {
                    result.error("INVALID_ARGS", "Missing imageBytes or modelName", null)
                    return
                }
                val maxDim = call.argument<Int>("maxDimension") ?: 1024
                executor.execute {
                    try {
                        val interpreter = loadInterpreter(modelName)
                        var input = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
                            ?: throw RuntimeException("Cannot decode image")
                        // Downsample for preview
                        if (input.width > maxDim || input.height > maxDim) {
                            val scale = min(maxDim.toFloat() / input.width, maxDim.toFloat() / input.height)
                            input = Bitmap.createScaledBitmap(input,
                                (input.width * scale).toInt(), (input.height * scale).toInt(), true)
                        }
                        val output = processTiled(input, interpreter, PATCH_SIZE, PADDING)
                        result.success(bitmapToJpeg(output, 85))
                    } catch (e: Exception) {
                        Log.e(TAG, "applyFilterPreview failed", e)
                        result.error("INFERENCE_FAILED", e.message, null)
                    }
                }
            }

            "upscalePhoto" -> {
                val imageBytes = call.argument<ByteArray>("imageBytes")
                if (imageBytes == null) {
                    result.error("INVALID_ARGS", "Missing imageBytes", null)
                    return
                }
                executor.execute {
                    try {
                        val input = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
                            ?: throw RuntimeException("Cannot decode image")
                        val outW = input.width * 2
                        val outH = input.height * 2
                        // Lanczos-equivalent: createScaledBitmap with filter=true (bilinear/bicubic)
                        // iOS uses CILanczosScaleTransform — same concept
                        val output = Bitmap.createScaledBitmap(input, outW, outH, true)
                        Log.i(TAG, "upscalePhoto: ${input.width}x${input.height} → ${outW}x${outH}")
                        result.success(bitmapToJpeg(output, 95))
                    } catch (e: Exception) {
                        Log.e(TAG, "upscalePhoto failed", e)
                        result.error("UPSCALE_FAILED", e.message, null)
                    }
                }
            }

            "clearCache" -> {
                modelCache.values.forEach { it.close() }
                modelCache.clear()
                delegateCache.clear()
                result.success(null)
            }

            "availableModels" -> {
                executor.execute {
                    val models = mutableListOf<String>()
                    try {
                        val ctx = context ?: return@execute
                        // Scan Flutter assets for .tflite model files
                        val files = ctx.assets.list("flutter_assets/assets/models") ?: emptyArray()
                        for (file in files) {
                            if (file.endsWith(".tflite")) {
                                models.add(file.removeSuffix(".tflite"))
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Cannot list models: ${e.message}")
                    }
                    result.success(models.sorted())
                }
            }

            else -> result.notImplemented()
        }
    }

    // ── Model Loading with Hardware Acceleration ──

    private fun loadInterpreter(modelName: String): Interpreter {
        modelCache[modelName]?.let { return it }

        val ctx = context ?: throw RuntimeException("No context")
        val assetPath = "flutter_assets/assets/models/${modelName}.tflite"

        // Load model from Flutter assets
        val fd = ctx.assets.openFd(assetPath)
        val inputStream = FileInputStream(fd.fileDescriptor)
        val channel = inputStream.channel
        val buffer = channel.map(
            java.nio.channels.FileChannel.MapMode.READ_ONLY,
            fd.startOffset, fd.length
        )

        val options = Interpreter.Options()

        // ── Hardware Acceleration Strategy ──
        // 1. GPU delegate (Adreno/Mali/PowerVR — most Android phones)
        try {
            val compatList = CompatibilityList()
            if (compatList.isDelegateSupportedOnThisDevice) {
                val gpuDelegate = GpuDelegate()
                options.addDelegate(gpuDelegate)
                delegateCache.add(gpuDelegate)
                Log.i(TAG, "loadModel: $modelName — using GPU delegate")
            } else {
                throw RuntimeException("GPU not supported")
            }
        } catch (e: Exception) {
            Log.w(TAG, "GPU delegate failed for $modelName: ${e.message}")
            // 2. NNAPI delegate (Android 8.1+, uses NPU/DSP)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                try {
                    val nnApiDelegate = NnApiDelegate()
                    options.addDelegate(nnApiDelegate)
                    delegateCache.add(nnApiDelegate)
                    Log.i(TAG, "loadModel: $modelName — using NNAPI delegate")
                } catch (e2: Exception) {
                    Log.w(TAG, "NNAPI delegate failed: ${e2.message}")
                    // 3. CPU fallback (4 threads)
                    options.setNumThreads(4)
                    Log.i(TAG, "loadModel: $modelName — using CPU (4 threads)")
                }
            } else {
                options.setNumThreads(4)
                Log.i(TAG, "loadModel: $modelName — using CPU (4 threads, pre-O_MR1)")
            }
        }

        val interpreter = Interpreter(buffer, options)
        modelCache[modelName] = interpreter
        return interpreter
    }

    // ── Tile-Based Inference ──

    /// Process image in overlapping tiles, blending with feather alpha.
    /// Mirrors iOS CoreMLPlugin.processTiledFilter().
    private fun processTiled(bitmap: Bitmap, interpreter: Interpreter, patchSize: Int, padding: Int): Bitmap {
        val width = bitmap.width
        val height = bitmap.height
        val cols = ceil(width.toDouble() / patchSize).toInt()
        val rows = ceil(height.toDouble() / patchSize).toInt()
        val effectiveSize = patchSize + 2 * padding // 480

        val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)

        for (row in 0 until rows) {
            for (col in 0 until cols) {
                // 1. Extract tile with padding (edge-replicate for borders)
                val tile = extractTile(bitmap, col, row, patchSize, padding, effectiveSize, width, height)

                // 2. Run TFLite inference on the tile
                val outputTile = runInference(interpreter, tile, effectiveSize)

                // 3. Crop valid region (strip padding from output)
                val validX = padding
                val validY = padding
                val validW = min(patchSize, width - col * patchSize)
                val validH = min(patchSize, height - row * patchSize)
                val validTile = Bitmap.createBitmap(outputTile, validX, validY, validW, validH)

                // 4. Apply feather alpha blending at tile boundaries
                val destX = col * patchSize
                val destY = row * patchSize
                val hasLeft = col > 0
                val hasRight = col < cols - 1
                val hasTop = row > 0
                val hasBottom = row < rows - 1
                val feathered = applyFeatherAlpha(validTile, padding, hasLeft, hasRight, hasTop, hasBottom)

                // 5. Draw onto output canvas
                val paint = Paint(Paint.ANTI_ALIAS_FLAG)
                canvas.drawBitmap(feathered, destX.toFloat(), destY.toFloat(), paint)

                // Recycle intermediate bitmaps
                if (tile !== bitmap) tile.recycle()
                outputTile.recycle()
                if (validTile !== feathered) validTile.recycle()
                feathered.recycle()
            }
        }
        return output
    }

    /// Extract a tile with padding from the source image.
    /// Edge pixels are replicated for border padding.
    private fun extractTile(
        bitmap: Bitmap, col: Int, row: Int,
        patchSize: Int, padding: Int, effectiveSize: Int,
        imgW: Int, imgH: Int
    ): Bitmap {
        val tileStartX = col * patchSize - padding
        val tileStartY = row * patchSize - padding

        // If tile is fully within image bounds, just extract it
        if (tileStartX >= 0 && tileStartY >= 0 &&
            tileStartX + effectiveSize <= imgW && tileStartY + effectiveSize <= imgH) {
            return Bitmap.createBitmap(bitmap, tileStartX, tileStartY, effectiveSize, effectiveSize)
        }

        // Need to pad — create tile and fill with edge-replicated pixels
        val tile = Bitmap.createBitmap(effectiveSize, effectiveSize, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(effectiveSize * effectiveSize)
        bitmap.getPixels(pixels, 0, effectiveSize, 0, 0, 0, 0) // dummy call to init

        // Sample from source with edge clamping
        val srcPixels = IntArray(imgW * imgH)
        bitmap.getPixels(srcPixels, 0, imgW, 0, 0, imgW, imgH)

        for (y in 0 until effectiveSize) {
            for (x in 0 until effectiveSize) {
                val srcX = (tileStartX + x).coerceIn(0, imgW - 1)
                val srcY = (tileStartY + y).coerceIn(0, imgH - 1)
                pixels[y * effectiveSize + x] = srcPixels[srcY * imgW + srcX]
            }
        }
        tile.setPixels(pixels, 0, effectiveSize, 0, 0, effectiveSize, effectiveSize)
        return tile
    }

    /// Run TFLite inference on a single tile.
    /// Input: [1, H, W, 3] float32 normalized to [0, 1]
    /// Output: [1, H, W, 3] float32 in [0, 1]
    private fun runInference(interpreter: Interpreter, tile: Bitmap, size: Int): Bitmap {
        // Prepare input buffer: RGB floats in [0, 1], NHWC layout
        val inputBuf = ByteBuffer.allocateDirect(size * size * 3 * 4)
            .order(ByteOrder.nativeOrder())
        val pixels = IntArray(size * size)
        tile.getPixels(pixels, 0, size, 0, 0, size, size)
        for (pixel in pixels) {
            inputBuf.putFloat(((pixel shr 16) and 0xFF) / 255.0f) // R
            inputBuf.putFloat(((pixel shr 8) and 0xFF) / 255.0f)  // G
            inputBuf.putFloat((pixel and 0xFF) / 255.0f)          // B
        }
        inputBuf.rewind()

        // Prepare output buffer
        val outputBuf = ByteBuffer.allocateDirect(size * size * 3 * 4)
            .order(ByteOrder.nativeOrder())

        // Run inference
        interpreter.run(inputBuf, outputBuf)
        outputBuf.rewind()

        // Convert output floats back to ARGB Bitmap
        val outPixels = IntArray(size * size)
        for (i in outPixels.indices) {
            val r = (outputBuf.float * 255.0f).toInt().coerceIn(0, 255)
            val g = (outputBuf.float * 255.0f).toInt().coerceIn(0, 255)
            val b = (outputBuf.float * 255.0f).toInt().coerceIn(0, 255)
            outPixels[i] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
        }
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        output.setPixels(outPixels, 0, size, 0, 0, size, size)
        return output
    }

    /// Apply feather alpha at tile boundaries for seamless blending.
    /// Mirrors iOS CoreMLPlugin feather alpha algorithm.
    /// Uses a cosine ramp over `padding` pixels at edges that have neighbors.
    private fun applyFeatherAlpha(
        tile: Bitmap, padding: Int,
        hasLeft: Boolean, hasRight: Boolean,
        hasTop: Boolean, hasBottom: Boolean
    ): Bitmap {
        // If no padding needed, return original
        if (!hasLeft && !hasRight && !hasTop && !hasBottom) return tile

        val w = tile.width
        val h = tile.height
        val result = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(w * h)
        tile.getPixels(pixels, 0, w, 0, 0, w, h)

        for (y in 0 until h) {
            for (x in 0 until w) {
                var alpha = 1.0f
                val idx = y * w + x
                val pixel = pixels[idx]

                // Left edge: ramp from 0→1 over `padding` pixels
                if (hasLeft && x < padding) {
                    alpha *= 0.5f * (1.0f - cos(PI.toFloat() * x / padding)).toFloat()
                }
                // Right edge
                if (hasRight && x >= w - padding) {
                    alpha *= 0.5f * (1.0f - cos(PI.toFloat() * (w - 1 - x) / padding)).toFloat()
                }
                // Top edge
                if (hasTop && y < padding) {
                    alpha *= 0.5f * (1.0f - cos(PI.toFloat() * y / padding)).toFloat()
                }
                // Bottom edge
                if (hasBottom && y >= h - padding) {
                    alpha *= 0.5f * (1.0f - cos(PI.toFloat() * (h - 1 - y) / padding)).toFloat()
                }

                // Apply alpha to pixel
                if (alpha < 0.999f) {
                    val a = ((pixel ushr 24) and 0xFF)
                    val r = ((pixel shr 16) and 0xFF)
                    val g = ((pixel shr 8) and 0xFF)
                    val b = (pixel and 0xFF)
                    pixels[idx] = ((a * alpha).toInt() shl 24) or
                            ((r * alpha).toInt() shl 16) or
                            ((g * alpha).toInt() shl 8) or
                            (b * alpha).toInt()
                }
            }
        }
        result.setPixels(pixels, 0, w, 0, 0, w, h)
        return result
    }

    // ── Helpers ──

    private fun bitmapToJpeg(bitmap: Bitmap, quality: Int): ByteArray {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, stream)
        return stream.toByteArray()
    }
}

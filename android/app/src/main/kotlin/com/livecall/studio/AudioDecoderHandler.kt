package com.livecall.studio

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteOrder
import java.util.concurrent.Executors

/**
 * Decodes compressed local/cached audio files to bounded mono PCM16 bytes via
 * Android MediaExtractor + MediaCodec for isolated onset/downbeat analysis.
 */
object AudioDecoderHandler {
    private const val CHANNEL_NAME = "com.livecall.studio/audio_decoder"
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                if (call.method != "decodeToMonoPcm16") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val filePath = call.argument<String>("filePath")?.trim()
                val maxDurationMs = (call.argument<Number>("maxDurationMs")?.toLong() ?: 45000L)
                    .coerceIn(1000L, 180000L)
                if (filePath.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "filePath must not be empty", null)
                    return@setMethodCallHandler
                }
                executor.execute {
                    try {
                        val decoded = decodeFileToMonoPcm16(filePath, maxDurationMs)
                        mainHandler.post { result.success(decoded) }
                    } catch (err: Exception) {
                        mainHandler.post {
                            result.error("DECODE_FAILED", err.message ?: err.toString(), null)
                        }
                    }
                }
            }
    }

    private fun decodeFileToMonoPcm16(
        filePath: String,
        maxDurationMs: Long,
    ): HashMap<String, Any> {
        val startNs = System.nanoTime()
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(filePath)
            var audioTrackIndex = -1
            var selectedFormat: MediaFormat? = null
            var mime = ""
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val trackMime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (trackMime.startsWith("audio/")) {
                    audioTrackIndex = i
                    selectedFormat = format
                    mime = trackMime
                    break
                }
            }
            if (audioTrackIndex < 0 || selectedFormat == null) {
                throw IllegalStateException("No audio track found in file")
            }

            extractor.selectTrack(audioTrackIndex)
            var sampleRate = if (selectedFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                selectedFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE).coerceAtLeast(8000)
            } else {
                44100
            }
            var channels = if (selectedFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                selectedFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
            } else {
                1
            }
            var pcmEncoding = if (selectedFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                selectedFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
            } else {
                AudioFormat.ENCODING_PCM_16BIT
            }

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(selectedFormat, null, null, 0)
            codec.start()

            val bufferInfo = MediaCodec.BufferInfo()
            val pcmOut = ByteArrayOutputStream()
            var inputDone = false
            var outputDone = false
            var decodedSamples = 0L
            var eosStallCount = 0

            while (!outputDone) {
                try {
                    if (!inputDone) {
                        val inIndex = codec.dequeueInputBuffer(10_000L)
                        if (inIndex >= 0) {
                            val inputBuffer = codec.getInputBuffer(inIndex)
                            if (inputBuffer != null) {
                                val sampleSize = extractor.readSampleData(inputBuffer, 0)
                                if (sampleSize < 0) {
                                    codec.queueInputBuffer(
                                        inIndex,
                                        0,
                                        0,
                                        0L,
                                        MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                    )
                                    inputDone = true
                                } else {
                                    val pts = extractor.sampleTime.coerceAtLeast(0L)
                                    codec.queueInputBuffer(inIndex, 0, sampleSize, pts, 0)
                                    extractor.advance()
                                }
                            }
                        }
                    }

                    val outIndex = codec.dequeueOutputBuffer(bufferInfo, 10_000L)
                    when {
                        outIndex >= 0 -> {
                            eosStallCount = 0
                            val outBuffer = codec.getOutputBuffer(outIndex)
                            val maxSamples = (maxDurationMs * sampleRate.toLong()) / 1000L
                            if (outBuffer != null && bufferInfo.size > 0 && decodedSamples < maxSamples) {
                                val slice = outBuffer.duplicate()
                                slice.position(bufferInfo.offset)
                                slice.limit(bufferInfo.offset + bufferInfo.size)
                                slice.order(ByteOrder.LITTLE_ENDIAN)

                                val remainingFrames = (maxSamples - decodedSamples).toInt()
                                when (pcmEncoding) {
                                    AudioFormat.ENCODING_PCM_FLOAT -> {
                                        val floats = slice.asFloatBuffer()
                                        val frameCount = minOf(floats.remaining() / channels, remainingFrames)
                                        for (f in 0 until frameCount) {
                                            var sum = 0.0f
                                            for (ch in 0 until channels) {
                                                sum += floats.get()
                                            }
                                            val monoFloat = (sum / channels.toFloat()).coerceIn(-1.0f, 1.0f)
                                            val s = (monoFloat * 32767.0f).toInt().coerceIn(-32768, 32767)
                                            pcmOut.write(s and 0xFF)
                                            pcmOut.write((s shr 8) and 0xFF)
                                        }
                                        decodedSamples += frameCount
                                    }
                                    AudioFormat.ENCODING_PCM_8BIT -> {
                                        val frameCount = minOf(slice.remaining() / channels, remainingFrames)
                                        for (f in 0 until frameCount) {
                                            var sum = 0
                                            for (ch in 0 until channels) {
                                                val unsigned = slice.get().toInt() and 0xFF
                                                sum += (unsigned - 128) shl 8
                                            }
                                            val s = (sum / channels).coerceIn(-32768, 32767)
                                            pcmOut.write(s and 0xFF)
                                            pcmOut.write((s shr 8) and 0xFF)
                                        }
                                        decodedSamples += frameCount
                                    }
                                    else -> {
                                        val shorts = slice.asShortBuffer()
                                        val frameCount = minOf(shorts.remaining() / channels, remainingFrames)
                                        for (f in 0 until frameCount) {
                                            var sum = 0
                                            for (ch in 0 until channels) {
                                                sum += shorts.get().toInt()
                                            }
                                            val s = (sum / channels).coerceIn(-32768, 32767)
                                            pcmOut.write(s and 0xFF)
                                            pcmOut.write((s shr 8) and 0xFF)
                                        }
                                        decodedSamples += frameCount
                                    }
                                }
                            }
                            codec.releaseOutputBuffer(outIndex, false)
                            val maxSamplesNow = (maxDurationMs * sampleRate.toLong()) / 1000L
                            if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0 ||
                                decodedSamples >= maxSamplesNow
                            ) {
                                outputDone = true
                            }
                        }
                        outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            eosStallCount = 0
                            val outFormat = codec.outputFormat
                            if (outFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                                sampleRate = outFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                                    .coerceAtLeast(8000)
                            }
                            if (outFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                                channels = outFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                                    .coerceAtLeast(1)
                            }
                            if (outFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                                pcmEncoding = outFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                            }
                        }
                        outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            if (inputDone && ++eosStallCount >= 100) {
                                outputDone = true
                            }
                        }
                    }
                } catch (err: Exception) {
                    if (decodedSamples > 0L) {
                        outputDone = true
                    } else {
                        throw err
                    }
                }
            }

            val decodeMs = ((System.nanoTime() - startNs) / 1_000_000L).toInt().coerceAtLeast(0)
            val durationMs = if (sampleRate > 0) {
                ((decodedSamples * 1000L) / sampleRate.toLong()).toInt()
            } else {
                0
            }
            return hashMapOf(
                "pcm16Bytes" to pcmOut.toByteArray(),
                "sampleRate" to sampleRate,
                "channels" to 1,
                "decodedSamples" to decodedSamples.toInt(),
                "durationMs" to durationMs,
                "decodeMs" to decodeMs,
            )
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            try {
                codec?.release()
            } catch (_: Exception) {
            }
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
    }
}

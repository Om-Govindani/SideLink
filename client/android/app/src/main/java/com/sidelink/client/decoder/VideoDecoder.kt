package com.sidelink.client.decoder

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer

class VideoDecoder(
    private val surface: Surface,
    private val width: Int,
    private val height: Int
) {
    private val TAG = "VideoDecoder"
    private var codec: MediaCodec? = null
    private var isRunning = false
    private var dequeueThread: Thread? = null

    fun start() {
        if (isRunning) return
        Log.i(TAG, "Starting H.264 hardware decoder for ${width}x${height}...")

        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
            
            // Configure low-latency playback mode if running on Android 11+
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            
            // Configure decoder to output directly to our hardware rendering Surface
            val mediaCodec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            mediaCodec.configure(format, surface, null, 0)
            mediaCodec.start()
            
            codec = mediaCodec
            isRunning = true

            // Start a dedicated thread for pulling decoded frames from output buffers and rendering them to the Surface
            dequeueThread = Thread { dequeueLoop() }.apply {
                priority = Thread.MAX_PRIORITY
                start()
            }
            
            Log.i(TAG, "Hardware decoder started successfully.")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize MediaCodec: ${e.message}", e)
        }
    }

    /// Feeds raw length-prefixed H.264 NAL blocks into MediaCodec input queue
    fun decode(data: ByteArray) {
        val mediaCodec = codec ?: return
        try {
            val inputBufferIndex = mediaCodec.dequeueInputBuffer(10000) // 10ms timeout
            if (inputBufferIndex >= 0) {
                val inputBuffer: ByteBuffer? = mediaCodec.getInputBuffer(inputBufferIndex)
                inputBuffer?.clear()
                inputBuffer?.put(data)
                
                val presentationTimeUs = System.nanoTime() / 1000
                mediaCodec.queueInputBuffer(
                    inputBufferIndex,
                    0,
                    data.size,
                    presentationTimeUs,
                    0
                )
            } else {
                Log.w(TAG, "No input buffer available, dropping frame.")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error queueing input frame: ${e.message}")
        }
    }

    fun stop() {
        if (!isRunning) return
        Log.i(TAG, "Stopping decoder session...")
        isRunning = false
        
        dequeueThread?.interrupt()
        try { dequeueThread?.join(500) } catch (e: Exception) {}
        dequeueThread = null
        
        try {
            codec?.stop()
            codec?.release()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping codec: ${e.message}")
        }
        codec = null
        Log.i(TAG, "Decoder release complete.")
    }

    private fun dequeueLoop() {
        val info = MediaCodec.BufferInfo()
        while (isRunning && !Thread.interrupted()) {
            val mediaCodec = codec ?: break
            try {
                // Dequeue available output buffers with a 10ms timeout
                val outputBufferIndex = mediaCodec.dequeueOutputBuffer(info, 10000)
                
                if (outputBufferIndex >= 0) {
                    // Release the buffer and set render = true.
                    // This forces MediaCodec to draw the decoded frame buffer directly on the GPU Surface texture queue.
                    mediaCodec.releaseOutputBuffer(outputBufferIndex, true)
                } else if (outputBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    Log.i(TAG, "MediaCodec output format changed: ${mediaCodec.outputFormat}")
                }
            } catch (e: Exception) {
                if (e is InterruptedException) break
                Log.e(TAG, "Error in dequeue loop: ${e.message}")
            }
        }
    }
}

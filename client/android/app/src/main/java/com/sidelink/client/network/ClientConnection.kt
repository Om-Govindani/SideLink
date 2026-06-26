package com.sidelink.client.network

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer

interface ClientConnectionListener {
    fun onConnected()
    fun onDisconnected(reason: String)
    fun onFrameReceived(data: ByteArray)
}

class ClientConnection(
    private val hostIp: String,
    private val controlPort: Int,
    private val secret: String,
    private val listener: ClientConnectionListener
) {
    private val TAG = "ClientConnection"
    private val streamPort = controlPort + 1
    
    private var controlSocket: Socket? = null
    private var streamSocket: Socket? = null
    
    private var controlOut: DataOutputStream? = null
    private var controlIn: DataInputStream? = null
    
    private var streamIn: DataInputStream? = null
    
    private val scope = CoroutineScope(Dispatchers.IO)
    private var connectionJob: Job? = null
    
    private var isClosed = false

    fun start() {
        connectionJob = scope.launch {
            try {
                Log.i(TAG, "Connecting to control socket at $hostIp:$controlPort...")
                val cSocket = Socket()
                cSocket.tcpNoDelay = true // Disable Nagle's algorithm for low-latency
                cSocket.connect(InetSocketAddress(hostIp, controlPort), 5000)
                controlSocket = cSocket
                
                controlOut = DataOutputStream(cSocket.getOutputStream())
                controlIn = DataInputStream(cSocket.getInputStream())
                
                Log.i(TAG, "Control socket established. Sending pairing handshake...")
                
                // 1. Perform Handshake: Send secret
                val secretBytes = secret.toByteArray(Charsets.UTF_8)
                val length = 1 + secretBytes.size // 1 byte for type + secret bytes
                
                controlOut?.writeInt(length)
                controlOut?.writeByte(0x01) // Type 0x01: Handshake Request
                controlOut?.write(secretBytes)
                controlOut?.flush()
                
                // 2. Await Handshake Response
                val respLength = controlIn?.readInt() ?: -1
                val respType = controlIn?.readByte() ?: -1
                if (respLength != 2 || respType.toInt() != 0x02) {
                    throw Exception("Invalid handshake response format.")
                }
                
                val result = controlIn?.readByte() ?: -1
                if (result.toInt() != 0x00) {
                    throw Exception("Authentication failed. Pairing secret rejected.")
                }
                
                Log.i(TAG, "Handshake successful. Control paired.")
                
                // 3. Connect Video Stream Socket
                Log.i(TAG, "Connecting to stream socket at $hostIp:$streamPort...")
                val sSocket = Socket()
                sSocket.tcpNoDelay = true
                sSocket.connect(InetSocketAddress(hostIp, streamPort), 5000)
                streamSocket = sSocket
                streamIn = DataInputStream(sSocket.getInputStream())
                
                listener.onConnected()
                
                // 4. Start Video Receiving Loop & Control Reading Loop
                launch { readVideoStreamLoop() }
                readControlMessagesLoop()
                
            } catch (e: Exception) {
                Log.e(TAG, "Connection failed: ${e.message}", e)
                close("Error: ${e.message}")
            }
        }
    }

    /// Request macOS host to set up a virtual screen matching our dimensions
    fun configureDisplay(width: Int, height: Int, fps: Int) {
        scope.launch {
            try {
                Log.i(TAG, "Requesting display configuration: ${width}x${height} @ $fps FPS")
                // Length: 1 (Type) + 4 (width) + 4 (height) + 1 (fps) = 10 bytes
                controlOut?.writeInt(10)
                controlOut?.writeByte(0x03) // Type 0x03: Configure Display
                controlOut?.writeInt(width)
                controlOut?.writeInt(height)
                controlOut?.writeByte(fps)
                controlOut?.flush()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send configuration request: ${e.message}")
                close("Failed to configure: ${e.message}")
            }
        }
    }

    /// Send touch/mouse input events back to the Mac
    fun sendInputEvent(type: Byte, x: Float, y: Float) {
        scope.launch {
            try {
                // Packet: Length (10) | Type (0x04) | TouchType (1) | X (4) | Y (4)
                val buffer = ByteBuffer.allocate(14)
                buffer.putInt(10)       // Length (Type + TouchType + FloatX + FloatY)
                buffer.put(0x04.toByte()) // Type: Input Event
                buffer.put(type)         // Touch Action
                buffer.putFloat(x)       // Normalized X
                buffer.putFloat(y)       // Normalized Y
                
                controlOut?.write(buffer.array())
                controlOut?.flush()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send input packet: ${e.message}")
            }
        }
    }

    fun close(reason: String = "Closed") {
        if (isClosed) return
        isClosed = true
        Log.i(TAG, "Closing connection. Reason: $reason")
        
        connectionJob?.cancel()
        
        try { controlSocket?.close() } catch (e: Exception) {}
        try { streamSocket?.close() } catch (e: Exception) {}
        
        controlSocket = null
        streamSocket = null
        
        listener.onDisconnected(reason)
    }

    private suspend fun readVideoStreamLoop() {
        try {
            val buffer = ByteArray(1024 * 1024) // 1MB buffer allocation reuse
            while (scope.isActive && !isClosed) {
                val stream = streamIn ?: break
                
                // Read 4-byte NALU packet length prefix
                val frameLength = stream.readInt()
                if (frameLength <= 0) continue
                
                // Read frame payload bytes
                var bytesRead = 0
                while (bytesRead < frameLength && !isClosed) {
                    val read = stream.read(buffer, bytesRead, frameLength - bytesRead)
                    if (read == -1) throw Exception("Stream socket end of file.")
                    bytesRead += read
                }
                
                // Deliver H.264 block to VideoDecoder
                val payload = ByteArray(frameLength)
                System.arraycopy(buffer, 0, payload, 0, frameLength)
                listener.onFrameReceived(payload)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Video read stream loop terminated: ${e.message}")
            close("Stream loop error: ${e.message}")
        }
    }

    private fun readControlMessagesLoop() {
        try {
            while (scope.isActive && !isClosed) {
                val stream = controlIn ?: break
                val length = stream.readInt()
                if (length <= 0) continue
                
                val type = stream.readByte()
                val payloadLength = length - 1
                if (payloadLength > 0) {
                    val payload = ByteArray(payloadLength)
                    stream.readFully(payload)
                    // Process any server control messages (like clipboard sync) here in the future
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Control channel read loop terminated: ${e.message}")
            close("Control loop error: ${e.message}")
        }
    }
}

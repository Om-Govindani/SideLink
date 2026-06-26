package com.sidelink.client

import android.content.pm.ActivityInfo
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sidelink.client.decoder.VideoDecoder
import com.sidelink.client.network.ClientConnection
import com.sidelink.client.network.ClientConnectionListener
import com.sidelink.client.ui.QRScanner
import com.sidelink.client.ui.StreamingSurface

enum class AppState {
    LANDING,
    SCANNING,
    CONNECTING,
    STREAMING
}

class MainActivity : ComponentActivity(), ClientConnectionListener {
    
    private var connection: ClientConnection? = null
    private var decoder: VideoDecoder? = null
    
    // Observable UI states
    private var appState by mutableStateOf(AppState.LANDING)
    private var statusMessage by mutableStateOf("")
    private var errorMessage by mutableStateOf<String?>(null)
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Prevent screen sleep while streaming
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        
        setContent {
            MaterialTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = Color(0xFF121212L) // Modern dark background
                ) {
                    MainScreen()
                }
            }
        }
    }
    
    @Composable
    private fun MainScreen() {
        LaunchedEffect(appState) {
            requestedOrientation = when (appState) {
                AppState.STREAMING -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                else -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
        }

        when (appState) {
            AppState.LANDING -> LandingView(
                onScanClick = { appState = AppState.SCANNING },
                error = errorMessage
            )
            AppState.SCANNING -> QRScanner(
                onScanSuccess = { uri -> handleScannedUri(uri) },
                onClose = { appState = AppState.LANDING }
            )
            AppState.CONNECTING -> ConnectingView(
                status = statusMessage,
                onCancel = { disconnect() }
            )
            AppState.STREAMING -> StreamingView()
        }
    }
    
    // MARK: - Navigation Views
    
    @Composable
    private fun LandingView(
        onScanClick: () -> Unit,
        error: String?
    ) {
        var isManualMode by remember { mutableStateOf(false) }
        var manualIp by remember { mutableStateOf("") }
        var manualPort by remember { mutableStateOf("5230") }
        var manualSecret by remember { mutableStateOf("") }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        colors = listOf(Color(0xFF1E1E2CL), Color(0xFF121212L))
                    )
                )
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Text(
                text = "SideLink",
                fontSize = 40.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White,
                letterSpacing = 2.sp
            )
            
            Text(
                text = "Turn this device into a second screen for your Mac.",
                fontSize = 16.sp,
                color = Color.Gray,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 8.dp, bottom = if (isManualMode) 16.dp else 48.dp)
            )
            
            if (!isManualMode) {
                Button(
                    onClick = onScanClick,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color(0xFF3F51B5L)
                    ),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier
                        .fillMaxWidth(0.8f)
                        .height(56.dp)
                ) {
                    Text(
                        text = "Scan QR to Connect",
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Medium,
                        color = Color.White
                    )
                }
                
                Spacer(modifier = Modifier.height(16.dp))
                
                TextButton(
                    onClick = { isManualMode = true }
                ) {
                    Text(
                        text = "Connect Manually",
                        color = Color(0xFF3F51B5L),
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Medium
                    )
                }
            } else {
                Column(
                    modifier = Modifier.fillMaxWidth(0.8f),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        OutlinedTextField(
                            value = manualIp,
                            onValueChange = { manualIp = it },
                            label = { Text("Mac IP Address", color = Color.Gray) },
                            textStyle = TextStyle(color = Color.White),
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                            modifier = Modifier.weight(1.5f)
                        )
                        OutlinedTextField(
                            value = manualPort,
                            onValueChange = { manualPort = it },
                            label = { Text("Port", color = Color.Gray) },
                            textStyle = TextStyle(color = Color.White),
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            modifier = Modifier.weight(0.7f)
                        )
                    }
                    
                    Spacer(modifier = Modifier.height(8.dp))
                    
                    OutlinedTextField(
                        value = manualSecret,
                        onValueChange = { manualSecret = it.uppercase() },
                        label = { Text("Pairing Code", color = Color.Gray) },
                        textStyle = TextStyle(color = Color.White),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    
                    Spacer(modifier = Modifier.height(24.dp))
                    
                    Button(
                        onClick = {
                            val port = manualPort.toIntOrNull() ?: 5230
                            startConnection(manualIp.trim(), port, manualSecret.trim())
                        },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Color(0xFF3F51B5L)
                        ),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(56.dp)
                    ) {
                        Text(
                            text = "Connect",
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Medium,
                            color = Color.White
                        )
                    }
                    
                    Spacer(modifier = Modifier.height(8.dp))
                    
                    TextButton(
                        onClick = { isManualMode = false }
                    ) {
                        Text(
                            text = "Back to QR Scan",
                            color = Color.Gray,
                            fontSize = 14.sp
                        )
                    }
                }
            }
            
            if (error != null) {
                Spacer(modifier = Modifier.height(24.dp))
                Text(
                    text = error,
                    color = Color(0xFFEF5350L),
                    fontSize = 14.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(0.8f)
                )
            }
        }
    }
    
    @Composable
    private fun ConnectingView(
        status: String,
        onCancel: () -> Unit
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            CircularProgressIndicator(color = Color(0xFF3F51B5L))
            
            Spacer(modifier = Modifier.height(24.dp))
            
            Text(
                text = status,
                fontSize = 18.sp,
                color = Color.White,
                textAlign = TextAlign.Center
            )
            
            Spacer(modifier = Modifier.height(48.dp))
            
            Button(
                onClick = onCancel,
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color.DarkGray
                ),
                shape = RoundedCornerShape(8.dp)
            ) {
                Text("Cancel", color = Color.White)
            }
        }
    }
    
    @Composable
    private fun StreamingView() {
        // Automatically hide system navigation/status bars when entering streaming screen
        DisposableEffect(Unit) {
            setImmersiveMode(true)
            onDispose {
                setImmersiveMode(false)
            }
        }
        
        Box(modifier = Modifier.fillMaxSize()) {
            StreamingSurface(
                onSurfaceCreated = { surface ->
                    // Since the screen is rotating to landscape, compute landscape dimensions
                    val metrics = resources.displayMetrics
                    val landscapeWidth = maxOf(metrics.widthPixels, metrics.heightPixels)
                    val landscapeHeight = minOf(metrics.widthPixels, metrics.heightPixels)
                    
                    // Initialize and launch hardware decoder on physical surface
                    val dec = VideoDecoder(surface, landscapeWidth, landscapeHeight)
                    dec.start()
                    decoder = dec
                    
                    // Request Mac host to initialize virtual monitor matching device resolution
                    connection?.configureDisplay(
                        width = landscapeWidth,
                        height = landscapeHeight,
                        fps = 60
                    )
                },
                onSurfaceDestroyed = {
                    decoder?.stop()
                    decoder = null
                },
                onTouchEvent = { type, x, y ->
                    // Send touchscreen actions back to the host
                    connection?.sendInputEvent(type, x, y)
                }
            )
        }
    }
    
    // MARK: - Connection Handlers
    
    private fun startConnection(ip: String, port: Int, secret: String) {
        errorMessage = null
        statusMessage = "Connecting to host..."
        appState = AppState.CONNECTING
        
        try {
            if (ip.isBlank()) throw Exception("IP address cannot be empty.")
            if (secret.isBlank()) throw Exception("Pairing code cannot be empty.")
            
            connection = ClientConnection(ip, port, secret, this).apply {
                start()
            }
        } catch (e: Exception) {
            errorMessage = e.message
            appState = AppState.LANDING
        }
    }
    
    private fun handleScannedUri(uriString: String) {
        errorMessage = null
        statusMessage = "Connecting to host..."
        appState = AppState.CONNECTING
        
        try {
            val uri = Uri.parse(uriString)
            if (uri.scheme != "sidelink" || uri.host != "connect") {
                throw Exception("Invalid QR code payload.")
            }
            
            val ip = uri.getQueryParameter("ip") ?: throw Exception("IP address missing from QR.")
            val port = uri.getQueryParameter("port")?.toIntOrNull() ?: 5230
            val secret = uri.getQueryParameter("secret") ?: throw Exception("Session key missing from QR.")
            
            startConnection(ip, port, secret)
            
        } catch (e: Exception) {
            errorMessage = e.message
            appState = AppState.LANDING
        }
    }
    
    private fun disconnect() {
        connection?.close()
        connection = null
        decoder?.stop()
        decoder = null
        
        appState = AppState.LANDING
    }
    
    override fun onDestroy() {
        super.onDestroy()
        disconnect()
    }
    
    // MARK: - ClientConnectionListener callbacks
    
    override fun onConnected() {
        runOnUiThread {
            statusMessage = "Setting up stream session..."
            appState = AppState.STREAMING
        }
    }
    
    override fun onDisconnected(reason: String) {
        runOnUiThread {
            errorMessage = reason
            disconnect()
        }
    }
    
    override fun onFrameReceived(data: ByteArray) {
        // Forward H.264 packet to low-latency decoder
        decoder?.decode(data)
    }
    
    // MARK: - System UI Utility
    
    private fun setImmersiveMode(enable: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let { controller ->
                if (enable) {
                    controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                    controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                } else {
                    controller.show(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                }
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = if (enable) {
                (View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        or View.SYSTEM_UI_FLAG_FULLSCREEN
                        or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY)
            } else {
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            }
        }
    }
}

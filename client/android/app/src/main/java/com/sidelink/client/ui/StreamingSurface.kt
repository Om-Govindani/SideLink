package com.sidelink.client.ui

import android.annotation.SuppressLint
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView

@SuppressLint("ClickableViewAccessibility")
@Composable
fun StreamingSurface(
    onSurfaceCreated: (Surface) -> Unit,
    onSurfaceDestroyed: () -> Unit,
    onTouchEvent: (type: Byte, x: Float, y: Float) -> Unit,
    modifier: Modifier = Modifier
) {
    AndroidView(
        factory = { context ->
            val surfaceView = SurfaceView(context).apply {
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
            }

            surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    onSurfaceCreated(holder.surface)
                }

                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    onSurfaceDestroyed()
                }
            })

            surfaceView.setOnTouchListener { view, event ->
                val width = view.width.toFloat()
                val height = view.height.toFloat()
                if (width > 0 && height > 0) {
                    // Normalize touch coordinate relative to screen size (0.0 to 1.0)
                    val normX = event.x / width
                    val normY = event.y / height
                    
                    // Clamp coordinates to range [0.0, 1.0] to prevent host overflow
                    val clampedX = normX.coerceIn(0f, 1f)
                    val clampedY = normY.coerceIn(0f, 1f)
                    
                    val actionType: Byte? = when (event.actionMasked) {
                        MotionEvent.ACTION_DOWN -> 0x00.toByte()
                        MotionEvent.ACTION_MOVE -> 0x01.toByte()
                        MotionEvent.ACTION_UP -> 0x02.toByte()
                        // Map double tap/two-finger secondary clicks to right click in the future if needed
                        else -> null
                    }
                    
                    if (actionType != null) {
                        onTouchEvent(actionType, clampedX, clampedY)
                    }
                }
                true
            }

            surfaceView
        },
        modifier = modifier.fillMaxSize()
    )
}

package dev.uconnect.uconnect_mobile

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import kotlin.math.abs
import kotlin.math.hypot

// Injects input into this device so a trusted peer watching its screen can
// control it (the host side of remote control). Android only lets an app move
// the pointer or press keys through an AccessibilityService that the user has
// turned on in Settings, so this service does the dispatching and the rest of
// the app talks to it through the running instance.
//
// A pointer stream (in.mouse) is collected into one gesture from press to
// release and then dispatched: a short path taps, a longer one swipes/drags
// over the same time it took. Scrolls, a few navigation keys and text into the
// focused field are supported too.
class UconnectAccessibilityService : AccessibilityService() {

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    // --- pointer gesture accumulation -----------------------------------------

    private val path = Path()
    private var down = false
    private var downAt = 0L
    private var lastX = 0f
    private var lastY = 0f
    private var moved = 0f

    fun pointer(x: Float, y: Float, pressed: Boolean) {
        if (pressed && !down) {
            down = true
            downAt = SystemClock.uptimeMillis()
            moved = 0f
            lastX = x; lastY = y
            path.reset()
            path.moveTo(x, y)
        } else if (pressed && down) {
            moved += hypot((x - lastX).toDouble(), (y - lastY).toDouble()).toFloat()
            lastX = x; lastY = y
            path.lineTo(x, y)
        } else if (!pressed && down) {
            down = false
            val dur = (SystemClock.uptimeMillis() - downAt).coerceIn(1L, 4000L)
            if (moved < 12f) {
                tap(lastX, lastY)
            } else {
                dispatch(path, dur)
            }
        }
    }

    fun tap(x: Float, y: Float) {
        val p = Path().apply { moveTo(x, y); lineTo(x + 0.1f, y + 0.1f) }
        dispatch(p, 40L)
    }

    fun scroll(cx: Float, cy: Float, dx: Int, dy: Int) {
        // Wheel notches (120 units each) -> a short swipe opposite the content
        // motion, so a wheel-down scrolls the page down.
        val p = Path()
        p.moveTo(cx, cy)
        val stepX = -dx / 120f * 220f
        val stepY = -dy / 120f * 220f
        p.lineTo(cx + stepX, cy + stepY)
        dispatch(p, 120L)
    }

    private fun dispatch(p: Path, durationMs: Long) {
        try {
            val stroke = GestureDescription.StrokeDescription(p, 0, durationMs)
            dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
        } catch (_: Throwable) {
        }
    }

    // --- keys and text --------------------------------------------------------

    // A few USB-HID keyboard usages mapped to the navigation this device can do.
    fun key(usage: Int) {
        when (usage) {
            0x29 -> performGlobalAction(GLOBAL_ACTION_BACK)        // Escape
            0x4A -> performGlobalAction(GLOBAL_ACTION_HOME)        // Home
            0x3A -> performGlobalAction(GLOBAL_ACTION_RECENTS)     // F1 -> recents
            0x2A -> backspaceFocused()                             // Backspace
            0x28 -> {                                              // Enter
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    softKeyEnter()
                }
            }
        }
    }

    fun text(value: String) {
        val node = focusedEditable() ?: return
        val existing = node.text?.toString() ?: ""
        val args = android.os.Bundle()
        args.putCharSequence(
            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, existing + value
        )
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    private fun backspaceFocused() {
        val node = focusedEditable() ?: return
        val existing = node.text?.toString() ?: ""
        if (existing.isEmpty()) return
        val args = android.os.Bundle()
        args.putCharSequence(
            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
            existing.substring(0, existing.length - 1)
        )
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    private fun softKeyEnter() {
        val node = focusedEditable() ?: return
        node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    private fun focusedEditable(): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        return if (focused != null && focused.isEditable) focused else null
    }

    fun releaseInput() {
        if (down) {
            down = false
        }
    }

    @Suppress("unused")
    private fun near(a: Float, b: Float) = abs(a - b) < 1f

    companion object {
        @Volatile
        var instance: UconnectAccessibilityService? = null

        fun isRunning(): Boolean = instance != null
    }
}

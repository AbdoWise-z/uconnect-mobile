package dev.uconnect.uconnect_mobile

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The foreground-service notification (shown while connected in the
        // background) needs this permission on Android 13+. The service keeps
        // the app alive either way; this just lets its notification show.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001
            )
        }
    }

    private var screenDecoder: ScreenDecoder? = null
    private var screenCapturer: ScreenCapturer? = null
    private var cameraCapturer: CameraCapturer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Decodes a shared screen's H.264 into a Flutter texture (watching).
        screenDecoder = ScreenDecoder(
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer,
        )
        // Captures and encodes this device's screen (sharing to a peer).
        screenCapturer = ScreenCapturer(
            this, flutterEngine.dartExecutor.binaryMessenger
        )
        // Captures and encodes this device's camera (sharing to a peer).
        cameraCapturer = CameraCapturer(
            this, flutterEngine.dartExecutor.binaryMessenger
        )
        // Dart starts the foreground service when a session connects and stops
        // it when the session ends; see lib/app/background.dart.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "uconnect/service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val text = call.argument<String>("text") ?: "Connected"
                        UconnectService.start(applicationContext, text)
                        result.success(null)
                    }
                    "stop" -> {
                        UconnectService.stop(applicationContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Remote control: a viewer's input, injected through the accessibility
        // service (lib/core/screen/remote_input.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "uconnect/input")
            .setMethodCallHandler { call, result ->
                val svc = UconnectAccessibilityService.instance
                when (call.method) {
                    "available" -> result.success(UconnectAccessibilityService.isRunning())
                    "openSettings" -> {
                        startActivity(
                            Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(null)
                    }
                    "pointer" -> {
                        val (w, h) = realScreenSize()
                        svc?.pointer(
                            (call.argument<Double>("x") ?: 0.0).toFloat() * w,
                            (call.argument<Double>("y") ?: 0.0).toFloat() * h,
                            call.argument<Boolean>("pressed") ?: false,
                        )
                        result.success(null)
                    }
                    "scroll" -> {
                        val (w, h) = realScreenSize()
                        svc?.scroll(
                            (call.argument<Double>("x") ?: 0.0).toFloat() * w,
                            (call.argument<Double>("y") ?: 0.0).toFloat() * h,
                            call.argument<Int>("dx") ?: 0,
                            call.argument<Int>("dy") ?: 0,
                        )
                        result.success(null)
                    }
                    "key" -> {
                        svc?.key(call.argument<Int>("usage") ?: 0)
                        result.success(null)
                    }
                    "text" -> {
                        svc?.text(call.argument<String>("text") ?: "")
                        result.success(null)
                    }
                    "release" -> {
                        svc?.releaseInput()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        // The screen rotated while we may be sharing it: rebuild the capture at
        // the new dimensions so the viewer sees it the right way up.
        screenCapturer?.onRotation()
    }

    @Suppress("DEPRECATION")
    private fun realScreenSize(): Pair<Int, Int> {
        val m = android.util.DisplayMetrics()
        windowManager.defaultDisplay.getRealMetrics(m)
        return Pair(m.widthPixels, m.heightPixels)
    }

    @Deprecated("deprecated base method; still the delivery path for the capture-consent result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == ScreenCapturer.CONSENT_REQUEST) {
            screenCapturer?.onConsentResult(resultCode, data)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CameraCapturer.PERMISSION_REQUEST) {
            cameraCapturer?.onPermissionResult(grantResults)
        }
    }
}

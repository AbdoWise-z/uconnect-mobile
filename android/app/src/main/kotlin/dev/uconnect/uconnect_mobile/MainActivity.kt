package dev.uconnect.uconnect_mobile

import android.Manifest
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Decodes a shared screen's H.264 into a Flutter texture.
        screenDecoder = ScreenDecoder(
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer,
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
    }
}

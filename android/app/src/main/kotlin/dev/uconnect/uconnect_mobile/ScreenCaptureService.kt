package dev.uconnect.uconnect_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

// A foreground service of type mediaProjection. Android 14+ requires such a
// service to be running before a MediaProjection is obtained; the capture and
// encoding themselves run in ScreenCapturer (same process), so this service
// only has to exist and carry the required type and a notice to the user that
// their screen is being shared.
class ScreenCaptureService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("uConnect")
            .setContentText("Sharing your screen")
            .setSmallIcon(R.drawable.ic_stat_uconnect)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // The projection may only be acquired once this foreground service is
        // running (Android 14+); signal the capturer that it is now safe.
        val cb = onForeground
        onForeground = null
        cb?.invoke()
        return START_NOT_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID, "Screen sharing",
                        NotificationManager.IMPORTANCE_LOW
                    ).apply { setShowBadge(false) }
                )
            }
        }
    }

    companion object {
        private const val CHANNEL_ID = "uconnect_screen_share"
        private const val NOTIFICATION_ID = 2

        // Invoked once the service is in the foreground, so the capturer can
        // safely acquire the MediaProjection.
        @Volatile
        var onForeground: (() -> Unit)? = null

        fun start(context: Context, onForeground: (() -> Unit)? = null) {
            this.onForeground = onForeground
            val intent = Intent(context, ScreenCaptureService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ScreenCaptureService::class.java))
        }
    }
}

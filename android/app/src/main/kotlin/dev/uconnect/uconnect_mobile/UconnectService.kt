package dev.uconnect.uconnect_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

// A minimal foreground service that keeps the app's process alive while a
// uConnect session is up. The session's networking runs on a native thread
// inside libuconnect_c.so; that thread keeps the encrypted link and its
// keepalives going as long as the process is not killed or frozen. A
// foreground service is what tells Android to leave the process running when
// the app is in the background.
//
// Started and stopped from Dart over the "uconnect/service" MethodChannel
// (see MainActivity): start when a session connects, stop when it ends.
class UconnectService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Connected"
        startForegroundCompat(text)
        // Sticky: if the system kills us under pressure, recreate the service
        // (Dart re-establishes the session on resume).
        return START_STICKY
    }

    // The user swiped the app out of recents. This foreground service is the
    // only thing keeping the process — and with it the native networking thread
    // in libuconnect_c.so — alive, so without this the node would keep its link
    // to the rendezvous server and linger as a ghost: other devices would still
    // see it, and the app would reconnect to its own old node on next launch.
    // Tear the service down and end the process so the server drops this node at
    // once (its socket closes), instead of after the freshness timeout.
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION") stopForeground(true)
        }
        stopSelf()
        android.os.Process.killProcess(android.os.Process.myPid())
    }

    private fun startForegroundCompat(text: String) {
        ensureChannel()
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("uConnect")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_uconnect)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID, "Running in the background",
                    NotificationManager.IMPORTANCE_LOW
                )
                channel.description =
                    "Lets uConnect stay connected to your devices while it is in the background."
                channel.setShowBadge(false)
                mgr.createNotificationChannel(channel)
            }
        }
    }

    companion object {
        private const val CHANNEL_ID = "uconnect_connection"
        private const val NOTIFICATION_ID = 1
        const val EXTRA_TEXT = "text"

        fun start(context: Context, text: String) {
            val intent = Intent(context, UconnectService::class.java)
                .putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, UconnectService::class.java))
        }
    }
}

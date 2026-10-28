package dev.uconnect.uconnect_mobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// What folder sync needs from the platform besides files:
//
//   "uconnect/power"         state() -> { wifi, charging }, where wifi means
//                            the active network is not metered (Wi-Fi,
//                            ethernet, an unmetered hotspot); and an
//                            EventChannel "uconnect/power/events" that sends
//                            the same map whenever either changes.
//   "uconnect/notify"        show(id, title, text) / cancel(id): a plain
//                            notification on its own channel, for sync
//                            problems the user should hear about.
//   "uconnect/storage" freeSpace(path) is in MainActivity.
class SyncPlatform(private val context: Context, messenger: BinaryMessenger) {
    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var powerReceiver: BroadcastReceiver? = null

    init {
        MethodChannel(messenger, "uconnect/power").setMethodCallHandler { call, result ->
            when (call.method) {
                "state" -> result.success(state())
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "uconnect/power/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    watch()
                }

                override fun onCancel(arguments: Any?) {
                    unwatch()
                    sink = null
                }
            })
        MethodChannel(messenger, "uconnect/notify").setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    show(
                        call.argument<Int>("id") ?: 0,
                        call.argument<String>("title") ?: "uConnect",
                        call.argument<String>("text") ?: "",
                    )
                    result.success(null)
                }
                "cancel" -> {
                    NotificationManagerCompat.from(context).cancel(call.argument<Int>("id") ?: 0)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun unmetered(): Boolean {
        val network = connectivity.activeNetwork ?: return false
        val caps = connectivity.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ||
            (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                !connectivity.isActiveNetworkMetered)
    }

    private fun charging(): Boolean {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: return false
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
    }

    private fun state(): Map<String, Any> = mapOf("wifi" to unmetered(), "charging" to charging())

    private fun push() {
        main.post { sink?.success(state()) }
    }

    private fun watch() {
        if (callback == null) {
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = push()
                override fun onLost(network: Network) = push()
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = push()
            }
            connectivity.registerDefaultNetworkCallback(cb)
            callback = cb
        }
        if (powerReceiver == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) = push()
            }
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_POWER_CONNECTED)
                addAction(Intent.ACTION_POWER_DISCONNECTED)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(receiver, filter)
            }
            powerReceiver = receiver
        }
    }

    private fun unwatch() {
        callback?.let { connectivity.unregisterNetworkCallback(it) }
        callback = null
        powerReceiver?.let { context.unregisterReceiver(it) }
        powerReceiver = null
    }

    private fun show(id: Int, title: String, text: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(CHANNEL_ID) == null
        ) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Folder sync", NotificationManager.IMPORTANCE_DEFAULT)
                    .apply { description = "Conflicts and other things folder sync needs you for" }
            )
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pending = PendingIntent.getActivity(
            context, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(id, notification)
        } catch (e: SecurityException) {
            // notifications not allowed: the app's own pages still show it
        }
    }

    companion object {
        const val CHANNEL_ID = "uconnect_sync"

        fun freeSpace(path: String): Long = try {
            StatFs(path).availableBytes
        } catch (e: IllegalArgumentException) {
            -1L
        }
    }
}

package xyz.purukitto.shinsoku

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Holds the process in the foreground while downloads run, so Android neither
 * freezes nor kills it in the background, and shows their progress as a silent
 * notification. Dart decides when it runs and what it says
 * (`lib/src/services/download_service.dart`).
 */
class DownloadService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(
            NOTIFICATION_ID,
            build(this, intent?.extras ?: Bundle()),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        running = true
        // after the system kills the process, the engine restores interrupted
        // downloads as paused, so there would be nothing to run
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    // Android 15 allows a data sync service six hours a day. Past that,
    // downloads carry on only while the app is open.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    companion object {
        private const val CHANNEL_ID = "downloads"
        private const val NOTIFICATION_ID = 1

        @Volatile
        private var running = false

        fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
            when (call.method) {
                "show" -> result.success(show(context, call.arguments as Map<*, *>))
                "stop" -> {
                    running = false
                    context.stopService(Intent(context, DownloadService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        /** Starts the service, or updates its notification. False if Android refused to start it. */
        private fun show(context: Context, args: Map<*, *>): Boolean {
            val extras = Bundle().apply {
                putString("title", args["title"] as String?)
                putString("text", args["text"] as String?)
                putInt("progress", (args["progress"] as Number?)?.toInt() ?: -1)
            }
            if (running) {
                context.getSystemService(NotificationManager::class.java)
                    .notify(NOTIFICATION_ID, build(context, extras))
                return true
            }
            return try {
                context.startForegroundService(Intent(context, DownloadService::class.java).putExtras(extras))
                true
            } catch (e: IllegalStateException) {
                // ForegroundServiceStartNotAllowedException: the app is in the background
                false
            }
        }

        private fun build(context: Context, extras: Bundle): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                // low importance: in the shade and the status bar, without sound or a pop-up
                val channel = NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW)
                channel.description = "Progress while files download"
                channel.setShowBadge(false)
                manager.createNotificationChannel(channel)
            }
            val open = PendingIntent.getActivity(
                context,
                0,
                context.packageManager.getLaunchIntentForPackage(context.packageName),
                PendingIntent.FLAG_IMMUTABLE,
            )
            val progress = extras.getInt("progress", -1)
            return Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(extras.getString("title"))
                .setContentText(extras.getString("text"))
                .setProgress(1000, progress.coerceAtLeast(0), progress < 0)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_PROGRESS)
                .apply {
                    // show it at once, not after the ten seconds Android otherwise waits
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                    }
                }
                .build()
        }
    }
}

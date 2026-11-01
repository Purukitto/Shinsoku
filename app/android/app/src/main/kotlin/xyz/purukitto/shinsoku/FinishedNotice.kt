package xyz.purukitto.shinsoku

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File

/**
 * Says that a download finished or failed. Dart decides what it says
 * (`lib/src/models/finish_notice.dart`). Tapping the notice for a finished
 * file opens it; any other opens the app.
 */
object FinishedNotice {
    private const val CHANNEL_ID = "finished"

    fun post(context: Context, args: Map<*, *>) {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            // default importance: a sound and a status bar icon, without a pop-up
            val channel = NotificationChannel(CHANNEL_ID, "Finished downloads", NotificationManager.IMPORTANCE_DEFAULT)
            channel.description = "When a download finishes or fails"
            manager.createNotificationChannel(channel)
        }
        val id = (args["id"] as Number).toInt()
        val text = args["text"] as String?
        val tap = (args["path"] as String?)?.let { view(context, it) }
            ?: context.packageManager.getLaunchIntentForPackage(context.packageName)
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(args["title"] as String?)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(
                PendingIntent.getActivity(
                    context,
                    id,
                    tap,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
            .setAutoCancel(true)
            .apply { if (args["failed"] == true) setCategory(Notification.CATEGORY_ERROR) }
            .build()
        manager.notify(id, notification)
    }

    /** Opens [path] in an app for its type; null when no app takes it. */
    private fun view(context: Context, path: String): Intent? {
        val file = File(path)
        val type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: return null
        val uri = try {
            FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        } catch (e: IllegalArgumentException) {
            // outside the folders the provider shares
            return null
        }
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, type)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        return intent.takeIf { it.resolveActivity(context.packageManager) != null }
    }
}

package xyz.purukitto.shinsoku

import android.Manifest
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.textclassifier.TextClassifier
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // The engine ShinsokuApplication started; it outlives this activity.
    override fun getCachedEngineId(): String = ShinsokuApplication.ENGINE_ID

    private var links: MethodChannel? = null

    // A link another app sent, until Dart takes it.
    private var pendingLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // Asking needs a window, so this channel lives only as long as one.
        MethodChannel(messenger, PERMISSIONS).setMethodCallHandler { call, result ->
            when (call.method) {
                "notifications" -> {
                    askForNotifications()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // Links arrive with this activity, and the clipboard can be read only
        // while it has focus.
        links = MethodChannel(messenger, LINKS).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "take" -> {
                        result.success(pendingLink)
                        pendingLink = null
                    }
                    "clip" -> result.success(clipInfo())
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERMISSIONS).setMethodCallHandler(null)
        links?.setMethodCallHandler(null)
        links = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Recreated after the process was killed, it would offer the same link again.
        if (savedInstanceState == null) receive(intent)
    }

    // singleTask: a link shared while Shinsoku is open comes to the running activity.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receive(intent)
    }

    private fun receive(intent: Intent?) {
        if (intent == null) return
        // reopened from Recents, which hands back the intent that first started it
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        val text = when (intent.action) {
            Intent.ACTION_SEND -> intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            Intent.ACTION_VIEW -> intent.dataString
            else -> null
        }
        if (text.isNullOrBlank()) return
        pendingLink = text
        links?.invokeMethod("ready", null)
    }

    // Describes the clip without reading it, which would show Android's
    // "pasted from your clipboard" notice for every check.
    private fun clipInfo(): Map<String, Any>? {
        val clip = getSystemService(ClipboardManager::class.java).primaryClipDescription ?: return null
        val noLink = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            clip.classificationStatus == ClipDescription.CLASSIFICATION_COMPLETE &&
            clip.getConfidenceScore(TextClassifier.TYPE_URL) == 0f
        return mapOf(
            "stamp" to clip.timestamp,
            "text" to clip.hasMimeType("text/*"),
            "noLink" to noLink,
        )
    }

    // Android 13 and later ask before an app may post notifications. Without
    // it downloads still run in the background; only the progress is hidden.
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
    }

    private companion object {
        const val PERMISSIONS = "shinsoku/permissions"
        const val LINKS = "shinsoku/links"
    }
}

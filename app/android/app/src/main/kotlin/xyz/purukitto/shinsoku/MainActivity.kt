package xyz.purukitto.shinsoku

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // The engine ShinsokuApplication started; it outlives this activity.
    override fun getCachedEngineId(): String = ShinsokuApplication.ENGINE_ID

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Asking needs a window, so this channel lives only as long as one.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERMISSIONS).setMethodCallHandler { call, result ->
            when (call.method) {
                "notifications" -> {
                    askForNotifications()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERMISSIONS).setMethodCallHandler(null)
        super.cleanUpFlutterEngine(flutterEngine)
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
    }
}

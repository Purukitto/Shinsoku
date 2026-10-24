package xyz.purukitto.shinsoku

import android.os.Environment
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shinsoku/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // The shared Download folder people see in their file manager.
                    // The engine writes by path, and this is the only API that
                    // returns it as one; since Android 11 the app may create files
                    // there without a storage permission.
                    "downloadsDir" -> {
                        @Suppress("DEPRECATION")
                        val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                        result.success(dir.absolutePath)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

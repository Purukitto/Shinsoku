package xyz.purukitto.shinsoku

import android.app.Application
import android.os.Environment
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Starts Flutter with the process instead of with the window. Dart, and the
 * Rust engine it holds, then keep running after the activity closes, for as
 * long as [DownloadService] keeps the process in the foreground.
 */
class ShinsokuApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        val messenger = engine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "shinsoku/storage").setMethodCallHandler { call, result ->
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
        MethodChannel(messenger, "shinsoku/downloads").setMethodCallHandler { call, result ->
            DownloadService.handle(this, call, result)
        }

        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    companion object {
        const val ENGINE_ID = "main"
    }
}

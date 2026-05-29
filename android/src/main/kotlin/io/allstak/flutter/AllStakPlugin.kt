package io.allstak.flutter

/*
 * Flutter Android crash capture plugin.
 *
 * SCAFFOLDED: this file targets the standard Flutter FlutterPlugin API
 * (androidx + Flutter 3.x). It requires the containing Flutter package
 * to declare it as a plugin in `pubspec.yaml` (android: { package: ...,
 * pluginClass: AllStakPlugin }) and a real Android Gradle build to
 * verify end-to-end on device/emulator.
 */

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

class AllStakPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "install" -> {
                val release = call.argument<String?>("release")
                install(appContext, release)
                // Async-signal-safe NDK signal handlers (gated, default on).
                // Degrades gracefully: if liballstak_crash.so isn't bundled
                // (the consuming app didn't opt into the NDK build) this is a
                // silent no-op and the SDK keeps working.
                val enableSignals =
                    call.argument<Boolean?>("enableSignalHandlers") ?: true
                if (enableSignals) {
                    installSignalHandlers(appContext)
                }
                result.success(true)
            }
            "drainPendingCrash" -> {
                val prefs = prefs(appContext)
                val json = prefs.getString(PREFS_KEY, null)
                prefs.edit().remove(PREFS_KEY).commit()
                result.success(json)
            }
            "drainPendingSignalCrash" -> {
                // Read + remove the async-signal-safe NDK record from the
                // previous launch. Fail-open: missing file/IO error -> null.
                result.success(drainSignalCrash(appContext))
            }
            "spoolDir" -> {
                // Persistent, sandboxed directory for the offline telemetry
                // spool. filesDir is app-private internal storage that
                // survives app restarts (cleared only on uninstall).
                result.success(appContext.filesDir?.absolutePath)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        private const val CHANNEL = "io.allstak.flutter/native"
        private const val PREFS_NAME = "allstak_flutter_crashes"
        private const val PREFS_KEY = "pending_crash"

        // Fixed filename of the async-signal-safe NDK crash record under filesDir.
        private const val SIGNAL_CRASH_FILE = "allstak_signal_crash.bin"

        // True once liballstak_crash.so loaded successfully. When the consuming
        // app did not opt into the NDK build, the lib is absent: loading throws
        // UnsatisfiedLinkError and native signal capture degrades to a no-op.
        @Volatile
        private var nativeLibLoaded = false

        private val nativeLibLoadAttempted = java.util.concurrent.atomic.AtomicBoolean(false)

        // JNI: arm the async-signal-safe signal handlers, writing crash records
        // to [path]. Called in NORMAL context (app start) — never from a handler.
        @JvmStatic
        private external fun nativeInstallSignalHandlers(path: String): Boolean

        private fun ensureNativeLib() {
            if (nativeLibLoadAttempted.getAndSet(true)) return
            try {
                System.loadLibrary("allstak_crash")
                nativeLibLoaded = true
            } catch (_: Throwable) {
                // UnsatisfiedLinkError / SecurityException — the NDK lib was not
                // bundled (app opted out of the native build). Fail-open: signal
                // capture is a no-op; the rest of the SDK is unaffected.
                nativeLibLoaded = false
            }
        }

        private fun signalCrashFile(ctx: Context): File =
            File(ctx.applicationContext.filesDir, SIGNAL_CRASH_FILE)

        fun installSignalHandlers(ctx: Context) {
            try {
                ensureNativeLib()
                if (!nativeLibLoaded) return
                val path = signalCrashFile(ctx).absolutePath
                nativeInstallSignalHandlers(path)
            } catch (_: Throwable) {
                // Never let native arming break startup.
            }
        }

        fun drainSignalCrash(ctx: Context): String? {
            return try {
                val file = signalCrashFile(ctx)
                if (!file.exists()) return null
                val contents = file.readText(Charsets.UTF_8)
                file.delete()
                if (contents.isEmpty()) null else contents
            } catch (_: Throwable) {
                null
            }
        }

        private fun prefs(ctx: Context): SharedPreferences =
            ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        fun install(ctx: Context, release: String?) {
            val appCtx = ctx.applicationContext
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
                try {
                    val sw = StringWriter()
                    throwable.printStackTrace(PrintWriter(sw))
                    val stack = JSONArray()
                    for (line in sw.toString().split("\n")) {
                        val trimmed = line.trim()
                        if (trimmed.isNotEmpty()) stack.put(trimmed)
                    }

                    val metadata = JSONObject().apply {
                        put("platform", "flutter")
                        put("device.os", "android")
                        put("device.osVersion", Build.VERSION.SDK_INT.toString())
                        put("device.model", Build.MODEL ?: "")
                        put("device.manufacturer", Build.MANUFACTURER ?: "")
                        put("fatal", "true")
                        put("source", "android-UncaughtExceptionHandler")
                    }

                    val payload = JSONObject().apply {
                        put("exceptionClass", throwable.javaClass.simpleName)
                        put("message", throwable.message ?: throwable.toString())
                        put("stackTrace", stack)
                        put("level", "fatal")
                        if (release != null) put("release", release)
                        put("metadata", metadata)
                    }

                    prefs(appCtx).edit()
                        .putString(PREFS_KEY, payload.toString())
                        .commit()
                } catch (_: Throwable) { /* never rethrow */ }

                previous?.uncaughtException(thread, throwable)
            }
        }
    }
}

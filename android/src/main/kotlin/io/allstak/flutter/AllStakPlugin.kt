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
                result.success(true)
            }
            "drainPendingCrash" -> {
                val prefs = prefs(appContext)
                val json = prefs.getString(PREFS_KEY, null)
                prefs.edit().remove(PREFS_KEY).commit()
                result.success(json)
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

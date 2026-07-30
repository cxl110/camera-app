package com.zivigo.cameraapp

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// System utility plugin — opens WiFi settings etc.
///
/// Method channel: "com.cameraapp/system"
class SystemPlugin : MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var activity: MainActivity? = null

    companion object {
        private const val CHANNEL = "com.cameraapp/system"

        fun register(activity: MainActivity, engine: FlutterEngine) {
            val plugin = SystemPlugin()
            plugin.activity = activity
            plugin.channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            plugin.channel?.setMethodCallHandler(plugin)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openWiFiSettings" -> {
                try {
                    val intent = Intent(Settings.ACTION_WIFI_SETTINGS)
                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    activity?.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("OPEN_FAILED", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }
}

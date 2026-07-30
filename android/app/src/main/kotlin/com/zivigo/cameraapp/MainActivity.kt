package com.zivigo.cameraapp

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register native plugins (Android equivalents of iOS CoreMLPlugin + VideoTranscoder)
        CoreMLPlugin.register(this, flutterEngine)
        VideoTranscoderPlugin.register(this, flutterEngine)
        SystemPlugin.register(this, flutterEngine)
    }
}

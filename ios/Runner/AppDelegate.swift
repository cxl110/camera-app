import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register CoreMLPlugin
    let controller = window?.rootViewController as! FlutterViewController
    CoreMLPlugin.register(with: controller.registrar(forPlugin: "CoreMLPlugin")!)

    // Register VideoTranscoderPlugin (AVI→MP4 native transcoder)
    VideoTranscoderPlugin.register(with: controller.registrar(forPlugin: "VideoTranscoderPlugin")!)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Do NOT register plugins here — in SceneDelegate mode the Flutter engine
    // is not yet ready. All registration happens in didInitializeImplicitFlutterEngine.
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Register ALL plugins (Flutter auto-generated + our custom native plugins)
    // after the Flutter engine is fully initialized.
    GeneratedPluginRegistrant.register(with: self)

    if let coreMLRegistrar = self.registrar(forPlugin: "CoreMLPlugin") {
      CoreMLPlugin.register(with: coreMLRegistrar)
    }
    if let videoRegistrar = self.registrar(forPlugin: "VideoTranscoderPlugin") {
      VideoTranscoderPlugin.register(with: videoRegistrar)
    }
  }
}

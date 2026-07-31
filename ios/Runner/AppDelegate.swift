import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Storyboard + implicit-engine lifecycle: do NOT register plugins here.
    // Accessing the FlutterViewController this early can crash. Plugin
    // registration happens in `didInitializeImplicitFlutterEngine(_:)`, which
    // Flutter calls once the implicit engine is initialized — the official
    // hook for this lifecycle (see FlutterEngine.h `FlutterImplicitEngineDelegate`).
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - FlutterImplicitEngineDelegate

  /// Called once the implicit `FlutterEngine` is initialized (e.g. by a
  /// `FlutterViewController` instantiated from Main.storyboard). The bridge's
  /// `pluginRegistry` is bound to this engine's binary messenger, so plugins
  /// registered here attach their channels to the *correct* engine — this is
  /// why `gal` / `shared_preferences_foundation` were throwing
  /// `MissingPluginException` before (they were registered against the wrong
  /// engine, or not at all).
  func didInitializeImplicitFlutterEngine(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    // 1. All auto-generated Flutter plugins (gal, shared_preferences_foundation,
    //    connectivity_plus, share_plus, path_provider, ...).
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 2. App's custom native plugins.
    if let coreMLRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "CoreMLPlugin") {
      CoreMLPlugin.register(with: coreMLRegistrar)
    }
    if let videoRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "VideoTranscoderPlugin") {
      VideoTranscoderPlugin.register(with: videoRegistrar)
    }
  }
}

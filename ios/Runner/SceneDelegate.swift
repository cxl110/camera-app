import Flutter
import UIKit

/// Scene-based lifecycle. Plugin registration is handled by
/// `CameraFlutterViewController.viewDidLoad` (the storyboard root view
/// controller), where the implicit engine is guaranteed to exist. Do not
/// register plugins here — doing so at `scene(_:willConnectTo:)` time is too
/// early (engine not yet created) and abort()s inside a plugin's
/// `registerWithRegistrar:`.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // Default Flutter scene setup — this instantiates the window and loads the
    // root FlutterViewController from Main.storyboard, which triggers
    // viewDidLoad → plugin registration.
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}

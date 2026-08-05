import {
  BinaryMessenger,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';

/**
 * App-level platform channel stubs for HarmonyOS.
 *
 * The app has 3 custom native channels (iOS: Swift, Android: Kotlin) that are
 * not implemented on ohos yet:
 *   - com.cameraapp/coreml  (AI neural filters, 7 methods)
 *   - com.cameraapp/video   (AVI -> MP4 transcoding, 1 method)
 *   - com.cameraapp/system  (open WiFi settings, 1 method)
 *
 * The Dart bridges all guard with try/catch MissingPluginException, so the
 * app runs fine without native handlers. This stub explicitly reports
 * "isAvailable" = false for coreml (graceful feature disable) and
 * notImplemented elsewhere (MissingPluginException on the Dart side).
 */
const TAG = "AppChannelStubs";

const SYSTEM_CHANNEL = "com.cameraapp/system";
const COREML_CHANNEL = "com.cameraapp/coreml";
const VIDEO_CHANNEL = "com.cameraapp/video";

const methodCallHandler: MethodCallHandler = {
  onMethodCall(call: MethodCall, result: MethodResult) {
    if (call.method === "isAvailable") {
      // Neural filter inference is not available on ohos yet — tell the
      // Dart side so the UI disables filter features gracefully.
      result.success(false);
      return;
    }
    result.notImplemented();
  }
};

export default class AppChannelStubs implements FlutterPlugin {
  private channels: MethodChannel[] = [];

  getUniqueClassName(): string {
    return TAG;
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.registerChannel(binding.getBinaryMessenger(), SYSTEM_CHANNEL);
    this.registerChannel(binding.getBinaryMessenger(), COREML_CHANNEL);
    this.registerChannel(binding.getBinaryMessenger(), VIDEO_CHANNEL);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    for (const channel of this.channels) {
      channel.setMethodCallHandler(null);
    }
    this.channels = [];
  }

  private registerChannel(messenger: BinaryMessenger, name: string): void {
    const channel = new MethodChannel(messenger, name);
    channel.setMethodCallHandler(methodCallHandler);
    this.channels.push(channel);
  }
}

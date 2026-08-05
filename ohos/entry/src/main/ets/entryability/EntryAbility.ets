
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import AppChannelStubs from '../plugins/AppChannelStubs';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // App custom channels (stubs for now — native impl in later phases)
    flutterEngine.getPlugins()?.add(new AppChannelStubs());
  }
}

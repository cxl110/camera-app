# TFLite / TFLite GPU delegate
# The GPU delegate references some optional classes (e.g. GpuDelegateFactory
# inner classes for selecting a backend) that may be absent depending on the
# device/ABI. R8 fails the release build if it sees these references, so tell
# it not to warn — the delegate falls back gracefully at runtime.
-dontwarn org.tensorflow.lite.gpu.**
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options$GpuBackend

# Keep the public GPU/NNAPI delegate entry points and the Interpreter, since
# they are loaded reflectively by the app.
-keep class org.tensorflow.lite.gpu.GpuDelegate { *; }
-keep class org.tensorflow.lite.gpu.GpuDelegateFactory$Options { *; }
-keep class org.tensorflow.lite.nnapi.NnApiDelegate { *; }
-keep class org.tensorflow.lite.Interpreter { *; }

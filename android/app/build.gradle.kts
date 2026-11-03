import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 上传签名（Google Play App Signing 的 upload key）。
// key.properties 与 .jks 都不入库，见 .gitignore；缺失时回退到 debug 签名，
// 这样没有密钥的机器（CI、别人的电脑）依然能跑 flutter run --release。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.zivigo.cameraapp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.zivigo.cameraapp"
        // minSdk 24: TFLite GPU delegate + NNAPI delegate 硬件加速要求
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    // .tflite 模型文件不压缩，保证 TFLite 可内存映射加载
    androidResources {
        noCompress += "tflite"
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // R8 shrinks the release build by default. TFLite's GPU delegate
            // references optional classes that aren't on every ABI; without
            // these keep rules R8 fails minifyReleaseWithR8. See
            // proguard-rules.pro for the full set.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

            // Google Play 只需要真机 ABI：
            // - x86_64 只有模拟器/ChromeOS 用，而且 2.17.0 的 TFLite x86_64 预编译库
            //   仍是 4 KB 页对齐，留着会被判 16 KB 不合规
            // - armeabi-v7a 保留（32 位设备不走 16 KB 页，不受该政策约束）
            ndk {
                abiFilters.clear()
                abiFilters += listOf("arm64-v8a", "armeabi-v7a")
            }
        }
    }

    // ndk.abiFilters 只影响 Flutter 自己编的 .so，AAR 里带的预编译库（TFLite）
    // 依然会按 AAR 的 ABI 打包进来，所以上架包还得在 packaging 里排掉 x86_64。
    // 用环境变量开关：日常 flutter run 到 x86_64 模拟器时需要 TFLite 的 x86_64 库，
    // 只有 scripts/build_play_bundle.ps1 才设置 PLAY_BUNDLE=1。
    packaging {
        if (System.getenv("PLAY_BUNDLE") == "1") {
            jniLibs {
                excludes += listOf("lib/x86_64/**")
            }
        }
    }
}

// TFLite 硬件加速依赖（GPU delegate + NNAPI delegate）
//
// 版本不能低于 2.17：Google Play 从 2025-11 起要求 targetSdk 35+ 的应用支持
// 16 KB 内存页，而 2.16.x 的 libtensorflowlite_jni.so 只按 4 KB 对齐
// （p_align = 0x1000），上传会被判不合规。scripts/inspect_play_readiness.py
// 会把每个 .so 的 p_align 打出来，改完版本务必跑一遍。
dependencies {
    implementation("org.tensorflow:tensorflow-lite:2.17.0")
    implementation("org.tensorflow:tensorflow-lite-gpu:2.17.0")
    // tensorflow-lite-support 已移除：CoreMLPlugin.kt 只用 Interpreter / GpuDelegate /
    // NnApiDelegate，没有用到 support 库；而它会把 tensorflow-lite-api:2.13.0 拖进来，
    // 与 2.17.0 自带的 com.google.ai.edge.litert:litert-api 撞出重复类。
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

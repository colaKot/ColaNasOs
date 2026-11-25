plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 单 ABI 打包开关：`-PnasAbi=arm64-v8a`（默认，约 40MB）/ `armeabi-v7a` / `universal`
// 默认保持 arm64-v8a，与「日常打安卓包 = V8 小包」的口径一致；
// 只有发 GitHub release 才需要 universal（含 V7 + V8）与 V8 两个包。
val nasAbi = (project.findProperty("nasAbi") as String?)?.trim().orEmpty()
    .ifEmpty { "arm64-v8a" }
val nasAllAbis = listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
val nasAbiFilters = if (nasAbi == "universal") {
    listOf("arm64-v8a", "armeabi-v7a")
} else {
    listOf(nasAbi)
}

// 端形态开关：`-PnasApp=photo` 出「相册独立端」（`build-photo.bat` 传），
// 不传就是主客户端。同一个工程、同一套原生能力，只换 applicationId 与桌面名称 ——
// 相册端要单独装、单独更新，包名必须与主客户端不同，否则会互相覆盖安装。
// 版本号仍与主客户端共用 pubspec 的 `X.Y.Z+B`（相册版本 = 主 app 版本）。
val nasApp = (project.findProperty("nasApp") as String?)?.trim().orEmpty()
val nasIsPhoto = nasApp == "photo"
val nasAppId = if (nasIsPhoto) "com.colanas.photo" else "com.colanas.os"
val nasAppLabel = if (nasIsPhoto) "ColaNas 相册" else "ColaNasOs 客户端"

android {
    namespace = "com.colanas.os"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 主客户端 `com.colanas.os`；相册端 `com.colanas.photo`（见上面的 nasApp）
        applicationId = nasAppId
        // 桌面名称随端形态变化（清单里写 `${appLabel}`）
        manifestPlaceholders["appLabel"] = nasAppLabel
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // media_kit 的 libmpv 每个 ABI 约 15MB，全打进去 APK 直接 68MB。
        // 手机端只需要 arm64-v8a（arm64 设备能跑 32 位包，反过来不行）。
        // 要出通用包时用 -PnasAbi=universal 重新构建，不要手改这里。
        ndk {
            abiFilters += nasAbiFilters
        }
    }

    packaging {
        jniLibs {
            // abiFilters 只管 jniLibs 源集和 externalNativeBuild 产物，
            // media_kit 的 so 是塞在 jar 的 lib/<abi>/ 里，只能按路径排掉。
            excludes += nasAllAbis
                .filter { it !in nasAbiFilters }
                .map { "**/$it/**" }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // 客户端自更新：FileProvider 把下载好的 APK 以 content:// 交给系统安装器
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.media3:media3-exoplayer:1.10.0")
    implementation("androidx.media3:media3-exoplayer-hls:1.10.0")
    implementation("androidx.media3:media3-ui:1.10.0")
    // 视频媒体会话：状态栏 / 通知栏的标题、暂停继续，以及播放时的音频焦点抢占
    implementation("androidx.media3:media3-session:1.10.0")
    // 音乐 / 播客媒体面板：MediaSessionCompat + MediaStyle 通知
    implementation("androidx.media:media:1.7.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

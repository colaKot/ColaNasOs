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

android {
    namespace = "com.colanas.os"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.colanas.os"
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

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

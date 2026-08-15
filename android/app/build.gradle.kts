plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名：CI（或本地）通过环境变量注入密钥；未注入时回退 debug 签名，
// 保证 `flutter run` / 本地无密钥构建不受影响。密钥在 GitHub Secrets，
// 本地副本 ~/.keystores/zcode-remote-client/。
val ksPath = System.getenv("KEYSTORE_PATH")
val ksPassword = System.getenv("KEYSTORE_PASSWORD")

android {
    namespace = "com.charlotte.zcode_remote_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.charlotte.zcode_remote_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (ksPath != null && ksPassword != null) {
                storeFile = file(ksPath)
                storePassword = ksPassword
                keyAlias = System.getenv("KEY_ALIAS") ?: "zcode"
                keyPassword = ksPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (ksPath != null && ksPassword != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.ble_proximity_bridge"
    // permission_handler 13 (permission_handler_android 14) requires compileSdk 37;
    // Flutter's default is still 36. Keep this at least as high as flutter.compileSdkVersion.
    compileSdk = maxOf(37, flutter.compileSdkVersion)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.ble_proximity_bridge"
        // Herald supports API 21+, so Flutter's default minimum (currently 24)
        // is the binding floor.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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

dependencies {
    // Herald handles BLE scanning, advertising, and payload exchange.
    // https://heraldprox.io — Apache 2.0, fetched from Maven Central.
    implementation("io.heraldprox:herald:2.2.0")
}

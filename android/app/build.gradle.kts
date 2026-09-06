import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.firebase-perf")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val requiredKeystoreProperties = listOf("keyAlias", "keyPassword", "storeFile", "storePassword")
val missingKeystoreProperties = if (keystorePropertiesFile.exists()) {
    requiredKeystoreProperties.filter { name ->
        keystoreProperties.getProperty(name)?.trim().isNullOrEmpty()
    }
} else {
    requiredKeystoreProperties
}
val releaseSigningConfigured =
    keystorePropertiesFile.exists() && missingKeystoreProperties.isEmpty()

android {
    namespace = "com.tiltastech.castcircle"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.tiltastech.castcircle"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (releaseSigningConfigured) {
                keyAlias = keystoreProperties.getProperty("keyAlias").trim()
                keyPassword = keystoreProperties.getProperty("keyPassword").trim()
                storeFile = file(keystoreProperties.getProperty("storeFile").trim())
                storePassword = keystoreProperties.getProperty("storePassword").trim()
            }
        }
    }

    buildTypes {
        release {
            // Keep debug-only Gradle configuration usable without signing
            // secrets. The task-graph guard below fails only release work.
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

gradle.taskGraph.whenReady {
    val releaseRequested = allTasks.any { task ->
        task.project == project && task.name.contains("release", ignoreCase = true)
    }
    if (releaseRequested && !releaseSigningConfigured) {
        val detail = if (!keystorePropertiesFile.exists()) {
            "android/key.properties is missing"
        } else {
            "android/key.properties is missing required properties: " +
                missingKeystoreProperties.joinToString()
        }
        throw GradleException(
            "$detail — release builds must be signed with the release keystore " +
                "(see docs/RELEASING.md)."
        )
    }
}

flutter {
    source = "../.."
}

dependencies {
    // ONNX Runtime Java bindings for PaddleOcrPlugin.kt — VENDORED, not the
    // Maven AAR: the AAR bundles its own libonnxruntime.so (1.22.0) which
    // collides with sherpa-onnx's newer bundled copy (1.27.0), and the jniLibs
    // merge can pick the wrong one (sherpa's JNI needs C-API v27; the 1.22 lib
    // would kill live matching + TTS at runtime). So we ship only the AAR's
    // classes.jar + per-ABI libonnxruntime4j_jni.so (app-source jniLibs) and
    // let sherpa's libonnxruntime.so be the ONLY C runtime — the 1.22 Java
    // bridge runs on it via ORT's versioned C API. Regenerate with
    // scripts/fetch-ort-java.sh; scripts/verify-apk-ort.sh checks the APK.
    implementation(files("libs/onnxruntime-java-1.22.0.jar"))
}

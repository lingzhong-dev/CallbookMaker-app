import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Read release signing config from android/key.properties if it exists.
val keystorePropertiesFile = rootProject.file("key.properties")
val releaseKey = if (keystorePropertiesFile.exists()) {
    Properties().apply { keystorePropertiesFile.reader(Charsets.UTF_8).use { load(it) } }
} else {
    null
}

android {
    namespace = "com.livecall.studio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.livecall.studio"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        releaseKey?.let { properties ->
            create("release") {
                fun required(name: String) = requireNotNull(properties.getProperty(name)?.takeIf { it.isNotEmpty() }) {
                    "Missing $name in android/key.properties"
                }
                storeFile = file(required("storeFile"))
                storePassword = required("storePassword")
                keyAlias = required("keyAlias")
                keyPassword = required("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Keep debug signing for local builds without a keystore, not for the release job.
            check(releaseKey != null || System.getenv("REQUIRE_RELEASE_SIGNING") != "true") {
                "GitHub Actions release builds require android/key.properties"
            }
            signingConfig = signingConfigs.getByName(if (releaseKey != null) "release" else "debug")
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

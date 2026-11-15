import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The phone app ships with the plugin's version (ds-bot/package.json). Android only
// installs an update with a higher versionCode, and a pre-release stays below its
// release: ((major * 1000 + minor) * 1000 + patch) * 100 + (rc number, or 99).
val dsBotVersion: String = run {
    val manifest = rootProject.file("../../ds-bot/package.json")
    @Suppress("UNCHECKED_CAST")
    ((JsonSlurper().parse(manifest) as Map<String, Any>)["version"] as String)
}

fun versionCodeOf(version: String): Int {
    val match = Regex("""^(\d+)\.(\d+)\.(\d+)(?:-[a-z]+\.(\d+))?$""").matchEntire(version)
        ?: throw GradleException("Cannot derive an Android versionCode from version $version")
    val (major, minor, patch, pre) = match.destructured
    if (minor.toInt() > 999 || patch.toInt() > 999 || (pre.isNotEmpty() && pre.toInt() > 98)) {
        throw GradleException("Version $version is out of the versionCode range")
    }
    val release = (major.toInt() * 1000 + minor.toInt()) * 1000 + patch.toInt()
    return release * 100 + (if (pre.isEmpty()) 99 else pre.toInt())
}

// Release builds are signed with the upload key named by these variables; without
// them the release falls back to the debug key, for local checks only.
val keystorePath: String? = System.getenv("DSBOT_ANDROID_KEYSTORE")

android {
    namespace = "io.github.cikeseven.dsbot_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time on older Android versions.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // A separate id from the Expo app, so both can be installed side by side.
        applicationId = "io.github.cikeseven.dsbot"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = versionCodeOf(dsBotVersion)
        versionName = dsBotVersion
    }

    signingConfigs {
        getByName("debug") {
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
        create("release") {
            if (keystorePath != null) {
                storeFile = file(keystorePath)
                storePassword = System.getenv("DSBOT_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("DSBOT_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("DSBOT_ANDROID_KEY_PASSWORD") ?: System.getenv("DSBOT_ANDROID_KEYSTORE_PASSWORD")
            }
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    buildTypes {
        release {
            if (keystorePath == null) {
                logger.warn("DSBOT_ANDROID_KEYSTORE is not set: this release APK is signed with the debug key.")
            }
            signingConfig = signingConfigs.getByName(if (keystorePath != null) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("androidx.appcompat:appcompat:1.7.1")
}

flutter {
    source = "../.."
}

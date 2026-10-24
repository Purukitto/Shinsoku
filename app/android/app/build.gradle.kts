import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Where buildRustEngine (below) puts libshinsoku_core.so for each ABI.
val rustJniLibs: File = layout.buildDirectory.dir("rustJniLibs").get().asFile

// The release key: android/key.properties when building by hand, or the SHINSOKU_*
// variables in the release workflow. Without either, release builds are signed with
// the debug key, so `flutter run --release` still works.
val keyProperties =
    Properties().apply {
        rootProject.file("key.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
    }

fun signingValue(property: String, env: String): String? = keyProperties.getProperty(property) ?: System.getenv(env)

val releaseKeystore: String? = signingValue("storeFile", "SHINSOKU_KEYSTORE")

android {
    namespace = "xyz.purukitto.shinsoku"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "xyz.purukitto.shinsoku"
        // Android 11: apps write to the shared Download folder by path without a
        // storage permission.
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = signingValue("storePassword", "SHINSOKU_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "SHINSOKU_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "SHINSOKU_KEY_PASSWORD")
            }
        }
    }

    // Where a build is published; docs/decisions.md, "Store builds", has why.
    // Android builds name one: --flavor foss or --flavor play.
    //   foss: GitHub releases, F-Droid and builds from source, with no Google code.
    //   play: Google Play, which updates the app itself. Play Billing goes only here.
    flavorDimensions += "store"
    productFlavors {
        create("foss") { dimension = "store" }
        create("play") { dimension = "store" }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    sourceSets["main"].jniLibs.srcDir(rustJniLibs)
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Build the Rust engine (shinsoku_core) with cargo-ndk and package it as
// libshinsoku_core.so, as the Windows build bundles the dll.

// `flutter run` passes the device's platform; `flutter build apk` passes them all.
val rustAbis: List<String> =
    (findProperty("target-platform") as String? ?: "android-arm,android-arm64,android-x64")
        .split(",")
        .mapNotNull {
            mapOf(
                "android-arm" to "armeabi-v7a",
                "android-arm64" to "arm64-v8a",
                "android-x64" to "x86_64",
            )[it.trim()]
        }

val cargo: String =
    listOfNotNull(System.getenv("CARGO_HOME"), "${System.getProperty("user.home")}/.cargo")
        .map { file("$it/bin/cargo" + if (System.getProperty("os.name").startsWith("Windows")) ".exe" else "") }
        .firstOrNull { it.exists() }
        ?.absolutePath ?: "cargo"

val buildRustEngine =
    tasks.register<Exec>("buildRustEngine") {
        description = "Builds shinsoku_core for each Android ABI"
        workingDir = rootProject.file("../../core")
        environment("ANDROID_NDK_HOME", android.ndkDirectory.absolutePath)
        commandLine(
            listOf(cargo, "ndk") +
                rustAbis.flatMap { listOf("-t", it) } +
                listOf("-P", "${android.defaultConfig.minSdk}") +
                listOf("-o", rustJniLibs.absolutePath, "build", "--release"),
        )
        // drop libraries for ABIs this build doesn't ask for
        doFirst { delete(rustJniLibs) }
    }

tasks.named("preBuild") { dependsOn(buildRustEngine) }

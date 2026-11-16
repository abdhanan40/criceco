import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- Release signing ----------------------------------------------------------
// The release keystore and its passwords live OUTSIDE the repository, in a
// key.properties file (storeFile, storePassword, keyAlias, keyPassword), found at:
//   1. the path in the CRICECO_SIGNING_PROPERTIES environment variable, else
//   2. the Gradle property -PcricecoSigningProperties=<path>, else
//   3. <user home>/CricEco-Backups/android-signing/key.properties.
// No secret is written in this file. Without a complete key.properties and its
// keystore, a release build stops with an error — it never falls back to the
// debug key. Debug builds are unaffected.
val releaseSigningFile: File = file(
    System.getenv("CRICECO_SIGNING_PROPERTIES")
        ?: (findProperty("cricecoSigningProperties") as String?)
        ?: "${System.getProperty("user.home")}/CricEco-Backups/android-signing/key.properties",
)
val releaseSigning = Properties().apply {
    if (releaseSigningFile.isFile) FileInputStream(releaseSigningFile).use { load(it) }
}
val releaseSigningKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val releaseSigningProblem: String? = run {
    val missing = releaseSigningKeys.filter { releaseSigning.getProperty(it).isNullOrBlank() }
    when {
        !releaseSigningFile.isFile -> "signing properties file not found: $releaseSigningFile"
        missing.isNotEmpty() -> "$releaseSigningFile is missing: ${missing.joinToString()}"
        !file(releaseSigning.getProperty("storeFile")).isFile ->
            "keystore not found: ${releaseSigning.getProperty("storeFile")}"
        else -> null
    }
}

android {
    namespace = "com.criceco.criceco"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.criceco.criceco"
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
    }

    signingConfigs {
        // Filled only from the external key.properties (see above). The debug
        // signing config is Android's default and is left unchanged.
        create("release") {
            if (releaseSigningProblem == null) {
                val store = releaseSigning.getProperty("storeFile")
                storeFile = file(store)
                storePassword = releaseSigning.getProperty("storePassword")
                keyAlias = releaseSigning.getProperty("keyAlias")
                keyPassword = releaseSigning.getProperty("keyPassword")
                storeType = releaseSigning.getProperty("storeType")
                    ?: if (store.endsWith(".p12", true) || store.endsWith(".pfx", true)) "pkcs12" else null
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// Fail safely: a release build (APK or app bundle) without the real release
// key stops here instead of producing an unsigned or debug-signed app.
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    doFirst {
        releaseSigningProblem?.let {
            throw GradleException("CricEco release signing is not configured — $it")
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

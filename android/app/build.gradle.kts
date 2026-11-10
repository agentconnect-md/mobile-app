plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Server hosts come from the same file as iOS (ios/Flutter/Environment.xcconfig,
// plus the optional git-ignored Environment.local.xcconfig), so they live in one place.
fun readXcconfig(): Map<String, String> {
    val out = mutableMapOf<String, String>()
    for (name in listOf("Environment.xcconfig", "Environment.local.xcconfig")) {
        val f = rootProject.file("../ios/Flutter/$name")
        if (!f.exists()) continue
        f.readLines().forEach { raw ->
            val line = raw.substringBefore("//").trim()
            if (line.isEmpty() || line.startsWith("#")) return@forEach
            val i = line.indexOf('=')
            if (i > 0) out[line.substring(0, i).trim()] = line.substring(i + 1).trim()
        }
    }
    return out
}
val acEnv = readXcconfig()
fun ac(key: String, fallback: String) = acEnv[key]?.takeIf { it.isNotEmpty() } ?: fallback

android {
    namespace = "com.yulong.agentconnect"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.yulong.agentconnect"
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

        val apiHost = ac("AC_API_HOST", "api.example.test")
        resValue("string", "ac_env_name", ac("AC_ENV_NAME", "Test"))
        resValue("string", "ac_api_base", "https://" + apiHost + ac("AC_API_PATH", "/v1"))
        resValue("string", "ac_callback_host", ac("AC_CALLBACK_HOST", "console.example.test"))
        resValue("string", "ac_callback_path", ac("AC_CALLBACK_PATH", "/mobile/oauth/callback"))
        resValue("string", "ac_url_scheme", ac("AC_URL_SCHEME", "agentconnect-test"))
        manifestPlaceholders["acUrlScheme"] = ac("AC_URL_SCHEME", "agentconnect-test")
        manifestPlaceholders["acCallbackHost"] = ac("AC_CALLBACK_HOST", "console.example.test")
    }

    buildFeatures {
        resValues = true
    }

    // Release signing from the environment (CI secrets). Without them a release
    // build is signed with the debug key, so `flutter run --release` still works.
    val keystorePath = System.getenv("AC_ANDROID_KEYSTORE")
    signingConfigs {
        if (!keystorePath.isNullOrEmpty()) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("AC_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("AC_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("AC_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (!keystorePath.isNullOrEmpty()) {
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

dependencies {
    // Custom Tabs for the sign-in page (shares the browser's console session).
    implementation("androidx.browser:browser:1.8.0")
}

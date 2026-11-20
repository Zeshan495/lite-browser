plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing comes from environment variables set by GitHub Actions (see docs/PUBLISHING.md).
// Without them the APK is signed with the debug key, which still installs fine.
val keystorePath: String? = System.getenv("ANDROID_KEYSTORE_PATH")

android {
    namespace = "dev.litebrowser"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.litebrowser"
        minSdk = 24
        targetSdk = 35
        versionCode = (System.getenv("VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("VERSION_NAME") ?: "1.0.0"
    }

    signingConfigs {
        if (keystorePath != null) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = if (keystorePath != null) signingConfigs.getByName("release")
                            else signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

// The home page is shared with the Mac app: copy it from ../../Resources at build time.
val webAssets = layout.buildDirectory.dir("generated/webassets")
val syncWebAssets by tasks.registering(Copy::class) {
    from(rootProject.file("../Resources")) { include("home.html", "AppIcon.png") }
    into(webAssets)
}
android.sourceSets["main"].assets.srcDir(webAssets)
tasks.named("preBuild") { dependsOn(syncWebAssets) }

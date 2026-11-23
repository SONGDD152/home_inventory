plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.songdd.homeinventory.home_inventory"
    // 显式固定 36：与已发版包（platformBuildVersionCode=36）对齐。
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        create("release") {
            // 正式签名：密码与路径一律从用户级 ~/.gradle/gradle.properties 读取
            // （权限 600、不入库、不出现在任何仓库文件/对话/文档中）。
            // 密钥轮换记录：2026-11-22 v1 密钥（别名 home_inventory）因密码
            // 明文泄露废弃，现用 v2（别名 home_inventory_v2）。
            // 旧包（V3.1.1 及之前）为 Windows debug 密钥签名，密钥未随环境
            // 迁移；3.2.0 起签名链全新，覆盖安装需卸载重装+备份恢复。
            storeFile = file(findProperty("MYAPP_RELEASE_STORE_FILE") as String)
            storePassword = findProperty("MYAPP_RELEASE_STORE_PASSWORD") as String
            keyAlias = findProperty("MYAPP_RELEASE_KEY_ALIAS") as String
            keyPassword = findProperty("MYAPP_RELEASE_KEY_PASSWORD") as String
        }
    }

    defaultConfig {
        applicationId = "com.songdd.homeinventory.home_inventory"
        // minSdk 24：与已发版包（sdkVersion:'24'）对齐。
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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

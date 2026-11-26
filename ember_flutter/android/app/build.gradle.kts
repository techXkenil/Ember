import java.io.FileOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.chaquo.python")
}

android {
    namespace = "com.ember.app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ember.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters.clear()
            abiFilters += listOf("arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }


    signingConfigs {
        create("release") {
            storeFile = file("ember.jks")
            storePassword = "ember2026"
            keyAlias = "ember2026"
            keyPassword = "ember2026"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

chaquopy {
    defaultConfig {
        val userHome = System.getProperty("user.home")
        val candidatePaths = listOf(
            File(userHome, "AppData/Roaming/uv/python/cpython-3.11-windows-x86_64-none/python.exe"),
            File(userHome, "AppData/Roaming/uv/python/cpython-3.11.14-windows-x86_64-none/python.exe"),
            File(userHome, "AppData/Local/Programs/Python/Python311/python.exe"),
            File("C:/Python311/python.exe"),
        )
        val pyExe = candidatePaths.firstOrNull { it.exists() }
        if (pyExe != null) {
            buildPython(pyExe.absolutePath)
        }

        version = "3.11"
        pip {
            options("--default-timeout=120")
            install("ytmusicapi>=1.7.0")
            install("yt-dlp>=2024.0.0")
            install("requests>=2.31.0")
        }
    }
    sourceSets {
        getByName("main") {
            srcDir("../../../ember")
            // Exclude desktop-only PyQt6 GUI/tray modules from the Android APK.
            exclude(
                "__main__.py",
                "app.py",
                "discord_rpc.py",
                "doctor.py",
                "exporter.py",
                "icons.py",
                "jobs.py",
                "panel.py",
                "player.py",
                "scrobbler.py",
                "settings_dialog.py",
                "smtc.py",
                "storage.py",
                "theme.py",
                "toast.py",
                "tray.py",
            )
        }
    }
}

fun pruneZipFile(zipFile: File, shouldDrop: (String) -> Boolean) {
    if (!zipFile.exists()) return
    val tmpFile = File(zipFile.parentFile, "${zipFile.name}.tmp")
    ZipFile(zipFile).use { zin ->
        ZipOutputStream(FileOutputStream(tmpFile)).use { zout ->
            val entries = zin.entries()
            while (entries.hasMoreElements()) {
                val entry = entries.nextElement()
                if (shouldDrop(entry.name)) continue
                val newEntry = ZipEntry(entry.name).apply {
                    time = entry.time
                }
                zout.putNextEntry(newEntry)
                zin.getInputStream(entry).use { input ->
                    input.copyTo(zout)
                }
                zout.closeEntry()
            }
        }
    }
    if (!zipFile.delete() || !tmpFile.renameTo(zipFile)) {
        tmpFile.copyTo(zipFile, overwrite = true)
        tmpFile.delete()
    }
}

afterEvaluate {
    listOf("Debug", "Profile", "Release").forEach { variant ->
        val variantLower = variant.lowercase()

        tasks.findByName("install${variant}PythonRequirements")?.doLast {
            val extDir = layout.buildDirectory
                .dir("python/pip/$variantLower/common/yt_dlp/extractor")
                .get()
                .asFile
            if (extDir.exists()) {
                val keepFiles = setOf(
                    "__init__.py", "__init__.pyc",
                    "extractors.py", "extractors.pyc",
                    "_extractors.py", "_extractors.pyc",
                    "common.py", "common.pyc",
                    "commonprotocols.py", "commonprotocols.pyc",
                    "generic.py", "generic.pyc",
                    "afreecatv.py", "afreecatv.pyc",
                    "adobepass.py", "adobepass.pyc",
                    "openload.py", "openload.pyc",
                    "youtube",
                )
                extDir.listFiles()?.forEach { f ->
                    if (f.name !in keepFiles) {
                        f.deleteRecursively()
                    }
                }
                val extractorsFile = File(extDir, "_extractors.py")
                val extractorsPyc = File(extDir, "_extractors.pyc")
                if (extractorsFile.exists()) {
                    val originalLines = extractorsFile.readLines()
                    val filteredLines = mutableListOf<String>()
                    var inYoutubeBlock = false
                    for (line in originalLines) {
                        when {
                            line.startsWith("from .generic import") -> filteredLines.add(line)
                            line.startsWith("from .youtube import") -> {
                                inYoutubeBlock = true
                                filteredLines.add(line)
                            }
                            inYoutubeBlock -> {
                                filteredLines.add(line)
                                if (line.trim() == ")") inYoutubeBlock = false
                            }
                        }
                    }
                    extractorsFile.writeText(filteredLines.joinToString("\n") + "\n")
                    if (extractorsPyc.exists()) {
                        extractorsPyc.delete()
                    }
                    val envDir = layout.buildDirectory.dir("python/env/$variantLower").get().asFile
                    val envPython = listOf(
                        File(envDir, "Scripts/python.exe"),
                        File(envDir, "bin/python"),
                        File(envDir, "bin/python3"),
                    ).firstOrNull { it.exists() }
                    if (envPython != null) {
                        val proc = ProcessBuilder(
                            envPython.absolutePath,
                            "-c",
                            "import py_compile; py_compile.compile(r'${extractorsFile.absolutePath.replace("\\", "/")}', cfile=r'${extractorsPyc.absolutePath.replace("\\", "/")}', doraise=True)"
                        ).redirectErrorStream(true).start()
                        val output = proc.inputStream.bufferedReader().readText()
                        if (proc.waitFor() != 0) {
                            throw GradleException("Failed to compile pruned yt_dlp _extractors.py: $output")
                        }
                    }
                }
            }
        }

        tasks.findByName("generate${variant}PythonMiscAssets")?.doLast {
            val stdlibImy = layout.buildDirectory
                .file("python/assets/misc/$variantLower/chaquopy/stdlib-common.imy")
                .get()
                .asFile
            val dropPrefixes = listOf(
                "distutils/",
                "lib2to3/",
                "unittest/",
                "pydoc.pyc",
                "pydoc_data/",
                "doctest.pyc",
                "pdb.pyc",
                "idlelib/",
                "tkinter/",
                "turtle.pyc",
                "turtledemo/",
                "ensurepip/",
                "venv/",
                "test/",
                "xmlrpc/",
                "mailbox.pyc",
            )
            pruneZipFile(stdlibImy) { name ->
                dropPrefixes.any { prefix -> name == prefix || name.startsWith(prefix) }
            }
        }
    }
}

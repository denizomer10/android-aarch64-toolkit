// ---------------------------------------------------------------------------
// Reusable Gradle snippet: cross-compile a Rust cdylib for every Android ABI
// on an aarch64 host, using a native aarch64 toolchain (no x86_64, no qemu).
//
// Copy this into your Kotlin Multiplatform / Android module's build.gradle.kts
// (or `apply(from = "path/to/rust-android-native.gradle.kts")` and adapt names).
//
// It reads two machine-local Gradle properties (written by setup.sh):
//   oxicalc.ndk        = /path/to/native-aarch64-ndk
//   oxicalc.ndkLibDir  = /path/to/extra/libs   (optional; e.g. libxml2.so.16)
//
// Output .so files are dropped into a jniLibs dir that the android block picks
// up via sourceSets.getByName("main").jniLibs.srcDir(...).
// ---------------------------------------------------------------------------

import org.gradle.api.tasks.Exec

// rust target triple, Android ABI dir, NDK clang prefix
val rustTargets = listOf(
    Triple("aarch64-linux-android", "arm64-v8a", "aarch64-linux-android"),
    Triple("armv7-linux-androideabi", "armeabi-v7a", "armv7a-linux-androideabi"),
    Triple("x86_64-linux-android", "x86_64", "x86_64-linux-android"),
)

val rustCrate = "oxicalc"            // cargo package name
val rustRoot = rootProject.file("rust")
val androidApiLevel = providers.gradleProperty("oxicalc.androidApi").orNull ?: "24"
val rustJniLibsDir = layout.buildDirectory.dir("rust/jniLibs")
val ndkPath: String? = providers.gradleProperty("oxicalc.ndk").orNull
    ?: System.getenv("ANDROID_NDK_HOME")
val ndkLibDir: String? = providers.gradleProperty("oxicalc.ndkLibDir").orNull

val cargoBuildAndroid = tasks.register<Exec>("cargoBuildAndroid") {
    group = "rust"
    description = "Cross-compiles the Rust core for all Android ABIs (native aarch64 toolchain)."
    workingDir = rustRoot
    val outputDir = rustJniLibsDir.get().asFile
    inputs.dir(rustRoot.resolve("$rustCrate/src"))
    inputs.file(rustRoot.resolve("$rustCrate/Cargo.toml"))
    outputs.dir(rustJniLibsDir)
    doFirst {
        val ndk = ndkPath ?: throw GradleException(
            "Set -Poxicalc.ndk=<native-aarch64-ndk> (or ANDROID_NDK_HOME)."
        )
        val prebuilt = File(ndk, "toolchains/llvm/prebuilt").listFiles()?.firstOrNull { it.isDirectory }
            ?: throw GradleException("No LLVM prebuilt toolchain under $ndk")
        val ndkBin = File(prebuilt, "bin")
        val ar = File(ndkBin, "llvm-ar").absolutePath
        outputDir.mkdirs()

        val script = StringBuilder("set -e\n")
        script.appendLine("export PATH=\"\$HOME/.cargo/bin:\$PATH\"")
        if (ndkLibDir != null) script.appendLine("export LD_LIBRARY_PATH=\"$ndkLibDir:\$LD_LIBRARY_PATH\"")
        rustTargets.forEach { (triple, abi, clangPrefix) ->
            val envTriple = triple.uppercase().replace('-', '_')
            val clang = File(ndkBin, "$clangPrefix$androidApiLevel-clang").absolutePath
            script.appendLine(
                "CARGO_TARGET_${envTriple}_LINKER=$clang AR_${triple.replace('-', '_')}=$ar " +
                    "cargo build --release --target $triple -p $rustCrate"
            )
            script.appendLine("mkdir -p $outputDir/$abi")
            script.appendLine("cp $rustRoot/target/$triple/release/lib$rustCrate.so $outputDir/$abi/lib$rustCrate.so")
        }

        val scriptFile = layout.buildDirectory.file("rust/build-android.sh").get().asFile
        scriptFile.parentFile.mkdirs()
        scriptFile.writeText(script.toString())
        scriptFile.setExecutable(true)
        commandLine("sh", scriptFile.absolutePath)
    }
}

// This task generates and runs a script at execution time → not config-cache compatible.
tasks.matching { it.name == "cargoBuildAndroid" }.configureEach {
    notCompatibleWithConfigurationCache("Generates a shell script at execution time.")
}

// In your `android { ... }` block add:
//   sourceSets.getByName("main").jniLibs.srcDir(layout.buildDirectory.dir("rust/jniLibs").get().asFile)
// and make sure the core is built first:
//   tasks.matching { it.name == "preBuild" }.configureEach { dependsOn(cargoBuildAndroid) }

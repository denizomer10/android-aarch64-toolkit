# android-aarch64-toolkit

Build Android apps **natively on Linux aarch64** (arm64) — no `qemu`, no `FEX`,
and without ever executing an x86_64 binary.

Google's Android SDK/NDK ship their *host* tools (`aapt2`, `zipalign`,
`apksigner`, `cmdline-tools`, the NDK clang, …) for **x86_64 Linux only**. On an
aarch64 machine (e.g. Fedora Asahi, Debian on Raspberry Pi, Ampere, …) the usual
toolchain simply cannot run. This toolkit assembles a **genuinely native
aarch64** equivalent from sources that do publish arm64 builds (mainly Debian
and a community NDK), then wires Gradle/AGP to use them.

## What it sets up

| Component | Source | Why |
| --- | --- | --- |
| `aapt2` (+ `aapt`) | **Debian** `aapt` package (arm64) | AGP needs aapt2 for resources; Google's is x86_64 |
| `android.jar` (platform) | Google platform zip (arch-independent) | Compile against the Android API |
| `build-tools` stub | generated | AGP requires a build-tools dir to exist |
| JDK (daemon JVM) | **Temurin** (arm64) | matches Gradle's pinned toolchain (21) |
| NDK (optional) | **community native aarch64 NDK** | cross-compile Rust/NDK native code |
| Gradle config | generated | points AGP at the native aapt2, disables SDK downloads |

Everything lands under `~/Android` by default and is fully self-contained.

## Platform coverage

By default the toolkit installs **every** Android platform from **API 21
(Android 5.0)** through the **latest (API 37)**, so you can set `compileSdk` to
any of them. Older platforms are read directly; newer ones (35+) have their
`android.jar` patched automatically (see below). Adjust the set with
`--platforms "21 34 37"` or the `PLATFORMS` variable.

A native `adb` (from your distro's `android-tools`) is installed too, so you can
run/debug on a device.

## Requirements

- A glibc **aarch64** Linux host: **Fedora**, **Arch**, **Debian/Ubuntu**, etc.
  (musl distros like Alpine are not supported — the binaries are glibc).
- `curl`, `unzip`, `python3`, `tar`. (`.deb` files are unpacked in pure Python —
  no `ar`, `dpkg` or `apt` required.)
- Optional: `clang`/`lld` for the sysroot fallback mode; auto-installed via
  `dnf`/`pacman`/`apt` when available.
- Optional: a Rust toolchain (`rustup`) for the native-code cross-compile.

## Quick start

```sh
# 1. Set up the whole native SDK + toolchain under ~/Android
./setup.sh

# 2. (optional) point a project at it
./setup.sh --project /path/to/your/android/app

# 3. Build
cd /path/to/your/android/app
./gradlew assembleDebug
```

`setup.sh` is idempotent; re-run it any time. Use `./verify.sh` to check the
result.

## Portable bundle (full native files)

To move the whole toolchain to another aarch64 machine (or ship it), pack it
into one relocatable tarball:

```sh
./bundle.sh              # full (includes the NDK)
./bundle.sh --no-ndk     # smaller, without the NDK
```

On the target machine:

```sh
tar xzf android-aarch64-toolchain-*.tar.gz
cd android-aarch64-toolchain
./install.sh                 # configure Gradle for this location
./install.sh /path/to/project
```

Everything inside is path-independent (wrappers resolve their own location), so
the extracted folder can live anywhere and works on Fedora, Arch and Debian
alike.

## Configuration

All steps are configurable through environment variables (defaults shown):

| Variable | Default | Meaning |
| --- | --- | --- |
| `TOOLKIT_ROOT` | `~/Android` | where everything is installed |
| `SDK_DIR` | `$TOOLKIT_ROOT/sdk` | the Android SDK root |
| `PLATFORMS` | `21 22 … 37` | API levels to install (Android 5.0 → latest) |
| `ARSC_MAX` | `34` | highest API whose `resources.arsc` aapt2 reads directly |
| `ARSC_DONOR` | `$ARSC_MAX` | platform whose `resources.arsc` patches newer ones |
| `BUILD_TOOLS_VERSION` | `36.0.0` | build-tools revision to stub |
| `ANDROID_API` | `24` | API level used when linking native code |
| `JDK_VERSION` | `21` | Temurin JDK major version |
| `WITH_NDK` | `1` | download the native aarch64 NDK |
| `NDK_REPO` / `NDK_TAG` | `SnowNF/ndk-aarch64-linux` / `0.0.2` | community NDK source |

Flags: `--platforms "…"`, `--arsc-donor N`, `--no-sysdeps`, `--no-adb`,
`--no-ndk`, `--offline`, `--project <dir>`, `--root <dir>`.

## The `resources.arsc` caveat (important)

The only native aarch64 `aapt2` available today is Debian's, built from
**AOSP 14**. It can only parse `resources.arsc` up to **API 34**. Newer platforms
(35+) use an encoding it rejects with:

```
LoadedArsc.cpp:94 RES_TABLE_TYPE_TYPE entry offsets overlap actual entry data.
```

Modern libraries (Compose UI, lifecycle, …) require `compileSdk 37`, so we can't
just downgrade. The toolkit therefore installs the requested platform but
**replaces the `resources.arsc` inside its `android.jar` with the API-34 one**.
Class files stay at the requested API, so Kotlin/Java compile against the full
API — only the resource table that `aapt2` reads is downgraded.

This is safe for apps that reference only long-stable framework resources, but it
is a targeted workaround, not a general solution. See `scripts/patch-platform-jar.py`.

## Native-code cross-compile (Rust/NDK)

The toolkit can pull the community aarch64 NDK
(`SnowNF/ndk-aarch64-linux`) and fix its one missing runtime dependency
(`libxml2.so.16`, provided by Debian's `libxml2-16`). Then a Gradle task like
`gradle/rust-android-native.gradle.kts` cross-compiles a Rust `cdylib` for every
Android ABI using the real NDK toolchain.

Environment written to `~/.gradle/gradle.properties`:

```properties
android.aapt2FromMavenOverride=$TOOLKIT_ROOT/bin/aapt2
android.builder.sdkDownload=false
oxicalc.ndk=$TOOLKIT_ROOT/ndk
oxicalc.ndkLibDir=$TOOLKIT_ROOT/ndk-libs
org.gradle.java.installations.paths=$TOOLKIT_ROOT/jdk21
org.gradle.java.installations.auto-download=false
```

## Do NOT run Google's `cmdline-tools` here

`commandlinetools-linux-*` is x86_64, and `sdkmanager` delegates to an x86_64
`android` binary. Running it would (silently) go through an emulator such as
FEX/qemu — which this toolkit exists to avoid. SDK packages are fetched as plain
zips instead.

## Notes

- On an x86_64 host none of this is needed — install the regular SDK + NDK.
- The community NDK is "still in development"; pin a known-good release tag.

## License

MIT — see [LICENSE](LICENSE).

#!/usr/bin/env bash
#
# android-aarch64-toolkit — set up a native aarch64 Android build toolchain.
#
# Works on any glibc aarch64 distro. Host package managers are auto-detected
# (dnf / pacman / apt) and used only for optional system tools; the Android-
# specific pieces come from distro-independent sources (Debian .deb files are
# unpacked in pure Python, Google platform zips, Temurin JDK, a community
# aarch64 NDK). No qemu, no FEX, no x86_64 binaries are ever executed.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment or flags)
# ---------------------------------------------------------------------------
TOOLKIT_ROOT="${TOOLKIT_ROOT:-$HOME/Android}"
SDK_DIR="${SDK_DIR:-$TOOLKIT_ROOT/sdk}"
# Platforms to install. Default spans Android 5.0 (API 21) .. latest (API 37).
PLATFORMS="${PLATFORMS:-21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37}"
# Highest API whose resources.arsc the native aapt2 can read directly.
ARSC_MAX="${ARSC_MAX:-34}"
# Donor platform whose resources.arsc is used to patch newer platforms.
ARSC_DONOR="${ARSC_DONOR:-$ARSC_MAX}"
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-36.0.0}"
ANDROID_API="${ANDROID_API:-24}"
JDK_VERSION="${JDK_VERSION:-21}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
WITH_NDK="${WITH_NDK:-1}"
NDK_REPO="${NDK_REPO:-SnowNF/ndk-aarch64-linux}"
NDK_TAG="${NDK_TAG:-0.0.2}"
NDK_VERSION="${NDK_VERSION:-29}"

DO_SYSDEPS=1
WITH_ADB=1
OFFLINE=0
PROJECT_DIR=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$TOOLKIT_ROOT/bin"
DEBIAN_ROOT="$TOOLKIT_ROOT/debian/root"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: ./setup.sh [options]

Options:
  --platforms "A B C" API levels to install (default: full range 21..37)
  --arsc-donor N      platform whose resources.arsc patches newer ones (default: $ARSC_DONOR)
  --build-tools V     build-tools revision to stub (default: $BUILD_TOOLS_VERSION)
  --jdk N             Temurin JDK major version (default: $JDK_VERSION)
  --root DIR          install root (default: $TOOLKIT_ROOT)
  --no-sysdeps        do not install host system packages
  --no-ndk            do not download the native aarch64 NDK
  --offline           never download; fail if something is missing
  --project DIR       also write DIR/local.properties with sdk.dir
  -h, --help          show this help
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
have_file_cmd() { have_cmd file; }

ensure_line() { local file="$1" line="$2"; touch "$file"; grep -qxF "$line" "$file" || printf '%s\n' "$line" >> "$file"; }

pkg_mgr() {
  if have_cmd dnf; then echo dnf
  elif have_cmd pacman; then echo pacman
  elif have_cmd apt-get; then echo apt
  else echo none; fi
}

download() { # url dest
  [ "$OFFLINE" = "1" ] && die "offline mode: refusing to download $1"
  curl -L --fail --retry 5 --retry-delay 2 --retry-all-errors --max-time 1800 -o "$2" "$1"
}

REPO_INDEX="$TOOLKIT_ROOT/repository2-3.xml"
fetch_repo_index() {
  if [ -s "$REPO_INDEX" ]; then return; fi
  [ "$OFFLINE" = "1" ] && return
  log "Caching Android repository manifest"
  curl -L --fail --retry 5 --retry-delay 2 --retry-all-errors --max-time 300 \
    -o "$REPO_INDEX" "https://dl.google.com/android/repository/repository2-3.xml" || warn "could not cache repo manifest"
}

get_pkg_url() { # package-prefix
  local args=(--package-prefix "$1")
  [ -s "$REPO_INDEX" ] && args+=(--repo-url "file://$REPO_INDEX")
  python3 "$SCRIPT_DIR/scripts/get-package-url.py" "${args[@]}"
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
preflight() {
  log "Preflight"
  [ "$(uname -m)" = "aarch64" ] || warn "Host is $(uname -m), not aarch64 — this toolkit targets aarch64."
  for c in curl unzip python3 tar; do need_cmd "$c"; done
  mkdir -p "$TOOLKIT_ROOT" "$SDK_DIR" "$BIN_DIR"
  fetch_repo_index
}

install_system_packages() {
  [ "$DO_SYSDEPS" = "1" ] || { log "Skipping system packages (--no-sysdeps)"; return; }
  [ "$OFFLINE" = "1" ] && { log "Skipping system packages (offline)"; return; }
  case "$(pkg_mgr)" in
    dnf)    log "Installing system tools via dnf";    sudo dnf install -y clang lld llvm binutils ;;
    pacman) log "Installing system tools via pacman"; sudo pacman -S --needed --noconfirm clang lld llvm binutils ;;
    apt)    log "Installing system tools via apt";    sudo apt-get update && sudo apt-get install -y clang lld llvm binutils ;;
    *)      warn "No known package manager found; skipping system tools (only needed for sysroot mode)." ;;
  esac
}

write_wrapper() { # name
  local name="$1"
  cat > "$BIN_DIR/$name" <<'EOF'
#!/bin/sh
# Relocatable wrapper: resolves its own location so the toolkit can be moved
# or shipped as a bundle and still work.
self="$0"
while [ -h "$self" ]; do
  d="$(cd -P "$(dirname "$self")" && pwd)"
  l="$(readlink "$self")"
  case "$l" in /*) self="$l" ;; *) self="$d/$l" ;; esac
done
here="$(cd -P "$(dirname "$self")" && pwd)"
root="$(cd "$here/.." && pwd)"
R="$root/debian/root"
LD_LIBRARY_PATH="$R/usr/lib/aarch64-linux-gnu:$R/usr/lib/aarch64-linux-gnu/android:$R/usr/lib/7zip${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
exec "$R/usr/lib/android-sdk/build-tools/debian/__NAME__" "$@"
EOF
  sed -i "s/__NAME__/$name/" "$BIN_DIR/$name"
  chmod +x "$BIN_DIR/$name"
}

setup_aapt2() {
  if [ -x "$BIN_DIR/aapt2" ] && "$BIN_DIR/aapt2" version >/dev/null 2>&1; then
    log "Native aapt2 already present: $("$BIN_DIR/aapt2" version 2>&1 | head -n1)"
  else
    log "Fetching native aarch64 aapt2 + deps from Debian"
    python3 "$SCRIPT_DIR/scripts/fetch-debian-debs.py" \
      --suite "$DEBIAN_SUITE" --dest "$DEBIAN_ROOT" --root-package aapt
  fi
  for t in aapt aapt2; do write_wrapper "$t"; done
  "$BIN_DIR/aapt2" version >/dev/null 2>&1 || die "native aapt2 failed to run"
}

usable_java() { # path -> 0 if >= 17
  [ -x "$1" ] || return 1
  local v; v="$("$1" -version 2>&1 | head -n1 | sed -E 's/.*"([0-9]+).*/\1/')"
  [ "${v:-0}" -ge 17 ] 2>/dev/null
}

setup_jdk() {
  local dest="$TOOLKIT_ROOT/jdk$JDK_VERSION"
  if usable_java "$dest/bin/java"; then log "JDK $JDK_VERSION already present at $dest"; return; fi

  # Reuse a suitable system JDK if the requested major version is present.
  local cand
  for cand in /usr/lib/jvm/*"$JDK_VERSION"* "$(command -v java 2>/dev/null)"; do
    [ -n "$cand" ] || continue
    local jhome
    jhome="$([ -x "$cand" ] && echo "$cand" || echo "$cand/bin/java")"
    if [ "$JDK_VERSION" = "$("$jhome" -version 2>&1 | head -n1 | sed -E 's/.*"([0-9]+).*/\1/')" ]; then
      log "Using system JDK $JDK_VERSION"; ln -sfn "$(dirname "$(dirname "$jhome")")" "$dest" 2>/dev/null || true
      usable_java "$dest/bin/java" && return
    fi
  done

  [ "$OFFLINE" = "1" ] && die "offline mode: JDK $JDK_VERSION not found"
  log "Downloading Temurin JDK $JDK_VERSION (arm64)"
  local tmp; tmp="$(mktemp -d)"
  download "https://api.adoptium.net/v3/binary/latest/$JDK_VERSION/ga/linux/aarch64/jdk/hotspot/normal/eclipse" "$tmp/jdk.tar.gz"
  mkdir -p "$dest"; tar xzf "$tmp/jdk.tar.gz" -C "$dest" --strip-components=1; rm -rf "$tmp"
  "$dest/bin/java" -version
}

write_platform_package_xml() { # api dest
  local api="$1" dest="$2"
  local ext; ext="$(grep -m1 '^AndroidVersion.ExtensionLevel=' "$dest/source.properties" 2>/dev/null | cut -d= -f2 || true)"; ext="${ext:-0}"
  cat > "$dest/package.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <sdk:localPackage path="platforms;android-$api" obsolete="false">
    <sdk:type-details xsi:type="sdk:platformDetailsType">
      <sdk:api-level>$api</sdk:api-level>
      <sdk:extension-level>$ext</sdk:extension-level>
      <sdk:base-extension>true</sdk:base-extension>
      <sdk:layoutlib api="15" revision="1"/>
    </sdk:type-details>
    <sdk:revision><sdk:major>1</sdk:major></sdk:revision>
    <sdk:display-name>Android SDK Platform $api</sdk:display-name>
  </sdk:localPackage>
</sdk:sdk-repository>
EOF
}

install_platform() { # api
  local api="$1"
  local dest="$SDK_DIR/platforms/android-$api"
  if [ -f "$dest/android.jar" ]; then
    log "Platform android-$api already installed"
    [ -f "$dest/package.xml" ] || write_platform_package_xml "$api" "$dest"
    return
  fi

  log "Installing platform android-$api"
  local url; url="$(get_pkg_url "platforms;android-$api")"
  local tmp; tmp="$(mktemp -d)"
  download "$url" "$tmp/p.zip"
  ( cd "$tmp" && unzip -q p.zip )
  local inner; inner="$(find "$tmp" -maxdepth 1 -type d -name 'android-*' | head -n1)"
  [ -n "$inner" ] || die "unexpected platform archive layout for android-$api"
  rm -rf "$dest"; mv "$inner" "$dest"
  write_platform_package_xml "$api" "$dest"
  rm -rf "$tmp"
}

patch_platform() { # target_api donor_api
  local target="$1" donor="$2"
  log "Patching android-$target resources.arsc from android-$donor"
  python3 "$SCRIPT_DIR/scripts/patch-platform-jar.py" \
    --old-jar "$SDK_DIR/platforms/android-$donor/android.jar" \
    --new-jar "$SDK_DIR/platforms/android-$target/android.jar" \
    --out     "$SDK_DIR/platforms/android-$target/android.jar"
}

setup_adb() {
  [ "$WITH_ADB" = "1" ] || { log "Skipping adb (--no-adb)"; return; }
  [ "$OFFLINE" = "1" ] && { log "Skipping adb (offline)"; return; }
  if have_cmd adb; then log "adb already present: $(adb version 2>/dev/null | head -n1)"; return; fi
  case "$(pkg_mgr)" in
    dnf)    log "Installing adb via dnf";    sudo dnf install -y android-tools ;;
    pacman) log "Installing adb via pacman"; sudo pacman -S --needed --noconfirm android-tools ;;
    apt)    log "Installing adb via apt";    sudo apt-get update && sudo apt-get install -y adb ;;
    *)      warn "No known package manager; skipping adb (install it yourself)" ;;
  esac
}

setup_build_tools() {
  log "Creating build-tools stub $BUILD_TOOLS_VERSION"
  local bt="$SDK_DIR/build-tools/$BUILD_TOOLS_VERSION"
  mkdir -p "$bt/lib"
  printf 'Pkg.Desc=Android SDK Build-Tools\nPkg.Revision=%s\n' "$BUILD_TOOLS_VERSION" > "$bt/source.properties"
  cat > "$bt/package.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03" xmlns:generic="http://schemas.android.com/repository/android/generic/02" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <localPackage path="build-tools;$BUILD_TOOLS_VERSION" obsolete="false">
    <type-details xsi:type="generic:genericDetailsType"/>
    <revision>
      <major>${BUILD_TOOLS_VERSION%%.*}</major>
      <minor>$(printf '%s' "$BUILD_TOOLS_VERSION" | cut -d. -f2)</minor>
      <micro>$(printf '%s' "$BUILD_TOOLS_VERSION" | cut -d. -f3)</micro>
    </revision>
    <display-name>Android SDK Build-Tools $BUILD_TOOLS_VERSION</display-name>
  </localPackage>
</sdk:sdk-repository>
EOF
  # Relative (relocatable) symlinks to the real native aapt/aapt2.
  ln -sf ../../../bin/aapt  "$bt/aapt"
  ln -sf ../../../bin/aapt2 "$bt/aapt2"
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1],'w').close()" "$bt/core-lambda-stubs.jar"
  local t
  for t in aidl zipalign apksigner d8 dx split-select dexdump mainDexClasses llvm-rs-cc; do
    printf '#!/bin/sh\necho "android-aarch64-toolkit placeholder: %s" >&2\nexit 0\n' "$t" > "$bt/$t"
    chmod +x "$bt/$t"
  done
}

setup_ndk() {
  [ "$WITH_NDK" = "1" ] || { log "Skipping NDK (--no-ndk)"; return; }
  local ndk_dir="$TOOLKIT_ROOT/ndk"
  if [ ! -d "$ndk_dir" ]; then
    [ "$OFFLINE" = "1" ] && die "offline mode: NDK not present at $ndk_dir"
    log "Downloading community native aarch64 NDK ($NDK_REPO $NDK_TAG)"
    local tmp; tmp="$(mktemp -d)"
    download "https://github.com/$NDK_REPO/releases/download/$NDK_TAG/android-ndk-r$NDK_VERSION-linux-aarch64.tar.gz" "$tmp/ndk.tar.gz"
    ( cd "$tmp" && tar xzf ndk.tar.gz )
    local inner; inner="$(find "$tmp" -maxdepth 1 -type d -name 'r*' | head -n1)"
    [ -n "$inner" ] || die "unexpected NDK archive layout"
    rm -rf "$ndk_dir"; mv "$inner" "$ndk_dir"; rm -rf "$tmp"
  else
    log "NDK already present at $ndk_dir"
  fi

  local libs="$TOOLKIT_ROOT/ndk-libs"
  if ! ls "$libs"/libxml2.so.16 >/dev/null 2>&1; then
    [ "$OFFLINE" = "1" ] && { warn "offline: skipping libxml2.so.16 (NDK lld may need it)"; return; }
    log "Fetching libxml2.so.16 (Debian) for the NDK linker"
    local src; src="$(mktemp -d)"
    python3 "$SCRIPT_DIR/scripts/fetch-debian-debs.py" --suite sid --dest "$src" --root-package libxml2-16 || true
    mkdir -p "$libs"
    find "$src" -name 'libxml2.so.16*' -exec cp -a {} "$libs/" \; || true
    rm -rf "$src"
  fi

  if have_file_cmd; then
    local hostbin; hostbin="$(find "$ndk_dir/toolchains/llvm/prebuilt" -maxdepth 1 -mindepth 1 -type d | head -n1)/bin"
    [ -x "$hostbin/clang" ] && log "NDK clang: $(file "$hostbin/clang" | sed 's/.*ELF/ELF/; s/,.*//')"
  fi
}

write_gradle_config() {
  if [ "$OFFLINE" != "1" ]; then
    log "Writing ~/.gradle/gradle.properties"
    local gp="$HOME/.gradle/gradle.properties"; mkdir -p "$HOME/.gradle"
    ensure_line "$gp" "android.aapt2FromMavenOverride=$BIN_DIR/aapt2"
    ensure_line "$gp" "android.builder.sdkDownload=false"
    ensure_line "$gp" "org.gradle.java.installations.paths=$TOOLKIT_ROOT/jdk$JDK_VERSION"
    ensure_line "$gp" "org.gradle.java.installations.auto-download=false"
    if [ "$WITH_NDK" = "1" ]; then
      ensure_line "$gp" "oxicalc.ndk=$TOOLKIT_ROOT/ndk"
      ensure_line "$gp" "oxicalc.ndkLibDir=$TOOLKIT_ROOT/ndk-libs"
    fi
  fi

  if [ -n "$PROJECT_DIR" ]; then
    log "Writing $PROJECT_DIR/local.properties"
    mkdir -p "$PROJECT_DIR"
    if [ -f "$PROJECT_DIR/local.properties" ]; then
      grep -v '^sdk.dir=' "$PROJECT_DIR/local.properties" > "$PROJECT_DIR/local.properties.tmp" || true
      mv "$PROJECT_DIR/local.properties.tmp" "$PROJECT_DIR/local.properties"
    fi
    printf 'sdk.dir=%s\n' "$SDK_DIR" >> "$PROJECT_DIR/local.properties"
  fi
}

summary() {
  log "Done."
  echo "  Install root : $TOOLKIT_ROOT"
  echo "  Android SDK  : $SDK_DIR"
  echo "  Platforms    : $(echo $PLATFORMS | wc -w) API levels (arsc donor: $ARSC_DONOR)"
  echo "  aapt2        : $BIN_DIR/aapt2"
  echo "  JDK          : $TOOLKIT_ROOT/jdk$JDK_VERSION"
  [ "$WITH_NDK" = "1" ] && echo "  NDK          : $TOOLKIT_ROOT/ndk  (libs: $TOOLKIT_ROOT/ndk-libs)"
  echo
  echo "  Build a project:  cd <project> && ./gradlew assembleDebug"
  echo "  Verify:           ./verify.sh"
  echo "  Make a portable bundle: ./bundle.sh"
}

# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --platforms) PLATFORMS="$2"; shift 2 ;;
    --arsc-donor) ARSC_DONOR="$2"; shift 2 ;;
    --build-tools) BUILD_TOOLS_VERSION="$2"; shift 2 ;;
    --jdk) JDK_VERSION="$2"; shift 2 ;;
    --root) TOOLKIT_ROOT="$2"; SDK_DIR="$2/sdk"; BIN_DIR="$2/bin"; DEBIAN_ROOT="$2/debian/root"; shift 2 ;;
    --no-sysdeps) DO_SYSDEPS=0; shift ;;
    --no-adb) WITH_ADB=0; shift ;;
    --no-ndk) WITH_NDK=0; shift ;;
    --offline) OFFLINE=1; shift ;;
    --project) PROJECT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

preflight
install_system_packages
setup_aapt2
setup_jdk
# Ensure the donor platform is available even if it wasn't requested.
case " $PLATFORMS " in *" $ARSC_DONOR "*) ;; *) PLATFORMS="$PLATFORMS $ARSC_DONOR" ;; esac

for api in $PLATFORMS; do install_platform "$api"; done
for api in $PLATFORMS; do
  # Newer platforms use a resources.arsc the native aapt2 can't read; downgrade it.
  if [ "$api" -gt "$ARSC_DONOR" ] 2>/dev/null; then patch_platform "$api" "$ARSC_DONOR"; fi
done
setup_build_tools
setup_ndk
setup_adb
write_gradle_config
summary

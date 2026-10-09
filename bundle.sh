#!/usr/bin/env bash
#
# bundle.sh — pack the installed toolchain into a single relocatable tarball.
#
# The result is a self-contained set of *native aarch64* binaries you can copy
# to any glibc aarch64 machine (Fedora, Arch, Debian, …) and use without
# installing anything or downloading the SDK/NDK again.
#
#   ./bundle.sh                 # full bundle (includes the NDK)
#   ./bundle.sh --no-ndk        # smaller bundle without the NDK
#   ./bundle.sh -o /tmp/out.tgz
#
set -euo pipefail

TOOLKIT_ROOT="${TOOLKIT_ROOT:-$HOME/Android}"
JDK_VERSION="${JDK_VERSION:-21}"
INCLUDE_NDK=1
OUT=""

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: ./bundle.sh [--no-ndk] [-o OUTPUT.tgz]
  --no-ndk        exclude the (large) NDK + libs
  -o FILE         output path (default: android-aarch64-toolchain-<date>.tar.gz)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-ndk) INCLUDE_NDK=0; shift ;;
    -o) OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -d "$TOOLKIT_ROOT" ] || die "toolkit root not found: $TOOLKIT_ROOT (run ./setup.sh first)"
OUT="${OUT:-$PWD/android-aarch64-toolchain-$(date +%Y%m%d).tar.gz}"

STAGE="$(mktemp -d)"
NAME="android-aarch64-toolchain"
DEST="$STAGE/$NAME"
mkdir -p "$DEST"

log "Staging runtime files"
for p in bin debian/root "jdk$JDK_VERSION" sdk/platforms sdk/build-tools; do
  [ -e "$TOOLKIT_ROOT/$p" ] || { echo "  -- missing $p, skipping"; continue; }
  echo "  + $p"
  mkdir -p "$(dirname "$DEST/$p")"
  cp -a "$TOOLKIT_ROOT/$p" "$DEST/$p"
done
if [ "$INCLUDE_NDK" = "1" ]; then
  for p in ndk ndk-libs; do
    [ -e "$TOOLKIT_ROOT/$p" ] || continue
    echo "  + $p"
    cp -a "$TOOLKIT_ROOT/$p" "$DEST/$p"
  done
fi

# A tiny installer that points Gradle at *this* extraction location.
cat > "$DEST/install.sh" <<'EOF'
#!/usr/bin/env bash
# Point Gradle/AGP at the toolchain in this directory. Run after extracting.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JDK="$ROOT/jdk21"
GP="$HOME/.gradle/gradle.properties"
mkdir -p "$HOME/.gradle"; touch "$GP"
ensure() { grep -qxF "$1" "$GP" || printf '%s\n' "$1" >> "$GP"; }
ensure "android.aapt2FromMavenOverride=$ROOT/bin/aapt2"
ensure "android.builder.sdkDownload=false"
ensure "org.gradle.java.installations.paths=$JDK"
ensure "org.gradle.java.installations.auto-download=false"
[ -d "$ROOT/ndk" ] && ensure "oxicalc.ndk=$ROOT/ndk"
[ -d "$ROOT/ndk-libs" ] && ensure "oxicalc.ndkLibDir=$ROOT/ndk-libs"
if [ "${1:-}" != "" ]; then
  grep -v '^sdk.dir=' "$1/local.properties" 2>/dev/null > "$1/local.properties.tmp" || true
  mv -f "$1/local.properties.tmp" "$1/local.properties" 2>/dev/null || true
  printf 'sdk.dir=%s\n' "$ROOT/sdk" >> "$1/local.properties"
fi
echo "Configured. Paths written to $GP ; SDK at $ROOT/sdk"
EOF
chmod +x "$DEST/install.sh"

cat > "$DEST/README.md" <<'EOF'
# OxiCalc-style Android aarch64 toolchain (portable bundle)

Native aarch64 Android build toolchain: aapt2, platform, build-tools, a JDK and
(optionally) an NDK. Runs natively on any glibc aarch64 distro (Fedora, Arch,
Debian, …). No x86_64 tools, no qemu/FEX.

## Use

```sh
tar xzf android-aarch64-toolchain-*.tar.gz
cd android-aarch64-toolchain
./install.sh                 # configure Gradle globally
./install.sh /path/to/project  # ...and set that project's local.properties

cd /path/to/project && ./gradlew assembleDebug
```

Paths inside are relocatable: move the extracted folder anywhere.
EOF

log "Creating archive: $OUT"
tar czf "$OUT" -C "$STAGE" "$NAME"
rm -rf "$STAGE"

SIZE="$(du -h "$OUT" | cut -f1)"
log "Wrote $OUT ($SIZE)"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUT" | sed 's/^/sha256: /'
fi

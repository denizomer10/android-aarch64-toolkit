#!/usr/bin/env bash
#
# verify.sh — check the native aarch64 toolchain set up by setup.sh.
#
set -uo pipefail

TOOLKIT_ROOT="${TOOLKIT_ROOT:-$HOME/Android}"
SDK_DIR="${SDK_DIR:-$TOOLKIT_ROOT/sdk}"
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-36.0.0}"
JDK_VERSION="${JDK_VERSION:-21}"
BIN_DIR="$TOOLKIT_ROOT/bin"

ok=0; bad=0
pass() { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; ok=$((ok+1)); }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; bad=$((bad+1)); }
info() { printf '  \033[1;34m--\033[0m   %s\n' "$*"; }

echo "== native aarch64 Android toolchain =="

echo "- aapt2 / aapt (native)"
if "$BIN_DIR/aapt2" version >/dev/null 2>&1; then pass "aapt2: $("$BIN_DIR/aapt2" version 2>&1 | head -n1)"; else fail "aapt2 not runnable"; fi
if "$BIN_DIR/aapt" version >/dev/null 2>&1; then pass "aapt runnable"; else fail "aapt not runnable"; fi

echo "- JDK $JDK_VERSION"
if [ -x "$TOOLKIT_ROOT/jdk$JDK_VERSION/bin/java" ]; then
  pass "JDK: $("$TOOLKIT_ROOT/jdk$JDK_VERSION/bin/java" -version 2>&1 | head -n1)"
else
  fail "JDK $JDK_VERSION missing"
fi

echo "- SDK platforms (aapt2 must be able to read each android.jar)"
tmp="$(mktemp -d)"
printf '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="v.e.r.i.f.y"/>\n' > "$tmp/AndroidManifest.xml"
count=0
for dir in "$SDK_DIR"/platforms/android-*; do
  [ -d "$dir" ] || continue
  api="$(basename "$dir" | sed 's/^android-//')"
  jar="$dir/android.jar"
  count=$((count+1))
  if [ ! -f "$jar" ]; then fail "android-$api: missing android.jar"; continue; fi
  if [ ! -f "$dir/package.xml" ]; then fail "android-$api: missing package.xml"; continue; fi
  if "$BIN_DIR/aapt2" link -I "$jar" --manifest "$tmp/AndroidManifest.xml" -o "$tmp/out.apk" >/dev/null 2>&1; then
    pass "android-$api"
  else
    fail "android-$api: aapt2 cannot read android.jar (run setup.sh to patch it)"
  fi
done
[ "$count" -eq 0 ] && fail "no platforms installed"
rm -rf "$tmp"

echo "- build-tools $BUILD_TOOLS_VERSION"
if [ -f "$SDK_DIR/build-tools/$BUILD_TOOLS_VERSION/package.xml" ]; then pass "build-tools stub present"; else fail "build-tools stub missing"; fi

echo "- adb"
if command -v adb >/dev/null 2>&1; then pass "$(adb version 2>/dev/null | head -n1)"; else info "adb not installed (optional)"; fi

echo "- NDK"
if [ -d "$TOOLKIT_ROOT/ndk" ]; then
  hostbin="$(find "$TOOLKIT_ROOT/ndk/toolchains/llvm/prebuilt" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1)/bin"
  if [ -x "$hostbin/clang" ] && command -v file >/dev/null 2>&1; then
    arch="$(file "$hostbin/clang" | sed 's/.*ELF/ELF/; s/,.*//')"
    case "$arch" in
      *aarch64*) pass "NDK clang is native aarch64 ($arch)" ;;
      *) fail "NDK clang is not aarch64 ($arch)" ;;
    esac
  elif [ -x "$hostbin/clang" ]; then
    pass "NDK clang present at $hostbin/clang"
  else
    fail "NDK clang not found"
  fi
  [ -f "$TOOLKIT_ROOT/ndk-libs/libxml2.so.16" ] && pass "ndk-libs/libxml2.so.16 present (lld dependency)" || info "ndk-libs/libxml2.so.16 missing (needed by some NDK builds' lld)"
else
  info "NDK not installed (ok if you used --no-ndk)"
fi

echo
echo "passed: $ok   failed: $bad"
[ "$bad" -eq 0 ]

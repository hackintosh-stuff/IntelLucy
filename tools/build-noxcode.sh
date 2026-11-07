#!/bin/sh
# build-noxcode.sh - Build IntelLucy.kext with only the Command Line Tools
#
# Usage (run on macOS; neither Xcode.app nor sudo is required):
#   sh tools/build-noxcode.sh [source-root] [MacKernelSDK-root]
#   MACKERNELSDK=/path/to/MacKernelSDK sh tools/build-noxcode.sh
#
# Why xcodebuild is not used:
#   The build machine has only the Command Line Tools, and /usr/bin/xcodebuild is a stub.
#   A kext needs clang, the kernel headers, libkmod and `ld -kext`, all of which ship with
#   the CLT. This script reproduces the target's build settings (x86_64, c++17/gnu17, the
#   IntelLucy prefix header, the bundled MacKernelSDK) without the Xcode project.
#
# Source list: taken from the target's "Sources" build phase.
#
# Info.plist: the project uses GENERATE_INFOPLIST_FILE = YES, so Xcode synthesises
#   CFBundleExecutable / CFBundleIdentifier / CFBundleName / CFBundlePackageType /
#   CFBundleVersion / CFBundleShortVersionString / NSHumanReadableCopyright on top of the
#   checked-in plist. A manual build has to add those keys itself, otherwise the bundle has
#   no identifier and the kext will not match or load.
#
# Output: build-noxcode.XXXXXX/IntelLucy.kext (a fresh directory per build; old ones are
#         kept). The path of the newest build is written to latest-noxcode-build.txt.
# Note: this script only builds. It does not deploy, and it does not touch
#       /Library/Extensions or any kernel collection.
set -eu

[ "$(uname -s)" = "Darwin" ] || { echo "This script can only run on macOS" >&2; exit 1; }

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SRC=${1:-$ROOT}
SRC=$(CDPATH= cd -- "$SRC" && pwd)
DRV="$SRC/IntelLucy"
PROJ="$SRC/IntelLucy.xcodeproj/project.pbxproj"
NAME=IntelLucy
PCH="$DRV/IntelLucy-Prefix.pch"

echo "== Environment =="
echo "source : $SRC"
xcrun clang++ --version | head -1
echo "sdk(CLT): $(xcrun --sdk macosx --show-sdk-version)"

# ---- Source files: mirror the target's "Sources" build phase ----
CPP_SOURCES="IntelLucy IntelLucySupport IntelLucyServiceTask IntelLucyHardware \
IntelLucyRxTx IntelLucySetup IntelLucyPhy IntelLucyVTD IntelLucyRxPool"
C_SOURCES="ixgbe_main ixgbe_82598 ixgbe_phy ixgbe_dcb_82598 ixgbe_lib ixgbe_common \
ixgbe_dcb_82599 ixgbe_82599 ixgbe_x540 ixgbe_x550 ixgbe_mbx ixgbe_ethtool"

[ -d "$DRV" ] || { echo "Source directory not found: $DRV" >&2; exit 1; }
for name in $CPP_SOURCES; do
    [ -f "$DRV/$name.cpp" ] || { echo "Missing source file: $name.cpp" >&2; exit 1; }
done
for name in $C_SOURCES; do
    [ -f "$DRV/$name.c" ] || { echo "Missing source file: $name.c" >&2; exit 1; }
done
[ -f "$DRV/Info.plist" ] || { echo "Missing file: Info.plist" >&2; exit 1; }
[ -f "$PCH" ] || { echo "Missing prefix header: $PCH" >&2; exit 1; }
command -v c++filt >/dev/null 2>&1 || { echo "c++filt not found" >&2; exit 1; }

# ---- Version / identity: read them from the project so the kext matches the source ----
CURVER=1.1.600
MKTVER=1.1.6
MODVER=1.1.600
BUNDLE_ID=com.insanelymac.IntelLucy
if [ -f "$PROJ" ]; then
    v=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' "$PROJ" | head -1)
    if [ -n "$v" ]; then CURVER=$v; fi
    v=$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$PROJ" | head -1)
    if [ -n "$v" ]; then MKTVER=$v; fi
    v=$(sed -n 's/^[[:space:]]*MODULE_VERSION = \([^;]*\);.*/\1/p' "$PROJ" | head -1)
    case "$v" in
        '')             ;;
        '$CURRENT_PROJECT_VERSION'|'$(CURRENT_PROJECT_VERSION)') MODVER=$CURVER ;;
        *)              MODVER=$v ;;
    esac
    v=$(sed -n 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = \([^;]*\);.*/\1/p' "$PROJ" | head -1)
    if [ -n "$v" ]; then BUNDLE_ID=$v; fi
fi
echo "bundle : $BUNDLE_ID"
echo "version: $CURVER (marketing $MKTVER, kmod $MODVER)"

# ---- Locate MacKernelSDK: the project vendors one, which is the default ----
SDK=${2:-${MACKERNELSDK:-}}
if [ -z "$SDK" ]; then
    if [ -d "$SRC/MacKernelSDK/Headers" ]; then
        SDK="$SRC/MacKernelSDK"
    else
        for cand in "$HOME"/MacKernelSDK "$HOME"/src/MacKernelSDK; do
            if [ -d "$cand/Headers" ]; then SDK=$cand; break; fi
        done
    fi
fi
[ -n "$SDK" ] || { echo "MacKernelSDK not found; pass it as the second argument or set MACKERNELSDK" >&2; exit 1; }
SDK=$(CDPATH= cd -- "$SDK" && pwd)
[ -d "$SDK/Headers/IOKit" ] || { echo "MacKernelSDK headers are incomplete: $SDK" >&2; exit 1; }
[ -f "$SDK/Library/universal/libkmodc++.a" ] || { echo "Missing libkmodc++.a" >&2; exit 1; }
[ -f "$SDK/Library/x86_64/libkmod.a" ] || { echo "Missing libkmod.a (x86_64)" >&2; exit 1; }
echo "kernel SDK: $SDK"

# ---- Build directory: new one per build, previous outputs are preserved ----
W=$(mktemp -d "$ROOT/build-noxcode.XXXXXX")
KEXT="$W/$NAME.kext"
BIN="$KEXT/Contents/MacOS/$NAME"
INFO="$KEXT/Contents/Info.plist"
mkdir -p "$W/objects" "$KEXT/Contents/MacOS"
echo "work   : $W"

# ---- kmod_info ----
# xcodebuild generates this translation unit through CreateKModInfo.perl. Bypassing Xcode
# means providing it here, otherwise the binary has no _kmod_info and the kext is rejected.
KMOD="$W/kmod-info.cpp"
cat > "$KMOD" <<'KMOD_EOF'
#include <mach/kmod.h>
#include <libkern/OSKextLib.h>

extern "C" {
extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);

KMOD_EXPLICIT_DECL(com.insanelymac.IntelLucy, "@VERSION@", _start, _stop);

__attribute__((visibility("hidden"))) kmod_start_func_t *_realmain = nullptr;
__attribute__((visibility("hidden"))) kmod_stop_func_t  *_antimain = nullptr;
__attribute__((visibility("hidden"))) int _kext_apple_cc = __APPLE_CC__;
}
KMOD_EOF
sed "s/@VERSION@/$MODVER/" "$KMOD" > "$KMOD.tmp"
mv "$KMOD.tmp" "$KMOD"

# ---- Compiler flags ----
# Mirror the target: x86_64, c++17 (CLANG_CXX_LANGUAGE_STANDARD) and gnu17 for C, the
# IntelLucy prefix header, MacKernelSDK headers. -O0 is what the project's Debug
# configuration uses; pass OPT=-Os for a Release-style build. DEBUG=1 enables the driver's
# own DebugLog chatter (the project sets DEBUG=1 only in its Debug configuration).
OPT=${OPT:--O0}
CFLAGS_COMMON="-arch x86_64 -mkernel -fapple-kext -mno-red-zone \
 -nostdinc++ $OPT \
 -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -D__APPLE_KEXT__ \
 ${DEBUG:+-DDEBUG=1} \
 -fno-builtin -fno-common -fno-exceptions -fno-rtti \
 -fstack-protector -fno-threadsafe-statics \
 -Wno-unused-parameter -Wno-unused-function"
CFLAGS="$CFLAGS_COMMON -std=c++17"
CFLAGS_C="$CFLAGS_COMMON -std=gnu17"
INCLUDES="-I $SDK/Headers -I $DRV"

compile_cpp() {
    echo "  CXX $(basename "$1")"
    # shellcheck disable=SC2086
    xcrun clang++ $CFLAGS $INCLUDES -include "$PCH" -c "$1" -o "$2"
}

compile_c() {
    echo "  CC  $(basename "$1")"
    # shellcheck disable=SC2086
    xcrun clang $CFLAGS_C $INCLUDES -include "$PCH" -c "$1" -o "$2"
}

echo "== Compilation =="
for name in $CPP_SOURCES; do
    compile_cpp "$DRV/$name.cpp" "$W/objects/$name.o"
done
for name in $C_SOURCES; do
    compile_c "$DRV/$name.c" "$W/objects/$name.o"
done
compile_cpp "$KMOD" "$W/objects/kmod-info.o"

echo "== Linking =="
# -kext leaves kernel symbols undefined on purpose (resolved at load), so the driver's own
# symbols have to be checked separately below.
# shellcheck disable=SC2086
xcrun ld -kext -arch x86_64 "$W"/objects/*.o \
    "$SDK/Library/universal/libkmodc++.a" \
    "$SDK/Library/x86_64/libkmod.a" \
    -o "$BIN"

echo "== Bundle validation =="
nm "$BIN" > "$W/symbols.txt"
for sym in ' _kmod_info$' ' __start$' ' __stop$'; do
    grep -q "$sym" "$W/symbols.txt" || { echo "Missing symbol: $sym" >&2; exit 1; }
done
FT=$(otool -h "$BIN" | awk 'NR>1{print $5}' | tail -1)
[ "$FT" = "11" ] || { echo "filetype=$FT; expected 11 (MH_KEXT_BUNDLE)" >&2; exit 1; }
echo "  MH_KEXT_BUNDLE OK"
# IntelLucy.hpp declares getMinPacketSize() as an override but no translation unit defines
# it. The released 1.1.6 kext carries exactly that one undefined symbol too, so this is a
# property of the source tree, not of this build: whitelist it (it is never called) and
# still fail on anything else that should have come from the driver's own sources.
if nm -u "$BIN" | c++filt | grep -E '(^| )IntelLucy::|(^| )_ixgbe_|IntelLucyRxPool' \
        | grep -v 'IntelLucy::getMinPacketSize' > "$W/unresolved.txt"; then
    echo "Unresolved driver-internal symbols (a source file may be missing):" >&2
    cat "$W/unresolved.txt" >&2
    exit 1
fi
echo "  All driver-internal symbols are defined: OK"

echo "== Info.plist =="
# The checked-in plist only carries the personalities; the bundle keys come from
# GENERATE_INFOPLIST_FILE and have to be synthesised here.
sed -e "s/\${PRODUCT_NAME:rfc1034identifier}/$NAME/g" \
    -e "s/\${PRODUCT_NAME}/$NAME/g" \
    -e "s/\$(PRODUCT_NAME)/$NAME/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$CURVER/g" \
    -e "s/\$(MARKETING_VERSION)/$MKTVER/g" \
    -e "s/\$MODULE_VERSION/$MODVER/g" \
    -e "s/\$(MODULE_VERSION)/$MODVER/g" \
    "$DRV/Info.plist" > "$INFO"

plist_key() {
    key=$1
    type=$2
    value=$3
    if /usr/libexec/PlistBuddy -c "Print :$key" "$INFO" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :$key $value" "$INFO"
    else
        /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$INFO"
    fi
}

plist_key CFBundleDevelopmentRegion string en
plist_key CFBundleExecutable string "$NAME"
plist_key CFBundleIdentifier string "$BUNDLE_ID"
plist_key CFBundleInfoDictionaryVersion string 6.0
plist_key CFBundleName string "$NAME"
plist_key CFBundlePackageType string KEXT
plist_key CFBundleShortVersionString string "$MKTVER"
plist_key CFBundleVersion string "$CURVER"
plist_key NSHumanReadableCopyright string "Copyright © 2024 Laura Müller. All rights reserved."

plutil -lint "$INFO"
if grep -E '\$\{|\$\(|\$MODULE_VERSION|MARKETING_VERSION' "$INFO" >/dev/null; then
    echo "Info.plist still contains unexpanded Xcode variables" >&2
    exit 1
fi

echo "== Signing (ad hoc) =="
codesign --force --sign - --timestamp=none "$KEXT"
codesign --verify --strict "$KEXT"

printf '%s\n' "$KEXT" > "$ROOT/latest-noxcode-build.txt"
echo
echo "BUILD OK: $KEXT ($NAME $CURVER)"
echo "Not deployed: /Library/Extensions and kernel collections were not modified."

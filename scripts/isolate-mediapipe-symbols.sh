#!/usr/bin/env bash
#
# isolate-mediapipe-symbols.sh
#
# Merges one slice of MediaPipe (Vision + Common + the static graph archive)
# into a single relocatable object in which only MediaPipe's public Objective-C
# API (MPP*) stays global. Everything else MediaPipe carries (glog, gflags,
# protobuf, absl, OpenCV, TensorFlow Lite) becomes local, so it can never clash
# with the same libraries in the host app.
#
# Why: React Native compiles every LOG(...) against glog 0.3.5. MediaPipe's
# archives export their own newer glog. Linked into one binary the two mix
# (glog 0.3.5's LogMessage with the newer LogToSinks) and the first React
# Native log on iOS aborts the app (2026-11-20, UIManagerBinding::dispatchEventToJS).
# The same applies to any app that links its own protobuf, absl or OpenCV.
#
# Link semantics match what an app link of the upstream pods does:
#   -force_load Vision      (all of its ObjC API)
#   -force_load graph       (the upstream podspec force_loads it: calculator
#                            registrations live in static initialisers)
#   Common, lazily          (only the members something needs)
#   -ObjC                   (CocoaPods adds it to every app: ObjC categories
#                            have no symbol references, e.g. MPPTaskInfo's
#                            generateGraphConfigWithError:)
#   -u <Common's MPP API>   (classes the SDK uses directly from Common)
#
# Usage: isolate-mediapipe-symbols.sh <common-bin> <vision-bin> <graph.a> <arch> <platform> <out.o>
#   platform: ios | ios-simulator
set -euo pipefail

COMMON=$1; VISION=$2; GRAPH=$3; ARCH=$4; PLATFORM=$5; OUT=$6

case "$PLATFORM" in
  ios)           SDK=iphoneos ;;
  ios-simulator) SDK=iphonesimulator ;;
  *) echo "ERROR: unknown platform $PLATFORM" >&2; exit 1 ;;
esac
SDK_VERSION="$(xcrun --sdk "$SDK" --show-sdk-version)"
MIN_VERSION="${IOS_DEPLOYMENT_TARGET:-15.0}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

thin() {
  if [ "$(lipo -archs "$1" | wc -w)" -gt 1 ]; then
    lipo "$1" -thin "$ARCH" -output "$T/$2"
  else
    cp "$1" "$T/$2"
  fi
}
thin "$COMMON" common.a
thin "$VISION" vision.a
thin "$GRAPH" graph.a

# Only MediaPipe's public API stays global.
cat > "$T/keep.txt" <<'EOF'
_OBJC_CLASS_$_MPP*
_OBJC_METACLASS_$_MPP*
_MPP*
_kMPP*
EOF

FORCE=()
while IFS= read -r sym; do FORCE+=(-u "$sym"); done < <(
  nm -gUj "$T/common.a" 2>/dev/null | grep -E '^(_OBJC_CLASS_\$_MPP|_MPP|_kMPP)' | sort -u
)

xcrun ld -r -arch "$ARCH" -platform_version "$PLATFORM" "$MIN_VERSION" "$SDK_VERSION" \
  -ObjC \
  -force_load "$T/vision.a" \
  -force_load "$T/graph.a" \
  "$T/common.a" \
  "${FORCE[@]}" \
  -exported_symbols_list "$T/keep.txt" \
  -o "$OUT" 2>&1 | grep -vE "no platform load command|was built for newer" || true

[ -f "$OUT" ] || { echo "ERROR: ld -r produced no output for $ARCH/$PLATFORM" >&2; exit 1; }

# Guard: nothing but MediaPipe's API may be global, and nothing internal may be
# left undefined (that would mean a member we needed was not pulled in).
leaked="$(nm -gU "$OUT" | awk '{print $3}' | grep -vE '^(_OBJC_CLASS_\$_MPP|_OBJC_METACLASS_\$_MPP|_MPP|_kMPP)' || true)"
if [ -n "$leaked" ]; then
  echo "ERROR: non-MediaPipe symbols still global in $ARCH/$PLATFORM:" >&2
  echo "$leaked" | head -20 >&2
  exit 1
fi
missing="$(nm -u "$OUT" | grep -E '__ZN6google|absl|tflite|__ZN2cv|__ZN9mediapipe' || true)"
if [ -n "$missing" ]; then
  echo "ERROR: MediaPipe internals left undefined in $ARCH/$PLATFORM:" >&2
  echo "$missing" | head -20 >&2
  exit 1
fi
echo "    isolated $ARCH/$PLATFORM: $(nm -gU "$OUT" | grep -c 'OBJC_CLASS_\$_MPP') MPP classes global, internals local"

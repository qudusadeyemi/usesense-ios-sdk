#!/usr/bin/env bash
#
# vendor-mediapipe.sh
#
# Produces the patched MediaPipe xcframework bundle that UseSenseMediaPipe.podspec
# distributes, so integrators get on-device face mesh WITHOUT adding the
# MediaPipeTasksVision pod + a pre_install Info.plist patch to their own Podfile.
#
# Why this exists: Google's MediaPipeTasks{Common,Vision}.xcframework ship with a
# broken top-level Info.plist -- `AvailableLibraries[].LibraryPath` is declared as
# "<NAME>.a" but the file on disk is a "<NAME>.framework/" directory. CocoaPods
# trusts the plist, classifies the xcframework as a static library, and emits a
# `-l<NAME>` linker flag that fails with `ld: library '<NAME>' not found`. We patch
# the plist once, centrally, and vendor the corrected xcframeworks via our own pod.
#
# This is the same .a -> .framework fix the SDK Example's pre_install hook applies,
# lifted out of every integrator's Podfile and done once at release time.
#
# Runs on macOS CI (needs CocoaPods + curl + unzip). Output:
#   <out>/UseSenseMediaPipe.xcframeworks.zip   (attached to the GitHub Release)
#   <out>/checksum.txt                         (sha256 of the zip, for provenance)
#
# Usage: scripts/vendor-mediapipe.sh [output-dir]
set -euo pipefail

# The set of MediaPipe pods whose xcframeworks the face-mesh feature links. This
# mirrors the pods the proven Example/Podfile pre_install hook patches. If a
# future MediaPipe release splits out more xcframeworks, add them here.
PODS=(MediaPipeTasksVision MediaPipeTasksCommon)
MEDIAPIPE_VERSION="${MEDIAPIPE_VERSION:-0.10.21}"

OUT_DIR="${1:-$PWD/build/mediapipe}"
mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/UseSenseMediaPipe.xcframeworks.zip"

# Idempotent: skip the (large) download + repackage if the bundle already exists.
# Delete the output dir to force a rebuild.
if [ -f "$ZIP" ]; then
  echo "==> $ZIP already exists; skipping rebuild (delete it to force)."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE"

echo "==> Vendoring MediaPipe ${MEDIAPIPE_VERSION} (pods: ${PODS[*]})"

# Resolve each pod's binary (http) source from its podspec and download it
# directly -- no `pod install` / Xcode project needed, since we only repackage
# the prebuilt xcframeworks. Read the podspec straight from the CocoaPods CDN
# (md5-sharded `Specs/<a>/<b>/<c>/<name>/<ver>/<name>.podspec.json`) via curl,
# rather than `pod spec cat`, which needs a cloned trunk spec repo that fresh
# CI runners don't have (they use the CDN).
for pod in "${PODS[@]}"; do
  echo "==> Resolving ${pod} ${MEDIAPIPE_VERSION} source URL"
  shard="$(python3 -c "import hashlib,sys;print('/'.join(hashlib.md5(sys.argv[1].encode()).hexdigest()[0:3]))" "$pod")"
  spec_url="https://cdn.cocoapods.org/Specs/${shard}/${pod}/${MEDIAPIPE_VERSION}/${pod}.podspec.json"
  curl -fsSL "$spec_url" -o "$WORK/${pod}.podspec.json"
  url="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['source']['http'])" "$WORK/${pod}.podspec.json")"
  if [ -z "$url" ]; then
    echo "ERROR: could not resolve http source for ${pod}" >&2
    exit 1
  fi
  echo "    ${url}"
  archive="$WORK/${pod}-$(basename "$url")"
  curl -fSL "$url" -o "$archive"
  mkdir -p "$WORK/${pod}"
  # Google distributes these pods as .tar.gz; handle the common archive types
  # rather than assuming a single format.
  case "$url" in
    *.tar.gz|*.tgz)  tar -xzf "$archive" -C "$WORK/${pod}" ;;
    *.tar.bz2|*.tbz) tar -xjf "$archive" -C "$WORK/${pod}" ;;
    *.tar)           tar -xf  "$archive" -C "$WORK/${pod}" ;;
    *.zip)           unzip -q "$archive" -d "$WORK/${pod}" ;;
    *) echo "ERROR: unknown archive type for ${url}" >&2; exit 1 ;;
  esac
done

# Patch every xcframework's top-level Info.plist: LibraryPath "<NAME>.a" -> the
# real "<NAME>.framework", then stage the corrected xcframework for packaging.
# (macOS ships bash 3.2 with no `globstar`, so enumerate with `find`. Reading via
# process substitution keeps the loop in the current shell so `patched` persists.)
patched=0
while IFS= read -r fw; do
  [ -d "$fw" ] || continue
  name="$(basename "$fw" .xcframework)"
  plist="$fw/Info.plist"
  if [ -f "$plist" ]; then
    # plutil round-trips the binary/xml plist; sed does the targeted swap.
    plutil -convert xml1 "$plist"
    if grep -q "<string>${name}.a</string>" "$plist"; then
      sed -i '' "s|<string>${name}.a</string>|<string>${name}.framework</string>|g" "$plist"
      echo "    patched LibraryPath .a -> .framework in ${name}.xcframework"
    fi
  fi
  # De-dupe: a pod can transitively include another's xcframework.
  if [ ! -d "$STAGE/$(basename "$fw")" ]; then
    cp -R "$fw" "$STAGE/"
    patched=$((patched + 1))
  fi
done < <(find "$WORK" -type d -name '*.xcframework')

if [ "$patched" -eq 0 ]; then
  echo "ERROR: no xcframeworks found to vendor" >&2
  exit 1
fi
echo "==> Staged ${patched} xcframework(s): $(cd "$STAGE" && echo *)"

# MediaPipeTasksCommon also ships two prebuilt static graph archives (device +
# simulator) that the upstream podspec -force_loads. Rather than ship them and
# make every app link MediaPipe's glog, protobuf, absl, OpenCV and TFLite as
# global symbols (which crashes React Native apps on iOS: they link their own
# glog), merge each slice into one object whose only global symbols are
# MediaPipe's MPP* API. See scripts/isolate-mediapipe-symbols.sh.
graph_dir="$(find "$WORK" -type d -name 'graph_libraries' | head -1)"
if [ -z "$graph_dir" ]; then
  echo "ERROR: graph_libraries/ not found; MediaPipeTasksCommon force-loads it" >&2
  exit 1
fi
ISOLATE="$(cd "$(dirname "$0")" && pwd)/isolate-mediapipe-symbols.sh"
ISO="$WORK/isolated"
mkdir -p "$ISO"
echo 'static int usesense_mediapipe_placeholder __attribute__((unused));' > "$ISO/empty.c"

isolate_slice() {
  # isolate_slice <slice-dir> <graph.a> <platform> <sdk> <archs...>
  local slice=$1 graph=$2 platform=$3 sdk=$4; shift 4
  local common="$STAGE/MediaPipeTasksCommon.xcframework/$slice/MediaPipeTasksCommon.framework/MediaPipeTasksCommon"
  local vision="$STAGE/MediaPipeTasksVision.xcframework/$slice/MediaPipeTasksVision.framework/MediaPipeTasksVision"
  local vis_parts=() com_parts=() arch
  for arch in "$@"; do
    bash "$ISOLATE" "$common" "$vision" "$graph" "$arch" "$platform" "$ISO/$slice-$arch.o"
    xcrun ar rcs "$ISO/$slice-$arch-vision.a" "$ISO/$slice-$arch.o"
    # Common keeps its headers and module map; its code now lives in Vision's
    # merged object, so its binary becomes an archive with one empty member.
    local target="$arch-apple-ios${IOS_DEPLOYMENT_TARGET:-15.0}"
    [ "$platform" = ios-simulator ] && target="$target-simulator"
    xcrun -sdk "$sdk" clang -c -target "$target" "$ISO/empty.c" -o "$ISO/$slice-$arch-empty.o"
    xcrun ar rcs "$ISO/$slice-$arch-common.a" "$ISO/$slice-$arch-empty.o" 2>/dev/null
    vis_parts+=("$ISO/$slice-$arch-vision.a"); com_parts+=("$ISO/$slice-$arch-common.a")
  done
  lipo -create "${vis_parts[@]}" -output "$vision"
  lipo -create "${com_parts[@]}" -output "$common"
}

echo "==> Isolating MediaPipe symbols (only MPP* stays global)"
isolate_slice ios-arm64 "$graph_dir/libMediaPipeTasksCommon_device_graph.a" ios iphoneos arm64
isolate_slice ios-arm64_x86_64-simulator "$graph_dir/libMediaPipeTasksCommon_simulator_graph.a" ios-simulator iphonesimulator arm64 x86_64

# Apache-2.0 requires the upstream LICENSE to travel with the binaries.
license="$(find "$WORK" -name 'LICENSE' | head -1)"
if [ -n "$license" ]; then cp "$license" "$STAGE/LICENSE"; fi

# Bundle a short provenance note alongside the binaries + license.
cat > "$STAGE/MEDIAPIPE_NOTICE.txt" <<EOF
These xcframeworks are Google's MediaPipe Tasks (MediaPipeTasksVision,
MediaPipeTasksCommon), version ${MEDIAPIPE_VERSION}, redistributed under the
Apache License 2.0. Modifications: each xcframework's top-level Info.plist
LibraryPath is corrected ("<NAME>.a" -> "<NAME>.framework") so CocoaPods links
them as frameworks; and each slice's Vision, Common and graph archives are merged
into one object (inside MediaPipeTasksVision) whose only global symbols are the
MPP* API, so MediaPipe's bundled glog, protobuf, absl, OpenCV and TensorFlow Lite
cannot clash with the host app's. Source: https://github.com/google-ai-edge/mediapipe
EOF

ZIP="$OUT_DIR/UseSenseMediaPipe.xcframeworks.zip"
rm -f "$ZIP"
( cd "$STAGE" && zip -qry "$ZIP" . )
shasum -a 256 "$ZIP" | tee "$OUT_DIR/checksum.txt"
echo "==> Wrote $ZIP"

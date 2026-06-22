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

# Resolve each pod's binary (http) source from its published podspec and download
# it directly -- no `pod install` / Xcode project needed, since we only repackage
# the prebuilt xcframeworks.
for pod in "${PODS[@]}"; do
  echo "==> Resolving ${pod} ${MEDIAPIPE_VERSION} source URL"
  spec_json="$(pod spec cat "${pod}" --version="${MEDIAPIPE_VERSION}" 2>/dev/null \
    || pod spec cat "${pod}")"
  url="$(printf '%s' "$spec_json" | python3 -c \
    'import sys,json; print(json.load(sys.stdin)["source"]["http"])')"
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

# MediaPipeTasksCommon force-loads two prebuilt static graph archives
# (device + simulator) that carry the actual graph runtime symbols the
# xcframeworks reference. The upstream podspec pulls them in via an
# OTHER_LDFLAGS -force_load; UseSenseMediaPipe.podspec replicates that, so we
# must ship the archives at the bundle root under graph_libraries/.
graph_dir="$(find "$WORK" -type d -name 'graph_libraries' | head -1)"
if [ -z "$graph_dir" ]; then
  echo "ERROR: graph_libraries/ not found — MediaPipeTasksCommon force-loads it" >&2
  exit 1
fi
mkdir -p "$STAGE/graph_libraries"
cp "$graph_dir"/*.a "$STAGE/graph_libraries/"
echo "==> Staged graph_libraries: $(cd "$STAGE/graph_libraries" && echo *)"

# Apache-2.0 requires the upstream LICENSE to travel with the binaries.
license="$(find "$WORK" -name 'LICENSE' | head -1)"
if [ -n "$license" ]; then cp "$license" "$STAGE/LICENSE"; fi

# Bundle a short provenance note alongside the binaries + license.
cat > "$STAGE/MEDIAPIPE_NOTICE.txt" <<EOF
These xcframeworks are Google's MediaPipe Tasks (MediaPipeTasksVision,
MediaPipeTasksCommon), version ${MEDIAPIPE_VERSION}, redistributed under the
Apache License 2.0. The only modification is a correction to each xcframework's
top-level Info.plist LibraryPath ("<NAME>.a" -> "<NAME>.framework") so CocoaPods
links them as frameworks. Source: https://github.com/google-ai-edge/mediapipe
EOF

ZIP="$OUT_DIR/UseSenseMediaPipe.xcframeworks.zip"
rm -f "$ZIP"
( cd "$STAGE" && zip -qry "$ZIP" . )
shasum -a 256 "$ZIP" | tee "$OUT_DIR/checksum.txt"
echo "==> Wrote $ZIP"

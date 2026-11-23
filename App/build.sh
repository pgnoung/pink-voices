#!/bin/zsh
set -euo pipefail
root="${0:A:h}"
build="$root/build"
app_name="$(/usr/libexec/PlistBuddy -c "Print CFBundleName" "$root/Info.plist")"
out="$build/$app_name.app"
mkdir -p "$build"
stage="$(mktemp -d "$build/.pink-voices.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/$app_name.app"
iconset="$stage/AppIcon.iconset"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$iconset"

flags=()
swiftc -O -target arm64-apple-macosx13.0 "${flags[@]}" -framework Cocoa -framework AVFoundation -framework WebKit -framework ApplicationServices -framework Carbon -framework ServiceManagement -framework Network "$root"/Sources/*.swift -o "$bundle/Contents/MacOS/ThaiDictation"
cp "$root/Info.plist" "$bundle/Contents/Info.plist"
glossary="$root/Resources/brand-context.json"
cp "$glossary" "$bundle/Contents/Resources/brand-context.json"
# Local AI setup files the app copies to Application Support on first run (no engine, no model).
mkdir -p "$bundle/Contents/Resources/LocalAI"
asr="$root/../ASR"
cp "$asr"/{setup.sh,start.sh,runtime-versions.txt,model.sha256,MODEL_SOURCE.md,LICENSE-MODEL-OpenMDW-1.1.txt} "$bundle/Contents/Resources/LocalAI/"
cp "$asr"/{local_dictation,dictation_text,final_scoring,plaud_vocabulary,protected_text,thai_numbers}.py "$bundle/Contents/Resources/LocalAI/"
for side in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$(( side * scale ))
        suffix=""
        if (( scale == 2 )); then suffix="@2x"; fi
        /usr/bin/sips -z "$pixels" "$pixels" "$root/Resources/AppIcon.png" --out "$iconset/icon_${side}x${side}${suffix}.png" >/dev/null
    done
done
/usr/bin/iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
# A consistent local development signer lets macOS recognize subsequent updates.
sign_args=(--force --sign "${PINK_VOICES_SIGN_IDENTITY:--}")
if [[ "${PINK_VOICES_RELEASE:-0}" == 1 ]]; then
    # Notarization needs the hardened runtime, a secure timestamp and the mic entitlement.
    sign_args+=(--options runtime --timestamp --entitlements "$root/PinkVoices.entitlements")
else
    sign_args+=(--timestamp=none)
fi
/usr/bin/codesign "${sign_args[@]}" "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
# Replace only a completed build. The original Thai Dictation bundle is kept separately.
if [[ -d "$out" ]]; then
    mv "$out" "$stage/previous.app"
    if ! mv "$bundle" "$out"; then
        mv "$stage/previous.app" "$out"
        exit 1
    fi
else
    mv "$bundle" "$out"
fi
print -r -- "$out"

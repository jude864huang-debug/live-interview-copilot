#!/usr/bin/env bash
set -euo pipefail

# Build macOS .app for Live Interview Copilot (Swift)
# Usage:
#   ./scripts/build_swift_app.sh
#
# For CI / explicit identity:
#   CODESIGN_IDENTITY="Developer ID Application: ..." ./scripts/build_swift_app.sh
#
# For smoke checks without code signing or installation:
#   SKIP_SIGN=1 SKIP_INSTALL=1 ./scripts/build_swift_app.sh
# For formal distribution (fails closed on missing runtime/signing/update config):
#   RELEASE_BUILD=1 CODESIGN_IDENTITY="Developer ID Application: ..." \
#     SPARKLE_FEED_URL="https://.../appcast.xml" \
#     SPARKLE_PUBLIC_ED_KEY="..." ./scripts/build_swift_app.sh
#
# Extra SwiftPM flags can be supplied for local toolchain compatibility:
#   SWIFT_BUILD_FLAGS="--disable-sandbox ..." ./scripts/build_swift_app.sh
# To package a verified debug binary when the local release toolchain is
# temporarily unavailable:
#   APP_BUILD_CONFIGURATION=debug ./scripts/build_swift_app.sh
#
# The bundle version is derived from the latest git tag; override explicitly with:
#   APP_VERSION=1.82.0 ./scripts/build_swift_app.sh
#
# For notarization:
#   APPLE_ID="name@example.com"
#   APPLE_TEAM_ID="TEAMID123"
#   APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
SWIFT_DIR="$ROOT_DIR/LiveInterviewCopilot"
APP_NAME="Live Interview Copilot"
APP_EXECUTABLE_NAME="OpenOats"
BUNDLE_ID="com.openoats.app"
SKIP_SIGN="${SKIP_SIGN:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
RELEASE_BUILD="${RELEASE_BUILD:-0}"
REQUIRE_CODEX_WORKER="${REQUIRE_CODEX_WORKER:-$RELEASE_BUILD}"
APP_BUILD_CONFIGURATION="${APP_BUILD_CONFIGURATION:-release}"

for flag_name in SKIP_SIGN SKIP_INSTALL RELEASE_BUILD REQUIRE_CODEX_WORKER; do
  flag_value="${!flag_name}"
  if [[ "$flag_value" != "0" && "$flag_value" != "1" ]]; then
    echo "Invalid $flag_name: $flag_value (expected 0 or 1)"
    exit 1
  fi
done

if [[ "$RELEASE_BUILD" == "1" && "$SKIP_SIGN" == "1" ]]; then
  echo "Release builds cannot skip code signing"
  exit 1
fi

if [[ "$RELEASE_BUILD" == "1" && ( -z "${SPARKLE_FEED_URL:-}" || -z "${SPARKLE_PUBLIC_ED_KEY:-}" ) ]]; then
  echo "Release builds require SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY"
  exit 1
fi

case "$APP_BUILD_CONFIGURATION" in
  debug|release) ;;
  *)
    echo "Invalid APP_BUILD_CONFIGURATION: $APP_BUILD_CONFIGURATION (expected debug or release)"
    exit 1
    ;;
esac

echo "=== Building $APP_NAME (Swift) ==="

# Build release binary
cd "$SWIFT_DIR"
SWIFT_BUILD_ARGS=()
if [[ -n "${SWIFT_BUILD_FLAGS:-}" ]]; then
  # This is intentionally a developer-controlled flag list, not user input.
  read -r -a SWIFT_BUILD_ARGS <<< "$SWIFT_BUILD_FLAGS"
fi
if [[ ${#SWIFT_BUILD_ARGS[@]} -gt 0 ]]; then
  swift build -c "$APP_BUILD_CONFIGURATION" "${SWIFT_BUILD_ARGS[@]}" 2>&1
else
  # macOS still ships Bash 3.2, where expanding an empty array while `set -u`
  # is enabled raises "unbound variable" instead of producing zero arguments.
  swift build -c "$APP_BUILD_CONFIGURATION" 2>&1
fi
BINARY_PATH=".build/$APP_BUILD_CONFIGURATION/LiveInterviewCopilot"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Build failed: binary not found at $BINARY_PATH"
  exit 1
fi

echo "Binary built: $BINARY_PATH"

# Create .app bundle
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

# Copy binary
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"

# Make the SwiftPM-built executable behave like a normal app bundle by
# teaching dyld to search the app's embedded Frameworks directory.
APP_BINARY="$APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
if ! otool -l "$APP_BINARY" | grep -Fq "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
  echo "Added app Frameworks rpath to executable"
fi

# Copy Info.plist
cp "$SWIFT_DIR/Sources/LiveInterviewCopilot/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ "$RELEASE_BUILD" == "1" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED_URL" "$APP_DIR/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$APP_DIR/Contents/Info.plist"
  echo "Configured release update feed"
fi

# Stamp the bundle version into the built app. The source Info.plist carries a
# placeholder version; release builds overwrite it from the tag in CI
# (release-dmg.yml). Mirror that for local builds by deriving the version from the
# latest git tag (override with APP_VERSION=...). Without this, local builds report
# the stale placeholder and Sparkle prompts to update on every launch.
if [[ -z "${APP_VERSION:-}" ]]; then
  TAG="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
  APP_VERSION="${TAG#v}"
fi
if [[ -n "$APP_VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_DIR/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$APP_DIR/Contents/Info.plist"
  echo "Set bundle version to $APP_VERSION"
else
  echo "Warning: no git tag found and APP_VERSION unset; bundle keeps placeholder version"
fi

# Copy app icon
ICON_PATH="$SWIFT_DIR/Sources/LiveInterviewCopilot/Assets/AppIcon.icns"
if [[ -f "$ICON_PATH" ]]; then
  cp "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"
  echo "App icon copied"
fi

# Bundle the subscription-backed Codex worker and its Node runtime so launching
# from Finder does not depend on an interactive shell or NVM PATH setup.
WORKER_DIR="$ROOT_DIR/worker"
WORKER_READY=1
for required_path in \
  "$WORKER_DIR/codex-worker.mjs" \
  "$WORKER_DIR/node_modules/@openai/codex-sdk/package.json" \
  "$WORKER_DIR/node_modules/@openai/codex/package.json"; do
  if [[ ! -e "$required_path" ]]; then
    WORKER_READY=0
  fi
done

if [[ "$WORKER_READY" == "1" ]]; then
  NODE_BINARY="$(command -v node || true)"
  if [[ -z "$NODE_BINARY" && "$REQUIRE_CODEX_WORKER" == "1" ]]; then
    echo "Required node executable was not found; cannot package the Codex worker"
    exit 1
  fi
  cp "$WORKER_DIR/codex-worker.mjs" "$APP_DIR/Contents/Resources/codex-worker.mjs"
  cp -R "$WORKER_DIR/node_modules" "$APP_DIR/Contents/Resources/node_modules"
  if [[ -n "$NODE_BINARY" ]]; then
    cp "$NODE_BINARY" "$APP_DIR/Contents/Resources/node"
    chmod +x "$APP_DIR/Contents/Resources/node"
  else
    echo "Warning: node executable not found; Codex worker will require node on PATH"
  fi
  echo "Codex worker copied"
else
  if [[ "$REQUIRE_CODEX_WORKER" == "1" ]]; then
    echo "Required Codex worker dependencies are missing; run npm ci in $WORKER_DIR"
    exit 1
  fi
  echo "Warning: run npm install in $WORKER_DIR before packaging"
fi

# Copy Sparkle framework
SPARKLE_ARTIFACT_DIR="$SWIFT_DIR/.build/artifacts/sparkle"
SPARKLE_FW=$(find "$SPARKLE_ARTIFACT_DIR" -name "Sparkle.framework" -type d 2>/dev/null | head -1)
if [[ -n "$SPARKLE_FW" ]]; then
  cp -R "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/"
  echo "Sparkle.framework copied"
else
  echo "Warning: Sparkle.framework not found in build artifacts"
fi

# Copy SPM resource bundles (needed by swift-transformers for tokenizer fallback configs)
COPIED_BUNDLES=0
while IFS= read -r -d '' bundle; do
  bundle_name="$(basename "$bundle")"
  destination="$APP_DIR/Contents/Resources/$bundle_name"
  rm -rf "$destination"
  cp -R "$bundle" "$destination"
  COPIED_BUNDLES=$((COPIED_BUNDLES + 1))
done < <(find "$SWIFT_DIR/.build" -path "*/$APP_BUILD_CONFIGURATION/*.bundle" -type d -print0)
if [[ $COPIED_BUNDLES -gt 0 ]]; then
  echo "Copied $COPIED_BUNDLES SPM resource bundle(s)"
else
  echo "Warning: no SPM resource bundles found under $SWIFT_DIR/.build"
fi

# Add PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "App bundle created: $APP_DIR"

if [[ "$SKIP_SIGN" == "1" ]]; then
  echo "Skipping code signing"
else
  # Auto-detect signing identity if not set
  if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    if [[ -z "$CODESIGN_IDENTITY" ]]; then
      CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    fi
  fi

  if [[ "$RELEASE_BUILD" == "1" && "${CODESIGN_IDENTITY:-}" != Developer\ ID\ Application:* ]]; then
    echo "Release builds require a Developer ID Application signing identity"
    exit 1
  fi

  # Sign the app
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    ENTITLEMENTS="$SWIFT_DIR/Sources/LiveInterviewCopilot/LiveInterviewCopilot.entitlements"
    echo "Signing with: $CODESIGN_IDENTITY"

    # Sign Sparkle components inside-out (innermost first)
    SPARKLE_FW_BUNDLE="$APP_DIR/Contents/Frameworks/Sparkle.framework"
    if [[ -d "$SPARKLE_FW_BUNDLE" ]]; then
      # Sign XPC service executables, then their bundles
      for xpc in "$SPARKLE_FW_BUNDLE"/Versions/B/XPCServices/*.xpc; do
        if [[ -d "$xpc" ]]; then
          codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$xpc/Contents/MacOS/$(basename "${xpc%.xpc}")"
          codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$xpc"
        fi
      done

      # Sign Autoupdate helper
      AUTOUPDATE="$SPARKLE_FW_BUNDLE/Versions/B/Autoupdate"
      if [[ -f "$AUTOUPDATE" ]]; then
        codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$AUTOUPDATE"
      fi

      # Sign Updater.app
      UPDATER_APP="$SPARKLE_FW_BUNDLE/Versions/B/Updater.app"
      if [[ -d "$UPDATER_APP" ]]; then
        codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$UPDATER_APP/Contents/MacOS/Updater"
        codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$UPDATER_APP"
      fi

      # Sign the framework dylib, then the framework bundle
      codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$SPARKLE_FW_BUNDLE/Versions/B/Sparkle"
      codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$SPARKLE_FW_BUNDLE"
    fi

    # Re-sign executable code bundled by the Codex npm package. Some small
    # helper binaries ship ad-hoc signed, which notarization rejects inside a
    # Developer ID app even though they work during local development.
    if [[ -d "$APP_DIR/Contents/Resources/node_modules" ]]; then
      while IFS= read -r -d '' bundled_executable; do
        if file -b "$bundled_executable" | grep -Fq "Mach-O"; then
          codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$bundled_executable"
        fi
      done < <(find "$APP_DIR/Contents/Resources/node_modules" -type f -perm -111 -print0)
    fi

    # Sign the Node runtime with the entitlements V8 needs under hardened
    # runtime, then sign the main app bundle.
    if [[ -f "$APP_DIR/Contents/Resources/node" ]]; then
      codesign --force --options runtime \
        --sign "$CODESIGN_IDENTITY" \
        --entitlements "$ROOT_DIR/scripts/node.entitlements" \
        --timestamp \
        "$APP_DIR/Contents/Resources/node"
    fi
    codesign --force --options runtime \
      --sign "$CODESIGN_IDENTITY" \
      --entitlements "$ENTITLEMENTS" \
      --timestamp \
      "$APP_DIR"

    echo "Code signing complete"
    codesign -vvv "$APP_DIR"
  else
    # A completely unsigned app has unreliable TCC behavior for microphone and
    # Documents access. Ad-hoc signing gives local development builds a proper
    # code identity even when no Apple signing certificate is installed.
    ENTITLEMENTS="$SWIFT_DIR/Sources/LiveInterviewCopilot/LiveInterviewCopilot.entitlements"
    echo "No Apple signing identity found; applying ad-hoc signature"
    if [[ -d "$APP_DIR/Contents/Frameworks/Sparkle.framework" ]]; then
      codesign --force --deep --sign - "$APP_DIR/Contents/Frameworks/Sparkle.framework"
    fi
    if [[ -f "$APP_DIR/Contents/Resources/node" ]]; then
      codesign --force --sign - "$APP_DIR/Contents/Resources/node"
    fi
    codesign --force --sign - \
      --requirements '=designated => identifier "com.openoats.app"' \
      --entitlements "$ENTITLEMENTS" \
      "$APP_DIR"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
  fi
fi

if [[ "$SKIP_INSTALL" == "1" ]]; then
  echo "Skipping installation to /Applications"
else
  INSTALL_PATH="/Applications/$APP_NAME.app"
  # Replacing the whole bundle avoids `cp -R` trying to overwrite
  # read-only files inside resource bundles from an older build.
  rm -rf "$INSTALL_PATH"
  ditto "$APP_DIR" "$INSTALL_PATH"
  echo "Installed to $INSTALL_PATH"
fi

echo "=== Build complete ==="

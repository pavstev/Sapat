#!/usr/bin/env bash
# Builds Šapat and wraps it into Sapat.app, ad-hoc signed ("Sign to Run Locally").
#
# Uses full Xcode (xcodebuild) when available — REQUIRED for the in-process MLX engine, whose
# Metal kernels only Xcode's toolchain compiles into default.metallib. Falls back to
# `swift build` under the Command Line Tools, which builds the engine-agnostic layers only
# (MLX is gated out via `#if canImport(MLXLLM)`, so the default engine is then LM Studio).
#
# Env overrides:
#   SAPAT_VERSION=1.2.3   stamp this version into the bundle (CI sets it from the tag)
#   SAPAT_UNIVERSAL=1     (swift-build fallback only) build a universal arm64+x86_64 binary
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Sapat"
APP="${APP_NAME}.app"

have_full_xcode() {
  xcodebuild -version >/dev/null 2>&1 && [[ "$(xcode-select -p 2>/dev/null)" != *CommandLineTools* ]]
}

if have_full_xcode; then
  echo "▶ Building with xcodebuild (in-process MLX engine enabled)…"
  command -v xcodegen >/dev/null 2>&1 || { echo "✗ xcodegen required: brew install xcodegen" >&2; exit 1; }
  xcodegen generate
  DERIVED="${PWD}/.build/xcode"
  # MLX is Apple-Silicon only, so the shippable build is arm64 (SAPAT_UNIVERSAL is ignored here).
  # -skip*Validation auto-trusts the mlx-swift build plugin + HuggingFace macros non-interactively.
  xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "${DERIVED}" \
    -skipPackagePluginValidation -skipMacroValidation build
  BUILT="${DERIVED}/Build/Products/Release/${APP}"
  if [[ ! -d "${BUILT}" ]]; then
    echo "✗ Built app not found at ${BUILT}" >&2
    exit 1
  fi
  rm -rf "${APP}"
  cp -R "${BUILT}" "${APP}"
else
  echo "▶ Building with swift build (Command Line Tools — MLX engine disabled)…"
  CONFIG="release"
  # Space-separated (not an array) so it's safe under macOS's bash 3.2, where expanding an
  # empty array with `set -u` errors out.
  ARCH_FLAGS=""
  if [[ "${SAPAT_UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
  fi

  # shellcheck disable=SC2086  # intentional word-splitting of the flag list
  swift build -c "${CONFIG}" ${ARCH_FLAGS}
  # shellcheck disable=SC2086
  BIN_DIR="$(swift build -c "${CONFIG}" ${ARCH_FLAGS} --show-bin-path)"
  BIN="${BIN_DIR}/${APP_NAME}"
  if [[ ! -x "${BIN}" ]]; then
    echo "✗ Built binary not found at ${BIN}" >&2
    exit 1
  fi

  echo "▶ Assembling ${APP}…"
  rm -rf "${APP}"
  mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
  cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
  cp Info.plist "${APP}/Contents/Info.plist"
  printf 'APPL????' > "${APP}/Contents/PkgInfo"
  if [[ -f Resources/Sapat.icns ]]; then
    cp Resources/Sapat.icns "${APP}/Contents/Resources/Sapat.icns"
  fi
  # Copy any SwiftPM resource bundles (Bundle.module) so they resolve inside the .app.
  shopt -s nullglob
  for bundle in "${BIN_DIR}"/*.bundle; do
    cp -R "${bundle}" "${APP}/Contents/Resources/"
  done
fi

# Stamp the release version (from the git tag in CI) so the in-app update check compares
# against an accurate current version.
if [[ -n "${SAPAT_VERSION:-}" ]]; then
  echo "▶ Stamping version ${SAPAT_VERSION}…"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${SAPAT_VERSION}" "${APP}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${SAPAT_VERSION}" "${APP}/Contents/Info.plist"
fi

# (Re-)ad-hoc sign — the version stamp above invalidates xcodebuild's signature.
echo "▶ Ad-hoc signing…"
codesign --force --sign - "${APP}"

echo "✓ Built ${APP}"
echo "   Run:     open ${APP}"
echo "   Install: cp -R ${APP} /Applications/ && open /Applications/${APP}"

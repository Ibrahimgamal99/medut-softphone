#!/usr/bin/env bash
# Builds Medut-SDK's Linux C library (medut.so) at the commit pubspec.yaml
# pins, into linux/medut/, where linux/CMakeLists.txt bundles it. The desktop
# engine (lib/desktop/engine.dart) loads it over dart:ffi.
#
#   scripts/desktop-sdk.sh                  clone the pinned commit from GitHub
#   MEDUT_SDK_DIR=../Medut-SDK scripts/desktop-sdk.sh
#                                           take it from a local checkout instead
#
# Windows' medut.dll is built the same way by the SDK's scripts/build-windows.ps1
# (.github/workflows/desktop.yml), into windows/medut/.
#
# Needs: git cmake ninja gcc, openssl-devel, webrtc-audio-processing-devel,
# pulseaudio-libs-devel (Fedora names; libssl-dev, libwebrtc-audio-processing-dev,
# libpulse-dev on Debian and Ubuntu).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REF="$(awk '/^  medut:/{m=1} m && /ref:/{print $2; exit}' "${ROOT}/pubspec.yaml")"
if [[ ! "${REF}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: no full Medut-SDK sha under medut: in pubspec.yaml (got '${REF}')" >&2
  exit 1
fi

SRC="${MEDUT_SDK_DIR:-https://github.com/Ibrahimgamal99/Medut-SDK.git}"
WORK="${ROOT}/build/medut-sdk-${REF:0:12}"
OUT="${ROOT}/linux/medut"

if [[ ! -d "${WORK}/.git" ]]; then
  echo "=== Medut-SDK ${REF:0:12} from ${SRC} ==="
  rm -rf "${WORK}"
  git clone --quiet --no-checkout "${SRC}" "${WORK}"
fi
git -C "${WORK}" fetch --quiet origin "${REF}" 2>/dev/null || true
git -C "${WORK}" -c advice.detachedHead=false checkout --quiet --force "${REF}"

bash "${WORK}/scripts/build-linux.sh"

mkdir -p "${OUT}"
cp "${WORK}/dist/linux/x86_64/medut.so" "${OUT}/medut.so"
echo "${REF}" > "${OUT}/REF"
echo ""
echo "medut.so (${REF:0:12}) -> ${OUT}/medut.so"

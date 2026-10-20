#!/usr/bin/env bash
# Builds the Linux desktop app for release and packages it:
#
#   dist/medut-<version>-linux-x86_64.tar.gz   the bundle; runs from any folder
#   dist/medut-<version>-1.x86_64.rpm          /opt/medut, `medut` on the PATH,
#                                              the menu entry and the tel:/sip:
#                                              links (needs rpmbuild)
#
#   scripts/build-desktop.sh
#
# medut.so must be in linux/medut/ first: scripts/desktop-sdk.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

VERSION="$(sed -nE 's/^version:[[:space:]]*([^+[:space:]]+).*/\1/p' pubspec.yaml)"
APP_ID="com.medut.generic.phone"
DIST="${ROOT}/dist"
BUNDLE="${ROOT}/build/linux/x64/release/bundle"

[[ -f linux/medut/medut.so ]] || { echo "linux/medut/medut.so is missing: run scripts/desktop-sdk.sh" >&2; exit 1; }

flutter build linux --release --dart-define=MEDUT_VERSION="${VERSION}"

mkdir -p "${DIST}"
TAR="${DIST}/medut-${VERSION}-linux-x86_64.tar.gz"
tar -C "$(dirname "${BUNDLE}")" --transform "s,^bundle,medut-${VERSION}," -czf "${TAR}" bundle
echo "-> ${TAR}"

if ! command -v rpmbuild >/dev/null; then
  echo "rpmbuild not found: no .rpm (dnf install rpm-build)"
  exit 0
fi

TOP="${ROOT}/build/rpm"
rm -rf "${TOP}"
mkdir -p "${TOP}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cat > "${TOP}/SPECS/medut.spec" <<SPEC
Name:           medut
Version:        ${VERSION}
Release:        1
Summary:        Softphone for any SIP PBX
License:        MPL-2.0
URL:            https://github.com/Ibrahimgamal99/medut-softphone
ExclusiveArch:  x86_64
# The bundle carries its own Flutter engine and plugins: they are not the
# system's to provide, and nothing outside it needs them. libdartjni (a
# dependency's Java bridge, for Android) links libjvm but never loads it here.
%global __provides_exclude_from ^/opt/medut/.*\$
%global __requires_exclude ^(libflutter_linux_gtk|lib.*_plugin|libdartjni|libapp|medut|libjvm)\\\\.so.*\$
%global debug_package %{nil}
%global __strip /bin/true
Requires:       libsecret
Recommends:     libayatana-appindicator-gtk3

%description
Medut, a softphone for Asterisk, FreeSWITCH, Kamailio, OpenSIPS, 3CX or a
carrier SBC: registration over UDP, TCP, TLS and WSS, calls, transfers,
recording and call quality. It stays in the tray and opens tel: and sip:
links.

%install
mkdir -p %{buildroot}/opt/medut %{buildroot}%{_bindir} \\
  %{buildroot}%{_datadir}/applications %{buildroot}%{_datadir}/icons/hicolor/512x512/apps
cp -a ${BUNDLE}/. %{buildroot}/opt/medut/
ln -s /opt/medut/medut %{buildroot}%{_bindir}/medut
install -m 644 ${ROOT}/linux/${APP_ID}.desktop %{buildroot}%{_datadir}/applications/${APP_ID}.desktop
install -m 644 ${ROOT}/linux/medut.png %{buildroot}%{_datadir}/icons/hicolor/512x512/apps/${APP_ID}.png

%files
/opt/medut
%{_bindir}/medut
%{_datadir}/applications/${APP_ID}.desktop
%{_datadir}/icons/hicolor/512x512/apps/${APP_ID}.png
SPEC

rpmbuild --quiet --define "_topdir ${TOP}" -bb "${TOP}/SPECS/medut.spec"
cp "${TOP}"/RPMS/x86_64/medut-"${VERSION}"-1.x86_64.rpm "${DIST}/"
echo "-> ${DIST}/medut-${VERSION}-1.x86_64.rpm"

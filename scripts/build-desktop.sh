#!/usr/bin/env bash
# Builds the Linux desktop app for release and packages it:
#
#   dist/medut-<version>-linux-x86_64.tar.gz   the bundle; runs from any folder
#   dist/medut_<version>_amd64.deb             Debian, Ubuntu (needs dpkg-deb)
#   dist/medut-<version>-1.x86_64.rpm          Fedora, openSUSE (needs rpmbuild)
#
# Both packages install /opt/medut, `medut` on the PATH, the menu entry and
# the tel:/sip:/callto: links.
#
#   scripts/build-desktop.sh            all three
#   scripts/build-desktop.sh deb        the bundle, then only the .deb (or rpm)
#
# medut.so is the medut plugin's prebuilt core for the pinned Medut-SDK
# commit; Flutter bundles it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

VERSION="$(sed -nE 's/^version:[[:space:]]*([^+[:space:]]+).*/\1/p' pubspec.yaml)"
APP_ID="com.medut.generic.phone"
DIST="${ROOT}/dist"
BUNDLE="${ROOT}/build/linux/x64/release/bundle"

ONLY="${1:-}"

flutter build linux --release --dart-define=MEDUT_VERSION="${VERSION}"

mkdir -p "${DIST}"
if [[ -z "${ONLY}" ]]; then
  TAR="${DIST}/medut-${VERSION}-linux-x86_64.tar.gz"
  tar -C "$(dirname "${BUNDLE}")" --transform "s,^bundle,medut-${VERSION}," -czf "${TAR}" bundle
  echo "-> ${TAR}"
fi

# ── .deb ─────────────────────────────────────────────────────────────────────
if [[ -z "${ONLY}" || "${ONLY}" == deb ]]; then
  if ! command -v dpkg-deb >/dev/null; then
    echo "dpkg-deb not found: no .deb (dnf install dpkg / apt install dpkg)"
  else
    STAGE="${ROOT}/build/deb/medut"
    rm -rf "${STAGE}"
    mkdir -p "${STAGE}/DEBIAN" "${STAGE}/opt/medut" "${STAGE}/usr/bin" \
      "${STAGE}/usr/share/applications" "${STAGE}/usr/share/icons/hicolor/512x512/apps"
    cp -a "${BUNDLE}/." "${STAGE}/opt/medut/"
    ln -s /opt/medut/medut "${STAGE}/usr/bin/medut"
    install -m 644 "linux/${APP_ID}.desktop" "${STAGE}/usr/share/applications/${APP_ID}.desktop"
    install -m 644 linux/medut.png "${STAGE}/usr/share/icons/hicolor/512x512/apps/${APP_ID}.png"
    # The newest glibc symbol the bundle uses: the build machine's, so a
    # system older than that is refused by apt instead of failing to start.
    GLIBC="$(find "${BUNDLE}" -type f \( -name '*.so*' -o -name medut \) -exec objdump -T {} + 2>/dev/null \
      | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -t. -k2 -n -u | tail -1 | cut -d_ -f2)"
    SIZE="$(du -sk "${STAGE}" | cut -f1)"
    cat > "${STAGE}/DEBIAN/control" <<CONTROL
Package: medut
Version: ${VERSION}
Section: comm
Priority: optional
Architecture: amd64
Installed-Size: ${SIZE}
Maintainer: Medut <noreply@github.com>
Homepage: https://github.com/Ibrahimgamal99/medut-softphone
Depends: libc6 (>= ${GLIBC:-2.17}), libgtk-3-0t64 | libgtk-3-0, libsecret-1-0, libayatana-appindicator3-1, libpulse0, zlib1g
Recommends: pipewire-pulse | pulseaudio-utils, xdg-utils
Description: Softphone for any SIP PBX
 Medut, a softphone for Asterisk, FreeSWITCH, Kamailio, OpenSIPS, 3CX or a
 carrier SBC: registration over UDP, TCP, TLS and WSS, calls, transfers,
 recording and call quality. It stays in the tray and opens tel: and sip:
 links.
CONTROL
    # Menus and the link handlers pick the new .desktop file up.
    cat > "${STAGE}/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q /usr/share/icons/hicolor || true
POST
    cp "${STAGE}/DEBIAN/postinst" "${STAGE}/DEBIAN/postrm"
    chmod 755 "${STAGE}/DEBIAN/postinst" "${STAGE}/DEBIAN/postrm"
    DEB="${DIST}/medut_${VERSION}_amd64.deb"
    dpkg-deb --root-owner-group --build "${STAGE}" "${DEB}" >/dev/null
    echo "-> ${DEB} (glibc ${GLIBC:-2.17}+)"
  fi
fi

# ── .rpm ─────────────────────────────────────────────────────────────────────
[[ -z "${ONLY}" || "${ONLY}" == rpm ]] || exit 0
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

# Menus, the link handlers and the taskbar pick up the new entry and icon.
%post
update-desktop-database -q %{_datadir}/applications &>/dev/null || :
gtk-update-icon-cache -q %{_datadir}/icons/hicolor &>/dev/null || :

%postun
update-desktop-database -q %{_datadir}/applications &>/dev/null || :
gtk-update-icon-cache -q %{_datadir}/icons/hicolor &>/dev/null || :

%files
/opt/medut
%{_bindir}/medut
%{_datadir}/applications/${APP_ID}.desktop
%{_datadir}/icons/hicolor/512x512/apps/${APP_ID}.png
SPEC

rpmbuild --quiet --define "_topdir ${TOP}" -bb "${TOP}/SPECS/medut.spec"
cp "${TOP}"/RPMS/x86_64/medut-"${VERSION}"-1.x86_64.rpm "${DIST}/"
echo "-> ${DIST}/medut-${VERSION}-1.x86_64.rpm"

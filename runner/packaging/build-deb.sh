#!/bin/sh
# Builds the goat-processors .deb from a built binary.
#   runner/packaging/build-deb.sh <arch: amd64|arm64> <path to the release binary> <output dir>
# Run from the repository root. Needs dpkg-deb.
set -eu
umask 022
arch=$1 bin=$2 out=$3
case "$arch" in amd64|arm64) ;; *) echo "arch must be amd64 or arm64" >&2; exit 2 ;; esac
version=$(sed -n 's/^version = "\(.*\)"/\1/p' runner/Cargo.toml | head -1)
root=$(mktemp -d)
chmod 0755 "$root"
trap 'rm -rf "$root"' EXIT

install -D -m 0755 "$bin" "$root/usr/bin/goat-processors"
install -D -m 0644 runner/packaging/systemd/goat-processors.service "$root/usr/lib/systemd/system/goat-processors.service"
install -D -m 0640 runner/config/runner.yaml "$root/etc/goat-processors/runner.yaml"
install -d -m 0750 "$root/etc/goat-processors/tls"
# Every pack, with its vectors: `goat-processors selftest` replays them.
mkdir -p "$root/usr/share/goat-processors"
cp -r packs "$root/usr/share/goat-processors/packs"
find "$root/usr/share/goat-processors" -type d -exec chmod 0755 {} + -o -type f -exec chmod 0644 {} +
for f in runner/README.md runner/INSTALL.md runner/DEPLOY-CONTRACT.md runner/docs/install-card.pdf NOTICE LICENSE; do
  [ -f "$f" ] && install -D -m 0644 "$f" "$root/usr/share/doc/goat-processors/$(basename "$f")"
done
for f in runner/README.md runner/INSTALL.md; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

mkdir -p "$root/DEBIAN"
size=$(du -sk --exclude=DEBIAN "$root" | cut -f1)
cat > "$root/DEBIAN/control" <<CONTROL
Package: goat-processors
Version: $version
Architecture: $arch
Maintainer: goat-processors maintainers <noreply@github.com>
Installed-Size: $size
Depends: adduser, systemd
Recommends: openssl
Section: net
Priority: optional
Homepage: https://github.com/USAREUR-AF/goat-processors
Description: goat-processors runner
 Runs a declared pipeline of processing functions (filter, correlate, fuse,
 quality) on the shared-model reports of the goat fabric, and publishes system
 tracks, quality marks and the trace. Configured by one file,
 /etc/goat-processors/runner.yaml; checked by goat-processors doctor.
CONTROL
echo /etc/goat-processors/runner.yaml > "$root/DEBIAN/conffiles"
install -m 0755 runner/packaging/deb/postinst runner/packaging/deb/prerm runner/packaging/deb/postrm "$root/DEBIAN/"

mkdir -p "$out"
deb="$out/goat-processors_${version}_${arch}.deb"
dpkg-deb --root-owner-group -Zxz --build "$root" "$deb" >/dev/null
echo "$deb"

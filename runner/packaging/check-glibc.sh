#!/bin/sh
# Fails when a binary needs a newer glibc than the oldest Ubuntu it is for.
#   runner/packaging/check-glibc.sh <max, e.g. 2.35> <.deb or binary> ...
# 2.35 is Ubuntu 22.04's glibc (and NVIDIA Jetson Linux 36 on Orin). Reads
# the ELF version needs with readelf, so it checks an arm64 binary on an
# amd64 host as well. Needs binutils (readelf) and dpkg-deb for a .deb.
set -eu
max=$1; shift
[ $# -gt 0 ] || { echo "usage: $0 <max glibc> <.deb or binary> ..." >&2; exit 2; }
status=0
for f in "$@"; do
  bin=$f tmp=""
  case "$f" in
    *.deb)
      tmp=$(mktemp -d)
      dpkg-deb -x "$f" "$tmp"
      bin=$tmp/usr/bin/goat-processors ;;
  esac
  [ -f "$bin" ] || { echo "$f: no binary at $bin" >&2; exit 2; }
  need=$(readelf -W --version-info "$bin" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n 1)
  [ -n "$need" ] || { echo "$f: no GLIBC version needs found (not a glibc binary?)" >&2; exit 2; }
  arch=$(readelf -h "$bin" | sed -n 's/^ *Machine: *//p')
  if [ "$(printf '%s\n%s\n' "$need" "$max" | sort -V | tail -n 1)" = "$max" ]; then
    echo "ok: $f ($arch) needs at most GLIBC_$need (limit GLIBC_$max)"
  else
    echo "FAIL: $f ($arch) needs GLIBC_$need, newer than GLIBC_$max: it will not run on Ubuntu 22.04" >&2
    status=1
  fi
  [ -z "$tmp" ] || rm -rf "$tmp"
done
exit $status

#!/usr/bin/env bash
# Fetch a modern nginx binary without root by parsing the apt Packages index.
set -uo pipefail
cd /tmp
rm -rf nginxroot nginx.deb pkgidx && mkdir -p nginxroot pkgidx

ARCH="$(dpkg --print-architecture)"
found_any=0

try_deb() {
  local rel="$1" comp="$2" fn="$3"
  echo "   -> $fn"
  if ! timeout 180 curl -sS -o nginx.deb "http://archive.ubuntu.com/ubuntu/${fn}" -w '      http=%{http_code} size=%{size_download}\n'; then
    return 1
  fi
  dpkg-deb -x nginx.deb nginxroot 2>/dev/null || return 1
  local bin
  bin="$(find nginxroot -name nginx -type f | head -1)"
  if [ -n "$bin" ]; then
    echo "      binary: $bin"
    "$bin" -v 2>&1 | sed 's/^/      /'
    echo "      libs: $(ldd "$bin" 2>&1 | grep -ci 'not found') missing"
    return 0
  fi
  return 1
}

for REL in noble-updates noble; do
  for COMP in main universe; do
    url="http://archive.ubuntu.com/ubuntu/dists/${REL}/${COMP}/binary-${ARCH}/Packages.gz"
    echo "== $REL/$COMP"
    if timeout 120 curl -sS -o pkgidx/Packages.gz "$url" 2>/dev/null && [ -s pkgidx/Packages.gz ]; then
      files="$(zcat pkgidx/Packages.gz | awk '
        /^Package: / { pkg=$2 }
        /^Filename: / { if (pkg=="nginx") print $2 }
      ' | head -3)"
      if [ -z "$files" ]; then echo "   nginx pkg not in this index"; continue; fi
      for fn in $files; do
        if try_deb "$REL" "$COMP" "$fn"; then
          if [ -x "$(find nginxroot -name nginx -type f | head -1)" ]; then
            echo
            echo "NGINX OBTAINED: $(find nginxroot -name nginx -type f | head -1)"
            exit 0
          fi
        fi
      done
    else
      echo "   index unavailable"
    fi
  done
done
echo "FAILED to obtain a working nginx"
exit 1

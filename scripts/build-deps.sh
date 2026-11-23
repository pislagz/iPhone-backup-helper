#!/usr/bin/env bash
# Builds the pinned C libraries as universal (arm64 + x86_64) dylibs into vendor/.
#
#   vendor/lib       libplist, libimobiledevice-glue, libusbmuxd, libimobiledevice
#                    (fat dylibs, install names @rpath/<file>); OpenSSL is linked
#                    statically *into* libimobiledevice, so it ships no dylib.
#   vendor/include   headers for the Swift C target
#   vendor/licenses  license texts + VERSIONS.txt (shipped in the .app)
#
# Build-time tools needed (CI installs them via Homebrew; never needed at runtime):
#   autoconf automake libtool pkg-config git make clang lipo install_name_tool
#
# Offline notes: libimobiledevice is built WITHOUT its tools (so no libtatsu/libcurl,
# no ideviceactivation), without python bindings and without readline.
set -euo pipefail

# ---- pins (bump deliberately; the CI cache is keyed on this file's hash) ----
LIBPLIST_SHA=b3f14c22dbb29056c0d3c37bb9b2401ffdb7bc8f        # master, 2026-11-16
GLUE_SHA=420053a5fc536062014a121e14d847db914be999            # master, 2026-11-16
LIBUSBMUXD_SHA=1498dee3aadf66dbae10e699d71c62b428a511a3      # master, 2026-11-19
LIBIMOBILEDEVICE_SHA=60bf03b4cac8ed5f52f803cdb031a404c0da3beb # master, 2026-11-18
OPENSSL_SHA=45e844fa2a14ec92d146bd8f5778ac130b6625fb         # openssl-3.5.9
DEPLOYMENT_TARGET=13.0
ARCHS=(arm64 x86_64)
# -----------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor"
SRC="$VENDOR/src"
BUILD="$VENDOR/build"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

for tool in autoconf automake glibtoolize pkg-config git make clang lipo install_name_tool; do
  command -v "$tool" >/dev/null || { echo "missing build tool: $tool" >&2; exit 1; }
done

if [[ -f "$VENDOR/.complete" && "$(cat "$VENDOR/.complete")" == "$(shasum "$0" | cut -d' ' -f1)" ]]; then
  echo "vendor/ is up to date"; exit 0
fi
rm -rf "$VENDOR"; mkdir -p "$SRC" "$BUILD"

fetch() { # name url sha
  local dir="$SRC/$1"
  mkdir -p "$dir"; git -C "$dir" init -q
  git -C "$dir" remote add origin "$2"
  git -C "$dir" fetch -q --depth 1 origin "$3"
  git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  [[ "$(git -C "$dir" rev-parse HEAD)" == "$3" ]]
}

fetch libplist https://github.com/libimobiledevice/libplist.git "$LIBPLIST_SHA"
fetch glue https://github.com/libimobiledevice/libimobiledevice-glue.git "$GLUE_SHA"
fetch libusbmuxd https://github.com/libimobiledevice/libusbmuxd.git "$LIBUSBMUXD_SHA"
fetch libimobiledevice https://github.com/libimobiledevice/libimobiledevice.git "$LIBIMOBILEDEVICE_SHA"
fetch openssl https://github.com/openssl/openssl.git "$OPENSSL_SHA"

# libimobiledevice only needs libtatsu (-> libcurl, network!) for its CLI tools. We
# don't build tools, so drop the dependency check entirely.
sed -i.bak '/[Ll][Ii][Bb][Tt][Aa][Tt][Ss][Uu]/d' "$SRC/libimobiledevice/configure.ac"
if grep -qi tatsu "$SRC/libimobiledevice/configure.ac"; then echo "libtatsu patch failed" >&2; exit 1; fi

autogen() { (cd "$SRC/$1" && NOCONFIGURE=1 ./autogen.sh >/dev/null); }
export LIBTOOLIZE=glibtoolize
autogen libplist; autogen glue; autogen libusbmuxd; autogen libimobiledevice

build_arch() {
  local arch="$1" host ossl
  case "$arch" in
    arm64)  host=aarch64-apple-darwin; ossl=darwin64-arm64-cc ;;
    x86_64) host=x86_64-apple-darwin;  ossl=darwin64-x86_64-cc ;;
  esac
  local prefix="$BUILD/$arch/prefix"
  mkdir -p "$prefix"
  export CFLAGS="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET -O2 -g0"
  export CXXFLAGS="$CFLAGS"
  export LDFLAGS="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET"
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"   # never see Homebrew .pc files
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
  unset OPENSSL_CFLAGS OPENSSL_LIBS
  export CC=clang CXX=clang++
  # x86_64 is a cross build on arm64 runners: pre-answer the checks that cannot run.
  export ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes

  echo "=== [$arch] openssl (static, local TLS only)"
  mkdir -p "$BUILD/$arch/openssl"
  (cd "$BUILD/$arch/openssl" &&
    "$SRC/openssl/Configure" "$ossl" no-shared no-tests no-apps no-docs no-module no-legacy \
      no-engine no-dso no-comp no-ssl3 --prefix="$prefix" --libdir=lib "-mmacosx-version-min=$DEPLOYMENT_TARGET" >/dev/null &&
    make -j"$JOBS" build_libs >/dev/null && make install_dev >/dev/null)

  conf() { # name srcdir extra-args...
    local name="$1" srcdir="$2"; shift 2
    mkdir -p "$BUILD/$arch/$name"
    (cd "$BUILD/$arch/$name" && "$srcdir/configure" --host="$host" --prefix="$prefix" \
        --enable-shared --disable-static "$@" >/dev/null)
  }
  inst() { local name="$1"; shift; for d in "$@"; do make -C "$BUILD/$arch/$name/$d" -j"$JOBS" >/dev/null && make -C "$BUILD/$arch/$name/$d" install >/dev/null; done; }

  echo "=== [$arch] libplist"
  conf libplist "$SRC/libplist" --without-cython --with-tools=no
  inst libplist libcnary src include

  echo "=== [$arch] libimobiledevice-glue"
  conf glue "$SRC/glue"
  inst glue src include

  echo "=== [$arch] libusbmuxd"
  conf libusbmuxd "$SRC/libusbmuxd"
  inst libusbmuxd src include

  echo "=== [$arch] libimobiledevice"
  conf libimobiledevice "$SRC/libimobiledevice" --without-cython --without-readline \
       --disable-wireless-pairing --with-openssl --without-mbedtls --without-gnutls
  inst libimobiledevice 3rd_party common src include
}

for a in "${ARCHS[@]}"; do build_arch "$a"; done

echo "=== lipo + install-name fixup"
mkdir -p "$VENDOR/lib" "$VENDOR/include" "$VENDOR/licenses"
first="${ARCHS[0]}"
for f in "$BUILD/$first/prefix/lib/"*.dylib; do
  name="$(basename "$f")"
  if [[ -L "$f" ]]; then
    ln -sf "$(readlink "$f")" "$VENDOR/lib/$name"; continue
  fi
  inputs=(); for a in "${ARCHS[@]}"; do inputs+=("$BUILD/$a/prefix/lib/$name"); done
  lipo -create "${inputs[@]}" -output "$VENDOR/lib/$name"
  install_name_tool -id "@rpath/$name" "$VENDOR/lib/$name"
done
for f in "$VENDOR/lib/"*.dylib; do
  [[ -L "$f" ]] && continue
  while read -r dep; do
    case "$dep" in "$BUILD"/*) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" ;; esac
  done < <(otool -L "$f" | grep -E '^[[:space:]]' | awk '{print $1}')
done
rsync -a --exclude openssl "$BUILD/$first/prefix/include/" "$VENDOR/include/"

# Sanity: every dependency is @rpath / system; nothing from Homebrew, nothing network-ish.
for f in "$VENDOR/lib/"*.dylib; do
  [[ -L "$f" ]] && continue
  lipo -archs "$f" | grep -q arm64 && lipo -archs "$f" | grep -q x86_64 || { echo "not universal: $f" >&2; exit 1; }
  if otool -L "$f" | grep -E '^[[:space:]]' | awk '{print $1}' | grep -Ev '^(@rpath/|/usr/lib/|/System/Library/)'; then
    echo "unexpected dependency in $f" >&2; exit 1
  fi
  if otool -L "$f" | grep -E '^[[:space:]]' | grep -Eqi 'curl|nghttp|libssl|libcrypto|Sparkle'; then
    echo "forbidden dependency in $f" >&2; exit 1
  fi
done

# Licenses
copylic() { # name file...
  local name="$1"; shift; mkdir -p "$VENDOR/licenses/$name"
  for f in "$@"; do if [[ -f "$f" ]]; then cp "$f" "$VENDOR/licenses/$name/"; fi; done
}
copylic libplist "$SRC/libplist/COPYING" "$SRC/libplist/COPYING.LESSER"
copylic libimobiledevice-glue "$SRC/glue/COPYING" "$SRC/glue/COPYING.LESSER"
copylic libusbmuxd "$SRC/libusbmuxd/COPYING" "$SRC/libusbmuxd/COPYING.LESSER" "$SRC/libusbmuxd/COPYING.GPLv2"
copylic libimobiledevice "$SRC/libimobiledevice/COPYING" "$SRC/libimobiledevice/COPYING.LESSER"
copylic openssl "$SRC/openssl/LICENSE.txt"
cat > "$VENDOR/licenses/VERSIONS.txt" <<VER
Bundled third-party libraries (built from source, unmodified except where noted)
  libplist                $LIBPLIST_SHA   https://github.com/libimobiledevice/libplist          LGPL-2.1
  libimobiledevice-glue   $GLUE_SHA   https://github.com/libimobiledevice/libimobiledevice-glue  LGPL-2.1
  libusbmuxd              $LIBUSBMUXD_SHA   https://github.com/libimobiledevice/libusbmuxd     LGPL-2.1
  libimobiledevice        $LIBIMOBILEDEVICE_SHA   https://github.com/libimobiledevice/libimobiledevice  LGPL-2.1
      (build patch: the libtatsu configure check was removed; only the unbuilt CLI tools used it)
  OpenSSL 3.5.9           $OPENSSL_SHA   https://github.com/openssl/openssl   Apache-2.0 (linked statically into libimobiledevice)
The LGPL libraries are dynamically linked (Contents/Frameworks) and can be replaced by
rebuilding them from the sources above with scripts/build-deps.sh of this project.
VER

shasum "$0" | cut -d' ' -f1 > "$VENDOR/.complete"
rm -rf "$BUILD" "$SRC"   # keep the cache small
echo "done: $(ls "$VENDOR/lib" | tr '\n' ' ')"

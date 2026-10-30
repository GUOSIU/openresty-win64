#!/usr/bin/env bash
# Build OpenResty 1.31.8.1 for Windows x64 inside an MSYS2 **MINGW64** shell.
# Mirrors openresty/util/build-win32.sh but with explicit https URLs,
# progress logging and a staged package output.
#
# Usage (inside MINGW64 shell):
#   OUT_DIR=/c/OpenRestyOut ./build-openresty.sh
#
set -Eeuo pipefail

# Report the exact failing line instead of dying silently under `set -e`.
trap 'printf "\nERROR: %s:%s exited %s while running: %s\n" \
        "${BASH_SOURCE[0]}" "$LINENO" "$?" "$BASH_COMMAND" >&2' ERR

# =============================================================================
# Version knobs - the ONLY place that has to change for a new OpenResty release.
# Everything else (package name, README.txt, patch selection, nginx dir) is
# derived from these four values.
#
#   VERSION=1.32.1.1 OPENSSL_VER=3.6.0 ./build-openresty.sh
#   or: powershell ... -File .\build-all.ps1 -Version 1.32.1.1 -OpenSSLVer 3.6.0
#
# Where to find the numbers for a new release: the announcement page
# https://openresty.org/en/changelog-<nginx-version-digits>.html lists the
# bundled OpenSSL / PCRE2 / zlib versions ("Components" section).
# =============================================================================
VERSION="${VERSION:-1.31.8.1}"
OPENSSL_VER="${OPENSSL_VER:-3.5.9}"
ZLIB_VER="${ZLIB_VER:-1.3.2}"
PCRE2_VER="${PCRE2_VER:-10.49}"

WORK="${WORK:-$HOME/orbuild-$VERSION}"
OUT_DIR="${OUT_DIR:-/c/OpenRestyOut}"
JOBS="${JOBS:-$(nproc)}"
PREFIX="${PREFIX:-}"

# Colour only when writing to a terminal. When the output is piped (as
# build-all.ps1 does), ESC sequences would end up in the log file and show up
# as stray "[1m" / "[0m" garbage in editors.
if [ -t 1 ]; then BOLD=$'\033[1m'; RESET=$'\033[0m'; else BOLD=''; RESET=''; fi

log()  { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$RESET"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
T0=$SECONDS

log "environment checks"
[ "${MSYSTEM:-}" = "MINGW64" ] || die "run this from the MSYS2 MINGW64 shell (MSYSTEM=${MSYSTEM:-unset})"
for tool in gcc make perl patch tar; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
gcc -dumpmachine | grep -q '^x86_64-w64-mingw32' || die "wrong compiler: $(gcc -dumpmachine) (expected x86_64-w64-mingw32)"
printf 'MSYSTEM=%s\ngcc=%s\nmake=%s\nperl=%s\njobs=%s\nwork=%s\nout=%s\nversions=openresty %s / openssl %s / pcre2 %s / zlib %s\n' \
    "$MSYSTEM" "$(gcc -dumpmachine)" "$(make --version | sed -n '1p')" "$(perl -e 'print $^O')" \
    "$JOBS" "$WORK" "$OUT_DIR" "$VERSION" "$OPENSSL_VER" "$PCRE2_VER" "$ZLIB_VER"

DL="$WORK/dl"
SRC="$WORK/openresty-$VERSION"
STAGE="$WORK/stage"
# Persistent download cache: this directory lives next to the scripts, i.e. on
# the host's mapped folder, so a fresh sandbox session does not re-download the
# ~60 MB of tarballs. You may also drop the tarballs here by hand.
DEPS="${DEPS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deps}"
mkdir -p "$DL" "$OUT_DIR" "$DEPS"

# fetch <dest-name> <url> [fallback-url ...]
# Downloads into <dest>.part and only promotes it to <dest> after the tarball
# passes an integrity check, so a half-downloaded file can never be mistaken for
# a complete one. Resume (-C -) makes a reset at 40 MB continue from there
# instead of restarting.
fetch() {
    local name="$1"; shift
    local dest="$DEPS/$name" tmp="$DEPS/$name.part"

    if [ -s "$dest" ]; then
        log "cached $name ($(du -h "$dest" | cut -f1))"
        return 0
    fi

    local url
    for url in "$@"; do
        log "downloading $url"
        if command -v curl >/dev/null 2>&1; then
            curl -fL --http1.1 -C - --retry 8 --retry-all-errors --retry-delay 2 \
                 --connect-timeout 30 --max-time 3600 --no-progress-meter \
                 -o "$tmp" "$url" || true
        else
            wget -c -O "$tmp" "$url" || true
        fi

        if [ -s "$tmp" ]; then
            if gzip -t "$tmp" 2>/dev/null; then
                mv "$tmp" "$dest"
                log "ok $name ($(du -h "$dest" | cut -f1))"
                return 0
            fi
            log "incomplete or corrupt: $(du -h "$tmp" | cut -f1) - keeping it for resume"
        fi
        log "source failed: $url"
    done

    die "could not download $name from any source (partial data kept in:
       $tmp
     ). Put the tarball into:  $DEPS  or set DEPS=/path/to/cache and rerun."
}

log "fetching sources"
fetch "openresty-$VERSION.tar.gz" \
      "https://openresty.org/download/openresty-$VERSION.tar.gz"
fetch "openssl-$OPENSSL_VER.tar.gz" \
      "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz"
fetch "pcre2-$PCRE2_VER.tar.gz" \
      "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VER/pcre2-$PCRE2_VER.tar.gz"
fetch "zlib-$ZLIB_VER.tar.gz" \
      "https://zlib.net/zlib-$ZLIB_VER.tar.gz" \
      "https://zlib.net/fossils/zlib-$ZLIB_VER.tar.gz" \
      "https://github.com/madler/zlib/releases/download/v$ZLIB_VER/zlib-$ZLIB_VER.tar.gz"

# REUSE=1 skips unpacking / patching / configure when a finished tree exists and
# only reruns `make` (a no-op if nothing changed) + install + package. Useful
# when only the packaging or the script changed: ~40 s instead of ~15 min.
if [ "${REUSE:-0}" = "1" ] && [ -f "$SRC/objs/Makefile" ] \
   && ls "$SRC"/build/nginx-*/objs/nginx.exe >/dev/null 2>&1; then
    log "REUSE=1: reusing the existing build tree - skipping extract / patch / configure"
    cd "$SRC"
else
log "extracting"
[ -d "$SRC" ] || tar -xzf "$DEPS/openresty-$VERSION.tar.gz" -C "$WORK"
cd "$SRC"
rm -rf objs
mkdir -p objs/lib
for tarball in "openssl-$OPENSSL_VER.tar.gz" "zlib-$ZLIB_VER.tar.gz" "pcre2-$PCRE2_VER.tar.gz"; do
    tar -xzf "$DEPS/$tarball" -C objs/lib
done
ls -1 objs/lib

# The release ships many variants of the sess_set_get_cb_yield patch, one per
# OpenSSL branch (1.0.2h, 1.1.1c, 3.0.12, 3.4.1, 3.5.0, 3.5.4, 3.5.5, ...).
# Picking the alphabetically first one (1.0.2h) fails against 3.5.9, so select
# by *applicability*: exact version first, then same major.minor, then the rest,
# each tried with `patch -F0 --dry-run` so a fuzzy near-miss cannot be accepted.
log "selecting an OpenSSL sess_set_get_cb_yield patch for $OPENSSL_VER"
OPENSSL_PATCH=""
if [ "${SKIP_OPENSSL_PATCH:-0}" = "1" ]; then
    log "SKIP_OPENSSL_PATCH=1 -> not patching OpenSSL"
else
    shopt -s nullglob
    p_exact=( "$SRC"/patches/openssl-"$OPENSSL_VER"-sess_set_get_cb_yield*.patch )
    p_minor=( "$SRC"/patches/openssl-"${OPENSSL_VER%.*}".[0-9]*-sess_set_get_cb_yield*.patch )
    p_all=(   "$SRC"/patches/openssl-*-sess_set_get_cb_yield*.patch )
    shopt -u nullglob

    declare -A seen=()
    try_patch() {
        local p b
        for p in "$@"; do
            [ -f "$p" ] || continue
            b="$(basename "$p")"
            [ -n "${seen[$b]:-}" ] && continue
            seen[$b]=1
            if ( cd "$SRC/objs/lib/openssl-$OPENSSL_VER" && \
                 patch -p1 -F0 --dry-run --forward --batch < "$p" >/dev/null 2>&1 ); then
                printf '  %s: applies\n' "$b"
                ( cd "$SRC/objs/lib/openssl-$OPENSSL_VER" && \
                  patch -p1 -F0 --forward --batch < "$p" >/dev/null ) \
                    || die "patch $b passed --dry-run but failed to apply"
                OPENSSL_PATCH="$b"
                return 0
            fi
            printf '  %s: does not apply\n' "$b"
        done
        return 1
    }

    if try_patch "${p_exact[@]}" "${p_minor[@]}" "${p_all[@]}"; then
        log "applied $OPENSSL_PATCH"
    else
        die "none of the shipped OpenSSL patches applies to $OPENSSL_VER.
       Checked: ${p_all[*]##*/}
       Override with SKIP_OPENSSL_PATCH=1 (session-callback yielding stays unpatched)
       or point OPENSSL_VER at a version one of these patches targets."
    fi
    unset seen
fi

log "configure"
./configure \
    --with-cc=gcc \
    --platform=msys \
    --prefix="$PREFIX" \
    --with-cc-opt='-DFD_SETSIZE=1024' \
    --sbin-path=nginx.exe \
    --with-pcre-jit \
    --without-http_rds_json_module \
    --without-http_rds_csv_module \
    --without-lua_rds_parser \
    --with-ipv6 \
    --with-stream \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --with-http_v2_module \
    --without-mail_pop3_module \
    --without-mail_imap_module \
    --without-mail_smtp_module \
    --with-http_stub_status_module \
    --with-http_realip_module \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_secure_link_module \
    --with-http_random_index_module \
    --with-http_gzip_static_module \
    --with-http_sub_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_mp4_module \
    --with-http_gunzip_module \
    --with-select_module \
    --with-luajit-xcflags="-DLUAJIT_NUMMODE=2 -DLUAJIT_ENABLE_LUA52COMPAT" \
    --with-pcre="objs/lib/pcre2-$PCRE2_VER" \
    --with-zlib="objs/lib/zlib-$ZLIB_VER" \
    --with-openssl="objs/lib/openssl-$OPENSSL_VER" \
    -j"$JOBS"
fi

T_MAKE=$SECONDS
log "make -j$JOBS (this is the long part: OpenSSL, LuaJIT, nginx)"
make -j"$JOBS"
log "make finished in $((SECONDS - T_MAKE))s"

log "make install (staged into DESTDIR)"
rm -rf "$STAGE" "${STAGE}."
mkdir -p "$STAGE"
# NOTE the trailing slash: configure used --prefix=. so install paths are
# "$DESTDIR$prefix/nginx.exe". "<stage>" + "." becomes "<stage>." (a sibling
# directory) without the slash, which is exactly what happened on the first run.
make install DESTDIR="$STAGE/" || true

# Recover the tree if an older/odd make put it in the "stage." sibling.
if [ ! -f "$STAGE/nginx.exe" ] && [ -f "${STAGE}./nginx.exe" ]; then
    log "install tree landed in ${STAGE}. - moving it into $STAGE"
    shopt -s dotglob
    mv "${STAGE}."/* "$STAGE/" 2>/dev/null || true
    shopt -u dotglob
    rmdir "${STAGE}." 2>/dev/null || true
fi

# Last resort: take the freshly built binary and the in-tree config layout.
# Directory names are globbed, never hard-coded, so a new nginx / resty-cli
# version does not need a script change.
if [ ! -f "$STAGE/nginx.exe" ]; then
    log "falling back to in-tree artifacts"
    for exe in "$SRC"/build/nginx-*/objs/nginx.exe; do
        [ -f "$exe" ] && cp -a "$exe" "$STAGE/nginx.exe" && break
    done

    NGINX_DIR="$(ls -d "$SRC"/build/nginx-* 2>/dev/null | head -n1 || true)"
    if [ -n "${NGINX_DIR:-}" ]; then
        for d in conf logs html; do
            [ -d "$NGINX_DIR/$d" ] && cp -a "$NGINX_DIR/$d" "$STAGE/"
        done
    fi

    for d in lualib pod; do
        [ -d "$SRC/$d" ] && cp -a "$SRC/$d" "$STAGE/"
        [ -d "$SRC/build/$d" ] && [ ! -d "$STAGE/$d" ] && cp -a "$SRC/build/$d" "$STAGE/"
    done

    for f in resty restydoc restydoc-index; do
        for cand in "$SRC/$f" "$SRC"/build/resty-cli-*/bin/"$f"; do
            [ -f "$cand" ] && cp -a "$cand" "$STAGE/" && break
        done
    done
fi

[ -f "$STAGE/nginx.exe" ] || die "build finished but nginx.exe was not produced"

log "smoke test"
"$STAGE/nginx.exe" -V 2>&1 | head -n 5 || true

log "packaging into $OUT_DIR"
PKG="openresty-$VERSION-win64"
ZIP="$OUT_DIR/$PKG.zip"
PKGDIR="$WORK/$PKG"

# Wrap the tree in a single top-level directory named after the package, so
# extracting the archive creates one folder instead of scattering nginx.exe,
# conf/, lualib/ ... into whatever directory the user happens to be in.
rm -rf "$PKGDIR"
mv "$STAGE" "$PKGDIR" || die "could not move $STAGE -> $PKGDIR"
[ -f "$PKGDIR/nginx.exe" ] || die "internal error: $PKGDIR/nginx.exe vanished during packaging"

# ---------------------------------------------------------------------------
# Align the package with the official Windows distribution layout:
#   conf html include logs lua lualib pod COPYRIGHT lua51.dll luajit.exe
#   nginx.exe openresty.exe README.txt resty(.bat) restydoc(.bat)
#   restydoc-index(.bat)
# So: drop the doc *generators* (md2pod.pl, nginx-xml2pod), plus opm/resty.index
# and the empty site/ skeleton; KEEP pod/ and the restydoc tools.
# ---------------------------------------------------------------------------
log "matching the official Windows package layout"

for item in md2pod.pl nginx-xml2pod opm resty.index site; do
    [ -e "$PKGDIR/$item" ] || continue
    _kb="$(du -sk "$PKGDIR/$item" 2>/dev/null | cut -f1)"
    rm -rf "$PKGDIR/$item"
    printf '  removed %-14s %s KB\n' "$item" "${_kb:-?}"
done

# cmd.exe wrappers: resty/restydoc/restydoc-index are Perl scripts, so on
# Windows they are normally invoked through these .bat shims.
printf '@echo off\r\nperl "%%~dp0resty" %%*\r\n'           > "$PKGDIR/resty.bat"
printf '@echo off\r\nperl "%%~dp0restydoc" %%*\r\n'        > "$PKGDIR/restydoc.bat"
printf '@echo off\r\nperl "%%~dp0restydoc-index" %%*\r\n'  > "$PKGDIR/restydoc-index.bat"
log "  created resty.bat, restydoc.bat, restydoc-index.bat"

# The official Windows package ships nginx.exe only - no openresty.exe.
# Keep it that way; OPENRESTY_EXE=copy optionally adds the duplicate back.
if [ "${OPENRESTY_EXE:-none}" = "copy" ]; then
    cp -f "$PKGDIR/nginx.exe" "$PKGDIR/openresty.exe" || die "could not create openresty.exe"
    log "  openresty.exe added on request (OPENRESTY_EXE=copy)"
else
    rm -f "$PKGDIR/openresty.exe" "$PKGDIR/openresty.bat"
fi

if [ ! -f "$PKGDIR/README.txt" ]; then
    # Component versions are read from the build tree, not hard-coded.
    # Pure-shell loop (no `| head`): SIGPIPE would trip `set -o pipefail`.
    dirver() {
        local d base
        for d in "$SRC"/build/"$1"-*/; do
            [ -d "$d" ] || continue
            base="${d%/}"; base="${base##*/}"
            printf '%s\n' "${base#"$1"-}"
            return 0
        done
        return 1
    }
    NGINX_VER="$(dirver nginx || true)"
    LUAJIT_VER="$(dirver LuaJIT || true)"
    cat > "$PKGDIR/README.txt" <<EOF
OpenResty ${VERSION} for Windows x64
==================================

Built from source with MSYS2 / MinGW-w64 (x86_64-w64-mingw32).
nginx core ${NGINX_VER:-unknown}, OpenSSL ${OPENSSL_VER}, PCRE2 ${PCRE2_VER}, zlib ${ZLIB_VER}, LuaJIT ${LUAJIT_VER:-unknown}.

Layout
------
  nginx.exe          the server (the only binary, like the official package)
  conf/              nginx.conf and stock configuration files
  logs/              error.log / access.log / nginx.pid
  html/              default index page
  lualib/            Lua libraries (resty.*, ngx.*, cjson, ...)
  lua/               LuaJIT jit.* modules
  include/           LuaJIT headers (for building C modules)
  lua51.dll          LuaJIT runtime DLL
  pod/               offline documentation for restydoc
  resty, resty.bat   run Lua code with the OpenResty stack
  restydoc(.bat)     offline documentation browser
  restydoc-index(.bat)
  COPYRIGHT

Quick start (cmd.exe or PowerShell)
-----------------------------------
  cd <this folder>
  start nginx
  tasklist /fi "imagename eq nginx.exe"
  nginx -s reload
  nginx -s quit

  resty -e "ngx.say('Hello, OpenResty!')"     (requires Perl in PATH)

Notes
-----
* This is the native Windows port: select() only, a single worker, and
  FD_SETSIZE=1024 (about 1024 concurrent connections). Use it for development;
  for production run OpenResty on Linux, WSL2 or Docker.
* There is no Windows service integration; use start/nginx -s or a wrapper
  such as NSSM if you need one.
* bin paths are relative, so the whole folder can be moved or renamed freely.
EOF
fi

printf '  top level: '
( cd "$PKGDIR" && printf '%s ' * )
printf '\n'

# Debug symbols are deliberately KEPT, exactly like the official Windows
# package ("Debug symbols are enabled even in release builds"). No strip step.

rm -f "$ZIP"
if command -v zip >/dev/null 2>&1; then
    ( cd "$WORK" && zip -qr "$ZIP" "$PKG" ) || die "zip failed for $ZIP"
else
    ( cd "$WORK" && tar -czf "$OUT_DIR/$PKG.tar.gz" "$PKG" ) || die "tar failed"
    ZIP="$OUT_DIR/$PKG.tar.gz"
fi

# Prove the layout: the first entry must be "$PKG/" (or "$PKG/./").
# NOTE: use `sed -n '1p'`, not `head -n1`. Under `set -o pipefail`, head exits
# after one line and the producer dies of SIGPIPE (exit 141), which would abort
# the script right after a perfectly good package was built.
FIRST_ENTRY=""
case "$ZIP" in
    *.zip)
        if command -v unzip >/dev/null 2>&1; then
            FIRST_ENTRY="$(unzip -Z1 "$ZIP" 2>/dev/null | sed -n '1p')"
        fi
        ;;
    *.tar.gz)
        FIRST_ENTRY="$(tar -tzf "$ZIP" 2>/dev/null | sed -n '1p')"
        ;;
esac
case "$FIRST_ENTRY" in
    "$PKG"/*) log "archive layout ok: everything is under $PKG/" ;;
    "")       log "could not inspect the archive (no unzip/tar)" ;;
    *)        die "archive does not contain the $PKG/ top-level directory (first entry: $FIRST_ENTRY)" ;;
esac

log "done in $((SECONDS - T0))s"
ls -lh "$ZIP"
printf '\nPackage ready: %s\nExtract it somewhere; it unpacks into %s/ and contains nginx.exe.\n' "$ZIP" "$PKG"

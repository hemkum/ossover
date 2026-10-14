#!/bin/bash
# engine/package.sh — assemble engine/out/<engineId>/ from engine/staging plus the pinned
# graphics/runtime inputs, make it relocatable and signed, write manifest.json + SHA256SUMS,
# then tar it to engine/out/<engineId>.tar.xz (+ .sha256).
#
# Plan: ~/.claude/plans/i-am-building-ossover-virtual-turtle.md §5 "Packaging" and
# "Engine layout"; manifest shape = Sources/OssoverKit/Model/EngineManifest.swift (written by
# engine/manifest.py; `ossover engine validate-manifest` decodes it with the same model).
#
# REA-backed rules this script implements (docs/rea/decisions.md 27-32, ledger rows in brackets):
#   - every Mach-O carries its own LC_RPATH set; nothing depends on the loader's rpath [L-12,
#     L-64]; the overlay winemetal.so gets sane rpaths (CrossOver's is malformed) [L-64]
#   - minMacOS = max(toolchain floor, overlay floor): 14.0 for DXMT/D3DMetal overlays [L-62, L-78]
#   - capabilities.esync=false on the CX tree [L-32]; wineVersionString read from ntdll.so [L-45]
#   - DXMT 0.80 / MoltenVK 1.4.2 are newer than CX's pins and stay gated capabilities, MoltenVK
#     reachable through the .so rpaths (win32u.so dlopens it) [L-29, L-49]
#   - single loader, no preloader, relocatable tarball, mono/gecko pins [L-49, L-50, L-51, L-52]
#
# Reference recipes this adapts:
#   - frankea/winecx-gptk .github/workflows/build.yml "install and package": install-lib tree,
#     loader symlinks, strip numbers, dylib closure walk + @loader_path rewrite, the two-iconv
#     rule, rpath on the unix modules, dxmt/dxvk/moltenvk payload handling
#   - gauthierpiarrette/highball-engine build.yml: addons into share/wine, winemetal.dll as a
#     builtin so a fresh prefix carries its placeholder, PE strip batch
#   - highball-engine gstreamer/prune.py: plugin selection ideas (we bundle the MacPorts set
#     minus X11/GL sinks and walk the closure instead of a keep-list)
#
# Layout produced (plan §5):
#   <id>/manifest.json  SHA256SUMS
#   <id>/wine/{bin, lib/wine/{x86_64-unix,x86_64-windows,i386-windows}, lib/*.dylib,
#              lib/gstreamer-1.0, libexec/gstreamer-1.0/gst-plugin-scanner, share/wine/{mono,gecko}}
#   <id>/overlays/{dxmt/{x86_64-unix,x86_64-windows,i386-windows}, dxvk/{x86_64-windows,i386-windows}}
#
# bash 3.2 compatible. Paths may contain spaces (everything is quoted; lists are NUL/line based).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ENGINE_DIR="$SCRIPT_DIR"
INPUTS_JSON="$ENGINE_DIR/inputs.json"
PATCHES_DIR="$ENGINE_DIR/patches"
OUT="$ENGINE_DIR/out"

usage() {
  cat <<EOF
usage: $(basename "$0") [options]

Packages engine/staging (from build.sh --install) into engine/out/<engineId>/ and a tarball.

options:
  --no-strip               keep symbols (PE --strip-debug and unix strip -x -S are skipped)
  --no-sign                skip ad-hoc codesign (the codesign gate will then fail; debugging only)
  --no-tar                 stop after manifest.json + SHA256SUMS; no .tar.xz
  --no-winemetal-builtin   do not copy DXMT's winemetal.{so,dll} into the engine's own builtin
                           dirs (then a fresh prefix has no placeholder and DXMT's dxgi cannot
                           find winemetal.dll — highball-engine, 2026-09-04)
  --gst-exclude RE         extended regex of gstreamer plugin basenames to leave out
                           (default: $GST_EXCLUDE_RE_DEFAULT)
  --jobs N                 parallelism for the strip batches (default: hw.ncpu)
  --keep-tmp               keep engine/work/pkg-tmp
  --help

inputs:   engine/inputs.json, engine/staging/<prefix>/{bin,lib,share}, engine/work/dl/*,
          engine/work/build/include/config.h (for the dlopen'd sonames; optional),
          /opt/local/lib (MacPorts x86_64 closure), /opt/local/lib/gstreamer-1.0
outputs:  engine/out/<engineId>/, engine/out/<engineId>.tar.xz, engine/out/<engineId>.tar.xz.sha256
log:      engine/work/logs/package.log
EOF
}

GST_EXCLUDE_RE_DEFAULT='^libgst(ximagesink|xvimagesink|opengl|gtk|qml6?|qt5?|wayland|python|cairo|pango|rsvg|gdkpixbuf|x11)'
STRIP=1 SIGN=1 TAR=1 WINEMETAL_BUILTIN=1 KEEP_TMP=0
GST_EXCLUDE_RE="$GST_EXCLUDE_RE_DEFAULT"
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
while [ $# -gt 0 ]; do
  case "$1" in
    --no-strip) STRIP=0 ;;
    --no-sign) SIGN=0 ;;
    --no-tar) TAR=0 ;;
    --no-winemetal-builtin) WINEMETAL_BUILTIN=0 ;;
    --gst-exclude) shift; GST_EXCLUDE_RE="${1:-}" ;;
    --jobs) shift; JOBS="${1:-}" ;;
    --jobs=*) JOBS="${1#--jobs=}" ;;
    --keep-tmp) KEEP_TMP=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
case "$JOBS" in ''|*[!0-9]*) echo "--jobs must be a positive integer" >&2; exit 2 ;; esac

log()  { printf '[package] %s\n' "$*"; }
warn() { printf '[package] WARNING: %s\n' "$*" >&2; }
die()  { printf '[package] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
resolve_dir() { (cd -P "$1" 2>/dev/null && pwd -P); }

# ---------------------------------------------------------------------------------------------
# locations (engine/work and engine/staging may be symlinks made by build.sh)
# ---------------------------------------------------------------------------------------------
[ -d "$ENGINE_DIR/work" ] || die "engine/work does not exist; run build.sh first"
[ -d "$ENGINE_DIR/staging" ] || die "engine/staging does not exist; run build.sh --install first"
WORK=$(resolve_dir "$ENGINE_DIR/work")
STAGING=$(resolve_dir "$ENGINE_DIR/staging")
DL="$WORK/dl"
LOGS="$WORK/logs"
TMP="$WORK/pkg-tmp"
mkdir -p "$LOGS" "$OUT"
rm -rf "$TMP"; mkdir -p "$TMP"
exec > >(tee -a "$LOGS/package.log") 2>&1
log "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) package.sh $* ====="

for t in otool install_name_tool codesign lipo strip nm shasum tar python3 x86_64-w64-mingw32-strip; do
  have "$t" || die "missing tool: $t"
done

T0=$SECONDS; TP=$SECONDS
phase() { log "phase $1: $((SECONDS - TP))s (total $((SECONDS - T0))s)"; TP=$SECONDS; }

# ---------------------------------------------------------------------------------------------
# inputs.json (same loader as build.sh)
# ---------------------------------------------------------------------------------------------
load_inputs() {
  [ -f "$INPUTS_JSON" ] || die "missing $INPUTS_JSON"
  eval "$(python3 -I - "$INPUTS_JSON" <<'PY'
import json, shlex, sys
d = json.load(open(sys.argv[1]))
def q(x):
    if x is None: x = ""
    elif isinstance(x, bool): x = "true" if x else "false"
    return shlex.quote(str(x))
print("INPUTS_SCHEMA=%s" % q(d.get("schema")))
print("ENGINE_ID=%s" % q(d.get("engineId")))
inputs = d.get("inputs", {})
print("INPUT_NAMES=%s" % q(" ".join(inputs.keys())))
for n, e in inputs.items():
    k = n.replace("-", "_")
    for f in ("url", "sha256", "size", "license", "subdir", "dylib", "optional"):
        print("IN_%s_%s=%s" % (k, f, q(e.get(f))))
tc = d.get("toolchain", {})
print("TC_DEPLOYMENT_TARGET=%s" % q(tc.get("macosx_deployment_target", "15.0")))
print("TC_PORTS=%s" % q(" ".join(tc.get("macports", {}).get("ports", []))))
print("PATCH_LIST=%s" % q(" ".join(d.get("patches", []))))
PY
)"
  [ "$INPUTS_SCHEMA" = "ossover-engine-inputs/1" ] || die "unexpected inputs.json schema '$INPUTS_SCHEMA'"
  [ -n "$ENGINE_ID" ] || die "inputs.json has no engineId"
}
input_field() { local var="IN_$(printf '%s' "$1" | tr '-' '_')_$2"; printf '%s' "${!var:-}"; }
dl_path() { printf '%s/%s' "$DL" "$(basename "$(input_field "$1" url)")"; }

# verified_input <name>: prints the path of a downloaded+verified input, or nothing if it is an
# optional input that is absent. Dies on a missing required input or a sha mismatch/TBD.
verified_input() {
  local name=$1 f want got
  f=$(dl_path "$name"); want=$(input_field "$name" sha256)
  if [ ! -f "$f" ]; then
    if [ "$(input_field "$name" optional)" = true ]; then return 0; fi
    die "input $name is not downloaded ($f); run build.sh --fetch"
  fi
  [ "$want" != "TBD" ] && [ -n "$want" ] || die "input $name has sha256 TBD; run build.sh --fetch --pin"
  got=$(sha256_of "$f")
  [ "$got" = "$want" ] || die "input $name: $f sha256 $got != pinned $want"
  printf '%s' "$f"
}

load_inputs

# ---------------------------------------------------------------------------------------------
# staging root
# ---------------------------------------------------------------------------------------------
PREFIX=/opt/ossover/engine
if [ -f "$STAGING/.ossover-install-stamp" ]; then
  p=$(sed -n 's/^prefix=//p' "$STAGING/.ossover-install-stamp"); [ -n "$p" ] && PREFIX=$p
fi
SROOT="$STAGING$PREFIX"
[ -f "$SROOT/lib/wine/x86_64-unix/ntdll.so" ] || die "no install-lib tree at $SROOT (run build.sh --install)"

E="$OUT/$ENGINE_ID"
LIB="$E/wine/lib"
BIN="$E/wine/bin"
UNIX="$LIB/wine/x86_64-unix"
PE64="$LIB/wine/x86_64-windows"
PE32="$LIB/wine/i386-windows"
GSTDIR="$LIB/gstreamer-1.0"
BAD_RE='/opt/local/|/opt/homebrew/|/usr/local/|/nix/'

log "engine id: $ENGINE_ID"
log "staging:   $SROOT"
log "output:    $E"

# ---------------------------------------------------------------------------------------------
# Mach-O helpers
# ---------------------------------------------------------------------------------------------
is_macho() {
  local m; m=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$m" in cffaedfe|cefaedfe|cafebabe) return 0 ;; *) return 1 ;; esac
}
# every Mach-O in the engine (PE dirs pruned), one path per line, sorted
list_machos() {
  local dirs=() d
  for d in "$E/wine/bin" "$E/wine/lib" "$E/wine/libexec" "$E/overlays"; do [ -d "$d" ] && dirs+=("$d"); done
  [ ${#dirs[@]} -gt 0 ] || return 0
  find "${dirs[@]}" -type d -name '*-windows' -prune -o -type f -print 2>/dev/null | LC_ALL=C sort \
    | while IFS= read -r f; do is_macho "$f" && printf '%s\n' "$f"; done
  return 0
}
scan_abs() { # absolute non-system load commands of one Mach-O (id line included for dylibs)
  otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -E "^($BAD_RE)" || true
}
needs_system_iconv() { # the binary imports Apple's _iconv (not GNU's _libiconv): leave it on /usr/lib
  nm -u "$1" 2>/dev/null | grep -qE '^_iconv(_open|_close)?$'
}
strip_unix() {
  [ "$STRIP" = 1 ] || return 0
  if ! strip -x -S "$1" >"$TMP/strip.err" 2>&1; then
    warn "strip failed on $1: $(tail -1 "$TMP/strip.err")"
  fi
}

# ---------------------------------------------------------------------------------------------
# 1. layout: copy the install-lib tree
# ---------------------------------------------------------------------------------------------
rm -rf "$E"
mkdir -p "$E/wine" "$E/overlays"
cp -R "$SROOT/bin" "$BIN"        # destinations must not pre-exist or cp -R nests the tree
cp -R "$SROOT/lib" "$LIB"
cp -R "$SROOT/share" "$E/wine/share"
mkdir -p "$GSTDIR"
chmod -R u+w "$E"
[ -d "$PE32" ] || die "no i386-windows in the staging tree"
a=$(find "$LIB/wine" -name '*.a' | wc -l | tr -d ' ')
[ "$a" = 0 ] || { warn "install-lib brought in $a import libraries; deleting"; find "$LIB/wine" -name '*.a' -delete; }
rm -rf "$LIB/wine/i386-unix" 2>/dev/null || true   # wow64-only engine (plan §5)

# The loader. Wine 11 may install it beside ntdll.so (lib/wine/x86_64-unix/wine) with bin/
# holding only wineserver; loader/main.c dlopens ntdll.so out of its own realpath'd directory,
# so a *copy* into bin dies ("could not load ntdll.so") but symlinks are fine (winecx-gptk).
if [ -f "$UNIX/wine" ] && [ ! -e "$BIN/wine" ]; then
  for n in wine wine64 wineloader; do ln -sfn ../lib/wine/x86_64-unix/wine "$BIN/$n"; done
  log "loader in x86_64-unix; bin/{wine,wine64,wineloader} symlinked"
elif [ -f "$BIN/wine" ]; then
  [ -e "$BIN/wine64" ] || ln -sfn wine "$BIN/wine64"
  log "loader in bin/wine"
else
  die "no wine loader in $BIN or $UNIX"
fi
[ -x "$BIN/wineserver" ] || die "no $BIN/wineserver"
# Single `wine` loader, no preloader: CrossOver ships none either (`wineloader` + the copy beside
# ntdll.so, both plain loaders; REA L-52), and the x86_64 preloader is not built with Xcode >= 15.3
# (plan §5). Harmless if present.
rm -f "$BIN/wine-preloader" 2>/dev/null || true
phase "layout"

# ---------------------------------------------------------------------------------------------
# 2. wine-mono + wine-gecko into share/wine (extracted form: mscoree/mshtml load them straight
#    from the datadir; the .msi form costs ~180 MB per bottle). The pins (10.4.1 / 2.47.4) match
#    what CrossOver 26.3.0 ships and what dlls/appwiz.cpl/addons.c wants (REA L-49; decision 30).
# ---------------------------------------------------------------------------------------------
MONO_TAR=$(verified_input wine-mono)
GECKO32_TAR=$(verified_input wine-gecko-x86)
GECKO64_TAR=$(verified_input wine-gecko-x86_64)
mkdir -p "$E/wine/share/wine/mono" "$E/wine/share/wine/gecko"
tar -xJf "$MONO_TAR" -C "$E/wine/share/wine/mono"
tar -xJf "$GECKO32_TAR" -C "$E/wine/share/wine/gecko"
tar -xJf "$GECKO64_TAR" -C "$E/wine/share/wine/gecko"
MONO_VER=$(basename "$MONO_TAR" | sed -n 's/^wine-mono-\([0-9.]*\)-x86\.tar\.xz$/\1/p')
GECKO_VER=$(basename "$GECKO64_TAR" | sed -n 's/^wine-gecko-\([0-9.]*\)-x86_64\.tar\.xz$/\1/p')
[ -d "$E/wine/share/wine/mono/wine-mono-$MONO_VER" ] || die "mono tarball layout changed (no wine-mono-$MONO_VER/)"
[ -d "$E/wine/share/wine/gecko/wine-gecko-$GECKO_VER-x86" ] || die "gecko x86 tarball layout changed"
[ -d "$E/wine/share/wine/gecko/wine-gecko-$GECKO_VER-x86_64" ] || die "gecko x86_64 tarball layout changed"
if [ -f "$WORK/wine/dlls/appwiz.cpl/addons.c" ]; then
  mh=$(sed -n 's/^#define MONO_VERSION "\(.*\)"/\1/p' "$WORK/wine/dlls/appwiz.cpl/addons.c")
  gh=$(sed -n 's/^#define GECKO_VERSION "\(.*\)"/\1/p' "$WORK/wine/dlls/appwiz.cpl/addons.c")
  [ "$mh" = "$MONO_VER" ] || warn "addons.c wants wine-mono $mh, bundled $MONO_VER"
  [ "$gh" = "$GECKO_VER" ] || warn "addons.c wants wine-gecko $gh, bundled $GECKO_VER"
fi
log "addons: wine-mono $MONO_VER, wine-gecko $GECKO_VER (x86, x86_64)"
phase "addons"

# ---------------------------------------------------------------------------------------------
# 3. MoltenVK: Khronos' universal dylib thinned to x86_64 (winevulkan dlopens libMoltenVK.dylib
#    by soname; no Vulkan loader needed)
# ---------------------------------------------------------------------------------------------
MVK_TAR=$(verified_input moltenvk)
MVK_MEMBER=$(input_field moltenvk dylib)
[ -n "$MVK_MEMBER" ] || MVK_MEMBER="MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
mkdir -p "$TMP/mvk"
tar -xf "$MVK_TAR" -C "$TMP/mvk" "$MVK_MEMBER" || die "member $MVK_MEMBER not in $MVK_TAR (tar tf it and fix inputs.json 'dylib')"
case "$(lipo -archs "$TMP/mvk/$MVK_MEMBER")" in
  *x86_64*arm64*|*arm64*x86_64*) lipo -thin x86_64 "$TMP/mvk/$MVK_MEMBER" -output "$LIB/libMoltenVK.dylib" ;;
  x86_64) cp "$TMP/mvk/$MVK_MEMBER" "$LIB/libMoltenVK.dylib" ;;
  *) die "libMoltenVK.dylib has no x86_64 slice ($(lipo -archs "$TMP/mvk/$MVK_MEMBER"))" ;;
esac
chmod u+w "$LIB/libMoltenVK.dylib"
log "moltenvk: $(lipo -archs "$LIB/libMoltenVK.dylib") $(du -h "$LIB/libMoltenVK.dylib" | cut -f1)"
phase "moltenvk"

# ---------------------------------------------------------------------------------------------
# 4. GStreamer plugins + scanner from MacPorts, and the libraries Wine dlopens by bare soname
#    (never load commands, so the closure walk below cannot discover them; the names come from
#    the build's config.h so a configure change cannot silently drop one)
# ---------------------------------------------------------------------------------------------
[ -d /opt/local/lib/gstreamer-1.0 ] || die "/opt/local/lib/gstreamer-1.0 missing; MacPorts gstreamer1 ports not installed"
n=0; x=0
while IFS= read -r p; do
  b=$(basename "$p")
  if printf '%s' "$b" | grep -qE "$GST_EXCLUDE_RE"; then x=$((x + 1)); continue; fi
  cp -L "$p" "$GSTDIR/$b"; chmod u+w "$GSTDIR/$b"; n=$((n + 1))
done < <(find /opt/local/lib/gstreamer-1.0 -maxdepth 1 -name 'libgst*.dylib' | LC_ALL=C sort)
log "gstreamer plugins: $n copied, $x excluded by /$GST_EXCLUDE_RE/"
[ "$n" -gt 50 ] || warn "only $n gstreamer plugins (gate wants > 50)"
HAS_SCANNER=false
if [ -x /opt/local/libexec/gstreamer-1.0/gst-plugin-scanner ]; then
  mkdir -p "$E/wine/libexec/gstreamer-1.0"
  cp -L /opt/local/libexec/gstreamer-1.0/gst-plugin-scanner "$E/wine/libexec/gstreamer-1.0/"
  chmod u+w "$E/wine/libexec/gstreamer-1.0/gst-plugin-scanner"
  HAS_SCANNER=true
  log "gst-plugin-scanner bundled (libexec/gstreamer-1.0)"
else
  warn "no /opt/local/libexec/gstreamer-1.0/gst-plugin-scanner; GStreamer will scan plugins in-process"
fi

sonames=""
if [ -f "$WORK/build/include/config.h" ]; then
  sonames=$(sed -n 's/^#define SONAME_LIB[A-Z0-9_]* "\(.*\)"/\1/p' "$WORK/build/include/config.h")
else
  warn "no $WORK/build/include/config.h; using the default soname list"
  sonames="libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib libMoltenVK.dylib"
fi
for s in $sonames; do
  case "$s" in
    */*) warn "config.h soname is a path, not a bare name: $s (relocation will not cover it)"; s=$(basename "$s") ;;
  esac
  [ "$s" = libMoltenVK.dylib ] && continue           # placed above from the Khronos tar
  if [ -e "$LIB/$s" ]; then continue; fi
  if [ -f "/opt/local/lib/$s" ]; then
    cp -L "/opt/local/lib/$s" "$LIB/$s"; chmod u+w "$LIB/$s"
    log "soname seed: $s"
  else
    warn "dlopen'd soname $s not found in /opt/local/lib (ok only if that subsystem is unused)"
  fi
done
# the reference runtimes also ship the unversioned freetype name
[ -e "$LIB/libfreetype.6.dylib" ] && ln -sfn libfreetype.6.dylib "$LIB/libfreetype.dylib"
phase "gstreamer + sonames"

# ---------------------------------------------------------------------------------------------
# 5. strip Wine's own output (before the overlays land so DXMT/DXVK files are untouched)
#    PE: gcc emits DWARF nothing removes; ntdll.dll is ~3-4.7 MB unstripped vs 0.7 MB stock.
# ---------------------------------------------------------------------------------------------
if [ "$STRIP" = 1 ]; then
  before=$(du -sm "$E" | cut -f1)
  # batched: GNU strip reports a non-COFF file (.tlb, .nls) and keeps going with the batch
  find "$PE64" "$PE32" -type f -print0 \
    | xargs -0 -P "$JOBS" -n 64 x86_64-w64-mingw32-strip --strip-debug 2>/dev/null || true
  while IFS= read -r f; do
    [ -L "$f" ] && continue
    strip_unix "$f"
  done < <(list_machos)
  log "strip: ${before} MB -> $(du -sm "$E" | cut -f1) MB"
  nt=$(wc -c < "$PE64/ntdll.dll" | tr -d ' ')
  [ "$nt" -lt 1500000 ] || warn "ntdll.dll is $nt bytes after strip (gate wants < 1.5 MB)"
else
  log "strip: skipped (--no-strip)"
fi
phase "strip"

# ---------------------------------------------------------------------------------------------
# 6. overlays: DXMT (required) and DXVK (optional). Layouts verified at run time with tar tf.
# ---------------------------------------------------------------------------------------------
tar_root() { tar -tf "$1" | head -1 | cut -d/ -f1; }
find_dir() { find "$1" -maxdepth "$2" -type d -name "$3" | head -1; }

DXMT_TAR=$(verified_input dxmt)
mkdir -p "$TMP/dxmt"; tar -xzf "$DXMT_TAR" -C "$TMP/dxmt"
DXMT_ROOT=$(tar_root "$DXMT_TAR")
log "dxmt tarball root: $DXMT_ROOT/ ; members: $(tar -tzf "$DXMT_TAR" | wc -l | tr -d ' ')"
mkdir -p "$E/overlays/dxmt"
for d in x86_64-unix x86_64-windows i386-windows; do
  src=$(find_dir "$TMP/dxmt" 3 "$d")
  [ -n "$src" ] || die "dxmt tarball has no $d/ directory (tar tzf $DXMT_TAR); plan §5 [A] assumption failed"
  cp -R "$src" "$E/overlays/dxmt/$d"
done
find "$TMP/dxmt" -maxdepth 2 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \) -exec cp {} "$E/overlays/dxmt/" \; 2>/dev/null || true
for f in x86_64-unix/winemetal.so x86_64-windows/winemetal.dll x86_64-windows/d3d11.dll x86_64-windows/dxgi.dll; do
  [ -f "$E/overlays/dxmt/$f" ] || die "dxmt overlay lacks $f"
done
DXMT_VER=$(printf '%s' "$(input_field dxmt url)" | sed -n 's|.*/v\([0-9.]*\)/.*|\1|p')
log "dxmt $DXMT_VER: $(ls "$E/overlays/dxmt/x86_64-windows" | tr '\n' ' ')"

HAS_DXVK=false
DXVK_TAR=$(verified_input dxvk-macos)
if [ -n "$DXVK_TAR" ]; then
  mkdir -p "$TMP/dxvk"; tar -xzf "$DXVK_TAR" -C "$TMP/dxvk"
  log "dxvk tarball root: $(tar_root "$DXVK_TAR")/"
  # The pinned "-builtin" repack already uses Wine's builtin layout (x86_64-windows/ and
  # i386-windows/, each with d3d10core.dll + d3d11.dll; tar tzf verified 2026-10-14); the plain
  # repack has x64/ + x32/. Accept either.
  x64=$(find_dir "$TMP/dxvk" 3 x86_64-windows); x32=$(find_dir "$TMP/dxvk" 3 i386-windows)
  if [ -z "$x64" ]; then x64=$(find_dir "$TMP/dxvk" 3 x64); x32=$(find_dir "$TMP/dxvk" 3 x32); fi
  if [ -n "$x64" ] && [ -f "$x64/d3d11.dll" ]; then
    mkdir -p "$E/overlays/dxvk"
    cp -R "$x64" "$E/overlays/dxvk/x86_64-windows"
    [ -n "$x32" ] && cp -R "$x32" "$E/overlays/dxvk/i386-windows"
    find "$TMP/dxvk" -maxdepth 2 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \) -exec cp {} "$E/overlays/dxvk/" \; 2>/dev/null || true
    HAS_DXVK=true
    log "dxvk: $(ls "$E/overlays/dxvk/x86_64-windows" | tr '\n' ' ')"
  else
    warn "dxvk tarball has no x86_64-windows/d3d11.dll or x64/d3d11.dll (tar tzf $DXVK_TAR); overlay skipped"
  fi
else
  warn "dxvk-macos not downloaded (optional); overlays/dxvk skipped"
fi

# DXMT's bridge as an engine builtin: wineboot writes system32 placeholders only for the
# engine's own builtins, and the loader will not load a non-16-bit builtin that has no file in
# the prefix (find_builtin_without_file). The overlay copy still wins through
# WINEDLLPATH_PREPEND because it is searched first. Only winemetal — never dxgi/d3d11, which
# would make every fresh prefix run DXMT silently (winecx-gptk).
WINEMETAL_BUILTIN_DONE=false
if [ "$WINEMETAL_BUILTIN" = 1 ]; then
  cp "$E/overlays/dxmt/x86_64-unix/winemetal.so" "$UNIX/winemetal.so"
  cp "$E/overlays/dxmt/x86_64-windows/winemetal.dll" "$PE64/winemetal.dll"
  [ -f "$E/overlays/dxmt/i386-windows/winemetal.dll" ] && cp "$E/overlays/dxmt/i386-windows/winemetal.dll" "$PE32/winemetal.dll"
  WINEMETAL_BUILTIN_DONE=true
  log "winemetal.{so,dll} copied into the builtin dirs (placeholder for fresh prefixes)"
fi
for d in d3d11 dxgi d3d10core; do
  if strings -a "$PE64/$d.dll" 2>/dev/null | grep -q 'DXMT_\|dxmt\.con'; then die "builtin $d.dll is DXMT's, not Wine's"; fi
done
phase "overlays"

# ---------------------------------------------------------------------------------------------
# 7. dependency closure: every /opt/local dylib any Mach-O links, recursively, into wine/lib
# ---------------------------------------------------------------------------------------------
n_copied=0
queue=()
while IFS= read -r f; do queue+=("$f"); done < <(list_machos)
i=0
while [ "$i" -lt "${#queue[@]}" ]; do
  f=${queue[$i]}; i=$((i + 1))
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    dbase=$(basename "$dep")
    [ -e "$LIB/$dbase" ] && continue
    case "$dbase" in libiconv*.dylib) if needs_system_iconv "$f"; then continue; fi ;; esac
    [ -f "$dep" ] || die "$f references $dep which does not exist on this Mac"
    cp -L "$dep" "$LIB/$dbase"; chmod u+w "$LIB/$dbase"
    strip_unix "$LIB/$dbase"
    queue+=("$LIB/$dbase")
    n_copied=$((n_copied + 1))
    printf '  + %-40s (for %s)\n' "$dbase" "$(basename "$f")"
  done < <(scan_abs "$f")
done
log "closure: $n_copied dylibs copied into wine/lib ($(ls "$LIB" | grep -c '\.dylib' || true) dylibs total)"
phase "closure"

# ---------------------------------------------------------------------------------------------
# 8. rewrite ids and load commands to @loader_path, then give every Mach-O its own LC_RPATH set
#    (@loader_path/<name> for wine/lib siblings, ../../<name> from lib/wine/x86_64-unix,
#     ../<name> for lib/gstreamer-1.0 plugins; /usr/lib and /System are left alone)
#
#    rpath rule (REA L-12, L-64; decision 28). Wine's unix modules name each other by install
#    name (`@rpath/ntdll.so`, `@rpath/win32u.so`, `@rpath/winemac.so` as LC_LOAD_DYLIB) and dlopen
#    freetype/gnutls/SDL2/MoltenVK by bare soname, which dyld tries as `@rpath/<soname>` against
#    the *calling image's* rpaths (L-29: win32u.so dlopens the Vulkan ICD). CrossOver's loader
#    executable has a dead rpath and everything still resolves only because each .so carries
#    `@loader_path/` + `@loader_path/../../../lib64`; its overlay winemetal.so ships one malformed
#    entry (`@loader_path/:@loader_path/../../`) and loads by accident (ntdll.so and winemac.so
#    are already in the process). So every Mach-O here gets the rpaths that reach its siblings
#    and wine/lib from its own location, malformed and builder-path entries are deleted, and
#    nothing relies on the loader executable's rpath. gates.sh rpath_self_contained checks the
#    result image by image; the dlopen sweep runs without DYLD_* help.
# ---------------------------------------------------------------------------------------------
rel_to_lib() { # relative path from dirname($1) to wine/lib ("." for siblings)
  local d; d=$(dirname "$1")
  case "$d" in
    "$LIB") printf '.' ;;
    "$GSTDIR") printf '..' ;;
    "$UNIX") printf '../..' ;;
    "$BIN") printf '../lib' ;;
    "$E/wine/libexec/gstreamer-1.0") printf '../../lib' ;;
    "$E"/overlays/*/x86_64-unix) printf '../../../wine/lib' ;;
    *) python3 -I -c 'import os,sys; sys.stdout.write(os.path.relpath(sys.argv[1], sys.argv[2]))' "$LIB" "$d" ;;
  esac
}
rpaths_of() { # LC_RPATH entries of one Mach-O, one per line, verbatim
  otool -l "$1" 2>/dev/null | awk '/ cmd LC_RPATH/{r=1} r && /^ *path /{sub(/^ *path /,""); sub(/ \(offset [0-9]+\)$/,""); print; r=0}'
}
has_rpath() { rpaths_of "$1" | grep -qxF -- "$2"; }
# wanted_rpaths <file>: the LC_RPATH set a Mach-O at that location must carry (one per line).
# Each set reaches the image's own directory and wine/lib; the overlay unix modules also reach
# lib/wine/x86_64-unix, where their `@rpath/ntdll.so` / `@rpath/winemac.so` live (L-64).
wanted_rpaths() {
  local d; d=$(dirname "$1")
  case "$d" in
    "$UNIX")                          printf '%s\n' '@loader_path/' '@loader_path/../../../lib' ;;
    "$LIB")                           printf '%s\n' '@loader_path/' ;;
    "$GSTDIR")                        printf '%s\n' '@loader_path/' '@loader_path/../' ;;
    "$BIN")                           printf '%s\n' '@loader_path/../lib' ;;
    "$E/wine/libexec/gstreamer-1.0")  printf '%s\n' '@loader_path/../../lib' ;;
    "$E"/overlays/*/x86_64-unix)      printf '%s\n' '@loader_path/' '@loader_path/../../../wine/lib/wine/x86_64-unix' '@loader_path/../../../wine/lib' ;;
    *)                                printf '%s\n' '@loader_path/' ;;
  esac
}
# rpath_args <file>: install_name_tool arguments, one per line, that delete malformed
# (colon-joined, L-64) and builder-path LC_RPATH entries and add the missing wanted ones.
# Deletions come first so they free header space for the additions. (engine/selftest.sh
# extracts rpaths_of/has_rpath/wanted_rpaths/rpath_args by name and runs them on a synthetic tree.)
rpath_args() {
  local f=$1 rp
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    case "$rp" in
      *:*) printf '%s\n' -delete_rpath "$rp" ;;
      /*) if printf '%s' "$rp" | grep -qE "^($BAD_RE)"; then printf '%s\n' -delete_rpath "$rp"; fi ;;
    esac
  done < <(rpaths_of "$f")
  while IFS= read -r rp; do
    has_rpath "$f" "$rp" || printf '%s\n' -add_rpath "$rp"
  done < <(wanted_rpaths "$f")
}

n_fix=0 n_rp_add=0 n_rp_del=0
while IFS= read -r f; do
  [ -L "$f" ] && continue
  base=$(basename "$f"); rel=$(rel_to_lib "$f")
  args=()
  self_id=$(otool -D "$f" 2>/dev/null | sed -n '2p')
  case "$base" in
    *.dylib*) args+=(-id "@loader_path/$base") ;;
    *) case "$self_id" in                      # .so modules: only when the id is an absolute non-system path
         /usr/lib/*|/System/*|"") ;;            # (`@rpath/<name>.so` ids stay: dyld's install-name match depends on them)
         /*) args+=(-id "@loader_path/$base") ;;
       esac ;;
  esac
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    [ "$dep" = "$self_id" ] && continue
    dbase=$(basename "$dep")
    case "$dbase" in
      libiconv*.dylib)
        if needs_system_iconv "$f"; then args+=(-change "$dep" /usr/lib/libiconv.2.dylib); continue; fi ;;
    esac
    [ -e "$LIB/$dbase" ] || die "$f needs $dep but $LIB/$dbase was not bundled (closure bug)"
    if [ "$rel" = . ]; then target="@loader_path/$dbase"; else target="@loader_path/$rel/$dbase"; fi
    args+=(-change "$dep" "$target")
  done < <(scan_abs "$f")
  # rpaths: the wanted set for this location, malformed/builder entries out (rpath_args above)
  while IFS= read -r a; do
    args+=("$a")
    case "$a" in
      -add_rpath) n_rp_add=$((n_rp_add + 1)) ;;
      -delete_rpath) n_rp_del=$((n_rp_del + 1)) ;;
      *:*) printf '  - rpath %s (malformed) from %s\n' "$a" "${f#"$E"/}" ;;
    esac
  done < <(rpath_args "$f")
  if [ "${#args[@]}" -gt 0 ]; then
    if ! install_name_tool "${args[@]}" "$f" > "$TMP/int.err" 2>&1; then
      cat "$TMP/int.err"
      die "install_name_tool failed on $f (headerpad? Wine is linked with -headerpad_max_install_names; a third-party overlay module may lack the room)"
    fi
    grep -v 'invalidate the code signature' "$TMP/int.err" || true
    n_fix=$((n_fix + 1))
  fi
done < <(list_machos)
log "fixup: $n_fix Mach-O files rewritten; rpaths +$n_rp_add/-$n_rp_del"

# nothing absolute may be left, and every image carries its rpath set (gates.sh checks again)
left=0
while IFS= read -r f; do
  while IFS= read -r dep; do [ -n "$dep" ] && { echo "  still absolute: $f -> $dep"; left=$((left + 1)); }; done < <(scan_abs "$f")
  while IFS= read -r rp; do has_rpath "$f" "$rp" || { echo "  missing rpath: $f needs $rp"; left=$((left + 1)); }; done < <(wanted_rpaths "$f")
done < <(list_machos)
[ "$left" = 0 ] || die "$left absolute reference(s) / missing rpath(s) remain"
phase "fixup"

# ---------------------------------------------------------------------------------------------
# 9. ad-hoc codesign, after every byte-level change (strip/install_name_tool invalidate it)
# ---------------------------------------------------------------------------------------------
if [ "$SIGN" = 1 ]; then
  list_machos | while IFS= read -r f; do [ -L "$f" ] || printf '%s\0' "$f"; done \
    | xargs -0 -n 40 codesign --force --sign - --timestamp=none 2>&1 | grep -v 'replacing existing signature' || true
  bad=0
  while IFS= read -r f; do
    [ -L "$f" ] && continue
    codesign --verify --strict "$f" >/dev/null 2>&1 || { echo "  unsigned/invalid: $f"; bad=$((bad + 1)); }
  done < <(list_machos)
  [ "$bad" = 0 ] || die "$bad Mach-O file(s) failed codesign --verify"
  log "codesign: ok ($(list_machos | wc -l | tr -d ' ') Mach-O files)"
else
  log "codesign: skipped (--no-sign)"
fi
phase "codesign"

# ---------------------------------------------------------------------------------------------
# 10. manifest.json — the shape Sources/OssoverKit/Model/EngineManifest.swift decodes, written by
#     engine/manifest.py from values measured on the tree, never assumed.
# ---------------------------------------------------------------------------------------------
# has_str <file> <literal>: grep -c reads strings' whole output; `grep -q` would exit at the
# first match, strings would die with SIGPIPE and pipefail would turn the hit into "false"
# (2026-10-14: msync and dllPathPrepend were measured false on an ntdll.so that has both).
has_str() { local n; n=$(strings -a "$1" 2>/dev/null | grep -c -- "$2" || true); [ "${n:-0}" -gt 0 ]; }
minos_of() { otool -l "$1" 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} /LC_VERSION_MIN_MACOSX/{m=1} b&&/minos/{print $2; exit} m&&/version/{print $2; exit}'; }
ver_ge() { # ver_ge A B: A >= B, numeric major.minor[.patch]
  awk -v a="$1" -v b="$2" 'BEGIN{n=split(a,x,"."); split(b,y,"."); for(i=1;i<=3;i++){ai=x[i]+0; bi=y[i]+0; if(ai>bi) exit 0; if(ai<bi) exit 1} exit 0}'
}
CAP_MSYNC=false;  has_str "$UNIX/ntdll.so" WINEMSYNC && CAP_MSYNC=true
# esync is not compiled into the CrossOver 26.3.0 tree: WINEESYNC occurs only in
# dlls/kernel32/tests (REA L-32), so the manifest says false. A WINEESYNC string in ntdll.so
# means this is not the pinned tree (EngineProbe would record true at install, contradicting it).
CAP_ESYNC=false
if has_str "$UNIX/ntdll.so" WINEESYNC; then die "ntdll.so carries a WINEESYNC string: not the CX 26.3.0 tree (REA L-32: esync is absent there)"; fi
CAP_WOW64=false;  [ -d "$PE32" ] && [ ! -d "$LIB/wine/i386-unix" ] && CAP_WOW64=true
CAP_MACDRV=false; nm -gU "$UNIX/winemac.so" 2>/dev/null | grep -q macdrv_functions && CAP_MACDRV=true
CAP_PREPEND=false; has_str "$UNIX/ntdll.so" WINEDLLPATH_PREPEND && CAP_PREPEND=true
CAP_D3DMETAL=false; has_str "$UNIX/ntdll.so" CX_APPLEGPTK_LIBD3DSHARED_PATH && CAP_D3DMETAL=true
log "capabilities: msync=$CAP_MSYNC esync=$CAP_ESYNC wow64=$CAP_WOW64 macdrvExports=$CAP_MACDRV dllPathPrepend=$CAP_PREPEND d3dmetalHost=$CAP_D3DMETAL"

WINE_VERSION=$(sed -n 's/^Wine version \([0-9.]*\).*/\1/p' "$WORK/wine/VERSION" 2>/dev/null || true)
[ -n "$WINE_VERSION" ] || WINE_VERSION=11.0
# wine_build string, read from the binary rather than by running wine under Rosetta (REA L-45:
# CX's ntdll.so holds `wine-11.0-8726-g2e2f5fca349`; a tarball build without git says `wine-11.0`).
# Not ^-anchored: in this build the literal follows a 16-byte hex-digit table with no NUL between
# them, so `strings` prints "0123456789abcdefwine-11.0" (2026-10-14). Anchoring on the VERSION
# file's number keeps "wine-%lx-msync" and friends out.
WINE_VERSION_STRING=$(strings -a "$UNIX/ntdll.so" 2>/dev/null | grep -oE "wine-${WINE_VERSION//./\\.}([-.][0-9A-Za-z]+)*" | head -1 || true)
case "$WINE_VERSION_STRING" in
  "wine-$WINE_VERSION"|"wine-$WINE_VERSION"[-.]*) log "wine_build: $WINE_VERSION_STRING" ;;
  "") warn "no wine-<version> string in ntdll.so; wineVersionString left empty" ;;
  *) warn "ntdll.so says '$WINE_VERSION_STRING' but VERSION says $WINE_VERSION" ;;
esac
CX_VERSION=$(printf '%s' "$(input_field crossover-sources url)" | sed -n 's|.*/crossover-sources-\([0-9.]*\)\.tar\.gz$|\1|p')
REV=$(printf '%s' "$ENGINE_ID" | sed -n 's/.*-r\([0-9]*\)$/\1/p'); [ -n "$REV" ] || REV=0
APPLIED_PATCHES=""
for p in "$PATCHES_DIR"/*.patch; do [ -f "$p" ] && APPLIED_PATCHES="$APPLIED_PATCHES $(basename "$p")"; done
GST_COUNT=$(ls "$GSTDIR" | grep -c '^libgst.*\.dylib$' || true); GST_COUNT=${GST_COUNT:-0}

# minMacOS = max(toolchain floor, overlay floor). DXMT's winemetal.so (and GPTK's libd3dshared /
# D3DMetal, never bundled here) are minos 14.0, so a DXMT/D3DMetal overlay raises the floor to
# 14.0; the plain engine stays at the toolchain's (REA L-62, L-78; decision 29). Measured per
# overlay from its Mach-Os; gates.sh overlay_minos re-checks the shipped tree.
MIN_MACOS="$TC_DEPLOYMENT_TARGET"
OVERLAY_FLOOR=""
DXMT_MINOS=""; DXVK_MINOS=""
for d in "$E"/overlays/*/; do
  [ -d "$d" ] || continue
  kind=$(basename "$d"); kfloor=""
  while IFS= read -r f; do
    case "$f" in "$d"*) ;; *) continue ;; esac
    m=$(minos_of "$f"); [ -n "$m" ] || continue
    if [ -z "$kfloor" ] || ver_ge "$m" "$kfloor"; then kfloor=$m; fi
  done < <(list_machos)
  [ -n "$kfloor" ] || continue
  log "overlay $kind: Mach-O floor macOS $kfloor"
  case "$kind" in dxmt) DXMT_MINOS=$kfloor ;; dxvk) DXVK_MINOS=$kfloor ;; esac
  if [ -z "$OVERLAY_FLOOR" ] || ver_ge "$kfloor" "$OVERLAY_FLOOR"; then OVERLAY_FLOOR=$kfloor; fi
done
if [ -n "$OVERLAY_FLOOR" ] && ! ver_ge "$MIN_MACOS" "$OVERLAY_FLOOR"; then
  log "minMacOS raised from $MIN_MACOS to $OVERLAY_FLOOR by the overlays (REA L-62)"
  MIN_MACOS="$OVERLAY_FLOOR"
fi
# Closure floor: every bundled Mach-O outside overlays/ (Wine's modules, the MacPorts closure,
# the GStreamer plugins). The toolchain floor only holds if MacPorts really built its ports for
# it: a port installed as a prebuilt binary archive carries the builder's macOS as minos
# (2026-10-14: 566 of 567 MacPorts dylibs were minos 26.0 / sdk 26.5 although macports.conf
# said macosx_deployment_target 15.0 - the archives were fetched, not built). The manifest must
# not promise a floor the libraries do not meet, so minMacOS is raised to the measured floor
# and the condition is reported loudly; OSSOVER_STRICT_FLOOR=1 makes it fatal instead. Getting
# back to the toolchain floor means rebuilding the ports from source (README, minos gate).
CLOSURE_FLOOR=""; CLOSURE_ABOVE=0; CLOSURE_N=0
while IFS= read -r f; do
  case "$f" in "$E"/overlays/*) continue ;; esac
  m=$(minos_of "$f"); [ -n "$m" ] || continue
  CLOSURE_N=$((CLOSURE_N + 1))
  if [ -z "$CLOSURE_FLOOR" ] || ver_ge "$m" "$CLOSURE_FLOOR"; then CLOSURE_FLOOR=$m; fi
  ver_ge "$MIN_MACOS" "$m" || CLOSURE_ABOVE=$((CLOSURE_ABOVE + 1))
done < <(list_machos)
if [ -n "$CLOSURE_FLOOR" ] && ! ver_ge "$MIN_MACOS" "$CLOSURE_FLOOR"; then
  warn "$CLOSURE_ABOVE of $CLOSURE_N bundled Mach-O(s) are built for macOS $CLOSURE_FLOOR, above the $MIN_MACOS floor (MacPorts binary archives ignore macosx_deployment_target; rebuild from source: sudo port -N -s upgrade --force installed)"
  if [ "${OSSOVER_STRICT_FLOOR:-0}" = 1 ]; then die "OSSOVER_STRICT_FLOOR=1: not raising minMacOS above the toolchain floor $MIN_MACOS"; fi
  warn "minMacOS raised from $MIN_MACOS to $CLOSURE_FLOOR so the manifest matches the bundled libraries (ossover will refuse older macOS)"
  MIN_MACOS="$CLOSURE_FLOOR"
fi
log "minMacOS: $MIN_MACOS (toolchain $TC_DEPLOYMENT_TARGET, overlays ${OVERLAY_FLOOR:-none}, closure ${CLOSURE_FLOOR:-none}, $CLOSURE_ABOVE above toolchain floor)"

TARBALL="$OUT/$ENGINE_ID.tar.xz"
env OSS_ID="$ENGINE_ID" OSS_VERSION="$CX_VERSION-r$REV" OSS_CX_VERSION="$CX_VERSION" \
    OSS_WINE_VERSION="$WINE_VERSION" OSS_WINE_VERSION_STRING="$WINE_VERSION_STRING" \
    OSS_MIN_MACOS="$MIN_MACOS" OSS_DEPLOYMENT_TARGET="$TC_DEPLOYMENT_TARGET" \
    OSS_OVERLAY_MIN_MACOS="$OVERLAY_FLOOR" OSS_DXMT_MINOS="$DXMT_MINOS" OSS_DXVK_MINOS="$DXVK_MINOS" \
    OSS_CLOSURE_MIN_MACOS="$CLOSURE_FLOOR" OSS_CLOSURE_ABOVE="$CLOSURE_ABOVE" \
    OSS_CAP_MSYNC="$CAP_MSYNC" OSS_CAP_ESYNC="$CAP_ESYNC" OSS_CAP_WOW64="$CAP_WOW64" \
    OSS_CAP_MACDRV="$CAP_MACDRV" OSS_CAP_PREPEND="$CAP_PREPEND" OSS_CAP_D3DMETAL="$CAP_D3DMETAL" \
    OSS_HAS_DXVK="$HAS_DXVK" OSS_HAS_SCANNER="$HAS_SCANNER" OSS_WINEMETAL_BUILTIN="$WINEMETAL_BUILTIN_DONE" \
    OSS_DXMT_VERSION="$DXMT_VER" OSS_MONO_VERSION="$MONO_VER" OSS_GECKO_VERSION="$GECKO_VER" \
    OSS_GST_COUNT="$GST_COUNT" OSS_PATCHES="${APPLIED_PATCHES# }" OSS_PATCH_LIST="$PATCH_LIST" \
    OSS_PORTS="$TC_PORTS" OSS_INPUTS_SHA="$(sha256_of "$INPUTS_JSON")" \
    OSS_TARBALL="$TARBALL" \
    OSS_HOST_OS="$(sw_vers -productVersion 2>/dev/null || echo '?')" \
    OSS_SDK="$(xcrun --show-sdk-version 2>/dev/null || echo '?')" \
    OSS_CLANG="$(clang --version 2>/dev/null | head -1)" \
    OSS_MINGW="$(x86_64-w64-mingw32-gcc --version 2>/dev/null | head -1)" \
    OSS_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    OSS_STAMP="$(cat "$STAGING/.ossover-install-stamp" 2>/dev/null | tr '\n' ';')" \
  python3 -I "$ENGINE_DIR/manifest.py" "$INPUTS_JSON" "$E/manifest.json"
phase "manifest"

# ---------------------------------------------------------------------------------------------
# 11. SHA256SUMS (regular files, relative paths, sorted; symlinks are carried by the tar)
# ---------------------------------------------------------------------------------------------
write_sums() {
  (cd "$E" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | sed 's|  \./|  |') > "$E/SHA256SUMS"
}
write_sums
log "SHA256SUMS: $(wc -l < "$E/SHA256SUMS" | tr -d ' ') files"
du -sh "$E" | sed 's/^/[package] engine dir size: /'
phase "sha256sums"

# ---------------------------------------------------------------------------------------------
# 12. tarball + sidecar, then the out-dir manifest gets its file:// source
# ---------------------------------------------------------------------------------------------
if [ "$TAR" = 1 ]; then
  rm -f "$TARBALL" "$TARBALL.sha256"
  if have xz; then
    # multi-threaded xz (Homebrew); bsdtar's built-in liblzma is single-threaded
    tar -cf - -C "$OUT" "$ENGINE_ID" | xz -T0 -6 > "$TARBALL"
  else
    tar -cJf "$TARBALL" -C "$OUT" "$ENGINE_ID"
  fi
  (cd "$OUT" && shasum -a 256 "$ENGINE_ID.tar.xz" > "$ENGINE_ID.tar.xz.sha256")
  TAR_SHA=$(cut -d' ' -f1 < "$TARBALL.sha256")
  TAR_SIZE=$(wc -c < "$TARBALL" | tr -d ' ')
  log "tarball: $TARBALL ($TAR_SIZE bytes) sha256 $TAR_SHA"
  # The manifest inside the tarball cannot know the tarball's own hash, so it carries
  # `source.sha256: "TBD"` (the unpinned placeholder ArtifactSource accepts); the copy in the out
  # dir gets the real hash and size so `ossover engine install engine/out/<id>/manifest.json`
  # can verify and extract it. url and extract {strip 1, into "."} were set by manifest.py.
  python3 -I - "$E/manifest.json" "$TAR_SHA" "$TAR_SIZE" <<'PY'
import json, sys
mp, sha, size = sys.argv[1:4]
m = json.load(open(mp))
m["source"]["sha256"] = sha
m["source"]["size"] = int(size)
with open(mp, "w") as f:
    json.dump(m, f, indent=2, ensure_ascii=False); f.write("\n")
PY
  msum=$(sha256_of "$E/manifest.json")
  awk -v s="$msum" '$2 == "manifest.json" { print s "  manifest.json"; next } { print }' "$E/SHA256SUMS" > "$E/SHA256SUMS.new" \
    && mv "$E/SHA256SUMS.new" "$E/SHA256SUMS"
  phase "tar"
else
  log "tar: skipped (--no-tar); manifest.json keeps source.sha256 TBD (ossover engine install refuses it)"
fi

[ "$KEEP_TMP" = 1 ] || rm -rf "$TMP"
log "done in $((SECONDS - T0))s"
log "next: $ENGINE_DIR/gates.sh \"$E\"   (set OSSOVER_BIN=<path to ossover> to also decode the manifest with the Swift model)"
log "then: ossover engine install \"$E/manifest.json\""

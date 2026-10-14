#!/bin/bash
# engine/selftest.sh [--keep] [--write-fixture <path>] — exercise the packaging rules that need no
# engine build: the rpath policy of package.sh (rpaths_of / has_rpath / wanted_rpaths /
# rpath_args, extracted by name), manifest.py, and the offline gates of gates.sh (manifest,
# sha256sums, absolute_refs, minos, overlay_minos, rpath_self_contained) on a synthetic engine
# tree of tiny Mach-Os compiled with clang for the host arch. Every expectation below is a
# behaviour the REA pass pinned down (docs/rea/decisions.md 28, 29):
#
#   - an overlay winemetal.so with CrossOver's colon-joined LC_RPATH cannot reach
#     @rpath/winemac.so or @rpath/ntdll.so from its own root (L-64) → rpath_self_contained FAILs
#     before the policy runs and PASSes after it;
#   - the policy adds @loader_path/ + @loader_path/../../../lib to lib/wine/x86_64-unix modules,
#     the overlay set to overlays/*/x86_64-unix, deletes malformed and builder-path entries (L-12);
#   - overlay Mach-Os at minos 14.0 with manifest minMacOS 15.0 pass overlay_minos; minMacOS 13.0
#     or an overlay built for macOS 15 fails it (L-62);
#   - manifest.py's output has the EngineManifest shape (source.extract {strip 1, into "."},
#     esync false, no DYLD_* baseEnv, bundledRenderers layouts) → the manifest gate passes and,
#     with OSSOVER_BIN set, so does `ossover engine validate-manifest --layout`.
#
# --write-fixture <path> copies the generated manifest.json there (Tests/Fixtures/manifests/
# package-sh-engine.json is produced this way, so the Swift tests decode exactly what the
# packager writes). Needs: clang, otool, install_name_tool, python3, shasum. bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PACKAGE_SH="$SCRIPT_DIR/package.sh"
GATES_SH="$SCRIPT_DIR/gates.sh"
MANIFEST_PY="$SCRIPT_DIR/manifest.py"
INPUTS_JSON="$SCRIPT_DIR/inputs.json"
KEEP=0 FIXTURE_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --write-fixture) shift; FIXTURE_OUT="${1:-}" ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
for t in clang otool install_name_tool python3 shasum; do command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }; done

N_OK=0 N_BAD=0
ok()   { N_OK=$((N_OK + 1)); printf 'ok   %s\n' "$*"; }
bad()  { N_BAD=$((N_BAD + 1)); printf 'FAIL %s\n' "$*"; }
check() { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$*"; fi; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ossover-selftest.XXXXXX")
[ "$KEEP" = 1 ] || trap 'rm -rf "$ROOT"' EXIT
ENGINE_ID=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["engineId"])' "$INPUTS_JSON")
E="$ROOT/$ENGINE_ID"
LIB="$E/wine/lib"; BIN="$E/wine/bin"; UNIX="$LIB/wine/x86_64-unix"
PE64="$LIB/wine/x86_64-windows"; PE32="$LIB/wine/i386-windows"; GSTDIR="$LIB/gstreamer-1.0"
BAD_RE='/opt/local/|/opt/homebrew/|/usr/local/|/nix/'
mkdir -p "$BIN" "$UNIX" "$PE64" "$PE32" "$GSTDIR" "$E/wine/libexec/gstreamer-1.0" "$E/wine/share/wine" \
         "$E/overlays/dxmt/x86_64-unix" "$E/overlays/dxmt/x86_64-windows" "$E/overlays/dxmt/i386-windows" \
         "$E/overlays/dxvk/x86_64-windows" "$E/overlays/dxvk/i386-windows" "$ROOT/src"
echo "selftest tree: $E"

# ---------------------------------------------------------------------------------------------
# 1. synthetic Mach-Os (host arch; the offline gates only read load commands)
# ---------------------------------------------------------------------------------------------
cat > "$ROOT/src/lib.c" <<'EOF'
int ossover_selftest_symbol(void) { return 1; }
EOF
cat > "$ROOT/src/main.c" <<'EOF'
int main(void) { return 0; }
EOF
CC="clang -mmacosx-version-min=15.0 -Wl,-headerpad_max_install_names"
dylib() { # dylib <out> <install_name> [extra clang args...]
  local out=$1 name=$2; shift 2
  $CC -dynamiclib -install_name "$name" "$@" -o "$out" "$ROOT/src/lib.c" 2>/dev/null
}
# Wine's unix modules: @rpath ids, @rpath deps on each other, the rpath pair Wine's build emits
WINE_RPATHS="-Wl,-rpath,@loader_path/ -Wl,-rpath,@loader_path/../../../lib"
dylib "$UNIX/ntdll.so"  @rpath/ntdll.so  $WINE_RPATHS
dylib "$UNIX/win32u.so" @rpath/win32u.so $WINE_RPATHS "$UNIX/ntdll.so"
dylib "$UNIX/winemac.so" @rpath/winemac.so $WINE_RPATHS "$UNIX/ntdll.so" "$UNIX/win32u.so"
# a wine/lib dylib and a gstreamer plugin (the plugin carries a dead builder rpath, as nix/MacPorts builds do)
dylib "$LIB/libfoo.dylib" @loader_path/libfoo.dylib
dylib "$GSTDIR/libgstselftest.dylib" @loader_path/libgstselftest.dylib -Wl,-rpath,/nix/store/selftest/lib "$LIB/libfoo.dylib"
install_name_tool -change @loader_path/libfoo.dylib @loader_path/../libfoo.dylib "$GSTDIR/libgstselftest.dylib" 2>/dev/null
# the overlay's winemetal.so: CrossOver's malformed single LC_RPATH, minos 14.0, deps on winemac/ntdll (L-64)
clang -mmacosx-version-min=14.0 -Wl,-headerpad_max_install_names -dynamiclib -install_name @rpath/winemetal.so \
  -Wl,-rpath,'@loader_path/:@loader_path/../../' "$UNIX/winemac.so" "$UNIX/ntdll.so" \
  -o "$E/overlays/dxmt/x86_64-unix/winemetal.so" "$ROOT/src/lib.c" 2>/dev/null
cp "$E/overlays/dxmt/x86_64-unix/winemetal.so" "$UNIX/winemetal.so"   # the builtin placeholder copy package.sh makes
# executables: the loader beside ntdll.so (bin/wine is a symlink, as package.sh lays it out), wineserver, the scanner
$CC -o "$UNIX/wine" "$ROOT/src/main.c" 2>/dev/null
ln -s ../lib/wine/x86_64-unix/wine "$BIN/wine"
$CC -o "$BIN/wineserver" "$ROOT/src/main.c" "$LIB/libfoo.dylib" 2>/dev/null
install_name_tool -change @loader_path/libfoo.dylib @loader_path/../lib/libfoo.dylib "$BIN/wineserver" 2>/dev/null
$CC -o "$E/wine/libexec/gstreamer-1.0/gst-plugin-scanner" "$ROOT/src/main.c" 2>/dev/null

# fake PE files: MZ header, e_lfanew = 0x80, "PE\0\0" there; the overlay ones carry Wine's builtin mark (L-25)
fake_pe() { # fake_pe <path> <marked 0|1>
  python3 -I - "$1" "$2" <<'PY'
import struct, sys
path, marked = sys.argv[1], sys.argv[2] == "1"
head = bytearray(0x100)
head[0:2] = b"MZ"; head[0x3C:0x40] = struct.pack("<I", 0x80)
if marked: head[0x40:0x51] = b"Wine builtin DLL\0"
head[0x80:0x84] = b"PE\0\0"
open(path, "wb").write(bytes(head))
PY
}
for n in ntdll d3d11 dxgi d3d10core; do fake_pe "$PE64/$n.dll" 0; fake_pe "$PE32/$n.dll" 0; done
for n in d3d10core d3d11 dxgi nvapi64 nvngx winemetal; do fake_pe "$E/overlays/dxmt/x86_64-windows/$n.dll" 1; done
for n in d3d10core d3d11 dxgi winemetal; do fake_pe "$E/overlays/dxmt/i386-windows/$n.dll" 1; done
for n in d3d9 d3d10core d3d11 dxgi; do fake_pe "$E/overlays/dxvk/x86_64-windows/$n.dll" 1; fake_pe "$E/overlays/dxvk/i386-windows/$n.dll" 1; done
echo "synthetic tree: $(find "$E" -type f | wc -l | tr -d ' ') files"

# ---------------------------------------------------------------------------------------------
# 2. the rpath policy, extracted from package.sh by function name
# ---------------------------------------------------------------------------------------------
eval "$(sed -n '/^rpaths_of()/,/^}/p; /^has_rpath()/p; /^wanted_rpaths()/,/^}/p; /^rpath_args()/,/^}/p' "$PACKAGE_SH")"
type rpath_args >/dev/null 2>&1 || { echo "could not extract rpath_args from package.sh" >&2; exit 1; }

list_machos() { find "$E/wine" "$E/overlays" -type d -name '*-windows' -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
  case "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" in cffaedfe|cefaedfe|cafebabe) printf '%s\n' "$f" ;; esac; done; }

# before the policy: the overlay module's deps are unreachable, the plugin carries a /nix rpath
if "$GATES_SH" "$E" --only rpath_self_contained > "$ROOT/gates-before.txt" 2>&1; then
  bad "rpath_self_contained should FAIL before the rpath policy (L-64)"; cat "$ROOT/gates-before.txt"
else
  ok "rpath_self_contained FAILs on the untreated overlay winemetal.so"
  grep -q 'overlays/dxmt/x86_64-unix/winemetal.so: @rpath/winemac.so unreachable' "$ROOT/gates-before.txt" \
    && ok "  ... naming @rpath/winemac.so" || { bad "  ... expected @rpath/winemac.so in the detail"; cat "$ROOT/gates-before.txt"; }
  grep -q 'malformed LC_RPATH' "$ROOT/gates-before.txt" && ok "  ... and the colon-joined LC_RPATH" || bad "  ... expected the malformed LC_RPATH in the detail"
fi

n=0
while IFS= read -r f; do
  args=()
  while IFS= read -r a; do args+=("$a"); done < <(rpath_args "$f")
  [ "${#args[@]}" -gt 0 ] || continue
  install_name_tool "${args[@]}" "$f" 2>&1 | grep -v 'invalidate the code signature' || true
  n=$((n + 1))
done < <(list_machos)
echo "rpath policy applied to $n Mach-O files"

expect_rpaths() { # expect_rpaths <file> <rpath>... : exactly this set, in any order
  local f=$1; shift
  local want have
  want=$(printf '%s\n' "$@" | LC_ALL=C sort); have=$(rpaths_of "$f" | LC_ALL=C sort)
  if [ "$want" = "$have" ]; then ok "rpaths of ${f#"$E"/}: $(printf '%s ' "$@")"; else bad "rpaths of ${f#"$E"/}: want [$(printf '%s ' "$@")] have [$(printf '%s' "$have" | tr '\n' ' ')]"; fi
}
expect_rpaths "$UNIX/ntdll.so" '@loader_path/' '@loader_path/../../../lib'
expect_rpaths "$UNIX/winemetal.so" '@loader_path/' '@loader_path/../../../lib'
expect_rpaths "$UNIX/wine" '@loader_path/' '@loader_path/../../../lib'
expect_rpaths "$E/overlays/dxmt/x86_64-unix/winemetal.so" '@loader_path/' '@loader_path/../../../wine/lib/wine/x86_64-unix' '@loader_path/../../../wine/lib'
expect_rpaths "$LIB/libfoo.dylib" '@loader_path/'
expect_rpaths "$GSTDIR/libgstselftest.dylib" '@loader_path/' '@loader_path/../'
expect_rpaths "$BIN/wineserver" '@loader_path/../lib'
expect_rpaths "$E/wine/libexec/gstreamer-1.0/gst-plugin-scanner" '@loader_path/../../lib'
# idempotent: a second pass has nothing to do
check test -z "$(rpath_args "$E/overlays/dxmt/x86_64-unix/winemetal.so")"

# ---------------------------------------------------------------------------------------------
# 3. manifest.py with the values package.sh would measure on this tree
# ---------------------------------------------------------------------------------------------
minos_of() { otool -l "$1" 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}'; }
DXMT_MINOS=$(minos_of "$E/overlays/dxmt/x86_64-unix/winemetal.so")
[ "$DXMT_MINOS" = 14.0 ] && ok "overlay winemetal.so minos 14.0" || bad "overlay winemetal.so minos $DXMT_MINOS"
env OSS_ID="$ENGINE_ID" OSS_VERSION="26.3.0-r1" OSS_CX_VERSION="26.3.0" \
    OSS_WINE_VERSION="11.0" OSS_WINE_VERSION_STRING="wine-11.0-8726-g2e2f5fca349" \
    OSS_MIN_MACOS="15.0" OSS_DEPLOYMENT_TARGET="15.0" OSS_OVERLAY_MIN_MACOS="$DXMT_MINOS" OSS_DXMT_MINOS="$DXMT_MINOS" \
    OSS_CAP_MSYNC=true OSS_CAP_ESYNC=false OSS_CAP_WOW64=true OSS_CAP_MACDRV=true OSS_CAP_PREPEND=true OSS_CAP_D3DMETAL=true \
    OSS_HAS_DXVK=true OSS_HAS_SCANNER=true OSS_WINEMETAL_BUILTIN=true \
    OSS_DXMT_VERSION="0.80" OSS_MONO_VERSION="10.4.1" OSS_GECKO_VERSION="2.47.4" OSS_GST_COUNT=0 \
    OSS_PATCHES="0001-use-the-real-user-name.patch 0003-ntdll-winedllpath-prepend.patch 0014-msync-unregister-early-return.patch" \
    OSS_PATCH_LIST="0001-use-the-real-user-name.patch 0003-ntdll-winedllpath-prepend.patch 0014-msync-unregister-early-return.patch" \
    OSS_PORTS="pkgconfig gettext freetype gnutls libsdl2 vulkan-headers gstreamer1" OSS_INPUTS_SHA="$(shasum -a 256 "$INPUTS_JSON" | cut -d' ' -f1)" \
    OSS_TARBALL="/opt/ossover/engine/out/$ENGINE_ID.tar.xz" OSS_HOST_OS="selftest" OSS_SDK="selftest" OSS_CLANG="selftest" OSS_MINGW="selftest" \
    OSS_BUILD_DATE="2026-10-14T00:00:00Z" OSS_STAMP="selftest" \
  python3 -I "$MANIFEST_PY" "$INPUTS_JSON" "$E/manifest.json" | sed 's/^/manifest.py: /'
(cd "$E" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | sed 's|  \./|  |') > "$E/SHA256SUMS"

check python3 -I - "$E/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["source"]["extract"] == {"strip": 1, "into": "."}, m["source"]
assert m["source"]["sha256"] == "TBD"
assert m["capabilities"] == {"msync": True, "esync": False, "wow64": True, "macdrvExports": True, "dllPathPrepend": True, "d3dmetalHost": True}
assert set(m["paths"]) == {"wine", "wineserver", "libWine"}
assert not any(k.startswith("DYLD_") for k in m["baseEnv"])
assert m["minMacOS"] == "15.0" and m["build"]["overlayMinMacOS"] == "14.0"
dxmt, dxvk = m["bundledRenderers"]
assert dxmt["kind"] == "dxmt" and dxmt["minMacOS"] == "14.0" and dxmt["builtinMarked"] is True
assert dxmt["layout"] == {"unix": ["winemetal.so"], "pe": ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "nvapi64.dll", "nvngx.dll", "winemetal.dll"], "pe32": ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"]}
assert dxvk["kind"] == "dxvk" and "minMacOS" not in dxvk and dxvk["layout"]["pe"] == ["d3d10core.dll", "d3d11.dll", "d3d9.dll", "dxgi.dll"]
# decision 32: one spelling per input, parsed from the pinned URL in inputs.json
by_id = {c["id"]: c for c in m["components"]}
assert dxvk["version"] == "1.10.3-20230507-repack" == by_id["dxvk-macos"]["version"], (dxvk["version"], by_id["dxvk-macos"]["version"])
assert dxmt["version"] == "0.80" == by_id["dxmt"]["version"], (dxmt["version"], by_id["dxmt"]["version"])
assert m["wineVersionString"].startswith("wine-11.0")
PY

# ---------------------------------------------------------------------------------------------
# 4. the offline gates on the treated tree
# ---------------------------------------------------------------------------------------------
OFFLINE="manifest,sha256sums,absolute_refs,minos,overlay_minos,rpath_self_contained"
if "$GATES_SH" "$E" --only "$OFFLINE" > "$ROOT/gates-after.txt" 2>&1; then ok "gates --only $OFFLINE all PASS"; else bad "gates --only $OFFLINE"; fi
sed 's/^/  /' "$ROOT/gates-after.txt"
for g in manifest sha256sums absolute_refs minos overlay_minos rpath_self_contained; do
  grep -q "^PASS $g:" "$ROOT/gates-after.txt" || bad "gate $g did not PASS"
done

# negative: manifest minMacOS 13.0 with a DXMT overlay present → overlay_minos (and minos) FAIL
cp "$E/manifest.json" "$ROOT/manifest.good.json"
python3 -I - "$E/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["minMacOS"] = "13.0"; json.dump(m, open(p, "w"), indent=2)
PY
if "$GATES_SH" "$E" --only overlay_minos > "$ROOT/gates-neg1.txt" 2>&1; then bad "overlay_minos should FAIL with minMacOS 13.0"; else ok "overlay_minos FAILs with manifest minMacOS 13.0"; fi
grep -q '13.0 < 14.0' "$ROOT/gates-neg1.txt" && ok "  ... with the 14.0 floor in the message" || { bad "  ... message"; cat "$ROOT/gates-neg1.txt"; }
cp "$ROOT/manifest.good.json" "$E/manifest.json"

# negative: an overlay Mach-O built for macOS 15 → overlay_minos FAIL (the 14.0 rule would be stale)
clang -mmacosx-version-min=15.0 -dynamiclib -install_name @rpath/selftest15.so -o "$E/overlays/dxmt/x86_64-unix/selftest15.so" "$ROOT/src/lib.c" 2>/dev/null
if "$GATES_SH" "$E" --only overlay_minos > "$ROOT/gates-neg2.txt" 2>&1; then bad "overlay_minos should FAIL with a minos-15 overlay module"; else ok "overlay_minos FAILs on an overlay module built for macOS 15"; fi
rm -f "$E/overlays/dxmt/x86_64-unix/selftest15.so"

# negative: the manifest gate rejects the pre-REA shape (string extract, DYLD row, esync true, extra path keys)
python3 -I - "$E/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p))
m["source"]["extract"] = "x64-ossover-cx26.3-r1/"; m["baseEnv"]["DYLD_FALLBACK_LIBRARY_PATH"] = "${engine}/wine/lib"
m["capabilities"]["esync"] = True; m["paths"]["unixLib"] = "wine/lib/wine/x86_64-unix"
json.dump(m, open(p, "w"), indent=2)
PY
if "$GATES_SH" "$E" --only manifest > "$ROOT/gates-neg3.txt" 2>&1; then bad "manifest gate should reject the old shape"; else ok "manifest gate rejects string extract / DYLD_ row / esync true / extra paths"; fi
for s in 'source.extract must be' 'DYLD_FALLBACK_LIBRARY_PATH' 'capabilities.esync is True' 'outside EnginePaths'; do
  grep -q "$s" "$ROOT/gates-neg3.txt" && ok "  ... names: $s" || { bad "  ... expected '$s'"; cat "$ROOT/gates-neg3.txt"; }
done
cp "$ROOT/manifest.good.json" "$E/manifest.json"

# ---------------------------------------------------------------------------------------------
# 5. the Swift decoder, when an ossover binary is at hand (OSSOVER_BIN or PATH)
# ---------------------------------------------------------------------------------------------
BIN_OSS="${OSSOVER_BIN:-}"; [ -n "$BIN_OSS" ] || BIN_OSS=$(command -v ossover 2>/dev/null || true)
if [ -n "$BIN_OSS" ] && [ -x "$BIN_OSS" ]; then
  if out=$("$BIN_OSS" engine validate-manifest "$E/manifest.json" --layout 2>&1); then ok "ossover engine validate-manifest --layout: $out"; else bad "ossover engine validate-manifest: $out"; fi
else
  echo "note: no ossover binary (set OSSOVER_BIN=.build-*/debug/ossover); Swift decode not exercised here"
fi

if [ -n "$FIXTURE_OUT" ]; then
  cp "$E/manifest.json" "$FIXTURE_OUT" && echo "fixture written: $FIXTURE_OUT"
fi

echo "----"
printf 'selftest: %d ok, %d failed\n' "$N_OK" "$N_BAD"
[ "$N_BAD" = 0 ]

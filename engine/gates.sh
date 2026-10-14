#!/bin/bash
# engine/gates.sh <engine-dir> — the release gates from plan §5 "Packaging", one PASS/FAIL line
# each, non-zero exit on any FAIL. Runs on the packaged tree (engine/out/<id>) or on an engine
# extracted anywhere; needs only the Xcode command line tools (+ Rosetta for the two gates that
# execute x86_64 code, which otherwise WARN).
#
# Adapted from frankea/winecx-gptk "verify the tree is relocatable" / "verify the runtime can
# open a window" steps and tests/dlopenall.c, and from the checks in highball-engine's
# build.yml; each gate here exists because that exact failure shipped silently somewhere.
#
# bash 3.2 compatible.

set -euo pipefail

usage() {
  cat <<EOF
usage: $(basename "$0") <engine-dir> [--strict] [--only a,b] [--skip a,b] [--list]

  <engine-dir>   engine/out/<engineId> (contains manifest.json, wine/, overlays/)
  --strict       treat WARN as FAIL
  --only a,b     run only these gates          --skip a,b   skip these gates
  --list         print the gate names and exit

gates:
  layout          required files/dirs, loader is x86_64, no i386-unix
  manifest        manifest.json has the EngineManifest shape (source{extract{strip,into}}, paths,
                  capabilities incl. esync=false, bundledRenderers layouts, no DYLD_* baseEnv);
                  also decoded by \`ossover engine validate-manifest\` when OSSOVER_BIN / PATH has one
  sha256sums      shasum -a 256 -c SHA256SUMS
  absolute_refs   no /opt/local|/opt/homebrew|/usr/local|/nix in any Mach-O id/load/rpath
  minos           every Mach-O LC_BUILD_VERSION minos <= manifest minMacOS (vtool/otool -l)
  overlay_minos   DXMT/D3DMetal overlay Mach-Os are minos <= 14 and the manifest minMacOS is
                  >= 14.0 while any such overlay is present (REA L-62; decision 29)
  rpath_self_contained
                  every @rpath/ and @loader_path/ dependency of every Mach-O resolves from that
                  image's own LC_RPATHs and location; no @executable_path, no colon-joined rpath
                  (REA L-12, L-64; decision 28)
  dlopen          every .so/.dylib/plugin dlopens (x86_64 helper built with clang, run under
                  Rosetta; ntdll.so/win32u.so preloaded for the flat-namespace modules)
  macdrv_exports  nm -gU winemac.so | grep macdrv_functions   (DXMT's winemetal.so dlsym()s it)
  dllpath_prepend strings ntdll.so | grep WINEDLLPATH_PREPEND   (patch 0003; overlay strategy C)
  soname_strings  no /opt/local etc. strings in Wine's own unix modules (dlopen'd sonames)
  i386_count      > 500 files in lib/wine/i386-windows
  ntdll_size      lib/wine/x86_64-windows/ntdll.dll < 1.5 MB (PE half is stripped)
  winedmo_ffmpeg  otool -L winedmo.so | grep libavcodec (video decode backend present)
  gst_plugins     > 50 plugins in lib/gstreamer-1.0, winegstreamer links libgstreamer
  addons          wine-mono and wine-gecko (x86, x86_64) extracted under share/wine
  overlays        overlays/dxmt complete, builtin d3d11/dxgi are Wine's, winemetal placeholder
  wine_version    WINEMSYNC=1 wine --version prints wine-11 (Rosetta)
  codesign        codesign --verify --strict on every Mach-O
  weak_imports    WARN: weak undefined libSystem symbols in the unix modules (APIs above floor)
EOF
}

ALL_GATES="layout manifest sha256sums absolute_refs minos overlay_minos rpath_self_contained dlopen macdrv_exports dllpath_prepend soname_strings i386_count ntdll_size winedmo_ffmpeg gst_plugins addons overlays wine_version codesign weak_imports"
ENGINE="" STRICT=0 ONLY="" SKIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    --only) shift; ONLY="${1:-}" ;;
    --skip) shift; SKIP="${1:-}" ;;
    --list) echo "$ALL_GATES" | tr ' ' '\n'; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) [ -z "$ENGINE" ] || { echo "only one engine dir" >&2; exit 2; }; ENGINE="$1" ;;
  esac
  shift
done
[ -n "$ENGINE" ] || { usage >&2; exit 2; }
[ -d "$ENGINE" ] || { echo "not a directory: $ENGINE" >&2; exit 2; }
E=$(cd "$ENGINE" && pwd)
LIB="$E/wine/lib"; BIN="$E/wine/bin"; UNIX="$LIB/wine/x86_64-unix"
PE64="$LIB/wine/x86_64-windows"; PE32="$LIB/wine/i386-windows"; GSTDIR="$LIB/gstreamer-1.0"

N_PASS=0 N_FAIL=0 N_WARN=0 N_SKIP=0
result() { # result PASS|FAIL|WARN|SKIP <gate> <message>
  case "$1" in
    PASS) N_PASS=$((N_PASS + 1)) ;;
    FAIL) N_FAIL=$((N_FAIL + 1)) ;;
    WARN) N_WARN=$((N_WARN + 1)) ;;
    SKIP) N_SKIP=$((N_SKIP + 1)) ;;
  esac
  printf '%-4s %s: %s\n' "$1" "$2" "$3"
}
detail() { sed 's/^/     /'; }   # pipe details through this
have() { command -v "$1" >/dev/null 2>&1; }
rosetta_ok() { arch -x86_64 /usr/bin/true >/dev/null 2>&1; }
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/ossover-gates.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

is_macho() {
  local m; m=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$m" in cffaedfe|cefaedfe|cafebabe) return 0 ;; *) return 1 ;; esac
}
MACHO_LIST="$TMPD/machos.txt"
build_macho_list() {
  local dirs=() d
  for d in "$E/wine/bin" "$E/wine/lib" "$E/wine/libexec" "$E/overlays"; do [ -d "$d" ] && dirs+=("$d"); done
  : > "$MACHO_LIST"
  [ ${#dirs[@]} -gt 0 ] || return 0
  find "${dirs[@]}" -type d -name '*-windows' -prune -o -type f -print 2>/dev/null | LC_ALL=C sort \
    | while IFS= read -r f; do is_macho "$f" && printf '%s\n' "$f"; done > "$MACHO_LIST"
  return 0
}
macho_count() { wc -l < "$MACHO_LIST" | tr -d ' '; }
rel() { printf '%s' "${1#"$E"/}"; }

# Mach-O load-command readers (paths with spaces survive: the ` (offset N)` / ` (compatibility
# version …)` suffixes are stripped instead of taking field $2)
rpaths_of() { otool -l "$1" 2>/dev/null | awk '/ cmd LC_RPATH/{r=1} r && /^ *path /{sub(/^ *path /,""); sub(/ \(offset [0-9]+\)$/,""); print; r=0}'; }
deps_of()   { otool -L "$1" 2>/dev/null | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//'; }
id_of()     { otool -D "$1" 2>/dev/null | sed -n '2p'; }
minos_of()  { otool -l "$1" 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} /LC_VERSION_MIN_MACOSX/{m=1} b&&/minos/{print $2; exit} m&&/version/{print $2; exit}'; }
ver_ge()    { awk -v a="$1" -v b="$2" 'BEGIN{split(a,x,"."); split(b,y,"."); for(i=1;i<=3;i++){ai=x[i]+0; bi=y[i]+0; if(ai>bi) exit 0; if(ai<bi) exit 1} exit 0}'; }

# manifest minMacOS, read once so --only <gate> works without the manifest gate
MIN_MACOS=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("minMacOS") or "")' "$E/manifest.json" 2>/dev/null || true)
case "$MIN_MACOS" in [0-9]*) ;; *) MIN_MACOS=15.0 ;; esac
FLOOR_MAJOR=${MIN_MACOS%%.*}

# ---------------------------------------------------------------------------------------------
gate_layout() {
  local missing="" p
  for p in wine/bin/wine wine/bin/wineserver wine/lib/wine/x86_64-unix/ntdll.so wine/lib/wine/x86_64-unix/winemac.so \
           wine/lib/wine/x86_64-windows/ntdll.dll wine/lib/wine/i386-windows/ntdll.dll \
           wine/lib/gstreamer-1.0 wine/share/wine manifest.json SHA256SUMS overlays/dxmt; do
    [ -e "$E/$p" ] || missing="$missing $p"
  done
  [ -d "$LIB/wine/i386-unix" ] && missing="$missing (i386-unix present: not a wow64-only engine)"
  local loader archs
  loader=$(cd "$BIN" && readlink "wine" 2>/dev/null || true)
  if [ -n "$loader" ]; then loader="$BIN/$loader"; else loader="$BIN/wine"; fi
  [ -f "$loader" ] || missing="$missing (bin/wine does not resolve: $loader)"
  archs=$(lipo -archs "$loader" 2>/dev/null || echo none)
  [ "$archs" = x86_64 ] || missing="$missing (loader archs: $archs)"
  if [ -z "$missing" ]; then
    result PASS layout "all required paths present; loader x86_64 ($(rel "$loader")); $(macho_count) Mach-O files"
  else
    result FAIL layout "missing:$missing"
  fi
}

gate_manifest() {
  # The checks mirror Sources/OssoverKit/Model/EngineManifest.swift (+ Source.swift,
  # RendererPack.swift): a manifest that fails here would not decode in `ossover engine install`.
  local out swift bin
  if out=$(python3 -I - "$E/manifest.json" "$(basename "$E")" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1])); want = sys.argv[2]
errs = []
ver = re.compile(r"[0-9]+(\.[0-9]+){0,2}")
def relative(p): return isinstance(p, str) and p and not p.startswith("/") and ".." not in p.split("/")
if m.get("schema") != "ossover.engine-manifest/1": errs.append("schema %r" % m.get("schema"))
if m.get("id") != want: errs.append("id %r != directory %r" % (m.get("id"), want))
if m.get("arch") != "x86_64": errs.append("arch %r" % m.get("arch"))
if "rosetta2" not in (m.get("requires") or []): errs.append("requires lacks rosetta2")
if not ver.fullmatch(str(m.get("wineVersion", ""))): errs.append("wineVersion %r is not a version" % m.get("wineVersion"))
if not ver.fullmatch(str(m.get("minMacOS", ""))): errs.append("minMacOS %r is not a version" % m.get("minMacOS"))
wvs = m.get("wineVersionString")
if wvs and not str(wvs).startswith("wine-" + str(m.get("wineVersion"))):
    errs.append("wineVersionString %r does not start with wine-%s" % (wvs, m.get("wineVersion")))
# source (ArtifactSource): url + sha256 (64 hex, or TBD inside the tarball) + extract{strip,into}
src = m.get("source")
if not isinstance(src, dict):
    errs.append("source block missing (EngineManifest requires source{url,sha256,extract})")
else:
    if not src.get("url"): errs.append("source.url missing")
    sha = str(src.get("sha256", ""))
    if not (sha == "TBD" or re.fullmatch(r"[0-9a-f]{64}", sha)): errs.append("source.sha256 %r is neither TBD nor 64 lowercase hex" % sha)
    ex = src.get("extract")
    if not (isinstance(ex, dict) and isinstance(ex.get("strip"), int) and isinstance(ex.get("into"), str)):
        errs.append("source.extract must be {strip: int, into: str} (ExtractSpec), got %r" % (ex,))
    elif ex != {"strip": 1, "into": "."}:
        errs.append("source.extract %r: the tarball is <id>/..., so strip 1 into '.'" % (ex,))
# paths (EnginePaths): relative, no '..', only the keys the model has
paths = m.get("paths") or {}
for k in ("wine", "wineserver", "libWine"):
    if not relative(paths.get(k)): errs.append("paths.%s %r must be relative without '..'" % (k, paths.get(k)))
extra = sorted(set(paths) - {"wine", "wineserver", "libWine", "frameworks"})
if extra: errs.append("paths has keys outside EnginePaths: %s" % ",".join(extra))
# capabilities (EngineCapabilities): the six names, esync false on a CrossOver tree (REA L-32)
caps = m.get("capabilities") or {}
for c in ("msync", "wow64", "macdrvExports", "dllPathPrepend", "d3dmetalHost"):
    if caps.get(c) is not True: errs.append("capabilities.%s is %r" % (c, caps.get(c)))
if caps.get("esync") is not False: errs.append("capabilities.esync is %r (the CX tree has no esync, REA L-32)" % caps.get("esync"))
extra = sorted(set(caps) - {"msync", "esync", "wow64", "macdrvExports", "dllPathPrepend", "d3dmetalHost"})
if extra: errs.append("capabilities has keys outside EngineCapabilities: %s" % ",".join(extra))
# baseEnv: no DYLD_* (REA L-54: CX never sets them; hardened runtime ignores them)
for k in (m.get("baseEnv") or {}):
    if k.startswith("DYLD_"): errs.append("baseEnv sets %s (REA L-54; the rpath rule carries the tree)" % k)
# bundledRenderers (BundledRenderer): kind, relative path, layout{unix,pe[,pe32]}
kinds = []
for r in m.get("bundledRenderers") or []:
    kind = r.get("kind"); kinds.append(str(kind))
    if kind not in ("dxmt", "dxvk", "d3dmetal", "wined3d"): errs.append("bundledRenderers kind %r" % kind)
    if not relative(r.get("path")): errs.append("bundledRenderers[%s].path %r must be relative" % (kind, r.get("path")))
    lay = r.get("layout")
    if not (isinstance(lay, dict) and isinstance(lay.get("unix"), list) and isinstance(lay.get("pe"), list)):
        errs.append("bundledRenderers[%s].layout must be {unix:[], pe:[], pe32?:[]}" % kind)
    elif kind == "dxmt" and ("winemetal.so" not in lay["unix"] or "d3d11.dll" not in lay["pe"]):
        errs.append("dxmt layout lacks winemetal.so / d3d11.dll")
    if r.get("builtinMarked") is not True: errs.append("bundledRenderers[%s].builtinMarked is %r (strategy C wants marked PEs)" % (kind, r.get("builtinMarked")))
    if r.get("minMacOS") and not ver.fullmatch(str(r["minMacOS"])): errs.append("bundledRenderers[%s].minMacOS %r" % (kind, r["minMacOS"]))
if "dxmt" not in kinds: errs.append("no dxmt in bundledRenderers")
if errs:
    print("ERR " + "; ".join(errs)); sys.exit(1)
print("OK id=%s version=%s wine=%s (%s) minMacOS=%s renderers=%s source=%s" % (
    m["id"], m.get("version"), m.get("wineVersion"), wvs or "no wineVersionString", m["minMacOS"],
    ",".join(kinds), "pinned" if src.get("sha256") != "TBD" else "unpinned (TBD)"))
PY
  ); then
    # the same file through the Swift model, when an ossover binary is at hand
    bin="${OSSOVER_BIN:-}"; [ -n "$bin" ] || bin=$(command -v ossover 2>/dev/null || true)
    if [ -n "$bin" ] && [ -x "$bin" ]; then
      if swift=$("$bin" engine validate-manifest "$E/manifest.json" --layout 2>&1); then
        result PASS manifest "$(printf '%s\n' "$out" | sed -n 's/^OK //p'); Swift: $(printf '%s\n' "$swift" | head -1)"
      else
        result FAIL manifest "Swift EngineManifest refused it: $(printf '%s\n' "$swift" | tail -3 | tr '\n' ' ')"
      fi
    else
      result PASS manifest "$(printf '%s\n' "$out" | sed -n 's/^OK //p') (Swift decode not run: no ossover on PATH / OSSOVER_BIN)"
    fi
  else
    result FAIL manifest "$(printf '%s\n' "$out" | sed -n 's/^ERR //p; /Traceback\|Error/p' | head -3 | tr '\n' ' ')"
  fi
}

gate_sha256sums() {
  local bad n
  n=$(wc -l < "$E/SHA256SUMS" | tr -d ' ')
  if (cd "$E" && shasum -a 256 -c --quiet SHA256SUMS > "$TMPD/sums.out" 2>&1); then
    result PASS sha256sums "$n files verified"
  else
    bad=$(grep -c 'FAILED' "$TMPD/sums.out" || true)
    result FAIL sha256sums "$bad of $n entries failed"
    head -10 "$TMPD/sums.out" | detail
  fi
}

gate_absolute_refs() {
  local f id n=0
  : > "$TMPD/abs.txt"
  while IFS= read -r f; do
    otool -D "$f" 2>/dev/null | sed -n '2p' | grep -E '^/' | grep -vE '^(/usr/lib/|/System/)' | sed "s|^|id $(rel "$f") -> |" >> "$TMPD/abs.txt" || true
    otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -E '^/' | grep -vE '^(/usr/lib/|/System/)' | sed "s|^|dep $(rel "$f") -> |" >> "$TMPD/abs.txt" || true
    rpaths_of "$f" | grep -E '^/(opt|usr/local|nix)' | sed "s|^|rpath $(rel "$f") -> |" >> "$TMPD/abs.txt" || true
  done < "$MACHO_LIST"
  n=$(wc -l < "$TMPD/abs.txt" | tr -d ' ')
  if [ "$n" = 0 ]; then
    result PASS absolute_refs "no absolute non-system references in $(macho_count) Mach-O files"
  else
    result FAIL absolute_refs "$n absolute reference(s)"
    head -20 "$TMPD/abs.txt" | detail
  fi
}

gate_minos() {
  local f minos n=0 none=0
  : > "$TMPD/minos.txt"
  while IFS= read -r f; do
    minos=$(minos_of "$f")
    if [ -z "$minos" ]; then none=$((none + 1)); continue; fi
    ver_ge "$MIN_MACOS" "$minos" || echo "$(rel "$f") minos $minos" >> "$TMPD/minos.txt"
  done < "$MACHO_LIST"
  n=$(wc -l < "$TMPD/minos.txt" | tr -d ' ')
  if [ "$n" = 0 ]; then
    result PASS minos "nothing newer than macOS $MIN_MACOS ($none file(s) without a version load command)"
  else
    result FAIL minos "$n Mach-O file(s) built for a macOS newer than $MIN_MACOS (MacPorts macosx_deployment_target?)"
    head -20 "$TMPD/minos.txt" | detail
  fi
}

gate_overlay_minos() {
  # REA L-62, L-78 / decision 29: DXMT's winemetal.so and GPTK's libd3dshared.dylib / D3DMetal
  # are minos 14.0, so any DXMT or D3DMetal overlay makes the engine need macOS 14.0 even when
  # the Wine build itself would run lower; the plain engine stays at the toolchain's floor.
  # Checks: (1) with such an overlay present the manifest minMacOS is >= 14.0 and >= every
  # overlay's floor, (2) a per-renderer `minMacOS` in the manifest equals the measured floor,
  # (3) WARN when an overlay Mach-O is newer than the 14.0 REA measured on CrossOver's DXMT
  # 0.72: the floor arithmetic above already covers it (DXMT 0.80's winemetal.so is 15.0,
  # found 2026-10-14), but a raised floor is worth seeing; --strict makes it a FAIL.
  local d kind f m kfloor declared floor="" bad="" floors="" mism="" n=0
  [ -d "$E/overlays" ] || { result PASS overlay_minos "no overlays/ directory"; return 0; }
  for d in "$E"/overlays/*/; do
    [ -d "$d" ] || continue
    kind=$(basename "$d"); kfloor=""
    while IFS= read -r f; do
      case "$f" in "$d"*) ;; *) continue ;; esac
      m=$(minos_of "$f"); [ -n "$m" ] || continue
      n=$((n + 1))
      if [ -z "$kfloor" ] || ver_ge "$m" "$kfloor"; then kfloor=$m; fi
      ver_ge 14 "$m" || bad="$bad $(rel "$f")=$m"
    done < "$MACHO_LIST"
    [ -n "$kfloor" ] || continue
    floors="$floors $kind=$kfloor"
    if [ -z "$floor" ] || ver_ge "$kfloor" "$floor"; then floor=$kfloor; fi
    declared=$(python3 -I -c 'import json,sys
for r in json.load(open(sys.argv[1])).get("bundledRenderers") or []:
    if r.get("kind") == sys.argv[2]: print(r.get("minMacOS") or "")' "$E/manifest.json" "$kind" 2>/dev/null || true)
    [ -z "$declared" ] || [ "$declared" = "$kfloor" ] || mism="$mism $kind(manifest $declared, measured $kfloor)"
  done
  if [ -z "$floor" ]; then
    result PASS overlay_minos "no Mach-O under overlays/ (PE-only overlays); manifest minMacOS $MIN_MACOS unaffected"
  elif ! ver_ge "$MIN_MACOS" 14.0; then
    result FAIL overlay_minos "manifest minMacOS $MIN_MACOS < 14.0 with a DXMT/D3DMetal overlay present (floors:$floors)"
  elif ! ver_ge "$MIN_MACOS" "$floor"; then
    result FAIL overlay_minos "manifest minMacOS $MIN_MACOS below the overlay floor $floor (floors:$floors)"
  elif [ -n "$mism" ]; then
    result FAIL overlay_minos "bundledRenderers minMacOS disagrees with the Mach-Os:$mism"
  elif [ -n "$bad" ]; then
    result WARN overlay_minos "$n overlay Mach-O(s), floors:$floors, covered by manifest minMacOS $MIN_MACOS; newer than the 14.0 REA L-62 measured on CX's DXMT 0.72:$bad"
  else
    result PASS overlay_minos "$n overlay Mach-O(s), floors:$floors; manifest minMacOS $MIN_MACOS >= 14.0"
  fi
}

gate_rpath_self_contained() {
  # REA L-12, L-64 / decision 28: Wine's unix modules name each other `@rpath/<x>.so` and dlopen
  # sonames that dyld tries as `@rpath/<soname>` against the *calling image's* rpaths; CrossOver
  # only works because every .so carries its own `@loader_path/` + `…/lib64` pair (its loader's
  # rpath is dead) and its overlay winemetal.so (one colon-joined LC_RPATH) loads by accident.
  # Here each image must resolve every `@rpath/` and `@loader_path/` dependency from its own
  # LC_RPATHs and location, with no `@executable_path` and no malformed entry.
  local f d dep id rp cand ok n_img=0 n_dep=0 n_bad=0 n_mal=0 n_img_bad=0 img_bad
  : > "$TMPD/rpath.txt"
  while IFS= read -r f; do
    [ -L "$f" ] && continue
    n_img=$((n_img + 1)); d=$(dirname "$f"); id=$(id_of "$f"); img_bad=0
    while IFS= read -r rp; do
      case "$rp" in *:*) echo "$(rel "$f"): malformed LC_RPATH '$rp' (colon-joined; dyld does not split it)" >> "$TMPD/rpath.txt"; n_mal=$((n_mal + 1)); img_bad=1 ;; esac
    done < <(rpaths_of "$f")
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      [ "$dep" = "$id" ] && continue
      case "$dep" in
        @rpath/*)
          n_dep=$((n_dep + 1)); ok=0
          while IFS= read -r rp; do
            case "$rp" in
              *:*|@executable_path*) continue ;;          # unusable: malformed, or the loader's location
              @loader_path) cand="$d/${dep#@rpath/}" ;;
              @loader_path/*) cand="$d/${rp#@loader_path/}/${dep#@rpath/}" ;;
              /*) cand="$rp/${dep#@rpath/}" ;;
              *) continue ;;                               # relative rpath: resolved against cwd, not the image
            esac
            [ -e "$cand" ] && { ok=1; break; }
          done < <(rpaths_of "$f")
          [ "$ok" = 1 ] || { echo "$(rel "$f"): $dep unreachable from its own rpaths [$(rpaths_of "$f" | tr '\n' ' ')]" >> "$TMPD/rpath.txt"; n_bad=$((n_bad + 1)); img_bad=1; } ;;
        @loader_path/*)
          n_dep=$((n_dep + 1))
          [ -e "$d/${dep#@loader_path/}" ] || { echo "$(rel "$f"): $dep does not exist" >> "$TMPD/rpath.txt"; n_bad=$((n_bad + 1)); img_bad=1; } ;;
        @executable_path/*)
          n_dep=$((n_dep + 1)); echo "$(rel "$f"): $dep depends on the loader executable's location" >> "$TMPD/rpath.txt"; n_bad=$((n_bad + 1)); img_bad=1 ;;
      esac
    done < <(deps_of "$f")
    [ "$img_bad" = 0 ] || n_img_bad=$((n_img_bad + 1))
  done < "$MACHO_LIST"
  if [ "$n_bad" = 0 ] && [ "$n_mal" = 0 ]; then
    result PASS rpath_self_contained "$n_dep @rpath/@loader_path dependencies of $n_img Mach-O files resolve from their own rpaths; no malformed LC_RPATH"
  else
    result FAIL rpath_self_contained "$n_img_bad of $n_img Mach-O files: $n_bad unresolvable dependency(ies), $n_mal malformed LC_RPATH(s)"
    head -20 "$TMPD/rpath.txt" | detail
  fi
}

gate_dlopen() {
  rosetta_ok || { result WARN dlopen "skipped: Rosetta 2 not installed, cannot run x86_64 code"; return 0; }
  have clang || { result WARN dlopen "skipped: clang not found"; return 0; }
  cat > "$TMPD/dlopenall.c" <<'EOF'
/* adapted from frankea/winecx-gptk tests/dlopenall.c: every bundled library must load by path,
 * off the builder, with nothing but what the tree carries. --preload <path>... are opened first
 * with RTLD_GLOBAL: Wine's unix modules resolve ntdll.so / win32u.so symbols through the flat
 * namespace (CrossOver's own winemac.so imports _Nt* with no load command), so without them a
 * module fails with "symbol not found in flat namespace" for reasons unrelated to relocation.
 * RTLD_NOW, not LAZY: a lazy load hides a missing function until it is called. A failure is
 * retried once after everything else has loaded (a module may need a later provider). */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int try_open(const char *p) { return dlopen(p, RTLD_NOW | RTLD_GLOBAL) != NULL; }
int main(int argc, char **argv)
{
    int i = 1, failed = 0, total = 0, n_retry = 0;
    char **retry = calloc(argc, sizeof(char *));
    char **err = calloc(argc, sizeof(char *));
    for (; i + 1 < argc && !strcmp(argv[i], "--preload"); i += 2) {
        total++;
        if (!try_open(argv[i + 1])) { printf("FAIL %s: %s\n", argv[i + 1], dlerror()); failed++; }
    }
    for (; i < argc; i++) {
        total++;
        if (try_open(argv[i])) continue;
        const char *e = dlerror();
        retry[n_retry] = argv[i]; err[n_retry] = strdup(e ? e : "unknown"); n_retry++;
    }
    for (i = 0; i < n_retry; i++) {
        if (try_open(retry[i])) continue;
        const char *e = dlerror();
        printf("FAIL %s: %s\n", retry[i], e ? e : err[i]); failed++;
    }
    printf("RESULT: %d of %d failed\n", failed, total);
    return failed ? 1 : 0;
}
EOF
  if ! clang -arch x86_64 -O1 -o "$TMPD/dlopenall" "$TMPD/dlopenall.c" > "$TMPD/cc.log" 2>&1; then
    result FAIL dlopen "could not build the x86_64 helper: $(tail -1 "$TMPD/cc.log")"; return 0
  fi
  local pre=() args=() f
  for f in "$UNIX/ntdll.so" "$UNIX/win32u.so"; do [ -f "$f" ] && pre+=(--preload "$f"); done
  [ ${#pre[@]} -gt 0 ] || { result FAIL dlopen "no ntdll.so to preload"; return 0; }   # bash 3.2: "${pre[@]}" on an empty array trips set -u
  while IFS= read -r f; do
    case "$f" in
      "$UNIX/ntdll.so"|"$UNIX/win32u.so") continue ;;
      *.so|*.dylib|*.dylib.*) [ -L "$f" ] || args+=("$f") ;;
    esac
  done < "$MACHO_LIST"
  [ ${#args[@]} -gt 0 ] || { result FAIL dlopen "no .so/.dylib found under wine/lib"; return 0; }
  # no DYLD_* help on purpose: @loader_path and the rpath must carry the tree by themselves
  set +e
  env -u DYLD_FALLBACK_LIBRARY_PATH -u DYLD_LIBRARY_PATH \
    perl -e 'alarm shift; exec @ARGV' 600 "$TMPD/dlopenall" "${pre[@]}" "${args[@]}" > "$TMPD/dlopen.log" 2>&1
  local rc=$?
  set -e
  local res flat other
  res=$(grep '^RESULT' "$TMPD/dlopen.log" || echo "RESULT: helper died (rc $rc)")
  flat=$(grep '^FAIL' "$TMPD/dlopen.log" | grep -c 'flat namespace' || true)
  other=$(grep '^FAIL' "$TMPD/dlopen.log" | grep -vc 'flat namespace' || true)
  if [ "$rc" = 0 ]; then
    result PASS dlopen "$res (ntdll.so, win32u.so preloaded; $((${#args[@]} + ${#pre[@]} / 2)) libraries)"
  elif [ "$other" = 0 ] && [ "$flat" != 0 ]; then
    result WARN dlopen "$res; all $flat failure(s) are flat-namespace symbol lookups (provider module order), not relocation errors"
    grep '^FAIL' "$TMPD/dlopen.log" | head -8 | detail
  else
    result FAIL dlopen "$res ($other relocation/arch failure(s), $flat flat-namespace)"
    grep '^FAIL' "$TMPD/dlopen.log" | grep -v 'flat namespace' | head -15 | detail
  fi
}

# count_str <file> <literal>: number of matching `strings` lines. Not `| grep -q`: under pipefail
# the early exit kills `strings` with SIGPIPE and the pipeline reports failure on a hit
# (2026-10-14: dllpath_prepend FAILed on an ntdll.so that has the string).
count_str() { strings -a "$1" 2>/dev/null | grep -c -- "$2" || true; }

gate_macdrv_exports() {
  if [ "$(nm -gU "$UNIX/winemac.so" 2>/dev/null | grep -c macdrv_functions || true)" -gt 0 ]; then
    result PASS macdrv_exports "winemac.so exports macdrv_functions"
  else
    result FAIL macdrv_exports "winemac.so does not export macdrv_functions (DXMT's winemetal.so dlsym()s it; not a CX tree build?)"
  fi
}

gate_dllpath_prepend() {
  if [ "$(count_str "$UNIX/ntdll.so" WINEDLLPATH_PREPEND)" -gt 0 ]; then
    result PASS dllpath_prepend "ntdll.so knows WINEDLLPATH_PREPEND"
  else
    result FAIL dllpath_prepend "no WINEDLLPATH_PREPEND in ntdll.so (patch 0003-ntdll-winedllpath-prepend not applied)"
  fi
}

gate_soname_strings() {
  local f n=0
  : > "$TMPD/son.txt"
  while IFS= read -r f; do
    strings -a "$f" 2>/dev/null | grep -E '^/(opt/local|opt/homebrew|usr/local|nix)/' | sed "s|^|$(rel "$f"): |" >> "$TMPD/son.txt" || true
  done < <(find "$UNIX" -maxdepth 1 -name '*.so' | LC_ALL=C sort)
  n=$(wc -l < "$TMPD/son.txt" | tr -d ' ')
  if [ "$n" = 0 ]; then
    result PASS soname_strings "no builder paths embedded in Wine's unix modules"
  else
    result FAIL soname_strings "$n builder path string(s) in unix modules (dlopen soname baked absolute? add ac_cv_lib_soname_* in build.sh)"
    head -10 "$TMPD/son.txt" | detail
  fi
}

gate_i386_count() {
  local n; n=$(find "$PE32" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -gt 500 ]; then result PASS i386_count "$n files in i386-windows"
  else result FAIL i386_count "$n files in i386-windows (need > 500; 32-bit programs would die with c0000135)"; fi
}

gate_ntdll_size() {
  local n; n=$(wc -c < "$PE64/ntdll.dll" 2>/dev/null | tr -d ' ' || echo 0)
  if [ "$n" -gt 0 ] && [ "$n" -lt 1500000 ]; then result PASS ntdll_size "ntdll.dll is $n bytes"
  else result FAIL ntdll_size "ntdll.dll is $n bytes (>= 1.5 MB: PE half not stripped, or missing)"; fi
}

gate_winedmo_ffmpeg() {
  if [ ! -f "$UNIX/winedmo.so" ]; then result FAIL winedmo_ffmpeg "no winedmo.so"; return 0; fi
  if otool -L "$UNIX/winedmo.so" | grep -q libavcodec; then
    result PASS winedmo_ffmpeg "winedmo.so links $(otool -L "$UNIX/winedmo.so" | awk '/libavcodec/{print $1; exit}')"
  else
    result FAIL winedmo_ffmpeg "winedmo.so has no libavcodec; ffmpeg was not found at configure time"
  fi
}

gate_gst_plugins() {
  local n msg=""
  n=$(ls "$GSTDIR" 2>/dev/null | grep -c '^libgst.*\.dylib$' || true)   # grep -c prints 0 itself
  n=${n:-0}
  [ -f "$UNIX/winegstreamer.so" ] || msg="$msg; no winegstreamer.so"
  if [ -f "$UNIX/winegstreamer.so" ] && ! otool -L "$UNIX/winegstreamer.so" | grep -q libgstreamer-1.0; then msg="$msg; winegstreamer.so does not link libgstreamer-1.0"; fi
  if [ "$n" -gt 50 ] && [ -z "$msg" ]; then
    result PASS gst_plugins "$n plugins in lib/gstreamer-1.0; winegstreamer links libgstreamer-1.0"
  else
    result FAIL gst_plugins "$n plugins (need > 50)$msg"
  fi
}

gate_addons() {
  local missing="" d
  for d in "$E"/wine/share/wine/mono/wine-mono-* "$E"/wine/share/wine/gecko/wine-gecko-*-x86 "$E"/wine/share/wine/gecko/wine-gecko-*-x86_64; do
    [ -d "$d" ] || missing="$missing $(rel "$d")"
  done
  if [ -z "$missing" ]; then
    result PASS addons "$(cd "$E/wine/share/wine" && ls -d mono/wine-mono-* gecko/wine-gecko-* | tr '\n' ' ')"
  else
    result FAIL addons "missing:$missing (a fresh prefix would stop on the Mono/Gecko download dialog)"
  fi
}

gate_overlays() {
  local missing="" warnmsg="" f d
  for f in x86_64-unix/winemetal.so x86_64-windows/winemetal.dll x86_64-windows/d3d11.dll x86_64-windows/dxgi.dll x86_64-windows/d3d10core.dll i386-windows/d3d11.dll; do
    [ -f "$E/overlays/dxmt/$f" ] || missing="$missing dxmt/$f"
  done
  for d in d3d11 dxgi d3d10core; do
    if strings -a "$PE64/$d.dll" 2>/dev/null | grep -q 'DXMT_\|dxmt\.con'; then missing="$missing (builtin $d.dll is DXMT's, not Wine's)"; fi
  done
  [ -f "$PE64/nvapi64.dll" ] && missing="$missing (nvapi64.dll in the builtins: Steam's webhelper dies on it)"
  [ -f "$UNIX/winemetal.so" ] && [ -f "$PE64/winemetal.dll" ] || warnmsg="$warnmsg; no winemetal builtin placeholder (DXMT's dxgi cannot find winemetal.dll in a fresh prefix)"
  [ -f "$E/overlays/dxvk/x86_64-windows/d3d11.dll" ] || warnmsg="$warnmsg; overlays/dxvk absent (optional)"
  if [ -n "$missing" ]; then
    result FAIL overlays "missing:$missing"
  elif [ -n "$warnmsg" ]; then
    result WARN overlays "dxmt ok${warnmsg}"
  else
    result PASS overlays "dxmt ($(ls "$E/overlays/dxmt/x86_64-windows" | wc -l | tr -d ' ') x64 dlls) + dxvk ($(ls "$E/overlays/dxvk/x86_64-windows" | wc -l | tr -d ' ') x64 dlls); winemetal placeholder present"
  fi
}

gate_wine_version() {
  rosetta_ok || { result WARN wine_version "skipped: Rosetta 2 not installed"; return 0; }
  local out rc=0
  set +e
  out=$(env WINEMSYNC=1 WINEDEBUG=-all HOME="$TMPD" WINEPREFIX="$TMPD/prefix" \
        perl -e 'alarm shift; exec @ARGV' 60 "$BIN/wine" --version 2>&1)
  rc=$?
  set -e
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^wine-11'; then
    result PASS wine_version "$(printf '%s' "$out" | head -1) (WINEMSYNC=1)"
  else
    result FAIL wine_version "rc=$rc output: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
  fi
}

gate_codesign() {
  local f bad=0 n=0
  : > "$TMPD/cs.txt"
  while IFS= read -r f; do
    [ -L "$f" ] && continue
    n=$((n + 1))
    codesign --verify --strict "$f" >/dev/null 2>&1 || { echo "$(rel "$f")" >> "$TMPD/cs.txt"; bad=$((bad + 1)); }
  done < "$MACHO_LIST"
  if [ "$bad" = 0 ]; then result PASS codesign "$n Mach-O files verify"
  else result FAIL codesign "$bad of $n Mach-O files fail codesign --verify"; head -10 "$TMPD/cs.txt" | detail; fi
}

gate_weak_imports() {
  local f n=0
  : > "$TMPD/weak.txt"
  while IFS= read -r f; do
    nm -m "$f" 2>/dev/null | grep -E '\(undefined\) weak external' | grep -i 'libSystem' | awk -v f="$(rel "$f")" '{print f ": " $(NF-2)}' >> "$TMPD/weak.txt" || true
  done < <(find "$UNIX" -maxdepth 1 -name '*.so' | LC_ALL=C sort)
  n=$(wc -l < "$TMPD/weak.txt" | tr -d ' ')
  if [ "$n" = 0 ]; then
    result PASS weak_imports "no weak libSystem imports in the unix modules"
  else
    result WARN weak_imports "$n weak libSystem import(s): APIs the SDK declares above the floor are null on macOS $FLOOR_MAJOR"
    sort -u "$TMPD/weak.txt" | head -10 | detail
  fi
}

# ---------------------------------------------------------------------------------------------
selected() { # selected <gate>: honours --only / --skip
  local g=$1
  if [ -n "$ONLY" ]; then case ",$ONLY," in *",$g,"*) ;; *) return 1 ;; esac; fi
  case ",$SKIP," in *",$g,"*) return 1 ;; esac
  return 0
}

echo "gates: $E"
build_macho_list
for g in $ALL_GATES; do
  selected "$g" || continue
  set +e
  "gate_$g"
  set -e
done
echo "----"
printf 'gates: %d PASS, %d FAIL, %d WARN, %d SKIP\n' "$N_PASS" "$N_FAIL" "$N_WARN" "$N_SKIP"
if [ "$N_FAIL" -gt 0 ]; then exit 1; fi
if [ "$STRICT" = 1 ] && [ "$N_WARN" -gt 0 ]; then echo "(--strict: WARN counts as FAIL)"; exit 1; fi
exit 0

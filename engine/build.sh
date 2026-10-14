#!/bin/bash
# engine/build.sh — build the ossover Wine engine from the pinned CrossOver sources.
#
# Plan: ~/.claude/plans/i-am-building-ossover-virtual-turtle.md §5 "Engine build design"
# (two-stage configure: native arm64 tools via __tooldeps__, then the x86_64 Unix half with
# MacPorts deps and the mingw-w64 PE half) and §3 Phase 4.
#
# Reference recipes this adapts (read before changing anything here):
#   - gauthierpiarrette/highball-engine .github/workflows/build.yml  (single-stage Intel build,
#     install-lib, addons from dlls/appwiz.cpl/addons.c, strip numbers)
#   - frankea/winecx-gptk .github/workflows/build.yml                (native tools build +
#     --with-wine-tools, ccache settings, nls symlink, pipe2/floor pitfalls, config.h checks)
#
# Steps (each selectable, each logged to engine/work/logs/<step>.log, each timed):
#   --fetch      download engine/inputs.json inputs into engine/work/dl and verify sha256
#   --prep       extract sources/wine into engine/work/wine, apply engine/patches/*.patch
#   --tools      native (arm64) configure + make __tooldeps__ in engine/work/build-tools
#   --configure  x86_64 configure in engine/work/build (plan §5 flags)
#   --build      make -j
#   --install    make install-lib DESTDIR=engine/staging
#   --all        all of the above in order
#
# Everything lives under engine/work, engine/staging, engine/out (gitignored). If the repo path
# contains whitespace (autoconf, make and DESTDIR all break on it) work/ and staging/ become
# symlinks into $OSSOVER_BUILD_ROOT (default ~/.cache/ossover-engine) and the build runs there.
#
# bash 3.2 compatible (macOS /bin/bash): no associative arrays, no mapfile, no ${var,,}.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ENGINE_DIR="$SCRIPT_DIR"
REPO_DIR=$(cd "$ENGINE_DIR/.." && pwd)
INPUTS_JSON="$ENGINE_DIR/inputs.json"
PATCHES_DIR="$ENGINE_DIR/patches"
PREFIX=/opt/ossover/engine            # baked into the loader as the fallback dll dir only

# ---------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------
usage() {
  cat <<EOF
usage: $(basename "$0") [steps...] [options]

steps (run in this fixed order regardless of argument order):
  --fetch        download inputs from engine/inputs.json into engine/work/dl and verify sha256
  --prep         extract crossover sources/wine -> engine/work/wine, apply engine/patches/*.patch
  --tools        native arm64 build tools (configure + make __tooldeps__) in engine/work/build-tools
  --configure    x86_64 configure of the real build in engine/work/build (plan §5)
  --build        make -j<N> in engine/work/build
  --install      make install-lib DESTDIR=engine/staging
  --all          --fetch --prep --tools --configure --build --install
  --check        only run the prerequisite check and exit

options:
  --pin          accept inputs whose sha256 is "TBD": download, compute sha256, write it back
                 into engine/inputs.json (python3 -I json). Without --pin a TBD entry is an error.
  --jobs N       parallel jobs for make (default: sysctl hw.ncpu = $(sysctl -n hw.ncpu))
  --clean        remove engine/work/{wine,build,build-tools} and engine/staging first
                 (downloads and the ccache are kept)
  --verbose      also stream step output to the terminal (always goes to the log)
  --help         this text

environment:
  OSSOVER_BUILD_ROOT   space-free directory used for work/ and staging/ when the repo path
                       contains whitespace (default: \$HOME/.cache/ossover-engine)
  OSSOVER_MIRROR_URL   optional mirror tried before the upstream URL (<mirror>/<basename>)
  CCACHE_DIR           defaults to engine/work/ccache
  OSSOVER_FLOOR_WERROR set to 0 to drop -Werror=unguarded-availability-new from CFLAGS

outputs:
  engine/work/dl/*                downloads        engine/work/logs/<step>.log   logs
  engine/work/wine/               patched source   engine/work/build-tools/      arm64 tools
  engine/work/build/              x86_64 build     engine/staging/opt/ossover/engine/  install-lib
EOF
}

DO_FETCH=0 DO_PREP=0 DO_TOOLS=0 DO_CONFIGURE=0 DO_BUILD=0 DO_INSTALL=0 DO_CHECK=0
PIN=0 CLEAN=0 VERBOSE=0
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)

[ $# -gt 0 ] || { usage; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --fetch) DO_FETCH=1 ;;
    --prep) DO_PREP=1 ;;
    --tools) DO_TOOLS=1 ;;
    --configure) DO_CONFIGURE=1 ;;
    --build) DO_BUILD=1 ;;
    --install) DO_INSTALL=1 ;;
    --all) DO_FETCH=1 DO_PREP=1 DO_TOOLS=1 DO_CONFIGURE=1 DO_BUILD=1 DO_INSTALL=1 ;;
    --check) DO_CHECK=1 ;;
    --pin) PIN=1 ;;
    --jobs) shift; JOBS="${1:-}"; [ -n "$JOBS" ] || { echo "--jobs needs a number" >&2; exit 2; } ;;
    --jobs=*) JOBS="${1#--jobs=}" ;;
    --clean) CLEAN=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
case "$JOBS" in ''|*[!0-9]*) echo "--jobs must be a positive integer, got '$JOBS'" >&2; exit 2 ;; esac

# ---------------------------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------------------------
log()  { printf '[build] %s\n' "$*"; }
warn() { printf '[build] WARNING: %s\n' "$*" >&2; }
die()  { printf '[build] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

fmt_secs() { # 125 -> 2m05s
  local s=$1
  printf '%dm%02ds' $((s / 60)) $((s % 60))
}

# ---------------------------------------------------------------------------------------------
# Work directories. autoconf refuses a srcdir with whitespace, GNU make and Wine's install rules
# break on $(DESTDIR) with spaces, so the physical build location must be space-free. When the
# repo path is not, engine/work and engine/staging are created as symlinks into
# $OSSOVER_BUILD_ROOT and every step cd's into the physical target.
# ---------------------------------------------------------------------------------------------
has_space() { case "$1" in *[[:space:]]*) return 0 ;; *) return 1 ;; esac; }

resolve_dir() { # prints the physical path of an existing directory (follows symlinks)
  (cd -P "$1" 2>/dev/null && pwd -P)
}

ensure_space_free_dir() { # $1 = name under engine/ (work|staging); prints the physical dir
  local name=$1 link="$ENGINE_DIR/$1" target root
  if [ -L "$link" ]; then
    target=$(readlink "$link")
    [ -d "$target" ] || mkdir -p "$target"
    target=$(resolve_dir "$target")
  elif [ -d "$link" ]; then
    target=$(resolve_dir "$link")
  else
    if has_space "$ENGINE_DIR"; then
      root="${OSSOVER_BUILD_ROOT:-$HOME/.cache/ossover-engine}"
      has_space "$root" && die "OSSOVER_BUILD_ROOT '$root' contains whitespace; autoconf/make cannot build there"
      mkdir -p "$root/$name"
      ln -s "$root/$name" "$link"
      warn "repo path contains whitespace; engine/$name -> $root/$name (symlink created)"
      target=$(resolve_dir "$root/$name")
    else
      mkdir -p "$link"
      target=$(resolve_dir "$link")
    fi
  fi
  has_space "$target" && die "engine/$name resolves to '$target' which contains whitespace; set OSSOVER_BUILD_ROOT and remove engine/$name"
  printf '%s' "$target"
}

WORK=$(ensure_space_free_dir work)
STAGING=$(ensure_space_free_dir staging)
DL="$WORK/dl"
LOGS="$WORK/logs"
SRC_EXTRACT="$WORK/src"
WINE_SRC="$WORK/wine"
BUILD_TOOLS="$WORK/build-tools"
BUILD="$WORK/build"
mkdir -p "$DL" "$LOGS"

export CCACHE_DIR="${CCACHE_DIR:-$WORK/ccache}"
mkdir -p "$CCACHE_DIR"

# ---------------------------------------------------------------------------------------------
# inputs.json -> shell variables (one python3 -I call). Keys with '-' become '_':
#   IN_<name>_url, IN_<name>_sha256, IN_<name>_size, IN_<name>_license, IN_<name>_subdir,
#   IN_<name>_dylib, IN_<name>_optional ; INPUT_NAMES, ENGINE_ID, TC_*, PATCH_LIST
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
print("TC_HOST_TRIPLE=%s" % q(tc.get("host_triple", "x86_64-apple-darwin24")))
print("TC_PORTS=%s" % q(" ".join(tc.get("macports", {}).get("ports", []))))
print("TC_BREW=%s" % q(" ".join(tc.get("homebrew", []))))
print("PATCH_LIST=%s" % q(" ".join(d.get("patches", []))))
PY
)"
  [ "$INPUTS_SCHEMA" = "ossover-engine-inputs/1" ] || die "unexpected inputs.json schema '$INPUTS_SCHEMA'"
  [ -n "$ENGINE_ID" ] || die "inputs.json has no engineId"
}

input_field() { # input_field <name> <field>
  local var="IN_$(printf '%s' "$1" | tr '-' '_')_$2"
  printf '%s' "${!var:-}"
}

dl_path() { # local download path for an input
  printf '%s/%s' "$DL" "$(basename "$(input_field "$1" url)")"
}

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

write_pin() { # write_pin <name> <sha>  (python3 -I json, rewrites the file with indent=2)
  python3 -I - "$INPUTS_JSON" "$1" "$2" <<'PY'
import json, sys
path, name, sha = sys.argv[1:4]
d = json.load(open(path))
d["inputs"][name]["sha256"] = sha
with open(path, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

# ---------------------------------------------------------------------------------------------
# Step runner: <name> <function>. Output goes to logs/<name>.log (and the terminal with
# --verbose); the last 40 log lines are printed on failure; wall time is printed always.
# ---------------------------------------------------------------------------------------------
run_step() {
  local name=$1 fn=$2 logf="$LOGS/$1.log" t0=$SECONDS rc=0
  log "==> $name (log: $logf)"
  : > "$logf"
  # The step runs in a subshell that re-enables errexit itself. It must not be the operand of
  # an || / && / if, because bash ignores `set -e` inside a function called from such a
  # context and a failing command in the middle of a step would be skipped, not fatal.
  set +e
  if [ "$VERBOSE" = 1 ]; then
    ( set -e; "$fn" ) 2>&1 | tee -a "$logf" | sed 's/^/  /'
    rc=$?
  else
    ( set -e; "$fn" ) >>"$logf" 2>&1
    rc=$?
  fi
  set -e
  if [ "$rc" != 0 ]; then
    echo "----- error lines in $logf -----" >&2
    grep -nE 'configure: error|: error:|^make.*\*\*\*|Error [0-9]+$|fatal error' "$logf" | tail -n 25 >&2 || true
    echo "----- tail $logf -----" >&2
    tail -n 40 "$logf" >&2
    die "step '$name' failed after $(fmt_secs $((SECONDS - t0)))"
  fi
  log "<== $name done in $(fmt_secs $((SECONDS - t0)))"
}

# ---------------------------------------------------------------------------------------------
# Prerequisites (plan §5 toolchain). Checked before --tools/--configure/--build/--install.
# ---------------------------------------------------------------------------------------------
BISON_DIR=/opt/homebrew/opt/bison/bin
# MacPorts' ffmpeg7 is a versioned "libexec" port: it installs into /opt/local/libexec/ffmpeg7
# (so it can coexist with ffmpeg 4/6) and its .pc files are NOT under /opt/local/lib/pkgconfig.
# The x86_64 configure must see this dir or `--with-ffmpeg` dies with "FFmpeg 64-bit development
# files not found" (2026-10-14: that was the first configure failure; the message was buried
# under the config.log dump the old failure handler printed).
FFMPEG_PC_DIR=/opt/local/libexec/ffmpeg7/lib/pkgconfig

# configure_failed <config.log>: what a failed configure actually complained about. The old
# handler dumped config.log lines 100-500 (the compiler flag probes, every one of which fails
# "normally") and the step runner's 40-line tail never reached the `configure: error:` line.
configure_failed() {
  local cl=$1
  echo "==== configure failed ===="
  if [ -f "$cl" ]; then
    grep -nE '^configure:[0-9]+: error:|^configure: error:' "$cl" || true
    echo "---- last checks / library errors before the exit (from $cl) ----"
    sed -n '1,/^## Cache variables/p' "$cl" \
      | grep -E '^configure:[0-9]+: (checking|result|error)|errors: |No package|not found|: error:' \
      | tail -n 30
  else
    echo "(no $cl written)"
  fi
  return 1
}

check_prereqs() {
  local fail=0 p

  if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    log "rosetta: ok"
  else
    warn "Rosetta 2 is not installed: sudo softwareupdate --install-rosetta --agree-to-license"; fail=1
  fi

  if [ -x /opt/local/bin/port ]; then
    log "macports: /opt/local/bin/port ($(/opt/local/bin/port version 2>/dev/null | tr -d '\n' || true))"
    for p in $TC_PORTS; do
      if /opt/local/bin/port -q installed "$p" 2>/dev/null | grep -q '(active)'; then
        :
      else
        warn "MacPorts port not installed/active: $p   (sudo port -N install $p)"; fail=1
      fi
    done
    if [ -r /opt/local/etc/macports/macports.conf ]; then
      grep -Eq '^[[:space:]]*build_arch[[:space:]]+x86_64' /opt/local/etc/macports/macports.conf \
        || { warn "macports.conf: 'build_arch x86_64' not set; ports would be arm64"; fail=1; }
      grep -Eq "^[[:space:]]*macosx_deployment_target[[:space:]]+${TC_DEPLOYMENT_TARGET%%.*}" /opt/local/etc/macports/macports.conf \
        || warn "macports.conf: 'macosx_deployment_target $TC_DEPLOYMENT_TARGET' not set; bundled dylibs will carry minos of this macOS and fail the minos gate"
    fi
    # The conf line is not enough: ports fetched as binary archives are built on the buildbots
    # with the default target (this macOS), so measure what is installed (2026-10-14: 566 of 567
    # dylibs were minos 26.0; only a locally built libjbig honoured 15.0). package.sh then raises
    # the manifest minMacOS to the closure floor. Fix: `buildfromsource always` in macports.conf
    # and `sudo port -N -s upgrade --force installed` (hours; ffmpeg/x265/gstreamer from source).
    local mp_minos
    mp_minos=$(otool -l /opt/local/lib/libglib-2.0.0.dylib 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}')
    if [ -n "$mp_minos" ] && awk -v a="$mp_minos" -v b="$TC_DEPLOYMENT_TARGET" 'BEGIN{split(a,x,"."); split(b,y,"."); exit !((x[1]+0) > (y[1]+0) || ((x[1]+0) == (y[1]+0) && (x[2]+0) > (y[2]+0)))}'; then
      warn "MacPorts libglib-2.0 is minos $mp_minos, above the $TC_DEPLOYMENT_TARGET floor (binary archives); the packaged engine's minMacOS will be raised to the closure floor. To keep $TC_DEPLOYMENT_TARGET: 'buildfromsource always' in macports.conf, then sudo port -N -s upgrade --force installed"
    fi
  else
    warn "MacPorts not installed (/opt/local/bin/port missing); see engine/README.md"; fail=1
  fi

  for p in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc x86_64-w64-mingw32-strip; do
    if have "$p"; then log "$p: $(command -v "$p")"; else warn "missing $p (brew install mingw-w64)"; fail=1; fi
  done

  if [ -x "$BISON_DIR/bison" ]; then
    local bv; bv=$("$BISON_DIR/bison" --version | head -1 | sed 's/.* //')
    case "$bv" in
      [3-9].*|[1-9][0-9].*) log "bison: $bv ($BISON_DIR)" ;;
      *) warn "bison at $BISON_DIR is $bv, need >= 3.0"; fail=1 ;;
    esac
  else
    warn "missing $BISON_DIR/bison (brew install bison); the Xcode bison 2.3 is too old"; fail=1
  fi

  for p in flex ccache curl patch python3 shasum xcrun clang; do
    if have "$p"; then :; else warn "missing $p"; fail=1; fi
  done
  # pkg-config: Homebrew's (arm64) or MacPorts' (x86_64, runs under Rosetta); both work because
  # every configure pins PKG_CONFIG_LIBDIR to the tree it may see.
  if have pkg-config; then PKG_CONFIG_BIN=$(command -v pkg-config)
  elif have pkgconf; then PKG_CONFIG_BIN=$(command -v pkgconf)
  elif [ -x /opt/local/bin/pkg-config ]; then PKG_CONFIG_BIN=/opt/local/bin/pkg-config
  else warn "missing pkg-config (MacPorts 'pkgconfig' port or brew install pkgconf)"; fail=1; fi
  log "pkg-config: ${PKG_CONFIG_BIN:-none}"
  log "ccache: $(ccache --version 2>/dev/null | head -1 || echo '?')  CCACHE_DIR=$CCACHE_DIR"

  if xcrun --show-sdk-path >/dev/null 2>&1; then
    log "sdk: $(xcrun --show-sdk-path) (version $(xcrun --show-sdk-version 2>/dev/null || echo '?'))"
  else
    warn "xcrun cannot locate an SDK; install Xcode or the Command Line Tools"; fail=1
  fi

  # Native freetype for the arm64 tools build: sfnt2fon (fonts) links it and the main build
  # takes sfnt2fon from --with-wine-tools. Without it configure skips the tool and the x86_64
  # build fails on the first .fon (winecx-gptk: "native freetype is needed because sfnt2fon
  # links it"). MacPorts freetype is x86_64 so it cannot serve the native stage.
  if [ -f "$FFMPEG_PC_DIR/libavcodec.pc" ]; then
    log "ffmpeg7: $FFMPEG_PC_DIR"
  else
    warn "no $FFMPEG_PC_DIR/libavcodec.pc (sudo port -N install ffmpeg7); --with-ffmpeg would fail"; fail=1
  fi

  if [ -d /opt/homebrew/opt/freetype/lib/pkgconfig ]; then
    log "native freetype: /opt/homebrew/opt/freetype"
  else
    warn "Homebrew freetype not found (brew install freetype); the tools build will not have sfnt2fon and fonts will fail to build"; fail=1
  fi

  [ "$fail" = 0 ] || die "prerequisites missing (see warnings above); engine/README.md has the install steps"
  log "prerequisites: ok"
}

# ---------------------------------------------------------------------------------------------
# --fetch
# ---------------------------------------------------------------------------------------------
fetch_one() { # fetch_one <url> <dest>
  local url=$1 dest=$2 part="$2.part" base
  base=$(basename "$dest")
  if [ -n "${OSSOVER_MIRROR_URL:-}" ]; then
    echo "trying mirror ${OSSOVER_MIRROR_URL%/}/$base"
    if curl -fL --retry 2 --connect-timeout 15 -o "$part" "${OSSOVER_MIRROR_URL%/}/$base"; then
      mv "$part" "$dest"; return 0
    fi
    rm -f "$part"
  fi
  echo "downloading $url"
  if ! curl -fL --retry 3 --retry-delay 3 -C - --progress-bar -o "$part" "$url"; then
    # a leftover .part the server will not resume (HTTP 416) — start over once
    rm -f "$part"
    curl -fL --retry 3 --retry-delay 3 --progress-bar -o "$part" "$url"
  fi
  mv "$part" "$dest"
}

step_fetch() {
  local name url sha want got dest size tbd_missing=""
  for name in $INPUT_NAMES; do
    url=$(input_field "$name" url)
    want=$(input_field "$name" sha256)
    size=$(input_field "$name" size)
    dest=$(dl_path "$name")
    [ -n "$url" ] || { echo "input $name has no url"; return 1; }

    if [ "$want" = "TBD" ] && [ "$PIN" != 1 ]; then
      echo "input $name: sha256 is TBD and --pin was not given; skipping"
      tbd_missing="$tbd_missing $name"
      continue
    fi

    if [ -f "$dest" ]; then
      got=$(sha256_of "$dest")
      if [ "$want" = "TBD" ]; then
        :
      elif [ "$got" = "$want" ]; then
        echo "input $name: present and verified ($(basename "$dest"))"
        continue
      else
        echo "input $name: cached file does not match pin, re-downloading"
        rm -f "$dest"
      fi
    fi

    [ -f "$dest" ] || fetch_one "$url" "$dest"
    got=$(sha256_of "$dest")
    if [ -n "$size" ] && [ "$(wc -c < "$dest" | tr -d ' ')" != "$size" ]; then
      echo "input $name: size $(wc -c < "$dest" | tr -d ' ') differs from inputs.json size $size (upstream re-upload?)"
    fi
    if [ "$want" = "TBD" ]; then
      write_pin "$name" "$got"
      echo "input $name: pinned sha256 $got (written to inputs.json)"
    elif [ "$got" != "$want" ]; then
      echo "input $name: sha256 MISMATCH"
      echo "   expected $want"
      echo "   got      $got"
      echo "   file     $dest  (left in place for inspection)"
      return 1
    else
      echo "input $name: downloaded and verified"
    fi
  done
  if [ -n "$tbd_missing" ]; then
    echo "inputs with sha256 TBD not fetched:$tbd_missing"
    echo "re-run with --pin to download them and record their sha256 in inputs.json"
    return 1
  fi
}

# ---------------------------------------------------------------------------------------------
# --prep : extract sources/wine, apply patches, cross-check addons versions
# ---------------------------------------------------------------------------------------------
prep_signature() { # sha of the source tarball + every patch that will be applied
  local p sig
  sig="source=$(input_field crossover-sources sha256)"
  for p in "$PATCHES_DIR"/*.patch; do
    [ -f "$p" ] || continue
    sig="$sig;$(basename "$p")=$(sha256_of "$p")"
  done
  printf '%s' "$sig"
}

step_prep() {
  local tarball subdir root stamp sig p listed name found addons mono_want gecko_want mono_have gecko_have
  tarball=$(dl_path crossover-sources)
  subdir=$(input_field crossover-sources subdir)
  [ -f "$tarball" ] || { echo "missing $tarball; run --fetch first"; return 1; }
  [ -n "$subdir" ] || subdir="sources/wine"
  [ "$(sha256_of "$tarball")" = "$(input_field crossover-sources sha256)" ] || { echo "$tarball does not match its pin"; return 1; }

  sig=$(prep_signature)
  stamp="$WINE_SRC/.ossover-prep-stamp"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$sig" ]; then
    echo "source tree up to date (same tarball and patch set); nothing to do"
    return 0
  fi

  rm -rf "$WINE_SRC" "$SRC_EXTRACT"
  mkdir -p "$SRC_EXTRACT"
  echo "listing tarball root"
  root=$(tar -tzf "$tarball" | head -1)
  echo "first member: $root"
  echo "extracting $subdir (this is a 149 MB tarball; ~1 minute)"
  # extract only the wine subtree; try the two layouts the tarball has had (sources/wine at the
  # root, or under a crossover-sources-<ver>/ directory), then fall back to everything.
  if ! tar -xzf "$tarball" -C "$SRC_EXTRACT" "$subdir" 2>/dev/null; then
    rm -rf "$SRC_EXTRACT"; mkdir -p "$SRC_EXTRACT"
    tar -xzf "$tarball" -C "$SRC_EXTRACT"
  fi
  found=$(find "$SRC_EXTRACT" -maxdepth 4 -type d -path "*/$subdir" | head -1)
  [ -n "$found" ] && [ -f "$found/configure" ] || { echo "could not find $subdir/configure inside the tarball"; return 1; }
  mv "$found" "$WINE_SRC"
  rm -rf "$SRC_EXTRACT"
  echo "wine source: $WINE_SRC ($(cat "$WINE_SRC/VERSION" 2>/dev/null || echo 'no VERSION file'))"

  # patches: engine/patches/*.patch in lexical order (highball-engine convention: numbered
  # files, each with a header). inputs.json lists the expected set; mismatches are warnings.
  for name in $PATCH_LIST; do
    [ -f "$PATCHES_DIR/$name" ] || echo "WARNING: patch listed in inputs.json is absent, skipping: $name"
  done
  # Base + patch set confirmed by the REA pass (decision 27): the 26.3.0 tarball defines every
  # unix-side export the shipped CrossOver has (REA L-46), identifies itself as
  # wine-11.0-8726-g2e2f5fca349 (L-45), and 0001/0003/0014 dry-run cleanly — 0003 at loader.c:387,
  # offset -209 (L-47). Refresh engine/patches/README.md's table when the tarball pin changes.
  listed=" $PATCH_LIST "
  for p in "$PATCHES_DIR"/*.patch; do
    [ -f "$p" ] || { echo "no patches in $PATCHES_DIR"; break; }
    name=$(basename "$p")
    case "$listed" in *" $name "*) ;; *) echo "WARNING: $name is not listed in inputs.json patches; applying anyway (lexical order)" ;; esac
    echo "applying $name"
    (cd "$WINE_SRC" && patch -p1 -N -t --dry-run < "$p" >/dev/null) || { echo "patch does not apply cleanly: $name"; (cd "$WINE_SRC" && patch -p1 -N -t --dry-run < "$p") || true; return 1; }
    (cd "$WINE_SRC" && patch -p1 -N -t < "$p")
  done

  # addons cross-check (plan §5 "gate against dlls/appwiz.cpl/addons.c"): the tarballs pinned in
  # inputs.json must be the versions mscoree/mshtml look for, or a bottle's first boot stops
  # on the "install Mono?" dialog (highball-engine, found 2026-09-04).
  addons="$WINE_SRC/dlls/appwiz.cpl/addons.c"
  if [ -f "$addons" ]; then
    mono_have=$(sed -n 's/^#define MONO_VERSION "\(.*\)"/\1/p' "$addons")
    gecko_have=$(sed -n 's/^#define GECKO_VERSION "\(.*\)"/\1/p' "$addons")
    mono_want=$(input_field wine-mono url | sed -n 's|.*/wine-mono-\([0-9.]*\)-x86\.tar\.xz$|\1|p')
    gecko_want=$(input_field wine-gecko-x86_64 url | sed -n 's|.*/wine-gecko-\([0-9.]*\)-x86_64\.tar\.xz$|\1|p')
    echo "addons.c wants wine-mono $mono_have, wine-gecko $gecko_have; inputs.json pins $mono_want / $gecko_want"
    [ "$mono_have" = "$mono_want" ] || { echo "wine-mono pin mismatch: update inputs.json to $mono_have"; return 1; }
    [ "$gecko_have" = "$gecko_want" ] || { echo "wine-gecko pin mismatch: update inputs.json to $gecko_have"; return 1; }
  else
    echo "WARNING: $addons not found; cannot cross-check mono/gecko versions"
  fi

  printf '%s' "$sig" > "$stamp"
  echo "prepared; stamp written"
}

# ---------------------------------------------------------------------------------------------
# Shared build environment
# ---------------------------------------------------------------------------------------------
setup_build_env() {
  export PATH="$BISON_DIR:$PATH"
  # 15.0 is above CrossOver's own 10.15 floor (its libraries are LC_BUILD_VERSION minos 10.15, SDK
  # 15.1) and fine for ossover; the manifest's minMacOS is raised to 14.0 only by a DXMT/D3DMetal
  # overlay, which package.sh handles (REA L-51, L-62; decision 30).
  export MACOSX_DEPLOYMENT_TARGET="$TC_DEPLOYMENT_TARGET"
  SDKROOT=$(xcrun --show-sdk-path); export SDKROOT
  # ccache (winecx-gptk): content check so a cache survives Xcode updates; time macros and
  # include mtimes out of the hash so a fresh extraction still hits.
  export CCACHE_COMPILERCHECK=content
  export CCACHE_SLOPPINESS=time_macros,locale,include_file_mtime,include_file_ctime
  export CCACHE_BASEDIR="$WORK"
  export CCACHE_NOHASHDIR=1
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-8G}"
}

# ---------------------------------------------------------------------------------------------
# --tools : native arm64 build tools (makedep, winebuild, wrc, widl, wmc, sfnt2fon, ...)
# ---------------------------------------------------------------------------------------------
step_tools() {
  [ -f "$WINE_SRC/configure" ] || { echo "no source at $WINE_SRC; run --prep"; return 1; }
  setup_build_env
  mkdir -p "$BUILD_TOOLS"
  cd "$BUILD_TOOLS"
  if [ -f "$BUILD_TOOLS/Makefile" ] && [ -x "$BUILD_TOOLS/tools/winebuild/winebuild" ] && [ -x "$BUILD_TOOLS/tools/widl/widl" ]; then
    echo "build-tools already configured; re-running make __tooldeps__ (incremental)"
  else
    # Native configure: without --enable-archs Wine defaults to aarch64 and stops on "PE
    # cross-compilation is required"; only __tooldeps__ is built here so the list just has to
    # name archs a PE compiler exists for (winecx-gptk). Nothing x86_64 from /opt/local may leak
    # in: PKG_CONFIG_LIBDIR is pinned to Homebrew's (arm64) freetype for sfnt2fon.
    env CC="ccache /usr/bin/clang" CXX="ccache /usr/bin/clang++" \
        PKG_CONFIG="${PKG_CONFIG:-${PKG_CONFIG_BIN:-/opt/local/bin/pkg-config}}" \
        PKG_CONFIG_LIBDIR="/opt/homebrew/opt/freetype/lib/pkgconfig:/opt/homebrew/lib/pkgconfig" \
        PKG_CONFIG_PATH="/opt/homebrew/opt/freetype/lib/pkgconfig" \
        "$WINE_SRC/configure" \
          --enable-archs=i386,x86_64 \
          --without-x --without-wayland --without-gstreamer --without-ffmpeg \
          --without-oss --without-alsa --without-pulse --without-sane --without-usb \
          --without-v4l2 --without-pcap --without-capi --without-opencl --without-cups \
          --without-gnutls --without-sdl --without-vulkan \
          --disable-tests \
      || { configure_failed config.log; return 1; }
  fi
  make -j"$JOBS" __tooldeps__
  grep -q 'sfnt2fon' Makefile || echo "WARNING: sfnt2fon not in the tools build (freetype missing?); fonts will fail in the main build"

  # wrc resolves nls data relative to its own binary (tools/wrc/../../nls); __tooldeps__ never
  # populates an out-of-tree nls dir, so the main build's first .res would die with "unable to
  # load locale.nls". Link the file, not the dir (winecx-gptk).
  rm -rf nls && mkdir nls && ln -s "$WINE_SRC/nls/locale.nls" nls/locale.nls
  test -r nls/locale.nls || { echo "tools nls dir does not resolve"; return 1; }
  for t in tools/makedep tools/winebuild/winebuild tools/wrc/wrc tools/widl/widl tools/wmc/wmc; do
    [ -x "$t" ] || { echo "expected tool missing: $t"; return 1; }
    echo "$t: $(lipo -archs "$t" 2>/dev/null || file -b "$t")"
  done
}

# ---------------------------------------------------------------------------------------------
# --configure : the x86_64 build (plan §5 verbatim, plus the floor guards from winecx-gptk)
# ---------------------------------------------------------------------------------------------
step_configure() {
  [ -f "$WINE_SRC/configure" ] || { echo "no source at $WINE_SRC; run --prep"; return 1; }
  [ -x "$BUILD_TOOLS/tools/winebuild/winebuild" ] || { echo "no tools in $BUILD_TOOLS; run --tools"; return 1; }
  setup_build_env
  mkdir -p "$BUILD"
  cd "$BUILD"

  local cflags="-O2 -I/opt/local/include -Wno-error=implicit-function-declaration"
  # The SDK is newer than the 15.0 floor. clang's answer to an API above the target is a weak
  # link that is a null pointer on the older OS, so make the unguarded use a compile error
  # (host flags only; mingw does not know the flag). OSSOVER_FLOOR_WERROR=0 turns it off.
  [ "${OSSOVER_FLOOR_WERROR:-1}" = 0 ] || cflags="$cflags -Werror=unguarded-availability-new"

  # ac_cv_func_pipe2=no: pipe2 is declared by the newer SDK and absent on macOS < 27; all call
  # sites have a pipe+fcntl fallback behind HAVE_PIPE2 (winecx-gptk issue #3).
  # ac_cv_lib_soname_*: bare sonames, else configure bakes /opt/local/lib/... into the dlopen
  # calls and the relocated engine opens the builder's copies (or nothing).
  env \
    PKG_CONFIG="${PKG_CONFIG:-${PKG_CONFIG_BIN:-/opt/local/bin/pkg-config}}" \
    PKG_CONFIG_PATH="$FFMPEG_PC_DIR:/opt/local/lib/pkgconfig" \
    PKG_CONFIG_LIBDIR="$FFMPEG_PC_DIR:/opt/local/lib/pkgconfig:/opt/local/share/pkgconfig" \
    CC="ccache /usr/bin/clang -arch x86_64" \
    CXX="ccache /usr/bin/clang++ -arch x86_64" \
    CROSSCC="ccache x86_64-w64-mingw32-gcc" \
    i386_CC="ccache i686-w64-mingw32-gcc" \
    x86_64_CC="ccache x86_64-w64-mingw32-gcc" \
    CFLAGS="$cflags" \
    CROSSCFLAGS="-O2" \
    LDFLAGS="-L/opt/local/lib -Wl,-headerpad_max_install_names" \
    ac_cv_func_pipe2=no \
    ac_cv_lib_soname_MoltenVK=libMoltenVK.dylib \
    ac_cv_lib_soname_freetype=libfreetype.6.dylib \
    ac_cv_lib_soname_gnutls=libgnutls.30.dylib \
    ac_cv_lib_soname_SDL2=libSDL2-2.0.0.dylib \
    "$WINE_SRC/configure" \
      --host="$TC_HOST_TRIPLE" \
      --with-wine-tools="$BUILD_TOOLS" \
      --prefix="$PREFIX" \
      `# --prefix is baked into ntdll.so only as relative-path seeds (bin_dir/data_dir derive from the real dll_dir), so the tarball stays relocatable (REA L-50; decision 30)` \
      --enable-archs=i386,x86_64 \
      --with-mingw \
      --disable-tests \
      --with-coreaudio --with-freetype --with-gnutls --with-gstreamer --with-ffmpeg \
      --with-vulkan --with-sdl \
      --without-x --without-wayland --without-inotify \
      --without-alsa --without-oss --without-pulse --without-capi --without-cups \
      --without-dbus --without-gphoto --without-sane --without-usb --without-v4l2 \
      --without-pcap --without-krb5 --without-gssapi --without-netapi --without-udev \
      --without-opencl --without-pcsclite \
    || { configure_failed config.log; return 1; }
  # (no --with-opengl / --without-opengl: the CX tree links OpenGL.framework for wined3d, and an
  #  explicit --with-opengl makes the missing EGL headers a hard error — highball-engine)

  # configure only *notices* a missing optional library; a bad pkg-config path would ship an
  # engine with no video decode and say nothing (winecx-gptk).
  grep -q '^#define HAVE_FFMPEG 1' include/config.h || { echo "ffmpeg not found; winedmo would have no backend"; grep -i 'ffmpeg\|libav' config.log | tail -20; return 1; }
  grep -qE '^GSTREAMER_LIBS *= *.+' Makefile || { echo "gstreamer not found; winegstreamer would not be built"; grep -i 'gstreamer\|glib-2.0' config.log | tail -20; return 1; }
  grep -qE '^#define SONAME_LIB(MOLTENVK|VULKAN) ' include/config.h || { echo "no MoltenVK/vulkan soname in config.h"; return 1; }
  for s in FREETYPE GNUTLS SDL2; do
    grep -q "^#define SONAME_LIB$s " include/config.h || echo "WARNING: SONAME_LIB$s not defined in config.h"
  done
  # every dlopen soname must be bare: an absolute /opt/local path here is a dependency the
  # closure walk in package.sh cannot see (not a load command) and that only exists on this Mac.
  if grep -E '^#define SONAME_' include/config.h | grep -E '"/(opt|usr/local|nix)'; then
    echo "absolute soname(s) above; add ac_cv_lib_soname_<lib>=<bare name> to step_configure"; return 1
  fi
  echo "configure: ffmpeg ok, gstreamer ok, sonames:"
  grep -E '^#define SONAME_' include/config.h
}

# ---------------------------------------------------------------------------------------------
# --build
# ---------------------------------------------------------------------------------------------
step_build() {
  [ -f "$BUILD/Makefile" ] || { echo "no Makefile in $BUILD; run --configure"; return 1; }
  setup_build_env
  cd "$BUILD"
  ccache -z >/dev/null 2>&1 || true
  make -j"$JOBS"
  echo "---- ccache stats for this make ----"
  ccache -s 2>/dev/null || true
  # Availability warnings that got through (CFLAGS can only catch clang's own diagnostics on
  # the files it compiles; a linked API above the floor is a null pointer on macOS 15).
  if grep -q 'has been marked as being introduced in macOS' "$LOGS/build.log" 2>/dev/null; then
    echo "WARNING: APIs above the $TC_DEPLOYMENT_TARGET floor were referenced:"
    grep -oE "'[A-Za-z_0-9]+' has been marked as being introduced in macOS [0-9.]+" "$LOGS/build.log" | sort -u
    echo "WARNING: the engine may not load on macOS $TC_DEPLOYMENT_TARGET; see winecx-gptk notes on pipe2"
  fi
}

# ---------------------------------------------------------------------------------------------
# --install
# ---------------------------------------------------------------------------------------------
step_install() {
  [ -f "$BUILD/Makefile" ] || { echo "no Makefile in $BUILD; run --configure/--build"; return 1; }
  setup_build_env
  cd "$BUILD"
  rm -rf "$STAGING"
  mkdir -p "$STAGING"
  # install-lib, not install: `install` also runs install-dev, whose prerequisite list is ~2000
  # import libraries that take 15+ minutes to build and are deleted again (winecx-gptk).
  make -j"$JOBS" install-lib DESTDIR="$STAGING"
  local root="$STAGING$PREFIX"
  [ -f "$root/lib/wine/x86_64-unix/ntdll.so" ] || { echo "install-lib produced no $root/lib/wine/x86_64-unix/ntdll.so"; return 1; }
  [ -d "$root/lib/wine/i386-windows" ] || { echo "no i386-windows in the install; --enable-archs did not take"; return 1; }
  echo "staged: $root"
  echo "  x86_64-unix:    $(ls "$root/lib/wine/x86_64-unix" | wc -l | tr -d ' ') files"
  echo "  x86_64-windows: $(ls "$root/lib/wine/x86_64-windows" | wc -l | tr -d ' ') files"
  echo "  i386-windows:   $(ls "$root/lib/wine/i386-windows" | wc -l | tr -d ' ') files"
  echo "  bin:            $(ls "$root/bin" | tr '\n' ' ')"
  du -sh "$root" | sed 's/^/  size: /'
  {
    echo "engineId=$ENGINE_ID"
    echo "prefix=$PREFIX"
    echo "sourceSha256=$(input_field crossover-sources sha256)"
    echo "deploymentTarget=$TC_DEPLOYMENT_TARGET"
    echo "sdk=$(xcrun --show-sdk-version 2>/dev/null || echo '?')"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$STAGING/.ossover-install-stamp"
}

# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------
load_inputs
log "engine $ENGINE_ID  work=$WORK  staging=$STAGING  jobs=$JOBS"

if [ "$CLEAN" = 1 ]; then
  log "cleaning work/{wine,src,build,build-tools} and staging (keeping dl/ and ccache/)"
  rm -rf "$WINE_SRC" "$SRC_EXTRACT" "$BUILD" "$BUILD_TOOLS" "$STAGING"
  mkdir -p "$STAGING"
fi

if [ "$DO_CHECK" = 1 ]; then
  check_prereqs
  exit 0
fi

T_ALL=$SECONDS
if [ "$DO_TOOLS" = 1 ] || [ "$DO_CONFIGURE" = 1 ] || [ "$DO_BUILD" = 1 ] || [ "$DO_INSTALL" = 1 ]; then
  check_prereqs
fi
if [ "$DO_FETCH" = 1 ];     then run_step fetch     step_fetch;     fi
if [ "$DO_PREP" = 1 ];      then run_step prep      step_prep;      fi
if [ "$DO_TOOLS" = 1 ];     then run_step tools     step_tools;     fi
if [ "$DO_CONFIGURE" = 1 ]; then run_step configure step_configure; fi
if [ "$DO_BUILD" = 1 ];     then run_step build     step_build;     fi
if [ "$DO_INSTALL" = 1 ];   then run_step install   step_install;   fi
log "all requested steps done in $(fmt_secs $((SECONDS - T_ALL)))"
if [ "$DO_INSTALL" = 1 ]; then
  log "next: $ENGINE_DIR/package.sh   then   $ENGINE_DIR/gates.sh $ENGINE_DIR/out/$ENGINE_ID"
fi

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""engine/manifest.py <inputs.json> <engine-dir>/manifest.json — write the engine manifest.

Called by engine/package.sh after the tree is assembled, relocated and signed, with every
measured value in OSS_* environment variables (see the `env … python3 -I manifest.py` call
there). engine/selftest.sh runs it on a synthetic tree, so the shape can be checked against
Sources/OssoverKit/Model/EngineManifest.swift (`ossover engine validate-manifest`) without a
45-minute engine build.

Shape: exactly what EngineManifest decodes — schema, id, displayName, version, wineVersion,
wineVersionString, arch, minMacOS, requires, source{url,sha256,size,license,extract{strip,into}},
paths{wine,wineserver,libWine}, baseEnv, capabilities{msync,esync,wow64,macdrvExports,
dllPathPrepend,d3dmetalHost}, bundledRenderers[{kind,version,path,layout{unix,pe,pe32},
builtinMarked}], addons{wineMono,wineGecko}, notes. Everything else (components, build, licenses,
and `requires` / `minMacOS` inside each bundled renderer) is the packaging record: JSONDecoder
ignores it, and `ossover engine install` drops it when it re-saves the manifest through the
Swift model.

Evidence (docs/rea/decisions.md 27-32): capabilities.esync=false on the CX tree [L-32];
wineVersionString from ntdll.so [L-45]; minMacOS raised to the overlay floor (14.0 for DXMT /
D3DMetal) [L-62, L-78]; no DYLD_* rows in baseEnv — CrossOver never sets them and the hardened
runtime ignores them; the rpath rule carries the tree [L-12, L-54].
"""
import json
import os
import pathlib
import re
import sys

BUILTIN_MARK = b"Wine builtin DLL\0"   # server/mapping.c; PEBuiltinMark.swift (REA L-25)
MARK_OFFSET = 0x40


def truthy(env, key):
    return env.get(key, "false") == "true"


def is_builtin_marked(path):
    """True/False for the 17-byte DOS-stub mark Wine's loader honours; None when `path` is
    not an MZ file (or is missing)."""
    try:
        with open(path, "rb") as f:
            head = f.read(MARK_OFFSET + len(BUILTIN_MARK))
    except OSError:
        return None
    if len(head) < 0x40 or head[:2] != b"MZ":
        return None
    lfanew = int.from_bytes(head[0x3C:0x40], "little")
    if lfanew < MARK_OFFSET + len(BUILTIN_MARK) or len(head) < MARK_OFFSET + len(BUILTIN_MARK):
        return False
    return head[MARK_OFFSET:MARK_OFFSET + len(BUILTIN_MARK)] == BUILTIN_MARK


def overlay_layout(engine_root, path):
    """{unix, pe, pe32}: file names under <path>/{x86_64-unix,x86_64-windows,i386-windows},
    the shape RendererLayout (Model/RendererPack.swift) decodes; pe32 only when the 32-bit
    directory exists (decision 16c)."""
    root = os.path.join(engine_root, path)

    def names(sub, ext):
        d = os.path.join(root, sub)
        return sorted(f for f in os.listdir(d) if f.lower().endswith(ext)) if os.path.isdir(d) else []

    layout = {"unix": names("x86_64-unix", ".so"), "pe": names("x86_64-windows", ".dll")}
    if os.path.isdir(os.path.join(root, "i386-windows")):
        layout["pe32"] = names("i386-windows", ".dll")
    return layout


def bundled_renderer(engine_root, env, kind, version, requires):
    path = "overlays/" + kind
    entry = {
        "kind": kind,
        "version": version,
        "path": path,
        "layout": overlay_layout(engine_root, path),
        "builtinMarked": is_builtin_marked(os.path.join(engine_root, path, "x86_64-windows", "d3d11.dll")),
    }
    minos = env.get("OSS_%s_MINOS" % kind.upper())
    if minos:
        entry["minMacOS"] = minos     # measured floor of the overlay's own Mach-Os (REA L-62)
    entry["requires"] = requires      # engine capabilities the overlay needs (decision 16c)
    return entry


def build_manifest(inputs, env, engine_root):
    b = lambda k: truthy(env, k)  # noqa: E731

    versions = {
        "crossover-sources": r"crossover-sources-([0-9.]+)\.tar\.gz$",
        "dxmt": r"/v([0-9.]+)/",
        "moltenvk": r"/v([0-9.]+)/",
        "dxvk-macos": r"/v([0-9.]+-[0-9]+-repack)/",
        "wine-mono": r"wine-mono-([0-9.]+)-x86",
        "wine-gecko-x86": r"wine-gecko-([0-9.]+)-x86\.",
        "wine-gecko-x86_64": r"wine-gecko-([0-9.]+)-x86_64",
    }
    roles = {
        "crossover-sources": "wine source (built, not shipped as source)",
        "dxmt": "overlays/dxmt",
        "moltenvk": "wine/lib/libMoltenVK.dylib",
        "dxvk-macos": "overlays/dxvk",
        "wine-mono": "wine/share/wine/mono",
        "wine-gecko-x86": "wine/share/wine/gecko",
        "wine-gecko-x86_64": "wine/share/wine/gecko",
    }
    components = []
    parsed = {}   # input id -> version parsed from its pinned URL: one spelling for the whole manifest
    for name, e in inputs["inputs"].items():
        m = re.search(versions.get(name, r"$^"), e["url"])
        parsed[name] = m.group(1) if m else None
        bundled = True
        if name == "dxvk-macos":
            bundled = b("OSS_HAS_DXVK")
        if name == "crossover-sources":
            bundled = False
        components.append({
            "id": name, "version": parsed[name], "url": e["url"],
            "sha256": e.get("sha256"), "size": e.get("size"), "license": e.get("license"),
            "bundled": bundled, "path": roles.get(name),
        })
    components.append({
        "id": "macports-closure", "version": None, "url": "https://www.macports.org/",
        "sha256": None, "size": None,
        "license": "per library (freetype FTL/GPL-2, gnutls LGPL-2.1+, GStreamer LGPL-2.1+, FFmpeg LGPL-2.1+/GPL, SDL2 zlib, glib LGPL-2.1+)",
        "bundled": True, "path": "wine/lib/*.dylib, wine/lib/gstreamer-1.0",
        "ports": env.get("OSS_PORTS", "").split(),
    })

    # bundledRenderers[].version is spelled exactly as components[].version for the same input
    # (decision 32): both come from the pinned URL in inputs.json, so a pin bump moves them
    # together. package.sh measures OSS_DXMT_VERSION from the dxmt URL with the same regex; the
    # parse here is its fallback and the only source for DXVK.
    renderers = [bundled_renderer(engine_root, env, "dxmt", env.get("OSS_DXMT_VERSION") or parsed.get("dxmt"),
                                  {"macdrvExports": True, "dllPathPrepend": True})]
    if b("OSS_HAS_DXVK"):
        renderers.append(bundled_renderer(engine_root, env, "dxvk", parsed.get("dxvk-macos"),
                                          {"dllPathPrepend": True}))

    # GStreamer rows only: every dylib/plugin/.so resolves through its own @loader_path/@rpath
    # set (REA L-12; gates rpath_self_contained + dlopen), so no DYLD_FALLBACK_LIBRARY_PATH —
    # CrossOver never sets DYLD_* and a hardened-runtime loader ignores them (L-54, L-73).
    base_env = {
        "GST_PLUGIN_SYSTEM_PATH": "${engine}/wine/lib/gstreamer-1.0",
        "GST_REGISTRY": "${engine}/gst-registry-x86_64.bin",
    }
    if b("OSS_HAS_SCANNER"):
        base_env["GST_PLUGIN_SCANNER"] = "${engine}/wine/libexec/gstreamer-1.0/gst-plugin-scanner"

    tarball = env.get("OSS_TARBALL") or os.path.join(os.path.dirname(engine_root), env["OSS_ID"] + ".tar.xz")
    overlay_floor = env.get("OSS_OVERLAY_MIN_MACOS") or None
    closure_floor = env.get("OSS_CLOSURE_MIN_MACOS") or None
    closure_above = int(env.get("OSS_CLOSURE_ABOVE", "0") or 0)
    revision = env["OSS_VERSION"].rsplit("-r", 1)[-1]

    return {
        "schema": "ossover.engine-manifest/1",
        "id": env["OSS_ID"],
        "displayName": "ossover Wine %s (CrossOver %s sources) r%s" % (env["OSS_WINE_VERSION"], env["OSS_CX_VERSION"], revision),
        "version": env["OSS_VERSION"],
        "wineVersion": env["OSS_WINE_VERSION"],
        "wineVersionString": env.get("OSS_WINE_VERSION_STRING") or None,
        "arch": "x86_64",
        "minMacOS": env["OSS_MIN_MACOS"],
        "requires": ["rosetta2"],
        # The tarball is `<id>/...`, so strip 1 into "." lands wine/ and overlays/ at the engine
        # root (ExtractSpec). sha256 stays TBD until package.sh has hashed the tarball.
        "source": {
            "url": pathlib.Path(tarball).resolve().as_uri(),
            "sha256": "TBD",
            "license": "LGPL-2.1-or-later (Wine; bundled components listed under components[])",
            "extract": {"strip": 1, "into": "."},
        },
        "paths": {
            "wine": "wine/bin/wine",
            "wineserver": "wine/bin/wineserver",
            "libWine": "wine/lib/wine",
        },
        "baseEnv": base_env,
        "capabilities": {
            "msync": b("OSS_CAP_MSYNC"),
            "esync": b("OSS_CAP_ESYNC"),
            "wow64": b("OSS_CAP_WOW64"),
            "macdrvExports": b("OSS_CAP_MACDRV"),
            "dllPathPrepend": b("OSS_CAP_PREPEND"),
            "d3dmetalHost": b("OSS_CAP_D3DMETAL"),
        },
        "bundledRenderers": renderers,
        "notes": [
            "Built by engine/build.sh + engine/package.sh from CodeWeavers' CrossOver %s LGPL sources (Wine %s) with engine/patches/*; manifest written by engine/manifest.py."
            % (env["OSS_CX_VERSION"], env["OSS_WINE_VERSION"]),
            "Keys outside the EngineManifest model (components, build, licenses, bundledRenderers[].requires/minMacOS) are the packaging record; ossover drops them when it re-saves the manifest at install.",
            "minMacOS is max(toolchain deployment target %s, overlay floor %s): DXMT's winemetal.so and GPTK's libd3dshared/D3DMetal are minos 14.0 (REA L-62)."
            % (env.get("OSS_DEPLOYMENT_TARGET", "?"), overlay_floor or "none"),
            "capabilities are measured on the tree (strings/nm), not assumed; esync is false because the CrossOver tree does not compile it in (REA L-32).",
        ] + ([
            "minMacOS was raised to %s, the measured floor of the bundled closure: %d Mach-O(s) (MacPorts binary archives, minos = the builder's macOS) are above the toolchain deployment target %s. Rebuild the ports from source (macports.conf macosx_deployment_target) to lower it."
            % (closure_floor, closure_above, env.get("OSS_DEPLOYMENT_TARGET", "?"))
        ] if closure_above else []),
        "addons": {"wineMono": env.get("OSS_MONO_VERSION"), "wineGecko": env.get("OSS_GECKO_VERSION")},
        "components": components,
        "build": {
            "date": env.get("OSS_BUILD_DATE"),
            "hostMacOS": env.get("OSS_HOST_OS"),
            "sdk": env.get("OSS_SDK"),
            "deploymentTarget": env.get("OSS_DEPLOYMENT_TARGET") or env["OSS_MIN_MACOS"],
            "overlayMinMacOS": overlay_floor,
            "closureMinMacOS": closure_floor,
            "closureAboveDeploymentTarget": closure_above,
            "clang": env.get("OSS_CLANG"),
            "mingw": env.get("OSS_MINGW"),
            "patches": env.get("OSS_PATCHES", "").split(),
            "patchesExpected": env.get("OSS_PATCH_LIST", "").split(),
            "inputsSha256": env.get("OSS_INPUTS_SHA"),
            "installStamp": env.get("OSS_STAMP"),
            "gstreamerPlugins": int(env.get("OSS_GST_COUNT", "0") or 0),
            "winemetalBuiltin": b("OSS_WINEMETAL_BUILTIN"),
            "recipe": "engine/build.sh + engine/package.sh (ossover)",
        },
        "licenses": {
            "wine": "LGPL-2.1-or-later (CrossOver sources; see NOTICE.md)",
            "note": "D3DMetal is never bundled; a user imports Apple's GPTK with `ossover renderer import-gptk`",
        },
    }


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: manifest.py <inputs.json> <engine-dir>/manifest.json (OSS_* in the environment)\n")
        return 2
    inputs_path, out_path = argv[1:3]
    with open(inputs_path) as f:
        inputs = json.load(f)
    engine_root = os.path.dirname(os.path.abspath(out_path))
    manifest = build_manifest(inputs, os.environ, engine_root)
    with open(out_path, "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("manifest.json written (%d components, %d renderers, minMacOS %s)"
          % (len(manifest["components"]), len(manifest["bundledRenderers"]), manifest["minMacOS"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

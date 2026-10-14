# SPDX-License-Identifier: GPL-3.0-or-later
"""ossover catalog check: engines/*.json, renderers/*.json, recipes/*.json.

Standard library only (Python 3.9+). Run from the checkout:

    python3 -I .github/scripts/catalog_check.py .

Checks syntax plus the shape OssoverKit decodes (ids, pinned sources, capability
set, renderer layouts, recipe steps against recipes/_schema.json). Exits 1 on any
problem. Other JSON files (engine/inputs.json, test fixtures) are parse-checked only.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
HEX64 = re.compile(r"^[0-9a-f]{64}$")
DOTTED = re.compile(r"^[0-9]+(\.[0-9]+)+$")
ID_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")
OVERRIDE_RE = re.compile(r"^[^=]+=.*$")
CAPS = {"msync", "esync", "wow64", "macdrvExports", "dllPathPrepend", "d3dmetalHost"}
RENDERER_KINDS = {"dxmt", "dxvk", "d3dmetal", "wined3d"}
LAYOUT_KEYS = {"unix", "pe", "pe32"}
problems = []
unpinned = []


def rel(path):
    return str(path.relative_to(ROOT))


def fail(path, msg):
    problems.append("%s: %s" % (rel(path), msg))


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        fail(path, "not valid JSON: %s" % exc)
        return None


def is_relative(p):
    return isinstance(p, str) and bool(p) and not p.startswith("/") and ".." not in p.split("/")


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def check_source(path, src):
    if not isinstance(src, dict):
        fail(path, "source must be an object")
        return
    for key in ("url", "sha256", "license", "extract"):
        if key not in src:
            fail(path, "source.%s missing" % key)
    url = str(src.get("url", ""))
    if not (url.startswith("https://") or url.startswith("file://")):
        fail(path, "source.url must be https:// or file://, got %r" % url)
    lowered = url.lower()
    if "d3dmetal" in lowered or "gameportingtoolkit" in lowered or "game-porting" in lowered:
        fail(path, "source.url looks like Apple's D3DMetal/GPTK, which ossover never downloads")
    sha = src.get("sha256")
    if sha == "TBD":
        unpinned.append(rel(path))
    elif not (isinstance(sha, str) and HEX64.match(sha)):
        fail(path, "source.sha256 must be 64 lowercase hex characters or the literal TBD")
    ext = src.get("extract")
    if not (isinstance(ext, dict) and is_int(ext.get("strip")) and ext["strip"] >= 0
            and is_relative(ext.get("into"))):
        fail(path, "source.extract must be {strip: int >= 0, into: relative path}")
    if "size" in src and not (is_int(src["size"]) and src["size"] > 0):
        fail(path, "source.size must be a positive integer")


def check_layout(path, layout, where):
    if not (isinstance(layout, dict) and set(layout) == LAYOUT_KEYS):
        fail(path, "%s.layout must have exactly the keys unix, pe, pe32" % where)
        return
    for key, names in layout.items():
        if not (isinstance(names, list)
                and all(isinstance(n, str) and n and "/" not in n for n in names)):
            fail(path, "%s.layout.%s must be a list of file names" % (where, key))


def check_engine(path, doc):
    for key in ("schema", "id", "displayName", "version", "wineVersion", "arch", "minMacOS",
                "source", "paths", "capabilities", "bundledRenderers"):
        if key not in doc:
            fail(path, "missing %s" % key)
    if doc.get("schema") != "ossover.engine-manifest/1":
        fail(path, "schema must be ossover.engine-manifest/1")
    if doc.get("id") != path.stem:
        fail(path, "id %r must equal the file name %r" % (doc.get("id"), path.stem))
    if doc.get("arch") not in ("x86_64", "arm64"):
        fail(path, "arch must be x86_64 or arm64")
    for key, example in (("minMacOS", "15.0"), ("wineVersion", "11.16")):
        if not (isinstance(doc.get(key), str) and DOTTED.match(doc[key])):
            fail(path, "%s must look like %s" % (key, example))
    check_source(path, doc.get("source"))
    paths = doc.get("paths")
    if not (isinstance(paths, dict) and set(paths) == {"wine", "wineserver", "libWine"}
            and all(is_relative(v) for v in paths.values())):
        fail(path, "paths must have exactly wine, wineserver and libWine as relative paths")
    caps = doc.get("capabilities")
    if not (isinstance(caps, dict) and set(caps) == CAPS
            and all(isinstance(v, bool) for v in caps.values())):
        fail(path, "capabilities must be exactly the booleans %s" % ", ".join(sorted(CAPS)))
    env = doc.get("baseEnv", {})
    if not (isinstance(env, dict)
            and all(isinstance(k, str) and isinstance(v, str) for k, v in env.items())):
        fail(path, "baseEnv must map strings to strings")
    elif any(k.startswith("DYLD_") for k in env):
        fail(path, "baseEnv must not set DYLD_* (docs/rea/decisions.md 1)")
    requires = doc.get("requires", [])
    if not (isinstance(requires, list) and all(isinstance(r, str) for r in requires)):
        fail(path, "requires must be a list of strings")
    bundled = doc.get("bundledRenderers")
    if not isinstance(bundled, list):
        fail(path, "bundledRenderers must be a list")
        return
    for i, entry in enumerate(bundled):
        where = "bundledRenderers[%d]" % i
        if not isinstance(entry, dict):
            fail(path, where + " must be an object")
            continue
        if entry.get("kind") not in RENDERER_KINDS:
            fail(path, where + ".kind must be one of " + ", ".join(sorted(RENDERER_KINDS)))
        if not isinstance(entry.get("version"), str):
            fail(path, where + ".version must be a string")
        if not is_relative(entry.get("path")):
            fail(path, where + ".path must be a relative path")
        if not isinstance(entry.get("builtinMarked"), bool):
            fail(path, where + ".builtinMarked must be a boolean")
        check_layout(path, entry.get("layout"), where)


def check_renderer(path, doc):
    for key in ("schema", "id", "kind", "version", "source", "builtinMarked", "layout"):
        if key not in doc:
            fail(path, "missing %s" % key)
    if doc.get("schema") != "ossover.renderer-pack/1":
        fail(path, "schema must be ossover.renderer-pack/1")
    if doc.get("id") != path.stem:
        fail(path, "id %r must equal the file name %r" % (doc.get("id"), path.stem))
    if doc.get("kind") not in ("dxmt", "dxvk"):
        fail(path, "kind must be dxmt or dxvk (D3DMetal is imported by the user, never downloaded)")
    if not isinstance(doc.get("version"), str):
        fail(path, "version must be a string")
    check_source(path, doc.get("source"))
    if not isinstance(doc.get("builtinMarked"), bool):
        fail(path, "builtinMarked must be a boolean")
    check_layout(path, doc.get("layout"), "pack")
    overrides = doc.get("overrides", [])
    if not (isinstance(overrides, list)
            and all(isinstance(o, str) and OVERRIDE_RE.match(o) for o in overrides)):
        fail(path, "overrides must be a list of WINEDLLOVERRIDES fragments such as dxgi,d3d11=n,b")
    if not isinstance(doc.get("requires", {}), dict):
        fail(path, "requires must be an object")


def recipe_rules(schema_path):
    schema = load(schema_path)
    if not isinstance(schema, dict) or schema.get("$schema") != "http://json-schema.org/draft-07/schema#":
        fail(schema_path, "expected a draft-07 JSON Schema")
        return None
    try:
        steps = {}
        for alt in schema["definitions"]["step"]["oneOf"]:
            steps[alt["properties"]["type"]["const"]] = (set(alt["properties"]), set(alt["required"]))
        report = schema["definitions"]["report"]
        return {
            "top": set(schema["properties"]),
            "required": set(schema["required"]),
            "steps": steps,
            "when": set(schema["definitions"]["when"]["properties"]),
            "status": set(schema["definitions"]["status"]["enum"]),
            "report": (set(report["properties"]), set(report["required"])),
        }
    except (KeyError, TypeError) as exc:
        fail(schema_path, "schema shape changed; update this checker (%s)" % exc)
        return None


def check_recipe(path, doc, rules):
    for key in rules["required"]:
        if key not in doc:
            fail(path, "missing %s" % key)
    extra = set(doc) - rules["top"]
    if extra:
        fail(path, "unknown top-level keys %s" % sorted(extra))
    if doc.get("schema") != "ossover.recipe/1":
        fail(path, "schema must be ossover.recipe/1")
    if not (isinstance(doc.get("id"), str) and ID_RE.match(doc["id"])):
        fail(path, "id must match %s" % ID_RE.pattern)
    if doc.get("license", "CC0-1.0") != "CC0-1.0":
        fail(path, "recipes are CC0-1.0, got license %r" % doc.get("license"))
    if "status" in doc and doc["status"] not in rules["status"]:
        fail(path, "status must be one of %s" % ", ".join(sorted(rules["status"])))
    steps = doc.get("steps")
    if not isinstance(steps, list):
        fail(path, "steps must be a list")
        steps = []
    for i, step in enumerate(steps):
        where = "steps[%d]" % i
        if not isinstance(step, dict):
            fail(path, where + " must be an object")
            continue
        kind = step.get("type")
        if kind not in rules["steps"]:
            fail(path, "%s.type %r is not in recipes/_schema.json (%s)"
                 % (where, kind, ", ".join(sorted(rules["steps"]))))
            continue
        allowed, required = rules["steps"][kind]
        extra = set(step) - allowed
        if extra:
            fail(path, "%s (%s) has unknown keys %s" % (where, kind, sorted(extra)))
        missing = required - set(step)
        if missing:
            fail(path, "%s (%s) misses %s" % (where, kind, sorted(missing)))
        when = step.get("when")
        if when is not None and not (isinstance(when, dict) and when and set(when) <= rules["when"]):
            fail(path, "%s.when must be a non-empty object with keys from %s"
                 % (where, ", ".join(sorted(rules["when"]))))
    if "${gameDir}" in json.dumps(steps) and not doc.get("gameDir"):
        fail(path, "a step uses ${gameDir} but gameDir is not set")
    reports = doc.get("reports", [])
    if not isinstance(reports, list):
        fail(path, "reports must be a list")
    else:
        props, required = rules["report"]
        for i, rep in enumerate(reports):
            if not (isinstance(rep, dict) and required <= set(rep) and set(rep) <= props
                    and rep.get("status") in rules["status"]):
                fail(path, "reports[%d] needs status and date and only schema keys" % i)


def main():
    counts = {"engines": 0, "renderers": 0, "recipes": 0, "other": 0}
    for path in sorted((ROOT / "engines").glob("*.json")):
        counts["engines"] += 1
        doc = load(path)
        if isinstance(doc, dict):
            check_engine(path, doc)
        elif doc is not None:
            fail(path, "top level must be an object")
    for path in sorted((ROOT / "renderers").glob("*.json")):
        counts["renderers"] += 1
        doc = load(path)
        if isinstance(doc, dict):
            check_renderer(path, doc)
        elif doc is not None:
            fail(path, "top level must be an object")
    rules = recipe_rules(ROOT / "recipes" / "_schema.json")
    for path in sorted((ROOT / "recipes").glob("*.json")):
        if path.name.startswith("_"):
            continue
        counts["recipes"] += 1
        doc = load(path)
        if isinstance(doc, dict):
            if rules is not None:
                check_recipe(path, doc, rules)
        elif doc is not None:
            fail(path, "top level must be an object")
    extras = [ROOT / "engine" / "inputs.json"] + sorted((ROOT / "Tests" / "Fixtures").rglob("*.json"))
    for path in extras:
        if path.is_file():
            counts["other"] += 1
            load(path)
    print("catalog check: %(engines)d engines, %(renderers)d renderers, %(recipes)d recipes checked; "
          "%(other)d other JSON files parsed" % counts)
    if unpinned:
        print("note: unpinned (TBD) sources, which ossover refuses to install: " + ", ".join(unpinned))
    for problem in problems:
        print("FAIL " + problem)
    if problems:
        print("catalog check: %d problem(s)" % len(problems))
        sys.exit(1)
    print("catalog check: OK")


main()

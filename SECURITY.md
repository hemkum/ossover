# Security policy

ossover is pre-release software maintained by one person. This page says how to report a
vulnerability, and what ossover does that is security-relevant, so you can judge what counts.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository:

**https://github.com/hemkum/ossover/security/advisories/new**

Do not open a public issue for anything that could let an attacker run code, read files or
tamper with downloads on a user's Mac. Ordinary crashes and "game X does not start" belong in
the public issue tracker (there is an issue form for each).

Please include:

- the ossover version (`ossover --version`) or commit, your macOS version and chip;
- what the attacker needs: a crafted engine manifest? a malicious recipe? control of a
  download host? a program already running inside a bottle?
- steps to reproduce, and a fix if you have one.

You will get an acknowledgement within seven days and a fix, or a public advisory with a
workaround, as soon as one exists. There is no bug bounty.

## Supported versions

Only the `main` branch and the most recent release receive fixes. Before 1.0 nothing is
backported.

## What ossover does with other people's binaries

Read this before you report, and before you run it.

- **ossover downloads and executes third-party binaries.** Engines (Wine builds), renderer
  packs (DXMT, DXVK) and the vendored `winetricks` script come from the URL in their manifest
  (`engines/*.json`, `renderers/*.json`, `engine/inputs.json`,
  `scripts/vendor/winetricks.sha256`). Every download is verified against the pinned SHA-256
  **before** it is extracted, and a manifest whose `source.sha256` is still `TBD` is refused at
  install time. After extraction the `com.apple.quarantine` attribute is removed from the
  engine tree (`xattr -drs`, symlinks are not followed) and the ad-hoc-signed x86_64 binaries
  run under Rosetta 2. Each installed engine carries a `SHA256SUMS` that
  `ossover engine verify` re-checks on demand.
- **Apple's D3DMetal / Game Porting Toolkit is never downloaded, bundled or redistributed by
  ossover.** `ossover renderer import-gptk` reads a dmg you obtained from Apple yourself; the
  import is recorded with the dmg's hash, and `ossover renderer accept` records that you
  accepted Apple's licence. A manifest, recipe or pull request that adds a download URL or a
  copy of D3DMetal is a bug, not a feature.
- **Steam credentials are never handled.** `ossover steam fetch` runs `steamcmd` (or
  DepotDownloader) in your own terminal; you type the password and the Steam Guard code at
  the tool's prompt. ossover has no password flag, environment variable or config key, and
  never will.
- **Recipes and manifests are data, but powerful data.** A recipe writes registry keys,
  files, DLL overrides and environment variables into a bottle; an engine manifest decides
  what gets executed. Only apply recipes and install manifests you have read, from this
  repository or a source you trust.
- **Logs** under `$OSSOVER_HOME` (default `~/Library/Application Support/ossover`) contain
  the full launch environment and paths that include your user name. Check them before
  attaching them to an issue.

## In scope

- Bypassing SHA-256 verification, or getting an unpinned (`TBD`) source installed.
- Path traversal during archive extraction, or a recipe `file` / `copy` / `ini` step writing
  outside the bottle it was applied to.
- Command, path or environment injection through manifest, recipe or bottle-settings values.
- ossover touching files outside `$OSSOVER_HOME` and the repository checkout without being
  told to, or anything that escalates privileges.
- The release or CI workflows producing an artifact that does not match the source.

## Out of scope

- Vulnerabilities in Wine, DXMT, DXVK, MoltenVK, GStreamer, winetricks, steamcmd or the
  games themselves: report those upstream (links in `NOTICE.md`). Do tell us if ossover should
  pin a fixed version sooner.
- Anything that requires an already-compromised Mac, or a user who deliberately runs an
  untrusted recipe or manifest.
- Windows programs doing what Windows programs do inside a bottle. Wine is not a sandbox and
  ossover does not claim to be one: a Wine prefix maps your whole file system as drive `Z:`.

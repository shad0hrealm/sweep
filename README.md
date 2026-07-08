# Sweep

A native macOS utility covering the core jobs of CleanMyMac — cleanup, large-file
discovery, performance visibility, and security checks — with a plain, native
SwiftUI interface. Nothing is ever removed without an explicit confirmation, and
almost everything goes to the Trash rather than being deleted outright.

## Installing

Grab `Sweep-x.y.zip` from the
[latest release](https://github.com/shad0hrealm/sweep/releases/latest), unzip,
and drop `Sweep.app` into `/Applications`.

The app is ad-hoc signed (not notarised). If it arrived with a quarantine flag
(AirDrop, browser download), clear it once:

```sh
xattr -dr com.apple.quarantine /Applications/Sweep.app
```

**Updates are then automatic**: with the scheduled scan enabled, Sweep checks
this repo's releases and installs new versions itself (Settings → Updates to
turn that off or make it manual). Self-installed updates carry no quarantine
flag, so this is a one-time step.

## Modules

**Dashboard** — storage/memory gauges, security posture at a glance, shortcuts
into the other modules.

**Cleanup** — scans and cleans, per category:
- *User Caches* (`~/Library/Caches`, with iCloud/HomeKit caches excluded)
- *Logs & Diagnostics* (`~/Library/Logs`)
- *Trash* (the one category that deletes permanently — clearly labelled)
- *Developer Junk* (Xcode DerivedData & device support, simulator caches,
  Homebrew/npm/pnpm/Go build caches)
- *Downloads* (largest first, with dates — review before cleaning)

Nothing is pre-selected; you tick what goes. Cleaned items are moved to the
Trash so mistakes are recoverable.

**Large & Old Files** — walks a folder of your choice (home by default, user
Library and Trash skipped) for files above a size threshold, showing when each
was last opened. Sort by size or by staleness.

**Uninstaller** — lists your applications with true on-disk size and Spotlight's
last-used date. Selecting an app hunts down its leftovers — Application Support,
caches, preferences, containers, saved state, cookies, launch agents — and
moves the lot to the Trash. Warns if the app is still running.

Beyond exact name/bundle-ID matches, it also finds:

- *Vendor files* — folders keyed by publisher rather than app (Chrome's data
  lives in `Application Support/Google`). If another installed app shares the
  vendor, the item is flagged "shared with …" and deselected by default.
- *System-domain files* — privileged helpers, launch daemons and vendor folders
  in `/Library`. These are **reveal-only by design**: Sweep never deletes
  anything requiring admin rights; it shows you where they are and you remove
  them in Finder.
- *Installer receipts* — locations recorded by `pkgutil` when the app's `.pkg`
  installer ran, catching files outside the usual folders. Also reveal-only.

**Orphaned Leftovers** (toolbar in Uninstaller) — scans your user Library for
reverse-domain-named files matching no installed or running app: the remnants
of software you've already deleted. Launch agents whose executables still exist
are treated as active and skipped. Nothing is pre-selected; attribution is
heuristic, so review before cleaning.

**Performance** — memory/disk/CPU-load cards, top processes by CPU, and every
launch agent & daemon on the system with one-click reveal; user-level agents can
be removed (to Trash). Shortcut into System Settings' Login Items pane.

**Security** — checks FileVault, Gatekeeper, System Integrity Protection, the
application firewall, Time Machine, and automatic update checking, with plain
advice for anything off. Also reviews launch agents/daemons for malware-ish
traits: Apple-style identifiers outside `/System`, executables in temp
directories, and orphaned agents whose binaries are gone.

**Menu bar** — disk, memory and junk-found at a glance, with scan/review
shortcuts. Toggle it in Settings.

**Scheduled scans** (Settings) — a launchd agent runs `Sweep --background-scan`
daily or weekly. Nothing is ever cleaned automatically. If you move Sweep.app,
toggle the schedule off and on so the agent points at the new location.

Each run measures junk, checks free disk space, and diffs the system against
the previous run: new launch agents/daemons (with the suspicion heuristics
applied) and newly-appeared security warnings (ignored checks stay silent).
A notification fires only when something is actionable — quiet runs just log.

**Activity & Recommendations** (Dashboard) — a persistent log shared by the app
and the scheduled scan: cleanups you performed, scan results, and anything that
changed while you were away. The menu-bar widget shows the latest
recommendation. Events live in `~/Library/Application Support/Sweep/`.

## Building

```sh
./build-app.sh        # builds with SwiftPM and assembles build/Sweep.app
open build/Sweep.app
```

Requires only the Xcode Command Line Tools (macOS 14+). To regenerate the icon:
`swift scripts/make-icon.swift`.

To install: `cp -R build/Sweep.app /Applications/`.

## Permissions

macOS will prompt when Sweep first touches protected folders (Downloads, etc.).
For complete results — especially Time Machine status and some caches — grant
Sweep **Full Disk Access** in System Settings → Privacy & Security.

macOS keys these grants on the app's *code-signing identity*, not its name.
Release builds are signed with a stable self-signed certificate ("Sweep
Signing"), so grants survive updates. If you build from source without that
certificate in your keychain, the build falls back to ad-hoc signing and
**every rebuild re-prompts** — create your own identity and put its name in
`build-app.sh` to avoid that.

## Honest limitations

- The app is ad-hoc signed: distribution to other Macs would need a Developer
  ID and notarisation.
- Trash emptying and launch-agent removal only cover your user; system-level
  daemons are listed read-only (removing those needs `sudo` and is deliberately
  out of scope).
- "Last opened" dates rely on filesystem access times, which macOS doesn't
  always update (e.g. on APFS with relatime-like behaviour) — treat them as a
  hint, not gospel.
- Scheduled-scan notifications require granting notification permission (Sweep
  asks when you enable the schedule).

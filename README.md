# Sweep

A native macOS utility covering the core jobs of CleanMyMac — cleanup, large-file
discovery, performance visibility, and security checks — with a plain, native
SwiftUI interface. Nothing is ever removed without an explicit confirmation, and
almost everything goes to the Trash rather than being deleted outright.

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

**Performance** — memory/disk/CPU-load cards, top processes by CPU, and every
launch agent & daemon on the system with one-click reveal; user-level agents can
be removed (to Trash). Shortcut into System Settings' Login Items pane.

**Security** — checks FileVault, Gatekeeper, System Integrity Protection, the
application firewall, Time Machine, and automatic update checking, with plain
advice for anything off. Also reviews launch agents/daemons for malware-ish
traits: Apple-style identifiers outside `/System`, executables in temp
directories, and orphaned agents whose binaries are gone.

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
Sweep **Full Disk Access** in System Settings → Privacy & Security. The build
script ad-hoc signs the bundle so that grant survives rebuilds.

## Honest limitations

- The app is ad-hoc signed: distribution to other Macs would need a Developer
  ID and notarisation.
- Trash emptying and launch-agent removal only cover your user; system-level
  daemons are listed read-only (removing those needs `sudo` and is deliberately
  out of scope).
- "Last opened" dates rely on filesystem access times, which macOS doesn't
  always update (e.g. on APFS with relatime-like behaviour) — treat them as a
  hint, not gospel.
- No always-on background monitoring or menu-bar widget (yet).

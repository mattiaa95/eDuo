# eDuo

A retro game emulator for iPhone and iPad, built on the
[melonDS](https://github.com/melonDS-emu/melonDS) emulation core.

This repository contains the complete source code of the eDuo app as it is
built and distributed. It is published under the **GNU GPLv3** (see
`LICENSE`) — the same license as melonDS — so that anyone who receives the
app can study, build and modify exactly what runs on their device.

## Built with AI assistance

This project was written with heavy use of AI coding assistants (Anthropic's
Claude, driven from Claude Code). A large share of the Swift and
Objective-C++ in `Targets/` was drafted by a model and then read, corrected,
tested on real devices and shipped by a human — but it would be dishonest to
present it as hand-typed work, so it is said here plainly rather than left
for you to guess from the commit log.

What that does **not** cover: the emulation core. `Vendor/melonDS` is
unmodified upstream melonDS, written by Arisotura and the melonDS team, and
no AI touched it.

## What eDuo adds on top of melonDS

- A native SwiftUI/UIKit iOS frontend: game library (with each game's
  real banner icon), dual-screen layouts, an on-screen controller with a
  visual layout/style editor, pause menu, save states and auto-save.
- Real microphone input (blow/speak) resampled to the emulated mic rate.
- External display / AirPlay support (TV shows the top screen, the device
  becomes the touch screen + controls).
- Game Controller framework + hardware keyboard support with remapping.
- `.zip` / `.7z` / `.gz` archive import, cheat codes, display filters,
  ReplayKit clip recording, per-game profiles.
- A layout that follows the window rather than the device: it reflows on
  iPad Split View, Stage Manager and continuously resizable windows.

## Credits

- **[melonDS](https://melonds.org)** — © Arisotura and the melonDS team,
  GPLv3. eDuo uses the core unmodified (see `Vendor/melonDS`, pinned as a
  submodule to the upstream commit each release builds against).
- **FreeBIOS** — the built-in BIOS replacement inside melonDS, © Gilead
  Kutnick (BSD). No proprietary console BIOS, firmware or keys are included anywhere
  in this repository or in the shipped app.
- **[teakra](https://github.com/wwylele/teakra)** — DSi DSP emulation, MIT.
- **LZMA SDK** (7z extraction) — Igor Pavlov, public domain.
- **minizip** (zip extraction) — Gilles Vollant, zlib license.

See `THIRD_PARTY.md` for the full component inventory — including the
libraries melonDS itself vendors (blip-buf, xxHash, FatFs, tiny-AES-c,
SHA-1) — and `Targets/INDS/Resources/Legal/NOTICES.txt` for their verbatim
license texts, which also ship inside the app (Settings › About › Licenses).

## Building

See `BUILDING.md`. Short version: build the melonDS static libraries with
CMake (exact flags documented), then open `eNDS.xcworkspace` and build the
`eNDS` scheme. No account-specific secrets are needed to build; signing uses
your own team.

## Releases

Every build of eDuo that leaves this machine gets a tag here — `v1.0-b29`,
`v1.0-b30`, … — and each tag is the complete corresponding source for that
exact binary. The current one has release notes on the [releases
page](https://github.com/mattiaa95/eDuo/releases). `main` may carry later
work (comment translations, docs) that is not in any binary yet; when in
doubt, build a tag.

What ships is what you see here: no ads, no analytics and no tracking SDKs
of any kind. The app's privacy policy is at
[mattials.com/privacy](https://mattials.com/privacy/).

## What the App Store build charges for

Said plainly, because reading it in the source is not the same as being
told: the App Store build has a paid tier ("PRO"), sold as a weekly or
yearly auto-renewing subscription or as a one-time lifetime unlock. It
gates save-state slots 2–4, the scanlines display filter and custom
background images — nothing else. Emulation, ROM library, controller and
layout editing, save slot 1, auto-save, cheats, multiplayer, external
display and every other feature are free and ungated, and the first 48
hours after install unlock the gated extras too
(`INDSHoneymoon.swift`).

The gates are ordinary `if` statements in this repository
(`EntitlementManager`, `ProGateAlert`) and the GPLv3 gives you the right
to build this source yourself with them removed. That is by design: the
subscription funds the work for people who would rather pay than compile,
it is not a lock.

## Legal

- eDuo is an unofficial project. It is **not** affiliated with, or endorsed
  by, the melonDS team, and **not** affiliated with any game console
  manufacturer. All related console names are trademarks of their respective
  owners and are used here only to describe compatibility.
- **On the `INDS` prefix you will see everywhere in this source**: the
  project was started under the working name *iNDS* and the class prefix,
  folder names, bundle id (`com.mls.inds`) and StoreKit product ids were
  never renamed when the app became eDuo. It is a leftover, and it is the
  obvious thing to be suspicious about, so: eDuo shares no code and no
  authorship with the earlier nds4ios/iNDS project for iOS. That one wrapped
  DeSmuME; this one is a SwiftUI/UIKit frontend over melonDS, and every line
  of it is in this repository for comparison.
- Parts of the on-screen controller, layout editor and purchase UI were
  ported from **iGBA**, the author's other emulator, and the
  comment headers of those files say so. That code is the author's own and
  is published here under the GPLv3.
- eDuo does not include any games and does not link to ROM sites. Play only
  backups of cartridges you legally own.

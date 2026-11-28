# Vitrine Apple Music Queue Parity: Memory & Progress Log

## Active Scope & Objectives
Mimic the exact UI and behavior of Apple Music's queue feature in Vitrine on `feat/apple-music-queue` and downstream `main`.
Target base: Clean `upstream/main` + branch features.
Target Platform: iOS 16.1+ to iOS 26+; Spotify 9.1.78 - 9.1.90 (Base: 9.1.90).
Special constraint: Keep Spotify's checkmark/plus UI icon at Apple Music's star size for liking songs.

---

## What Was Broken & Visual/Behavioral Discrepancies

### 1. Long-Press Preview Card Visual Discrepancy
- **Symptoms**:
  - The preview card shown above the queue context menu was narrow and cramped (`cardW = 250.0`, `cardH = 86.0`), misaligned with the wider system context menu below it.
  - The album artwork was tiny (`56x56 pt`, corner radius `8.0 pt`).
  - The card background had a harsh greenish tint (`[UIColor colorWithRed:0.10 green:0.16 blue:0.15 alpha:0.96]`) rather than Apple's native dark frosted glass / thick material.
  - Fonts used basic system fonts at small sizes (`15.0 pt` title, `13.5 pt` artist, `13.0 pt` album).
  - When San Francisco is selected, Apple Music uses **SF Pro Display** (specifically `.SFUIDisplay-Bold` / `.SFUIDisplay-Semibold`) for the prominent title, whereas Vitrine defaulted to SF Text.
  - Title was forced to a single truncated line rather than supporting up to 2 wrapped lines with an inline explicit badge.
  - The right chevron was awkwardly sized and placed.
- **Apple Music Ground Truth & Fix Applied**:
  - Implemented `SGRQueuePreviewViewController` matching Apple Music's exact 1:1 geometry.
  - Card Dimensions: `cardW = MIN(342.0, screenW - 32.0)`, `cardH = 124.0`, corner radius `22.0 pt` continuous curve, dark thick material blur (`UIBlurEffectStyleSystemThickMaterialDark`) over deep `#1c1c1e` base.
  - Large square artwork: `92.0 x 92.0 pt` with `14.0 pt` continuous corner curve, centered with `16.0 pt` margins.
  - Typography: `SGRQueueDisplayFont(18.0, UIFontWeightBold)` using SF Pro Display for San Francisco while dynamically adapting to user font setting (`SGAppFontChosen()`).
  - Title supports 2 wrapped lines with `NSTextAttachment` explicit badge `[E]` (`SGRExplicitBadgeImageNP()`).
  - Artist: `14.5 pt` (`alpha: 0.62`); Album: `13.5 pt` (`alpha: 0.42`).
  - Trailing chevron: `15.0 pt` Semibold `chevron.right` pinned to right margin (`16.0 pt`), vertically centered.

### 2. Tapping Card Fails to Minimize Player and Open Album in Focus
- **Symptoms**:
  - Tapping on the preview card did nothing; the context menu either stayed open or ignored the tap.
  - The player did not minimize to the mini player.
  - The app did not navigate to the album, and did not focus/scroll the track in the main navigator.
- **Root Cause & Fix Applied**:
  - `SGRQueueRowView` and `SGRQueueView` implemented `-contextMenuInteraction:willPerformPreviewActionForMenuWithAnimator:`.
  - Added tap gesture handler in `SGRQueuePreviewViewController` as fallback to trigger the commit action if animator is bypassed.
  - Added `SGRSetAlbumTrackToFocus(trackURI, item.title)` to register the target track to focus.
  - Inside the commit block:
    - Minimized the player via `SGRPlayerMinimizeIfOpen()`.
    - Navigated to the album URI via `SGOpenSpotifyURI([NSURL URLWithString:albumURI])` (falling back to track URI).
  - In `AlbumRows.x`:
    - Intercepted `applyRow(cell, page)` to locate the cell matching `SGRFocusTrackTitle()`.
    - Automatically centered the track row in the collection view (`[scroller setContentOffset:... animated:YES]`).
    - Flashed a subtle 0.85s selection highlight pulse (`[UIColor colorWithWhite:1.0 alpha:0.18]`) matching Apple Music.
    - Cleared the focus target via `SGRClearAlbumTrackFocus()` to ensure single execution.

---

## Progress Log
- [x] Initial build verification on `main` and branch sync.
- [x] Fix Discrepancy 1: Long-press preview card visual parity & SF Pro Display font.
- [x] Fix Discrepancy 2: Preview action commit, player minimization, and album track focus.
- [x] Bug check passes (Pass 1 & 2) and deslopification passes (Pass 1 & 2).
- [x] Layer rule verification (`check-layers.sh` -> 0 violations).
- [ ] Safety commit & push for Discrepancy 1 & 2.
- [ ] Merge into `main` and push `main`.
- [ ] Dispatch `build-ipa.yml` build in artifacts mode.

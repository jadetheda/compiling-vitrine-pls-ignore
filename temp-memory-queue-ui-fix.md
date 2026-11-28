# Vitrine Apple Music Queue Parity: Memory & Progress Log

## Active Scope & Objectives
Mimic the exact UI and behavior of Apple Music's queue feature in Vitrine on `feat/apple-music-queue` and downstream `main`.
Target base: Clean `upstream/main` + branch features.
Target Platform: iOS 16.1+ to iOS 26+; Spotify 9.1.78 - 9.1.90 (Base: 9.1.90).
Special constraint: Keep Spotify's checkmark/plus UI icon at Apple Music's star size for liking songs.

---

## What Was Broken & Visual/Behavioral Discrepancies

### 0. CI Build Failure on `21286d5` / `e78b6c4`
- **Root Cause**:
  - `SGRQueuePreviewViewController` `@interface` and `@implementation ... @end` were accidentally placed inside `@implementation SGRQueueView { ... }`, causing 16 clang errors (`missing '@end'`, `missing context for method declaration`, `-Wprotocol` errors on `SGRQueueView`).
  - `commitPreviewActionForItem:animator:` directly referenced `_activeContextURI`, which is an ivar of `SGRQueueSession` rather than `SGRQueueView`.
  - Protocol/method signatures used `nullable` in a non-`NS_ASSUME_NONNULL` file and left `interaction` unannotated for `-Wunused-parameter`.
- **Fix Applied**:
  - Moved `SGRQueuePreviewViewController` `@interface`/`@implementation` above `SGRQueueView`.
  - Exposed `@property (nonatomic, readonly) NSString *activeContextURI;` on `SGRQueueSession` and read `[SGRQueueSession shared].activeContextURI`.
  - Removed `nullable` annotations and marked unused parameters `__unused` for strict `-Werror` cleanliness.

### 1. Long-Press Preview Card Visual Discrepancy
- **Symptoms**:
  - Earlier build `21286d5` added `UIBlurEffectStyleSystemThickMaterialDark` over `#1A191B`, letting red background color bleed through instead of Apple Music's crisp solid `#1A191B` charcoal card.
  - Album label was single-line (`numberOfLines = 1`) instead of wrapping up to 2 lines like Apple Music (`"My Beautiful Dark\nTwisted Fantasy"`).
  - Text width extended slightly into the trailing chevron clearance zone, and `.SF UI Display` descriptor lookup could silently fall back to non-SF metrics on iOS 16+.
- **Fix Applied**:
  - Solid opaque `#1A191B` (`rgb(26, 25, 27)`) card background, continuous `22.0 pt` corners, `cardW = MIN(342.0, screenW - 32.0)`, dynamic `cardH = MAX(124.0, totalTextH + 28.0)`.
  - `92.0 x 92.0 pt` artwork (`cornerRadius = 12.0` continuous), vertically centered.
  - `SGRQueueDisplayFont`: verifies `SFUI` font name before accepting `.SFUIDisplay-*` and otherwise derives SF Pro Display via CoreText `kCTFontOpticalSizeAttribute` (`@28.0`) + `'opsz'` variation axis while preserving `'wght'` and falling back to `SGRQueueFont` when non-System fonts are chosen in Settings.
  - `titleLabel` (`numberOfLines = 2`, explicit `[E]` badge with thin space gap), `artistLabel` (`14.5 pt`, `0.58` alpha), `albumLabel` (`13.5 pt`, `0.44` alpha, `numberOfLines = 2`), vertically centered in card with clean 12pt clearance before trailing `chevron.right`.

### 2. Tapping Preview Card -> Minimize Player, Open Album, Focus Track
- **Symptoms**:
  - `SGRQueuePreviewViewController` attached a competing `UITapGestureRecognizer` that could steal touches from UIKit's `willPerformPreviewActionForMenuWithAnimator:` without setting `UIContextMenuInteractionCommitStyleDismiss`.
  - `AlbumRows.x` used `hasPrefix:` matching (falsely matching `"All of the Lights"` vs `"All of the Lights (Interlude)"`), didn't handle off-screen/below-the-fold album tracks, didn't retry if `contentSize` wasn't settled, and didn't trigger when the album page was already open behind the player.
- **Fix Applied**:
  - Removed competing `UITapGestureRecognizer` and set `animator.preferredCommitStyle = UIContextMenuInteractionCommitStyleDismiss` in both `SGRQueueRowView` and `SGRQueueView` commit handlers.
  - Posted `SGRAlbumTrackFocusRequestedNotification` on focus registration and after minimize/navigation delays (`0.18s`, `0.50s`).
  - `AlbumRows.x`: exact case-insensitive trimmed title match (`caseInsensitiveCompare: == NSOrderedSame`), full-width edge-to-edge translucent highlight pulse (`alpha 0.16 -> 0.0`), delayed layout-settle retry, and safe incremental scroll-scan for off-screen tracks.

---

## Progress Log
- [x] Fix CI build errors in `SGRQueueView.m` (`SGRQueuePreviewViewController` placement, `activeContextURI`, `-Werror` cleanliness).
- [x] Refine preview card visual parity (`#1A191B`, dynamic card height, 2-line album wrapping, SF Pro Display `'opsz'` fallback, chevron clearance).
- [x] Harden preview commit (`UIContextMenuInteractionCommitStyleDismiss`) and `AlbumRows.x` focus (exact title match, off-screen step scan, full-width highlight pulse, already-open album support).
- [x] Rename `memory.md` to `temp-memory-queue-ui-fix.md`.
- [x] Run `check-layers.sh` and syntax/balance verification, then safety commit & push `feat/apple-music-queue`.
- [x] Address Search Results + Autoplay OFF bug in `temp-memory-autoplay-queue-fix.md`.
- [x] Bug check passes (Pass 1 & 2) and deslopification passes (Pass 1 & 2) completed.

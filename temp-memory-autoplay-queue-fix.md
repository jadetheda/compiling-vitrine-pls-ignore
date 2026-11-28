# Autoplay OFF + Search Results Continue Playing Fix Log

## Issue Description
When the Autoplay pill toggle (`SGRKeyQueueAutoplay`) is OFF and the user taps a song in Spotify Search results, `Continue Playing` still appeared and got populated instead of remaining hidden / showing the empty-queue Autoplay prompt (`"To keep music playing, turn on ∞ AutoPlay."`).

## Root Causes Identified in `SGRQueueView.m`
1. **`effectiveContextURIForState:` fabricated an album context (`spotify:album:...`) for Search & single-track playback**:
   - When playing a song directly from Search results, Spotify often reports `state.contextURI` as `@""` or `spotify:track:<id>`.
   - `effectiveContextURIForState:` previously promoted `(!ctx.length || [ctx hasPrefix:@"spotify:track:"])` into `track.metadata[@"album_uri"]`.
   - That turned standalone search playback into `spotify:album:...`, causing `resolveContextIfSupported:` to fetch the entire album from `context-resolve/v1/` and populate `Continue Playing` (`"From <Album>"`) even with Autoplay OFF.
2. **`ingestPlayerState:` failed to clear previous context when transitioning to empty `ctxURI`**:
   - `BOOL contextChanged = (ctxURI.length > 0 && ![_activeContextURI isEqualToString:ctxURI]);` ignored transitions from an active album/playlist to `@""`, leaving stale `_activeContextURI` and `_contextEntries` in place.
3. **`isPlayerTrackAutoplay:forFuture:` missed several Search / non-context shapes**:
   - Previously checked only `spotify:search`, `:search:`, and `spotify:track:`.
   - Missed empty context `@""`, `:search` without trailing colon (e.g. `spotify:user:...:search`), `spotify:find`, `spotify:internal:`, `spotify:assist:`, `provider` containing `"search"`, and `track.metadata[@"context_uri"]` carrying a search/track URI.
4. **Guards & State Fingerprint**:
   - `rebuildContinuePlayingWithState:` needed an explicit `!SGRIsNonContextURI(_activeContextURI)` guard on `_contextEntries`.
   - `fingerprintForSession:` did not encode the live Autoplay flag state (`A:%d`), risking skipped UI layout updates on edge transitions.

## Fixes Applied
- Added `SGRIsNonContextURI(NSString *ctxURI)` covering empty context, `spotify:search` / `:search`, `spotify:find` / `:find:`, `spotify:track:`, `spotify:internal:`, and `spotify:assist:`.
- Removed `meta[@"album_uri"]` fallback promotion in `effectiveContextURIForState:`.
- Updated `ingestPlayerState:` so `contextChanged` triggers whenever `np != nil && ![(_activeContextURI ?: @"") isEqualToString:ctxURI]`, clearing stale context state on transitions to empty or search contexts.
- Updated `isPlayerTrackAutoplay:forFuture:` to classify non-user-queued future tracks under any non-context URI (or `track.metadata[@"context_uri"]` non-context URI or `"search"` provider) as autoplay recommendations, hidden whenever Autoplay is OFF.
- Guarded `_contextEntries` usage in `rebuildContinuePlayingWithState:` with `!SGRIsNonContextURI(_activeContextURI)` and included Autoplay state in `fingerprintForSession:`.

## Verification Checklist
- [x] Fix `effectiveContextURIForState:` (stop promoting empty/`spotify:track:` to `album_uri`).
- [x] Fix `ingestPlayerState:` `contextChanged` clearing on transition to empty context.
- [x] Harden `isPlayerTrackAutoplay:forFuture:` with `SGRIsNonContextURI` + track metadata/provider checks.
- [x] Guard `_contextEntries` & add `A:%d` to `fingerprintForSession:`.
- [x] Run Bug Check Pass 1 & 2 + Deslopification Pass 1 & 2.
- [x] Run `./scripts/check-layers.sh` (0 violations).
- [x] Safety commit & push `feat/apple-music-queue`.

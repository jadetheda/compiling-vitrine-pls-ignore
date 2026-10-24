// Hooks a C function Spotify imports, by pointing Spotify's own import slot for it (its __got,
// or __la_symbol_ptr in an older build) at a replacement. Only calls Spotify's own code makes
// go through the new function; the system's frameworks keep calling the original. This is the
// fishhook technique, targeting Spotify's binary (the main executable on standard installs,
// or the guest image under virtualization like LiveContainer), for the few places no Objective-C
// method stands between Spotify and a system call (the audio output unit Music Haptics listens to).
//
// Threading: safe to call from a %ctor or dynamically; image notifications and slot rebindings
// are synchronized with an internal lock.
#import <Foundation/Foundation.h>

// Returns YES when at least one slot named `symbol` (without the leading underscore) was repointed.
// `original` receives what the first slot held (or the dynamic symbol from AudioToolbox/libsystem),
// which is what the replacement calls on.
BOOL SGRebindImport(const char *symbol, void *replacement, void **original);

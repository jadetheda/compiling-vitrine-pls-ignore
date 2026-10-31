// Apple Music style inline queue view for the redesigned player.
// Displays history, currently playing track with star & context actions,
// and upcoming tracks ("Continue Playing") with Apple Music pill buttons,
// swipe-to-delete, drag-to-reorder, and long-press context menus.

#import <UIKit/UIKit.h>
#import "Headers/SPTPlayer.h"
#import "Shared/Player/PlayerState.h"

@interface SGRQueueView : UIView <SGPlayerStateObserver>

// Reloads the upcoming tracks, history, and playback controls from current player state.
- (void)reloadTracks;

// Updates the queue with a fresh state report.
- (void)updateWithState:(SPTPlayerState *)state;

@end

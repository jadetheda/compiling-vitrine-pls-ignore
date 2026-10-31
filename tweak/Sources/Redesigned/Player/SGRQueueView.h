// Apple Music style inline queue view for the redesigned player.
// Displays upcoming tracks ("Playing Next") inside the player stage without opening a modal sheet.

#import <UIKit/UIKit.h>
#import "Headers/SPTPlayer.h"
#import "Shared/Player/PlayerState.h"

@interface SGRQueueView : UIView <SGPlayerStateObserver>

// Reloads the upcoming tracks and playback controls from the current player state.
- (void)reloadTracks;

// Updates the queue with a fresh state report.
- (void)updateWithState:(SPTPlayerState *)state;

@end

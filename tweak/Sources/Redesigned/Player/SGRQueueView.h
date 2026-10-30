// Apple Music style inline queue view for the redesigned player.
// Displays upcoming tracks ("Playing Next") inside the player stage without opening a modal sheet.

#import <UIKit/UIKit.h>
#import "Headers/SPTPlayer.h"

@interface SGRQueueView : UIView

// Reloads the upcoming tracks from the current player state.
- (void)reloadTracks;

// Updates the queue with a fresh state report.
- (void)updateWithState:(SPTPlayerState *)state;

@end

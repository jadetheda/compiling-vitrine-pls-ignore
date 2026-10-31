// Apple Music style inline queue view for the redesigned player.
// Displays an independent chronological History log, currently playing mini-card,
// and full upcoming context/queue tracks ("Continue Playing") with the 4-pill
// playback mode bar, scrollY = 0 detent, swipe-to-delete, drag-to-reorder,
// and long-press context menus.

#import <UIKit/UIKit.h>
#import "Headers/SPTPlayer.h"
#import "Shared/Player/PlayerState.h"

@interface SGRQueueView : UIView <SGPlayerStateObserver>

// Starts the persistent session tracker (chronological history + full spclient context track resolver).
+ (void)startSessionIfNeeded;

// Reloads upcoming tracks, history, and playback controls from current player/session state.
- (void)reloadTracks;

// Updates the queue with a fresh state report.
- (void)updateWithState:(SPTPlayerState *)state;

// Prepares the queue right before an open transition: docks scrollY = 0 with History locked closed
// and ensures track rows & layout are warm with zero blank frame.
- (void)prepareForOpenTransition;

// Hides the inline 62x62 Now Playing thumbnail while the shared-element 310x310 <-> 62x62 cover is in flight.
- (void)setTransitionArtworkHidden:(BOOL)hidden;

// Vertical slide + opacity applied to the queue chrome during the open/close spring transition.
- (void)setContentSlideOffset:(CGFloat)offsetY opacity:(CGFloat)opacity;

// Exact destination frame of the 62x62 Now Playing thumbnail in `targetView` coordinates (28.0, 86.7, 62, 62).
- (CGRect)nowPlayingArtworkFrameInView:(UIView *)targetView;

@end

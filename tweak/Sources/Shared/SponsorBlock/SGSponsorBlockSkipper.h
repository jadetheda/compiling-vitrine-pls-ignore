// SponsorBlock playback observer and segment skipper for podcasts.
#import <UIKit/UIKit.h>
#import "SGSponsorBlockAPI.h"
#import "Shared/Player/PlayerState.h"

@interface SGSponsorBlockSkipper : NSObject <SGPlayerStateObserver>

+ (instancetype)sharedSkipper;

@property (nonatomic, copy, readonly) NSString *currentEpisodeID;
@property (nonatomic, strong, readonly) NSArray<SGSponsorBlockSegment *> *currentSegments;
@property (nonatomic, assign, readonly) double currentDuration;

- (void)refreshCurrentState;
- (void)categoryActionsDidChange;

@end

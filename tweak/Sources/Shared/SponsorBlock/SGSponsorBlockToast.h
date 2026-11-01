// Pill banner for SponsorBlock skip notifications (Undo) and skip prompts (Skip).
#import <UIKit/UIKit.h>
#import "SGSponsorBlockAPI.h"

@interface SGSponsorBlockToast : NSObject

+ (void)showWithCategory:(NSString *)category
                duration:(NSTimeInterval)duration
             undoHandler:(void (^)(void))undoHandler;

+ (void)showPromptForSegment:(SGSponsorBlockSegment *)segment
                   remaining:(NSTimeInterval)remaining
                 skipHandler:(void (^)(void))skipHandler;

+ (BOOL)isPresentingPromptForSegment:(SGSponsorBlockSegment *)segment;
+ (void)updateActiveToastTimeout;
+ (void)dismiss;
+ (void)dismissImmediate:(BOOL)immediate;

@end

// SponsorBlock for podcasts: preferences keys and settings page entry point.
#import <UIKit/UIKit.h>
#import "SGSponsorBlockAPI.h"

static NSString *const SGKeySponsorBlockEnabled           = @"spotifyglass.sponsorblock.enabled";
static NSString *const SGKeySponsorBlockShowToast         = @"spotifyglass.sponsorblock.showToast";
static NSString *const SGKeySponsorBlockToastDuration     = @"spotifyglass.sponsorblock.toastDuration";
static NSString *const SGKeySponsorBlockPromptDuration    = @"spotifyglass.sponsorblock.promptDuration";
static NSString *const SGKeySponsorBlockHaptics           = @"spotifyglass.sponsorblock.haptics";
static NSString *const SGKeySponsorBlockIgnoreManualScrub = @"spotifyglass.sponsorblock.ignoreManualScrub";
static NSString *const SGKeySponsorBlockMinDuration       = @"spotifyglass.sponsorblock.minDuration";
static NSString *const SGKeySponsorBlockSkipCount         = @"spotifyglass.sponsorblock.skipCount";
static NSString *const SGKeySponsorBlockTimeSaved         = @"spotifyglass.sponsorblock.timeSaved";

UIViewController *SGSponsorBlockSettingsPage(void);
NSString *SGSponsorBlockSummary(void);
void SGSponsorBlockPreferencesDidChange(void);

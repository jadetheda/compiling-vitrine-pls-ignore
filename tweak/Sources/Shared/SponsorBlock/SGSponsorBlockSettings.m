// SponsorBlock settings page (linked from Shared/AdBlock/AdBlockSettings.m under Podcasts).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "SGSponsorBlock.h"
#import "SGSponsorBlockAPI.h"
#import "SGSponsorBlockSkipper.h"
#import "SGSponsorBlockOverlay.h"
#import "SGSponsorBlockToast.h"

NSString *SGSponsorBlockSummary(void) {
    NSUInteger active = SGSponsorBlockActiveCategoryCount();
    return active == 0 ? @"None" : [NSString stringWithFormat:@"%lu active", (unsigned long)active];
}

void SGSponsorBlockPreferencesDidChange(void) {
    SGRefreshSponsorBlockOverlays();
    [[SGSponsorBlockSkipper sharedSkipper] refreshCurrentState];
}

static NSArray<NSString *> *actionMenuTitles(void) {
    return @[@"Auto-skip", @"Prompt", @"Seekbar only", @"Off"];
}

static NSString *titleForAction(SGSponsorBlockAction action) {
    switch (action) {
        case SGSponsorBlockActionSkip:     return @"Auto-skip";
        case SGSponsorBlockActionPrompt:   return @"Prompt";
        case SGSponsorBlockActionShowOnly: return @"Seekbar only";
        case SGSponsorBlockActionOff:
        default:                           return @"Off";
    }
}

static SGSponsorBlockAction actionForMenuIndex(NSInteger index) {
    switch (index) {
        case 0:  return SGSponsorBlockActionSkip;
        case 1:  return SGSponsorBlockActionPrompt;
        case 2:  return SGSponsorBlockActionShowOnly;
        default: return SGSponsorBlockActionOff;
    }
}

static SGModRow *categoryRow(SGSponsorBlockCategoryInfo *info) {
    NSString *catID = info.identifier;
    SGModRow *row = SGMenuRow(info.settingsTitle, actionMenuTitles(), ^NSString *{
        return titleForAction(SGSponsorBlockActionForCategory(catID));
    }, ^(NSInteger index) {
        SGSponsorBlockSetActionForCategory(catID, actionForMenuIndex(index));
        [[SGSponsorBlockSkipper sharedSkipper] categoryActionsDidChange];
    });
    row.subtitle = info.summary;
    return row;
}

UIViewController *SGSponsorBlockSettingsPage(void) {
    __block __weak SGModPage *weakPage = nil;

    NSMutableArray<SGModRow *> *catRows = [NSMutableArray array];
    for (SGSponsorBlockCategoryInfo *info in SGSponsorBlockAllCategories()) {
        [catRows addObject:categoryRow(info)];
    }

    SGModRow *resetCats = SGActionRow(@"Reset categories to defaults", @"Restore default skip and prompt settings", ^{
        SGSponsorBlockResetCategoriesToDefaults();
        [[SGSponsorBlockSkipper sharedSkipper] categoryActionsDidChange];
        [weakPage.tableView reloadData];
    });
    [catRows addObject:resetCats];

    SGModRow *showToast = SGSwitchRow(@"Show skip notifications", @"Show an Undo banner after skipping a segment", SGKeySponsorBlockShowToast);
    showToast.changed = ^(BOOL on) {
        if (!on) [SGSponsorBlockToast dismiss];
        else [SGSponsorBlockToast updateActiveToastTimeout];
    };

    SGModRow *toastDuration = SGSliderRow(@"Undo banner duration", nil, 2.0, 10.0, 1.0,
        ^double { return SGSponsorBlockToastDuration(); },
        ^(double val) {
            SGSponsorBlockSetToastDuration(val);
            [SGSponsorBlockToast updateActiveToastTimeout];
        },
        ^NSString *(double val) { return [NSString stringWithFormat:@"%ld s", lround(val)]; });

    SGModRow *promptDuration = SGSliderRow(@"Skip prompt duration", nil, 3.0, SGSponsorBlockPromptDurationInfinite, 1.0,
        ^double { return SGSponsorBlockPromptDuration(); },
        ^(double val) {
            SGSponsorBlockSetPromptDuration(val);
            [SGSponsorBlockToast updateActiveToastTimeout];
        },
        ^NSString *(double val) {
            return val >= SGSponsorBlockPromptDurationInfinite ? @"Until end" : [NSString stringWithFormat:@"%ld s", lround(val)];
        });

    SGModRow *haptics = SGSwitchRow(@"Haptic feedback", @"Play haptics when skipping or showing a prompt", SGKeySponsorBlockHaptics);
    SGModRow *manualScrub = SGHideRow(@"Respect manual scrub", @"Prompt instead of auto-skipping when scrubbing into a segment", SGKeySponsorBlockIgnoreManualScrub);

    SGModRow *minDuration = SGSliderRow(@"Minimum segment duration", nil, 0.0, 10.0, 0.5,
        ^double { return SGSponsorBlockMinDuration(); },
        ^(double val) {
            SGSponsorBlockSetMinDuration(val);
            SGSponsorBlockPreferencesDidChange();
        },
        ^NSString *(double val) {
            return val <= 0.0 ? @"0 s" : [NSString stringWithFormat:@"%.1f s", val];
        });

    SGModRow *skipCountRow = SGStatRow(@"Segments skipped", ^NSString *{
        return [NSString stringWithFormat:@"%ld", (long)SGSponsorBlockSkipCount()];
    });

    SGModRow *timeSavedRow = SGStatRow(@"Time saved", ^NSString *{
        return SGFormatSponsorBlockDuration(SGSponsorBlockTimeSaved());
    });

    SGModRow *resetStatsRow = SGActionRow(@"Reset statistics", nil, ^{
        SGResetSponsorBlockStats();
        [weakPage.tableView reloadData];
    });
    resetStatsRow.color = SGRed();

    SGModPage *page = [[SGModPage alloc] initWithTitle:@"SponsorBlock" intro:nil sections:@[
        SGNotedSection(@"Categories to skip", catRows,
            @"Auto-skip jumps past segments automatically. Prompt shows a banner so you can choose when to skip."),
        SGSection(@"Behavior", @[showToast, toastDuration, promptDuration, haptics, manualScrub, minDuration]),
        SGSection(@"Statistics", @[skipCountRow, timeSavedRow, resetStatsRow]),
    ] footer:@"Segment timestamps come from Spot-SponsorBlock (spotsponsorblock.org) on the SponsorBlock database "
             @"(sponsor.ajay.app). Because segments are submitted by listeners, newer or less common episodes may not be marked yet."];
    weakPage = page;
    return page;
}

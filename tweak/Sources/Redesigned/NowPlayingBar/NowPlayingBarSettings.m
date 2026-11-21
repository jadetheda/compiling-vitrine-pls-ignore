// The now playing bar's rows of the redesign, the Mini player section of the Player page
// (Redesigned/Player/PlayerSettings.m puts them there).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Redesigned/Navbar/Navbar.h"
#import "NowPlayingBar.h"

NSArray<SGModRow *> *SGRNowPlayingBarRows(void) {
    // The tab bar reads the switch as each scroll goes; a bar minimized when it goes off grows back at once.
    SGModRow *minimize = SGSwitchRow(@"Minimize on scroll", @"Dock between the tabs when scrolling down", SGRKeyNavbarMinimize);
    minimize.changed = ^(BOOL on) {
        if (!on) SGRSetTabBarMinimized(NO, NO);
        SGRRefreshTabBar();
        SGRNowPlayingBarFollowTabBar();
    };
    SGModRow *nextButton = SGSwitchRow(@"Next button", @"Skip forward button next to play", SGRKeyBarNextButton);
    nextButton.defaultOn = SGEnabled(SGRKeyBarCompact);
    nextButton.changed = ^(BOOL on) {
        SGRNowPlayingBarFollowTabBar();
    };
    SGModRow *compactBar = SGSwitchRow(@"Compact mini player", @"48 pt pill with 32 pt artwork", SGRKeyBarCompact);
    compactBar.changed = ^(BOOL on) {
        nextButton.defaultOn = on;
        SGRNowPlayingBarFollowTabBar();
        SGRRefreshTabBar();
    };
    SGModRow *artworkShape = SGChoiceRow(@"Artwork shape", @"Cover art shape on the mini player",
                                         SGRKeyBarArtworkShape,
                                         @[@"Rounded square", @"Circle"],
                                         SGRBarArtworkShapeRoundedSquare);
    artworkShape.choiceNotes = @[
        @"Continuous rounded square matching Apple Music.",
        @"Circular cover art matching the classic Vitrine look.",
    ];
    artworkShape.chosen = ^(NSInteger index) {
        SGRNowPlayingBarFollowTabBar();
    };
    // The capsule bar (iOS < 26) only: the glass bar always comes back as the page is scrolled up.
    SGModRow *expandOnUp = SGRLegacyTabBarOn() ? SGOptionRow(@"Expand on scroll up", @"Off: only at the top of the page or on a tap on a tab", SGRKeyNavbarExpandOnScrollUp) : nil;
    expandOnUp.waitsOn = SGRKeyNavbarMinimize;
    SGModRow *inlineConnect = SGOptionRow(@"Device button", @"Kept on the bar between the tabs", SGRKeyBarInlineConnect);
    inlineConnect.waitsOn = SGRKeyNavbarMinimize;
    inlineConnect.changed = ^(BOOL on) {
        SGRNowPlayingBarFollowTabBar();
    };
    SGModRow *hideConnect = SGHideRow(@"Hide the device button", @"On the full now playing bar", SGRHideBarConnect);
    hideConnect.changed = ^(BOOL on) {
        SGRNowPlayingBarFollowTabBar();
    };
    NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithObject:minimize];
    if (expandOnUp) [rows addObject:expandOnUp];
    [rows addObjectsFromArray:@[
        compactBar,
        nextButton,
        artworkShape,
        inlineConnect,
        hideConnect,
        // Spotify's own flag for the bar's save button, forced off: Spotify leaves the button out.
        SGKillRow(@"Hide the like button", @"ios-feature-nowplayingbar.add_button"),
    ]];
    return rows;
}

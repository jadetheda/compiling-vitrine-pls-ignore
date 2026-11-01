// Hooks Spotify's Now Playing progress bar views (regular and chapter-segmented) to draw
// SponsorBlock segment markers, and starts the shared playback observer on launch.
#import "Core/SGCore.h"
#import "SGSponsorBlock.h"
#import "SGSponsorBlockSkipper.h"
#import "SGSponsorBlockOverlay.h"

%hook _TtCO17NowPlaying_ECMKit11ProgressBar9AudioView
- (void)layoutSubviews {
    %orig;
    SGUpdateSponsorBlockOverlay((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) SGUpdateSponsorBlockOverlay((UIView *)self);
}
%end

%hook _TtC22EpisodeChapters_ECMKit18SegmentedAudioView
- (void)layoutSubviews {
    %orig;
    SGUpdateSponsorBlockOverlay((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) SGUpdateSponsorBlockOverlay((UIView *)self);
}
%end

%hook _TtCO17NowPlaying_ECMKit11ProgressBar6Slider
- (void)layoutSubviews {
    %orig;
    SGUpdateSponsorBlockOverlay((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) SGUpdateSponsorBlockOverlay((UIView *)self);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[
        @"_TtCO17NowPlaying_ECMKit11ProgressBar9AudioView",
        @"_TtC22EpisodeChapters_ECMKit18SegmentedAudioView",
        @"_TtCO17NowPlaying_ECMKit11ProgressBar6Slider",
    ]);
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification *note) {
        [SGSponsorBlockSkipper sharedSkipper];
    }];
}

// Colored segment markers on Spotify's Now Playing progress bar (both regular ProgressBar.AudioView
// and EpisodeChapters_ECMKit.SegmentedAudioView for chaptered podcast episodes).
#import <objc/runtime.h>
#import "SGSponsorBlockOverlay.h"
#import "SGSponsorBlockSkipper.h"
#import "SGSponsorBlockAPI.h"
#import "SGSponsorBlock.h"
#import "Core/SGCore.h"

static const void *kOverlayContainerKey = &kOverlayContainerKey;
static NSHashTable<UIView *> *sg_trackedBars;
static NSUInteger sg_overlayGeneration = 1;

@interface SGSponsorBlockOverlayContainer : UIView
@property (nonatomic, copy) NSString *renderedEpisodeID;
@property (nonatomic, assign) double renderedDuration;
@property (nonatomic, assign) CGRect renderedTrackFrame;
@property (nonatomic, assign) NSUInteger renderedGeneration;
@end

@implementation SGSponsorBlockOverlayContainer
@end

static BOOL hasDedicatedAudioViewSibling(UIView *view) {
    NSString *cls = NSStringFromClass(view.class);
    if ([cls containsString:@"AudioView"]) return NO;
    for (UIView *sibling in view.superview.subviews) {
        if (sibling != view && [NSStringFromClass(sibling.class) containsString:@"AudioView"]) return YES;
    }
    return NO;
}

static CGRect resolveTrackFrame(UIView *barView) {
    CGFloat w = barView.bounds.size.width;
    CGFloat h = barView.bounds.size.height;
    if (w <= 10 || h <= 0) return CGRectZero;

    // Inside ProgressBar.AudioView and EpisodeChapters_ECMKit.SegmentedAudioView, the subviews are
    // AudioSegmentView instances, each holding a `barView` subview at the exact visual track height.
    for (UIView *sub in barView.subviews) {
        if ([sub isKindOfClass:SGSponsorBlockOverlayContainer.class] || sub.hidden || sub.alpha < 0.01) continue;
        NSString *subCls = NSStringFromClass(sub.class);
        if ([subCls containsString:@"AudioSegmentView"]) {
            for (UIView *inner in sub.subviews) {
                if (!inner.hidden && inner.bounds.size.width > 0 && inner.bounds.size.height > 0 && inner.bounds.size.height <= 14) {
                    CGRect r = [barView convertRect:inner.bounds fromView:inner];
                    return CGRectMake(0, r.origin.y, w, r.size.height);
                }
            }
            if (sub.bounds.size.height > 0 && sub.bounds.size.height <= 14) {
                CGRect r = [barView convertRect:sub.bounds fromView:sub];
                return CGRectMake(0, r.origin.y, w, r.size.height);
            }
        }
    }

    if ([barView isKindOfClass:UISlider.class]) {
        CGRect track = [(UISlider *)barView trackRectForBounds:barView.bounds];
        if (track.size.width > 10 && track.size.height > 0 && track.size.height <= 14) return track;
    }

    CGFloat barHeight = MIN(4.0, h);
    return CGRectMake(0, (h - barHeight) / 2.0, w, barHeight);
}

void SGUpdateSponsorBlockOverlay(UIView *barView) {
    if (!barView) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGUpdateSponsorBlockOverlay(barView); });
        return;
    }

    if (!sg_trackedBars) sg_trackedBars = [NSHashTable weakObjectsHashTable];
    if (![sg_trackedBars containsObject:barView]) [sg_trackedBars addObject:barView];

    SGSponsorBlockOverlayContainer *container = objc_getAssociatedObject(barView, kOverlayContainerKey);

    // If this is a UISlider whose superview already has a dedicated AudioView/SegmentedAudioView sibling,
    // let the AudioView draw the overlay so we don't duplicate markers.
    if (hasDedicatedAudioViewSibling(barView)) {
        container.hidden = YES;
        return;
    }

    SGSponsorBlockSkipper *skipper = [SGSponsorBlockSkipper sharedSkipper];
    NSArray<SGSponsorBlockSegment *> *segments = skipper.currentSegments;
    double duration = skipper.currentDuration;
    NSString *episodeID = skipper.currentEpisodeID;

    if (!SGFlag(SGKeySponsorBlockEnabled, NO) || !episodeID.length || !segments.count || duration <= 0 || barView.bounds.size.width <= 10) {
        container.hidden = YES;
        return;
    }

    CGRect trackFrame = resolveTrackFrame(barView);
    if (trackFrame.size.width <= 10 || trackFrame.size.height <= 0) {
        container.hidden = YES;
        return;
    }

    if (container &&
        !container.hidden &&
        container.renderedGeneration == sg_overlayGeneration &&
        [container.renderedEpisodeID isEqualToString:episodeID] &&
        fabs(container.renderedDuration - duration) < 0.25 &&
        CGRectEqualToRect(container.renderedTrackFrame, trackFrame)) {
        [barView bringSubviewToFront:container];
        return;
    }

    if (!container) {
        container = [[SGSponsorBlockOverlayContainer alloc] initWithFrame:trackFrame];
        container.userInteractionEnabled = NO;
        container.clipsToBounds = YES;
        objc_setAssociatedObject(barView, kOverlayContainerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [barView addSubview:container];
    }

    container.frame = trackFrame;
    container.layer.cornerRadius = trackFrame.size.height / 2.0;
    container.renderedEpisodeID = episodeID;
    container.renderedDuration = duration;
    container.renderedTrackFrame = trackFrame;
    container.renderedGeneration = sg_overlayGeneration;

    for (UIView *sub in [container.subviews copy]) [sub removeFromSuperview];

    double minDur = SGSponsorBlockMinDuration();
    CGFloat totalW = trackFrame.size.width;
    CGFloat barH = trackFrame.size.height;
    NSUInteger drawn = 0;

    for (SGSponsorBlockSegment *seg in segments) {
        if (seg.duration < minDur) continue;
        if (SGSponsorBlockActionForCategory(seg.category) == SGSponsorBlockActionOff) continue;

        double clampedStart = MAX(0.0, MIN(duration, seg.startTime));
        double clampedEnd = MAX(clampedStart, MIN(duration, seg.endTime));
        if (clampedEnd <= clampedStart) continue;

        CGFloat x = (CGFloat)(clampedStart / duration) * totalW;
        CGFloat w = MAX(3.0, (CGFloat)((clampedEnd - clampedStart) / duration) * totalW);
        if (x + w > totalW) w = MAX(2.0, totalW - x);

        UIView *marker = [[UIView alloc] initWithFrame:CGRectMake(x, 0, w, barH)];
        marker.userInteractionEnabled = NO;
        marker.backgroundColor = [SGSponsorBlockCategoryColor(seg.category) colorWithAlphaComponent:0.9];
        marker.layer.cornerRadius = MIN(barH / 2.0, w / 2.0);
        [container addSubview:marker];
        drawn++;
    }

    container.hidden = (drawn == 0);
    [barView bringSubviewToFront:container];
}

void SGRefreshSponsorBlockOverlays(void) {
    void (^work)(void) = ^{
        sg_overlayGeneration++;
        for (UIView *bar in sg_trackedBars.allObjects) {
            if (bar.window) SGUpdateSponsorBlockOverlay(bar);
        }
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

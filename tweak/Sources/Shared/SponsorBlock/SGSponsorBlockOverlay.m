// Colored segment rail for Spotify's Now Playing progress bar.
// Ported from EeveeSpotify Reincarnated (GPL-3.0) and Spot-SponsorBlock-Extension.

#import "SGSponsorBlockOverlay.h"
#import "SGSponsorBlock.h"
#import "SGSponsorBlockSkipper.h"
#import "Core/SGCore.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static const CGFloat kSegmentRailHeight = 3.0;
static const CGFloat kSegmentRailGap = 4.0;
static const CGFloat kExpandedTrackHeight = 12.0;
static const CGFloat kLegacyTrackHeight = 7.0;
static const CGFloat kLegacyTrackInset = 3.0;

@interface SGSponsorBlockSegmentBar : UIView
@property (nonatomic) CGFloat startRatio;
@property (nonatomic) CGFloat endRatio;
@end

@implementation SGSponsorBlockSegmentBar
@end

@interface SGSponsorBlockOverlayContainer : UIView
@property (nonatomic, copy) NSString *cachedEpisodeID;
@property (nonatomic) double cachedDuration;
@property (nonatomic) NSArray<SGSponsorBlockSegment *> *cachedRawSegments;
@property (nonatomic) BOOL needsRebuild;
@property (nonatomic) BOOL pendingPostLayout;
@property (nonatomic) CGRect lastPostLayoutBounds;
@property (nonatomic, weak) UIView *cachedVisualElement;
- (void)rebuildWithSegments:(NSArray<SGSponsorBlockSegment *> *)segments
                   duration:(double)duration
                  episodeID:(NSString *)episodeID
                 trackFrame:(CGRect)trackFrame;
- (void)layoutSegmentsForTrackFrame:(CGRect)trackFrame;
@end

@implementation SGSponsorBlockOverlayContainer

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}

- (void)applyTrackFrame:(CGRect)trackFrame {
    self.frame = trackFrame;
    self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    self.layer.cornerRadius = trackFrame.size.height / 2.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
}

- (void)layoutSegmentBar:(SGSponsorBlockSegmentBar *)bar
              trackWidth:(CGFloat)trackWidth
             trackHeight:(CGFloat)trackHeight
                  corner:(CGFloat)corner {
    CGFloat x = bar.startRatio * trackWidth;
    CGFloat segWidth = MAX(2.0, (bar.endRatio - bar.startRatio) * trackWidth);
    if (x + segWidth > trackWidth) {
        segWidth = MAX(1.0, trackWidth - x);
    }
    bar.frame = CGRectMake(x, 0, segWidth, trackHeight);
    bar.layer.cornerRadius = corner;
    bar.layer.cornerCurve = kCACornerCurveContinuous;
    bar.layer.masksToBounds = YES;
}

- (void)rebuildWithSegments:(NSArray<SGSponsorBlockSegment *> *)segments
                   duration:(double)duration
                  episodeID:(NSString *)episodeID
                 trackFrame:(CGRect)trackFrame {
    _cachedEpisodeID = [episodeID copy];
    _cachedDuration = duration;
    _needsRebuild = NO;

    for (UIView *subview in [self.subviews copy]) {
        [subview removeFromSuperview];
    }

    [self applyTrackFrame:trackFrame];

    CGFloat trackWidth = trackFrame.size.width;
    CGFloat trackHeight = trackFrame.size.height;
    CGFloat corner = trackHeight / 2.0;

    for (SGSponsorBlockSegment *seg in segments) {
        CGFloat startRatio = (CGFloat)(seg.start / duration);
        CGFloat endRatio = (CGFloat)(seg.end / duration);
        if (startRatio < 0.0) startRatio = 0.0;
        if (endRatio > 1.0) endRatio = 1.0;
        if (endRatio <= startRatio) continue;

        SGSponsorBlockSegmentBar *bar = [SGSponsorBlockSegmentBar new];
        bar.startRatio = startRatio;
        bar.endRatio = endRatio;
        UIColor *catColor = SGSponsorBlockCategoryColor(seg.category);
        bar.backgroundColor = [catColor colorWithAlphaComponent:0.90];
        bar.userInteractionEnabled = NO;
        [self layoutSegmentBar:bar trackWidth:trackWidth trackHeight:trackHeight corner:corner];
        [self addSubview:bar];
    }
}

- (void)layoutSegmentsForTrackFrame:(CGRect)trackFrame {
    [self applyTrackFrame:trackFrame];
    CGFloat trackWidth = trackFrame.size.width;
    CGFloat trackHeight = trackFrame.size.height;
    if (trackWidth <= 0 || trackHeight <= 0) return;
    CGFloat corner = trackHeight / 2.0;

    for (UIView *sv in self.subviews) {
        if (![sv isKindOfClass:[SGSponsorBlockSegmentBar class]]) continue;
        [self layoutSegmentBar:(SGSponsorBlockSegmentBar *)sv
                    trackWidth:trackWidth
                   trackHeight:trackHeight
                        corner:corner];
    }
}

@end

static NSHashTable<UIView *> *s_trackedSliders = nil;

static BOOL isFiniteRect(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) &&
           isfinite(r.size.width) && isfinite(r.size.height);
}

static BOOL rectNearlyEqual(CGRect a, CGRect b, CGFloat tol) {
    return fabs(a.origin.x - b.origin.x) <= tol &&
           fabs(a.origin.y - b.origin.y) <= tol &&
           fabs(a.size.width - b.size.width) <= tol &&
           fabs(a.size.height - b.size.height) <= tol;
}

static BOOL isVisualElementView(UIView *view) {
    return SGClassNamed(view.class, @"_UISlideriOSVisualElement") ||
           SGClassNamed(view.class, @"_UISliderFluidVisualElement") ||
           SGClassNamed(view.class, @"VisualElement");
}

static BOOL isFluidSlider(UIView *visualElement) {
    if (visualElement &&
        (SGClassNamed(visualElement.class, @"_UISliderFluidVisualElement") ||
         SGClassNamed(visualElement.class, @"Fluid") ||
         SGClassNamed(visualElement.class, @"Glass"))) {
        return YES;
    }
    return !SGBelowiOS26();
}

static CGRect superTrackRectForSlider(UISlider *slider, CGRect bounds) {
    typedef CGRect (*TrackRectIMP)(id, SEL, CGRect);
    static TrackRectIMP s_uiSliderTrackRect = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        IMP imp = class_getMethodImplementation(UISlider.class, @selector(trackRectForBounds:));
        s_uiSliderTrackRect = (TrackRectIMP)(void *)imp;
    });
    if (!s_uiSliderTrackRect || !slider) return CGRectZero;
    return s_uiSliderTrackRect(slider, @selector(trackRectForBounds:), bounds);
}

static BOOL hasValidHorizontalSpan(CGRect r, CGFloat sliderW) {
    return isFiniteRect(r) &&
           r.size.width > 0 &&
           r.size.width >= sliderW - 24.0 &&
           r.origin.x >= -16.0 &&
           CGRectGetMaxX(r) <= sliderW + 16.0;
}

static CGRect resolveSegmentRailFrame(UIView *slider, UIView *visualElement) {
    if (!slider || slider.bounds.size.width <= 0 || slider.bounds.size.height <= 0) {
        return CGRectZero;
    }

    CGFloat sliderW = slider.bounds.size.width;
    BOOL isFluid = isFluidSlider(visualElement);
    CGRect tr = CGRectZero;
    CGRect superRect = CGRectZero;

    if ([slider isKindOfClass:UISlider.class]) {
        UISlider *uiSlider = (UISlider *)slider;
        tr = [uiSlider trackRectForBounds:slider.bounds];
        superRect = superTrackRectForSlider(uiSlider, slider.bounds);
    }

    CGFloat fallbackInset = isFluid ? 0.0 : kLegacyTrackInset;
    CGFloat x = fallbackInset;
    CGFloat w = MAX(0.0, sliderW - fallbackInset * 2.0);
    if (hasValidHorizontalSpan(tr, sliderW)) {
        x = tr.origin.x;
        w = tr.size.width;
    } else if (hasValidHorizontalSpan(superRect, sliderW)) {
        x = superRect.origin.x;
        w = superRect.size.width;
    }

    BOOL hasVisualFrame = (visualElement &&
                           visualElement.superview == slider &&
                           isFiniteRect(visualElement.frame) &&
                           visualElement.frame.size.height > 0);
    BOOL hasSuperRect = (isFiniteRect(superRect) && superRect.size.height > 0);

    CGFloat trackMidY = CGRectGetMidY(slider.bounds);
    if (isFluid) {
        if (hasVisualFrame) {
            trackMidY = CGRectGetMidY(visualElement.frame);
        } else if (hasSuperRect) {
            trackMidY = CGRectGetMidY(superRect);
        }
    } else if (hasSuperRect) {
        trackMidY = CGRectGetMidY(superRect);
    }

    CGFloat legacyTrackH = (isFiniteRect(tr) && tr.size.height > 0 && tr.size.height <= 16.0)
        ? tr.size.height
        : kLegacyTrackHeight;
    CGFloat trackHalfMaxH = isFluid ? (kExpandedTrackHeight / 2.0) : MAX(legacyTrackH / 2.0, 3.5);
    CGFloat y = trackMidY - trackHalfMaxH - kSegmentRailGap - kSegmentRailHeight;
    if (slider.clipsToBounds) {
        y = MAX(0.0, y);
    }

    return CGRectMake(x, y, w, kSegmentRailHeight);
}

@interface SGSponsorBlockOverlay (Internal)
+ (void)updateSlider:(UIView *)slider;
@end

@implementation SGSponsorBlockOverlay

+ (void)initialize {
    if (self == [SGSponsorBlockOverlay class]) {
        s_trackedSliders = [NSHashTable weakObjectsHashTable];
    }
}

+ (void)attachToSlider:(UIView *)slider {
    if (!slider) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self attachToSlider:slider];
        });
        return;
    }
    [s_trackedSliders addObject:slider];
    [self updateSlider:slider];
}

+ (void)refreshAll {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshAll];
        });
        return;
    }
    for (UIView *slider in s_trackedSliders.allObjects) {
        for (UIView *sv in slider.subviews) {
            if ([sv isKindOfClass:[SGSponsorBlockOverlayContainer class]]) {
                ((SGSponsorBlockOverlayContainer *)sv).needsRebuild = YES;
            }
        }
        [self updateSlider:slider];
    }
}

+ (void)updateSlider:(UIView *)slider {
    SGSponsorBlockOverlayContainer *container = nil;
    for (UIView *sv in slider.subviews) {
        if ([sv isKindOfClass:[SGSponsorBlockOverlayContainer class]]) {
            container = (SGSponsorBlockOverlayContainer *)sv;
            break;
        }
    }

    if (!SGFlag(SGKeySponsorBlockEnabled, NO) || !SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockOverlay)) {
        if (container) [container removeFromSuperview];
        return;
    }

    SGSponsorBlockSkipper *skipper = [SGSponsorBlockSkipper sharedSkipper];
    NSString *episodeID = skipper.currentEpisodeID;
    double duration = skipper.episodeDuration;
    NSArray<SGSponsorBlockSegment *> *segments = skipper.currentSegments;

    if (!episodeID.length || !isfinite(duration) || duration <= 0 || !segments.count) {
        if (container) [container removeFromSuperview];
        return;
    }

    UIView *visualElement = container.cachedVisualElement;
    if (!visualElement || visualElement.superview != slider) {
        visualElement = nil;
        for (UIView *sv in slider.subviews) {
            if (sv != container && isVisualElementView(sv)) {
                visualElement = sv;
                break;
            }
        }
        if (container) {
            container.cachedVisualElement = visualElement;
        }
    }

    CGRect railFrame = resolveSegmentRailFrame(slider, visualElement);
    if (railFrame.size.width <= 0 || railFrame.size.height <= 0) return;

    BOOL needsRebuild = (!container ||
                         container.needsRebuild ||
                         container.cachedRawSegments != segments ||
                         ![container.cachedEpisodeID isEqualToString:episodeID] ||
                         fabs(container.cachedDuration - duration) > 0.001);

    BOOL frameChanged = container && !rectNearlyEqual(container.frame, railFrame, 0.05);

    if (!needsRebuild) {
        if (frameChanged) {
            [UIView performWithoutAnimation:^{
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                [container layoutSegmentsForTrackFrame:railFrame];
                [CATransaction commit];
            }];
        }
    } else {
        NSTimeInterval minDuration = SGSponsorBlockMinDuration();
        NSMutableArray<SGSponsorBlockSegment *> *visible = [NSMutableArray array];
        for (SGSponsorBlockSegment *seg in segments) {
            if (![seg.actionType isEqualToString:@"skip"]) continue;
            if (seg.duration < minDuration) continue;
            if (SGSponsorBlockCategoryBehavior(seg.category) == SGSponsorBlockBehaviorOff) continue;
            [visible addObject:seg];
        }

        if (!visible.count) {
            if (container) [container removeFromSuperview];
            return;
        }

        if (!container) {
            container = [[SGSponsorBlockOverlayContainer alloc] initWithFrame:railFrame];
            container.userInteractionEnabled = NO;
            container.cachedVisualElement = visualElement;
            [slider addSubview:container];
        }
        container.cachedRawSegments = segments;
        [UIView performWithoutAnimation:^{
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [container rebuildWithSegments:visible duration:duration episodeID:episodeID trackFrame:railFrame];
            [CATransaction commit];
        }];
        frameChanged = YES;
    }

    BOOL boundsChanged = !CGRectEqualToRect(container.lastPostLayoutBounds, slider.bounds);
    if (slider.window && !container.pendingPostLayout && (boundsChanged || frameChanged)) {
        container.pendingPostLayout = YES;
        container.lastPostLayoutBounds = slider.bounds;
        __weak UIView *weakSlider = slider;
        __weak SGSponsorBlockOverlayContainer *weakContainer = container;
        dispatch_async(dispatch_get_main_queue(), ^{
            SGSponsorBlockOverlayContainer *c = weakContainer;
            UIView *s = weakSlider;
            if (!c) return;
            c.pendingPostLayout = NO;
            if (s && c.superview == s && s.window) {
                [self updateSlider:s];
            }
        });
    } else if (boundsChanged) {
        container.lastPostLayoutBounds = slider.bounds;
    }
}

@end

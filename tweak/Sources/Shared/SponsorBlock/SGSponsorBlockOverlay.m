// Colored progress-bar segment overlay for SponsorBlock segments.
// Ported from EeveeSpotify Reincarnated (GPL-3.0) and Spot-SponsorBlock-Extension.

#import "SGSponsorBlockOverlay.h"
#import "SGSponsorBlock.h"
#import "SGSponsorBlockSkipper.h"
#import "Core/SGCore.h"

static const CGFloat kMinTrackHeight = 3.0;
static const CGFloat kMaxTrackHeight = 16.0;
static const CGFloat kDefaultTrackHeight = 7.0;
static const CGFloat kExpandedTrackHeight = 12.0;
static const CGFloat kDefaultTrackInset = 3.0;
static const CGFloat kMaxMidYOffset = 5.5;

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
@property (nonatomic) BOOL didScanSubviews;
@property (nonatomic) BOOL usedRenderedTrack;
@property (nonatomic) BOOL lastHighlighted;
@property (nonatomic) BOOL pendingPostLayout;
@property (nonatomic) CGRect lastPostLayoutBounds;
@property (nonatomic, weak) UIView *cachedTrackView;
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
    CGFloat trackHeight = trackFrame.size.height;
    self.layer.cornerRadius = trackHeight / 2.0;
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
    CGFloat corner = MIN(1.0, trackHeight / 2.0);

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
        bar.backgroundColor = [catColor colorWithAlphaComponent:0.65];
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
    CGFloat corner = MIN(1.0, trackHeight / 2.0);

    for (UIView *sv in self.subviews) {
        if (![sv isKindOfClass:[SGSponsorBlockSegmentBar class]]) continue;
        [self layoutSegmentBar:(SGSponsorBlockSegmentBar *)sv trackWidth:trackWidth trackHeight:trackHeight corner:corner];
    }
}

@end

static NSHashTable<UIView *> *s_trackedSliders = nil;

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
    [self updateSlider:slider animateHeightChange:NO];
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
        [self updateSlider:slider animateHeightChange:NO];
    }
}

static BOOL isFiniteRect(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) &&
           isfinite(r.size.width) && isfinite(r.size.height);
}

static BOOL isVisualElementView(UIView *view) {
    if (SGClassNamed(view.class, @"_UISlideriOSVisualElement") ||
        SGClassNamed(view.class, @"_UISliderFluidVisualElement")) {
        return YES;
    }
    NSString *name = NSStringFromClass(view.class);
    return [name containsString:@"VisualElement"];
}

static BOOL isThumbView(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return [name containsString:@"Thumb"] || [name containsString:@"Knob"];
}

static BOOL isColorVisible(CGColorRef color) {
    return color != NULL && CGColorGetAlpha(color) > 0.01;
}

static BOOL hasRenderedLayerContent(CALayer *layer) {
    if (!layer || layer.hidden || layer.opacity <= 0.01) return NO;
    if (isColorVisible(layer.backgroundColor) || layer.contents != nil) return YES;
    if ([layer isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *shape = (CAShapeLayer *)layer;
        if (shape.path != NULL && (isColorVisible(shape.fillColor) || isColorVisible(shape.strokeColor))) {
            return YES;
        }
    }
    if ([layer isKindOfClass:CAGradientLayer.class] && ((CAGradientLayer *)layer).colors.count > 0) {
        return YES;
    }
    if ((layer.masksToBounds && layer.cornerRadius >= 1.5) ||
        layer.mask != nil ||
        layer.compositingFilter != nil) {
        return YES;
    }
    NSString *name = NSStringFromClass(layer.class);
    return [name containsString:@"Backdrop"];
}

static BOOL hasRenderedTrackContent(UIView *view) {
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image != nil) {
        return YES;
    }
    if ([view isKindOfClass:UIVisualEffectView.class]) {
        return YES;
    }
    if (view.backgroundColor && isColorVisible(view.backgroundColor.CGColor)) {
        return YES;
    }
    if (view.clipsToBounds && view.layer.cornerRadius >= 1.5) {
        return YES;
    }
    return hasRenderedLayerContent(view.layer);
}

static CGRect renderedTrackRectForSubview(UIView *sub, UIView *slider) {
    CGRect r = [slider convertRect:sub.bounds fromView:sub];
    if ([sub isKindOfClass:UIImageView.class]) {
        UIImage *img = ((UIImageView *)sub).image;
        if (img && img.size.height > 0 && img.size.height < r.size.height - 0.5 &&
            (sub.contentMode == UIViewContentModeCenter || sub.contentMode == UIViewContentModeScaleAspectFit)) {
            r.origin.y = CGRectGetMidY(r) - img.size.height / 2.0;
            r.size.height = img.size.height;
        }
    }
    return r;
}

static BOOL isValidTrackCandidate(CGRect r, CGFloat sliderW, CGFloat expectedMidY, CGFloat cornerRadius) {
    if (!isFiniteRect(r)) return NO;
    BOOL thumbSized = (r.size.width <= r.size.height + 4.0 &&
                       r.size.width < sliderW * 0.25 &&
                       cornerRadius >= r.size.height * 0.4 &&
                       r.size.height >= 9.0);
    if (thumbSized) return NO;
    return r.size.height >= kMinTrackHeight && r.size.height <= kMaxTrackHeight &&
           r.size.width >= 1.0 &&
           fabs(CGRectGetMidY(r) - expectedMidY) <= kMaxMidYOffset &&
           r.origin.x >= -16.0 && CGRectGetMaxX(r) <= sliderW + 16.0;
}

static void collectLayerTrackCandidates(CALayer *layer,
                                        UIView *slider,
                                        CGFloat expectedMidY,
                                        NSUInteger depth,
                                        NSMutableArray<NSValue *> *outRects) {
    if (!layer || depth > 8 || outRects.count >= 32) return;
    CGFloat sliderW = slider.bounds.size.width;
    for (CALayer *sub in layer.sublayers) {
        if (sub.hidden || sub.opacity <= 0.01) continue;
        if ([sub.delegate isKindOfClass:UIView.class] && isThumbView((UIView *)sub.delegate)) continue;
        if (hasRenderedLayerContent(sub)) {
            CGRect r = [slider.layer convertRect:sub.bounds fromLayer:sub];
            if (isValidTrackCandidate(r, sliderW, expectedMidY, sub.cornerRadius)) {
                [outRects addObject:[NSValue valueWithCGRect:r]];
            }
        }
        collectLayerTrackCandidates(sub, slider, expectedMidY, depth + 1, outRects);
    }
}

static void collectLeafTrackCandidates(UIView *view,
                                       UIView *slider,
                                       CGFloat expectedMidY,
                                       NSUInteger depth,
                                       NSMutableArray<NSValue *> *outRects) {
    if (!view || depth > 8 || outRects.count >= 32) return;
    CGFloat sliderW = slider.bounds.size.width;
    for (UIView *sub in view.subviews) {
        if (sub.hidden || sub.alpha <= 0.01 || sub.layer.hidden || sub.layer.opacity <= 0.01 || isThumbView(sub)) continue;
        CGRect r = renderedTrackRectForSubview(sub, slider);
        if (hasRenderedTrackContent(sub) &&
            isValidTrackCandidate(r, sliderW, expectedMidY, sub.layer.cornerRadius)) {
            [outRects addObject:[NSValue valueWithCGRect:r]];
        }
        collectLeafTrackCandidates(sub, slider, expectedMidY, depth + 1, outRects);
    }
}

static CGFloat trackCandidateScore(CGRect r, CGFloat expectedMidY, CGFloat targetHeight) {
    return fabs(r.size.height - targetHeight) * 6.0 + fabs(CGRectGetMidY(r) - expectedMidY) * 2.0;
}

static CGRect selectBestTrackCandidate(NSArray<NSValue *> *candidates,
                                       CGFloat sliderW,
                                       CGFloat expectedMidY,
                                       CGFloat targetHeight,
                                       BOOL *foundOut) {
    BOOL foundBest = NO;
    CGRect bestRect = CGRectZero;
    CGFloat bestScore = CGFLOAT_MAX;

    for (NSValue *val in candidates) {
        CGRect r = val.CGRectValue;
        if (r.size.width < sliderW - 16.0) continue;
        CGFloat score = trackCandidateScore(r, expectedMidY, targetHeight);
        if (!foundBest || score < bestScore) {
            foundBest = YES;
            bestRect = r;
            bestScore = score;
        }
    }

    // UIKit often splits the slider track into min/max segments on either side of the thumb.
    for (NSUInteger i = 0; i < candidates.count; i++) {
        CGRect a = candidates[i].CGRectValue;
        for (NSUInteger j = i + 1; j < candidates.count; j++) {
            CGRect b = candidates[j].CGRectValue;
            if (fabs(CGRectGetMidY(a) - CGRectGetMidY(b)) > 1.0) continue;
            if (fabs(a.size.height - b.size.height) > 1.0) continue;
            if (CGRectGetMaxX(a) > CGRectGetMinX(b) + 8.0 &&
                CGRectGetMaxX(b) > CGRectGetMinX(a) + 8.0) continue;
            CGRect combined = CGRectUnion(a, b);
            if (combined.size.height >= kMinTrackHeight && combined.size.height <= kMaxTrackHeight &&
                combined.size.width >= sliderW - 16.0 &&
                a.size.width + b.size.width >= combined.size.width - 32.0) {
                CGFloat score = trackCandidateScore(combined, expectedMidY, targetHeight);
                if (!foundBest || score < bestScore) {
                    foundBest = YES;
                    bestRect = combined;
                    bestScore = score;
                }
            }
        }
    }

    if (foundOut) *foundOut = foundBest;
    return bestRect;
}

static BOOL isValidBufferingFrame(CGRect bf, CGFloat sliderW, CGFloat expectedMidY, CGFloat maxMidYDelta) {
    return isFiniteRect(bf) &&
           bf.size.height >= kMinTrackHeight && bf.size.height <= kMaxTrackHeight &&
           bf.size.width >= sliderW - 12.0 &&
           bf.origin.x >= -1.0 && bf.origin.x <= 10.0 &&
           CGRectGetMaxX(bf) <= sliderW + 1.0 &&
           fabs(CGRectGetMidY(bf) - expectedMidY) <= maxMidYDelta;
}

// ProgressBar6Slider carries a UIKit slider visual element (_UISlideriOSVisualElement or iOS 26
// _UISliderFluidVisualElement) and SliderBufferingAnimationView. Spotify's trackRectForBounds:
// computes y = superRect.minY + (superRect.height - targetHeight) without halving the height delta,
// which shifts tr.origin.y (and bufferingView.frame) upward relative to the centered iOS 26 fluid track.
// Prefer rendered track views/layers inside the visual element centered near slider.bounds.midY,
// then centered bufferingView, falling back to tr's horizontal bounds + height centered in slider.bounds.
static CGRect resolveTrackFrame(UIView *slider, UIView *bufferingView, UIView *visualElement, BOOL *usedRenderedTrack) {
    if (usedRenderedTrack) *usedRenderedTrack = NO;
    if (!slider || slider.bounds.size.width <= 0 || slider.bounds.size.height <= 0) {
        return CGRectZero;
    }
    CGFloat sliderW = slider.bounds.size.width;
    CGFloat sliderH = slider.bounds.size.height;
    CGFloat expectedMidY = CGRectGetMidY(slider.bounds);
    BOOL isHighlighted = [slider isKindOfClass:UISlider.class] &&
                         (((UISlider *)slider).highlighted || ((UISlider *)slider).tracking);

    CGRect tr = CGRectZero;
    BOOL hasHorizontalTr = NO;
    CGFloat targetHeight = isHighlighted ? kExpandedTrackHeight : kDefaultTrackHeight;
    if ([slider isKindOfClass:UISlider.class]) {
        tr = [(UISlider *)slider trackRectForBounds:slider.bounds];
        if (isFiniteRect(tr) &&
            tr.size.width >= sliderW - 16.0 &&
            tr.origin.x >= -16.0 && CGRectGetMaxX(tr) <= sliderW + 16.0) {
            hasHorizontalTr = YES;
        }
        if (isFiniteRect(tr) && tr.size.height >= kMinTrackHeight && tr.size.height <= kMaxTrackHeight) {
            targetHeight = tr.size.height;
        }
    }

    if (visualElement && visualElement.superview == slider) {
        NSMutableArray<NSValue *> *viewCandidates = [NSMutableArray array];
        collectLeafTrackCandidates(visualElement, slider, expectedMidY, 0, viewCandidates);
        BOOL foundBest = NO;
        CGRect bestRect = selectBestTrackCandidate(viewCandidates, sliderW, expectedMidY, targetHeight, &foundBest);
        if (!foundBest) {
            NSMutableArray<NSValue *> *layerCandidates = [NSMutableArray array];
            collectLayerTrackCandidates(visualElement.layer, slider, expectedMidY, 0, layerCandidates);
            bestRect = selectBestTrackCandidate(layerCandidates, sliderW, expectedMidY, targetHeight, &foundBest);
        }
        if (foundBest) {
            if (usedRenderedTrack) *usedRenderedTrack = YES;
            return bestRect;
        }
    }

    if (bufferingView && bufferingView.superview == slider) {
        CGRect bf = bufferingView.frame;
        if (isValidBufferingFrame(bf, sliderW, expectedMidY, 1.5)) {
            if (usedRenderedTrack) *usedRenderedTrack = YES;
            return bf;
        }
    }

    CGFloat x = hasHorizontalTr ? tr.origin.x : kDefaultTrackInset;
    CGFloat w = hasHorizontalTr ? tr.size.width : MAX(0.0, sliderW - kDefaultTrackInset * 2.0);
    CGFloat h = MIN(targetHeight, sliderH);
    CGFloat y = MAX(0.0, MIN(sliderH - h, expectedMidY - h / 2.0));
    return CGRectMake(x, y, w, h);
}

static UIView *overlayAnchor(UIView *slider, UIView *bufferingView, UIView *visualElement) {
    if (bufferingView && visualElement) {
        NSUInteger bIdx = [slider.subviews indexOfObjectIdenticalTo:bufferingView];
        NSUInteger vIdx = [slider.subviews indexOfObjectIdenticalTo:visualElement];
        return (bIdx != NSNotFound && vIdx != NSNotFound && bIdx > vIdx) ? bufferingView : visualElement;
    }
    return bufferingView ?: visualElement;
}

+ (void)updateSlider:(UIView *)slider animateHeightChange:(BOOL)animateHeightChange {
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

    UIView *bufferingView = container.cachedTrackView;
    UIView *visualElement = container.cachedVisualElement;
    if (!container || !container.didScanSubviews ||
        (bufferingView && bufferingView.superview != slider) ||
        (visualElement && visualElement.superview != slider)) {
        bufferingView = nil;
        visualElement = nil;
        for (UIView *sv in slider.subviews) {
            if (sv == container) continue;
            if (SGClassNamed(sv.class, @"SliderBufferingAnimationView")) {
                bufferingView = sv;
            } else if (isVisualElementView(sv)) {
                visualElement = sv;
            }
        }
        if (container) {
            container.cachedTrackView = bufferingView;
            container.cachedVisualElement = visualElement;
            container.didScanSubviews = (visualElement != nil && bufferingView != nil);
            UIView *anchor = overlayAnchor(slider, bufferingView, visualElement);
            if (anchor) {
                NSUInteger containerIdx = [slider.subviews indexOfObjectIdenticalTo:container];
                NSUInteger anchorIdx = [slider.subviews indexOfObjectIdenticalTo:anchor];
                if (containerIdx != NSNotFound && anchorIdx != NSNotFound && containerIdx < anchorIdx) {
                    [slider insertSubview:container aboveSubview:anchor];
                }
            }
        }
    }

    BOOL usedRenderedTrack = NO;
    CGRect trackFrame = resolveTrackFrame(slider, bufferingView, visualElement, &usedRenderedTrack);
    if (trackFrame.size.width <= 0 || trackFrame.size.height <= 0) return;

    BOOL needsRebuild = (!container ||
                         container.needsRebuild ||
                         container.cachedRawSegments != segments ||
                         ![container.cachedEpisodeID isEqualToString:episodeID] ||
                         fabs(container.cachedDuration - duration) > 0.001);

    BOOL frameChanged = container && !CGRectEqualToRect(container.frame, trackFrame);
    if (!needsRebuild) {
        if (frameChanged) {
            BOOL heightChanged = fabs(container.frame.size.height - trackFrame.size.height) > 0.5;
            if (animateHeightChange && heightChanged && UIView.inheritedAnimationDuration <= 0.0) {
                [UIView animateWithDuration:0.15
                                      delay:0
                                    options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                                 animations:^{
                    [container layoutSegmentsForTrackFrame:trackFrame];
                } completion:nil];
            } else {
                [container layoutSegmentsForTrackFrame:trackFrame];
            }
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
            container = [[SGSponsorBlockOverlayContainer alloc] initWithFrame:trackFrame];
            container.userInteractionEnabled = NO;
            container.backgroundColor = [UIColor clearColor];
            container.cachedTrackView = bufferingView;
            container.cachedVisualElement = visualElement;
            container.didScanSubviews = (visualElement != nil && bufferingView != nil);
            UIView *anchor = overlayAnchor(slider, bufferingView, visualElement);
            if (anchor) {
                [slider insertSubview:container aboveSubview:anchor];
            } else {
                [slider addSubview:container];
            }
        }
        container.cachedRawSegments = segments;
        [container rebuildWithSegments:visible duration:duration episodeID:episodeID trackFrame:trackFrame];
        frameChanged = YES;
    }

    BOOL prevUsedRendered = container.usedRenderedTrack;
    container.usedRenderedTrack = usedRenderedTrack;

    BOOL curHighlighted = [slider isKindOfClass:UISlider.class] &&
                          (((UISlider *)slider).highlighted || ((UISlider *)slider).tracking);
    BOOL highlightedChanged = (container.lastHighlighted != curHighlighted);
    container.lastHighlighted = curHighlighted;

    // Visual elements lay out their child track views after ProgressBar6Slider -layoutSubviews returns;
    // schedule one post-layout pass whenever on screen and the overlay was just placed/resized,
    // highlight/tracking state toggled, or slider bounds changed.
    BOOL boundsChanged = !CGRectEqualToRect(container.lastPostLayoutBounds, slider.bounds);
    if (slider.window && !container.pendingPostLayout &&
        (frameChanged || highlightedChanged || (!usedRenderedTrack && (boundsChanged || prevUsedRendered)))) {
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
                [self updateSlider:s animateHeightChange:YES];
            }
        });
    }
}

@end

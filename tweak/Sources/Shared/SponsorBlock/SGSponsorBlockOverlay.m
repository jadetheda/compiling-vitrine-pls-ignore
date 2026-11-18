// Colored progress-bar segment overlay for SponsorBlock segments.
// Ported from EeveeSpotify Reincarnated (GPL-3.0) and Spot-SponsorBlock-Extension.

#import "SGSponsorBlockOverlay.h"
#import "SGSponsorBlock.h"
#import "SGSponsorBlockSkipper.h"
#import "Core/SGCore.h"

static const CGFloat kMinTrackHeight = 2.0;
static const CGFloat kMaxTrackHeight = 16.0;
static const CGFloat kDefaultTrackHeight = 7.0;
static const CGFloat kExpandedTrackHeight = 12.0;
static const CGFloat kLegacyTrackInset = 3.0;
static const CGFloat kTrackSearchMaxMidYDelta = 16.0;
enum {
    kMaxSearchDepth = 14,
    kMaxCandidates = 64,
    kMaxPostLayoutRetries = 2,
};

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
@property (nonatomic) NSUInteger postLayoutRetries;
@property (nonatomic) BOOL hasLastMeasuredMidY;
@property (nonatomic) CGFloat lastMeasuredMidY;
@property (nonatomic) CGFloat lastMeasuredBoundsHeight;
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

static BOOL isFluidSlider(UIView *visualElement) {
    if (visualElement) {
        if (SGClassNamed(visualElement.class, @"_UISliderFluidVisualElement")) return YES;
        if (SGClassNamed(visualElement.class, @"_UISlideriOSVisualElement")) return NO;
        if ([NSStringFromClass(visualElement.class) containsString:@"Fluid"]) return YES;
    }
    return !SGBelowiOS26();
}

static BOOL isThumbName(NSString *name) {
    if (!name.length) return NO;
    return [name containsString:@"Thumb"] ||
           [name containsString:@"Knob"] ||
           [name containsString:@"Grabber"] ||
           [name containsString:@"Handle"] ||
           [name containsString:@"Lens"] ||
           [name containsString:@"Platter"];
}

static BOOL isThumbView(UIView *view) {
    return isThumbName(NSStringFromClass(view.class));
}

static BOOL isThumbLayer(CALayer *layer) {
    if ([layer.delegate isKindOfClass:UIView.class] && isThumbView((UIView *)layer.delegate)) {
        return YES;
    }
    return isThumbName(NSStringFromClass(layer.class)) || isThumbName(layer.name);
}

static BOOL isColorVisible(CGColorRef color) {
    return color != NULL && CGColorGetAlpha(color) > 0.01;
}

static BOOL isDirectRenderedLayer(CALayer *layer) {
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
    if (layer.compositingFilter != nil || layer.filters.count > 0 || layer.backgroundFilters.count > 0) {
        return YES;
    }
    NSString *name = NSStringFromClass(layer.class);
    return [name containsString:@"Backdrop"];
}

static BOOL hasRenderedDescendantLayer(CALayer *layer, NSUInteger depth) {
    if (!layer || depth > 4) return NO;
    for (CALayer *sub in layer.sublayers) {
        if (sub.hidden || sub.opacity <= 0.01 || isThumbLayer(sub)) continue;
        if (isDirectRenderedLayer(sub)) return YES;
        if (hasRenderedDescendantLayer(sub, depth + 1)) return YES;
    }
    return NO;
}

static BOOL hasRenderedLayerContent(CALayer *layer, BOOL *isSolidOut) {
    if (isSolidOut) *isSolidOut = NO;
    if (!layer || layer.hidden || layer.opacity <= 0.01) return NO;
    if (isDirectRenderedLayer(layer)) {
        if (isSolidOut) {
            *isSolidOut = (isColorVisible(layer.backgroundColor) ||
                           layer.contents != nil ||
                           [layer isKindOfClass:CAShapeLayer.class] ||
                           [layer isKindOfClass:CAGradientLayer.class]);
        }
        return YES;
    }
    CGFloat h = layer.bounds.size.height;
    if (layer.masksToBounds && h >= kMinTrackHeight && h <= kMaxTrackHeight &&
        layer.cornerRadius >= MAX(1.5, h * 0.35) &&
        hasRenderedDescendantLayer(layer, 0)) {
        return YES;
    }
    return NO;
}

static BOOL hasRenderedTrackContent(UIView *view, BOOL *isSolidOut) {
    if (isSolidOut) *isSolidOut = NO;
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image != nil) {
        if (isSolidOut) *isSolidOut = YES;
        return YES;
    }
    if ([view isKindOfClass:UIVisualEffectView.class]) {
        return YES;
    }
    if (view.backgroundColor && isColorVisible(view.backgroundColor.CGColor)) {
        if (isSolidOut) *isSolidOut = YES;
        return YES;
    }
    return hasRenderedLayerContent(view.layer, isSolidOut);
}

static CGRect renderedTrackRectForSubview(UIView *sub, UIView *slider) {
    CGRect r = [slider convertRect:sub.bounds fromView:sub];
    if ([sub isKindOfClass:UIImageView.class]) {
        UIImage *img = ((UIImageView *)sub).image;
        CGFloat boundsH = sub.bounds.size.height;
        if (img && img.size.height > 0 && boundsH > 0 && img.size.height < boundsH - 0.5 &&
            (sub.contentMode == UIViewContentModeCenter || sub.contentMode == UIViewContentModeScaleAspectFit)) {
            CGFloat scaledH = img.size.height * (r.size.height / boundsH);
            r.origin.y = CGRectGetMidY(r) - scaledH / 2.0;
            r.size.height = scaledH;
        }
    }
    return r;
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

typedef struct {
    CGRect rect;
    BOOL isSolid;
    BOOL isShiftedTr;
} SGTrackCandidate;

typedef struct {
    CGFloat sliderW;
    CGFloat trackMinX;
    CGFloat trackMaxX;
    CGFloat trackWidth;
    CGFloat referenceMidY;
    CGFloat visualMidY;
    BOOL isFluid;
    CGRect tr;
    BOOL hasTr;
    BOOL trIsShifted;
    BOOL isHighlighted;
    CGFloat targetHeight;
} SGTrackSearchContext;

static BOOL isShiftedTrackRectArtifact(CGRect r, const SGTrackSearchContext *ctx) {
    if (!ctx->isFluid || !ctx->hasTr || !ctx->trIsShifted) return NO;
    return fabs(CGRectGetMidY(r) - CGRectGetMidY(ctx->tr)) <= 0.75 &&
           fabs(r.size.height - ctx->tr.size.height) <= 0.75;
}

static BOOL isValidTrackCandidate(CGRect r,
                                  const SGTrackSearchContext *ctx,
                                  CGFloat cornerRadius) {
    if (!isFiniteRect(r)) return NO;
    if (r.size.height < kMinTrackHeight || r.size.height > kMaxTrackHeight || r.size.width < 2.0) {
        return NO;
    }
    BOOL leftAnchored = fabs(r.origin.x - ctx->trackMinX) <= 10.0;
    BOOL allowSmallLeftCap = leftAnchored &&
                             (ctx->isFluid || r.size.width > r.size.height + 4.0 || r.size.height <= kDefaultTrackHeight + 1.5);
    BOOL thumbSized = (!allowSmallLeftCap &&
                       r.size.width <= r.size.height + 4.0 &&
                       r.size.width < ctx->sliderW * 0.25 &&
                       cornerRadius >= r.size.height * 0.4 &&
                       r.size.height >= 9.0);
    if (thumbSized) return NO;

    CGFloat midY = CGRectGetMidY(r);
    if (fabs(midY - ctx->referenceMidY) > kTrackSearchMaxMidYDelta &&
        fabs(midY - ctx->visualMidY) > kTrackSearchMaxMidYDelta) {
        return NO;
    }
    return r.origin.x >= ctx->trackMinX - 16.0 && CGRectGetMaxX(r) <= ctx->trackMaxX + 16.0;
}

static void appendTrackCandidate(SGTrackCandidate *candidates,
                                 NSUInteger *count,
                                 CGRect r,
                                 BOOL isSolid,
                                 const SGTrackSearchContext *ctx) {
    if (*count >= kMaxCandidates) return;
    candidates[*count] = (SGTrackCandidate){
        .rect = r,
        .isSolid = isSolid,
        .isShiftedTr = isShiftedTrackRectArtifact(r, ctx),
    };
    (*count)++;
}

static void collectLayerTrackCandidates(CALayer *layer,
                                        UIView *slider,
                                        const SGTrackSearchContext *ctx,
                                        NSUInteger depth,
                                        SGTrackCandidate *candidates,
                                        NSUInteger *count) {
    if (!layer || depth > kMaxSearchDepth || *count >= kMaxCandidates) return;
    for (CALayer *sub in layer.sublayers) {
        if (sub.hidden || sub.opacity <= 0.01 || isThumbLayer(sub)) continue;
        BOOL isSolid = NO;
        if (hasRenderedLayerContent(sub, &isSolid)) {
            CGRect r = [slider.layer convertRect:sub.bounds fromLayer:sub];
            if (isValidTrackCandidate(r, ctx, sub.cornerRadius)) {
                appendTrackCandidate(candidates, count, r, isSolid, ctx);
            }
        }
        collectLayerTrackCandidates(sub, slider, ctx, depth + 1, candidates, count);
    }
}

static void collectLeafTrackCandidates(UIView *view,
                                       UIView *slider,
                                       const SGTrackSearchContext *ctx,
                                       NSUInteger depth,
                                       SGTrackCandidate *candidates,
                                       NSUInteger *count) {
    if (!view || depth > kMaxSearchDepth || *count >= kMaxCandidates) return;
    for (UIView *sub in view.subviews) {
        if (sub.hidden || sub.alpha <= 0.01 || sub.layer.hidden || sub.layer.opacity <= 0.01 || isThumbView(sub)) {
            continue;
        }
        BOOL isSolid = NO;
        if (hasRenderedTrackContent(sub, &isSolid)) {
            CGRect r = renderedTrackRectForSubview(sub, slider);
            if (isValidTrackCandidate(r, ctx, sub.layer.cornerRadius)) {
                appendTrackCandidate(candidates, count, r, isSolid, ctx);
            }
        }
        collectLeafTrackCandidates(sub, slider, ctx, depth + 1, candidates, count);
    }
}

static CGFloat trackCandidateScore(CGRect r,
                                   BOOL isSolid,
                                   BOOL isShiftedTr,
                                   const SGTrackSearchContext *ctx) {
    CGFloat score = fabs(r.size.height - ctx->targetHeight) * 6.0 +
                    fabs(CGRectGetMidY(r) - ctx->referenceMidY) * 2.0;
    if (!isSolid) score += 1.5;
    if (isShiftedTr) score += 200.0;
    return score;
}

static BOOL isMatchingTargetHeight(CGFloat h, const SGTrackSearchContext *ctx) {
    if (!ctx->isFluid) return YES;
    if (ctx->isHighlighted) {
        return h >= kExpandedTrackHeight - 1.5;
    }
    return h <= kDefaultTrackHeight + 1.5;
}

static CGRect selectBestTrackCandidate(const SGTrackCandidate *candidates,
                                       NSUInteger count,
                                       const SGTrackSearchContext *ctx,
                                       BOOL *foundFullOut,
                                       BOOL *foundAnyRenderedOut,
                                       CGFloat *measuredMidYOut) {
    BOOL foundBestFull = NO;
    CGRect bestFullRect = CGRectZero;
    CGFloat bestFullScore = CGFLOAT_MAX;

    CGFloat fullMinWidth = MAX(8.0, ctx->trackWidth - 20.0);

    // 1. Full-width rendered track candidates.
    for (NSUInteger i = 0; i < count; i++) {
        SGTrackCandidate c = candidates[i];
        if (c.rect.size.width < fullMinWidth) continue;
        if (!isMatchingTargetHeight(c.rect.size.height, ctx)) continue;
        CGFloat score = trackCandidateScore(c.rect, c.isSolid, c.isShiftedTr, ctx);
        if (!foundBestFull || score < bestFullScore) {
            foundBestFull = YES;
            bestFullRect = c.rect;
            bestFullScore = score;
        }
    }

    // 2. Split min/max track segments flanking the thumb.
    for (NSUInteger i = 0; i < count; i++) {
        SGTrackCandidate a = candidates[i];
        for (NSUInteger j = i + 1; j < count; j++) {
            SGTrackCandidate b = candidates[j];
            if (fabs(CGRectGetMidY(a.rect) - CGRectGetMidY(b.rect)) > 1.0) continue;
            if (fabs(a.rect.size.height - b.rect.size.height) > 1.0) continue;
            if (CGRectGetMaxX(a.rect) > CGRectGetMinX(b.rect) + 8.0 &&
                CGRectGetMaxX(b.rect) > CGRectGetMinX(a.rect) + 8.0) {
                continue;
            }
            CGRect combined = CGRectUnion(a.rect, b.rect);
            if (combined.size.height >= kMinTrackHeight &&
                combined.size.height <= kMaxTrackHeight &&
                combined.size.width >= fullMinWidth &&
                a.rect.size.width + b.rect.size.width >= combined.size.width - 32.0 &&
                isMatchingTargetHeight(combined.size.height, ctx)) {
                CGFloat score = trackCandidateScore(combined,
                                                    a.isSolid && b.isSolid,
                                                    a.isShiftedTr || b.isShiftedTr,
                                                    ctx);
                if (!foundBestFull || score < bestFullScore) {
                    foundBestFull = YES;
                    bestFullRect = combined;
                    bestFullScore = score;
                }
            }
        }
    }

    // 3. Left-anchored fill bar (e.g. elapsed white fill): exact rendered y + height even when max track uses a private glass layer.
    BOOL foundFill = NO;
    CGRect bestFillRect = CGRectZero;
    CGFloat bestFillScore = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < count; i++) {
        SGTrackCandidate c = candidates[i];
        if (c.isShiftedTr) continue;
        if (fabs(c.rect.origin.x - ctx->trackMinX) > 10.0) continue;
        if (!isMatchingTargetHeight(c.rect.size.height, ctx)) continue;
        CGFloat score = trackCandidateScore(c.rect, c.isSolid, NO, ctx);
        if (!foundFill || score < bestFillScore) {
            foundFill = YES;
            bestFillRect = c.rect;
            bestFillScore = score;
        }
    }

    BOOL preferFill = foundFill && (!foundBestFull || bestFullScore > bestFillScore + 4.0);
    if (preferFill || foundBestFull) {
        CGRect chosen = preferFill
            ? CGRectMake(ctx->trackMinX, bestFillRect.origin.y, ctx->trackWidth, bestFillRect.size.height)
            : bestFullRect;
        if (foundFullOut) *foundFullOut = YES;
        if (foundAnyRenderedOut) *foundAnyRenderedOut = YES;
        if (measuredMidYOut) *measuredMidYOut = CGRectGetMidY(chosen);
        return chosen;
    }

    // 4. Stale-height rendered bar during highlight transition: borrow its live measured midY for targetHeight.
    BOOL foundStale = NO;
    CGRect bestStaleRect = CGRectZero;
    CGFloat bestStaleScore = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < count; i++) {
        SGTrackCandidate c = candidates[i];
        if (c.isShiftedTr) continue;
        BOOL isSpanOrLeftFill = (c.rect.size.width >= fullMinWidth || fabs(c.rect.origin.x - ctx->trackMinX) <= 10.0);
        if (!isSpanOrLeftFill) continue;
        CGFloat score = fabs(CGRectGetMidY(c.rect) - ctx->referenceMidY) * 2.0 +
                        (c.rect.size.width >= fullMinWidth ? 0.0 : 4.0) +
                        (c.isSolid ? 0.0 : 2.0);
        if (!foundStale || score < bestStaleScore) {
            foundStale = YES;
            bestStaleRect = c.rect;
            bestStaleScore = score;
        }
    }

    if (foundFullOut) *foundFullOut = NO;
    if (foundAnyRenderedOut) *foundAnyRenderedOut = foundStale;
    if (measuredMidYOut) *measuredMidYOut = foundStale ? CGRectGetMidY(bestStaleRect) : ctx->referenceMidY;
    return bestStaleRect;
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
// shifting tr.origin.y (and bufferingView.frame) upward relative to UIKit's rendered track.
// Measure the rendered track/fill layers directly inside visualElement in slider coordinates; if
// visualElement hasn't finished laying out a height transition yet, center targetHeight on the live
// rendered bar's midY or UIKit's [UISlider trackRectForBounds:] IMP.
static CGRect resolveTrackFrame(UIView *slider,
                                UIView *bufferingView,
                                UIView *visualElement,
                                SGSponsorBlockOverlayContainer *container,
                                BOOL *usedRenderedTrack,
                                BOOL *measuredMidYValid,
                                CGFloat *measuredMidYOut) {
    if (usedRenderedTrack) *usedRenderedTrack = NO;
    if (measuredMidYValid) *measuredMidYValid = NO;
    if (!slider || slider.bounds.size.width <= 0 || slider.bounds.size.height <= 0) {
        return CGRectZero;
    }

    CGFloat sliderW = slider.bounds.size.width;
    CGFloat sliderH = slider.bounds.size.height;
    CGFloat boundsMidY = CGRectGetMidY(slider.bounds);
    BOOL isHighlighted = [slider isKindOfClass:UISlider.class] && ((UISlider *)slider).highlighted;
    BOOL isFluid = isFluidSlider(visualElement);

    CGRect tr = CGRectZero;
    CGRect superRect = CGRectZero;
    BOOL hasTr = NO;
    BOOL hasSuper = NO;
    BOOL hasHorizontalTr = NO;
    BOOL hasHorizontalSuper = NO;
    CGFloat targetHeight = isHighlighted ? kExpandedTrackHeight : kDefaultTrackHeight;

    if ([slider isKindOfClass:UISlider.class]) {
        UISlider *uiSlider = (UISlider *)slider;
        tr = [uiSlider trackRectForBounds:slider.bounds];
        hasTr = isFiniteRect(tr) && tr.size.width > 0 && tr.size.height > 0;
        hasHorizontalTr = hasTr && tr.size.width >= sliderW - 24.0 &&
                          tr.origin.x >= -16.0 && CGRectGetMaxX(tr) <= sliderW + 16.0;

        superRect = superTrackRectForSlider(uiSlider, slider.bounds);
        hasSuper = isFiniteRect(superRect) && superRect.size.width > 0 && superRect.size.height > 0;
        hasHorizontalSuper = hasSuper && superRect.size.width >= sliderW - 24.0 &&
                             superRect.origin.x >= -16.0 && CGRectGetMaxX(superRect) <= sliderW + 16.0;

        if (hasTr && !isFluid && tr.size.height >= kMinTrackHeight && tr.size.height <= kMaxTrackHeight) {
            targetHeight = tr.size.height;
        }
    }

    CGFloat fallbackInset = isFluid ? 0.0 : kLegacyTrackInset;
    CGFloat trackMinX = hasHorizontalTr ? tr.origin.x
                      : (hasHorizontalSuper ? superRect.origin.x : fallbackInset);
    CGFloat trackWidth = hasHorizontalTr ? tr.size.width
                       : (hasHorizontalSuper ? superRect.size.width : MAX(0.0, sliderW - fallbackInset * 2.0));
    CGFloat referenceMidY = hasSuper ? CGRectGetMidY(superRect) : boundsMidY;
    CGFloat visualMidY = (visualElement && visualElement.superview == slider) ? CGRectGetMidY(visualElement.frame) : referenceMidY;
    BOOL trIsShifted = hasTr && (fabs(CGRectGetMidY(tr) - referenceMidY) > 0.75);

    if (visualElement && visualElement.superview == slider) {
        SGTrackSearchContext ctx = {
            .sliderW = sliderW,
            .trackMinX = trackMinX,
            .trackMaxX = trackMinX + trackWidth,
            .trackWidth = trackWidth,
            .referenceMidY = referenceMidY,
            .visualMidY = visualMidY,
            .isFluid = isFluid,
            .tr = tr,
            .hasTr = hasTr,
            .trIsShifted = trIsShifted,
            .isHighlighted = isHighlighted,
            .targetHeight = targetHeight,
        };

        SGTrackCandidate viewCandidates[kMaxCandidates];
        NSUInteger viewCount = 0;
        collectLeafTrackCandidates(visualElement, slider, &ctx, 0, viewCandidates, &viewCount);
        BOOL foundFullView = NO;
        BOOL foundStaleView = NO;
        CGFloat viewMidY = referenceMidY;
        CGRect bestView = selectBestTrackCandidate(viewCandidates, viewCount, &ctx, &foundFullView, &foundStaleView, &viewMidY);

        SGTrackCandidate layerCandidates[kMaxCandidates];
        NSUInteger layerCount = 0;
        BOOL foundFullLayer = NO;
        BOOL foundStaleLayer = NO;
        CGFloat layerMidY = referenceMidY;
        CGRect bestLayer = CGRectZero;
        if (!foundFullView || isFluid) {
            collectLayerTrackCandidates(visualElement.layer, slider, &ctx, 0, layerCandidates, &layerCount);
            bestLayer = selectBestTrackCandidate(layerCandidates, layerCount, &ctx, &foundFullLayer, &foundStaleLayer, &layerMidY);
        }

        if (foundFullView || foundFullLayer) {
            CGRect chosen = CGRectZero;
            if (foundFullView && foundFullLayer) {
                CGFloat viewScore = trackCandidateScore(bestView, YES, NO, &ctx);
                CGFloat layerScore = trackCandidateScore(bestLayer, YES, NO, &ctx);
                chosen = (layerScore + 0.01 < viewScore) ? bestLayer : bestView;
            } else {
                chosen = foundFullView ? bestView : bestLayer;
            }
            if (usedRenderedTrack) *usedRenderedTrack = YES;
            if (measuredMidYValid) *measuredMidYValid = YES;
            if (measuredMidYOut) *measuredMidYOut = CGRectGetMidY(chosen);
            return chosen;
        }

        if (foundStaleView || foundStaleLayer) {
            CGFloat midY = foundStaleLayer ? layerMidY : viewMidY;
            if (measuredMidYValid) *measuredMidYValid = YES;
            if (measuredMidYOut) *measuredMidYOut = midY;
            return CGRectMake(trackMinX, midY - targetHeight / 2.0, trackWidth, targetHeight);
        }
    }

    if (!isFluid && bufferingView && bufferingView.superview == slider) {
        CGRect bf = bufferingView.frame;
        if (isValidBufferingFrame(bf, sliderW, referenceMidY, 5.5)) {
            if (usedRenderedTrack) *usedRenderedTrack = YES;
            if (measuredMidYValid) *measuredMidYValid = YES;
            if (measuredMidYOut) *measuredMidYOut = CGRectGetMidY(bf);
            return bf;
        }
    }

    CGFloat fallbackMidY = referenceMidY;
    if (container && container.hasLastMeasuredMidY &&
        fabs(container.lastMeasuredBoundsHeight - sliderH) <= 0.5) {
        fallbackMidY = container.lastMeasuredMidY;
    }

    CGFloat h = slider.clipsToBounds ? MIN(targetHeight, sliderH) : targetHeight;
    CGFloat y = fallbackMidY - h / 2.0;
    if (slider.clipsToBounds) {
        y = MAX(0.0, MIN(sliderH - h, y));
    }
    return CGRectMake(trackMinX, y, trackWidth, h);
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
    BOOL measuredMidYValid = NO;
    CGFloat measuredMidY = 0;
    CGRect trackFrame = resolveTrackFrame(slider, bufferingView, visualElement, container,
                                          &usedRenderedTrack, &measuredMidYValid, &measuredMidY);
    if (trackFrame.size.width <= 0 || trackFrame.size.height <= 0) return;

    BOOL curHighlighted = [slider isKindOfClass:UISlider.class] && ((UISlider *)slider).highlighted;
    BOOL highlightedChanged = container && (container.lastHighlighted != curHighlighted);

    BOOL needsRebuild = (!container ||
                         container.needsRebuild ||
                         container.cachedRawSegments != segments ||
                         ![container.cachedEpisodeID isEqualToString:episodeID] ||
                         fabs(container.cachedDuration - duration) > 0.001);

    BOOL frameChanged = container && !CGRectEqualToRect(container.frame, trackFrame);
    if (!needsRebuild) {
        if (frameChanged) {
            BOOL heightChanged = fabs(container.frame.size.height - trackFrame.size.height) > 0.5;
            if ((animateHeightChange || highlightedChanged) && heightChanged && UIView.inheritedAnimationDuration <= 0.0) {
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

    if (measuredMidYValid) {
        container.hasLastMeasuredMidY = YES;
        container.lastMeasuredMidY = measuredMidY;
        container.lastMeasuredBoundsHeight = slider.bounds.size.height;
    }

    BOOL prevUsedRendered = container.usedRenderedTrack;
    container.usedRenderedTrack = usedRenderedTrack;
    container.lastHighlighted = curHighlighted;

    BOOL boundsChanged = !CGRectEqualToRect(container.lastPostLayoutBounds, slider.bounds);
    if (usedRenderedTrack || highlightedChanged || boundsChanged) {
        container.postLayoutRetries = 0;
    }

    // Visual elements lay out their child track views after ProgressBar6Slider -layoutSubviews returns;
    // schedule a post-layout pass whenever on screen and the overlay was just placed/resized,
    // highlight state toggled, or visualElement hasn't finished laying out the target height yet.
    BOOL shouldSchedulePostLayout = (frameChanged ||
                                     highlightedChanged ||
                                     (!usedRenderedTrack && (boundsChanged || prevUsedRendered || container.postLayoutRetries < kMaxPostLayoutRetries)));
    if (slider.window && !container.pendingPostLayout && shouldSchedulePostLayout) {
        if (!usedRenderedTrack && !highlightedChanged && !boundsChanged && !prevUsedRendered) {
            container.postLayoutRetries++;
        }
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

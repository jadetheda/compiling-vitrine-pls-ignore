// Colored progress-bar segment overlay for SponsorBlock segments.
// Ported from EeveeSpotify Reincarnated (GPL-3.0) and Spot-SponsorBlock-Extension.

#import "SGSponsorBlockOverlay.h"
#import "SGSponsorBlock.h"
#import "SGSponsorBlockSkipper.h"
#import "Core/SGCore.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static const CGFloat kMinTrackHeight = 2.0;
static const CGFloat kMaxTrackHeight = 20.0;
static const CGFloat kDefaultTrackHeight = 7.0;
static const CGFloat kExpandedTrackHeight = 12.0;
static const CGFloat kLegacyTrackInset = 3.0;
static const CGFloat kTrackSearchMaxMidYDelta = 16.0;
static const CFTimeInterval kAnimationGraceSeconds = 0.45;
static const CFTimeInterval kAnimationMaxWatchSeconds = 0.85;
static const CFTimeInterval kAnimationMinWatchSeconds = 0.08;
enum {
    kMaxSearchDepth = 14,
    kMaxDescendantDepth = 6,
    kMaxMaskSublayerDepth = 3,
    kMaxCandidates = 128,
    kMaxHookedVisualClasses = 8,
};

@class SGSponsorBlockOverlayContainer;

@interface SGSponsorBlockOverlayContainer : UIView
@property (nonatomic, copy) NSString *cachedEpisodeID;
@property (nonatomic) double cachedDuration;
@property (nonatomic) NSArray<SGSponsorBlockSegment *> *cachedRawSegments;
@property (nonatomic) BOOL needsRebuild;
@property (nonatomic) BOOL didScanSubviews;
@property (nonatomic) BOOL usedRenderedTrack;
@property (nonatomic) BOOL lastHighlighted;
@property (nonatomic) BOOL pendingPostLayout;
@property (nonatomic) BOOL hasLastMeasuredMidY;
@property (nonatomic) CGFloat lastMeasuredMidY;
@property (nonatomic) CGFloat lastMeasuredBoundsHeight;
@property (nonatomic) CGRect lastPostLayoutBounds;
@property (nonatomic, weak) UIView *cachedTrackView;
@property (nonatomic, weak) UIView *cachedVisualElement;
@property (nonatomic, weak) CALayer *trackedLayer;
@property (nonatomic, weak) CALayer *trackedSpanLayer;
@property (nonatomic) BOOL trackedLayerIsLeftFill;
@property (nonatomic) CGFloat fallbackSpanMinX;
@property (nonatomic) CGFloat fallbackSpanWidth;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic) CFTimeInterval watchStartedAt;
@property (nonatomic) CFTimeInterval animationWatchUntil;
@property (nonatomic) CFTimeInterval minWatchUntil;
@property (nonatomic) BOOL didRecheckLayerMidWatch;
@property (nonatomic) NSUInteger settledTickCount;
- (void)rebuildWithSegments:(NSArray<SGSponsorBlockSegment *> *)segments
                   duration:(double)duration
                  episodeID:(NSString *)episodeID
                 trackFrame:(CGRect)trackFrame;
- (void)layoutSegmentsForTrackFrame:(CGRect)trackFrame;
- (void)startAnimationWatchWithMinDuration:(CFTimeInterval)minDuration;
- (void)stopDisplayLink;
@end

@interface SGSponsorBlockOverlayContainer (DisplayLinkSync)
- (void)handleDisplayLinkTick;
@end

@interface SGOverlayDisplayLinkProxy : NSObject
@property (nonatomic, weak) SGSponsorBlockOverlayContainer *owner;
- (void)tick:(CADisplayLink *)link;
@end

@implementation SGOverlayDisplayLinkProxy
- (void)tick:(CADisplayLink *)link {
    SGSponsorBlockOverlayContainer *owner = self.owner;
    if (!owner) {
        [link invalidate];
        return;
    }
    [owner handleDisplayLinkTick];
}
@end

@interface SGSponsorBlockSegmentBar : UIView
@property (nonatomic) CGFloat startRatio;
@property (nonatomic) CGFloat endRatio;
@end

@implementation SGSponsorBlockSegmentBar
@end

@implementation SGSponsorBlockOverlayContainer

- (void)dealloc {
    [_displayLink invalidate];
    _displayLink = nil;
}

- (void)stopDisplayLink {
    if (_displayLink) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
    _settledTickCount = 0;
}

- (void)removeFromSuperview {
    [self stopDisplayLink];
    [super removeFromSuperview];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self stopDisplayLink];
    }
}

- (void)startAnimationWatchWithMinDuration:(CFTimeInterval)minDuration {
    if (!self.window) return;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval watchEnd = now + MAX(kAnimationGraceSeconds, minDuration);
    if (watchEnd > now + kAnimationMaxWatchSeconds) {
        watchEnd = now + kAnimationMaxWatchSeconds;
    }
    if (!_displayLink) {
        _watchStartedAt = now;
        _didRecheckLayerMidWatch = NO;
        SGOverlayDisplayLinkProxy *proxy = [SGOverlayDisplayLinkProxy new];
        proxy.owner = self;
        _displayLink = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(tick:)];
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else if (minDuration > 0.0 || now - _watchStartedAt > kAnimationMaxWatchSeconds) {
        _watchStartedAt = now;
        _didRecheckLayerMidWatch = NO;
    }
    _animationWatchUntil = MAX(_animationWatchUntil, watchEnd);
    _minWatchUntil = MAX(_minWatchUntil, now + minDuration);
    _settledTickCount = 0;
}

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
static BOOL s_updatingFromVisualLayout = NO;
static NSUInteger s_visualLayoutDepth = 0;

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

static BOOL isDescendantLayer(CALayer *layer, CALayer *ancestor, NSUInteger maxHops) {
    for (CALayer *cur = layer; cur && maxHops > 0; cur = cur.superlayer, maxHops--) {
        if (cur == ancestor) return YES;
    }
    return NO;
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
    // iOS 26+ UISlider keeps _UISlideriOSVisualElement for Liquid Glass fluid tracks.
    return !SGBelowiOS26();
}

static BOOL isThumbClass(Class cls) {
    return SGClassNamed(cls, @"Thumb") ||
           SGClassNamed(cls, @"Knob") ||
           SGClassNamed(cls, @"Grabber") ||
           SGClassNamed(cls, @"Handle");
}

static BOOL isThumbLayer(CALayer *layer) {
    if ([layer.delegate isKindOfClass:UIView.class] && isThumbClass(((UIView *)layer.delegate).class)) {
        return YES;
    }
    if (isThumbClass(layer.class)) return YES;
    NSString *name = layer.name;
    return name.length > 0 &&
           ([name containsString:@"Thumb"] ||
            [name containsString:@"Knob"] ||
            [name containsString:@"Grabber"] ||
            [name containsString:@"Handle"]);
}

static BOOL layerMatchesClassOrName(CALayer *layer, NSString *token) {
    if ([layer.delegate isKindOfClass:UIView.class] && SGClassNamed(((UIView *)layer.delegate).class, token)) {
        return YES;
    }
    return SGClassNamed(layer.class, token) ||
           (layer.name.length > 0 && [layer.name containsString:token]);
}

static BOOL isLensView(UIView *view) {
    return SGClassNamed(view.class, @"Lens");
}

static BOOL isLensLayer(CALayer *layer) {
    return layerMatchesClassOrName(layer, @"Lens");
}

static BOOL isLensOrPlatterView(UIView *view) {
    return isLensView(view) || SGClassNamed(view.class, @"Platter");
}

static BOOL isLensOrPlatterLayer(CALayer *layer) {
    return isLensLayer(layer) || layerMatchesClassOrName(layer, @"Platter");
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
    if (layer.borderWidth > 0.25 && isColorVisible(layer.borderColor)) {
        return YES;
    }
    if (layer.compositingFilter != nil || layer.filters.count > 0 || layer.backgroundFilters.count > 0) {
        return YES;
    }
    return SGClassNamed(layer.class, @"Backdrop") ||
           SGClassNamed(layer.class, @"Portal") ||
           SGClassNamed(layer.class, @"Glass") ||
           SGClassNamed(layer.class, @"Fluid") ||
           SGClassNamed(layer.class, @"Material") ||
           SGClassNamed(layer.class, @"Metal");
}

static BOOL hasRenderedDescendantLayer(CALayer *layer, NSUInteger depth) {
    if (!layer || depth > kMaxDescendantDepth) return NO;
    for (CALayer *sub in layer.sublayers) {
        if (sub.hidden || sub.opacity <= 0.01 || isThumbLayer(sub)) continue;
        if (isDirectRenderedLayer(sub)) return YES;
        if ([sub.delegate isKindOfClass:UIVisualEffectView.class]) return YES;
        if (hasRenderedDescendantLayer(sub, depth + 1)) return YES;
    }
    return NO;
}

static BOOL hasRenderedLayerContent(CALayer *layer, CGFloat renderedHeight, BOOL *isSolidOut) {
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
    if (((layer.masksToBounds && renderedHeight >= kMinTrackHeight && renderedHeight <= kMaxTrackHeight &&
          layer.cornerRadius >= MAX(1.5, renderedHeight * 0.35)) ||
         (layer.mask != nil && !layer.mask.hidden && layer.mask.opacity > 0.01)) &&
        hasRenderedDescendantLayer(layer, 0)) {
        return YES;
    }
    return NO;
}

static BOOL viewOverridesDrawRect(UIView *view) {
    static IMP s_uiViewDrawRect = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_uiViewDrawRect = [UIView instanceMethodForSelector:@selector(drawRect:)];
    });
    if (!view || !s_uiViewDrawRect) return NO;
    return [view.class instanceMethodForSelector:@selector(drawRect:)] != s_uiViewDrawRect;
}

static BOOL hasRenderedTrackContent(UIView *view, CGFloat renderedHeight, BOOL *isSolidOut) {
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
    if (viewOverridesDrawRect(view)) {
        if (isSolidOut) *isSolidOut = YES;
        return YES;
    }
    return hasRenderedLayerContent(view.layer, renderedHeight, isSolidOut);
}

static CGRect intersectOptionalClip(CGRect rect, CGRect clipRect) {
    if (CGRectIsNull(rect) || !isFiniteRect(rect)) return CGRectNull;
    if (CGRectIsNull(clipRect)) return rect;
    return CGRectIntersection(rect, clipRect);
}

static CGRect mapRectFromMaskToOwner(CGRect localMask, CALayer *mask) {
    if (!mask || CGRectIsNull(localMask) || !isFiniteRect(localMask)) return CGRectNull;
    CGRect bounds = mask.bounds;
    if (!isFiniteRect(bounds)) return CGRectNull;
    CGPoint anchor = mask.anchorPoint;
    CGPoint pos = mask.position;
    if (!isfinite(anchor.x) || !isfinite(anchor.y) || !isfinite(pos.x) || !isfinite(pos.y)) {
        return CGRectNull;
    }
    CGFloat ax = bounds.origin.x + bounds.size.width * anchor.x;
    CGFloat ay = bounds.origin.y + bounds.size.height * anchor.y;
    CGRect centered = CGRectOffset(localMask, -ax, -ay);
    CATransform3D t3d = mask.transform;
    if (!CATransform3DIsIdentity(t3d) && CATransform3DIsAffine(t3d)) {
        centered = CGRectApplyAffineTransform(centered, CATransform3DGetAffineTransform(t3d));
    }
    CGRect inOwner = CGRectOffset(centered, pos.x, pos.y);
    return isFiniteRect(inOwner) ? inOwner : CGRectNull;
}

static CGRect shapePathContentBox(CAShapeLayer *shape) {
    if (!shape || shape.path == NULL) return CGRectNull;
    CGRect pathBox = CGPathGetPathBoundingBox(shape.path);
    if (!isColorVisible(shape.fillColor) && isColorVisible(shape.strokeColor) && shape.lineWidth > 0) {
        pathBox = CGRectInset(pathBox, -shape.lineWidth / 2.0, -shape.lineWidth / 2.0);
    }
    if (!isFiniteRect(pathBox) || pathBox.size.width <= 0 || pathBox.size.height <= 0) {
        return CGRectNull;
    }
    CGRect bounds = shape.bounds;
    if (shape.masksToBounds && isFiniteRect(bounds) && bounds.size.width > 0 && bounds.size.height > 0) {
        CGRect clipped = CGRectIntersection(bounds, pathBox);
        return (!CGRectIsNull(clipped) && clipped.size.width > 0 && clipped.size.height > 0) ? clipped : CGRectNull;
    }
    return pathBox;
}

static CGRect maskLocalContentRect(CALayer *mask, NSUInteger depth) {
    if (!mask || mask.hidden || mask.opacity <= 0.01) return CGRectNull;
    CGRect bounds = mask.bounds;
    if ([mask isKindOfClass:CAShapeLayer.class]) {
        CGRect pathBox = shapePathContentBox((CAShapeLayer *)mask);
        if (!CGRectIsNull(pathBox)) return pathBox;
    }
    if (!isColorVisible(mask.backgroundColor) && mask.contents == nil &&
        mask.sublayers.count > 0 && depth < kMaxMaskSublayerDepth) {
        CGRect combined = CGRectNull;
        for (CALayer *sub in mask.sublayers) {
            CGRect subRect = maskLocalContentRect(sub, depth + 1);
            if (CGRectIsNull(subRect)) continue;
            CGRect inMask = mapRectFromMaskToOwner(subRect, sub);
            if (!CGRectIsNull(inMask) && inMask.size.width > 0 && inMask.size.height > 0) {
                combined = CGRectIsNull(combined) ? inMask : CGRectUnion(combined, inMask);
            }
        }
        if (!CGRectIsNull(combined)) {
            if (mask.masksToBounds && isFiniteRect(bounds) && bounds.size.width > 0 && bounds.size.height > 0) {
                combined = CGRectIntersection(bounds, combined);
            }
            if (!CGRectIsNull(combined) && combined.size.width > 0 && combined.size.height > 0) {
                return combined;
            }
        }
    }
    return (isFiniteRect(bounds) && bounds.size.width > 0 && bounds.size.height > 0) ? bounds : CGRectNull;
}

static CGRect layerMaskRectInSlider(CALayer *mask, CALayer *ownerLayer, CALayer *sliderLayer) {
    if (!mask || !ownerLayer || !sliderLayer || mask.hidden || mask.opacity <= 0.01) return CGRectNull;
    CGRect localMask = maskLocalContentRect(mask, 0);
    if (CGRectIsNull(localMask) || !isFiniteRect(localMask) || localMask.size.width <= 0 || localMask.size.height <= 0) {
        return CGRectNull;
    }
    CGRect inOwner = mapRectFromMaskToOwner(localMask, mask);
    if (CGRectIsNull(inOwner) || !isFiniteRect(inOwner)) return CGRectNull;
    CGRect converted = [sliderLayer convertRect:inOwner fromLayer:ownerLayer];
    return isFiniteRect(converted) ? converted : CGRectNull;
}

static CGRect localContentRectForLayer(CALayer *srcLayer, CALayer *modelLayer) {
    CGRect localRect = srcLayer.bounds;
    if (!isFiniteRect(localRect)) return CGRectNull;

    if ([srcLayer isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *shape = (CAShapeLayer *)srcLayer;
        if (isColorVisible(shape.fillColor) || isColorVisible(shape.strokeColor)) {
            CGRect pathBox = shapePathContentBox(shape);
            if (!CGRectIsNull(pathBox)) localRect = pathBox;
        }
    } else if (modelLayer && [modelLayer.delegate isKindOfClass:UIImageView.class]) {
        UIImageView *iv = (UIImageView *)modelLayer.delegate;
        UIImage *img = iv.image;
        CGFloat boundsH = localRect.size.height;
        if (img && img.size.height > 0 && boundsH > 0 && img.size.height < boundsH - 0.5 &&
            (iv.contentMode == UIViewContentModeCenter || iv.contentMode == UIViewContentModeScaleAspectFit)) {
            localRect.origin.y = CGRectGetMidY(localRect) - img.size.height / 2.0;
            localRect.size.height = img.size.height;
        }
    }
    return isFiniteRect(localRect) ? localRect : CGRectNull;
}

static CGRect measureLayerInSlider(CALayer *modelLayer, CALayer *sliderLayer, BOOL usePresentation) {
    if (!modelLayer || !sliderLayer) return CGRectNull;
    CALayer *src = modelLayer;
    CALayer *dst = sliderLayer;
    BOOL usingPres = NO;
    if (usePresentation) {
        CALayer *srcPres = modelLayer.presentationLayer;
        CALayer *dstPres = sliderLayer.presentationLayer;
        if (srcPres && dstPres && isDescendantLayer(srcPres, dstPres, kMaxSearchDepth + 8)) {
            src = srcPres;
            dst = dstPres;
            usingPres = YES;
        }
    }

    CGRect localRect = localContentRectForLayer(src, modelLayer);
    if (CGRectIsNull(localRect) || localRect.size.width <= 0 || localRect.size.height <= 0) {
        return CGRectNull;
    }

    CGRect rect = [dst convertRect:localRect fromLayer:src];
    if (!isFiniteRect(rect)) return CGRectNull;

    NSUInteger hops = 0;
    CALayer *modelCur = usingPres ? modelLayer : nil;
    for (CALayer *cur = src; cur && cur != dst && hops < kMaxSearchDepth + 8; cur = cur.superlayer, hops++) {
        if (cur != src && cur.masksToBounds && isFiniteRect(cur.bounds) &&
            cur.bounds.size.width > 0 && cur.bounds.size.height > 0) {
            CGRect clipInSlider = [dst convertRect:cur.bounds fromLayer:cur];
            rect = intersectOptionalClip(rect, clipInSlider);
            if (CGRectIsNull(rect)) return CGRectNull;
        }
        CALayer *effMask = cur.mask ?: (modelCur ? modelCur.mask : nil);
        if (effMask) {
            if (usingPres && effMask.presentationLayer) {
                effMask = effMask.presentationLayer;
            }
            CGRect maskInSlider = layerMaskRectInSlider(effMask, cur, dst);
            if (!CGRectIsNull(maskInSlider)) {
                rect = intersectOptionalClip(rect, maskInSlider);
                if (CGRectIsNull(rect)) return CGRectNull;
            }
        }
        if (modelCur) modelCur = modelCur.superlayer;
    }
    return rect;
}

static CGRect measureTrackFrameFromLayers(CALayer *tracked,
                                          CALayer *span,
                                          BOOL isLeftFill,
                                          CGFloat fallbackSpanMinX,
                                          CGFloat fallbackSpanWidth,
                                          UIView *slider,
                                          BOOL usePresentation) {
    if (!tracked || !slider || tracked.hidden || tracked.opacity <= 0.01 ||
        !isDescendantLayer(tracked, slider.layer, kMaxSearchDepth + 8)) {
        return CGRectNull;
    }
    CGRect measured = measureLayerInSlider(tracked, slider.layer, usePresentation);
    if (CGRectIsNull(measured) || !isFiniteRect(measured) ||
        measured.size.height < kMinTrackHeight || measured.size.height > kMaxTrackHeight) {
        return CGRectNull;
    }
    if (!isLeftFill) {
        return (measured.size.width > 2.0) ? measured : CGRectNull;
    }

    CGFloat x = fallbackSpanMinX;
    CGFloat w = fallbackSpanWidth;
    if (span && span != tracked && !span.hidden && span.opacity > 0.01 &&
        isDescendantLayer(span, slider.layer, kMaxSearchDepth + 8)) {
        CGRect spanRect = measureLayerInSlider(span, slider.layer, usePresentation);
        if (!CGRectIsNull(spanRect) && isFiniteRect(spanRect) &&
            spanRect.size.width >= MAX(8.0, w - 20.0)) {
            x = spanRect.origin.x;
            w = spanRect.size.width;
        }
    }
    return (w > 2.0) ? CGRectMake(x, measured.origin.y, w, measured.size.height) : CGRectNull;
}

static BOOL maskHasActiveAnimations(CALayer *mask, NSUInteger depth) {
    if (!mask || depth > kMaxMaskSublayerDepth) return NO;
    if (mask.animationKeys.count > 0) return YES;
    for (CALayer *sub in mask.sublayers) {
        if (maskHasActiveAnimations(sub, depth + 1)) return YES;
    }
    return NO;
}

static BOOL layerChainHasActiveAnimations(CALayer *layer, CALayer *sliderLayer) {
    if (!layer || !sliderLayer) return NO;
    NSUInteger hops = 0;
    for (CALayer *cur = layer; cur && cur != sliderLayer && hops < kMaxSearchDepth + 8; cur = cur.superlayer, hops++) {
        if (cur.animationKeys.count > 0) return YES;
        if (cur.mask && maskHasActiveAnimations(cur.mask, 0)) return YES;
    }
    return NO;
}

static CGRect nextClipRectForLayer(CALayer *layer, CALayer *sliderLayer, CGRect activeClip) {
    CGRect next = activeClip;
    if (!layer || !sliderLayer) return next;
    if (layer.masksToBounds && isFiniteRect(layer.bounds) &&
        layer.bounds.size.width > 0 && layer.bounds.size.height > 0) {
        CGRect boundsInSlider = [sliderLayer convertRect:layer.bounds fromLayer:layer];
        next = intersectOptionalClip(boundsInSlider, next);
    }
    if (layer.mask) {
        CGRect maskInSlider = layerMaskRectInSlider(layer.mask, layer, sliderLayer);
        if (!CGRectIsNull(maskInSlider)) {
            next = intersectOptionalClip(maskInSlider, next);
        }
    }
    return next;
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
    __unsafe_unretained CALayer *layer;
    BOOL isSolid;
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
    // Reject rendered tracks pinned to Spotify's shifted tr rect only when tr is clearly off visualMidY
    // so a genuine visual track whose center happens to lie ~1pt away from tr.midY is never pruned.
    if (fabs(CGRectGetMidY(ctx->tr) - ctx->visualMidY) > 1.25 &&
        fabs(CGRectGetMidY(r) - CGRectGetMidY(ctx->tr)) <= 0.35 &&
        fabs(r.size.height - ctx->tr.size.height) <= 0.35) {
        return YES;
    }
    return NO;
}

static BOOL isValidTrackCandidate(CGRect r,
                                  const SGTrackSearchContext *ctx,
                                  CGFloat cornerRadius,
                                  BOOL requireFullSpan) {
    if (CGRectIsNull(r) || !isFiniteRect(r)) return NO;
    if (r.size.height < kMinTrackHeight || r.size.height > kMaxTrackHeight || r.size.width < 2.0) {
        return NO;
    }
    if (requireFullSpan && r.size.width < MAX(8.0, ctx->trackWidth - 20.0)) {
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
                                 CALayer *layer,
                                 BOOL isSolid,
                                 const SGTrackSearchContext *ctx) {
    if (*count >= kMaxCandidates) return;
    if (isShiftedTrackRectArtifact(r, ctx)) return;
    candidates[*count] = (SGTrackCandidate){
        .rect = r,
        .layer = layer,
        .isSolid = isSolid,
    };
    (*count)++;
}

static CGRect clippedRectForLayer(CALayer *layer, CALayer *sliderLayer, CGRect activeClip) {
    CGRect localRect = localContentRectForLayer(layer, layer);
    if (CGRectIsNull(localRect) || localRect.size.width <= 0 || localRect.size.height <= 0) {
        return CGRectNull;
    }
    CGRect r = [sliderLayer convertRect:localRect fromLayer:layer];
    if (!isFiniteRect(r)) return CGRectNull;
    if (layer.mask) {
        CGRect maskInSlider = layerMaskRectInSlider(layer.mask, layer, sliderLayer);
        if (!CGRectIsNull(maskInSlider)) {
            r = intersectOptionalClip(r, maskInSlider);
        }
    }
    return intersectOptionalClip(r, activeClip);
}

static void collectLayerTrackCandidates(CALayer *layer,
                                        UIView *slider,
                                        const SGTrackSearchContext *ctx,
                                        CGRect activeClip,
                                        NSUInteger depth,
                                        SGTrackCandidate *candidates,
                                        NSUInteger *count) {
    if (!layer || depth > kMaxSearchDepth || *count >= kMaxCandidates) return;
    for (CALayer *sub in layer.sublayers) {
        if (sub.hidden || sub.opacity <= 0.01 || isThumbLayer(sub)) continue;
        CGRect subInSlider = [slider.layer convertRect:sub.bounds fromLayer:sub];
        if (!isFiniteRect(subInSlider)) continue;
        if (isLensLayer(sub) && subInSlider.size.width < ctx->trackWidth * 0.5) {
            continue;
        }
        CGRect r = clippedRectForLayer(sub, slider.layer, activeClip);
        CGFloat renderedH = (!CGRectIsNull(r) && isFiniteRect(r)) ? r.size.height : subInSlider.size.height;
        BOOL isSolid = NO;
        if (!CGRectIsNull(r) && hasRenderedLayerContent(sub, renderedH, &isSolid)) {
            if (isValidTrackCandidate(r, ctx, sub.cornerRadius, isLensOrPlatterLayer(sub))) {
                appendTrackCandidate(candidates, count, r, sub, isSolid, ctx);
            }
        }
        CGRect nextClip = nextClipRectForLayer(sub, slider.layer, activeClip);
        if (!CGRectIsNull(nextClip) && (nextClip.size.width <= 0 || nextClip.size.height <= 0)) {
            continue;
        }
        collectLayerTrackCandidates(sub, slider, ctx, nextClip, depth + 1, candidates, count);
    }
}

static void collectLeafTrackCandidates(UIView *view,
                                       UIView *slider,
                                       const SGTrackSearchContext *ctx,
                                       CGRect activeClip,
                                       NSUInteger depth,
                                       SGTrackCandidate *candidates,
                                       NSUInteger *count) {
    if (!view || depth > kMaxSearchDepth || *count >= kMaxCandidates) return;
    for (UIView *sub in view.subviews) {
        if (sub.hidden || sub.alpha <= 0.01 || sub.layer.hidden || sub.layer.opacity <= 0.01 || isThumbClass(sub.class)) {
            continue;
        }
        CGRect subInSlider = [slider convertRect:sub.bounds fromView:sub];
        if (!isFiniteRect(subInSlider)) continue;
        if (isLensView(sub) && subInSlider.size.width < ctx->trackWidth * 0.5) {
            continue;
        }
        CGRect r = clippedRectForLayer(sub.layer, slider.layer, activeClip);
        CGFloat renderedH = (!CGRectIsNull(r) && isFiniteRect(r)) ? r.size.height : subInSlider.size.height;
        BOOL isSolid = NO;
        if (!CGRectIsNull(r) && hasRenderedTrackContent(sub, renderedH, &isSolid)) {
            if (isValidTrackCandidate(r, ctx, sub.layer.cornerRadius, isLensOrPlatterView(sub))) {
                appendTrackCandidate(candidates, count, r, sub.layer, isSolid, ctx);
            }
        }
        CGRect nextClip = nextClipRectForLayer(sub.layer, slider.layer, activeClip);
        if (!CGRectIsNull(nextClip) && (nextClip.size.width <= 0 || nextClip.size.height <= 0)) {
            continue;
        }
        collectLeafTrackCandidates(sub, slider, ctx, nextClip, depth + 1, candidates, count);
    }
}

static CGFloat trackCandidateScore(CGRect r,
                                   BOOL isSolid,
                                   const SGTrackSearchContext *ctx) {
    CGFloat score = fabs(r.size.height - ctx->targetHeight) * 6.0 +
                    fabs(CGRectGetMidY(r) - ctx->referenceMidY) * 2.0;
    if (!isSolid) score += 1.5;
    return score;
}

static BOOL isMatchingTargetHeight(CGFloat h, const SGTrackSearchContext *ctx) {
    if (!ctx->isFluid) return YES;
    if (ctx->isHighlighted) {
        return h > kDefaultTrackHeight + 1.5;
    }
    return h < kExpandedTrackHeight - 1.5;
}

static CGRect selectBestTrackCandidate(const SGTrackCandidate *candidates,
                                       NSUInteger count,
                                       const SGTrackSearchContext *ctx,
                                       BOOL *foundFullOut,
                                       CGFloat *bestScoreOut,
                                       CALayer **bestLayerOut,
                                       CALayer **spanLayerOut,
                                       BOOL *isLeftFillOut) {
    BOOL foundBestFull = NO;
    CGRect bestFullRect = CGRectZero;
    CGFloat bestFullScore = CGFLOAT_MAX;
    CALayer *bestFullLayer = nil;

    BOOL foundAnySpan = NO;
    CGRect bestAnySpanRect = CGRectZero;
    CGFloat bestAnySpanScore = CGFLOAT_MAX;
    CALayer *bestAnySpanLayer = nil;

    CGFloat fullMinWidth = MAX(8.0, ctx->trackWidth - 20.0);

    // 1. Full-width rendered track candidates.
    for (NSUInteger i = 0; i < count; i++) {
        SGTrackCandidate c = candidates[i];
        if (c.rect.size.width < fullMinWidth) continue;
        CGFloat score = trackCandidateScore(c.rect, c.isSolid, ctx);
        if (!foundAnySpan || score < bestAnySpanScore) {
            foundAnySpan = YES;
            bestAnySpanRect = c.rect;
            bestAnySpanScore = score;
            bestAnySpanLayer = c.layer;
        }
        if (!isMatchingTargetHeight(c.rect.size.height, ctx)) continue;
        if (!foundBestFull || score < bestFullScore) {
            foundBestFull = YES;
            bestFullRect = c.rect;
            bestFullScore = score;
            bestFullLayer = c.layer;
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
                CGFloat score = trackCandidateScore(combined, a.isSolid && b.isSolid, ctx);
                if (!foundBestFull || score < bestFullScore) {
                    foundBestFull = YES;
                    bestFullRect = combined;
                    bestFullScore = score;
                    bestFullLayer = (b.rect.size.width >= a.rect.size.width) ? b.layer : a.layer;
                }
            }
        }
    }

    // 3. Left-anchored fill bar (e.g. elapsed white fill).
    BOOL foundFill = NO;
    CGRect bestFillRect = CGRectZero;
    CGFloat bestFillScore = CGFLOAT_MAX;
    CALayer *bestFillLayer = nil;
    for (NSUInteger i = 0; i < count; i++) {
        SGTrackCandidate c = candidates[i];
        if (fabs(c.rect.origin.x - ctx->trackMinX) > 10.0) continue;
        if (!isMatchingTargetHeight(c.rect.size.height, ctx)) continue;
        CGFloat score = trackCandidateScore(c.rect, c.isSolid, ctx);
        if (!foundFill || score < bestFillScore) {
            foundFill = YES;
            bestFillRect = c.rect;
            bestFillScore = score;
            bestFillLayer = c.layer;
        }
    }

    BOOL preferFill = foundFill && (!foundBestFull || bestFullScore > bestFillScore + 4.0);
    if (preferFill || foundBestFull) {
        CALayer *spanLayer = preferFill ? (bestFullLayer ?: bestAnySpanLayer) : bestFullLayer;
        CGRect spanRect = foundBestFull ? bestFullRect : (foundAnySpan ? bestAnySpanRect : CGRectZero);
        CGFloat chosenX = (preferFill && spanLayer && spanRect.size.width >= fullMinWidth) ? spanRect.origin.x : ctx->trackMinX;
        CGFloat chosenW = (preferFill && spanLayer && spanRect.size.width >= fullMinWidth) ? spanRect.size.width : ctx->trackWidth;
        CGRect chosen = preferFill
            ? CGRectMake(chosenX, bestFillRect.origin.y, chosenW, bestFillRect.size.height)
            : bestFullRect;
        if (foundFullOut) *foundFullOut = YES;
        if (bestScoreOut) *bestScoreOut = preferFill ? bestFillScore : bestFullScore;
        if (bestLayerOut) *bestLayerOut = preferFill ? bestFillLayer : bestFullLayer;
        if (spanLayerOut) *spanLayerOut = spanLayer;
        if (isLeftFillOut) *isLeftFillOut = preferFill;
        return chosen;
    }

    // 4. Stale-height rendered bar during highlight transition: return the underlying layer & live frame.
    BOOL foundStale = NO;
    CGRect bestStaleRect = CGRectZero;
    CGFloat bestStaleScore = CGFLOAT_MAX;
    CALayer *bestStaleLayer = nil;
    BOOL bestStaleIsLeftFill = NO;
    for (NSUInteger i = 0; i < count; i++) {
        SGTrackCandidate c = candidates[i];
        BOOL fullSpan = (c.rect.size.width >= fullMinWidth);
        BOOL leftFill = (!fullSpan && fabs(c.rect.origin.x - ctx->trackMinX) <= 10.0);
        if (!fullSpan && !leftFill) continue;
        CGFloat score = fabs(CGRectGetMidY(c.rect) - ctx->referenceMidY) * 2.0 +
                        (fullSpan ? 0.0 : 4.0) +
                        (c.isSolid ? 0.0 : 2.0);
        if (!foundStale || score < bestStaleScore) {
            foundStale = YES;
            CGFloat staleX = (leftFill && bestAnySpanLayer && bestAnySpanRect.size.width >= fullMinWidth) ? bestAnySpanRect.origin.x : ctx->trackMinX;
            CGFloat staleW = (leftFill && bestAnySpanLayer && bestAnySpanRect.size.width >= fullMinWidth) ? bestAnySpanRect.size.width : ctx->trackWidth;
            bestStaleRect = fullSpan
                ? c.rect
                : CGRectMake(staleX, c.rect.origin.y, staleW, c.rect.size.height);
            bestStaleScore = score;
            bestStaleLayer = c.layer;
            bestStaleIsLeftFill = leftFill;
        }
    }

    if (foundFullOut) *foundFullOut = NO;
    if (bestScoreOut) *bestScoreOut = bestStaleScore;
    if (bestLayerOut) *bestLayerOut = bestStaleLayer;
    if (spanLayerOut) *spanLayerOut = bestStaleIsLeftFill ? bestAnySpanLayer : bestStaleLayer;
    if (isLeftFillOut) *isLeftFillOut = bestStaleIsLeftFill;
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

typedef struct {
    CGRect frame;
    __unsafe_unretained CALayer *trackedLayer;
    __unsafe_unretained CALayer *spanLayer;
    BOOL isLeftFill;
    BOOL usedRenderedTrack;
    BOOL measuredMidYValid;
    CGFloat measuredMidY;
    CGFloat fallbackSpanMinX;
    CGFloat fallbackSpanWidth;
} SGResolvedTrackResult;

static SGResolvedTrackResult resolveTrackCandidate(UIView *slider,
                                                   UIView *bufferingView,
                                                   UIView *visualElement,
                                                   SGSponsorBlockOverlayContainer *container) {
    SGResolvedTrackResult res = {0};
    if (!slider || slider.bounds.size.width <= 0 || slider.bounds.size.height <= 0) {
        return res;
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
    CGFloat visualMidY = (visualElement && visualElement.superview == slider) ? CGRectGetMidY(visualElement.frame) : boundsMidY;
    CGFloat referenceMidY = isFluid ? visualMidY : (hasSuper ? CGRectGetMidY(superRect) : boundsMidY);
    BOOL trIsShifted = hasTr && (fabs(CGRectGetMidY(tr) - referenceMidY) > 0.75);

    res.fallbackSpanMinX = trackMinX;
    res.fallbackSpanWidth = trackWidth;

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

        CGRect rootClip = nextClipRectForLayer(visualElement.layer, slider.layer, CGRectNull);

        SGTrackCandidate viewCandidates[kMaxCandidates];
        NSUInteger viewCount = 0;
        collectLeafTrackCandidates(visualElement, slider, &ctx, rootClip, 0, viewCandidates, &viewCount);
        BOOL foundFullView = NO;
        CGFloat viewScore = CGFLOAT_MAX;
        CALayer *viewBestLayer = nil;
        CALayer *viewSpanLayer = nil;
        BOOL viewLeftFill = NO;
        CGRect bestView = selectBestTrackCandidate(viewCandidates, viewCount, &ctx,
                                                   &foundFullView, &viewScore,
                                                   &viewBestLayer, &viewSpanLayer, &viewLeftFill);

        SGTrackCandidate layerCandidates[kMaxCandidates];
        NSUInteger layerCount = 0;
        BOOL foundFullLayer = NO;
        CGFloat layerScore = CGFLOAT_MAX;
        CALayer *layerBestLayer = nil;
        CALayer *layerSpanLayer = nil;
        BOOL layerLeftFill = NO;
        CGRect bestLayer = CGRectZero;
        if (!foundFullView || isFluid) {
            collectLayerTrackCandidates(visualElement.layer, slider, &ctx, rootClip, 0, layerCandidates, &layerCount);
            bestLayer = selectBestTrackCandidate(layerCandidates, layerCount, &ctx,
                                                 &foundFullLayer, &layerScore,
                                                 &layerBestLayer, &layerSpanLayer, &layerLeftFill);
        }

        if (foundFullView || foundFullLayer) {
            BOOL pickLayer = (foundFullView && foundFullLayer) ? (layerScore + 0.01 < viewScore) : foundFullLayer;
            CGRect chosen = pickLayer ? bestLayer : bestView;
            res.frame = chosen;
            res.trackedLayer = pickLayer ? layerBestLayer : viewBestLayer;
            res.spanLayer = pickLayer ? layerSpanLayer : viewSpanLayer;
            res.isLeftFill = pickLayer ? layerLeftFill : viewLeftFill;
            res.usedRenderedTrack = YES;
            res.measuredMidYValid = YES;
            res.measuredMidY = CGRectGetMidY(chosen);
            return res;
        }

        if (viewBestLayer || layerBestLayer) {
            BOOL pickLayer = (viewBestLayer && layerBestLayer) ? (layerScore + 0.01 < viewScore) : (layerBestLayer != nil);
            CGRect staleRect = pickLayer ? bestLayer : bestView;
            res.frame = staleRect;
            res.trackedLayer = pickLayer ? layerBestLayer : viewBestLayer;
            res.spanLayer = pickLayer ? layerSpanLayer : viewSpanLayer;
            res.isLeftFill = pickLayer ? layerLeftFill : viewLeftFill;
            res.usedRenderedTrack = YES;
            res.measuredMidYValid = YES;
            res.measuredMidY = CGRectGetMidY(staleRect);
            return res;
        }
    }

    if (!isFluid && bufferingView && bufferingView.superview == slider) {
        CGRect bf = bufferingView.frame;
        if (isValidBufferingFrame(bf, sliderW, referenceMidY, 5.5)) {
            res.frame = bf;
            res.trackedLayer = bufferingView.layer;
            res.spanLayer = bufferingView.layer;
            res.usedRenderedTrack = YES;
            res.measuredMidYValid = YES;
            res.measuredMidY = CGRectGetMidY(bf);
            return res;
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
    res.frame = CGRectMake(trackMinX, y, trackWidth, h);
    return res;
}

static void applyResolvedMetadataToContainer(SGSponsorBlockOverlayContainer *container,
                                             const SGResolvedTrackResult *res) {
    container.trackedLayer = res->trackedLayer;
    container.trackedSpanLayer = res->spanLayer;
    container.trackedLayerIsLeftFill = res->isLeftFill;
    container.fallbackSpanMinX = res->fallbackSpanMinX;
    container.fallbackSpanWidth = res->fallbackSpanWidth;
}

static UIView *overlayAnchor(UIView *slider, UIView *bufferingView, UIView *visualElement) {
    if (bufferingView && visualElement) {
        NSUInteger bIdx = [slider.subviews indexOfObjectIdenticalTo:bufferingView];
        NSUInteger vIdx = [slider.subviews indexOfObjectIdenticalTo:visualElement];
        return (bIdx != NSNotFound && vIdx != NSNotFound && bIdx > vIdx) ? bufferingView : visualElement;
    }
    return bufferingView ?: visualElement;
}

typedef struct {
    __unsafe_unretained Class cls;
    IMP origIMP;
} SGHookedLayoutEntry;

static SGHookedLayoutEntry s_hookedLayouts[kMaxHookedVisualClasses];
static NSUInteger s_hookedLayoutCount = 0;

static void handleVisualElementLayout(UIView *self, SEL _cmd, NSUInteger slot) {
    IMP orig = s_hookedLayouts[slot].origIMP;
    s_visualLayoutDepth++;
    if (orig) {
        ((void (*)(id, SEL))(void *)orig)(self, _cmd);
    }
    s_visualLayoutDepth--;
    if (s_visualLayoutDepth > 0 || s_updatingFromVisualLayout) return;
    UIView *slider = self.superview;
    if (slider && slider.window && [s_trackedSliders containsObject:slider]) {
        s_updatingFromVisualLayout = YES;
        [SGSponsorBlockOverlay updateSlider:slider animateHeightChange:NO];
        s_updatingFromVisualLayout = NO;
    }
}

#define SG_VE_TRAMPOLINE(N) \
static void sg_veLayout##N(UIView *self, SEL _cmd) { handleVisualElementLayout(self, _cmd, N); }

SG_VE_TRAMPOLINE(0)
SG_VE_TRAMPOLINE(1)
SG_VE_TRAMPOLINE(2)
SG_VE_TRAMPOLINE(3)
SG_VE_TRAMPOLINE(4)
SG_VE_TRAMPOLINE(5)
SG_VE_TRAMPOLINE(6)
SG_VE_TRAMPOLINE(7)
#undef SG_VE_TRAMPOLINE

static void * const kVETrampolines[kMaxHookedVisualClasses] = {
    (void *)sg_veLayout0, (void *)sg_veLayout1, (void *)sg_veLayout2, (void *)sg_veLayout3,
    (void *)sg_veLayout4, (void *)sg_veLayout5, (void *)sg_veLayout6, (void *)sg_veLayout7,
};

static BOOL isTrampolineIMP(IMP imp) {
    for (NSUInteger i = 0; i < kMaxHookedVisualClasses; i++) {
        if ((IMP)kVETrampolines[i] == imp) return YES;
    }
    return NO;
}

static void hookVisualElementLayoutIfNeeded(UIView *visualElement) {
    if (!visualElement) return;
    Class cls = visualElement.class;
    if (!cls || cls == UIView.class || cls == UIControl.class) return;
    if (!isVisualElementView(visualElement)) return;

    @synchronized ([SGSponsorBlockOverlay class]) {
        for (NSUInteger i = 0; i < s_hookedLayoutCount; i++) {
            if (s_hookedLayouts[i].cls == cls) return;
        }
        if (s_hookedLayoutCount >= kMaxHookedVisualClasses) return;

        Method m = class_getInstanceMethod(cls, @selector(layoutSubviews));
        if (!m) return;
        IMP curIMP = method_getImplementation(m);
        if (isTrampolineIMP(curIMP)) return;

        NSUInteger slot = s_hookedLayoutCount;
        IMP newIMP = (IMP)kVETrampolines[slot];
        if (class_addMethod(cls, @selector(layoutSubviews), newIMP, method_getTypeEncoding(m))) {
            s_hookedLayouts[slot].cls = cls;
            s_hookedLayouts[slot].origIMP = curIMP;
            s_hookedLayoutCount++;
        } else {
            IMP prevIMP = method_setImplementation(m, newIMP);
            s_hookedLayouts[slot].cls = cls;
            s_hookedLayouts[slot].origIMP = prevIMP;
            s_hookedLayoutCount++;
        }
    }
}

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

    if (visualElement) hookVisualElementLayoutIfNeeded(visualElement);

    SGResolvedTrackResult resolved = resolveTrackCandidate(slider, bufferingView, visualElement, container);
    CGRect applyFrame = resolved.frame;
    if (applyFrame.size.width <= 0 || applyFrame.size.height <= 0) return;

    BOOL curHighlighted = [slider isKindOfClass:UISlider.class] && ((UISlider *)slider).highlighted;
    BOOL highlightedChanged = container && (container.lastHighlighted != curHighlighted);
    BOOL animatingTracked = resolved.trackedLayer &&
        (layerChainHasActiveAnimations(resolved.trackedLayer, slider.layer) ||
         (resolved.spanLayer && resolved.spanLayer != resolved.trackedLayer &&
          layerChainHasActiveAnimations(resolved.spanLayer, slider.layer)));

    if (resolved.usedRenderedTrack && resolved.trackedLayer && animatingTracked) {
        CGRect presFrame = measureTrackFrameFromLayers(resolved.trackedLayer,
                                                       resolved.spanLayer,
                                                       resolved.isLeftFill,
                                                       resolved.fallbackSpanMinX,
                                                       resolved.fallbackSpanWidth,
                                                       slider,
                                                       YES);
        if (!CGRectIsNull(presFrame)) {
            applyFrame = presFrame;
        }
    }

    BOOL needsRebuild = (!container ||
                         container.needsRebuild ||
                         container.cachedRawSegments != segments ||
                         ![container.cachedEpisodeID isEqualToString:episodeID] ||
                         fabs(container.cachedDuration - duration) > 0.001);

    BOOL frameChanged = container && !rectNearlyEqual(container.frame, applyFrame, 0.05);

    if (!needsRebuild) {
        if (frameChanged) {
            BOOL heightChanged = fabs(container.frame.size.height - applyFrame.size.height) > 0.5;
            if (!resolved.usedRenderedTrack &&
                (animateHeightChange || highlightedChanged) &&
                heightChanged &&
                UIView.inheritedAnimationDuration <= 0.0) {
                [UIView animateWithDuration:0.15
                                      delay:0
                                    options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                                 animations:^{
                    [container layoutSegmentsForTrackFrame:applyFrame];
                } completion:nil];
            } else {
                [UIView performWithoutAnimation:^{
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    [container layoutSegmentsForTrackFrame:applyFrame];
                    [CATransaction commit];
                }];
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
            container = [[SGSponsorBlockOverlayContainer alloc] initWithFrame:applyFrame];
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
        [UIView performWithoutAnimation:^{
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [container rebuildWithSegments:visible duration:duration episodeID:episodeID trackFrame:applyFrame];
            [CATransaction commit];
        }];
        frameChanged = YES;
    }

    applyResolvedMetadataToContainer(container, &resolved);

    if (resolved.measuredMidYValid) {
        container.hasLastMeasuredMidY = YES;
        container.lastMeasuredMidY = resolved.measuredMidY;
        container.lastMeasuredBoundsHeight = slider.bounds.size.height;
    }

    container.usedRenderedTrack = resolved.usedRenderedTrack;
    container.lastHighlighted = curHighlighted;

    if (slider.window && resolved.usedRenderedTrack && (animatingTracked || highlightedChanged)) {
        [container startAnimationWatchWithMinDuration:highlightedChanged ? kAnimationMinWatchSeconds : 0.0];
    }

    BOOL boundsChanged = !CGRectEqualToRect(container.lastPostLayoutBounds, slider.bounds);
    BOOL needAsyncPostLayout = (!resolved.usedRenderedTrack && (boundsChanged || frameChanged || highlightedChanged));
    if (slider.window && !container.pendingPostLayout && needAsyncPostLayout) {
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
                [self updateSlider:s animateHeightChange:NO];
            }
        });
    } else if (boundsChanged) {
        container.lastPostLayoutBounds = slider.bounds;
    }
}

@end

@implementation SGSponsorBlockOverlayContainer (DisplayLinkSync)

- (void)handleDisplayLinkTick {
    UIView *slider = self.superview;
    if (!slider || !self.window) {
        [self stopDisplayLink];
        return;
    }

    CALayer *tracked = self.trackedLayer;
    CALayer *span = self.trackedSpanLayer;
    BOOL animating = (tracked && layerChainHasActiveAnimations(tracked, slider.layer)) ||
                     (span && span != tracked && layerChainHasActiveAnimations(span, slider.layer));

    CFTimeInterval now = CACurrentMediaTime();
    BOOL trackedInvalid = (!tracked || tracked.hidden || tracked.opacity <= 0.01 ||
                           !isDescendantLayer(tracked, slider.layer, kMaxSearchDepth + 8));

    BOOL isHighlighted = [slider isKindOfClass:UISlider.class] && ((UISlider *)slider).highlighted;
    CGFloat targetH = isHighlighted ? kExpandedTrackHeight : kDefaultTrackHeight;

    CGRect liveFrame = trackedInvalid
        ? CGRectNull
        : measureTrackFrameFromLayers(tracked, span, self.trackedLayerIsLeftFill,
                                      self.fallbackSpanMinX, self.fallbackSpanWidth, slider, YES);
    BOOL heightMismatch = (!CGRectIsNull(liveFrame) && fabs(liveFrame.size.height - targetH) > 2.0);
    BOOL needMidWatchRecheck = (!animating && heightMismatch && !self.didRecheckLayerMidWatch && now >= self.minWatchUntil);
    if (trackedInvalid || needMidWatchRecheck) {
        if (needMidWatchRecheck) self.didRecheckLayerMidWatch = YES;
        SGResolvedTrackResult recheck = resolveTrackCandidate(slider, self.cachedTrackView, self.cachedVisualElement, self);
        if (recheck.usedRenderedTrack && recheck.trackedLayer) {
            applyResolvedMetadataToContainer(self, &recheck);
            tracked = recheck.trackedLayer;
            span = recheck.spanLayer;
            animating = layerChainHasActiveAnimations(tracked, slider.layer) ||
                        (span && span != tracked && layerChainHasActiveAnimations(span, slider.layer));
            liveFrame = measureTrackFrameFromLayers(tracked, span, self.trackedLayerIsLeftFill,
                                                    self.fallbackSpanMinX, self.fallbackSpanWidth, slider, animating);
        }
    }

    if (!CGRectIsNull(liveFrame) && isFiniteRect(liveFrame) &&
        liveFrame.size.width > 0 && liveFrame.size.height > 0) {
        if (!rectNearlyEqual(self.frame, liveFrame, 0.05)) {
            [UIView performWithoutAnimation:^{
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                [self layoutSegmentsForTrackFrame:liveFrame];
                [CATransaction commit];
            }];
            self.hasLastMeasuredMidY = YES;
            self.lastMeasuredMidY = CGRectGetMidY(liveFrame);
            self.lastMeasuredBoundsHeight = slider.bounds.size.height;
            self.settledTickCount = 0;
        } else {
            self.settledTickCount++;
        }
    } else {
        self.settledTickCount++;
    }

    if (now >= self.watchStartedAt + kAnimationMaxWatchSeconds) {
        [self stopDisplayLink];
        return;
    }

    if (!animating && ((self.settledTickCount >= 3 && now >= self.minWatchUntil) || now >= self.animationWatchUntil)) {
        [self stopDisplayLink];
    }
}

@end

// The redesign's now playing bar: the album-colored card becomes a glass card with round artwork and the
// progress line under the text. Spotify's own labels, buttons and gestures stay in place.
//
// The full screen player morphs the bar's own card and artwork into the cover art. The bar was
// written to hand itself back to Spotify for that animation, from NowPlaying_ViewPageImpl's
// Show/CloseFullscreenAnimatedTransitioning, but Spotify 9.1.78 never runs the player through those,
// so the handback never happened and is gone; if the morph ever reads as a cut, the place to start is
// Shared/Player/PlayerEvents.h, which does fire. What does move with the player is a stand-in of the
// bar, which BarTransition.x keeps glass behind.
//
// Tree (trees/home.txt): NowPlayingBarContainerViewController.view 402x56 > NowPlayingBarViewController.view
//   at {8,0} 386x56 > UIView 386x56 (the painted card) > artwork 40x40 r=4, title stack,
//   progress line 370x2 at the bottom. The glass pane goes on the container's view.
//
// In a Jam Spotify puts a "Jam by ..." strip on the bar, a SwiftUI _UIHostingView of
// Jam_AttachmentsImpl.JamHatElement as wide as the card and 44pt high, and grows the bar by its height
// (386x100, the track card at y = 44). It paints the strip, or a view around the strip and the track, as
// well, so the card is the painted view that holds the track and has no strip in it. The strip stays out
// of the card's glass and gets a pane of its own above it, since its own paint goes clear with the rest.
// The strip's class is modelled, not recorded: no tree has a Jam in it yet. The 9.1.90 binary has the Jam's
// hat under Jam_AttachmentsImpl.HatRootViewController, so the strip is also known by its controller.
// In the minimized tab bar's row the card docks as it does outside a Jam, and the strip rides above it at
// its width, on its own pane.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRRepaint.h"
#import "Redesigned/Kit/SGRGlass.h"
#import "Redesigned/Kit/SGRGlyph.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "Redesigned/Kit/SGRPass.h"
#import "Shared/Player/PlayerEvents.h"
#import "Settings/SGMarquee.h"
#import "Shared/Player/PlayerState.h"
#import "NowPlayingBar.h"
#import "Redesigned/Navbar/Navbar.h"
#import <objc/message.h>

static inline BOOL SGRIsBarCompact(void) {
    return SGEnabled(SGRKeyBarCompact);
}

BOOL SGRIsBarNextButtonEnabled(void) {
    return SGFlag(SGRKeyBarNextButton, SGRIsBarCompact());
}

static const CGFloat kCardRadius = 24;
static const CGFloat kCompactArtScale = 0.80;          // 40 pt -> 32 pt inside the 48 pt compact card
static const CGFloat kCompactArtShiftX = 2.0;          // 14 pt leading inset inside the 48 pt capsule
static const CGFloat kNonCompactSquareArtScale = 0.85; // 40 pt -> 34 pt inside the 56 pt non-compact capsule
static const CGFloat kNonCompactSquareArtShiftX = 3.0; // 14 pt leading inset inside the 56 pt capsule
static const CGFloat kSquareArtCornerRadius = 6.5;     // visual continuous corner radius for rounded-square artwork
// The strip's pane is this much smaller than the strip at each end, so a gap parts it from the card's glass.
static const CGFloat kStripInset = 4;
static NSString *const kUnitId = @"Components.UI.PageInformationUnitNowPlayingBar";
static NSString *const kPageId = @"now-playing-bar-page";
static NSString *const kDeviceLineId = @"now-plaging-bar-connect-content";   // Spotify's spelling
static NSString *const kBullet = @" • ";
static char kGlassKey, kStripGlassKey, kStripFilmKey, kNextButtonKey, kPlayGlyphKey, kPlayTapHookedKey, kTextKey, kArtLockKey;
static __weak UIView *sg_card;
static CGRect sg_stripFrame;
static __weak UIView *sg_cardGlass;
static char kTintKey, kCardDimKey, kStripDimKey;
// The track's glass frame in the container's view as the bar was last styled, the strip cut off: the row
// takes the card's height and middle from it, never the bar's, which in a Jam has the strip on top.
static CGRect sg_trackFrame = {{INFINITY, INFINITY}, {0, 0}};
static __weak UIView *sg_cardArtwork;
static __weak UIView *sg_progress;
static __weak UIViewController *sg_container;
// The container's view while it stands in the minimized tab bar's row, below the page that holds it.
static __weak UIView *sg_inline;
static CGFloat sg_scrollSquish;
static BOOL sg_stylingBar;
// The tab bar's moves under way (one can start before the last one ends), and the relayout owed to their end.
static NSInteger sg_barMoves;
static BOOL sg_owedLayout, sg_owedRefresh;

CGRect SGRNowPlayingCardFrameIn(UIView *host, CGFloat *radius) {
    UIView *glass = sg_cardGlass;
    if (!glass.superview || !glass.window || !host) return CGRectNull;
    if (radius) *radius = MIN(kCardRadius, glass.bounds.size.height / 2);
    return [host convertRect:glass.bounds fromView:glass];
}

CGFloat SGRNowPlayingStripHeight(void) {
    return sg_stripFrame.size.height;
}

CGRect SGRNowPlayingArtworkFrameIn(UIView *host) {
    UIView *artwork = sg_cardArtwork;
    if (!artwork.window || !host) return CGRectNull;
    return [host convertRect:artwork.bounds fromView:artwork];
}

// The Jam strip, by its class or by its controller's (Jam_AttachmentsImpl.HatRootViewController, whose view
// can be any hosting view). Only the Jam's: the bar's other hats (ads, sponsors) keep the card out of the row.
// The height keeps out a view of the same module that can hold the track card too.
static BOOL isStrip(UIView *view) {
    if (view.bounds.size.height > 60) return NO;
    if (SGClassNamed(view.class, @"AttachmentsImpl") && SGClassNamed(view.class, @"Hat")) return YES;
    UIResponder *next = view.nextResponder;
    if (![next isKindOfClass:UIViewController.class]) return NO;
    return SGClassNamed(next.class, @"Jam") && SGClassNamed(next.class, @"Hat");
}

static BOOL inStrip(UIView *view, UIView *root) {
    for (UIView *v = view; v && v != root; v = v.superview) if (isStrip(v)) return YES;
    return NO;
}

static UIView *stripIn(UIView *root) {
    __block UIView *strip = nil;
    SGForEachView(root, ^(UIView *v) { if (!strip && isStrip(v)) strip = v; });
    return strip;
}

static BOOL insideInformationContainer(UIView *view, UIView *root) {
    for (UIView *v = view; v && v != root; v = v.superview) {
        if (SGClassNamed(v.class, @"InformationContainer")
            || [v.accessibilityIdentifier isEqualToString:kPageId]
            || [v.accessibilityIdentifier isEqualToString:kUnitId]) {
            return YES;
        }
    }
    return NO;
}

// The listener's avatar at the strip's right end: a small round SwiftUI view (24pt, r=12) whose fill is the
// colour behind the initial. Stripping it like the rest of the bar's paint left the letter alone on the glass.
// SGRRepaint.x asks as well, so the fill Spotify paints later stays.
BOOL SGRIsStripAvatar(UIView *view) {
    CGSize size = view.bounds.size;
    if (size.height < 16 || size.height > 44 || fabs(size.width - size.height) > 1) return NO;
    if (view.layer.cornerRadius < size.height / 2 - 1) return NO;
    for (UIView *v = view.superview; v; v = v.superview) if (isStrip(v)) return YES;
    return NO;
}

// SGStripBackgrounds (Core/SGViewTree.m) for the bar, except that it leaves the strip's avatar and what is in it.
static void stripBar(UIView *view) {
    if (SGRIsStripAvatar(view)) return;
    if ([view isKindOfClass:UIVisualEffectView.class]) return;
    if (!SGKeepsColor(view)) view.layer.backgroundColor = NULL;
    if ([view.layer isKindOfClass:CAGradientLayer.class] || [NSStringFromClass(view.class) containsString:@"GradientView"]) view.hidden = YES;
    for (CALayer *layer in view.layer.sublayers) {
        if ([layer isKindOfClass:CAGradientLayer.class]) layer.hidden = YES;
    }
    for (UIView *sub in view.subviews) stripBar(sub);
}
// What holds the track on the bar: the title and artist block, else the artwork (a 36 to 48pt square that
// is not a button), never anything in the strip. Nil when neither is there.
static UIView *trackMarker(UIView *bar) {
    __block UIView *info = nil, *artwork = nil;
    SGForEachView(bar, ^(UIView *v) {
        if (info || inStrip(v, bar)) return;
        if (SGClassNamed(v.class, @"InformationContainer")) info = v;
        CGSize size = v.bounds.size;
        BOOL square = size.width >= 36 && size.width <= 48 && fabs(size.width - size.height) < 1;
        if (!artwork && square && ![v isKindOfClass:UIControl.class]) artwork = v;
    });
    return info ?: artwork;
}

// A card holds the track and has no strip in it; one with the strip in it only when there is no other.
// Among equals the largest, which outside a Jam is the card it always was.
static BOOL isGoodCard(UIView *card, UIView *bar, UIView *marker) {
    return SGIsInside(card, bar) && !inStrip(card, bar) && (!marker || [marker isDescendantOfView:card]);
}

static UIView *chooseCard(UIView *bar, UIView *marker) {
    UIView *best = nil;
    BOOL bestHasStrip = NO;
    CGFloat bestArea = 0;
    for (UIView *v in sgr_nowPlayingPainted) {
        // Card sized: the paint itself has gone clear by now.
        if (!SGLooksLikeCard(v, UIColor.whiteColor.CGColor) || !isGoodCard(v, bar, marker)) continue;
        BOOL hasStrip = stripIn(v) != nil;
        CGFloat area = v.bounds.size.width * v.bounds.size.height;
        BOOL better = !best || (hasStrip != bestHasStrip ? !hasStrip : area > bestArea);
        if (!better) continue;
        best = v;
        bestHasStrip = hasStrip;
        bestArea = area;
    }
    return best;
}

// Fallback when nothing is painted: the box around artwork, text and the small buttons.
static CGRect contentBounds(UIView *bar, UIView *target) {
    __block CGRect box = CGRectNull;
    SGForEachView(bar, ^(UIView *v) {
        if (v.hidden || v.alpha == 0 || inStrip(v, bar)) return;
        CGFloat width = v.bounds.size.width;
        BOOL content = ([v isKindOfClass:UIImageView.class] && width >= 20 && width <= 120)
            || [v isKindOfClass:UILabel.class]
            || ([v isKindOfClass:UIControl.class] && width <= 100);
        if (content) box = CGRectUnion(box, SGFrameIn(v, target));
    });
    return CGRectIsNull(box) ? box : CGRectInset(box, -10, -8);
}

static void roundView(UIView *view, CGFloat radius) {
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
}

static BOOL insideControlOrStack(UIView *view, UIView *root) {
    for (UIView *v = view; v && v != root; v = v.superview) {
        if ([v isKindOfClass:UIControl.class] || [v isKindOfClass:UIStackView.class]) return YES;
    }
    return NO;
}

static void resetArtworkTransform(UIView *card) {
    UIView *art = sg_cardArtwork;
    if (art && (!card || [art isDescendantOfView:card]) && !CGAffineTransformIsIdentity(art.transform)) {
        art.transform = CGAffineTransformIdentity;
    }
}

static void restyleCardContent(UIView *card) {
    if (!card) return;
    BOOL compact = SGRIsBarCompact();
    BOOL isCircle = SGInt(SGRKeyBarArtworkShape, SGRBarArtworkShapeRoundedSquare) == SGRBarArtworkShapeCircle;

    resetArtworkTransform(card);

    __block UIView *foundView = nil;
    if (sg_cardArtwork && [sg_cardArtwork isDescendantOfView:card]) {
        CGSize sz = sg_cardArtwork.bounds.size;
        if (sz.width >= 32 && sz.width <= 48 && fabs(sz.width - sz.height) < 2) {
            foundView = sg_cardArtwork;
        }
    }
    if (!foundView) {
        SGForEachView(card, ^(UIView *v) {
            if (foundView || inStrip(v, card) || insideInformationContainer(v, card) || insideControlOrStack(v, card)) return;
            CGSize size = v.bounds.size;
            BOOL square = size.width >= 32 && size.width <= 48 && fabs(size.width - size.height) < 2;
            if (!square || SGFrameIn(v, card).origin.x > 36) return;
            foundView = v;
        });
    }

    if (foundView) {
        CGSize size = foundView.bounds.size;
        UIView *outer = foundView;
        for (UIView *u = foundView; u && u != card && CGSizeEqualToSize(u.bounds.size, size); u = u.superview) {
            outer = u;
        }
        if (!objc_getAssociatedObject(outer, &kArtLockKey)) {
            objc_setAssociatedObject(outer, &kArtLockKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [outer setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [outer setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        }
        CGFloat baseWidth = size.width > 0 ? size.width : 40.0;
        CGFloat artScale = compact ? kCompactArtScale : (isCircle ? 1.0 : kNonCompactSquareArtScale);
        CGFloat artShiftX = compact ? kCompactArtShiftX : (isCircle ? 0.0 : kNonCompactSquareArtShiftX);
        CGFloat radius = isCircle ? (baseWidth / 2.0) : (kSquareArtCornerRadius / artScale);
        // Round both the outer wrapper and all matching square image views inside it so neither background nor cover bleeds.
        for (UIView *u = foundView; u && u != card && CGSizeEqualToSize(u.bounds.size, size); u = u.superview) {
            roundView(u, radius);
            u.clipsToBounds = YES;
        }
        SGForEachView(outer, ^(UIView *sub) {
            if (fabs(sub.bounds.size.width - size.width) < 2 && fabs(sub.bounds.size.height - size.height) < 2) {
                roundView(sub, radius);
                sub.clipsToBounds = YES;
            }
        });
        if (fabs(artScale - 1.0) > 0.001 || fabs(artShiftX) > 0.001) {
            outer.transform = CGAffineTransformConcat(
                CGAffineTransformMakeScale(artScale, artScale),
                CGAffineTransformMakeTranslation(artShiftX, 0.0)
            );
        } else {
            outer.transform = CGAffineTransformIdentity;
        }
        sg_cardArtwork = outer;
    }

    __block UIView *progress = sg_progress;
    if (![progress isDescendantOfView:card]) {
        progress = nil;
        SGForEachView(card, ^(UIView *v) {
            CGRect f = v.frame;
            if (!progress && !inStrip(v, card) && f.size.height <= 3 && f.size.width >= 200 && v.superview.bounds.size.height >= 40) progress = v;
        });
        sg_progress = progress;
    }
    if (progress) {
        // Apple Music's compact mini player has no bottom progress line; the non-compact 56pt bar keeps
        // upstream's native full-width bottom progress bar untouched across both expanded and sandwiched states.
        progress.hidden = compact;
        progress.alpha = compact ? 0.0 : 1.0;
    }
}

// The strip's own pane, a strip high less the gaps, on the card's side the strip is on. It is the card's glass,
// one material with it; the strip's white text reads over a bright page by the fade under the bars (TabBar.x). It is measured from
// the card's settled frame and the strip's height, not from the strip's frame: Spotify animates the strip
// in, and a pane taken from it mid-way sat about 12pt off and cut its ⋯ button. The glass comes in and goes
// by its effect, never by alpha (SGRGlass.h).
// Whether a pane is showing: a UIVisualEffectView by its effect, an SGLegacyGlassView (below iOS 26) by its alpha,
// the two ways SGRShowGlass hides one.
static BOOL paneShown(UIView *pane) {
    if ([pane isKindOfClass:UIVisualEffectView.class]) return ((UIVisualEffectView *)pane).effect != nil;
    return pane.alpha > 0;
}

static void placeStripGlass(UIView *host, UIView *strip, CGRect card, BOOL above) {
    UIView *pane = objc_getAssociatedObject(host, &kStripGlassKey);
    UIView *oldFilm = objc_getAssociatedObject(host, &kStripFilmKey);
    if (!strip) {
        if (pane && paneShown(pane)) SGRAnimate(SGRMotionExit, ^{ SGRShowGlass(pane, NO); oldFilm.alpha = 0; }, nil);
        return;
    }
    BOOL made = pane != nil;
    pane = SGGlassFor(host, &kStripGlassKey);
    if (!made) {
        if ([pane isKindOfClass:UIVisualEffectView.class]) ((UIVisualEffectView *)pane).effect = nil;
        else pane.alpha = 0;
        pane.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    CGFloat height = strip.bounds.size.height;
    CGRect frame = CGRectMake(card.origin.x, above ? CGRectGetMinY(card) - height : CGRectGetMaxY(card), card.size.width, height);
    pane.frame = CGRectInset(frame, 0, kStripInset);
    CGFloat radius = MIN(kCardRadius, pane.bounds.size.height / 2);
    SGShapeGlass(pane, radius, NO);
    SGRDarkenGlass(pane, &kStripDimKey, radius, SGRBarDim);
    // The same white film as the card and the tab bar (16%), which comes and goes with the pane.
    UIView *film = SGRGlassFilm(host, &kStripFilmKey, pane, radius);
    if (!made) film.alpha = 0;
    if (!paneShown(pane)) SGRAnimate(SGRMotionRespond, ^{ SGRShowGlass(pane, YES); film.alpha = 1; }, nil);
}

// The bar's left and right edges in its superview, set through the constants of the constraints that hold
// them there (their constants as Spotify set them kept to go back to), or through its frame when it is laid
// out by frame. A frame alone does not move a view laid out by constraints, nor what is constrained inside
// it (harness/tabbar). NO, with nothing changed, when its edges are held some other way, or right to left.
static NSMapTable<NSLayoutConstraint *, NSNumber *> *sg_constants;
static CGRect sg_fullFrame, sg_narrowFrame;

static void restoreEdges(UIView *bar) {
    for (NSLayoutConstraint *constraint in sg_constants) constraint.constant = [[sg_constants objectForKey:constraint] doubleValue];
    [sg_constants removeAllObjects];
    if (bar.translatesAutoresizingMaskIntoConstraints && CGRectEqualToRect(bar.frame, sg_narrowFrame)) bar.frame = sg_fullFrame;
    sg_narrowFrame = CGRectNull;
}

static BOOL setEdges(UIView *bar, CGFloat left, CGFloat right) {
    UIView *superview = bar.superview;
    if (!superview) return NO;
    if (bar.translatesAutoresizingMaskIntoConstraints) {
        CGRect frame = CGRectMake(left, bar.frame.origin.y, right - left, bar.frame.size.height);
        if (!CGRectEqualToRect(bar.frame, sg_narrowFrame)) sg_fullFrame = bar.frame;
        sg_narrowFrame = frame;
        if (!CGRectEqualToRect(bar.frame, frame)) bar.frame = frame;
        return YES;
    }
    if (superview.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft) return NO;
    if (!sg_constants) sg_constants = [NSMapTable weakToStrongObjectsMapTable];
    NSUInteger held = 0;
    BOOL changed = NO;
    for (NSLayoutConstraint *constraint in superview.constraints) {
        NSLayoutAttribute attribute = constraint.firstAttribute;
        BOOL barFirst = constraint.firstItem == bar && constraint.secondItem == superview;
        if (!constraint.active || constraint.relation != NSLayoutRelationEqual || constraint.multiplier != 1 || attribute != constraint.secondAttribute
            || (!barFirst && !(constraint.secondItem == bar && constraint.firstItem == superview))) continue;
        BOOL isLeft = attribute == NSLayoutAttributeLeading || attribute == NSLayoutAttributeLeft;
        if (!isLeft && attribute != NSLayoutAttributeTrailing && attribute != NSLayoutAttributeRight) continue;
        if (![sg_constants objectForKey:constraint]) [sg_constants setObject:@(constraint.constant) forKey:constraint];
        CGFloat edge = isLeft ? 0 : superview.bounds.size.width, value = isLeft ? left : right;
        CGFloat constant = barFirst ? value - edge : edge - value;
        if (fabs(constraint.constant - constant) > 0.05) {
            constraint.constant = constant;
            changed = YES;
        }
        held |= isLeft ? 1 : 2;
    }
    if (held == 3) {
        if (changed) [superview setNeedsLayout];
        return YES;
    }
    restoreEdges(bar);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"now playing bar: its edges are not held by its superview's constraints, so it keeps Spotify's"); });
    return NO;
}

static BOOL hasPlayableNextTrack(SPTPlayerState *state) {
    if (!state) return YES;
    SPTPlayerOptions *opts = [state respondsToSelector:@selector(options)] ? state.options : nil;
    if (opts.repeatingContext || opts.repeatingTrack) return YES;
    SEL restSel = NSSelectorFromString(@"restrictions");
    id restrictions = [state respondsToSelector:restSel] ? ((id (*)(id, SEL))objc_msgSend)(state, restSel) : nil;
    SEL disallowSel = NSSelectorFromString(@"disallowSkippingToNextTrack");
    if (restrictions && [restrictions respondsToSelector:disallowSel]) {
        if (((BOOL (*)(id, SEL))objc_msgSend)(restrictions, disallowSel)) return NO;
    }
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    Class trackClass = objc_getClass("SPTPlayerTrack");
    for (id item in [future isKindOfClass:NSArray.class] ? future : @[]) {
        if (trackClass && ![item isKindOfClass:trackClass]) continue;
        SPTPlayerTrack *t = (SPTPlayerTrack *)item;
        NSString *uri = SGURIString([t respondsToSelector:@selector(URI)] ? t.URI : nil);
        NSString *title = [t respondsToSelector:@selector(trackTitle)] ? t.trackTitle : nil;
        if (title.length > 0 && uri.length > 0 && ![uri containsString:@"delimiter"]) return YES;
    }
    return NO;
}

static __weak SGRGlyphView *sg_barPlayGlyph;
static __weak UIView *sg_barPlayView;
static CFTimeInterval sg_barPlayTappedUntil;
static BOOL sg_barPlayTappedPaused;

@interface SGRBarNextButton : UIButton
@property (nonatomic, weak) UIView *fallbackPlayView;
- (void)updateAvailability:(BOOL)animated;
@end

static __weak SGRBarNextButton *sg_barNextButton;

static void refreshBarPlayGlyph(BOOL animated) {
    SGRGlyphView *glyph = sg_barPlayGlyph;
    SPTPlayerState *state = SGPlayerState();
    if (!glyph || !state) return;
    if (CACurrentMediaTime() < sg_barPlayTappedUntil) {
        if (state.isPaused != sg_barPlayTappedPaused) return;
        sg_barPlayTappedUntil = 0;
    }
    [glyph setSymbol:(state.isPaused ? @"play.fill" : @"pause.fill") animated:animated];
}

@interface SGRBarPlayWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGRBarPlayWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    refreshBarPlayGlyph(YES);
    [sg_barNextButton updateAvailability:YES];
}
- (void)barPlayTapped {
    SGRGlyphView *glyph = sg_barPlayGlyph;
    if (!glyph) return;
    sg_barPlayTappedPaused = ![glyph.symbol isEqualToString:@"play.fill"];
    sg_barPlayTappedUntil = CACurrentMediaTime() + 1.0;
    [glyph setSymbol:(sg_barPlayTappedPaused ? @"play.fill" : @"pause.fill") animated:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        refreshBarPlayGlyph(YES);
    });
}
@end

static SGRBarPlayWatcher *sg_barPlayWatcher;

static void styleBarPlayButton(UIView *play) {
    if (!play) return;
    SPTPlayerState *state = SGPlayerState();
    __block UIControl *control = [play isKindOfClass:UIControl.class] ? (UIControl *)play : nil;
    if (!control) {
        SGForEachView(play, ^(UIView *v) {
            if (!control && [v isKindOfClass:UIControl.class]) control = (UIControl *)v;
        });
    }
    UIView *host = control ?: play;
    if (host.bounds.size.width < 1) {
        [UIView performWithoutAnimation:^{
            [play setNeedsLayout];
            [play layoutIfNeeded];
        }];
    }
    SGRGlyphView *glyph = objc_getAssociatedObject(play, &kPlayGlyphKey);
    if (!glyph) {
        BOOL paused = state ? state.isPaused : YES;
        glyph = [[SGRGlyphView alloc] initWithSymbol:(paused ? @"play.fill" : @"pause.fill")
                                           pointSize:19.0
                                              weight:UIImageSymbolWeightRegular];
        objc_setAssociatedObject(play, &kPlayGlyphKey, glyph, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    SGForEachView(host, ^(UIView *v) {
        if (v == host || v == glyph || [v isDescendantOfView:glyph]) return;
        if ([v isKindOfClass:UIImageView.class] || [NSStringFromClass(v.class) containsString:@"IconView"]) {
            v.alpha = 0;
        }
    });
    if (glyph.superview != host) {
        glyph.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                               | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [host addSubview:glyph];
    } else if (host.subviews.lastObject != glyph) {
        [host bringSubviewToFront:glyph];
    }
    // In the Music app's mini player play stands 2 pt left of where Spotify's button centers it (its recording, 3x:
    // 888.5 px against 894.5), a little further from Next.
    CGFloat inward = (SGRIsBarCompact() && SGRIsBarNextButtonEnabled() && !sg_inline) ? -2.0 : 0;
    CGSize hostSize = host.bounds.size;
    if (hostSize.width >= 1 && hostSize.height >= 1) {
        glyph.center = CGPointMake(hostSize.width / 2.0 + inward, hostSize.height / 2.0);
    }
    if (control && !objc_getAssociatedObject(control, &kPlayTapHookedKey)) {
        [control addTarget:sg_barPlayWatcher action:@selector(barPlayTapped) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(control, &kPlayTapHookedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    sg_barPlayView = play;
    sg_barPlayGlyph = glyph;
    refreshBarPlayGlyph(NO);
}

// Apple Music's mini player shows Play/Pause + Next (`forward.fill`) when expanded above the tab bar,
// and Play/Pause alone when minimized into the tab bar's inline row.
@implementation SGRBarNextButton {
    UIView *_glyphHost;
    UIImageView *_incomingArrow;
    UIImageView *_leftArrow;
    UIImageView *_rightArrow;
    NSUInteger _animToken;
}

// The Music app's Next is two 16 pt arrows 12 pt apart, 24 x 13 pt in all (its recording, 3x: 72 x 40 px).
static const CGFloat kSkipArrowOffset = 6.0;

static UIImageView *makeSkipArrow(void) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightRegular];
    UIImage *img = [[UIImage systemImageNamed:@"play.fill" withConfiguration:cfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.tintColor = SGRPrimary();
    iv.contentMode = UIViewContentModeCenter;
    [iv sizeToFit];
    return iv;
}

+ (instancetype)button {
    SGRBarNextButton *btn = [self buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, 0, 42, 44);
    btn->_glyphHost = [[UIView alloc] initWithFrame:btn.bounds];
    btn->_glyphHost.userInteractionEnabled = NO;
    btn->_glyphHost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [btn addSubview:btn->_glyphHost];
    btn->_incomingArrow = makeSkipArrow();
    btn->_leftArrow = makeSkipArrow();
    btn->_rightArrow = makeSkipArrow();
    btn->_incomingArrow.alpha = 0;
    [btn->_glyphHost addSubview:btn->_incomingArrow];
    [btn->_glyphHost addSubview:btn->_leftArrow];
    [btn->_glyphHost addSubview:btn->_rightArrow];
    [btn resetArrows];
    btn.accessibilityIdentifier = @"SPTNowPlayingNextTrackButton";
    btn.accessibilityLabel = @"Next";
    [btn addTarget:btn action:@selector(sgr_skipNext) forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_incomingArrow.alpha < 0.01) [self resetArrows];
}

- (void)resetArrows {
    CGPoint mid = CGPointMake(CGRectGetMidX(_glyphHost.bounds), CGRectGetMidY(_glyphHost.bounds));
    CGPoint leftPos = CGPointMake(mid.x - kSkipArrowOffset, mid.y);
    CGPoint rightPos = CGPointMake(mid.x + kSkipArrowOffset, mid.y);
    _incomingArrow.transform = CGAffineTransformMakeScale(0.2, 0.2);
    _incomingArrow.center = leftPos;
    _incomingArrow.alpha = 0.0;
    _leftArrow.transform = CGAffineTransformIdentity;
    _leftArrow.center = leftPos;
    _leftArrow.alpha = 1.0;
    _rightArrow.transform = CGAffineTransformIdentity;
    _rightArrow.center = rightPos;
    _rightArrow.alpha = 1.0;
}

- (void)animateSkip {
    NSUInteger token = ++_animToken;
    CGPoint mid = CGPointMake(CGRectGetMidX(_glyphHost.bounds), CGRectGetMidY(_glyphHost.bounds));
    CGPoint leftPos = CGPointMake(mid.x - kSkipArrowOffset, mid.y);
    CGPoint rightPos = CGPointMake(mid.x + kSkipArrowOffset, mid.y);
    [UIView performWithoutAnimation:^{
        [self resetArrows];
    }];
    [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        _incomingArrow.transform = CGAffineTransformIdentity;
        _incomingArrow.center = leftPos;
        _incomingArrow.alpha = 1.0;
        _leftArrow.center = rightPos;
        _rightArrow.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.35, 0.35), CGAffineTransformMakeTranslation(4.0, 0));
        _rightArrow.alpha = 0.0;
    } completion:^(BOOL finished) {
        if (_animToken != token) return;
        [UIView performWithoutAnimation:^{
            [self resetArrows];
        }];
    }];
}

- (void)updateAvailability:(BOOL)animated {
    if (self.hidden) return;
    BOOL canSkip = hasPlayableNextTrack(SGPlayerState());
    self.enabled = canSkip;
    void (^apply)(void) = ^{
        self.alpha = canSkip ? 1.0 : 0.35;
    };
    if (animated && self.window) {
        SGRAnimate(SGRMotionFade, apply, nil);
    } else {
        apply();
    }
}

- (void)sgr_skipNext {
    if (!hasPlayableNextTrack(SGPlayerState())) {
        [self updateAvailability:YES];
        return;
    }
    [self animateSkip];
    id player = SGPlayer();
    if ([player respondsToSelector:@selector(skipToNextTrackWithOptions:)]) {
        [(id<SPTPlayer>)player skipToNextTrackWithOptions:nil];
    } else if ([player respondsToSelector:@selector(skipToNextTrack)]) {
        [(id<SPTPlayer>)player skipToNextTrack];
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    UIView *iv = _glyphHost;
    SGRAnimate(SGRMotionPress, ^{
        iv.alpha = highlighted ? 0.5 : 1.0;
        iv.transform = highlighted ? CGAffineTransformMakeScale(0.9, 0.9) : CGAffineTransformIdentity;
    }, nil);
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return gestureRecognizer.view == self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(42, 44);
}
@end

static SGRBarNextButton *ensureNextButton(UIView *bar) {
    if (!bar) return nil;
    SGRBarNextButton *next = objc_getAssociatedObject(bar, &kNextButtonKey);
    __block UIView *play = nil;
    SGForEachView(bar, ^(UIView *v) {
        if (!play && [v.accessibilityIdentifier isEqualToString:@"SPTNowPlayingPlayButton"]) play = v;
    });
    if (!play) {
        UIView *card = sg_card ?: bar;
        SGForEachView(card, ^(UIView *v) {
            if (!play && [v isKindOfClass:UIButton.class] && ![v isKindOfClass:SGRBarNextButton.class]
                && !inStrip(v, card) && !insideInformationContainer(v, card)) {
                play = v;
            }
        });
    }
    if (!play) return next;
    styleBarPlayButton(play);

    if (!next) {
        next = [SGRBarNextButton button];
        objc_setAssociatedObject(bar, &kNextButtonKey, next, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    sg_barNextButton = next;
    BOOL showNext = SGRIsBarNextButtonEnabled();
    if (!showNext) {
        next.hidden = YES;
        next.alpha = 0;
    } else if (!next.hidden && ![next.layer animationForKey:@"opacity"]) {
        [next updateAvailability:NO];
    }

    UIView *playItem = play;
    while (playItem.superview && playItem.superview != bar && ![playItem.superview isKindOfClass:UIStackView.class]) {
        playItem = playItem.superview;
    }
    if ([playItem.superview isKindOfClass:UIStackView.class] && ((UIStackView *)playItem.superview).axis == UILayoutConstraintAxisHorizontal) {
        UIStackView *stack = (UIStackView *)playItem.superview;
        next.fallbackPlayView = nil;
        if (next.superview != stack) {
            [UIView performWithoutAnimation:^{
                next.translatesAutoresizingMaskIntoConstraints = NO;
                NSLayoutConstraint *w = [next.widthAnchor constraintEqualToConstant:42];
                NSLayoutConstraint *h = [next.heightAnchor constraintEqualToConstant:44];
                // Priority 999 avoids unsatisfiable constraint conflicts when UIStackView hides `next` (width == 0 @ 1000).
                w.priority = 999;
                h.priority = 999;
                [NSLayoutConstraint activateConstraints:@[w, h]];
                [next setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
                [next setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
                [stack addArrangedSubview:next];
            }];
        }
    } else {
        UIView *host = play.superview ?: bar;
        next.fallbackPlayView = play;
        if (next.superview != host) {
            next.translatesAutoresizingMaskIntoConstraints = YES;
            next.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            [host addSubview:next];
        }
        next.frame = CGRectMake(host.bounds.size.width - 50, round((host.bounds.size.height - 44) / 2.0), 42, 44);
    }
    return next;
}

// In the row the card keeps the cover, the title and play, as the Music app's does: the device and add
// buttons stand aside while it is there and come back with the full card, the device button staying when the
// Player page's Device button asks for it (SGRKeyBarInlineConnect). Only what this hid is shown again.
static NSHashTable<UIView *> *sg_tucked;

static void tuckExtras(UIView *bar, BOOL tuck) {
    if (!bar) return;
    if (!sg_tucked) sg_tucked = [NSHashTable weakObjectsHashTable];
    BOOL compact = SGRIsBarCompact();
    BOOL keepInlineConnect = SGHidden(SGRKeyBarInlineConnect);
    BOOL hideFullConnect = SGHidden(SGRHideBarConnect);
    BOOL showNext = SGRIsBarNextButtonEnabled();
    SGRBarNextButton *next = ensureNextButton(bar);

    if (!tuck) {
        NSArray<UIView *> *items = sg_tucked.allObjects;
        [sg_tucked removeAllObjects];
        NSMutableArray<UIView *> *restored = [NSMutableArray array];
        [UIView performWithoutAnimation:^{
            for (UIView *item in items) {
                if (item == next && !showNext) continue;
                item.alpha = 0;
                item.hidden = NO;
                [restored addObject:item];
            }
            if (next) {
                if (!showNext) {
                    next.hidden = YES;
                    next.alpha = 0;
                } else if (next.hidden) {
                    next.alpha = 0;
                    next.hidden = NO;
                    if (![restored containsObject:next]) [restored addObject:next];
                } else if (![restored containsObject:next] && next.alpha < 1.0 && ![next.layer animationForKey:@"opacity"]) {
                    [restored addObject:next];
                }
                if (next.fallbackPlayView) {
                    next.fallbackPlayView.transform = showNext ? CGAffineTransformMakeTranslation(-42.0, 0) : CGAffineTransformIdentity;
                }
            }
            SGForEachView(bar, ^(UIView *v) {
                if (insideInformationContainer(v, bar)) return;
                NSString *name = v.accessibilityIdentifier;
                Class cls = v.class;
                BOOL connect = [name isEqualToString:@"Components.ConnectButtonOutputSwitcher"] ||
                               SGClassNamed(cls, @"ConnectButtonView") || SGClassNamed(cls, @"ConnectStateView");
                if (!connect) return;
                UIView *item = v;
                while (item.superview && item.superview != bar && ![item.superview isKindOfClass:UIStackView.class]) item = item.superview;
                if (![item.superview isKindOfClass:UIStackView.class] || insideInformationContainer(item, bar)) return;
                if (item.bounds.size.width > 64) return;
                if (hideFullConnect) {
                    item.hidden = YES;
                    item.alpha = 0;
                    [restored removeObject:item];
                } else if (item.hidden) {
                    item.alpha = 0;
                    item.hidden = NO;
                    if (![restored containsObject:item]) [restored addObject:item];
                }
            });
        }];
        if (restored.count) {
            SGRAnimate(SGRMotionFade, ^{
                for (UIView *item in restored) {
                    if (item == next) [next updateAvailability:NO];
                    else item.alpha = 1;
                }
            }, nil);
        }
        return;
    }

    [UIView performWithoutAnimation:^{
        if (next) {
            if (!next.hidden) {
                next.hidden = YES;
                next.alpha = 0;
                [sg_tucked addObject:next];
            }
            if (next.fallbackPlayView) {
                next.fallbackPlayView.transform = CGAffineTransformIdentity;
            }
        }

        SGForEachView(bar, ^(UIView *v) {
            // Never touch ConnectStateView inside InformationContainer (the "playing on..." subtitle row):
            // walking up from it reaches InformationContainer itself and collapses the entire text column.
            if (insideInformationContainer(v, bar)) return;
            NSString *name = v.accessibilityIdentifier;
            Class cls = v.class;
            BOOL connect = [name isEqualToString:@"Components.ConnectButtonOutputSwitcher"] ||
                           SGClassNamed(cls, @"ConnectButtonView") || SGClassNamed(cls, @"ConnectStateView");
            if (!connect && ![name isEqualToString:@"Components.UI.AddToButton"]) return;
            UIView *item = v;
            while (item.superview && item.superview != bar && ![item.superview isKindOfClass:UIStackView.class]) item = item.superview;
            if (![item.superview isKindOfClass:UIStackView.class] || insideInformationContainer(item, bar)) return;
            if (item.bounds.size.width > 64) return;
            if (connect && keepInlineConnect && !compact) {
                if (item.hidden) {
                    item.hidden = NO;
                    item.alpha = 1;
                }
                return;
            }
            if (item.hidden) return;
            item.hidden = YES;
            item.alpha = 0;
            [sg_tucked addObject:item];
        });
    }];
}

// The Music app's two lines, the title over the artists, in place of Spotify's "title • artists" and the
// device line under it; the title over the artists in the minimized row too. Each swipe page holds its own track's labels,
// so the text is read from them and drawn over them page by page. The page reads its own VoiceOver label.
@interface SGRBarText : UIView
@property (nonatomic, readonly) SGMarqueeLabel *title, *artists;
@property (nonatomic) BOOL inRow;
@end

@implementation SGRBarText
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    _title = [SGMarqueeLabel new];
    _title.textColor = SGRPrimary();
    _title.font = SGRFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, UIContentSizeCategoryLarge);
    _artists = [SGMarqueeLabel new];
    _artists.textColor = SGRSecondary();
    _artists.font = SGRFont(UIFontTextStyleFootnote, UIFontWeightRegular, UIContentSizeCategoryLarge);
    [self addSubview:_title];
    [self addSubview:_artists];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [UIView performWithoutAnimation:^{
        CGSize size = self.bounds.size;
        BOOL compact = SGRIsBarCompact();
        _title.textColor = SGRPrimary();
        _artists.textColor = SGRIncreaseContrast() ? SGRSecondary() : [UIColor colorWithWhite:0xB3 / 255.0 alpha:1.0];
        if (compact) {
            _title.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
            _artists.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        } else {
            _title.font = SGRFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, UIContentSizeCategoryLarge);
            _artists.font = SGRFont(UIFontTextStyleFootnote, UIFontWeightRegular, UIContentSizeCategoryLarge);
        }
        CGFloat titleHeight = ceil(_title.font.lineHeight), artistsHeight = ceil(_artists.font.lineHeight);
        BOOL two = _artists.text.length > 0;
        // The lines share 1.5pt of their leading in compact (~14.5pt baseline-to-baseline), 2pt normally.
        CGFloat shared = compact ? 1.5 : 2.0;
        CGFloat totalH = titleHeight + (two ? artistsHeight - shared : 0);
        CGFloat top = round((size.height - totalH) / 2.0);
        _title.frame = CGRectMake(0, top, size.width, titleHeight);
        _artists.frame = CGRectMake(0, top + titleHeight - shared, size.width, artistsHeight);
        _artists.alpha = two ? 1.0 : 0.0;
        [_title layoutIfNeeded];
        [_artists layoutIfNeeded];
    }];
}
@end

static NSString *marqueeText(UIView *marquee) {
    for (UIView *sub in marquee.subviews) if ([sub isKindOfClass:UILabel.class]) return ((UILabel *)sub).text;
    return nil;
}

// Not hidden or faded by Spotify between the view and the unit; the unit's own children are faded by this file.
static BOOL inSight(UIView *view, UIView *unit) {
    for (UIView *v = view; v && v != unit; v = v.superview) {
        if (v.hidden || (v.alpha < 0.01 && v.superview != unit)) return NO;
    }
    return YES;
}

static BOOL sg_placingText;

static void placeText(UIView *page) {
    if (!page || sg_placingText) return;
    sg_placingText = YES;
    // Ensure page's subviews and unit have settled their frames on cold launch when layout is top-down.
    if (!sg_barMoves) {
        [UIView performWithoutAnimation:^{
            [page layoutIfNeeded];
            for (UIView *sub in page.subviews) [sub layoutIfNeeded];
        }];
    }
    __block UIView *unit = nil;
    SGForEachView(page, ^(UIView *v) {
        if (!unit && [v.accessibilityIdentifier isEqualToString:kUnitId]) unit = v;
    });
    if (unit && !sg_barMoves) {
        [UIView performWithoutAnimation:^{
            [unit.superview layoutIfNeeded];
            [unit layoutIfNeeded];
        }];
    }
    // Spotify lays a page out two ways. With a device line under it, the unit's first marquee is "title • artists"
    // and a later one, hidden, holds the artists alone. Without one, the first is the title and the next one in
    // sight is the artists. A promotional line, held at no alpha, is never the artists.
    __block NSString *line = nil, *artists = nil, *shown = nil;
    if (unit) SGForEachView(unit, ^(UIView *v) {
        if (![v.accessibilityIdentifier isEqualToString:@"Encore.MarqueeLabel"]) return;
        NSString *text = marqueeText(v);
        if (!line) {
            line = text;
            return;
        }
        if (!text.length) return;
        if (!artists && [line hasSuffix:[kBullet stringByAppendingString:text]]) artists = text;
        if (!shown && inSight(v, unit)) shown = text;
    });
    if (!line.length || !unit) {
        sg_placingText = NO;
        return;
    }
    NSString *title = line;
    if (artists) {
        title = [line substringToIndex:line.length - artists.length - kBullet.length];
    } else {
        NSRange bullet = [line rangeOfString:kBullet];
        if (bullet.location != NSNotFound) {
            title = [line substringToIndex:bullet.location];
            artists = [line substringFromIndex:NSMaxRange(bullet)];
        } else {
            artists = shown;
        }
    }

    SGRBarText *text = objc_getAssociatedObject(page, &kTextKey);
    if (!text) {
        text = [SGRBarText new];
        objc_setAssociatedObject(page, &kTextKey, text, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Inside Spotify's unit, spanning the page's height so the two lines center vertically from launch.
    CGFloat width = unit.bounds.size.width > 8.0 ? unit.bounds.size.width : page.bounds.size.width;
    CGFloat height = page.bounds.size.height > 8.0 ? page.bounds.size.height : (SGRIsBarCompact() ? 48.0 : 56.0);
    CGFloat unitY = SGFrameIn(unit, page).origin.y;
    CGRect frame = CGRectMake(0, -unitY, width, height);
    BOOL inRow = sg_inline != nil;
    void (^place)(void) = ^{
        if (text.superview != unit) [unit addSubview:text];
        else if (unit.subviews.lastObject != text) [unit bringSubviewToFront:text];
        if (!CGRectEqualToRect(text.frame, frame)) text.frame = frame;
        text.title.text = title;
        text.artists.text = artists ?: @"";
        // Every pass: the artists can come in after the title.
        text.inRow = inRow;
        [text setNeedsLayout];
        [text layoutIfNeeded];
    };
    // Placed without animating UILabel bounds/position so kCAGravityCenter never shifts the text left mid-spring.
    [UIView performWithoutAnimation:place];
    for (UIView *sub in unit.subviews) if (sub != text && sub.alpha > 0) sub.alpha = 0;
    sg_placingText = NO;
}

static void placeTexts(UIView *bar) {
    SGForEachView(bar, ^(UIView *v) {
        if (SGClassNamed(v.class, @"InformationContainer")) {
            v.clipsToBounds = YES;
            if (v.hidden) v.hidden = NO;
            if (v.alpha < 1.0) v.alpha = 1.0;
        }
        NSString *name = v.accessibilityIdentifier;
        if ([name isEqualToString:kPageId]) placeText(v);
        else if ([name isEqualToString:kDeviceLineId] && v.alpha > 0) v.alpha = 0;
    });
}

// In the minimized tab bar's row (TabBar.x): the bar narrowed to the slot by its edges, so Spotify's content
// lays itself out to the width, and moved down by a transform on the container's view, which Spotify's
// layout leaves alone. The slot is the track card's height and the card is centred in it; in a Jam the strip,
// on the bar above the card, rides above the row. A bar taller than its card for any other reason (a hat this
// file does not know) stays above the tab bar.
static const CGFloat kHatMin = 20;

// The Jam strip the bar was last styled with, shown or not: the tab bar's move lays the bar out again without
// styling it, and a second walk of the bar on each pass for it was a cost of its own.
static __weak UIView *sg_strip;

// Class names and frames only: a hat's labels can hold the track and the names of the people in a Jam.
static void appendShape(UIView *view, NSUInteger depth, NSMutableString *out) {
    [out appendFormat:@"%*s%@ %@\n", (int)depth * 2, "", NSStringFromClass(view.class), NSStringFromCGRect(view.frame)];
    if (depth < 8) for (UIView *sub in view.subviews) appendShape(sub, depth + 1, out);
}

// The bar's edges set to `r`'s sides, `r` in the slot's coordinates and the view standing at `origin` in them.
static BOOL edgesTo(UIView *bar, CGRect r, CGPoint origin) {
    return !CGRectIsNull(r) && setEdges(bar, CGRectGetMinX(r) - origin.x, CGRectGetMaxX(r) - origin.x);
}

// Under a slow downward scroll before crossing the minimize threshold, the mini player card compresses and
// pulls slightly down toward the tab bar with physical rubber-band resistance alongside the tab bar.
static CGAffineTransform uninlineTransform(UIView *bar) {
    BOOL compact = SGRIsBarCompact();
    CGFloat dy = (compact && bar && bar.bounds.size.height > 48.0) ? round((bar.bounds.size.height - 48.0) / 2.0) : 0;
    CGFloat r = (!sg_inline && sg_scrollSquish > 0) ? (sg_scrollSquish / (1.0 + 0.45 * sg_scrollSquish)) : 0;
    CGFloat scale = 1.0 - 0.036 * r;
    CGFloat totalDy = dy + 4.0 * r;
    CGAffineTransform t = fabs(totalDy) > 0.01 ? CGAffineTransformMakeTranslation(0, totalDy) : CGAffineTransformIdentity;
    if (r > 0.0005) {
        t = CGAffineTransformConcat(CGAffineTransformMakeScale(scale, scale), t);
    }
    return t;
}

void SGRNowPlayingBarSetScrollSquish(CGFloat progress) {
    progress = MIN(1.0, MAX(0.0, progress));
    if (fabs(progress - sg_scrollSquish) < 0.001) return;
    sg_scrollSquish = progress;
    UIViewController *container = sg_container;
    if (!container.isViewLoaded || sg_inline) return;
    UIView *bar = container.childViewControllers.firstObject.viewIfLoaded;
    CGAffineTransform rest = uninlineTransform(bar);
    if (!CGAffineTransformEqualToTransform(container.view.transform, rest)) container.view.transform = rest;
}

static void placeInline(UIViewController *container) {
    UIView *view = container.view;
    UIView *bar = container.childViewControllers.firstObject.viewIfLoaded;
    CGRect track = CGRectIsNull(sg_trackFrame) ? bar.frame : sg_trackFrame;
    // A hat is a row of its own (the Jam's is 44pt); a few points between card and bar are not one.
    BOOL hat = bar && bar.bounds.size.height - track.size.height >= kHatMin;
    UIView *strip = hat && [sg_strip isDescendantOfView:bar] ? sg_strip : nil;
    BOOL known = !hat || strip;
    if (!known) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSMutableString *shape = [NSMutableString string];
            appendShape(bar, 0, shape);
            SGLogLong(@"now playing bar", [NSString stringWithFormat:@"a hat on the bar that is not the Jam's keeps the card out of the "
                                          @"tab bar's row: card %@, bar %@\n%@", NSStringFromCGRect(track), NSStringFromCGRect(bar.frame), shape]);
        });
    }
    CGRect slot = !bar || bar.superview != view || !known ? CGRectNull : SGRTabBarInlineSlot(view.superview, track.size.height);
    // Where the view stands untransformed, in the slot's coordinates.
    CGPoint origin = CGPointMake(view.center.x - view.bounds.size.width / 2, view.center.y - view.bounds.size.height / 2);
    if (!edgesTo(bar, slot, origin)) {
        tuckExtras(bar, NO);
        sg_inline = nil;
        // Above the bar the card takes the glass row's edges (SGRTabBarGlassRow).
        CGRect row = bar && bar.superview == view ? SGRTabBarGlassRow(view.superview) : CGRectNull;
        if (!edgesTo(bar, row, origin)) restoreEdges(bar);
        CGAffineTransform rest = uninlineTransform(bar);
        if (!CGAffineTransformEqualToTransform(view.transform, rest)) view.transform = rest;
        return;
    }
    CGAffineTransform move = CGAffineTransformMakeTranslation(0, CGRectGetMidY(slot) - origin.y - CGRectGetMidY(track));
    if (!CGAffineTransformEqualToTransform(view.transform, move)) view.transform = move;
    tuckExtras(bar, YES);
    sg_inline = view;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableString *clips = [NSMutableString string];
        for (UIView *v = view.superview; v; v = v.superview) if (v.clipsToBounds) [clips appendFormat:@" %@", v.class];
        SGLog(@"now playing bar in the tab bar's row at %@, clipped by:%@", NSStringFromCGRect(slot), clips.length ? clips : @" nothing");
    });
    // Whether the strip followed the bar's narrowed edges, which no recorded tree shows.
    static dispatch_once_t jamOnce;
    if (strip) dispatch_once(&jamOnce, ^{
        SGLog(@"now playing bar in the tab bar's row in a Jam: strip %@, bar %@, card %@ (in the container's view)",
              NSStringFromCGRect(SGFrameIn(strip, view)), NSStringFromCGRect(bar.frame), NSStringFromCGRect(track));
    });
}

static void styleNowPlayingBar(UIViewController *container);

void SGRNowPlayingBarFollowTabBar(void) {
    UIViewController *container = sg_container;
    if (!container.isViewLoaded) return;
    resetArtworkTransform(sg_card);
    styleNowPlayingBar(container);
    [container.view layoutIfNeeded];
    SGRSnackbarFollowNowPlayingBar();
    SGRTooltipFollowNowPlayingBar();
}

CGFloat SGRNowPlayingBarInlineShift(void) {
    UIView *view = sg_inline;
    return view ? view.transform.ty : 0;
}

CGFloat SGRNowPlayingBarShiftOver(CGRect frame, UIWindow *window) {
    CGFloat shift = SGRNowPlayingBarInlineShift();
    if (shift == 0 || !window) return 0;
    CGRect bar = SGRNowPlayingCardFrameIn(window, NULL);
    if (CGRectIsNull(bar)) return shift;
    return CGRectGetMaxY(frame) <= CGRectGetMinY(bar) - shift + 24 ? shift : 0;
}

CGRect SGRNowPlayingStripFrameIn(UIView *host) {
    UIView *strip = sg_strip;
    if (SGRNowPlayingStripHeight() <= 0 || !host || ![strip isDescendantOfView:host]) return CGRectNull;
    return [host convertRect:strip.bounds fromView:strip];
}

static void relayoutBar(UIView *host, BOOL taller) {
    if (sg_barMoves > 0) {
        sg_owedLayout = YES;
        sg_owedRefresh |= taller;
        return;
    }
    [host setNeedsLayout];
    if (taller) SGRRefreshTabBar();
}

void SGRNowPlayingBarMoving(BOOL moving) {
    UIView *strip = sg_strip;
    if (moving) {
        // Spotify's own strip-in animation would race the tab bar's spring: the strip goes to where it is set.
        if (sg_barMoves++ == 0 && SGRNowPlayingStripHeight() > 0 && strip.window && strip.layer.animationKeys.count) [strip.layer removeAllAnimations];
        return;
    }
    if (sg_barMoves == 0 || --sg_barMoves > 0) return;
    UIView *host = sg_container.viewIfLoaded;
    if (sg_owedLayout && host) relayoutBar(host, sg_owedRefresh);
    sg_owedLayout = sg_owedRefresh = NO;
    static dispatch_once_t once;
    if (host && SGRNowPlayingStripHeight() > 0 && [strip isDescendantOfView:host]) dispatch_once(&once, ^{
        SGLog(@"now playing bar: tab bar move ended in a Jam, strip %@, card glass %@ (in the container's view)",
              NSStringFromCGRect(SGFrameIn(strip, host)), NSStringFromCGRect(SGFrameIn(sg_cardGlass, host)));
    });
}

// The same bar class also stands at the top of Spotify's sheets (the DJ request one: Up next, device, play).
// It is not the tab bar's card there: the sheet has its own blue ground and corners, and a dark 24pt pane of
// the bar's full width on it reads as a frame round the track. It is left as Spotify draws it, and it must not
// become the bar this file tracks (sg_container, sg_cardGlass, sgr_nowPlayingRoot): the player takes its card
// frame from those.
static BOOL inSheet(UIView *view) {
    for (UIView *v = view.superview; v; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:@"sheet-view"] || SGClassNamed(v.class, @"SheetImpl")) return YES;
    }
    return NO;
}

// Whether the controller stands in something presented over the app (a sheet), by its controllers rather than its views:
// the DJ request sheet's bar lays out again as the sheet comes back, before its view is in the sheet, and taken then for
// the tab bar's own it became the bar the tab bar's minimizing and the player's transitions follow, which broke both
// until Spotify restarted.
static BOOL inPresented(UIViewController *controller) {
    UIViewController *root = controller;
    while (root.parentViewController) root = root.parentViewController;
    return root.presentingViewController != nil;
}

// The card's glass frame in `host`: the card, else the box round the track's content, with the strip cut
// out from its side, all of it when the card is a view around both, else as much as overlaps. CGRectNull
// when there is no card to speak of.
static CGRect trackFrame(UIView *bar, UIView *card, UIView *strip, CGRect stripFrame, UIView *host, BOOL *stripAbove) {
    CGRect frame = card ? SGFrameIn(card, host) : contentBounds(bar, host);
    if (CGRectIsNull(frame)) return frame;
    *stripAbove = NO;
    if (strip) {
        *stripAbove = CGRectGetMidY(stripFrame) < CGRectGetMidY(frame);
        CGFloat cut = card && [strip isDescendantOfView:card] ? strip.bounds.size.height : CGRectIntersection(frame, stripFrame).size.height;
        frame.size.height -= cut;
        if (*stripAbove) frame.origin.y += cut;
    }
    if (SGRIsBarCompact() && frame.size.height > 50) {
        CGFloat diff = frame.size.height - 48;
        frame.origin.y += round(diff / 2.0);
        frame.size.height = 48;
    }
    frame.size.height = MIN(frame.size.height, 80);
    return frame.size.height < 30 || frame.size.width < 100 ? CGRectNull : frame;
}

static void styleNowPlayingBar(UIViewController *container) {
    if (!container || sg_stylingBar) return;
    if (inPresented(container) || (container.isViewLoaded && inSheet(container.view))) {
        UIVisualEffectView *pane = objc_getAssociatedObject(container.view, &kGlassKey);
        if (pane) [pane removeFromSuperview];
        return;
    }
    sg_stylingBar = YES;
    UIViewController *barVC = container.childViewControllers.firstObject;
    UIView *bar = barVC.viewIfLoaded ?: container.view;
    sg_container = container;
    if (!sgr_nowPlayingPainted) sgr_nowPlayingPainted = [NSHashTable weakObjectsHashTable];
    sgr_nowPlayingRoot = bar;

    // Reset artwork transform before any layout pass so Auto Layout never measures a scaled frame.
    resetArtworkTransform(sg_card);

    // Ensure bar's subviews (the card and its children) have laid out during cold launch's top-down layout pass.
    if (!sg_barMoves) {
        [UIView performWithoutAnimation:^{
            for (UIView *sub in bar.subviews) [sub layoutIfNeeded];
        }];
    }

    // What is painted now, before it goes clear; SGRRepaint.x adds what Spotify paints later. Its size is
    // judged when the card is chosen: in a Jam the card can still be unsized here (harness/tabbar).
    SGForEachView(bar, ^(UIView *v) {
        if (![v isKindOfClass:UIVisualEffectView.class] && !SGKeepsColor(v) && !SGRIsStripAvatar(v) && SGIsVisibleColor(v.layer.backgroundColor)) [sgr_nowPlayingPainted addObject:v];
    });
    // The card stays while it still holds the track with no strip in it, whatever Spotify paints after.
    UIView *marker = trackMarker(bar);
    UIView *card = sg_card;
    if (!card || !isGoodCard(card, bar, marker) || stripIn(card)) card = sg_card = chooseCard(bar, marker);

    // The strip before the bar's paint goes, so the log says what it was made of.
    UIView *strip = sg_strip = stripIn(bar);
    if (strip && (strip.hidden || strip.alpha < 0.01 || !strip.window)) strip = nil;
    static dispatch_once_t stripOnce;
    if (strip) dispatch_once(&stripOnce, ^{
        NSMutableString *tree = [NSMutableString string];
        SGForEachView(strip, ^(UIView *v) {
            CGColorRef paint = v.layer.backgroundColor;
            [tree appendFormat:@"%@ %@ a=%.2f%@\n", v.class, NSStringFromCGRect(SGFrameIn(v, strip)), v.alpha,
                                paint ? [NSString stringWithFormat:@" paint=%@", [UIColor colorWithCGColor:paint]] : @""];
        });
        SGLogLong(@"now playing bar", [NSString stringWithFormat:@"Jam strip %@, controller %@, in the bar: %@ (Spotify's paint inside the "
                                       @"bar is cleared as it is set, SGRRepaint.x)\n%@", strip.class, strip.nextResponder.class,
                                       [strip isDescendantOfView:bar] ? @"yes" : @"no", tree]);
    });

    container.view.layer.backgroundColor = NULL;
    stripBar(bar);

    // Spotify lays the strip out after the bar and moves it in, so the bar is styled again a moment after
    // the strip has moved, until it stays put. A strip that comes, goes or changes height moves the fade too.
    CGRect stripFrame = strip ? SGFrameIn(strip, container.view) : CGRectZero;
    if (!CGRectEqualToRect(stripFrame, sg_stripFrame)) {
        BOOL taller = stripFrame.size.height != sg_stripFrame.size.height;
        sg_stripFrame = stripFrame;
        UIView *host = container.view;
        // During the tab bar's move it waits for the move's end (SGRNowPlayingBarMoving).
        dispatch_async(dispatch_get_main_queue(), ^{ relayoutBar(host, taller); });
    }
    if (strip.bounds.size.height < 1) strip = nil;
    // The track's frame for the row, then again for the glass: the row narrows the bar, which the card follows.
    BOOL stripAbove = NO;
    // A card's, or in a Jam the box round the track's content; outside a Jam without a card the bar's own
    // frame stands for it, as before, since that box is padded.
    sg_trackFrame = card || strip ? trackFrame(bar, card, strip, stripFrame, container.view, &stripAbove) : CGRectNull;
    placeInline(container);

    // Flush any constraint changes from setEdges / tuckExtras so card, artwork, text and buttons have settled frames.
    [container.view layoutIfNeeded];
    [bar layoutIfNeeded];
    if (card) {
        [card layoutIfNeeded];
        for (UIView *sub in card.subviews) [sub layoutIfNeeded];
    }
    placeTexts(bar);

    CGRect frame = trackFrame(bar, card, strip, stripFrame, container.view, &stripAbove);
    if (CGRectIsNull(frame)) {
        sg_stylingBar = NO;
        return;
    }

    CGFloat radius = MIN(kCardRadius, frame.size.height / 2);
    if (card) {
        roundView(card, radius);
        restyleCardContent(card);
    }
    if (sg_barPlayView) {
        styleBarPlayButton(sg_barPlayView);
    }

    UIView *glass = SGGlassFor(container.view, &kGlassKey);
    // Dark whatever the system is set to: the bar is outside the navigation stacks Spotify makes dark, and
    // took the system's light glass on a phone in light mode (TabBar.x).
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    sg_cardGlass = glass;
    glass.frame = frame;
    SGShapeGlass(glass, radius, NO);
    // Dimmed as the tab bar's glass is, so the card's text and buttons stand out over a bright page (below iOS 26).
    SGRDarkenGlass(glass, &kCardDimKey, radius, SGRBarDim);
    placeStripGlass(container.view, strip, frame, stripAbove);

    SGRGlassFilm(container.view, &kTintKey, glass, radius);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"now playing card %@ at %@ (bar %@, container %@)", card.class, NSStringFromCGRect(frame),
              NSStringFromCGRect(bar.frame), NSStringFromCGRect(container.view.bounds));
    });
    static dispatch_once_t jamOnce;
    if (strip) dispatch_once(&jamOnce, ^{
        SGLog(@"now playing card in a Jam: %@ at %@, strip %@ at %@ (bar %@)", card.class, NSStringFromCGRect(frame), strip.class,
              NSStringFromCGRect(SGFrameIn(strip, container.view)), NSStringFromCGRect(bar.frame));
    });
    sg_stylingBar = NO;
}

%hook _TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    styleNowPlayingBar((UIViewController *)self);
}
%end

// The page the bar stands in passes touches outside the bar through, and the bar in the tab bar's row is
// below the page's bounds: a touch there reaches the bar only through this. Only the narrowed card takes
// one: the container's view keeps the screen's width, and took the touches meant for the tab bar's circles.
%hook _TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView
// Spotify hides the bar while Create's menu is up, because the menu covers the bar's place above the tab bar. The
// card in the minimized row is below the menu, so it stays: the minimized bar does not go away with the menu.
- (void)setHidden:(BOOL)hidden {
    if (hidden && SGBelowiOS26() && sg_inline && [sg_inline isDescendantOfView:(UIView *)self] && SGRTabBarMinimized() && SGRCreateMenuUp((UIView *)self)) {
        %orig(NO);
        return;
    }
    %orig;
}

// Only the container's view moves to the row, by a transform; Spotify's layout view above it stays at the
// bar's old place and took every touch there (#70), so a touch on nothing of the moved bar's goes through.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = %orig;
    UIView *moved = sg_inline;
    if (![moved isDescendantOfView:(UIView *)self] || (hit && [hit isDescendantOfView:moved])) return hit;
    UIView *inside = [moved hitTest:[(UIView *)self convertPoint:point toView:moved] withEvent:event];
    return inside && inside != moved ? inside : nil;
}
%end

// A page lays out again when Spotify moves its text, which it does after the first pass at launch.
%hook _TtC18NowPlaying_BarImpl17InformationCellV2
- (void)layoutSubviews {
    %orig;
    if (sgr_nowPlayingRoot && [(UIView *)self isDescendantOfView:sgr_nowPlayingRoot]) placeText((UIView *)self);
}
%end

%hook _TtC18NowPlaying_BarImpl15InformationCell
- (void)layoutSubviews {
    %orig;
    if (sgr_nowPlayingRoot && [(UIView *)self isDescendantOfView:sgr_nowPlayingRoot]) placeText((UIView *)self);
}
%end

// A page's marquee lays out again when Spotify gives it a new track, which nothing else of the bar's does.
%hook _TtCE14Encore_TextKitO16EncoreFoundation6Encore12MarqueeLabel
- (void)layoutSubviews {
    %orig;
    UIView *root = sgr_nowPlayingRoot;
    if (!root || ![(UIView *)self isDescendantOfView:root]) return;
    for (UIView *v = (UIView *)self; v && v != root; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:kPageId]) {
            placeText(v);
            return;
        }
    }
}
%end

%hook _TtC18NowPlaying_BarImpl27NowPlayingBarViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *parent = ((UIViewController *)self).parentViewController;
    if (SGClassNamed(parent.class, @"NowPlayingBarContainer")) styleNowPlayingBar(parent);
}
%end

// The bar is Spotify's to hide and show while the player opens and closes, and Spotify paints it again then (its
// album colour, its gradient) with no layout of the container to bring the glass card back: after a close the bar
// now and then stood in Spotify's own colour above the tab bar until something laid it out. So it is styled again
// once the player has settled, and a little after, as Spotify finishes.
static void restyleAfterPlayer(void) {
    UIViewController *container = sg_container;
    if (!container.isViewLoaded) return;
    styleNowPlayingBar(container);
    SGRRepeatPass(container, SGRSettleDelays, ^(UIViewController *c) { if (c.viewIfLoaded.window) styleNowPlayingBar(c); });
}

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    sg_barPlayWatcher = [SGRBarPlayWatcher new];
    SGAddPlayerStateObserver(sg_barPlayWatcher);
    // Below iOS 26 only: the redesign's iOS 26 bar stays as it is on main.
    if (SGBelowiOS26()) {
        [NSNotificationCenter.defaultCenter addObserverForName:SGPlayerTransitionEndedNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { restyleAfterPlayer(); }];
    }
    SGRequireClasses(@[
        @"_TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController",
        @"_TtC18NowPlaying_BarImpl27NowPlayingBarViewController",
        @"_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView",
        @"_TtCE14Encore_TextKitO16EncoreFoundation6Encore12MarqueeLabel",
        @"_TtC18NowPlaying_BarImpl17InformationCellV2",
    ]);
}

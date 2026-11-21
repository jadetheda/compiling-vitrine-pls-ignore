// Tab bar: Spotify's own bar stays where it is but goes invisible, and a system UITabBar sits on top
// of it. On iOS 26+ with UIDesignRequiresCompatibility off, UIKit draws that bar as real Liquid Glass
// (selection bubble, lensing, light/dark adaptation) with no glass API of ours. Spotify's bar keeps
// its frame, so the page insets and the now playing bar stay where Spotify puts them; where the system
// bar is taller than Spotify's, Spotify is made to leave it the room (see "room for the glass bar").
//
// A tab picked on the system bar is passed on as a tap on the hidden Spotify item it mirrors, and the
// system bar's selection follows whichever Spotify label is painted white, or the tab of the mod's own whose
// page is up (SGRNavbarLitTab), which Spotify does not know of. Navbar.x composes the
// hidden row, so its order, hidden tabs and tabs of the mod's own carry over. Always on in the redesign.
//
// Tree (trees/home.txt): NavigationUI_TabBarImpl.TabBarView > TabBarCompactView > UIStackView of
//   ElementContentView<TabBarItemElement>, each with an SPTEncoreIconView and an SPTEncoreLabel.
#import "Core/SGCore.h"
#import "Navbar.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Settings/SGPage.h"
#import "Shared/Navigation/TabItems.h"
#import "Headers/SPTEncoreIconView.h"
#import "Shared/Navigation/TabIcons.h"
#import <objc/message.h>

static inline BOOL SGRIsBarCompact(void) {
    return SGEnabled(SGRKeyNavbarCompact);
}

static inline BOOL SGRIsBarAutoSplit(void) {
    return SGEnabled(SGRKeyNavbarAutoSplit);
}

static char kBarKey, kApartBarKey, kHostKey, kFadeKey, kTabNameKey, kPlatterSubKey;
// On a UITabBarItem: the names of the Encore icons its image and selectedImage were drawn from (see fillBar).
static char kGlyphNamesKey;
static __weak UIView *sg_stockBar;
// The glass row and inline slot in the window as the now playing card was last told of them (syncBar), CGRectNull for none.
static CGRect sg_glassRow = {{INFINITY, INFINITY}, {0, 0}};
static CGRect sg_inlineSlot = {{INFINITY, INFINITY}, {0, 0}};
// See "minimized". sg_keepApart holds the second bar on screen while the main one grows back under it.
static BOOL sg_minimized, sg_minimizedTarget, sg_keepApart, sg_transitioning;
static CGFloat sg_scrollSquish;

@interface SGRSystemTabBar : UITabBar <UITabBarDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *stockBar;
@property (nonatomic, copy) NSArray<UIView *> *sources;
@property (nonatomic, weak) UILongPressGestureRecognizer *hold;
@property (nonatomic) BOOL holding;
// The other bar, when the split tabs have one of their own: a tab picked on one bar clears the other's.
@property (nonatomic, weak) SGRSystemTabBar *partner;
// The item last shown selected, so a tap on it can be told from a tap that changes the tab.
@property (nonatomic, weak) UITabBarItem *shown;
@property (nonatomic) BOOL layingOut;
@end

static void syncBar(UIView *stockBar);

#pragma mark - reading Spotify's items

// The SPTEncoreIcon an icon view was built with. Encore keeps it in a Swift ivar with no getter.
static id encoreIconOf(UIView *view) {
    Ivar ivar = class_getInstanceVariable(view.class, "icon");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    return type && type[0] == '@' ? object_getIvar(view, ivar) : nil;
}

// An SPTEncoreIcon's name, which is what tells two icons apart: Spotify may hand a view a new instance of the
// same glyph. Nil for an icon that does not say.
static NSString *iconName(id icon) {
    id name = [icon respondsToSelector:@selector(name)] ? [icon name] : nil;
    return [name isKindOfClass:NSString.class] ? name : nil;
}

// The filled variant of a tab's SPTEncoreIcon (-active, which fillBar's log prints), when it has one. A filled
// icon has none: its -active is itself, or the same glyph again.
static id activeVariantOf(id icon) {
    SEL selector = NSSelectorFromString(@"active");
    if (!icon || ![icon respondsToSelector:selector]) return nil;
    id variant = ((id (*)(id, SEL))objc_msgSend)(icon, selector);
    if (variant == icon || ![variant isKindOfClass:[icon class]]) return nil;
    NSString *name = iconName(icon);
    return name && [name isEqualToString:iconName(variant)] ? nil : variant;
}

// A tab of the mod's own that wears an SF Symbol hands UIKit the symbol itself, with no size of its own, so the
// bar sizes it the way UIKit sizes every app's tab symbols, the Music app's included. One object per name, so
// setGlyphs sees the same image again and leaves the item alone.
static UIImage *symbolGlyph(NSString *name) {
    if (!name.length) return nil;
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    UIImage *image = [cache objectForKey:name];
    if (image) return image;
    image = [SGSymbolImageWithConfig(name, nil) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (image) [cache setObject:image forKey:name];
    return image;
}

// One glyph of a tab: `icon` drawn at the size of `live`, Spotify's icon view it came from. The caller picks the
// icon, outline or filled, so the cache key names the glyph actually drawn and an outline drawing can never be
// filed under a filled icon's name or the other way round. isActive only picks the view's colors, white either
// way. Drawn on an icon view of our own, off screen, so the images do not wait for Spotify's views to lay out
// and paint, and UITabBar swaps image and selectedImage itself.
// Every glyph image is the same outer size in both states, 24 pt as Spotify draws its icon views, so UIKit's
// measure of the bar (SGRTabBarGlassHeight) never changes with them: a 26.5 and 28 pt image changing as the bar
// minimized moved the room under Spotify's bar from inside -setContentOffset: and the page scrolled against it
// for good (the freeze of c52af73). The glyph grows inside its canvas instead, to the Music app's weight: 1.12
// on the full bar (Search 21.6 pt against the Music app's 21.7) and 1.22 in a minimized circle.
static const CGFloat kGlyphCanvas = 24, kGlyphScale = 1.12, kMinimizedGlyphScale = 1.22;

// The selected tab's glyph on a minimized circle, in the accent (UIKit shows no bubble there): one object per
// glyph and color, for the same reason.
static UIImage *tintedGlyph(UIImage *image, UIColor *color) {
    if (!image || !color) return image;
    static char kTintedKey;
    NSMutableDictionary<UIColor *, UIImage *> *tinted = objc_getAssociatedObject(image, &kTintedKey);
    if (!tinted) {
        tinted = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(image, &kTintedKey, tinted, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIImage *done = tinted[color];
    if (!done) {
        done = [image imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (done) tinted[color] = done;
    }
    return done;
}

static UIImage *renderScaledEncoreView(SPTEncoreIconView *view, CGSize size, CGFloat scale) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *drawn = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef cg = context.CGContext;
        CGContextTranslateCTM(cg, size.width / 2, size.height / 2);
        CGContextScaleCTM(cg, scale, scale);
        CGContextTranslateCTM(cg, -size.width / 2, -size.height / 2);
        [view.layer renderInContext:cg];
    }];
    return [drawn imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *drawGlyph(UIView *live, id icon, BOOL active, BOOL minimized) {
    if (!live) return nil;
    NSString *symbol = SGTabIconSymbolName(live);
    if (symbol.length) {
        NSString *activeSymbol = active && ![symbol hasSuffix:@".fill"] ? [symbol stringByAppendingString:@".fill"] : symbol;
        UIImage *glyph = symbolGlyph(activeSymbol) ?: symbolGlyph(symbol);
        if (glyph) return glyph;
    }
    CGSize size = live.bounds.size;
    if (size.width < 2 || size.height < 2) size = CGSizeMake(kGlyphCanvas, kGlyphCanvas);
    CGFloat scale = 1;
    if (SGRIsBarCompact() && size.width >= 20 && size.width <= 26) {
        size = CGSizeMake(kGlyphCanvas, kGlyphCanvas);
        scale = minimized ? kMinimizedGlyphScale : kGlyphScale;
    }
    Class viewClass = NSClassFromString(@"SPTEncoreIconView");
    if (icon && viewClass) {
        static NSCache<NSString *, UIImage *> *cache;
        if (!cache) cache = [NSCache new];
        id iconIdent = iconName(icon) ?: icon;
        NSString *sizeStr = NSStringFromCGSize(size);
        NSString *key = [NSString stringWithFormat:@"%@ %d %@ %.2f", iconIdent, active, sizeStr, scale];
        UIImage *cached = [cache objectForKey:key];
        if (cached) return cached;

        SPTEncoreIconView *view = [[viewClass alloc] initWithIcon:icon];
        view.frame = (CGRect){CGPointZero, size};
        [view setForegroundColor:UIColor.whiteColor];
        if ([view respondsToSelector:@selector(setActiveForegroundColor:)]) [view setActiveForegroundColor:UIColor.whiteColor];
        if ([view respondsToSelector:@selector(setIsActive:)]) [view setIsActive:active];
        [view layoutIfNeeded];

        UIImage *image = renderScaledEncoreView(view, size, scale);
        if (image && hasInk(image)) {
            [cache setObject:image forKey:key];
            // Pre-warm the companion compact scale at the same time so the first scroll minimize never misses cache.
            for (NSNumber *other in @[@(1.0), @(kGlyphScale), @(kMinimizedGlyphScale)]) {
                CGFloat s = other.doubleValue;
                if (fabs(s - scale) < 0.005) continue;
                NSString *otherKey = [NSString stringWithFormat:@"%@ %d %@ %.2f", iconIdent, active, sizeStr, s];
                if (![cache objectForKey:otherKey]) {
                    UIImage *otherImg = renderScaledEncoreView(view, size, s);
                    if (otherImg) [cache setObject:otherImg forKey:otherKey];
                }
            }
            return image;
        }
    }
    // Any other image view (an icon Encore would not draw off screen): its image as it is, one object per image.
    if ([live isKindOfClass:UIImageView.class] && ((UIImageView *)live).image) {
        UIImage *image = ((UIImageView *)live).image;
        return image.renderingMode == UIImageRenderingModeAlwaysTemplate ? image : [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return live.bounds.size.width >= 2 ? renderLayer(live.layer, live.bounds.size) : nil;
}

// A tab's glyph from what its view holds now, the filled variant for the selected state where the icon has one.
static UIImage *glyphOf(UIView *item, BOOL active) {
    UIView *live = iconIn(item);
    id icon = live ? encoreIconOf(live) : nil;
    if (active) icon = activeVariantOf(icon) ?: icon;
    return drawGlyph(live, icon, active, NO);
}

// For the Tab bar page's list and preview: a tab of Spotify's drawn from its item on the bar, hidden or not,
// found by the label its entry is named after; a tab of the mod's own drawn from its entry, as Navbar.x
// draws it on the bar. Nil while Spotify's item has not been built.
UIImage *SGRNavbarGlyph(NSDictionary *entry, BOOL active) {
    if (entry[SGRNavbarURI]) {
        UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
        UIView *icon = SGTabIconView(entry[SGRNavbarIcon], [entry[SGRNavbarIconSet] isEqual:SGTabIconSetSymbols], UIColor.whiteColor);
        icon.translatesAutoresizingMaskIntoConstraints = YES;
        icon.frame = holder.bounds;
        if ([icon isKindOfClass:UIImageView.class]) icon.contentMode = UIViewContentModeScaleAspectFit;
        [holder addSubview:icon];
        [holder layoutIfNeeded];
        return glyphOf(holder, active);
    }
    for (UIView *item in SGRowIn(sg_stockBar).arrangedSubviews) {
        if ([NSStringFromClass(item.class) isEqualToString:@"SGRTabItemView"]) continue;
        if ([labelIn(item).text isEqualToString:entry[SGRNavbarID]]) return glyphOf(item, active);
    }
    return nil;
}

#pragma mark - the system bar

// Split tabs stand on a glass bar of their own at the trailing end, the way the Music app sets Search
// apart. A standalone UITabBar has no way to set an item apart (iOS 27 SDK: only UITabBarController's
// UISearchTab does), so it is a second bar. UIKit draws each bar's platter 21 pt in from its sides
// (harness/tabbar, iPhone 17 Pro, iOS 27: a 72 pt bar got a 30 pt platter at x 21), so a split bar is
// a 62 pt platter, a circle as tall as the bar's, per tab plus those insets, and the main bar runs under
// its leading inset to leave 12 pt of glassless gap between the two platters.
static const CGFloat kPlatterInset = 21, kApartItemWidth = 62, kPlatterGap = 12, kCompactCircleSize = 48;

// A name too long for its tab (one of the user's own, a split tab's circle) shrinks a little before UIKit cuts
// it short, to 8 pt from 10.
void SGRShrinkTabTitles(UIView *bar) {
    SGForEachView(bar, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class] || ((UILabel *)v).adjustsFontSizeToFitWidth) return;
        ((UILabel *)v).adjustsFontSizeToFitWidth = YES;
        ((UILabel *)v).minimumScaleFactor = 0.8;
    });
}

static UIImageView *glyphView(UIView *button) {
    __block UIImageView *glyph = nil;
    SGForEachView(button, ^(UIView *v) {
        if (!glyph && [v isKindOfClass:UIImageView.class] && !v.hidden && ((UIImageView *)v).image) glyph = (UIImageView *)v;
    });
    return glyph;
}

static BOOL isTabButton(UIView *view) {
    return [view isKindOfClass:UIControl.class] && glyphView(view) != nil;
}

// UIKit draws every tab twice, the second time in the accent under the selection's bubble only.
static BOOL isLitCopy(UIView *view, UIView *host) {
    for (UIView *up = view.superview; up && up != host; up = up.superview) {
        if ([NSStringFromClass(up.class) containsString:@"SelectedContent"]) return YES;
    }
    return NO;
}

static UIView *platterIn(UIView *bar) {
    __block UIView *platter = nil;
    SGForEachView(bar, ^(UIView *v) {
        if (!platter && !v.hidden && v.alpha >= 0.01 && [NSStringFromClass(v.class) hasSuffix:@"PlatterView"]) platter = v;
    });
    return platter;
}

@implementation SGRSystemTabBar

// UIKit makes the labels as it lays the items out, so they are shrunk after each pass.
- (void)layoutSubviews {
    if (self.layingOut) {
        [super layoutSubviews];
        return;
    }
    self.layingOut = YES;
    [super layoutSubviews];
    SGRShrinkTabTitles(self);
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    NSMutableArray<UIView *> *litButtons = [NSMutableArray array];
    SGForEachView(self, ^(UIView *v) {
        if (!isTabButton(v)) return;
        if (isLitCopy(v, self)) [litButtons addObject:v];
        else [buttons addObject:v];
    });
    NSComparisonResult (^byX)(UIView *, UIView *) = ^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ax = [self convertPoint:a.bounds.origin fromView:a].x;
        CGFloat bx = [self convertPoint:b.bounds.origin fromView:b].x;
        return [@(ax) compare:@(bx)];
    };
    [buttons sortUsingComparator:byX];
    [litButtons sortUsingComparator:byX];
    for (NSUInteger i = 0; i < buttons.count && i < self.items.count; i++) {
        NSString *name = self.items[i].accessibilityLabel ?: self.items[i].title;
        if (name) objc_setAssociatedObject(buttons[i], &kTabNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    for (NSUInteger i = 0; i < litButtons.count && i < self.items.count; i++) {
        NSString *name = self.items[i].accessibilityLabel ?: self.items[i].title;
        if (name) objc_setAssociatedObject(litButtons[i], &kTabNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    UIView *platter = platterIn(self);
    if (platter) {
        if (sg_minimized) {
            // Both the leading and trailing minimized bars are `kApartItemWidth + 2 * kPlatterInset` (104 pt) wide,
            // and UIKit places the 62 pt platter in the top 62 pt above the bottom safe area (at x = 21, y = 0 in self).
            // In compact mode, centering the 48 pt circle inside that 62 x 62 platter slot places it at (28, 7, 48, 48)
            // in self; in non-compact mode, pinning the 62 pt circle at (21, 0, 62, 62) prevents UITabBarItemPositioningFill
            // from stretching a single-item platter wider than 62 pt into the mini player slot.
            BOOL compact = SGRIsBarCompact();
            CGFloat circleSize = compact ? kCompactCircleSize : kApartItemWidth;
            CGFloat top = round((kApartItemWidth - circleSize) / 2.0);
            CGFloat xInSelf = kPlatterInset + top;
            CGRect circleInSelf = CGRectMake(xInSelf, top, circleSize, circleSize);
            CGRect circleFrame = platter.superview ? [self convertRect:circleInSelf toView:platter.superview] : circleInSelf;
            if (!CGRectEqualToRect(platter.frame, circleFrame)) {
                platter.frame = circleFrame;
            }
            SGShapeGlass(platter, circleSize / 2.0, YES);
            [platter setNeedsLayout];
            [platter layoutIfNeeded];
            for (UIView *sub in platter.subviews) {
                if ((sub.bounds.size.width >= circleSize && fabs(sub.bounds.size.width - sub.bounds.size.height) < 2.0)
                    || objc_getAssociatedObject(sub, &kPlatterSubKey)) {
                    sub.frame = platter.bounds;
                    SGShapeGlass(sub, circleSize / 2.0, YES);
                    objc_setAssociatedObject(sub, &kPlatterSubKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
            CGPoint centerInSelf = CGPointMake(CGRectGetMidX(circleInSelf), CGRectGetMidY(circleInSelf));
            for (UIView *b in buttons) {
                b.center = b.superview ? [self convertPoint:centerInSelf toView:b.superview] : centerInSelf;
            }
            for (UIView *b in litButtons) {
                b.center = b.superview ? [self convertPoint:centerInSelf toView:b.superview] : centerInSelf;
            }
        } else {
            CGFloat r = platter.bounds.size.height / 2.0;
            SGShapeGlass(platter, r, YES);
            [platter setNeedsLayout];
            [platter layoutIfNeeded];
            for (UIView *sub in platter.subviews) {
                if (objc_getAssociatedObject(sub, &kPlatterSubKey)) {
                    sub.frame = platter.bounds;
                    SGShapeGlass(sub, r, YES);
                }
            }
        }
    }
    self.layingOut = NO;
}

- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    NSUInteger index = [self.items indexOfObject:item];
    if (index == NSNotFound || index >= self.sources.count) return;
    BOOL again = item == self.shown;
    self.shown = item;
    // On the minimized bar the leading circle brings the whole bar back, as the Music app's does; passed on,
    // the tap would take Spotify's stack back to its root. Minimizing builds the circle's item anew, so it
    // is told by the bar it is on, not by being the item shown before.
    BOOL leading = self.stockBar && objc_getAssociatedObject(self.stockBar, &kBarKey) == self;
    if (sg_minimized && (again || leading)) {
        SGRSetTabBarMinimized(NO, YES);
        return;
    }
    // One of Spotify's own takes the light back from a tab of the mod's own.
    UIView *source = self.sources[index];
    if (![NSStringFromClass(source.class) isEqualToString:@"SGRTabItemView"]) SGRNavbarForgetTab();
    // Home tapped while on Home pops Spotify's stack, which would take Mod Settings straight off it.
    if (!self.holding) forwardTap(source);
    self.partner.selectedItem = nil;
    self.partner.shown = nil;
    // Spotify repaints its labels a moment later; a tap it did not take snaps the selection back.
    UIView *stockBar = self.stockBar;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (stockBar) syncBar(stockBar);
    });
}

// UIKit's item views are private, so the item under a touch is the one whose title label or glyph is
// nearest. With the labels hidden only the glyph is left; UIKit shows the item's own image instance.
- (UITabBarItem *)itemAt:(CGPoint)point {
    __block UITabBarItem *nearest = nil;
    __block CGFloat best = CGFLOAT_MAX;
    SGForEachView(self, ^(UIView *v) {
        BOOL label = [v isKindOfClass:UILabel.class], glyph = [v isKindOfClass:UIImageView.class];
        if ((!label && !glyph) || v.bounds.size.width < 1) return;
        CGFloat distance = fabs([v convertPoint:CGPointMake(CGRectGetMidX(v.bounds), 0) toView:self].x - point.x);
        if (distance >= best) return;
        for (UITabBarItem *item in self.items) {
            UIImage *image = glyph ? ((UIImageView *)v).image : nil;
            if (label ? ![((UILabel *)v).text isEqualToString:item.title] : !image || (image != item.image && image != item.selectedImage)) continue;
            best = distance;
            nearest = item;
            break;
        }
    });
    return nearest;
}

// UIView asks itself this for its own recognizers too, so only the hold is answered here.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer != self.hold) return [super gestureRecognizerShouldBegin:recognizer];
    NSUInteger index = [self.items indexOfObject:[self itemAt:[recognizer locationInView:self]]];
    return index < self.sources.count && isHome(self.sources[index], self.stockBar);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)held:(UILongPressGestureRecognizer *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) {
        self.holding = YES;
        SGOpenModSettings(self);
    } else if (hold.state != UIGestureRecognizerStateChanged) {
        // The bar may still pick Home as the finger lifts, after this.
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            weakSelf.holding = NO;
        });
    }
}

@end

// The system bar's own view in Spotify's bar. UIKit measures the system bar and lays it out by the safe
// area of the view it stands in, and the room made under Spotify's bar is not the phone's: on a phone
// with a home button it went under the platter as well, squeezing it to 49 pt. So this view hands the
// bar the safe area without the room.
@interface SGRTabBarHost : UIView
@end

@implementation SGRTabBarHost
- (UIEdgeInsets)safeAreaInsets {
    UIEdgeInsets insets = [super safeAreaInsets];
    insets.bottom = MAX(0, insets.bottom - SGRTabBarRoom());
    return insets;
}
@end

static void logBarOnce(UITabBar *bar) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGLogLong(@"navbar", [NSString stringWithFormat:@"system tab bar %@\n%@", NSStringFromCGRect(bar.superview.frame), [bar recursiveDescription]]);
        });
    });
}

#pragma mark - the fade under the bars

// The pages darken toward the bottom of the screen under the glass bar and the now playing bar, from clear
// a little above the now playing card to half black at the screen's foot, so a row going under the glass
// reads as passing behind it. Never darker than half: the glass still has the page to lens. The fade is the
// stock bar's own subview, behind the glass, so it slides away with the bar when a page hides it; Spotify's
// bar does not clip, or the glass bar would not have stood over the now playing bar before the room was made.
@interface SGRBarFade : UIView
@end

@implementation SGRBarFade
+ (Class)layerClass {
    return CAGradientLayer.class;
}
@end

// The now playing card (56), its gap over the bar (8) and 24 more, whether a song is playing or not; in a
// Jam the strip's height on top while the card is above the bar. In the minimized row the strip rides just
// above the card, which these 88 already reach.
static const CGFloat kFadeAbove = 88;

static void placeFade(UIView *stockBar, CGRect glass, BOOL minimized) {
    SGRBarFade *fade = objc_getAssociatedObject(stockBar, &kFadeKey);
    if (!fade) {
        fade = [SGRBarFade new];
        fade.userInteractionEnabled = NO;
        CAGradientLayer *layer = (CAGradientLayer *)fade.layer;
        // Eased rather than straight, so the fade has no edge where it starts.
        layer.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.3].CGColor,
                         (id)[UIColor colorWithWhite:0 alpha:0.5].CGColor];
        layer.locations = @[@0, @0.5, @1];
        objc_setAssociatedObject(stockBar, &kFadeKey, fade, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat top = CGRectGetMinY(glass) - kFadeAbove - (minimized ? 0 : SGRNowPlayingStripHeight());
    CGRect frame = CGRectMake(0, top, stockBar.bounds.size.width, CGRectGetMaxY(glass) - top);
    if (!CGRectEqualToRect(fade.frame, frame)) fade.frame = frame;
    if (fade.superview != stockBar || stockBar.subviews.firstObject != fade) [stockBar insertSubview:fade atIndex:0];
}

#pragma mark - room for the glass bar

// The room itself is TabBarRoom.m's, shared with the capsule bar below iOS 26.
static void makeRoom(UIViewController *container) {
    UIView *stockBar = sg_stockBar;
    SGRMakeTabBarRoom(container, stockBar, stockBar ? objc_getAssociatedObject(stockBar, &kBarKey) : nil);
}

static SGRSystemTabBar *makeBar(UIView *stockBar) {
    SGRSystemTabBar *bar = [[SGRSystemTabBar alloc] initWithFrame:stockBar.bounds];
    // UIKit draws the glass in the appearance the bar inherits, and the bar is outside the navigation
    // stacks Spotify makes dark itself (-[SPNavigationController viewDidLoad] while +[SPTLiquidGlass
    // isEnabled]), so a phone in light mode had it light over Spotify's black. Spotify is dark whatever
    // the system is, and so is the bar.
    bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    bar.delegate = bar;
    bar.stockBar = stockBar;
    bar.itemPositioning = UITabBarItemPositioningFill;
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:bar action:@selector(held:)];
    hold.delegate = bar;
    [bar addGestureRecognizer:hold];
    bar.hold = hold;
    return bar;
}

// Setting a tab's image lays its bar's items out again, so an image is set only when it is another one: the glyph
// cache hands back the same object for the same glyph.
static void setGlyphs(UITabBarItem *item, UIImage *image, UIImage *selectedImage) {
    if (image && item.image != image) item.image = image;
    if (selectedImage && item.selectedImage != selectedImage) item.selectedImage = selectedImage;
}

// One bar's share of the tabs: its items, their glyphs and titles. YES while a glyph is still missing.
static BOOL fillBar(SGRSystemTabBar *bar, NSArray<UIView *> *sources, BOOL hideLabels, UIView *active, BOOL minimized) {
    bar.tintColor = SGRAccent();
    if (![sources isEqualToArray:bar.sources]) {
        NSMutableArray<UITabBarItem *> *items = [NSMutableArray array];
        for (UIView *source in sources) {
            NSString *label = labelIn(source).text;
            UITabBarItem *item = [[UITabBarItem alloc] initWithTitle:hideLabels ? nil : label image:nil tag:items.count];
            item.accessibilityLabel = label;
            [items addObject:item];
        }
        bar.sources = sources;
        [bar setItems:items animated:NO];
        static dispatch_once_t logIconsOnce;
        dispatch_once(&logIconsOnce, ^{
            NSMutableString *out = [NSMutableString stringWithString:@"tab bar icons"];
            for (UIView *source in sources) {
                UIView *live = iconIn(source);
                id icon = live ? encoreIconOf(live) : nil;
                id variant = activeVariantOf(icon);
                [out appendFormat:@"\n  %@: %@ icon %@ active-variant %@ live-isActive %d label-white %d", labelIn(source).text, NSStringFromClass(live.class),
                     iconName(icon) ?: icon, iconName(variant) ?: variant,
                     [live respondsToSelector:@selector(isActive)] ? [(SPTEncoreIconView *)live isActive] : -1, isActive(source)];
            }
            SGLogLong(@"navbar", out);
        });
    }

    BOOL missing = NO;
    for (NSUInteger i = 0; i < sources.count; i++) {
        UITabBarItem *item = bar.items[i];
        // A tab's filled glyph is not an isActive state of its icon view: Spotify gives the selected tab's view the
        // filled SPTEncoreIcon in place of the outline one (#151: the glass bar's selected tab stayed outlined, and
        // showed filled only once minimizing made its item anew). So both images come from the icon the view holds,
        // known by the icon itself and never by the label's color, which Spotify repaints apart from the icon: an
        // outline icon gives image and its -active variant selectedImage, and a filled one, or one with no variant,
        // gives both, which is right for the state it is shown in. The item keeps the names it was drawn from, so it
        // is drawn again only when the view holds an icon outside them: a filled icon whose outline drew the item
        // changes nothing. Tabs of the mod's own have no Encore icon and are drawn once.
        UIView *live = iconIn(sources[i]);
        id icon = live ? encoreIconOf(live) : nil;
        NSString *name = iconName(icon);
        NSString *modeTag = [NSString stringWithFormat:@"%d-%d", SGRIsBarCompact(), minimized];
        NSArray *drawnTags = objc_getAssociatedObject(item, &kGlyphNamesKey);
        BOOL activeMinimized = minimized && sources[i] == active;
        if (activeMinimized) {
            id lit = activeVariantOf(icon);
            UIImage *image = drawGlyph(live, lit ?: icon, YES, YES);
            if (image) {
                UIImage *tinted = tintedGlyph(image, SGRAccent());
                setGlyphs(item, tinted, tinted);
                objc_setAssociatedObject(item, &kGlyphNamesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } else if (!item.image || !item.selectedImage || ![drawnTags containsObject:modeTag] || (name && ![drawnTags containsObject:name])) {
            id lit = activeVariantOf(icon);
            setGlyphs(item, drawGlyph(live, icon, NO, minimized), drawGlyph(live, lit ?: icon, YES, minimized));
            NSString *litName = iconName(lit);
            if (item.image && item.selectedImage) {
                NSArray *tags = name ? (litName ? @[modeTag, name, litName] : @[modeTag, name]) : @[modeTag];
                objc_setAssociatedObject(item, &kGlyphNamesKey, tags, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        missing |= !item.image || !item.selectedImage;
        item.accessibilityLabel = labelIn(sources[i]).text;
        item.largeContentSizeImage = item.image;
        item.accessibilityHint = sg_minimized && bar == objc_getAssociatedObject(bar.stockBar, &kBarKey) ? @"Shows all tabs" : nil;
        NSString *title = hideLabels ? nil : labelIn(sources[i]).text;
        if (hideLabels ? item.title != nil : title.length && ![title isEqualToString:item.title]) item.title = title;
    }
    return missing;
}

// The bar holding the tab Spotify paints as selected selects it, and the other one lets go. With no tab
// painted (a tab of the mod's own, a repaint still to come) both keep what they have. When minimized,
// selectedItem is nil so UIKit omits the dark inner selection bubble while shown remembers the active tab.
static void selectActive(SGRSystemTabBar *bar, UIView *active, BOOL minimized) {
    NSUInteger index = active ? [bar.sources indexOfObject:active] : NSNotFound;
    UITabBarItem *item = index == NSNotFound ? nil : bar.items[index];
    UITabBarItem *selected = minimized ? nil : item;
    if (active && bar.selectedItem != selected) bar.selectedItem = selected;
    if (active && item) bar.shown = item;
}

// The tab a bar shows selected, when Spotify paints none: a tab of the mod's own.
static UIView *selectedSource(SGRSystemTabBar *bar) {
    UITabBarItem *item = bar.selectedItem ?: bar.shown;
    NSUInteger index = item ? [bar.items indexOfObject:item] : NSNotFound;
    return index < bar.sources.count ? bar.sources[index] : nil;
}

static UIView *autoSplitTrailingSource(NSArray<UIView *> *sources) {
    if (sources.count < 2) return nil;
    for (UIView *source in [sources reverseObjectEnumerator]) {
        NSString *title = labelIn(source).text.lowercaseString;
        NSString *icon = iconName(encoreIconOf(iconIn(source))).lowercaseString;
        if ([title isEqualToString:@"search"] || [icon hasPrefix:@"search"]) {
            return source;
        }
    }
    return sources.lastObject;
}

static void syncBar(UIView *stockBar) {
    if (!stockBar) return;
    sg_stockBar = stockBar;

    SGRSystemTabBar *bar = objc_getAssociatedObject(stockBar, &kBarKey);
    if (!bar) {
        bar = makeBar(stockBar);
        objc_setAssociatedObject(stockBar, &kBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRTabBarHost *host = [SGRTabBarHost new];
        [host addSubview:bar];
        objc_setAssociatedObject(stockBar, &kHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *host = objc_getAssociatedObject(stockBar, &kHostKey);
    SGRSystemTabBar *apartBar = objc_getAssociatedObject(stockBar, &kApartBarKey);
    if (!apartBar) {
        apartBar = makeBar(stockBar);
        objc_setAssociatedObject(stockBar, &kApartBarKey, apartBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        apartBar.partner = bar;
        bar.partner = apartBar;
        apartBar.hidden = YES;
        [host addSubview:apartBar];
    }

    // Attach host up front so bar.window is valid when SGRTabBarGlassHeight and makeRoom run on cold launch.
    if (host.superview != stockBar) [stockBar addSubview:host];
    else if (stockBar.subviews.lastObject != host) [stockBar bringSubviewToFront:host];

    for (UIView *sub in stockBar.subviews) {
        if (sub == host || [sub isKindOfClass:SGRBarFade.class]) continue;
        sub.alpha = 0;
        sub.hidden = YES;
        sub.userInteractionEnabled = NO;
    }
    stockBar.superview.layer.backgroundColor = NULL;

    NSArray<UIView *> *sources = tabItems(stockBar);
    if (!sources.count) return;
    // An item with no title is drawn by UIKit as its glyph alone, centered, on a bar of the same height.
    BOOL hideLabels = SGHidden(SGRKeyNavbarHideLabels);
    UIView *active = SGRNavbarLitTab();
    if (![sources containsObject:active]) active = nil;
    for (UIView *source in sources) if (!active && isActive(source)) active = source;
    active = active ?: selectedSource(bar) ?: selectedSource(apartBar);

    NSMutableArray<UIView *> *main = [NSMutableArray array], *apart = [NSMutableArray array];
    for (UIView *source in sources) [(SGRTabIsApart(source) ? apart : main) addObject:source];
    if (!main.count) {
        main = [sources mutableCopy];
        [apart removeAllObjects];
    }
    // Minimized, the bar keeps the tab it is on, glyph only, on a circle at the leading end, and the last
    // split tab on one at the trailing end (falling back to Search when Split Search when minimized is on),
    // the way the Music app sandwiches the card. Without split tabs the expanded bar stays whole.
    BOOL minimized = sg_minimized && sources.count >= 2;
    if (minimized) {
        BOOL autoSplit = SGRIsBarAutoSplit();
        UIView *autoTrailing = (!apart.count && autoSplit) ? autoSplitTrailingSource(sources) : nil;
        UIView *last = apart.lastObject ?: autoTrailing;
        UIView *lead = (active && active != last) ? active : nil;
        if (!lead) {
            for (UIView *source in main) {
                if (source != last) {
                    lead = source;
                    break;
                }
            }
        }
        main = lead ? [NSMutableArray arrayWithObject:lead] : [NSMutableArray arrayWithObject:main.firstObject];
        apart = last ? [NSMutableArray arrayWithObject:last] : [NSMutableArray array];
        hideLabels = YES;
    }
    apartBar.hidden = !apart.count && !sg_keepApart;
    if (apartBar.hidden) {
        apartBar.sources = nil;
    } else {
        apartBar.alpha = 1;
    }

    CGRect bounds = stockBar.bounds;
    CGFloat width = bounds.size.width;
    CGFloat height = MAX(bounds.size.height, SGRTabBarGlassHeight(bar, stockBar));
    CGRect frame = CGRectMake(0, CGRectGetMaxY(bounds) - height, width, height);
    if (!CGRectEqualToRect(host.frame, frame)) host.frame = frame;
    placeFade(stockBar, frame, minimized);
    CGRect mainFrame = host.bounds, apartFrame = CGRectZero;
    CGFloat side = kApartItemWidth + 2 * kPlatterInset;
    if (minimized) {
        mainFrame.size.width = side;
        apartFrame = CGRectMake(width - side, 0, side, height);
    } else if (apart.count) {
        CGFloat apartWidth = MIN(width / 2, apart.count * kApartItemWidth + 2 * kPlatterInset);
        CGRectDivide(host.bounds, &apartFrame, &mainFrame, apartWidth, CGRectMaxXEdge);
        mainFrame.size.width += 2 * kPlatterInset - kPlatterGap;
    } else {
        apartFrame = CGRectMake(width - side, 0, side, height);
    }
    if (!CGRectEqualToRect(bar.frame, mainFrame)) bar.frame = mainFrame;
    if (apartBar && !CGRectEqualToRect(apartBar.frame, apartFrame)) apartBar.frame = apartFrame;

    // The items go in once the bars are laid out at their frames. UIKit sizes an item's title by the platter it
    // is made in and never again when the bar grows, so items made while a bar was still a circle kept "…" for
    // their names at full width (harness/tabbar, `names`).
    BOOL wasTransitioning = sg_transitioning;
    sg_transitioning = YES;
    [host layoutIfNeeded];
    BOOL missing = fillBar(bar, main, hideLabels, active, minimized);
    if (apart.count) missing |= fillBar(apartBar, apart, hideLabels, active, minimized);
    selectActive(bar, active, minimized);
    if (apart.count) selectActive(apartBar, active, minimized);
    [bar setNeedsLayout];
    [bar layoutIfNeeded];
    if (apartBar && !apartBar.hidden) {
        [apartBar setNeedsLayout];
        [apartBar layoutIfNeeded];
    }
    sg_transitioning = wasTransitioning;

    // An icon view Spotify has not built yet at cold launch is looked for again shortly, never during a minimize pass.
    static NSUInteger retries;
    static BOOL retryPending;
    if (missing && !minimized && !sg_transitioning && !retryPending && retries < 12) {
        retries++;
        retryPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            retryPending = NO;
            if (!sg_minimized && !sg_transitioning && sg_stockBar) syncBar(sg_stockBar);
        });
    }
    // The now playing card takes its edges from the glass row (SGRTabBarGlassRow) or the minimized slot (SGRTabBarInlineSlot);
    // it is told, after this pass, when the row or slot comes, goes or its sides move.
    CGRect row = SGRTabBarGlassRow(bar.window);
    CGRect slot = minimized ? SGRTabBarInlineSlot(bar.window, 48.0) : CGRectNull;
    BOOL rowMoved = CGRectIsNull(row) != CGRectIsNull(sg_glassRow)
        || (!CGRectIsNull(row) && (fabs(CGRectGetMinX(row) - CGRectGetMinX(sg_glassRow)) >= 0.5
                                   || fabs(CGRectGetMaxX(row) - CGRectGetMaxX(sg_glassRow)) >= 0.5));
    BOOL slotMoved = CGRectIsNull(slot) != CGRectIsNull(sg_inlineSlot)
        || (!CGRectIsNull(slot) && (fabs(CGRectGetMinX(slot) - CGRectGetMinX(sg_inlineSlot)) >= 0.5
                                    || fabs(CGRectGetMaxX(slot) - CGRectGetMaxX(sg_inlineSlot)) >= 0.5));
    if (rowMoved || slotMoved) {
        sg_glassRow = row;
        sg_inlineSlot = slot;
        if (!sg_transitioning) {
            dispatch_async(dispatch_get_main_queue(), ^{ SGRNowPlayingBarFollowTabBar(); });
        }
    }
    logBarOnce(bar);
    makeRoom(containerOf(stockBar));
}

#pragma mark - minimized

// A page scrolled down minimizes the bar (TabBarMinimize.x), the way the Music app's does. Spotify's tab bar
// container is a UIViewController of its own, not a UITabBarController (the binary's ObjC metadata), so
// UIKit's tabBarMinimizeBehavior and bottomAccessory have nothing to act on. The minimized bar is built
// from the two bars this file already has: the main bar narrowed to one circle at the leading end, the
// second bar to one at the trailing end, and the now playing card between them (NowPlayingBar.x). The
// bars get their new items and are laid out where they are going at once; then every view of theirs goes back
// to where it was and moves on one spring with the card (see "one move"); nothing fades a bar's glass.
BOOL SGRTabBarMinimized(void) {
    if (SGRLegacyTabBarOn()) return SGRLegacyTabBarMinimized();
    return sg_minimized;
}

BOOL SGRTabBarMinimizedTarget(void) {
    return sg_minimizedTarget;
}

BOOL SGRTabBarIsTransitioning(void) {
    return sg_transitioning;
}

static void setMinimized(BOOL minimized, BOOL animated);
static void applyScrollSquish(UIView *host, CGFloat progress);

// The scroll asks from inside -[UIScrollView setContentOffset:], which Spotify can call inside an animation of
// its own: a block, whose length the spring then took, or a property animator held part way, which kept the bar's
// and the card's moves at its fraction for good, the circle stopped half way along the row and the card half way
// down to it (harness/tabbar, `nested`). So an animated change asked for inside an animation is made on the main
// queue's next turn, outside it, and only if nothing was asked for since; one asked for outside any is made at
// once. A change with no animation stays at once too: the player's transition takes its pictures of the bars
// right after asking. The same for the capsule bar below iOS 26 (TabBarLegacy.x), which makes the change itself.
static NSUInteger sg_request;

static void applyMinimized(BOOL minimized, BOOL animated) {
    if (SGRLegacyTabBarOn()) SGRLegacyApplyTabBarMinimized(minimized, animated);
    else setMinimized(minimized, animated);
}

void SGRSetTabBarMinimized(BOOL minimized, BOOL animated) {
    NSUInteger request = ++sg_request;
    sg_minimizedTarget = minimized;
    if (!animated) {
        sg_scrollSquish = 0;
        [UIView performWithoutAnimation:^{ applyMinimized(minimized, NO); }];
        return;
    }
    if (UIView.areAnimationsEnabled && UIView.inheritedAnimationDuration <= 0) {
        applyMinimized(minimized, YES);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (request == sg_request) applyMinimized(minimized, YES);
    });
}

// Interactive pre-minimize scroll compression with physical rubber-band resistance: gently dragging down
// before crossing the minimize threshold proportionally compresses both the mini player card and the tab bar.
static const CGFloat kScrollSquishScale = 0.036;
static const CGFloat kScrollSquishDrop = 2.5;

static CGFloat rubberBandSquish(CGFloat progress) {
    if (progress <= 0) return 0;
    return progress / (1.0 + 0.45 * progress);
}

static void applyScrollSquish(UIView *host, CGFloat progress) {
    CGFloat r = (!sg_minimized && progress > 0) ? rubberBandSquish(progress) : 0;
    CGFloat scale = 1.0 - kScrollSquishScale * r;
    CGFloat dy = kScrollSquishDrop * r;
    CGAffineTransform transform = r > 0.0005
        ? CGAffineTransformConcat(CGAffineTransformMakeScale(scale, scale), CGAffineTransformMakeTranslation(0, dy))
        : CGAffineTransformIdentity;
    if (host && !CGAffineTransformEqualToTransform(host.transform, transform)) {
        host.transform = transform;
    }
}

void SGRSetTabBarScrollSquish(CGFloat progress, BOOL animated) {
    if (SGRLegacyTabBarOn()) return;
    progress = MIN(1.0, MAX(0.0, progress));
    if (sg_minimized) progress = 0;
    if (fabs(progress - sg_scrollSquish) < 0.001 && !animated) return;
    sg_scrollSquish = progress;
    UIView *stockBar = sg_stockBar;
    UIView *host = stockBar ? objc_getAssociatedObject(stockBar, &kHostKey) : nil;
    void (^apply)(void) = ^{
        applyScrollSquish(host, progress);
        SGRNowPlayingBarSetScrollSquish(progress);
    };
    if (animated && host.window) {
        SGRAnimate(SGRMotionBar, apply, nil);
    } else {
        [UIView performWithoutAnimation:apply];
    }
}

#pragma mark - one move

// The bars, the circles and the card move as one: on one spring (SGRMotionBar), from what is on screen. UIKit
// lays a bar's items out by its width, so a bar laid out where it was with its new items put them where they
// never were: minimizing, the circle's tab stood in the middle of the old full bar and slid to the leading end
// from there (harness/tabbar, `motion`: 124 pt in one frame). So each bar is laid out where it is going, and
// every view of the bars that was already there goes back to its frame from before, under its animations still
// running, and moves to its new one in the spring. UIView's animations add up, so a change that turns one back
// carries on from where the screen is, at the speed it had. UIKit takes the animations off its platters when it
// lays new items out, though, and a platter turned back half way then started from the old move's end, 62 pt from
// where it was shown (`motion`, four quick turns); one whose move was taken off starts from what was shown. The
// selected tab's new button starts with its glyph where the old one's was; the other new buttons fade in, and the
// buttons that went fade out from where they were.
typedef struct {
    NSMapTable<UIView *, NSArray<NSValue *> *> *frames; // every view of the host: its frame, the frame shown, moving
    NSMutableDictionary<NSString *, NSValue *> *glyphs; // the selected tab's glyph center in the host (buttonKey)
    NSMapTable<UIView *, UIView *> *buttons;            // each tab button, a picture of it
    NSMapTable<UIView *, UIView *> *labels;             // each tab button's title label, a picture of it
} SGRBarState;

static BOOL isMoving(UIView *view) {
    for (NSString *key in view.layer.animationKeys) if ([key hasPrefix:@"position"] || [key hasPrefix:@"bounds"]) return YES;
    return NO;
}

static BOOL isVisibleInHost(UIView *view, UIView *host) {
    if (!view.window) return NO;
    for (UIView *v = view; v && v != host; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    return YES;
}

static NSString *tabButtonName(UIView *button) {
    NSString *name = objc_getAssociatedObject(button, &kTabNameKey);
    if (name.length) return name;
    if (button.accessibilityLabel.length) return button.accessibilityLabel;
    for (UIView *sub in button.subviews) {
        if ([sub isKindOfClass:UILabel.class] && ((UILabel *)sub).text.length) return ((UILabel *)sub).text;
    }
    return nil;
}

// Which old button a new one takes over from. Both the selected tab (Home) and split tabs (Search)
// carry over continuously between expanded and minimized states, gliding smoothly rather than popping.
static NSString *buttonKey(UIView *button, UIView *host) {
    if (!isTabButton(button)) return nil;
    NSString *name = tabButtonName(button);
    if (!name.length) {
        if (!((UIControl *)button).selected) return nil;
        name = @"selected";
    }
    return name;
}

static CGRect shownIn(UIView *view, UIView *host) {
    CALayer *layer = view.layer.presentationLayer ?: view.layer, *top = host.layer.presentationLayer ?: host.layer;
    return [layer convertRect:layer.bounds toLayer:top];
}

// A picture of a tab's title, in the host. Built from the label rather than snapshotted: a snapshot of a view inside
// UIKit's glass platter comes back blank (a _UIReplicantView drawing nothing), and the tabs leaving a minimizing
// bar went in one frame instead of fading.
static UILabel *labelPicture(UILabel *label, UIView *host) {
    UILabel *copy = [[UILabel alloc] initWithFrame:shownIn(label, host)];
    copy.userInteractionEnabled = NO;
    copy.text = label.text;
    copy.font = label.font;
    copy.textColor = label.textColor;
    copy.textAlignment = label.textAlignment;
    copy.adjustsFontSizeToFitWidth = label.adjustsFontSizeToFitWidth;
    copy.minimumScaleFactor = label.minimumScaleFactor;
    copy.lineBreakMode = label.lineBreakMode;
    copy.alpha = label.alpha;
    copy.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    return copy;
}

// A picture of a tab button, in the host: its glyph and its title, drawn again the way UIKit shows them.
static UIView *buttonPicture(UIView *button, UIView *host) {
    CGRect shown = shownIn(button, host);
    UIView *picture = [[UIView alloc] initWithFrame:shown];
    picture.userInteractionEnabled = NO;
    picture.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIImageView *glyph = glyphView(button);
    if (glyph.image) {
        UIImageView *copy = [[UIImageView alloc] initWithImage:glyph.image];
        copy.tintColor = glyph.tintColor;
        copy.contentMode = glyph.contentMode;
        copy.preferredSymbolConfiguration = glyph.preferredSymbolConfiguration;
        CGRect inHost = shownIn(glyph, host);
        copy.frame = CGRectOffset(inHost, -shown.origin.x, -shown.origin.y);
        [picture addSubview:copy];
    }
    for (UIView *sub in button.subviews) {
        if (![sub isKindOfClass:UILabel.class] || sub.hidden || sub.alpha <= 0.01) continue;
        UILabel *copy = labelPicture((UILabel *)sub, host);
        copy.frame = CGRectOffset(copy.frame, -shown.origin.x, -shown.origin.y);
        [picture addSubview:copy];
        break;
    }
    return picture;
}

static SGRBarState barState(UIView *host) {
    SGRBarState state = {
        [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory],
        [NSMutableDictionary dictionary],
        [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory],
        [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory],
    };
    SGForEachView(host, ^(UIView *v) {
        if (!isVisibleInHost(v, host)) return;
        for (UIView *u = v; u && u != host; u = u.superview) {
            if (isTabButton(u) && !isVisibleInHost(u, host)) return;
        }
        CALayer *shownLayer = v.layer.presentationLayer;
        [state.frames setObject:@[[NSValue valueWithCGRect:v.frame], [NSValue valueWithCGRect:shownLayer ? shownLayer.frame : v.frame], @(isMoving(v))] forKey:v];
        if (v == host || !isTabButton(v)) return;
        CGRect glyph = shownIn(glyphView(v), host);
        NSString *key = buttonKey(v, host);
        if (key) state.glyphs[key] = [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(glyph), CGRectGetMidY(glyph))];
        // The lit copy is left out, or its picture would show the tab lit outside the bubble.
        if (isLitCopy(v, host)) return;
        [state.buttons setObject:buttonPicture(v, host) forKey:v];
        for (UIView *sub in v.subviews) {
            if ([sub isKindOfClass:UILabel.class] && !sub.hidden && sub.alpha > 0.01) {
                [state.labels setObject:labelPicture((UILabel *)sub, host) forKey:v];
                break;
            }
        }
    });
    return state;
}

// Moves the host's views from `before` to where they are now, with `along` (the card) in the same spring.
static void moveFrom(UIView *host, SGRBarState before, UIView *bar, NSString *apartName, BOOL splitTransition, void (^along)(void), void (^completion)(BOOL)) {
    NSMutableArray<UIView *> *moved = [NSMutableArray array], *faded = [NSMutableArray array];
    NSMutableArray<NSValue *> *starts = [NSMutableArray array], *targets = [NSMutableArray array];
    NSMutableSet<NSString *> *taken = [NSMutableSet set];
    SGForEachView(host, ^(UIView *v) {
        if (v == host || [v isKindOfClass:UITabBar.class] || !isVisibleInHost(v, host)) return;
        for (UIView *u = v; u && u != host; u = u.superview) {
            if (isTabButton(u) && u.hidden) return;
        }
        NSArray<NSValue *> *old = [before.frames objectForKey:v];
        if (old) {
            BOOL wasMoving = [(NSNumber *)old[2] boolValue];
            CGRect start = wasMoving ? old[1].CGRectValue : old[0].CGRectValue;
            // Minimizing into a split, the main platter starts short of the trailing circle's place so the two never
            // overlap. Only the views inside the bar start short: the bar's own bounds at a width UIKit never laid it
            // out at would send it through a layout pass of its own mid-move.
            if (sg_minimized && splitTransition && !wasMoving && v != bar && [v isDescendantOfView:bar] && !isTabButton(v) && start.size.width > host.bounds.size.width - 80.0) {
                start.size.width -= (kApartItemWidth + kPlatterGap);
            }
            if (!wasMoving && CGRectEqualToRect(start, v.frame)) return;
            [moved addObject:v];
            [starts addObject:[NSValue valueWithCGRect:start]];
            [targets addObject:[NSValue valueWithCGRect:v.frame]];
            return;
        }
        // A view made for the new items, whose superview was there before. The selected tab's button starts where
        // the old one's glyph was, another fades in where it is going; the rest (the selection's bubble) are there
        // at once, or the selected tab's glyph, drawn under the bubble, went with it.
        BOOL superKnown = [before.frames objectForKey:v.superview] != nil;
        NSString *key = buttonKey(v, host);
        NSValue *was = key ? before.glyphs[key] : nil;
        if (was) {
            [moved addObject:v];
            [starts addObject:was];   // a center in the host, placed once the views above it are back
            [targets addObject:[NSValue valueWithCGRect:v.frame]];
            [taken addObject:key];
            if (!sg_minimized && !(splitTransition && apartName && [key isEqualToString:apartName])) {
                SGForEachView(v, ^(UIView *sub) {
                    if ([sub isKindOfClass:UILabel.class] && !sub.hidden && sub.alpha > 0.01) [faded addObject:sub];
                });
            }
            return;
        }
        if (!superKnown || [v isKindOfClass:UITabBar.class]) return;
        if (isTabButton(v) && v.alpha > 0.01) {
            if (!sg_minimized && splitTransition && apartName && [key isEqualToString:apartName]) return;
            [faded addObject:v];
        }
    });
    NSMutableArray<UIView *> *gone = [NSMutableArray array];
    for (UIView *button in before.buttons) {
        NSString *key = buttonKey(button, host);
        BOOL replaced = key && [taken containsObject:key];
        if (!replaced && (!button.window || button.hidden || button.alpha < 0.01)) {
            [gone addObject:[before.buttons objectForKey:button]];
        } else if (replaced && sg_minimized) {
            UIView *labelPic = [before.labels objectForKey:button];
            if (labelPic) [gone addObject:labelPic];
        }
    }

    [UIView performWithoutAnimation:^{
        // Top down, so a button's center is placed in its platter where the platter starts.
        for (NSUInteger i = 0; i < moved.count; i++) {
            UIView *v = moved[i];
            if (strcmp(starts[i].objCType, @encode(CGPoint)) != 0) {
                v.frame = starts[i].CGRectValue;
                continue;
            }
            // Its glyph where the old one's was: the button moved by as much as its glyph is off its center.
            UIImageView *glyph = glyphView(v);
            CGPoint inButton = [v convertPoint:glyph.center fromView:glyph.superview], to = [host convertPoint:starts[i].CGPointValue toView:v.superview];
            v.center = CGPointMake(to.x - (inButton.x - CGRectGetMidX(v.bounds)), to.y - (inButton.y - CGRectGetMidY(v.bounds)));
        }
        for (UIView *v in faded) v.alpha = 0;
        for (UIView *picture in gone) [host addSubview:picture];
    }];
    SGRAnimate(SGRMotionBar, ^{
        for (NSUInteger i = 0; i < moved.count; i++) moved[i].frame = targets[i].CGRectValue;
        if (along) along();
    }, completion);
    // The buttons that went leave quickly, and those that came arrive as the platter reaches them.
    SGRAnimate(SGRMotionExit, ^{ for (UIView *picture in gone) picture.alpha = 0; }, ^(BOOL finished) {
        for (UIView *picture in gone) [picture removeFromSuperview];
    });
    SGRAnimate(SGRMotionFade, ^{ for (UIView *v in faded) v.alpha = 1; }, nil);
}

@interface SGRPlatterHandoff : NSObject
@property (nonatomic, weak) UIView *host, *bar, *apartBar;
@property (nonatomic, copy) NSString *apartName;
@property (nonatomic, strong) CADisplayLink *link;
- (void)start;
- (void)stop;
@end

static SGRPlatterHandoff *sg_handoff;

static UIView *anyPlatterIn(UIView *bar) {
    __block UIView *platter = nil;
    SGForEachView(bar, ^(UIView *v) {
        if (!platter && [NSStringFromClass(v.class) hasSuffix:@"PlatterView"]) platter = v;
    });
    return platter;
}

@implementation SGRPlatterHandoff

- (void)start {
    [self.link invalidate];
    [self tick];
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    if (@available(iOS 15.0, *)) {
        self.link.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    }
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)tick {
    UIView *host = self.host, *bar = self.bar, *apartBar = self.apartBar;
    if (!host || !bar || !apartBar || sg_minimized) {
        [self stop];
        return;
    }
    UIView *barPlatter = anyPlatterIn(bar), *apartPlatter = anyPlatterIn(apartBar);
    if (!barPlatter || !apartPlatter) return;
    CGRect mainRect = shownIn(barPlatter, host), apartRect = shownIn(apartPlatter, host);
    BOOL merged = CGRectGetMaxX(mainRect) >= CGRectGetMinX(apartRect) - 4.0;
    if (!merged) {
        if (apartBar.hidden) apartBar.hidden = NO;
        if (self.apartName.length) {
            NSString *target = self.apartName;
            SGForEachView(bar, ^(UIView *v) {
                if (isTabButton(v) && [buttonKey(v, host) isEqualToString:target]) v.alpha = 0.0;
            });
        }
        return;
    }
    // As the platters meet, hide apartBar and let bar's spring run its course without stripping animations.
    apartBar.hidden = YES;
    if (self.apartName.length) {
        NSString *target = self.apartName;
        SGForEachView(bar, ^(UIView *v) {
            if (isTabButton(v) && [buttonKey(v, host) isEqualToString:target]) {
                v.alpha = 1.0;
                for (UIView *sub in v.subviews) sub.alpha = 1.0;
            }
        });
    }
    [self stop];
}

- (void)stop {
    [self.link invalidate];
    self.link = nil;
    UIView *bar = self.bar;
    if (bar) {
        SGForEachView(bar, ^(UIView *v) {
            if (!isTabButton(v)) return;
            v.alpha = 1.0;
            UIImageView *g = glyphView(v);
            if (g) g.alpha = 1.0;
        });
    }
}

@end

static void setMinimized(BOOL minimized, BOOL animated) {
    UIView *stockBar = sg_stockBar;
    if (minimized == sg_minimized) return;
    // Spotify's regular width bar is not the glass one's row of tabs; it stays as it is.
    if (minimized && (!stockBar.window || stockBar.traitCollection.horizontalSizeClass != UIUserInterfaceSizeClassCompact)) {
        sg_minimizedTarget = sg_minimized;
        return;
    }
    sg_transitioning = YES;
    [sg_handoff stop];
    sg_handoff = nil;
    if (!stockBar) {
        sg_minimized = sg_minimizedTarget = minimized;
        sg_keepApart = NO;
        sg_transitioning = NO;
        return;
    }
    UIView *host = objc_getAssociatedObject(stockBar, &kHostKey);
    UIView *bar = objc_getAssociatedObject(stockBar, &kBarKey);
    UIView *apartBar = objc_getAssociatedObject(stockBar, &kApartBarKey);
    NSArray<UIView *> *allSources = tabItems(stockBar);
    BOOL hasPermanentSplit = NO;
    for (UIView *source in allSources) {
        if (SGRTabIsApart(source)) {
            hasPermanentSplit = YES;
            break;
        }
    }
    BOOL wasShowingApart = apartBar && !apartBar.hidden;
    BOOL willAutoSplit = !hasPermanentSplit && SGRIsBarAutoSplit() && allSources.count >= 2;
    sg_minimized = sg_minimizedTarget = minimized;
    // Only keep apartBar on screen during expand if apartBar was actually visible while minimized.
    sg_keepApart = !minimized && wasShowingApart;
    SGLog(@"tab bar: %@", minimized ? @"minimized" : @"expanded");
    void (^settle)(BOOL) = ^(BOOL finished) {
        if (sg_minimized != minimized) return;
        [sg_handoff stop];
        sg_handoff = nil;
        sg_keepApart = NO;
        if (apartBar) apartBar.alpha = 1;
        syncBar(stockBar);
    };
    animated &= host.window != nil;
    if (animated && minimized && willAutoSplit && apartBar && apartBar.hidden) {
        [UIView performWithoutAnimation:^{
            sg_minimized = NO;
            apartBar.hidden = NO;
            apartBar.alpha = 1;
            UIView *trailing = autoSplitTrailingSource(allSources);
            if (trailing) fillBar((SGRSystemTabBar *)apartBar, @[trailing], YES, nil, YES);
            [apartBar setNeedsLayout];
            [apartBar layoutIfNeeded];
            SGForEachView(apartBar, ^(UIView *v) {
                if (isTabButton(v)) v.hidden = YES;
            });
            sg_minimized = minimized;
        }];
    }
    SGRBarState before = animated ? barState(host) : (SGRBarState){0};
    // The items are made where the bars are going, before anything moves. UIKit sizes a tab's name by the platter
    // its item is made in and never again, and the first pass made the expanding row's items while the bar still
    // held the circle's one item, its platter a circle: "Your Library" stayed cut. So they are made a second time,
    // the platters now the full row's, and the names are whole all the way.
    [UIView performWithoutAnimation:^{
        if (minimized && apartBar) ((SGRSystemTabBar *)apartBar).sources = nil;
        syncBar(stockBar);
        [host layoutIfNeeded];
        if (!minimized) {
            ((SGRSystemTabBar *)objc_getAssociatedObject(stockBar, &kBarKey)).sources = nil;
            if (hasPermanentSplit) ((SGRSystemTabBar *)objc_getAssociatedObject(stockBar, &kApartBarKey)).sources = nil;
            syncBar(stockBar);
            [host layoutIfNeeded];
        }
        if (!animated) {
            sg_scrollSquish = 0;
            applyScrollSquish(host, 0);
            SGRNowPlayingBarSetScrollSquish(0);
            SGRNowPlayingBarFollowTabBar();
        }
    }];
    if (!animated) {
        sg_transitioning = NO;
        settle(YES);
        return;
    }
    SGRNowPlayingBarMoving(YES);
    if (apartBar) apartBar.alpha = 1;
    UITabBarItem *trailItem = (apartBar && ((SGRSystemTabBar *)apartBar).items.count > 0) ? ((SGRSystemTabBar *)apartBar).items.firstObject : nil;
    NSString *apartName = trailItem.accessibilityLabel ?: trailItem.title;
    BOOL splitTransition = !hasPermanentSplit && (minimized ? willAutoSplit : wasShowingApart);
    moveFrom(host, before, bar, apartName, splitTransition, ^{
        sg_scrollSquish = 0;
        applyScrollSquish(host, 0);
        SGRNowPlayingBarSetScrollSquish(0);
        SGRNowPlayingBarFollowTabBar();
    }, ^(BOOL finished) {
        SGRNowPlayingBarMoving(NO);
        settle(finished);
    });
    if (!minimized && splitTransition && apartBar && apartName.length) {
        [host insertSubview:apartBar belowSubview:bar];
        sg_handoff = [SGRPlatterHandoff new];
        sg_handoff.host = host;
        sg_handoff.bar = bar;
        sg_handoff.apartBar = apartBar;
        sg_handoff.apartName = apartName;
        [sg_handoff start];
    }
    sg_transitioning = NO;
}

// The glass the expanded bar draws runs kPlatterInset in from either side of Spotify's bar, the split tabs' bar
// included: its trailing platter ends where the main one would have.
static CGRect platterEdges(UIView *stockBar, UIView *host) {
    return CGRectInset([stockBar convertRect:stockBar.bounds toView:host], kPlatterInset, 0);
}

CGRect SGRTabBarInlineSlot(UIView *host, CGFloat height) {
    if (SGRLegacyTabBarOn()) return SGRLegacyTabBarInlineSlot(host, height);
    UIView *stockBar = sg_stockBar;
    UIView *bar = stockBar ? objc_getAssociatedObject(stockBar, &kBarKey) : nil;
    UIView *apartBar = stockBar ? objc_getAssociatedObject(stockBar, &kApartBarKey) : nil;
    if (!sg_minimized || !host || !bar.window || stockBar.hidden || stockBar.alpha < 0.01) return CGRectNull;
    // Calculated from the bars' settled frames, never from live platter subview frames which moveFrom resets
    // to their pre-animation start rects before invoking SGRNowPlayingBarFollowTabBar.
    BOOL hasApart = apartBar && (!apartBar.hidden || ((SGRSystemTabBar *)apartBar).sources.count > 0);
    CGRect lead = [bar.superview convertRect:bar.frame toView:host];
    CGRect trail = hasApart ? [apartBar.superview convertRect:apartBar.frame toView:host] : CGRectZero;
    BOOL compact = SGRIsBarCompact();
    CGFloat apartItemW = compact ? kCompactCircleSize : kApartItemWidth;
    CGFloat inset = compact ? (kPlatterInset + round((kApartItemWidth - kCompactCircleSize) / 2.0)) : kPlatterInset;
    CGFloat gap = compact ? 12.0 : SGRGrid;
    CGFloat left = CGRectGetMinX(lead) + inset + apartItemW + gap;
    CGFloat right = hasApart
        ? CGRectGetMaxX(trail) - inset - apartItemW - gap
        : CGRectGetMaxX(platterEdges(stockBar, host));
    CGFloat middle = CGRectGetMinY(lead) + kApartItemWidth / 2.0;
    CGRect slot = CGRectMake(left, middle - height / 2.0, MAX(0, right - left), height);
    // A bar Spotify has slid away for a page takes the slot off the screen with it.
    CGRect inWindow = [host convertRect:slot toView:nil];
    if (slot.size.width < 100 || CGRectGetMaxY(inWindow) > CGRectGetMaxY(bar.window.bounds)) return CGRectNull;
    return slot;
}

// Only the x edges are meant; a bar Spotify has slid away for a page keeps them.
CGRect SGRTabBarGlassRow(UIView *host) {
    UIView *stockBar = sg_stockBar;
    UIView *bar = stockBar ? objc_getAssociatedObject(stockBar, &kBarKey) : nil;
    if (!host || !bar.window || stockBar.traitCollection.horizontalSizeClass != UIUserInterfaceSizeClassCompact) return CGRectNull;
    return platterEdges(stockBar, host);
}

#pragma mark - hooks

// The bar in its own pass, and whether one of its items laid out during it.
static __weak UIView *sg_passBar;
static BOOL sg_itemsLaidOut;

%hook _TtC23NavigationUI_TabBarImpl10TabBarView
- (void)layoutSubviews {
    // A pass nested in another (an item's layoutIfNeeded) hands both back, so the outer one still composes.
    UIView *bar = (UIView *)self, *outer = sg_passBar;
    BOOL outerLaidOut = sg_itemsLaidOut;
    sg_passBar = bar;
    %orig;
    SGRComposeTabBar(bar);
    sg_itemsLaidOut = NO;
    for (UIView *sub in bar.subviews) {
        if (![sub isKindOfClass:SGRTabBarHost.class] && ![sub isKindOfClass:SGRBarFade.class]) [sub layoutIfNeeded];
    }
    // Items the row's pass laid out are composed once, all together, rather than once each.
    if (sg_itemsLaidOut) SGRComposeTabBar(bar);
    sg_passBar = outer;
    sg_itemsLaidOut = outerLaidOut;
    SGRHoldHomeForModSettings(bar);
    syncBar(bar);
    SGRLogTabBarRow(bar);
}
%end

// The bar's own pass runs before Spotify has filled the row; the items lay out as they arrive. Inside the bar's
// pass, the pass composes once after them; outside it, the item composes at once, so no frame shows Spotify's row.
static void itemDidLayOut(UIView *item) {
    UIView *bar = tabBarOf(item);
    if (!bar) return;
    if (bar == sg_passBar) {
        sg_itemsLaidOut = YES;
        return;
    }
    SGRComposeTabBar(bar);
    SGRHoldHomeForModSettings(bar);
    syncBar(bar);
    SGRLogTabBarRow(bar);
}

%hook _TtC23NavigationUI_TabBarImpl21TabBarItemElementView
- (void)layoutSubviews {
    %orig;
    itemDidLayOut((UIView *)self);
}
%end

%hook _TtC25CreateMenu_TabBarItemImpl24CreateMenuTabBarItemView
- (void)layoutSubviews {
    %orig;
    itemDidLayOut((UIView *)self);
}
%end

// A tab changed from elsewhere (a link, the side drawer) repaints the labels without a layout pass.
%hook _TtC23NavigationUI_TabBarImpl19TabBarContainerImpl
- (void)setSelectedViewController:(UIViewController *)controller {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Another tab brings the minimized bar back (HIG, Tab bars).
        SGRSetTabBarMinimized(NO, YES);
        UIView *bar = sg_stockBar;
        if (bar) syncBar(bar);
    });
}
// The message bar coming or going changes the view's safe area before Spotify lays the bar out for it,
// so the room follows in that same pass, and inside the message bar's animation.
- (void)viewSafeAreaInsetsDidChange {
    %orig;
    makeRoom((UIViewController *)self);
}
%end

// Spotify's own fade under its bar, 219 pt down to black from 9.1.90 (TabBarGradientView), stacked with SGRBarFade
// into a band near black over the page's foot. SGRBarFade is the redesign's, so Spotify's stays clear.
%group SpotifyBarFade
%hook _TtC23NavigationUI_TabBarImpl18TabBarGradientView
- (void)didMoveToWindow {
    %orig;
    ((UIView *)self).alpha = 0;
}
- (void)setAlpha:(CGFloat)alpha {
    %orig(0);
}
%end
%end

%ctor {
    if (!SGRedesignedUI() || SGRLegacyTabBarOn()) return;   // below iOS 26 TabBarLegacy.x is the bar
    %init;
    if (objc_getClass("_TtC23NavigationUI_TabBarImpl18TabBarGradientView")) %init(SpotifyBarFade);
    SGRequireClasses(@[
        @"_TtC23NavigationUI_TabBarImpl10TabBarView",
        @"_TtC23NavigationUI_TabBarImpl21TabBarItemElementView",
        @"_TtC25CreateMenu_TabBarItemImpl24CreateMenuTabBarItemView",
        @"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl",
    ]);
}

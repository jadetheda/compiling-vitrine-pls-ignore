// Player redesign: the footer as the Music app's row of three glyphs, lyrics, devices and queue, spread
// evenly across the player, and no share button.
//
// Spotify's footer is Connect with the device's name at the leading edge, share, and the queue at the
// trailing edge. Connect and the queue stay Spotify's controls (the device sheet, the remote device
// tint, the Jam avatars) and are only moved, by a translation of the arranged view that holds each: a
// transform survives the stack view laying them out again, and moving the holder keeps its touches
// inside its own bounds. The device name goes transparent, since the glyph alone sits in the middle, and
// Connect's holder takes touches only in a square over the glyph (SGRPlayerCoverConnect).
// Both draw the Music app's glyphs, AirPlay audio and a bulleted list (issue #109): a stand-in inside each of
// Spotify's glyph views, so it is hidden, faded and pulsed with Spotify's own, while Spotify's drawing goes
// clear at its source. Connect's glyph is an image Spotify draws the color into: each new one is read once for
// that color, so a device in use still lights it in the accent (or the cover's, PlayerCoverAccent.x), and is
// swapped for a clear image of its size. The queue's is an SPTEncoreIconView: its foreground colors are kept
// for the stand-in and Spotify's drawn clear.
// Spotify has no lyrics control down here, so that one is the Kit's glyph button, and it turns the
// lyrics in the player on and off (PlayerLyrics.x): filled while they are up, dimmed and dead for a
// track that has none.
// Spotify's icons (SGRKeyPlayerSpotifyIcons) leaves Connect's and the queue's glyphs Spotify's, and draws the Lyrics
// glyph as Spotify's Encore "lyrics", lit in the primary color while the lyrics are up.
//
// The row sits lower than Spotify puts it, just over the home indicator the way the Music app's does
// (issue #54): the footer unit's view is translated down, the controls follow it part of the way, and a
// band of the redesign's hands the touches below the bottom stack's bounds back to the row.
//
// Tree (trees/clean/player/01.txt:295-320): FooterElementsUnit's view 402x44 > UIStackView 382x44 >
// ElementView > ConnectButtonOutputSwitcherViewHolder id=Components.ConnectButtonOutputSwitcher 153x36
// (a 19x19 UIImageView glyph and a MarqueeLabel with the device name), a spacer, a hidden media trimmer,
// ElementView > EncoreButton id=ShareButtonNowPlayingView 44x44, ElementView > Queue control
// id=QueueButtonNowPlaying 47x32 (an 18x18 SPTEncoreIconView id=Encore.IconView glyph, out/rep/ptree.txt:1228-1279).
#import <substrate.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Headers/SPTEncoreIconView.h"
#import "Player.h"
#import "Shared/Navigation/TabIcons.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

static const CGFloat kLyricsGlyphSize = 20;
// Filled and at full strength while the lyrics are up, the way the Music app marks the control that is on.
static NSString *const kLyricsSymbol = @"quote.bubble", *const kLyricsSymbolOpen = @"quote.bubble.fill";
// Where the three glyphs sit, as parts of the footer's width (matching Apple Music's ~80.7 pt inset from edges).
static const CGFloat kLeading = 0.207, kMiddle = 0.5, kTrailing = 0.793;
static const CGFloat kGlyphMaxWidth = 30;

// Issue #54: Spotify ends its bottom stack 61pt above the screen's bottom (01.txt:127, 576.67 + 236 of
// 874), so the row's middle sat 83pt up, well clear of the home indicator, and the controls crowded it.
// The Music app keeps that row just over the home indicator: its middle this far above the safe area's
// bottom, and never less than kRowMinBottom above the screen's on a phone without a home indicator.
static const CGFloat kRowAboveSafeArea = 20, kRowMinBottom = 34;
// The controls follow a share of the row's move when nothing stands between them, so the gaps above
// and below them even out instead of all the room opening under them.
static const CGFloat kControlsShare = 0.3;
// The volume row's sides, the player's own margin.
static const CGFloat kVolumeMargin = 24;
// And the controls go up this much over it, so the gaps above and below the volume row match.
static const CGFloat kVolumeLift = 10;

// "airplayaudio" is the name iOS 16 knows; iOS 18 calls it airplay.audio and keeps this one as its alias.
static NSString *const kConnectSymbol = @"airplayaudio", *const kQueueSymbol = @"list.bullet";
static NSString *const kSharedAudioSymbol = @"person.2.fill";

static char kEncoreKey;
static char kConnectKey, kShareKey, kTrimmerKey, kSharedByKey, kQueueKey, kLyricsGlyphKey, kQueueGlyphKey, kReachKey, kRowKey;
static __weak SGRGlyphButton *sg_lyricsGlyph;
static __weak SGRGlyphButton *sg_queueGlyph;
static __weak UIView *sg_footerRow;

// The view the footer's stack view arranges around `view`.
static UIView *arrangedAround(UIView *view, UIView *host) {
    for (UIView *v = view; v && v != host; v = v.superview) {
        if ([v.superview isKindOfClass:UIStackView.class]) return v;
    }
    return nil;
}

// Where `point` of `view` is in the host with the arranged view's own transform left out.
static CGFloat untransformedX(UIView *arranged, UIView *view, CGPoint point, UIView *host) {
    CGPoint local = [view convertPoint:point toView:arranged];
    CGPoint inRow = CGPointMake(arranged.center.x + local.x - CGRectGetMidX(arranged.bounds), arranged.center.y);
    return [arranged.superview convertPoint:inRow toView:host].x;
}

CGFloat SGRPlayerTranslateArranged(UIView *arranged, UIView *view, CGPoint point, UIView *host, CGFloat x) {
    if (!arranged) return -1;
    CGFloat from = untransformedX(arranged, view, point, host);
    CGAffineTransform transform = CGAffineTransformMakeTranslation(round(x - from), 0);
    if (!CGAffineTransformEqualToTransform(arranged.transform, transform)) arranged.transform = transform;
    return from;
}

#pragma mark - Spotify's icons

BOOL SGRPlayerSpotifyIcons(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGHidden(SGRKeyPlayerSpotifyIcons); });
    return on;
}

UIView *SGRPlayerEncoreGlyphIn(SGRGlyphButton *button, NSString *name) {
    if (!button) return nil;
    SPTEncoreIconView *encore = objc_getAssociatedObject(button, &kEncoreKey);
    if (!encore) {
        Class icons = NSClassFromString(@"SPTEncoreIcon"), view = NSClassFromString(@"SPTEncoreIconView");
        SEL glyphSel = NSSelectorFromString(name);
        if (!icons || !view || ![icons respondsToSelector:glyphSel]) {
            SGLog(@"redesign player: no Encore glyph %@, the Music app's stays", name);
            return nil;
        }
        id glyph = ((id (*)(id, SEL))objc_msgSend)(icons, glyphSel);
        encore = glyph ? [[view alloc] initWithIcon:glyph] : nil;
        if (!encore) return nil;
        encore.userInteractionEnabled = NO;
        encore.isAccessibilityElement = NO;
        CGSize size = encore.intrinsicContentSize;
        encore.bounds = CGRectMake(0, 0, size.width > 0 ? size.width : 24, size.height > 0 ? size.height : 24);
        encore.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                                | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        encore.foregroundColor = button.glyph.tintColor ?: SGRPrimary();
        objc_setAssociatedObject(button, &kEncoreKey, encore, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Hidden rather than clear: the button puts its glyph's alpha back as it is pressed.
    button.glyph.hidden = YES;
    if (encore.superview != button) [button addSubview:encore];
    encore.center = CGPointMake(CGRectGetMidX(button.bounds), CGRectGetMidY(button.bounds));
    return encore;
}

#pragma mark - lyrics

void SGRPlayerLyricsChanged(void) {
    SGRPlayerMotionLyricsChanged();
    SGRPlayerVisualiserUpdate();
    SGRGlyphButton *glyph = sg_lyricsGlyph;
    if (!glyph) return;
    BOOL enabled = SGRPlayerLyricsAvailable() || SGRPlayerLyricsOpen(), open = SGRPlayerLyricsOpen();
    BOOL wasOpen = [glyph.glyph.symbol isEqualToString:kLyricsSymbolOpen];
    if (glyph.enabled == enabled && wasOpen == open) return;
    // Lyrics turn up once the player has fetched them, well after the footer laid out: a fade, not a pop.
    // While the player opens or closes the glyph and the lyrics come and go together, so nothing animates.
    BOOL animated = glyph.window && !SGRPlayerIsTransitioning();
    [glyph.glyph setSymbol:open ? kLyricsSymbolOpen : kLyricsSymbol animated:animated];
    void (^mark)(void) = ^{
        glyph.enabled = enabled;
        glyph.glyph.tintColor = open ? SGRPrimary() : SGRSecondary();
        glyph.backgroundColor = open ? [UIColor colorWithWhite:1.0 alpha:0.18] : UIColor.clearColor;
        glyph.layer.cornerRadius = glyph.bounds.size.height > 0 ? glyph.bounds.size.height / 2.0 : 22.0;
        glyph.clipsToBounds = YES;
        ((SPTEncoreIconView *)objc_getAssociatedObject(glyph, &kEncoreKey)).foregroundColor = glyph.glyph.tintColor;
    };
    if (animated) SGRAnimate(SGRMotionFade, mark, nil);
    else mark();
}

SGRGlyphButton *SGRPlayerLyricsGlyphIn(UIView *host) {
    SGRGlyphButton *glyph = objc_getAssociatedObject(host, &kLyricsGlyphKey);
    if (!glyph) {
        glyph = [SGRGlyphButton buttonWithSymbol:kLyricsSymbol pointSize:kLyricsGlyphSize title:@"Lyrics"];
        glyph.glyph.tintColor = SGRSecondary();
        glyph.onTap = ^{ SGRPlayerToggleLyrics(); };
        objc_setAssociatedObject(host, &kLyricsGlyphKey, glyph, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glyph.superview != host) [host addSubview:glyph];
    if (SGRPlayerSpotifyIcons()) SGRPlayerEncoreGlyphIn(glyph, @"lyrics");
    sg_lyricsGlyph = glyph;
    return glyph;
}

#pragma mark - queue

static UIImage *SGRQueueActiveKnockoutIconImage(CGSize size) {
    static UIImage *cached = nil;
    static CGSize cachedSize = {0, 0};
    if (cached && CGSizeEqualToSize(cachedSize, size)) return cached;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef cg = ctx.CGContext;
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:rect];
        [[UIColor colorWithWhite:1.0 alpha:0.65] setFill];
        [circle fill];

        // Knockout SF Symbol list.bullet using kCGBlendModeDestinationOut + template alpha mask
        // (kCGBlendModeClear in Quartz clears the entire rectangular bounding box instead of masking by alpha)
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19.8 weight:UIImageSymbolWeightMedium];
        UIImage *sym = [[UIImage systemImageNamed:kQueueSymbol withConfiguration:cfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        if (sym) {
            CGRect symRect = CGRectMake((size.width - sym.size.width) * 0.5,
                                        (size.height - sym.size.height) * 0.5,
                                        sym.size.width,
                                        sym.size.height);
            CGContextSetBlendMode(cg, kCGBlendModeDestinationOut);
            [[UIColor colorWithWhite:0.0 alpha:1.0] setFill];
            [sym drawInRect:symRect];
        }
    }];
    cached = [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    cachedSize = size;
    return cached;
}

UIImage *SGRPlayerQueueActiveIcon(CGSize size) {
    return SGRQueueActiveKnockoutIconImage(size);
}

UIView *SGRPlayerFooterRow(void) {
    return sg_footerRow;
}

void SGRPlayerTriggerConnect(void) {
    UIView *row = sg_footerRow;
    if (!row) return;
    UIView *connect = SGRFindByIdentifier(row, @"Components.ConnectButtonOutputSwitcher", &kConnectKey);
    if (connect) SGRActivate(connect);
}

static char kQueueWasOpenKey;

void SGRPlayerQueueChanged(void) {
    SGRPlayerMotionLyricsChanged();
    SGRPlayerVisualiserUpdate();
    SGRPlayerControlsQueueChanged();
    SGRGlyphButton *glyph = sg_queueGlyph;
    if (!glyph) return;
    BOOL open = SGRPlayerQueueOpen();
    NSNumber *wasOpen = objc_getAssociatedObject(glyph, &kQueueWasOpenKey);
    if (wasOpen && wasOpen.boolValue == open) return;
    objc_setAssociatedObject(glyph, &kQueueWasOpenKey, @(open), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    BOOL animated = glyph.window && !SGRPlayerIsTransitioning();
    void (^mark)(void) = ^{
        glyph.opaque = NO;
        glyph.layer.opaque = NO;
        glyph.glyph.opaque = NO;
        glyph.glyph.layer.opaque = NO;
        if (open) {
            glyph.glyph.image = SGRQueueActiveKnockoutIconImage(CGSizeMake(38.0, 38.0));
            glyph.glyph.tintColor = nil;
            glyph.backgroundColor = UIColor.clearColor;
            glyph.layer.compositingFilter = nil;
        } else {
            glyph.glyph.image = [UIImage systemImageNamed:kQueueSymbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:kLyricsGlyphSize weight:UIImageSymbolWeightRegular]];
            glyph.glyph.tintColor = [UIColor colorWithWhite:1.0 alpha:0.65];
            glyph.backgroundColor = UIColor.clearColor;
            glyph.layer.compositingFilter = nil;
        }
        glyph.layer.cornerRadius = 19.0;
        glyph.layer.cornerCurve = kCACornerCurveContinuous;
        glyph.clipsToBounds = YES;
        [glyph setNeedsLayout];
        [glyph layoutIfNeeded];
    };
    if (animated) SGRAnimate(SGRMotionFade, mark, nil);
    else mark();
}

void SGRPlayerLayoutFooterForQueue(void) {
    UIView *row = sg_footerRow;
    if (row) SGRPlayerLowerRow(row);
}

SGRGlyphButton *SGRPlayerQueueGlyphIn(UIView *host) {
    SGRGlyphButton *glyph = objc_getAssociatedObject(host, &kQueueGlyphKey);
    if (!glyph) {
        glyph = [SGRGlyphButton buttonWithSymbol:kQueueSymbol pointSize:kLyricsGlyphSize title:@"Queue"];
        glyph.onTap = ^{ SGRPlayerToggleQueue(); };
        objc_setAssociatedObject(host, &kQueueGlyphKey, glyph, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glyph.superview != host) [host addSubview:glyph];
    sg_queueGlyph = glyph;
    return glyph;
}

#pragma mark - the Music app's glyphs

static char kStandInKey, kClearKey, kConnectLitKey, kConnectInkKey, kConnectNameKey;

// The Kit's glyph centered inside `drawn`: it takes `drawn`'s hidden, alpha and animations with it.
static SGRGlyphView *standIn(UIView *drawn, NSString *symbol) {
    if (!drawn) return nil;
    SGRGlyphView *glyph = objc_getAssociatedObject(drawn, &kStandInKey);
    if (!glyph) {
        glyph = [[SGRGlyphView alloc] initWithSymbol:symbol pointSize:kLyricsGlyphSize weight:UIImageSymbolWeightRegular];
        glyph.userInteractionEnabled = NO;
        glyph.isAccessibilityElement = NO;
        glyph.tintColor = [UIColor colorWithWhite:1.0 alpha:0.65];   // neutral translucent white matching lyrics
        // Kept centered when Spotify resizes the view between the footer's passes (a new Connect image of another size).
        glyph.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                               | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        objc_setAssociatedObject(drawn, &kStandInKey, glyph, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glyph.superview != drawn) [drawn addSubview:glyph];
    CGPoint middle = CGPointMake(CGRectGetMidX(drawn.bounds), CGRectGetMidY(drawn.bounds));
    if (!CGPointEqualToPoint(glyph.center, middle)) glyph.center = middle;
    return glyph;
}

static NSString *const kSpeakerSymbol = @"hifispeaker.fill";
static NSHashTable<UIImageView *> *sg_connectViews;
static NSString *sg_routeSymbol;
static NSString *sg_routePortName;
static BOOL sg_routeIsAirPlay;
static BOOL sg_routeIsLocalAccessory;
static __weak id sg_connectAggregator;
// What MediaPlayer names the active route's glyph (fetchAppleRouteSymbol), nil until it answers or when it cannot.
static NSString *sg_appleRouteSymbol;
static NSUInteger sg_appleRouteRequest;
static NSString *sg_routeUID;   // the first output's, to tell another device from the same one with a new category

// NULL-terminated substring -> SF Symbol rule; matched case-insensitively with zero allocations.
typedef struct {
    __unsafe_unretained NSString *needle, *primary, *fallback;
} SGRSymbolRule;

// A symbol by name, drawn in `config`. A public one loads as it always did here; any other (the system loads a route's glyph
// with _systemImageNamed:, so some are private) goes through the tabs' lookup, with `config` on top, since the Kit's own
// finds public names only. A template, as the tabs draw every symbol (symbolView in TabIcons.m), so the glyph's tint reaches it.
static UIImage *routeGlyph(NSString *name, UIImageSymbolConfiguration *config) {
    if (!name.length) return nil;
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:config];
    if (!image) {
        image = SGSymbolImage(name);
        if (image && config) image = [image imageByApplyingSymbolConfiguration:config] ?: image;
    }
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// Whether a name draws. A hit is remembered: the footer asks on every layout pass.
static BOOL symbolDraws(NSString *name) {
    if (!name.length) return NO;
    static NSMutableSet<NSString *> *drawn;
    if ([drawn containsObject:name]) return YES;
    UIImage *image = routeGlyph(name, nil);
    if (!image) return NO;
    if (!drawn) drawn = [NSMutableSet set];
    [drawn addObject:name];
    if (![UIImage systemImageNamed:name]) {
        SGLog(@"redesign player: %@ is not a public symbol; loaded %@, symbol image %d", name, NSStringFromCGSize(image.size), image.isSymbolImage);
    }
    return YES;
}

static NSString *firstSymbol(NSString *primary, NSString *fallback, NSString *defaultSymbol) {
    if (symbolDraws(primary)) return primary;
    if (symbolDraws(fallback)) return fallback;
    return defaultSymbol;
}

static NSString *matchSymbol(NSString *haystack, const SGRSymbolRule *rules, NSString *defaultSymbol) {
    if (!haystack.length) return defaultSymbol;
    for (const SGRSymbolRule *r = rules; r->needle; r++) {
        if ([haystack rangeOfString:r->needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return firstSymbol(r->primary, r->fallback, defaultSymbol);
        }
    }
    return defaultSymbol;
}

// Apple's own per-product symbols (SF Symbols 7), most specific first. The second name is the older spelling, for an iOS
// without the first. SF Symbols has no Bluetooth glyph and cannot tell a pair of earbuds from a speaker by its port, so any
// other device gets the speaker the system's picker uses for one it does not know.
static NSString *bluetoothSymbol(NSString *portName) {
    static const SGRSymbolRule rules[] = {
        {@"airpods max",              @"airpods.max",          @"airpodsmax"},
        {@"airpods pro",              @"airpods.pro",          @"airpodspro"},
        {@"airpods 4",                @"airpods.gen4",         @"airpods.gen3"},
        {@"airpods (4",               @"airpods.gen4",         @"airpods.gen3"},
        {@"airpods 3",                @"airpods.gen3",         nil},
        {@"airpods (3",               @"airpods.gen3",         nil},
        {@"airpods",                  @"airpods",              nil},
        {@"powerbeats pro 2",         @"beats.powerbeats.pro.2", @"beats.powerbeats.pro"},
        {@"powerbeats pro",           @"beats.powerbeats.pro", @"beats.powerbeatspro"},
        {@"powerbeats3",              @"beats.powerbeats3",    @"beats.powerbeats"},
        {@"powerbeats",               @"beats.powerbeats",     @"beats.earphones"},
        {@"beats fit pro",            @"beats.fit.pro",        @"beats.fitpro"},
        {@"beats studio buds +",      @"beats.studiobuds.plus", @"beats.studiobudsplus"},
        {@"beats studio buds+",       @"beats.studiobuds.plus", @"beats.studiobudsplus"},
        {@"beats studio buds plus",   @"beats.studiobuds.plus", @"beats.studiobudsplus"},
        {@"beats studio buds",        @"beats.studiobuds",     nil},
        {@"beats solo buds",          @"beats.solobuds",       nil},
        {@"beats pill",               @"beats.pill",           nil},
        {@"beatsx",                   @"beats.earphones",      nil},
        {@"beats flex",               @"beats.earphones",      nil},
        {@"beats",                    @"beats.headphones",     nil},
        {nil, nil, nil}
    };
    return matchSymbol(portName, rules, kSpeakerSymbol);
}

static NSString *connectDeviceSymbol(NSString *deviceName) {
    static const SGRSymbolRule rules[] = {
        {@" + ",          @"hifispeaker.2.fill", nil},
        {@" & ",          @"hifispeaker.2.fill", nil},
        {@"multi-room",   @"hifispeaker.2.fill", nil},
        {@"multiroom",    @"hifispeaker.2.fill", nil},
        {@"everywhere",   @"hifispeaker.2.fill", nil},
        {@"speakers",     @"hifispeaker.2.fill", nil},
        {@"group",        @"hifispeaker.2.fill", nil},
        {@"homepod mini", @"homepodmini.fill",   @"homepod.mini.fill"},
        {@"homepod",      @"homepod.fill",       nil},
        {@"apple tv",     @"appletv.fill",       nil},
        {@"macbook",      @"laptopcomputer",     nil},
        {@"laptop",       @"laptopcomputer",     nil},
        {@"imac",         @"desktopcomputer",    nil},
        {@"mac mini",     @"desktopcomputer",    nil},
        {@"mac studio",   @"desktopcomputer",    nil},
        {@"mac pro",      @"desktopcomputer",    nil},
        {@"desktop",      @"desktopcomputer",    nil},
        {@"iphone",       @"iphone",             nil},
        {@"ipad",         @"ipad",               nil},
        {@"apple watch",  @"applewatch",         nil},
        {@"playstation",  @"gamecontroller.fill", nil},
        {@"ps5",          @"gamecontroller.fill", nil},
        {@"ps4",          @"gamecontroller.fill", nil},
        {@"xbox",         @"gamecontroller.fill", nil},
        {@"chromecast",   @"tv.and.mediabox",    nil},
        {@"fire tv",      @"tv.and.mediabox",    nil},
        {@"roku",         @"tv.and.mediabox",    nil},
        {@"shield",       @"tv.and.mediabox",    nil},
        {@"tv",           @"tv",                 nil},
        {nil, nil, nil}
    };
    return matchSymbol(deviceName, rules, kSpeakerSymbol);
}

// Spotify's device types: ConnectAggregatorEntityDeviceType's cases in declaration order from 0. The binary does not show
// the values themselves, so the log below prints the number the entity reports.
enum {
    kConnectUnknown, kConnectComputer, kConnectTablet, kConnectSmartphone, kConnectSpeaker, kConnectTV, kConnectAVR,
    kConnectSetTopBox, kConnectAudioDongle, kConnectGameConsole, kConnectCastVideo, kConnectCastAudio, kConnectAutomobile,
    kConnectSmartwatch, kConnectTypeCount
};

// The glyph for the device Spotify plays on, by what Spotify reports of it: the aggregator's active entity
// (SPTConnectAggregatorEntity) has a deviceType and an isGroup. The system picker names a third-party route from five types
// (MediaControls in iOS 27.2, symbolNameForVendorSpecificRoute:): a group is hifispeaker.2.fill, a set-top box
// tv.and.mediabox, a TV tv, a laptop laptopcomputer, a desktop desktopcomputer, and anything else hifispeaker.fill. Those are
// used as they are. The types the picker has no glyph for take the symbol of the thing itself (a phone, a tablet, a watch, a
// car, a console), and a receiver takes the picker's glyph for devices it has no name for, tv.and.hifispeaker.fill
// (MRUAssetsProvider genericDevices). nil with no entity or a type that says nothing: the name decides then.
static NSString *connectEntitySymbol(NSString *connectName) {
    static NSString *const symbols[kConnectTypeCount] = {
        [kConnectComputer] = @"laptopcomputer", [kConnectTablet] = @"ipad", [kConnectSmartphone] = @"iphone",
        [kConnectSpeaker] = @"hifispeaker.fill", [kConnectTV] = @"tv", [kConnectAVR] = @"tv.and.hifispeaker.fill",
        [kConnectSetTopBox] = @"tv.and.mediabox", [kConnectAudioDongle] = @"hifispeaker.fill",
        [kConnectGameConsole] = @"gamecontroller.fill", [kConnectCastVideo] = @"tv", [kConnectCastAudio] = @"hifispeaker.fill",
        [kConnectAutomobile] = @"car.fill", [kConnectSmartwatch] = @"applewatch",
    };
    id aggregator = sg_connectAggregator;
    if (![aggregator respondsToSelector:@selector(activeConnectEntity)]) return nil;
    id entity = ((id (*)(id, SEL))objc_msgSend)(aggregator, @selector(activeConnectEntity));
    if (![entity respondsToSelector:@selector(deviceType)]) return nil;
    NSUInteger type = ((NSUInteger (*)(id, SEL))objc_msgSend)(entity, @selector(deviceType));
    BOOL group = [entity respondsToSelector:@selector(isGroup)] && ((BOOL (*)(id, SEL))objc_msgSend)(entity, @selector(isGroup));
    NSString *symbol = nil;
    if (group) {
        symbol = @"hifispeaker.2.fill";
    } else if (type < kConnectTypeCount) {
        symbol = symbols[type];
        // The name refines the type: a desktop rather than a laptop, an Apple TV rather than a TV.
        NSString *byName = connectDeviceSymbol(connectName);
        if (type == kConnectComputer && [byName isEqualToString:@"desktopcomputer"]) symbol = byName;
        if ((type == kConnectTV || type == kConnectSetTopBox || type == kConnectCastVideo) && [byName isEqualToString:@"appletv.fill"]) symbol = byName;
    }
    static NSUInteger loggedType = NSNotFound;
    static BOOL loggedGroup;
    if (type != loggedType || group != loggedGroup) {
        loggedType = type;
        loggedGroup = group;
        SGLog(@"redesign player: connect device type %lu%@ -> %@", (unsigned long)type, group ? @", group" : @"", symbol ?: @"by name");
    }
    return symbolDraws(symbol) ? symbol : nil;
}

static NSString *routeSymbolForOutputs(NSArray<AVAudioSessionPortDescription *> *outputs, BOOL *isAirPlay) {
    if (isAirPlay) *isAirPlay = NO;
    AVAudioSessionPortDescription *port = outputs.firstObject;
    if (!port) return kConnectSymbol;

    NSUInteger airplayCount = 0;
    AVAudioSessionPortDescription *airplayPort = nil;
    for (AVAudioSessionPortDescription *outPort in outputs) {
        if ([outPort.portType isEqualToString:AVAudioSessionPortAirPlay]) {
            airplayCount++;
            if (!airplayPort) airplayPort = outPort;
        }
    }
    if (airplayCount > 0) {
        if (isAirPlay) *isAirPlay = YES;
        if (airplayCount > 1) return firstSymbol(@"hifispeaker.2.fill", nil, kConnectSymbol);
        static const SGRSymbolRule airplayRules[] = {
            {@" + ",          @"hifispeaker.2.fill", nil},
            {@"homepod mini", @"homepodmini.fill",   @"homepod.mini.fill"},
            {@"homepod",      @"homepod.fill",       nil},
            {@"apple tv",     @"appletv.fill",       nil},
            {nil, nil, nil}
        };
        return matchSymbol(airplayPort.portName, airplayRules, kConnectSymbol);
    }

    NSString *type = port.portType;
    if ([type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
        [type isEqualToString:AVAudioSessionPortBluetoothLE] ||
        [type isEqualToString:AVAudioSessionPortBluetoothHFP]) {
        return bluetoothSymbol(port.portName);
    }
    if ([type isEqualToString:AVAudioSessionPortHeadphones]) return @"headphones";
    if ([type isEqualToString:AVAudioSessionPortCarAudio])   return firstSymbol(@"car.fill", @"car", kConnectSymbol);
    if ([type isEqualToString:AVAudioSessionPortHDMI] || [type isEqualToString:AVAudioSessionPortDisplayPort])
        return firstSymbol(@"tv", @"tv.fill", kConnectSymbol);
    if ([type isEqualToString:AVAudioSessionPortUSBAudio] || [type isEqualToString:AVAudioSessionPortLineOut])
        return firstSymbol(@"cable.connector", @"headphones", kConnectSymbol);
    return kConnectSymbol;
}

static void refreshRouteSymbol(void) {
    NSArray<AVAudioSessionPortDescription *> *outputs = AVAudioSession.sharedInstance.currentRoute.outputs;
    BOOL isAirPlay = NO;
    sg_routeSymbol = routeSymbolForOutputs(outputs, &isAirPlay);
    AVAudioSessionPortDescription *first = outputs.firstObject;
    sg_routePortName = first.portName;
    sg_routeIsAirPlay = isAirPlay;
    NSString *pt = first.portType;
    sg_routeIsLocalAccessory = pt && ![pt isEqualToString:AVAudioSessionPortBuiltInSpeaker] && ![pt isEqualToString:AVAudioSessionPortBuiltInReceiver];
    // The system's own name for the glyph outranks the guess from the port; the phone's own speaker keeps AirPlay's glyph.
    if (sg_appleRouteSymbol.length && sg_routeIsLocalAccessory) sg_routeSymbol = sg_appleRouteSymbol;
}

static BOOL isRemoteConnectTarget(NSString *connectName) {
    id aggregator = sg_connectAggregator;
    if (aggregator && [aggregator respondsToSelector:@selector(isPlayingRemotely)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(aggregator, @selector(isPlayingRemotely));
    }
    if (!connectName.length || sg_routeIsAirPlay || sg_routeIsLocalAccessory) return NO;
    if ([connectName localizedCaseInsensitiveCompare:@"iphone"] == NSOrderedSame ||
        [connectName localizedCaseInsensitiveCompare:@"this iphone"] == NSOrderedSame) return NO;
    if (sg_routePortName.length &&
        ([connectName localizedCaseInsensitiveCompare:sg_routePortName] == NSOrderedSame ||
         [connectName rangeOfString:sg_routePortName options:NSCaseInsensitiveSearch].location != NSNotFound ||
         [sg_routePortName rangeOfString:connectName options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        return NO;
    }
    return YES;
}

// What Connect's glyph shows: the device Spotify plays on while it is lit and elsewhere, else what the audio plays through.
static NSString *connectTargetSymbol(NSString *connectName, BOOL lit) {
    if (lit && isRemoteConnectTarget(connectName)) return connectEntitySymbol(connectName) ?: connectDeviceSymbol(connectName);
    return sg_routeSymbol ?: kConnectSymbol;
}

static void applyConnectSymbol(UIImageView *drawn, SGRGlyphView *glyph, BOOL lit, UIColor *ink, BOOL animated, BOOL forceRedraw) {
    (void)ink;
    if (!glyph) return;
    NSString *connectName = objc_getAssociatedObject(drawn, &kConnectNameKey);
    NSString *target = connectTargetSymbol(connectName, lit);
    BOOL wasLit = [objc_getAssociatedObject(drawn, &kConnectLitKey) boolValue];
    if (!forceRedraw && lit == wasLit && [glyph.symbol isEqualToString:target] && glyph.image) return;
    UIImage *symbol = routeGlyph(target, glyph.preferredSymbolConfiguration);
    if (!symbol) {
        target = kConnectSymbol;
        symbol = routeGlyph(target, glyph.preferredSymbolConfiguration);
    }
    if (!symbol) return;
    BOOL changed = ![glyph.symbol isEqualToString:target];
    UIImage *before = glyph.image;
    [glyph setSymbol:target animated:NO];   // the Kit sets a public symbol's image at once and clears the image for any other
    glyph.tintColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    if (@available(iOS 17.0, *)) {
        if (changed && animated && glyph.window && !SGRReduceMotion()) {
            glyph.image = before;
            [glyph setSymbolImage:symbol withContentTransition:[NSSymbolReplaceContentTransition transition] options:[NSSymbolEffectOptions optionsWithSpeed:2]];
            return;
        }
    }
    glyph.image = symbol;
}

static void reapplyRouteSymbols(BOOL animated) {
    for (UIImageView *drawn in sg_connectViews.allObjects) {
        SGRGlyphView *glyph = objc_getAssociatedObject(drawn, &kStandInKey);
        BOOL lit = [objc_getAssociatedObject(drawn, &kConnectLitKey) boolValue];
        applyConnectSymbol(drawn, glyph, lit, objc_getAssociatedObject(drawn, &kConnectInkKey), animated, NO);
    }
}

// The order Apple's own route buttons ask in (MediaControls' MRUNowPlayingController, outputDevicesSymbolName, in iOS 27.2; the
// Music app's MPRouteButton keeps the app's AirPlay glyph for the phone's speaker the same way): a split route, Shared Audio,
// is person.2.fill, the phone's own speaker is airplayaudio, and any other route is named from its output devices by
// MediaPlayer. A selector this iOS lacks is skipped, which leaves the last step.
static id appleRouteSymbolName(Class controller, SEL nameFor, id route) {
    SEL split = NSSelectorFromString(@"isSplitRoute"), speaker = NSSelectorFromString(@"isDeviceSpeakerRoute");
    if ([route respondsToSelector:split] && ((BOOL (*)(id, SEL))objc_msgSend)(route, split)) return kSharedAudioSymbol;
    if ([route respondsToSelector:speaker] && ((BOOL (*)(id, SEL))objc_msgSend)(route, speaker)) return kConnectSymbol;
    return ((id (*)(id, SEL, id))objc_msgSend)(controller, nameFor, route);
}

// The glyph the system draws for the active route, as the Music app's route button does. MediaPlayer names it from the route's
// output devices (MediaRemote's MRAVOutputDeviceSymbolProvider) and loads it with _systemImageNamed:, so it may be private.
// Without the two selectors, or where MediaRemote does not answer, the guess from the port stays.
static void fetchAppleRouteSymbol(void) {
    Class controller = NSClassFromString(@"MPAVRoutingController");
    SEL getRoute = NSSelectorFromString(@"getActiveRouteWithCompletion:"), nameFor = NSSelectorFromString(@"_symbolNameForRoute:");
    if (![controller respondsToSelector:getRoute] || ![controller respondsToSelector:nameFor]) return;
    NSUInteger request = ++sg_appleRouteRequest;
    void (^completion)(id) = ^(id route) {
        // Called back off the main queue; a reply to a route that has since changed is dropped.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (request != sg_appleRouteRequest) return;
            id name = route ? appleRouteSymbolName(controller, nameFor, route) : nil;
            // AirPlay's glyph is what the system answers for a device it does not know, and where the port's guess ends anyway.
            NSString *symbol = ([name isKindOfClass:NSString.class] && symbolDraws(name) && ![name isEqualToString:kConnectSymbol]) ? name : nil;
            SGLog(@"redesign player: system route glyph %@, %@", name ?: @"none", symbol ? @"used" : @"not used");
            if (symbol == sg_appleRouteSymbol || [symbol isEqualToString:sg_appleRouteSymbol]) return;
            sg_appleRouteSymbol = [symbol copy];
            refreshRouteSymbol();
            reapplyRouteSymbols(YES);
        });
    };
    ((void (*)(id, SEL, id))objc_msgSend)(controller, getRoute, completion);
}

// AVAudioSessionRouteChangeNotification may post from a background thread; queue:nil + dispatch_async
// to main avoids deadlocking at launch (AGENTS.md). The same goes for MediaPlayer's own route notification.
static void ensureRouteObserver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_connectViews = [NSHashTable weakObjectsHashTable];
        sg_routeUID = [AVAudioSession.sharedInstance.currentRoute.outputs.firstObject.UID copy];
        refreshRouteSymbol();
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note;
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *uid = AVAudioSession.sharedInstance.currentRoute.outputs.firstObject.UID;
                if (uid != sg_routeUID && ![uid isEqualToString:sg_routeUID]) {
                    sg_routeUID = [uid copy];
                    sg_appleRouteSymbol = nil;   // the last device's
                }
                refreshRouteSymbol();
                reapplyRouteSymbols(YES);
                fetchAppleRouteSymbol();
            });
        }];
        [center addObserverForName:@"MPAVRoutingControllerActiveSystemRouteDidChangeNotification" object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note;
            dispatch_async(dispatch_get_main_queue(), ^{ fetchAppleRouteSymbol(); });
        }];
        dispatch_async(dispatch_get_main_queue(), ^{ fetchAppleRouteSymbol(); });
    });
}

static UIColor *inkOf(UIImageView *view, UIImage *image) {
    if (image.isSymbolImage || image.renderingMode == UIImageRenderingModeAlwaysTemplate) return view.tintColor;
    return SGRPlayerImageInk(image) ?: SGRPrimary();
}

// Spotify's new Connect glyph: matches the left Lyrics icon in neutral translucent white (rgba(255, 255, 255, 0.65)),
// and a clear image of the same size in its place, so nothing moves.
static BOOL takeConnectImage(UIImageView *drawn) {
    UIImage *image = drawn.image;
    UIImage *clear = objc_getAssociatedObject(drawn, &kClearKey);
    if (!image.CGImage || image == clear) return NO;
    SGRGlyphView *glyph = objc_getAssociatedObject(drawn, &kStandInKey);
    UIColor *ink = inkOf(drawn, image);
    BOOL lit = SGRPlayerAccentLike(ink);
    applyConnectSymbol(drawn, glyph, lit, ink, NO, YES);
    objc_setAssociatedObject(drawn, &kConnectLitKey, @(lit), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(drawn, &kConnectInkKey, ink, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!clear || !CGSizeEqualToSize(clear.size, image.size) || clear.scale != image.scale) {
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = image.scale;
        clear = [[[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {}];
        objc_setAssociatedObject(drawn, &kClearKey, clear, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    drawn.image = clear;
    return YES;
}

// Spotify draws a new glyph when the device changes, with no layout pass of the footer to tell it, so its setImage:
// tells the stand-in; the clear image set back in reports too, and stops there. Each pass looks too, at the cost of a
// compare, for a view the image cannot be watched on.
static void standInForConnect(UIImageView *drawn, NSString *connectName) {
    if (SGRPlayerSpotifyIcons()) return;
    ensureRouteObserver();
    BOOL made = objc_getAssociatedObject(drawn, &kStandInKey) != nil;
    NSString *prevName = objc_getAssociatedObject(drawn, &kConnectNameKey);
    BOOL nameChanged = (connectName != prevName) && ![connectName isEqualToString:prevName];
    if (nameChanged) objc_setAssociatedObject(drawn, &kConnectNameKey, connectName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    SGRGlyphView *glyph = standIn(drawn, kConnectSymbol);
    if (!glyph) return;
    if (![sg_connectViews containsObject:drawn]) [sg_connectViews addObject:drawn];
    BOOL handled = takeConnectImage(drawn);
    if (!made) {
        applyConnectSymbol(drawn, glyph, [objc_getAssociatedObject(drawn, &kConnectLitKey) boolValue], objc_getAssociatedObject(drawn, &kConnectInkKey), NO, YES);
        SGRObserveImage(drawn, ^(UIImageView *view) { takeConnectImage(view); });
    } else if (!handled) {
        BOOL lit = [objc_getAssociatedObject(drawn, &kConnectLitKey) boolValue];
        UIColor *ink = objc_getAssociatedObject(drawn, &kConnectInkKey);
        applyConnectSymbol(drawn, glyph, lit, ink, nameChanged, nameChanged && lit);
    }
}


#pragma mark - the row

static UIView *connectGlyphIn(UIView *holder) {
    __block UIView *glyph = nil;
    SGForEachView(holder, ^(UIView *view) {
        if (!glyph && [view isKindOfClass:UIImageView.class] && ![view isKindOfClass:SGRGlyphView.class]
            && view.bounds.size.width > 0 && view.bounds.size.width <= kGlyphMaxWidth) glyph = view;
    });
    return glyph;
}

// Connect is Spotify's control as wide as the device's name, with the glyph near its leading edge. With the
// name hidden and the glyph in the middle, its touches would reach far past the glyph, over the queue, and
// hardly before it. So the row's view that holds it takes touches only in a square over the glyph, the size
// of the row's other two; Spotify's own views inside still handle them. The square is kept on that view, and
// its class answers from it, as it does for every other view of the class.
static char kConnectHitKey;
static NSMutableDictionary<NSString *, NSValue *> *sg_origPointInside;   // class name -> original IMP

static BOOL connectPointInside(UIView *self, SEL _cmd, CGPoint point, UIEvent *event) {
    NSValue *square = objc_getAssociatedObject(self, &kConnectHitKey);
    if (square) return CGRectContainsPoint(square.CGRectValue, point);
    // The nearest hooked class up the chain holds the original this view would have run.
    for (Class cls = self.class; cls; cls = class_getSuperclass(cls)) {
        NSValue *orig = sg_origPointInside[NSStringFromClass(cls)];
        // A subclass hooked after its parent got the parent's hook as its original; that one is skipped.
        if (orig && orig.pointerValue != (void *)connectPointInside)
            return ((BOOL (*)(UIView *, SEL, CGPoint, UIEvent *))orig.pointerValue)(self, _cmd, point, event);
    }
    return NO;
}

void SGRPlayerCoverConnect(UIView *arranged, UIView *glyph) {
    if (!arranged || !glyph) return;
    // The ordinary footer and the DJ's can hand over views of different classes; each class is hooked once.
    if (!sg_origPointInside) sg_origPointInside = [NSMutableDictionary new];
    NSString *name = NSStringFromClass(arranged.class);
    if (!sg_origPointInside[name]) {
        IMP orig = NULL;
        MSHookMessageEx(arranged.class, @selector(pointInside:withEvent:), (IMP)connectPointInside, &orig);
        sg_origPointInside[name] = [NSValue valueWithPointer:(void *)orig];
    }
    CGRect drawn = [glyph convertRect:glyph.bounds toView:arranged];
    CGRect square = CGRectMake(CGRectGetMidX(drawn) - 22, CGRectGetMidY(drawn) - 22, 44, 44);
    objc_setAssociatedObject(arranged, &kConnectHitKey, [NSValue valueWithCGRect:square], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Connect's glyph, ready to be moved: Connect laid out first, since the glyph is unsized until it is (the first time the
// player opens), and its device name hidden. The name is a MarqueeLabel on the phone's speaker and a plain Encore label
// on AirPods; Connect holds nothing else that draws text. With no glyph yet the caller leaves Connect where Spotify put
// it, and `host` looks again on the next turn of the run loop.
UIView *SGRPlayerConnectGlyphIn(UIView *host, UIView *connect) {
    [connect layoutIfNeeded];
    UIView *glyph = connectGlyphIn(connect);
    static NSUInteger lookedAgain;   // a Connect with no glyph at all is left alone after this many
    if (glyph) lookedAgain = 0;
    if (connect && !glyph && lookedAgain++ < 20) {
        __weak UIView *weakHost = host;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakHost setNeedsLayout]; });
    }
    __block NSString *connectName = nil;
    SGForEachView(connect, ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class] || SGClassNamed(view.class, @"MarqueeLabel")) {
            if (!connectName && [view respondsToSelector:@selector(text)]) {
                NSString *labelText = ((UILabel *)view).text;
                if (labelText.length > 0) connectName = labelText;
            }
            SGRPlayerVanish(view);
        }
    });
    if (!connectName && connect.accessibilityLabel.length > 0) connectName = connect.accessibilityLabel;
    if (glyph) standInForConnect((UIImageView *)glyph, connectName);
    return glyph;
}

#pragma mark - lower down

// Moved down, the row is drawn partly below the bottom stack it is arranged in, and UIKit does not look
// into a view for a touch outside its bounds. This band over the part that hangs out hands such a touch
// to the row itself, and lets every other one through.
@interface SGRFooterReach : UIView
@property (nonatomic, weak) UIView *row;
@end

@implementation SGRFooterReach
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *row = self.row;
    if (!row.window || row.alpha < 0.01 || row.hidden) return nil;
    UIView *hit = [row hitTest:[row convertPoint:point fromView:self] withEvent:event];
    return hit == row ? nil : hit;
}
@end

static UIViewController *unitOf(UIView *view) {
    UIResponder *next = view.nextResponder;
    return [next isKindOfClass:UIViewController.class] && ((UIViewController *)next).viewIfLoaded == view ? (UIViewController *)next : nil;
}

// The arranged view drawn right above `row` in its stack, by where the stack put them.
static UIView *rowAbove(UIView *row) {
    UIView *best = nil;
    CGFloat top = row.center.y - row.bounds.size.height / 2, bestBottom = -CGFLOAT_MAX;
    // The volume row lives in the same stack, between the controls and the footer: it is not what is above, or the
    // controls would be taken for something else whenever it ends within a point of the footer (the AI DJ's gap does).
    static Class volumeRow;
    if (!volumeRow) volumeRow = NSClassFromString(@"SGRVolumeRow");
    for (UIView *sibling in row.superview.subviews) {
        if (sibling == row || sibling.hidden || sibling.alpha < 0.01 || sibling.bounds.size.height < 1) continue;
        if (volumeRow && [sibling isKindOfClass:volumeRow]) continue;
        CGFloat bottom = sibling.center.y + sibling.bounds.size.height / 2;
        if (bottom <= top + 1 && bottom > bestBottom) {
            best = sibling;
            bestBottom = bottom;
        }
    }
    return best;
}

void SGRPlayerLowerRow(UIView *row) {
    UIView *stack = row.superview, *player = stack.superview;
    UIWindow *window = row.window ?: player.window;
    if (![stack isKindOfClass:UIStackView.class] || !player) return;
    sg_footerRow = row;
    BOOL queueOpen = SGRPlayerQueueOpen();
    // Where the stack put the row, the row's own transform left out, and where it belongs.
    CGFloat middle = [stack convertPoint:row.center toView:player].y;
    CGFloat height = player.bounds.size.height;
    CGFloat safeBottom = window ? window.safeAreaInsets.bottom : 34.0;
    CGFloat aboveSafe = queueOpen ? 32.0 : kRowAboveSafeArea;
    CGFloat minBottom = queueOpen ? 44.0 : kRowMinBottom;
    CGFloat target = height - MAX(safeBottom + aboveSafe, minBottom);
    CGFloat move = queueOpen ? round(target - middle) : MAX(0, round(target - middle));
    CGAffineTransform down = CGAffineTransformMakeTranslation(0, move);
    if (!CGAffineTransformEqualToTransform(row.transform, down)) row.transform = down;

    // Only the controls, and only straight above: a volume row between them keeps its place and theirs.
    UIView *above = rowAbove(row);
    // The ordinary player's controls unit, or the AI DJ's head unit (DJPlayer.x), which holds the same buttons.
    Class unit = unitOf(above).class;
    BOOL controls = SGClassNamed(unit, @"PlaybackControlsElementsUnit") || SGClassNamed(unit, @"DJMHeadUnitViewController");
    UIView *controlsView = controls ? above : nil;
    if (!controlsView) {
        for (UIView *sibling in stack.subviews) {
            Class sibUnit = unitOf(sibling).class;
            if (SGClassNamed(sibUnit, @"PlaybackControlsElementsUnit") || SGClassNamed(sibUnit, @"DJMHeadUnitViewController")) {
                controlsView = sibling;
                break;
            }
        }
    }
    BOOL volume = SGRPlayerVolumeOn() && (controls || (queueOpen && controlsView != nil));
    CGFloat share = volume ? 0 : kControlsShare, lift = volume ? kVolumeLift : 0;

    if (queueOpen && controlsView) {
        // In Queue view, center the 3-button transport row at Apple Music's y = 638.2 pt (height - (171.8 + safeBottom) on 844pt)
        CGFloat ctrlMiddle = [stack convertPoint:controlsView.center toView:player].y;
        CGFloat targetCtrlMiddle = height - (175.6 + safeBottom);
        CGAffineTransform queueFollow = CGAffineTransformMakeTranslation(0, round(targetCtrlMiddle - ctrlMiddle));
        if (!CGAffineTransformEqualToTransform(controlsView.transform, queueFollow)) controlsView.transform = queueFollow;
    } else {
        if (!controls && controlsView && !CGAffineTransformIsIdentity(controlsView.transform)) {
            controlsView.transform = CGAffineTransformIdentity;
        }
        // With the volume row, the controls stay where Spotify put them and the row takes the room the footer leaves.
        // The volume row is placed against the controls where they would stand for it; one that does not show leaves them
        // following the footer as they do without it.
        CGAffineTransform follow = CGAffineTransformMakeTranslation(0, controls ? round(move * share) - lift : 0);
        if (above && controls && !CGAffineTransformEqualToTransform(above.transform, follow)) above.transform = follow;
    }
    SGRPlayerPaintCover(stack);
    UIView *volumeAnchor = queueOpen ? (controlsView ?: above) : above;
    CGFloat vMargin = queueOpen ? 32.0 : kVolumeMargin;
    if (volume && !SGRPlayerPlaceVolume(stack, volumeAnchor, row, vMargin)) {
        if (!queueOpen) {
            share = kControlsShare;
            CGAffineTransform follow = CGAffineTransformMakeTranslation(0, round(move * share));
            if (above && controls && !CGAffineTransformEqualToTransform(above.transform, follow)) above.transform = follow;
        }
    } else if (!volume) {
        SGRPlayerPlaceVolume(stack, nil, row, vMargin);
    }

    SGRFooterReach *reach = objc_getAssociatedObject(row, &kReachKey);
    if (!reach) {
        reach = [SGRFooterReach new];
        reach.row = row;
        objc_setAssociatedObject(row, &kReachKey, reach, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (reach.superview != player) [player addSubview:reach];
    CGRect stackFrame = [stack convertRect:stack.bounds toView:player];
    CGRect drawn = [row convertRect:row.bounds toView:player];
    CGFloat from = CGRectGetMaxY(stackFrame);
    CGRect band = CGRectMake(CGRectGetMinX(drawn), from, drawn.size.width, MAX(0, CGRectGetMaxY(drawn) - from));
    if (!CGRectEqualToRect(reach.frame, band)) reach.frame = band;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"redesign player: footer row from %.0f to %.0f of %.0f (safe area %.0f), controls %@ %.0f, volume %@", middle, middle + move, height,
              window.safeAreaInsets.bottom, controls ? @"follow" : @"stay", controls ? round(move * share) : 0, SGRPlayerVolumeOn() ? @"on" : @"off");
    });
}

%hook _TtC20NowPlaying_ModesImpl18FooterElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *host = ((UIViewController *)self).viewIfLoaded;
    if (!host) return;
    // The unit lays out before its row does, and the moves are measured from where the row put things.
    [SGFindRemembered(host, &kRowKey, ^BOOL(UIView *v) { return SGIsRow(v); }) layoutIfNeeded];
    CGFloat width = host.bounds.size.width, middleY = CGRectGetMidY(host.bounds);
    BOOL rtl = host.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;

    // Share; Spotify's clip button, hidden in every clean tree, which would turn up where the queue moves to; and
    // "From <friend>" on a track a friend shared, which sits in the middle of the row, over Connect, which the row
    // moves there (the Music app has no such chip). Found in one walk: nothing between them touches the tree.
    static const void *const goneKeys[] = {&kShareKey, &kTrimmerKey, &kSharedByKey};
    UIView *gone[3];
    static NSArray<NSString *> *goneIdentifiers;
    if (!goneIdentifiers) goneIdentifiers = @[@"ShareButtonNowPlayingView", @"nowplaying-npv-media-trimmer-navigation-button", @"Components.UI.SharedByChip"];
    SGRFindByIdentifiers(host, goneIdentifiers, goneKeys, gone);
    UIView *share = gone[0];
    for (NSUInteger i = 0; i < 3; i++) {
        SGRPlayerVanish(gone[i]);
        // The arranged view goes too: a view that takes touches swallows them even with nothing on it.
        SGRPlayerVanish(arrangedAround(gone[i], host));
    }

    SGRGlyphButton *lyrics = SGRPlayerLyricsGlyphIn(host);
    lyrics.bounds = CGRectMake(0, 0, 44, 44);
    lyrics.center = CGPointMake(round(width * (rtl ? kTrailing : kLeading)), middleY);
    SGRPlayerLyricsChanged();

    UIView *connect = SGRFindByIdentifier(host, @"Components.ConnectButtonOutputSwitcher", &kConnectKey);
    UIView *glyph = SGRPlayerConnectGlyphIn(host, connect);
    CGFloat connectFrom = glyph ? SGRPlayerTranslateArranged(arrangedAround(connect, host), glyph, CGPointMake(CGRectGetMidX(glyph.bounds), CGRectGetMidY(glyph.bounds)), host, round(width * kMiddle)) : -1;

    UIView *queue = SGRFindByIdentifier(host, @"QueueButtonNowPlaying", &kQueueKey);
    SGRPlayerVanish(queue);
    SGRPlayerVanish(arrangedAround(queue, host));

    SGRGlyphButton *queueButton = SGRPlayerQueueGlyphIn(host);
    queueButton.bounds = CGRectMake(0, 0, 38, 38);
    queueButton.center = CGPointMake(round(width * (rtl ? kLeading : kTrailing)), middleY);
    if (SGRPlayerSpotifyIcons()) {
        SGRPlayerEncoreGlyphIn(queueButton, @"queue").transform = CGAffineTransformMakeScale(0.85, 0.85);
    }
    SGRPlayerQueueChanged();

    SGRPlayerLowerRow(host);
    SGRPlayerCoverConnect(arrangedAround(connect, host), glyph);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"redesign player: footer lyrics at %.0f, connect %.0f (%@) to %.0f, queue %.0f to %.0f, share %@", lyrics.center.x,
              connectFrom, glyph ? @"glyph" : @"button", round(width * kMiddle), queueButton.center.x, round(width * (rtl ? kLeading : kTrailing)), share ? @"gone" : @"not found");
    });
}
%end

// The Connect button lays itself out again when the device changes (its name comes or goes, another device's glyph,
// the button's width with them),
// with no pass of the footer around it: the glyph moved inside it while the footer's transform, worked out from where
// the glyph was, stayed, so Connect slid off its place (the phone, 2026-10-24: switched to another device from
// elsewhere, the DJ footer's Connect 11pt left of its slot). The footer is laid out again whenever the glyph moves, and
// its pass puts the button back on its place, the ordinary player's and the DJ's alike.
static char kGlyphSeenKey;

%hook _TtC23Connect_EntryPointsImpl37ConnectButtonOutputSwitcherViewHolder
- (void)layoutSubviews {
    %orig;
    UIView *connect = (UIView *)self;
    UIView *glyph = connectGlyphIn(connect);
    if (!glyph) return;
    // The glyph's place in the button and the button's size: the glyph keeps its place at the button's leading edge while
    // the button grows and shrinks with the device's name (101.5pt with "iPhone", 51 without, the phone, 2026-10-24), and
    // the element holding it is laid out again round its new size, so either one moving is a move of the glyph.
    CGRect seen = [glyph convertRect:glyph.bounds toView:connect];
    seen.size = connect.bounds.size;
    NSValue *was = objc_getAssociatedObject(connect, &kGlyphSeenKey);
    if (was && CGRectEqualToRect(was.CGRectValue, seen)) return;
    objc_setAssociatedObject(connect, &kGlyphSeenKey, [NSValue valueWithCGRect:seen], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!was) return;
    // The footer unit's view: the first ancestor a controller owns.
    for (UIView *v = connect.superview; v; v = v.superview) {
        if (!unitOf(v)) continue;
        [v setNeedsLayout];
        break;
    }
}
%end

%group VolumeSlider
%hook UISlider
- (void)setValue:(float)value animated:(BOOL)animated {
    %orig;
    SGRPlayerVolumeSliderSet(self);
}
%end

%hook _TtC18Connect_VolumeImpl17VolumeServiceImpl
- (id)provideVolumeImpl {
    id volume = %orig;
    SGRPlayerConnectVolumeProvided(volume);
    return volume;
}
%end

%hook _TtC18Connect_VolumeImpl10VolumeImpl
- (void)add:(id)observer {
    %orig;
    SGRPlayerConnectVolumeProvided(self);
}
%end

%hook _TtC22Connect_AggregatorImpl24ConnectAggregatorService
- (id)provideConnectAggregatorLegacyAPI {
    id aggregator = %orig;
    sg_connectAggregator = aggregator;
    SGRPlayerConnectAggregatorProvided(aggregator);
    return aggregator;
}
%end

%hook _TtC18Connect_VolumeImpl21AggregatorEventSource
- (void)aggregator:(id)aggregator didUpdateActiveConnectEntity:(id)entity {
    %orig;
    SGRPlayerConnectEntityChanged(aggregator, entity);
}
%end

%hook _TtC20Connect_VolumeUXImpl21VolumeUXPresenterImpl
- (void)systemVolumeChangedTo:(double)volume {
    if (SGRPlayerConnectVolumeActive()) return;
    %orig;
}
%end

%hook _TtC20Connect_VolumeUXImpl28SmartControlVolumeController
- (void)systemVolumeChangedTo:(double)volume {
    if (SGRPlayerConnectVolumeActive()) return;
    %orig;
}
%end

%hook _TtC20Connect_VolumeUXImpl27RemoteVolumePopupController
- (void)remoteMediaSessionVolumeDidChangeToValue:(double)volume {
    if (SGRPlayerConnectVolumeActive()) return;
    %orig;
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    if (SGRPlayerVolumeOn()) {
        %init(VolumeSlider);
        SGRPlayerConnectVolumeInit();
        SGRequireClasses(@[
            @"_TtC18Connect_VolumeImpl10VolumeImpl",
            @"_TtC18Connect_VolumeImpl17VolumeServiceImpl",
            @"_TtC18Connect_VolumeImpl21AggregatorEventSource",
            @"_TtC20Connect_VolumeUXImpl21VolumeUXPresenterImpl",
            @"_TtC20Connect_VolumeUXImpl27RemoteVolumePopupController",
            @"_TtC20Connect_VolumeUXImpl28SmartControlVolumeController",
            @"_TtC22Connect_AggregatorImpl24ConnectAggregatorService",
        ]);
    }
    SGRequireClasses(@[@"_TtC20NowPlaying_ModesImpl18FooterElementsUnit"]);
}

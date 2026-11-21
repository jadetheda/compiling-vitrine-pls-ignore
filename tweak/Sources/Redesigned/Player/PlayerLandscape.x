// Player redesign: the lyrics or the queue turn sideways with the phone onto a landscape screen of their own.
// When Lyrics are open, the cover is on the left with the title, the artist and the controls under it, and the
// lines are on the right. When the Queue is open, the 291x291 cover sits on the left with a top-center grabber
// pill above, the full interactive SGRQueueView (History, Now Playing, 4-Pill Bar, Queue, Continue Playing) on
// the right, and the 3-glyph footer row (Lyrics, AirPlay/Connect, Active Queue circle) at the bottom right.
//
// Spotify's iPhone Info.plist allows portrait only, and UIKit asks the app delegate's
// -application:supportedInterfaceOrientationsForWindow: in its place where there is one. So the delegate
// answers landscape for this screen's own window and portrait for every other, and the scene is asked to
// turn while the window is up. Spotify's own windows never turn.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Lyrics/SGRKaraokeView.h"
#import "Redesigned/Player/SGRQueueView.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Player.h"

static const CGFloat kSide = 32, kCoverGap = 16, kControlSide = 44, kColumnShare = 0.38;
// The title and the controls beside the cover of a track without lines.
static const CGFloat kBareInfoWidth = 300, kBareControlsWidth = 200;
static const NSTimeInterval kLandscapeRest = 4;

static UIWindow *sg_window;
// Shut from the screen: turning the phone again does not reopen it until it has stood upright.
static BOOL sg_shut;

static BOOL shouldShowLandscapeForCurrentState(void) {
    if (SGRPlayerQueueOpen() && SGEnabled(SGRKeyQueueLandscape)) return YES;
    if (SGRPlayerLyricsOpen() && SGEnabled(SGRKeyLyricsLandscape)) return YES;
    return NO;
}

#pragma mark - the screen

@interface SGRLandscapeLyricsController : UIViewController <SGPlayerStateObserver>
@property (nonatomic, assign) BOOL closingToPortrait;
- (void)updateMode;
- (void)updateBare:(BOOL)mayGoBare;
- (CGFloat)currentQueueScrollOffset;
@end

@implementation SGRLandscapeLyricsController {
    SGRArtworkField *_field;
    SGRShadowPlate *_coverShadow;
    UIImageView *_cover;
    SGMarqueeLabel *_title, *_artist;
    UIStackView *_controls;
    UIButton *_play, *_close;
    UIView *_stage;   // the lines' own view: the karaoke view dims every sibling it has
    SGRKaraokeView *_lyrics;

    // Landscape Queue components (Apple Music 844x390 layout)
    UIView *_queueGrabberPill;
    SGRQueueView *_queueView;
    UIView *_portraitTransportSnapshot;
    SGRGlyphButton *_queueFooterLyricsButton;
    SGRGlyphButton *_queueFooterConnectButton;
    SGRGlyphButton *_queueFooterQueueButton;
    SGRGlyphButton *_queueFooterDJButton;
    UIButton *_djControl;
    BOOL _showingQueue;
    BOOL _queueNeedsInitialOffset;

    NSTimer *_rest;
    UITapGestureRecognizer *_hide;   // only while the controls are up
    UIView *_shield;                 // only while they are not: the touch that brings them back
    BOOL _bare;                      // the track playing has no lines: the cover takes the screen
}

// Portrait once the screen is on its way out, or the scene could not turn back while it fades.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return sg_window.rootViewController == self ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskPortrait;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

// A glyph in a 44pt square, so the touch is as large as the default control whatever the glyph's size.
static UIButton *controlButton(NSString *symbol, CGFloat size, NSString *label, SEL action, id target) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = label;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:kControlSide].active = YES;
    [button.heightAnchor constraintEqualToConstant:kControlSide].active = YES;
    return button;
}

// The title and the artist at the phone's text size, capped where the column still holds a cover.
- (void)applyFonts {
    _title.font = SGRFont(UIFontTextStyleTitle3, UIFontWeightBold, UIContentSizeCategoryExtraExtraExtraLarge);
    _artist.font = SGRFont(UIFontTextStyleCallout, UIFontWeightRegular, UIContentSizeCategoryExtraExtraExtraLarge);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self applyFonts];
    [self.view setNeedsLayout];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _showingQueue = SGRPlayerQueueOpen() && SGEnabled(SGRKeyQueueLandscape);

    // The player's own field behind the screen, so the colors carry over from the portrait player.
    _field = [[SGRArtworkField alloc] initWithFrame:self.view.bounds];
    _field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _field.showsBackdrop = YES;
    _field.fluid = YES;
    NSString *identity = nil;
    UIImage *art = SGRNowPlayingArtwork(NULL, &identity);
    if (art) [_field setArtwork:art identity:identity animated:NO];
    [self.view addSubview:_field];

    _coverShadow = [SGRShadowPlate new];
    _coverShadow.cornerRadius = _showingQueue ? 10.0 : SGRRadiusArtwork;
    [self.view addSubview:_coverShadow];

    _cover = [UIImageView new];
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    _cover.clipsToBounds = YES;
    _cover.layer.cornerRadius = _showingQueue ? 10.0 : SGRRadiusArtwork;
    _cover.layer.cornerCurve = kCACornerCurveContinuous;
    _cover.image = art;
    [self.view addSubview:_cover];

    // A title or artist too long for the column scrolls, as the player's own do.
    _title = [SGMarqueeLabel new];
    _title.textColor = UIColor.whiteColor;
    _artist = [SGMarqueeLabel new];
    _artist.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    [self applyFonts];
    [self.view addSubview:_title];
    [self.view addSubview:_artist];
    // Where the Music app keeps a song's ⋯: the way back to the player, for a phone that is not turned back.
    _close = controlButton(@"arrow.down.right.and.arrow.up.left", 17, @"Exit full screen", @selector(turnBack), self);
    [self.view addSubview:_close];

    _play = controlButton(@"pause.fill", 30, @"Pause", @selector(togglePlay), self);
    _djControl = controlButton(@"waveform", 20, @"DJ", @selector(triggerDJ), self);
    _djControl.tintColor = SGRPrimary();
    _djControl.hidden = YES;
    _controls = [[UIStackView alloc] initWithArrangedSubviews:@[
        controlButton(@"backward.fill", 24, @"Previous track", @selector(previous), self), _play,
        controlButton(@"forward.fill", 24, @"Next track", @selector(next), self), _djControl,
    ]];
    _controls.distribution = UIStackViewDistributionEqualSpacing;
    _controls.alignment = UIStackViewAlignmentCenter;
    [self.view addSubview:_controls];

    _stage = [UIView new];
    [self.view addSubview:_stage];
    _lyrics = [[SGRKaraokeView alloc] initWithFrame:CGRectZero];
    _lyrics.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_stage addSubview:_lyrics];
    __weak SGRLandscapeLyricsController *weakSelf = self;
    _lyrics.browsingBegan = ^(BOOL onward) { [weakSelf rest]; };

    // Top-center 60x4pt grabber pill for Landscape Queue (x = 392..452pt, y = 15..19pt on 844x390pt)
    _queueGrabberPill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 60.0, 4.0)];
    _queueGrabberPill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
    _queueGrabberPill.layer.cornerRadius = 2.0;
    _queueGrabberPill.layer.compositingFilter = @"plusL";
    _queueGrabberPill.userInteractionEnabled = NO;
    [self.view addSubview:_queueGrabberPill];

    // Right-column Queue view in landscapeMode
    _queueView = [[SGRQueueView alloc] initWithFrame:CGRectZero];
    _queueView.landscapeMode = YES;
    [_queueView prepareForOpenTransition];
    _queueView.currentScrollOffset = SGRPlayerQueueScrollOffset();
    [self.view addSubview:_queueView];

    [self refreshPortraitTransportSnapshot];
    [self.view bringSubviewToFront:_coverShadow];
    [self.view bringSubviewToFront:_cover];
    [self.view bringSubviewToFront:_queueGrabberPill];

    // Right-column 3-glyph footer row matching Apple Music Landscape Queue (Lyrics at x=433.5, AirPlay at x=599.0, Queue at x=764.0, y=328.83)
    _queueFooterLyricsButton = [SGRGlyphButton buttonWithSymbol:@"quote.bubble" pointSize:20.0 title:@"Lyrics"];
    _queueFooterLyricsButton.bounds = CGRectMake(0, 0, 44.0, 44.0);
    _queueFooterLyricsButton.glyph.tintColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    _queueFooterLyricsButton.onTap = ^{
        if (!SGRPlayerLyricsAvailable()) return;
        SGRPlayerToggleLyrics();
        [weakSelf updateMode];
    };
    [self.view addSubview:_queueFooterLyricsButton];

    _queueFooterConnectButton = [SGRGlyphButton buttonWithSymbol:@"airplayaudio" pointSize:20.0 title:@"Connect"];
    _queueFooterConnectButton.bounds = CGRectMake(0, 0, 44.0, 44.0);
    _queueFooterConnectButton.glyph.tintColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    _queueFooterConnectButton.onTap = ^{
        SGRPlayerTriggerConnect();
    };
    [self.view addSubview:_queueFooterConnectButton];

    _queueFooterQueueButton = [SGRGlyphButton buttonWithSymbol:@"list.bullet" pointSize:20.0 title:@"Queue"];
    _queueFooterQueueButton.bounds = CGRectMake(0, 0, 38.0, 38.0);
    _queueFooterQueueButton.opaque = NO;
    _queueFooterQueueButton.layer.opaque = NO;
    _queueFooterQueueButton.glyph.opaque = NO;
    _queueFooterQueueButton.glyph.layer.opaque = NO;
    _queueFooterQueueButton.glyph.image = SGRPlayerQueueActiveIcon(CGSizeMake(38.0, 38.0));
    _queueFooterQueueButton.glyph.tintColor = nil;
    _queueFooterQueueButton.backgroundColor = UIColor.clearColor;
    _queueFooterQueueButton.layer.cornerRadius = 19.0;
    _queueFooterQueueButton.layer.cornerCurve = kCACornerCurveContinuous;
    _queueFooterQueueButton.clipsToBounds = YES;
    _queueFooterQueueButton.onTap = ^{
        if (SGRPlayerQueueOpen()) SGRPlayerToggleQueue();
        [weakSelf turnBack];
    };
    [self.view addSubview:_queueFooterQueueButton];

    _queueFooterDJButton = [SGRGlyphButton buttonWithSymbol:@"waveform" pointSize:20.0 title:@"DJ"];
    _queueFooterDJButton.bounds = CGRectMake(0, 0, 44.0, 44.0);
    _queueFooterDJButton.glyph.tintColor = SGRPrimary();
    _queueFooterDJButton.onTap = ^{
        SGRPlayerTriggerDJ();
    };
    [self.view addSubview:_queueFooterDJButton];

    _queueNeedsInitialOffset = YES;

    _hide = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rest)];
    [self.view addGestureRecognizer:_hide];
    _shield = [[UIView alloc] initWithFrame:self.view.bounds];
    _shield.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _shield.accessibilityElementsHidden = YES;
    [_shield addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(wake)]];
    [_shield addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(wake)]];

    [self applyModeVisibility];
    if (!_showingQueue) [self updateBare:YES];
    SGAddPlayerStateObserver(self);
    [self playerStateDidChange:SGPlayerState()];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(artworkChanged)
                                               name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    // The shield is hidden from VoiceOver, so turning it on brings the controls back and keeps them.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(wake)
                                               name:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_rest invalidate];
}

- (void)syncQueueFooterLyricsButtonState {
    BOOL avail = SGRPlayerLyricsAvailable();
    _queueFooterLyricsButton.enabled = avail;
    _queueFooterLyricsButton.alpha = avail ? 1.0 : 0.40;
}

- (void)refreshPortraitTransportSnapshot {
    [_portraitTransportSnapshot removeFromSuperview];
    _portraitTransportSnapshot = nil;
    if (!_showingQueue) return;
    UIView *snap = SGRPlayerSnapshotQueueTransport();
    if (snap) {
        snap.userInteractionEnabled = NO;
        _portraitTransportSnapshot = snap;
        [self.view insertSubview:snap aboveSubview:_queueView];
    }
}

- (void)applyModeVisibility {
    BOOL queueMode = _showingQueue;
    BOOL djAvail = SGRPlayerDJAvailable();
    _queueGrabberPill.hidden = !queueMode;
    _queueView.hidden = !queueMode;
    _portraitTransportSnapshot.hidden = !queueMode;
    _queueFooterLyricsButton.hidden = !queueMode;
    _queueFooterConnectButton.hidden = !queueMode;
    _queueFooterQueueButton.hidden = !queueMode;
    _queueFooterDJButton.hidden = !queueMode || !djAvail;
    [self syncQueueFooterLyricsButtonState];

    _title.hidden = queueMode;
    _artist.hidden = queueMode;
    _close.hidden = queueMode;
    _controls.hidden = queueMode;
    _djControl.hidden = queueMode || !djAvail;
    _stage.hidden = queueMode || _bare;
    _hide.enabled = !queueMode && !_shield.superview;
    if (queueMode && _shield.superview) [_shield removeFromSuperview];
    _cover.layer.cornerRadius = queueMode ? 10.0 : SGRRadiusArtwork;
    _coverShadow.cornerRadius = _cover.layer.cornerRadius;
}

- (void)updateMode {
    if (!shouldShowLandscapeForCurrentState()) {
        [self turnBack];
        return;
    }
    BOOL wantQueue = SGRPlayerQueueOpen() && SGEnabled(SGRKeyQueueLandscape);
    if (wantQueue == _showingQueue) {
        [self syncQueueFooterLyricsButtonState];
        return;
    }
    _showingQueue = wantQueue;
    if (_showingQueue) {
        CGFloat offset = SGRPlayerQueueScrollOffset();
        [_rest invalidate];
        _rest = nil;
        [_queueView prepareForOpenTransition];
        _queueView.currentScrollOffset = offset;
        _queueNeedsInitialOffset = YES;
    }
    [self applyModeVisibility];
    if (!_showingQueue) {
        [self updateBare:YES];
        [self restartRest];
    }
    [self.view setNeedsLayout];
}

- (CGFloat)currentQueueScrollOffset {
    return _queueView ? _queueView.currentScrollOffset : 0.0;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize boundsSize = self.view.bounds.size;
    CGFloat W = boundsSize.width;
    CGFloat H = boundsSize.height;

    if (_showingQueue) {
        if (W <= H) {
            // Portrait transitional geometry (when rotating into or out of Landscape):
            // Matches the portrait Queue layout 1:1 (466pt stage above the transport controls, single morphing cover).
            CGFloat safeBottom = self.view.safeAreaInsets.bottom > 0.0 ? self.view.safeAreaInsets.bottom : (H >= 800.0 ? 34.0 : 0.0);
            CGFloat stageBottom = H - (264.0 + safeBottom) + 3.0; // 546.0 pt on 844 pt screen
            _queueView.landscapeMode = NO;
            _queueView.frame = CGRectMake(0.0, 54.0, W, MAX(200.0, stageBottom - 54.0));
            [_queueView layoutIfNeeded];

            CGFloat scrollY = [self currentQueueScrollOffset];
            CGRect artFrame = CGRectMake(32.0, 80.0 - scrollY, 72.0, 72.0);
            BOOL npVisible = (scrollY <= 4.0 && CGRectGetMinY(artFrame) >= 76.0 && CGRectGetMaxY(artFrame) <= stageBottom - 8.0);
            [_queueView setTransitionArtworkHidden:npVisible];

            _queueGrabberPill.bounds = CGRectMake(0.0, 0.0, 60.0, 4.0);
            _queueGrabberPill.center = CGPointMake(W * 0.5, 56.0);
            _queueGrabberPill.alpha = 0.0;
            _cover.frame = npVisible ? artFrame : CGRectMake(32.0, 80.0, 72.0, 72.0);
            _cover.layer.cornerRadius = 11.0;
            _coverShadow.frame = _cover.frame;
            _coverShadow.cornerRadius = 11.0;
            _cover.alpha = npVisible ? 1.0 : 0.0;
            _coverShadow.alpha = 0.0;

            if (_portraitTransportSnapshot) {
                _portraitTransportSnapshot.frame = CGRectMake(0.0, 0.0, W, H);
                _portraitTransportSnapshot.alpha = 1.0;
            }
            CGFloat footerY = H - MAX(safeBottom + 32.0, 44.0); // 778.0 pt on 844 pt screen
            BOOL djAvail = SGRPlayerDJAvailable();
            _queueFooterDJButton.hidden = !djAvail;
            if (djAvail) {
                _queueFooterLyricsButton.center  = CGPointMake(round(W * 0.20), footerY);
                _queueFooterConnectButton.center = CGPointMake(round(W * 0.40), footerY);
                _queueFooterQueueButton.center   = CGPointMake(round(W * 0.60), footerY);
                _queueFooterDJButton.center      = CGPointMake(round(W * 0.80), footerY);
            } else {
                _queueFooterLyricsButton.center  = CGPointMake(round(W * 0.207), footerY);
                _queueFooterConnectButton.center = CGPointMake(round(W * 0.500), footerY);
                _queueFooterQueueButton.center   = CGPointMake(round(W * 0.793), footerY);
            }
            return;
        }

        // Apple Music Landscape Queue layout (measured 1:1 on 844x390 pt):
        _queueView.landscapeMode = YES;
        [_queueView setTransitionArtworkHidden:NO];
        if (_portraitTransportSnapshot) {
            _portraitTransportSnapshot.alpha = 0.0;
        }
        _queueGrabberPill.alpha = 1.0;
        _cover.alpha = 1.0;
        _coverShadow.alpha = 1.0;
        _cover.layer.cornerRadius = 10.0;
        _coverShadow.cornerRadius = 10.0;

        // - Top grabber pill: 60x4 pt at cx = W * 0.5 (422.0 pt), y = 15..19 pt (center.y = 17.0 pt)
        _queueGrabberPill.bounds = CGRectMake(0.0, 0.0, 60.0, 4.0);
        _queueGrabberPill.center = CGPointMake(W * 0.5, 17.0);

        // - Left artwork: 291x291 pt at x = 79.0 pt, y = 49.5 pt on 844x390 pt
        CGFloat coverSide = round(H * (291.0 / 390.0));
        CGFloat coverX = round(W * (79.0 / 844.0));
        CGFloat coverY = round((H - coverSide) * 0.5);
        _cover.frame = CGRectMake(coverX, coverY, coverSide, coverSide);
        _coverShadow.frame = _cover.frame;

        // - Right column SGRQueueView: content spans x = 415..783 pt (width 368 pt);
        //   with kSideMargin = 32 pt inside SGRQueueView, frame is x = 383.0 pt, width = 432.0 pt
        CGFloat innerLeft = round(W * (415.0 / 844.0));
        CGFloat innerWidth = round(W * (368.0 / 844.0));
        CGFloat queueX = innerLeft - 32.0;
        CGFloat queueW = innerWidth + 64.0;
        _queueView.frame = CGRectMake(queueX, 0.0, queueW, H);
        [_queueView layoutIfNeeded];
        if (_queueNeedsInitialOffset) {
            _queueNeedsInitialOffset = NO;
            _queueView.currentScrollOffset = SGRPlayerQueueScrollOffset();
        }

        // - Bottom-right 3- or 4-glyph footer row at y = H - 61.17 pt (328.83 pt on 390 pt height)
        CGFloat footerCenterY = H - 61.17;
        BOOL djAvail = SGRPlayerDJAvailable();
        _queueFooterDJButton.hidden = !djAvail;
        if (djAvail) {
            CGFloat b0 = innerLeft + 18.5;
            CGFloat b3 = innerLeft + innerWidth - 19.0;
            CGFloat step = (b3 - b0) / 3.0;
            _queueFooterLyricsButton.center  = CGPointMake(round(b0), footerCenterY);
            _queueFooterConnectButton.center = CGPointMake(round(b0 + step), footerCenterY);
            _queueFooterQueueButton.center   = CGPointMake(round(b0 + 2.0 * step), footerCenterY);
            _queueFooterDJButton.center      = CGPointMake(round(b3), footerCenterY);
        } else {
            _queueFooterLyricsButton.center  = CGPointMake(innerLeft + 18.5, footerCenterY);
            _queueFooterConnectButton.center = CGPointMake(innerLeft + innerWidth * 0.5, footerCenterY);
            _queueFooterQueueButton.center   = CGPointMake(innerLeft + innerWidth - 19.0, footerCenterY);
        }
        return;
    }

    BOOL djAvail = SGRPlayerDJAvailable();
    _djControl.hidden = !djAvail;

    _cover.alpha = 1.0;
    _coverShadow.alpha = 1.0;
    CGRect safe = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    CGFloat column = round(safe.size.width * kColumnShare);
    CGFloat left = CGRectGetMinX(safe) + kSide;
    CGFloat titleHeight = ceil(_title.font.lineHeight), artistHeight = ceil(_artist.font.lineHeight);
    CGFloat textHeight = MAX(titleHeight + artistHeight, kControlSide), controlsHeight = kControlSide;
    CGFloat side = MIN(column - kSide, safe.size.height - 2 * kSide - textHeight - controlsHeight - 2 * kCoverGap);
    CGFloat top = CGRectGetMidY(safe) - (side + kCoverGap + textHeight + kCoverGap + controlsHeight) / 2;
    _cover.frame = CGRectMake(left, top, side, side);
    _coverShadow.frame = _cover.frame;
    // The close button at the text's trailing end, its glyph (about 20pt in the 44pt square) at the cover's edge.
    CGFloat textTop = CGRectGetMaxY(_cover.frame) + kCoverGap;
    _close.frame = CGRectMake(left + side - kControlSide + 12, textTop + (textHeight - kControlSide) / 2, kControlSide, kControlSide);
    _title.frame = CGRectMake(left, textTop + (textHeight - titleHeight - artistHeight) / 2, side - kControlSide, titleHeight);
    _artist.frame = CGRectMake(left, CGRectGetMaxY(_title.frame), side - kControlSide, artistHeight);
    _controls.frame = CGRectMake(left + side * 0.1, textTop + textHeight + kCoverGap, side * 0.8, controlsHeight);
    CGFloat linesLeft = left + side + kSide;
    _stage.frame = CGRectMake(linesLeft, CGRectGetMinY(safe), CGRectGetMaxX(safe) - linesLeft, safe.size.height);
    _lyrics.frame = _stage.bounds;
    if (!_bare) return;

    // The cover at the screen's height and the title and controls beside it, the two centered as one. The
    // lines keep their place above, so they come back from where they will stand.
    side = safe.size.height - 2 * kSide;
    CGFloat info = MIN(kBareInfoWidth, safe.size.width - 3 * kSide - side);
    CGFloat x = CGRectGetMidX(safe) - (side + kSide + info) / 2;
    _cover.frame = CGRectMake(x, CGRectGetMidY(safe) - side / 2, side, side);
    _coverShadow.frame = _cover.frame;
    CGFloat infoLeft = x + side + kSide;
    textTop = CGRectGetMidY(safe) - (textHeight + kCoverGap + controlsHeight) / 2;
    _close.frame = CGRectMake(infoLeft + info - kControlSide + 12, textTop + (textHeight - kControlSide) / 2, kControlSide, kControlSide);
    _title.frame = CGRectMake(infoLeft, textTop + (textHeight - titleHeight - artistHeight) / 2, info - kControlSide, titleHeight);
    _artist.frame = CGRectMake(infoLeft, CGRectGetMaxY(_title.frame), info - kControlSide, artistHeight);
    _controls.frame = CGRectMake(infoLeft, textTop + textHeight + kCoverGap, MIN(kBareControlsWidth, info), controlsHeight);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_showingQueue) [self restartRest];
}

// Keeps the landscape window opaque throughout the 90-degree turn in both directions so the stationary
// portrait player underneath is never seen cross-fading at a different angle mid-rotation.
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    UIWindow *window = self.view.window;
    if (!window) return;
    if (size.width > size.height && window == sg_window) {
        window.alpha = 1.0;
        [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            window.alpha = 1.0;
            [self.view setNeedsLayout];
            [self.view layoutIfNeeded];
        } completion:nil];
    } else if (size.width < size.height && self.closingToPortrait) {
        [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            window.alpha = 1.0;
            [self.view setNeedsLayout];
            [self.view layoutIfNeeded];
        } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            [UIView animateWithDuration:0.10 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                window.alpha = 0.0;
            } completion:^(BOOL finished) {
                window.hidden = YES;
            }];
        }];
    }
}

- (void)artworkChanged {
    NSString *identity = nil;
    UIImage *art = SGRNowPlayingArtwork(NULL, &identity);
    if (!art) return;
    // On the field's clock, so the cover and the colors behind it change as one.
    UIImageView *cover = _cover;
    [UIView transitionWithView:cover duration:SGRCrossfade options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ cover.image = art; } completion:nil];
    [_field setArtwork:art identity:identity animated:YES];
}

// Lines in: the lines' layout at once. None (the player's own verdict, after its grace): the cover's.
// Otherwise the layout stays, so a track change does not flash between the two. A track change alone never
// takes the lines away: the player may not have heard of it yet, and would still count the last one's grace.
- (void)updateBare:(BOOL)mayGoBare {
    if (_showingQueue) return;
    BOOL bare = _bare;
    if (SGRPlayerLyricsAvailable()) bare = NO;
    else if (mayGoBare && SGRPlayerLyricsNone()) bare = YES;
    if (bare == _bare) return;
    _bare = bare;
    SGLog(@"redesign player: landscape %@", bare ? @"without lines, the cover takes the screen" : @"with lines");
    // The lines leave the window while they are away, so their display link stops with them.
    if (!bare) [self.view insertSubview:_stage aboveSubview:_controls];
    UIView *stage = _stage;
    void (^change)(void) = ^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        stage.alpha = bare ? 0 : 1;
    };
    void (^done)(BOOL) = ^(BOOL finished) {
        if (self->_bare) [stage removeFromSuperview];
    };
    if (self.view.window) SGRAnimateLayout(self.view, change, done);
    else {
        change();
        done(YES);
    }
    // Without lines there is nothing to read past the controls, so they stay.
    if (bare) [self wake];
    else [self restartRest];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (!state) return;
    if (_showingQueue) {
        [_queueView updateWithState:state];
        [self syncQueueFooterLyricsButtonState];
        [self applyModeVisibility];
    } else {
        [self updateBare:NO];
        [self applyModeVisibility];
    }
    _title.text = state.track.trackTitle;
    _artist.text = state.track.artistName;
    [_play setImage:[UIImage systemImageNamed:state.isPaused ? @"play.fill" : @"pause.fill" withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    _play.accessibilityLabel = state.isPaused ? @"Play" : @"Pause";
    _field.motionHeld = state.isPaused;
    // A pause brings the controls back and keeps them; playing again, from here or anywhere, starts the
    // clock. The tap on the play button cannot: the state saying so arrives a beat after it.
    if (!_showingQueue) {
        if (state.isPaused) [self setControlsShown:YES];
        else if (!_rest && !_shield.superview) [self restartRest];
    }
}

#pragma mark - controls

- (id<SPTPlayer>)player {
    id player = SGKaraokePlayer();
    return [player conformsToProtocol:@protocol(SPTPlayer)] || [player respondsToSelector:@selector(pause:)] ? player : nil;
}

- (void)togglePlay {
    id<SPTPlayer> player = self.player;
    if (SGPlayerState().isPaused) [player resume:nil];
    else [player pause:nil];
    [self restartRest];
}

- (void)previous {
    [self.player skipToPreviousTrackWithOptions:nil];
    [self restartRest];
}

- (void)next {
    [self.player skipToNextTrackWithOptions:nil];
    [self restartRest];
}

- (void)triggerDJ {
    SGRPlayerTriggerDJ();
    [self restartRest];
}

- (void)turnBack {
    sg_shut = YES;
    SGRPlayerShowLandscape(NO);
}

// VoiceOver's two-finger scrub.
- (BOOL)accessibilityPerformEscape {
    [self turnBack];
    return YES;
}

// The lines on their own, unless VoiceOver needs the controls to be there.
- (void)rest {
    if (!_showingQueue && !_bare && !UIAccessibilityIsVoiceOverRunning()) [self setControlsShown:NO];
}

- (void)wake {
    if (_showingQueue) return;
    [self setControlsShown:YES];
}

- (void)setControlsShown:(BOOL)shown {
    if (_showingQueue) return;
    [_rest invalidate];
    _rest = nil;
    _hide.enabled = shown;
    if (shown) [_shield removeFromSuperview];
    else if (!_shield.superview) {
        _shield.frame = self.view.bounds;
        [self.view addSubview:_shield];
    }
    // Back at a tap with the Kit's response, from where a fade out is; they go with the slow fade, as the
    // portrait player's do (PlayerLyrics.x).
    SGRAnimate(shown ? SGRMotionRespond : SGRMotionFade, ^{
        // Keeping the title (Player.h), the title and the artist stay over the lines.
        NSArray<UIView *> *fading = SGRLyricsHideMode() == SGRLyricsHideControls ? @[self->_controls, self->_close]
                                                                                 : @[self->_controls, self->_close, self->_title, self->_artist];
        for (UIView *view in fading) view.alpha = shown ? 1 : 0;
        self->_lyrics.extrasHidden = !shown;
    }, nil);
    if (shown) [self restartRest];
}

- (void)restartRest {
    [_rest invalidate];
    _rest = nil;
    if (_showingQueue || _bare || SGRLyricsHideMode() == SGRLyricsHideOff || SGPlayerState().isPaused || UIAccessibilityIsVoiceOverRunning()) return;
    __weak SGRLandscapeLyricsController *weakSelf = self;
    _rest = [NSTimer scheduledTimerWithTimeInterval:kLandscapeRest repeats:NO block:^(NSTimer *timer) {
        // A sheet over the lines (a line's meanings) keeps them up, and the clock runs again behind it.
        SGRLandscapeLyricsController *strongSelf = weakSelf;
        if (strongSelf.presentedViewController) [strongSelf restartRest];
        else [strongSelf rest];
    }];
}

@end

#pragma mark - turning

static UIInterfaceOrientationMask (*sg_origOrientations)(id, SEL, UIApplication *, UIWindow *);

static UIInterfaceOrientationMask orientationsFor(id self, SEL _cmd, UIApplication *application, UIWindow *window) {
    if (window && window == sg_window) return UIInterfaceOrientationMaskLandscape;
    return sg_origOrientations ? sg_origOrientations(self, _cmd, application, window) : UIInterfaceOrientationMaskPortrait;
}

// The delegate's own answer stays for every window but the landscape one; one that has none answers
// portrait, which is what the Info.plist said.
static void answerForOrientations(void) {
    static BOOL done;
    id delegate = UIApplication.sharedApplication.delegate;
    if (done || !delegate) return;
    done = YES;
    SEL selector = @selector(application:supportedInterfaceOrientationsForWindow:);
    Method method = class_getInstanceMethod([delegate class], selector);
    if (method) sg_origOrientations = (void *)method_setImplementation(method, (IMP)orientationsFor);
    else class_addMethod([delegate class], selector, (IMP)orientationsFor, "Q@:@@");
    SGLog(@"redesign player: landscape answer for %@ (%@)", NSStringFromClass([delegate class]), method ? @"its own answer kept" : @"portrait otherwise");
}

// A landscape window still clear when no turn is coming to fade it in.
static void reveal(UIWindow *window) {
    if (window && window == sg_window && window.alpha < 1) SGRAnimate(SGRMotionFade, ^{ window.alpha = 1; }, nil);
}

static void requestOrientations(UIWindowScene *scene, UIInterfaceOrientationMask mask) {
    __weak UIWindow *window = sg_window;
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS *preferences = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
        [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
            SGLog(@"redesign player: the scene did not turn: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{ reveal(window); });
        }];
    }
}

void SGRPlayerLandscapeLinesChanged(void) {
    id screen = sg_window.rootViewController;
    if ([screen isKindOfClass:SGRLandscapeLyricsController.class]) {
        [(SGRLandscapeLyricsController *)screen updateBare:YES];
        [(SGRLandscapeLyricsController *)screen updateMode];
    }
}

void SGRPlayerLandscapeModeChanged(void) {
    id screen = sg_window.rootViewController;
    if ([screen isKindOfClass:SGRLandscapeLyricsController.class]) {
        [(SGRLandscapeLyricsController *)screen updateMode];
    } else if (UIDeviceOrientationIsLandscape(UIDevice.currentDevice.orientation) && !sg_shut && shouldShowLandscapeForCurrentState()) {
        SGRPlayerShowLandscape(YES);
    }
}

void SGRPlayerShowLandscape(BOOL show) {
    UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    if (show && !sg_window) {
        answerForOrientations();
        sg_window = [[UIWindow alloc] initWithWindowScene:scene];
        sg_window.windowLevel = UIWindowLevelNormal + 1;
        // The window is the mod's own, so what it presents (Sing's alerts, a line's meanings) is dark too.
        sg_window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        sg_window.alpha = 1.0;
        sg_window.rootViewController = [SGRLandscapeLyricsController new];
        [sg_window makeKeyAndVisible];
        [UIView performWithoutAnimation:^{
            [sg_window layoutIfNeeded];
        }];
        requestOrientations(scene, UIInterfaceOrientationMaskLandscape);
        if (UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)) reveal(sg_window);
        SGLog(@"redesign player: turning sideways into landscape");
    } else if (!show && sg_window) {
        UIWindow *window = sg_window;
        SGRLandscapeLyricsController *ctrl = [window.rootViewController isKindOfClass:SGRLandscapeLyricsController.class]
            ? (SGRLandscapeLyricsController *)window.rootViewController : nil;
        if (ctrl && SGRPlayerQueueOpen()) {
            SGRPlayerSetQueueScrollOffset([ctrl currentQueueScrollOffset]);
            [ctrl refreshPortraitTransportSnapshot];
        }
        if (ctrl) ctrl.closingToPortrait = YES;
        sg_window = nil;
        window.userInteractionEnabled = NO;
        // A sheet up over the lines (a line's meanings) goes with them, or it would be left on a hidden window.
        [window.rootViewController dismissViewControllerAnimated:NO completion:nil];
        BOOL wasLandscape = (window.bounds.size.width > window.bounds.size.height);
        if (@available(iOS 16.0, *)) [window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
        requestOrientations(scene, UIInterfaceOrientationMaskPortrait);

        void (^restoreKeyWindow)(void) = ^{
            if (sg_window) return;
            for (UIWindow *other in scene.windows) {
                if (other != window && !other.hidden && other.windowLevel == UIWindowLevelNormal) {
                    [other makeKeyWindow];
                    break;
                }
            }
        };

        if (wasLandscape) {
            // Keep window opaque while viewWillTransitionToSize: rotates it back to Portrait so the two windows
            // never cross-fade at 45 degrees; safety timer ensures cleanup even if UIKit skips the transition.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.42 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!window.hidden) {
                    [UIView animateWithDuration:0.10 animations:^{ window.alpha = 0.0; } completion:^(BOOL finished) {
                        window.hidden = YES;
                        restoreKeyWindow();
                    }];
                } else {
                    restoreKeyWindow();
                }
            });
        } else {
            SGRAnimate(SGRMotionFade, ^{ window.alpha = 0; }, ^(BOOL finished) {
                window.hidden = YES;
                restoreKeyWindow();
            });
        }
        SGLog(@"redesign player: turning back to portrait");
    }
}

static void orientationChanged(void) {
    UIDeviceOrientation orientation = UIDevice.currentDevice.orientation;
    if (UIDeviceOrientationIsLandscape(orientation)) {
        if (!sg_shut && shouldShowLandscapeForCurrentState()) SGRPlayerShowLandscape(YES);
    } else if (orientation == UIDeviceOrientationPortrait) {
        sg_shut = NO;
        SGRPlayerShowLandscape(NO);
    }
}

%ctor {
    if (!SGRedesignedUI()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
        [NSNotificationCenter.defaultCenter addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { orientationChanged(); }];
    });
}

#import "SGRQueueView.h"
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Shared/Navigation/Links.h"
#import "Player.h"

// ============================================================================
// Constants & Geometry (Measured 1:1 from Apple Music iOS 18 @ 390x844 pt)
// ============================================================================

static const CGFloat kGrabberWidth = 36.0;
static const CGFloat kGrabberHeight = 5.0;
static const CGFloat kViewportTopOffset = 19.0;       // Grabber at y=0 (screenY=53), Viewport at y=19 (screenY=72)
static const CGFloat kNowPlayingDocY = 14.7;          // screenY = 86.7 at scrollY = 0
static const CGFloat kNowPlayingHeight = 85.0;        // screenY = 86.7..171.7
static const CGFloat kContinueHeaderDocY = 99.7;      // screenY = 171.7 at scrollY = 0
static const CGFloat kContinueHeaderPinOffset = 12.7; // Pins at viewportY = 12.7 (screenY = 84.7, bottom = 174.7)
static const CGFloat kContinueHeaderHeight = 90.0;    // 36pt pills + 10pt gap + 44pt title/subtitle
static const CGFloat kQueueRowsStartDocY = 196.5;     // Places Row 0 art at screenY=274..319 and title cap-top at 283
static const CGFloat kQueueRowPitch = 56.0;           // Exact 56pt row pitch (283, 339, 395, 451, 507)
static const CGFloat kHistoryHeaderHeight = 46.0;
static const CGFloat kHistoryRowPitch = 58.0;
static const CGFloat kHistoryBottomGap = 22.0;        // 46 + 2*58 + 22 = 184pt total history pull-down
static const CGFloat kHistoryHeaderPinOffset = 7.0;   // Pins at viewportY = 7.0 (screenY = 79.0)
static const CGFloat kHistoryHeaderPushOffDocY = -43.7;

static const CGFloat kSwipeParkOffset = -80.0;        // Parked swipe-to-delete offset (-80pt)
static const CGFloat kSwipeCommitRatio = 0.58;        // ~225pt on 390pt width

// ============================================================================
// Artwork URL Resolution & Async Loader (i.scdn.co + LocalFiles cache)
// ============================================================================

static NSURL *SGRQueueArtworkURLForTrack(SPTPlayerTrack *track) {
    if (!track || ![track respondsToSelector:@selector(metadata)]) return nil;
    NSDictionary *metadata = track.metadata;
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *field in @[@"image_url", @"image_large_url", @"image_small_url", @"image_xlarge_url"]) {
        NSString *val = metadata[field];
        if (![val isKindOfClass:NSString.class] || !val.length) continue;
        NSString *stored = SGLocalFileCoverInURL(val);
        if (stored.length) return [NSURL fileURLWithPath:stored];
        if ([val hasPrefix:@"spotify:image:"]) {
            NSString *imgID = [val substringFromIndex:@"spotify:image:".length];
            if (imgID.length) return [NSURL URLWithString:[@"https://i.scdn.co/image/" stringByAppendingString:imgID]];
        }
        if ([val hasPrefix:@"https://"] || [val hasPrefix:@"http://"]) {
            return [NSURL URLWithString:val];
        }
    }
    return nil;
}

static NSCache<NSString *, UIImage *> *SGRQueueImageCache(void) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 120;
    });
    return cache;
}

static void SGRLoadQueueArtwork(NSURL *url, void (^completion)(UIImage *image)) {
    if (!url || !completion) return;
    NSString *key = url.absoluteString;
    UIImage *cached = [SGRQueueImageCache() objectForKey:key];
    if (cached) {
        completion(cached);
        return;
    }
    if (url.isFileURL) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *img = [UIImage imageWithContentsOfFile:url.path];
            if (img) [SGRQueueImageCache() setObject:img forKey:key];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(img);
            });
        });
        return;
    }
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *img = (data.length && !error) ? [UIImage imageWithData:data] : nil;
        if (img) [SGRQueueImageCache() setObject:img forKey:key];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(img);
        });
    }];
    [task resume];
}

// ============================================================================
// Explicit "E" Badge Helper (Solid muted gray rounded square with cutout "E")
// ============================================================================

static UIImage *SGRExplicitBadgeImage(void) {
    static UIImage *badge = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGSize size = CGSizeMake(13.5, 13.5);
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
        badge = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            CGContextRef cg = ctx.CGContext;
            UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:2.8];
            [[UIColor colorWithWhite:1.0 alpha:0.42] setFill];
            [bg fill];

            CGContextSetBlendMode(cg, kCGBlendModeClear);
            UIFont *font = [UIFont systemFontOfSize:9.2 weight:UIFontWeightHeavy];
            NSDictionary *attrs = @{
                NSFontAttributeName: font,
                NSForegroundColorAttributeName: UIColor.blackColor,
            };
            NSString *e = @"E";
            CGSize textSize = [e sizeWithAttributes:attrs];
            CGRect textRect = CGRectMake((size.width - textSize.width) * 0.5,
                                         (size.height - textSize.height) * 0.5,
                                         textSize.width,
                                         textSize.height);
            [e drawInRect:textRect withAttributes:attrs];
        }];
    });
    return badge;
}

// ============================================================================
// Crossing-Arrows Transitions / AutoMix Glyph Helper
// ============================================================================

static UIImage *SGRTransitionsGlyphImage(UIColor *tintColor) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightMedium];
    UIImage *img = [UIImage systemImageNamed:@"arrow.triangle.merge" withConfiguration:cfg];
    if (!img) img = [UIImage systemImageNamed:@"waveform.path" withConfiguration:cfg];
    return [img imageWithTintColor:tintColor renderingMode:UIImageRenderingModeAlwaysOriginal];
}

// ============================================================================
// SGRQueueRowView: Individual Track Row (History & Continue Playing)
// ============================================================================

@class SGRQueueRowView;

@protocol SGRQueueRowViewDelegate <NSObject>
- (void)queueRowDidTap:(SGRQueueRowView *)row;
- (void)queueRowWillBeginSwipe:(SGRQueueRowView *)row;
- (void)queueRowDidCommitDelete:(SGRQueueRowView *)row;
- (void)queueRowHandlePan:(UIPanGestureRecognizer *)pan forRow:(SGRQueueRowView *)row;
- (UIMenu *)queueRowContextMenuForRow:(SGRQueueRowView *)row;
- (UIViewController *)queueRowPreviewControllerForRow:(SGRQueueRowView *)row;
@end

@interface SGRQueueRowView : UIView <UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate>
@property (nonatomic, weak) id<SGRQueueRowViewDelegate> delegate;
@property (nonatomic, strong) SPTPlayerTrack *track;
@property (nonatomic, assign) NSInteger rowIndex;
@property (nonatomic, assign) BOOL isHistory;
@property (nonatomic, assign) BOOL showsHandle;
@property (nonatomic, assign, readonly) BOOL isSwipeParked;
@property (nonatomic, strong, readonly) UIImageView *artView;

- (void)configureWithTrack:(SPTPlayerTrack *)track isHistory:(BOOL)isHistory rowIndex:(NSInteger)rowIndex;
- (void)closeSwipeAnimated:(BOOL)animated;
@end

@implementation SGRQueueRowView {
    UIView *_highlightBand;
    UIView *_rowContentView;
    UIImageView *_artView;
    UILabel *_titleLabel;
    UIImageView *_explicitView;
    UILabel *_subtitleLabel;
    UIView *_handleHitView;
    CAShapeLayer *_handleBarsLayer;

    // Swipe-to-delete views (Section 2 rows only)
    UIView *_deleteCapsuleView;
    UIView *_deleteCapsuleRim;
    UIView *_minusDiscView;
    UIView *_minusBarView;

    UIPanGestureRecognizer *_swipePan;
    UIPanGestureRecognizer *_reorderPan;
    CGFloat _swipeOffsetX;
    CGFloat _panStartOffsetX;
    BOOL _isSwipeParked;
    BOOL _committedFullSwipe;
    BOOL _isDeleting;
    NSString *_loadedArtURL;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.clipsToBounds = YES;
    self.backgroundColor = UIColor.clearColor;

    _highlightBand = [[UIView alloc] initWithFrame:self.bounds];
    _highlightBand.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    _highlightBand.alpha = 0.0;
    _highlightBand.userInteractionEnabled = NO;
    [self addSubview:_highlightBand];

    // Floating Red Delete Capsule (#F03850) behind/beside row content
    _deleteCapsuleView = [[UIView alloc] initWithFrame:CGRectZero];
    _deleteCapsuleView.backgroundColor = [UIColor colorWithRed:240.0/255.0 green:56.0/255.0 blue:80.0/255.0 alpha:1.0];
    _deleteCapsuleView.layer.cornerCurve = kCACornerCurveContinuous;
    _deleteCapsuleView.clipsToBounds = YES;
    _deleteCapsuleView.alpha = 0.0;
    _deleteCapsuleView.hidden = YES;
    UITapGestureRecognizer *delTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDeleteCapsuleTap:)];
    [_deleteCapsuleView addGestureRecognizer:delTap];
    [self addSubview:_deleteCapsuleView];

    _deleteCapsuleRim = [[UIView alloc] initWithFrame:CGRectZero];
    _deleteCapsuleRim.backgroundColor = [UIColor colorWithRed:175.0/255.0 green:24.0/255.0 blue:44.0/255.0 alpha:0.45];
    _deleteCapsuleRim.userInteractionEnabled = NO;
    [_deleteCapsuleView addSubview:_deleteCapsuleRim];

    _minusDiscView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 19.0, 19.0)];
    _minusDiscView.backgroundColor = UIColor.whiteColor;
    _minusDiscView.layer.cornerRadius = 9.5;
    _minusDiscView.userInteractionEnabled = NO;
    [_deleteCapsuleView addSubview:_minusDiscView];

    _minusBarView = [[UIView alloc] initWithFrame:CGRectMake(4.75, 8.4, 9.5, 2.2)];
    _minusBarView.backgroundColor = [UIColor colorWithRed:240.0/255.0 green:56.0/255.0 blue:80.0/255.0 alpha:1.0];
    _minusBarView.layer.cornerRadius = 1.1;
    [_minusDiscView addSubview:_minusBarView];

    // Rigid row content block
    _rowContentView = [[UIView alloc] initWithFrame:self.bounds];
    _rowContentView.backgroundColor = UIColor.clearColor;
    [self addSubview:_rowContentView];

    _artView = [[UIImageView alloc] initWithFrame:CGRectMake(33.5, 5.5, 45.0, 45.0)];
    _artView.contentMode = UIViewContentModeScaleAspectFill;
    _artView.clipsToBounds = YES;
    _artView.layer.cornerRadius = 5.5;
    _artView.layer.cornerCurve = kCACornerCurveContinuous;
    _artView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    [_rowContentView addSubview:_artView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [UIFont systemFontOfSize:16.5 weight:UIFontWeightRegular];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_rowContentView addSubview:_titleLabel];

    _explicitView = [[UIImageView alloc] initWithImage:SGRExplicitBadgeImage()];
    _explicitView.contentMode = UIViewContentModeScaleAspectFit;
    _explicitView.hidden = YES;
    [_rowContentView addSubview:_explicitView];

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightRegular];
    _subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.56];
    _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_rowContentView addSubview:_subtitleLabel];

    // 3-line reorder handle (21x10 pt visual bars at x = w - 57 .. w - 36)
    _handleHitView = [[UIView alloc] initWithFrame:CGRectZero];
    _handleHitView.backgroundColor = UIColor.clearColor;
    [_rowContentView addSubview:_handleHitView];

    _handleBarsLayer = [CAShapeLayer layer];
    _handleBarsLayer.fillColor = [UIColor colorWithWhite:1.0 alpha:0.36].CGColor;
    [_handleHitView.layer addSublayer:_handleBarsLayer];

    _reorderPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleReorderPan:)];
    _reorderPan.delegate = self;
    [_handleHitView addGestureRecognizer:_reorderPan];

    _swipePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipePan:)];
    _swipePan.delegate = self;
    [self addGestureRecognizer:_swipePan];

    UITapGestureRecognizer *rowTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleRowTap:)];
    rowTap.cancelsTouchesInView = NO;
    [rowTap requireGestureRecognizerToFail:_swipePan];
    [rowTap requireGestureRecognizerToFail:_reorderPan];
    [_rowContentView addGestureRecognizer:rowTap];

    UIContextMenuInteraction *menuInteraction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    [_rowContentView addInteraction:menuInteraction];

    return self;
}

- (UIImageView *)artView {
    return _artView;
}

- (BOOL)isSwipeParked {
    return _isSwipeParked;
}

- (BOOL)isTrackExplicit:(SPTPlayerTrack *)track {
    if (!track) return NO;
    @try {
        NSDictionary *meta = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
        if ([meta isKindOfClass:NSDictionary.class]) {
            NSString *exp = meta[@"is_explicit"] ?: meta[@"explicit"];
            if ([exp isKindOfClass:NSString.class] && ([exp isEqualToString:@"true"] || [exp isEqualToString:@"1"])) return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

- (void)configureWithTrack:(SPTPlayerTrack *)track isHistory:(BOOL)isHistory rowIndex:(NSInteger)rowIndex {
    _track = track;
    _isHistory = isHistory;
    _rowIndex = rowIndex;
    _showsHandle = !isHistory;
    _handleHitView.hidden = isHistory;
    _swipePan.enabled = !isHistory;

    NSDictionary *meta = ([track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class]) ? track.metadata : nil;
    NSString *title = [track respondsToSelector:@selector(trackTitle)] ? track.trackTitle : nil;
    if (!title.length) title = meta[@"title"] ?: @"Unknown Track";
    _titleLabel.text = title;

    NSString *artist = [track respondsToSelector:@selector(artistName)] ? track.artistName : nil;
    if (!artist.length) artist = meta[@"artist_name"] ?: @"";
    _subtitleLabel.text = artist;

    _explicitView.hidden = ![self isTrackExplicit:track];

    NSURL *artURL = SGRQueueArtworkURLForTrack(track);
    NSString *urlKey = artURL.absoluteString ?: @"";
    if (![urlKey isEqualToString:_loadedArtURL]) {
        _loadedArtURL = [urlKey copy];
        _artView.image = nil;
        if (artURL) {
            NSString *expected = _loadedArtURL;
            __weak typeof(self) weakSelf = self;
            SGRLoadQueueArtwork(artURL, ^(UIImage *image) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || ![strongSelf->_loadedArtURL isEqualToString:expected]) return;
                strongSelf->_artView.image = image;
            });
        }
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_isDeleting) return;

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    _highlightBand.frame = self.bounds;

    _rowContentView.frame = CGRectMake(_swipeOffsetX, 0, w, h);

    CGFloat artY = round((h - 45.0) * 0.5 * 2.0) * 0.5;
    _artView.frame = CGRectMake(33.5, artY, 45.0, 45.0);

    // 3-line handle at x = w - 57 .. w - 36 (333..354 on 390pt screen)
    CGFloat handleTouchW = 54.0;
    _handleHitView.frame = CGRectMake(w - 66.0, 0, handleTouchW, h);
    CGFloat barLeft = 66.0 - 57.0; // 9pt inside _handleHitView -> screenX = w - 57
    CGFloat barTop = (h - 10.0) * 0.5;
    UIBezierPath *bars = [UIBezierPath bezierPath];
    for (int i = 0; i < 3; i++) {
        CGRect r = CGRectMake(barLeft, barTop + i * 4.2, 21.0, 1.6);
        [bars appendPath:[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:0.8]];
    }
    _handleBarsLayer.path = bars.CGPath;

    CGFloat textLeft = 93.7;
    CGFloat maxRight = _showsHandle ? (w - 68.0) : (w - 20.0);
    CGFloat availW = MAX(40.0, maxRight - textLeft);

    BOOL hasExp = !_explicitView.hidden;
    CGFloat badgeW = hasExp ? (13.5 + 5.0) : 0.0;
    CGSize naturalTitle = [_titleLabel sizeThatFits:CGSizeMake(availW - badgeW, 24.0)];
    CGFloat titleW = MIN(availW - badgeW, ceil(naturalTitle.width));

    _titleLabel.frame = CGRectMake(textLeft, 9.0, titleW, 20.5);
    if (hasExp) {
        _explicitView.frame = CGRectMake(textLeft + titleW + 5.0, 12.5, 13.5, 13.5);
    }
    _subtitleLabel.frame = CGRectMake(textLeft, 30.0, availW, 18.0);

    [self layoutDeleteCapsule];
}

- (void)layoutDeleteCapsule {
    CGFloat w = self.bounds.size.width;
    CGFloat absOffset = -_swipeOffsetX;
    if (absOffset < 6.0) {
        _deleteCapsuleView.alpha = 0.0;
        _deleteCapsuleView.hidden = YES;
        return;
    }
    _deleteCapsuleView.hidden = NO;

    if (_committedFullSwipe) {
        // Full-width stretched capsule (x = 12 .. w - 10) with icon at 25pt inside left edge
        CGFloat capLeft = 12.0;
        CGFloat capRight = w - 10.0;
        CGFloat capW = MAX(59.0, capRight - capLeft);
        CGFloat capH = 46.5;
        CGFloat capY = (self.bounds.size.height - capH) * 0.5;
        _deleteCapsuleView.frame = CGRectMake(capLeft, capY, capW, capH);
        _deleteCapsuleView.layer.cornerRadius = capH * 0.5;
        _deleteCapsuleView.alpha = 1.0;
        _deleteCapsuleView.backgroundColor = [UIColor colorWithRed:240.0/255.0 green:56.0/255.0 blue:80.0/255.0 alpha:1.0];
        _deleteCapsuleRim.frame = CGRectMake(0, capH - 2.0, capW, 2.0);
        _minusDiscView.center = CGPointMake(25.0, capH * 0.5);
        _minusDiscView.transform = CGAffineTransformIdentity;
        return;
    }

    if (absOffset <= 82.0) {
        // Swipe 1 pop-in phase: scales up from a dim crimson dot at (w - 40.5, midY) to 59x46 capsule at x = w - 70..w - 11
        CGFloat t = MIN(1.0, MAX(0.0, (absOffset - 10.0) / 70.0));
        CGFloat eased = 1.0 - (1.0 - t) * (1.0 - t);
        CGFloat capW = 16.0 + (59.0 - 16.0) * eased;
        CGFloat capH = 16.0 + (46.0 - 16.0) * eased;
        CGFloat centerX = (w - 40.5);
        CGFloat centerY = self.bounds.size.height * 0.5;
        _deleteCapsuleView.frame = CGRectMake(centerX - capW * 0.5, centerY - capH * 0.5, capW, capH);
        _deleteCapsuleView.layer.cornerRadius = capH * 0.5;
        _deleteCapsuleView.alpha = MIN(1.0, t * 1.35);

        CGFloat r = (140.0 + (240.0 - 140.0) * eased) / 255.0;
        CGFloat g = (24.0 + (56.0 - 24.0) * eased) / 255.0;
        CGFloat b = (40.0 + (80.0 - 40.0) * eased) / 255.0;
        _deleteCapsuleView.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:1.0];
        _deleteCapsuleRim.frame = CGRectMake(0, capH - 2.0, capW, 2.0);

        _minusDiscView.center = CGPointMake(capW * 0.5, capH * 0.5);
        CGFloat discScale = 0.4 + 0.6 * eased;
        _minusDiscView.transform = CGAffineTransformMakeScale(discScale, discScale);
    } else {
        // Swipe 2 continuous stretch phase: width = |offset| - 14, right edge drifts from w-11 to w-9
        CGFloat extra = MIN(1.0, (absOffset - 80.0) / 140.0);
        CGFloat capRight = (w - 11.0) + 2.0 * extra;
        CGFloat capW = MAX(59.0, absOffset - 14.0);
        CGFloat capH = 46.0 + 1.0 * extra;
        CGFloat capLeft = MAX(12.0, capRight - capW);
        CGFloat capY = (self.bounds.size.height - capH) * 0.5;
        _deleteCapsuleView.frame = CGRectMake(capLeft, capY, capRight - capLeft, capH);
        _deleteCapsuleView.layer.cornerRadius = capH * 0.5;
        _deleteCapsuleView.alpha = 1.0;
        _deleteCapsuleView.backgroundColor = [UIColor colorWithRed:240.0/255.0 green:56.0/255.0 blue:80.0/255.0 alpha:1.0];
        _deleteCapsuleRim.frame = CGRectMake(0, capH - 2.0, capRight - capLeft, 2.0);
        _minusDiscView.center = CGPointMake((capRight - capLeft) * 0.5, capH * 0.5);
        _minusDiscView.transform = CGAffineTransformIdentity;
    }
}

#pragma mark - Gestures (Swipe-to-Delete, Reorder, Tap, Context Menu)

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == _swipePan) {
        if (_isHistory || _isDeleting) return NO;
        CGPoint vel = [_swipePan velocityInView:self];
        return fabs(vel.x) > fabs(vel.y) * 1.15;
    }
    if (gestureRecognizer == _reorderPan) {
        if (_isHistory || _isDeleting || _isSwipeParked) return NO;
        return YES;
    }
    return YES;
}

- (void)handleReorderPan:(UIPanGestureRecognizer *)pan {
    [self.delegate queueRowHandlePan:pan forRow:self];
}

- (void)handleSwipePan:(UIPanGestureRecognizer *)pan {
    if (_isDeleting || _isHistory) return;
    CGFloat w = MAX(320.0, self.bounds.size.width);
    CGFloat commitThreshold = -(w * kSwipeCommitRatio);

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            [self.delegate queueRowWillBeginSwipe:self];
            _panStartOffsetX = _swipeOffsetX;
            _committedFullSwipe = NO;
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint trans = [pan translationInView:self];
            CGFloat rawX = MIN(0.0, _panStartOffsetX + trans.x);
            _swipeOffsetX = rawX;

            BOOL nowCommitted = (rawX <= commitThreshold);
            if (nowCommitted != _committedFullSwipe) {
                _committedFullSwipe = nowCommitted;
                UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                [gen impactOccurred];
                [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
                    if (self->_committedFullSwipe) {
                        self->_rowContentView.frame = CGRectMake(-w, 0, w, self.bounds.size.height);
                    } else {
                        self->_rowContentView.frame = CGRectMake(self->_swipeOffsetX, 0, w, self.bounds.size.height);
                    }
                    [self layoutDeleteCapsule];
                } completion:nil];
            } else {
                if (!_committedFullSwipe) {
                    _rowContentView.frame = CGRectMake(_swipeOffsetX, 0, w, self.bounds.size.height);
                }
                [self layoutDeleteCapsule];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGPoint vel = [pan velocityInView:self];
            if (_committedFullSwipe || (_swipeOffsetX < -165.0 && vel.x < -650.0)) {
                [self commitDeleteWithStretch:!_committedFullSwipe];
            } else if (_swipeOffsetX < -34.0 || vel.x < -220.0) {
                // Park at -80pt with fast ease-out, zero bounce
                _isSwipeParked = YES;
                _committedFullSwipe = NO;
                _swipeOffsetX = kSwipeParkOffset;
                [UIView animateWithDuration:0.32 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction animations:^{
                    self->_rowContentView.frame = CGRectMake(kSwipeParkOffset, 0, w, self.bounds.size.height);
                    [self layoutDeleteCapsule];
                } completion:^(BOOL finished) {
                    if (finished && self->_isSwipeParked && !self->_isDeleting) {
                        // Subtle ~3% parked settle (60x47 -> 58x46) per Clip 1
                        [UIView animateWithDuration:0.20 animations:^{
                            self->_deleteCapsuleView.transform = CGAffineTransformMakeScale(0.97, 0.98);
                        }];
                    }
                }];
            } else {
                [self closeSwipeAnimated:YES];
            }
            break;
        }
        default:
            break;
    }
}

- (void)closeSwipeAnimated:(BOOL)animated {
    if (_isDeleting) return;
    _isSwipeParked = NO;
    _committedFullSwipe = NO;
    _swipeOffsetX = 0.0;
    _deleteCapsuleView.transform = CGAffineTransformIdentity;
    void (^apply)(void) = ^{
        self->_rowContentView.frame = CGRectMake(0, 0, self.bounds.size.width, self.bounds.size.height);
        [self layoutDeleteCapsule];
    };
    if (animated) {
        [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:apply completion:nil];
    } else {
        apply();
    }
}

- (void)handleDeleteCapsuleTap:(UITapGestureRecognizer *)tap {
    if (_isDeleting) return;
    [self commitDeleteWithStretch:YES];
}

- (void)commitDeleteWithStretch:(BOOL)needsStretch {
    if (_isDeleting) return;
    _isDeleting = YES;
    _isSwipeParked = NO;
    _deleteCapsuleView.transform = CGAffineTransformIdentity;
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    void (^triggerCollapse)(void) = ^{
        [self.delegate queueRowDidCommitDelete:self];
    };

    if (needsStretch) {
        // Phase 1 of Commit (Clip 1 1.818-1.952s): Capsule stretches left to x=12, minus disc slides to x=25 inside capsule, row content pushes off-screen left
        _committedFullSwipe = YES;
        _swipeOffsetX = -w;
        [UIView animateWithDuration:0.135 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self->_rowContentView.frame = CGRectMake(-w - 20.0, 0, w, h);
            CGFloat capH = 46.0;
            CGFloat capY = (h - capH) * 0.5;
            CGFloat capW = w - 23.0;
            self->_deleteCapsuleView.frame = CGRectMake(12.0, capY, capW, capH);
            self->_deleteCapsuleView.layer.cornerRadius = capH * 0.5;
            self->_deleteCapsuleRim.frame = CGRectMake(0, capH - 2.0, capW, 2.0);
            self->_minusDiscView.center = CGPointMake(25.0, capH * 0.5);
        } completion:^(BOOL finished) {
            triggerCollapse();
        }];
    } else {
        triggerCollapse();
    }
}

- (void)handleRowTap:(UITapGestureRecognizer *)tap {
    if (_isDeleting) return;
    if (_isSwipeParked) {
        [self closeSwipeAnimated:YES];
        return;
    }
    _highlightBand.alpha = 1.0;
    [UIView animateWithDuration:0.25 animations:^{
        self->_highlightBand.alpha = 0.0;
    }];
    [self.delegate queueRowDidTap:self];
}

#pragma mark - UIContextMenuInteractionDelegate

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    if (_isSwipeParked || _isDeleting) return nil;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:^UIViewController * _Nullable{
        return [weakSelf.delegate queueRowPreviewControllerForRow:weakSelf];
    } actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return [weakSelf.delegate queueRowContextMenuForRow:weakSelf];
    }];
}

@end

// ============================================================================
// SGRQueueView: Main Inline Apple Music Queue View
// ============================================================================

@interface SGRQueueView () <UIScrollViewDelegate, SGRQueueRowViewDelegate, UIContextMenuInteractionDelegate>
@end

@implementation SGRQueueView {
    UIView *_grabberPill;
    UIView *_viewportClipView;
    CAGradientLayer *_bottomFadeMask;
    UIScrollView *_scrollView;

    // Section 0: History
    UIView *_historyHeaderView;
    UILabel *_historyTitleLabel;
    UIButton *_historyClearButton;
    UIView *_historyRowsClipView;
    UIView *_historyRowsContainerView;
    NSMutableArray<SGRQueueRowView *> *_historyRowViews;

    // Section 1: Now Playing Card
    UIView *_nowPlayingCard;
    UIImageView *_npArtView;
    UILabel *_npTitleLabel;
    UIImageView *_npExplicitView;
    UILabel *_npArtistLabel;
    UIButton *_npStarButton;
    UIButton *_npMoreButton;

    // Section 2: Continue Playing Sticky Header & Rows
    UIView *_continueHeaderView;
    UIButton *_shufflePill;
    UIButton *_repeatPill;
    UIButton *_autoplayPill;
    UIButton *_transitionsPill;
    UILabel *_continueTitleLabel;
    UILabel *_continueSubtitleLabel;

    UIView *_queueRowsClipView;
    UIView *_queueRowsContainerView;
    NSMutableArray<SGRQueueRowView *> *_queueRowViews;

    // Data Model & Local Persistence over Spotify state updates
    SPTPlayerTrack *_currentTrack;
    NSMutableArray<SPTPlayerTrack *> *_historyTracks;
    NSMutableArray<SPTPlayerTrack *> *_futureTracks;
    NSMutableSet<NSString *> *_locallyDeletedKeys;
    NSMutableSet<NSString *> *_starredURIs;
    BOOL _historyClearedByUser;
    BOOL _autoplayEnabled;
    BOOL _transitionsEnabled;
    NSString *_loadedNPArtURL;
    NSString *_lastStateFingerprint;

    // Scroll Detent State
    CGFloat _dragStartOffsetY;
    BOOL _clampAtZeroOnDeceleration;
    BOOL _didSetInitialOffset;

    // Drag-to-Reorder State
    SGRQueueRowView *_draggingRow;
    UIView *_dragSnapshotView;
    NSInteger _dragCurrentIndex;
    CGFloat _dragGrabOffsetY;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;

    _historyTracks = [NSMutableArray array];
    _futureTracks = [NSMutableArray array];
    _historyRowViews = [NSMutableArray array];
    _queueRowViews = [NSMutableArray array];
    _locallyDeletedKeys = [NSMutableSet set];
    _starredURIs = [NSMutableSet set];
    _autoplayEnabled = NO;     // Dimmed by default per Clip 1 & Clip 2
    _transitionsEnabled = NO;

    [self buildViewHierarchy];
    SGAddPlayerStateObserver(self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleNowPlayingArtworkChanged:) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)handleNowPlayingArtworkChanged:(NSNotification *)note {
    UIImage *art = SGRNowPlayingArtwork(NULL, NULL);
    if (art) _npArtView.image = art;
}

- (void)buildViewHierarchy {
    // 1. Top Sheet Grabber Pill (36x5 pt at y=0, screenY=53..58)
    _grabberPill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kGrabberWidth, kGrabberHeight)];
    _grabberPill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
    _grabberPill.layer.cornerRadius = kGrabberHeight * 0.5;
    _grabberPill.userInteractionEnabled = NO;
    [self addSubview:_grabberPill];

    // 2. Scrollable Queue Viewport (starts at y=19, screenY=72..540) with bottom fade gradient
    _viewportClipView = [[UIView alloc] initWithFrame:CGRectZero];
    _viewportClipView.clipsToBounds = YES;
    _viewportClipView.backgroundColor = UIColor.clearColor;
    [self addSubview:_viewportClipView];

    _bottomFadeMask = [CAGradientLayer layer];
    _bottomFadeMask.colors = @[
        (id)UIColor.whiteColor.CGColor,
        (id)UIColor.whiteColor.CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.52].CGColor,
        (id)UIColor.clearColor.CGColor,
    ];
    _bottomFadeMask.startPoint = CGPointMake(0.5, 0.0);
    _bottomFadeMask.endPoint = CGPointMake(0.5, 1.0);
    _viewportClipView.layer.mask = _bottomFadeMask;

    _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollView.delegate = self;
    _scrollView.showsVerticalScrollIndicator = YES;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scrollView.decelerationRate = UIScrollViewDecelerationRateNormal;
    _scrollView.backgroundColor = UIColor.clearColor;
    [_viewportClipView addSubview:_scrollView];

    // 3. Section 0: History Rows Clipping Plane & Sticky Header
    _historyRowsClipView = [[UIView alloc] initWithFrame:CGRectZero];
    _historyRowsClipView.clipsToBounds = YES;
    _historyRowsClipView.backgroundColor = UIColor.clearColor;
    [_scrollView addSubview:_historyRowsClipView];

    _historyRowsContainerView = [[UIView alloc] initWithFrame:CGRectZero];
    _historyRowsContainerView.backgroundColor = UIColor.clearColor;
    [_historyRowsClipView addSubview:_historyRowsContainerView];

    _historyHeaderView = [[UIView alloc] initWithFrame:CGRectZero];
    _historyHeaderView.backgroundColor = UIColor.clearColor;
    [_scrollView addSubview:_historyHeaderView];

    _historyTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _historyTitleLabel.text = @"History";
    _historyTitleLabel.font = [UIFont systemFontOfSize:19.5 weight:UIFontWeightBold];
    _historyTitleLabel.textColor = UIColor.whiteColor;
    [_historyHeaderView addSubview:_historyTitleLabel];

    _historyClearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_historyClearButton setTitle:@"Clear" forState:UIControlStateNormal];
    _historyClearButton.titleLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightSemibold];
    [_historyClearButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.56] forState:UIControlStateNormal];
    [_historyClearButton addTarget:self action:@selector(handleClearHistoryTap) forControlEvents:UIControlEventTouchUpInside];
    [_historyHeaderView addSubview:_historyClearButton];

    // 4. Section 1: Now Playing Card (docY = 14.7..99.7)
    _nowPlayingCard = [[UIView alloc] initWithFrame:CGRectZero];
    _nowPlayingCard.backgroundColor = UIColor.clearColor;
    [_scrollView addSubview:_nowPlayingCard];

    _npArtView = [[UIImageView alloc] initWithFrame:CGRectMake(20.0, 4.0, 62.0, 62.0)];
    _npArtView.contentMode = UIViewContentModeScaleAspectFill;
    _npArtView.clipsToBounds = YES;
    _npArtView.layer.cornerRadius = 8.0;
    _npArtView.layer.cornerCurve = kCACornerCurveContinuous;
    _npArtView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    _npArtView.userInteractionEnabled = YES;
    [_npArtView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleNowPlayingArtTap)]];
    [_nowPlayingCard addSubview:_npArtView];

    _npTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _npTitleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    _npTitleLabel.textColor = UIColor.whiteColor;
    _npTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_nowPlayingCard addSubview:_npTitleLabel];

    _npExplicitView = [[UIImageView alloc] initWithImage:SGRExplicitBadgeImage()];
    _npExplicitView.contentMode = UIViewContentModeScaleAspectFit;
    _npExplicitView.hidden = YES;
    [_nowPlayingCard addSubview:_npExplicitView];

    _npArtistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _npArtistLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightRegular];
    _npArtistLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.58];
    _npArtistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_nowPlayingCard addSubview:_npArtistLabel];

    _npStarButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _npStarButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    _npStarButton.layer.cornerRadius = 16.0;
    [_npStarButton addTarget:self action:@selector(handleNowPlayingStarTap) forControlEvents:UIControlEventTouchUpInside];
    [_nowPlayingCard addSubview:_npStarButton];

    _npMoreButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _npMoreButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    _npMoreButton.layer.cornerRadius = 16.0;
    UIImageSymbolConfiguration *moreCfg = [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightBold];
    [_npMoreButton setImage:[[UIImage systemImageNamed:@"ellipsis" withConfiguration:moreCfg] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
    UIContextMenuInteraction *npMenu = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    [_npMoreButton addInteraction:npMenu];
    [_nowPlayingCard addSubview:_npMoreButton];

    // 5. Section 2: Queue Track Rows Clipping Plane & Sticky Continue Playing Header
    _queueRowsClipView = [[UIView alloc] initWithFrame:CGRectZero];
    _queueRowsClipView.clipsToBounds = YES;
    _queueRowsClipView.backgroundColor = UIColor.clearColor;
    [_scrollView addSubview:_queueRowsClipView];

    _queueRowsContainerView = [[UIView alloc] initWithFrame:CGRectZero];
    _queueRowsContainerView.backgroundColor = UIColor.clearColor;
    [_queueRowsClipView addSubview:_queueRowsContainerView];

    _continueHeaderView = [[UIView alloc] initWithFrame:CGRectZero];
    _continueHeaderView.backgroundColor = UIColor.clearColor;
    [_scrollView addSubview:_continueHeaderView];

    _shufflePill = [self createPlaybackPillWithAction:@selector(handleShufflePillTap)];
    _repeatPill = [self createPlaybackPillWithAction:@selector(handleRepeatPillTap)];
    _autoplayPill = [self createPlaybackPillWithAction:@selector(handleAutoplayPillTap)];
    _transitionsPill = [self createPlaybackPillWithAction:@selector(handleTransitionsPillTap)];
    [_continueHeaderView addSubview:_shufflePill];
    [_continueHeaderView addSubview:_repeatPill];
    [_continueHeaderView addSubview:_autoplayPill];
    [_continueHeaderView addSubview:_transitionsPill];

    _continueTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _continueTitleLabel.text = @"Continue Playing";
    _continueTitleLabel.font = [UIFont systemFontOfSize:18.5 weight:UIFontWeightBold];
    _continueTitleLabel.textColor = UIColor.whiteColor;
    [_continueHeaderView addSubview:_continueTitleLabel];

    _continueSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _continueSubtitleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightRegular];
    _continueSubtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.56];
    [_continueHeaderView addSubview:_continueSubtitleLabel];

    [self updateNowPlayingStarAppearance];
    [self updatePlaybackPillsWithState:SGPlayerState()];
}

- (UIButton *)createPlaybackPillWithAction:(SEL)action {
    UIButton *pill = [UIButton buttonWithType:UIButtonTypeCustom];
    pill.layer.cornerRadius = 18.0;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.clipsToBounds = YES;
    [pill addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return pill;
}

#pragma mark - Track Identification & State Synchronization

- (NSString *)keyForTrack:(SPTPlayerTrack *)track {
    if (!track) return @"";
    NSString *uri = SGURIString(track.URI);
    NSDictionary *meta = ([track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class]) ? track.metadata : nil;
    NSString *uid = meta[@"uid"] ?: @"";
    NSString *title = [track respondsToSelector:@selector(trackTitle)] ? track.trackTitle : (meta[@"title"] ?: @"");
    return [NSString stringWithFormat:@"%@|%@|%@", uri ?: @"", uid, title];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self updateWithState:state];
}

- (void)reloadTracks {
    _didSetInitialOffset = NO;
    [self updateWithState:SGPlayerState() forceRebuild:YES];
}

- (void)updateWithState:(SPTPlayerState *)state {
    [self updateWithState:state forceRebuild:NO];
}

- (void)updateWithState:(SPTPlayerState *)state forceRebuild:(BOOL)forceRebuild {
    if (!state) state = SGPlayerState();
    [self updatePlaybackPillsWithState:state];
    if (!state) return;

    // Don't rebuild rows mid-swipe or mid-drag unless forced
    if (!forceRebuild && _draggingRow) return;
    for (SGRQueueRowView *row in _queueRowViews) {
        if (!forceRebuild && row.isSwipeParked) return;
    }

    SPTPlayerTrack *np = state.track;
    NSArray *rawReverse = ([state respondsToSelector:@selector(reverse)] && [state.reverse isKindOfClass:NSArray.class]) ? state.reverse : @[];
    NSArray *rawFuture = ([state respondsToSelector:@selector(future)] && [state.future isKindOfClass:NSArray.class]) ? state.future : @[];

    // state.reverse is nearest-first (most recently played at index 0).
    // Collect up to 8 unique recent tracks and reverse them into chronological order so the most recent sits right above Now Playing.
    NSMutableArray<SPTPlayerTrack *> *recentFirst = [NSMutableArray array];
    NSString *npURI = SGURIString(np.URI);
    if (!_historyClearedByUser && rawReverse.count > 0) {
        NSString *lastURI = npURI;
        for (id item in rawReverse) {
            if (![item respondsToSelector:@selector(URI)]) continue;
            SPTPlayerTrack *t = (SPTPlayerTrack *)item;
            NSString *u = SGURIString(t.URI);
            if (!u.length) continue;
            if ([u isEqualToString:lastURI]) continue;
            lastURI = u;
            [recentFirst addObject:t];
            if (recentFirst.count >= 8) break;
        }
    }
    NSMutableArray<SPTPlayerTrack *> *cleanHist = [NSMutableArray arrayWithCapacity:recentFirst.count];
    for (SPTPlayerTrack *t in [recentFirst reverseObjectEnumerator]) {
        [cleanHist addObject:t];
    }

    NSMutableArray<SPTPlayerTrack *> *cleanNext = [NSMutableArray array];
    for (id item in rawFuture) {
        if (![item respondsToSelector:@selector(URI)]) continue;
        SPTPlayerTrack *t = (SPTPlayerTrack *)item;
        NSString *u = SGURIString(t.URI);
        if (!u.length) continue;
        NSString *k = [self keyForTrack:t];
        if ([_locallyDeletedKeys containsObject:k]) continue;
        [cleanNext addObject:t];
        if (cleanNext.count >= 40) break;
    }

    NSMutableString *fp = [NSMutableString stringWithFormat:@"NP:%@|H:%lu|N:%lu|", npURI ?: @"", (unsigned long)cleanHist.count, (unsigned long)cleanNext.count];
    for (NSUInteger i = 0; i < MIN((NSUInteger)8, cleanNext.count); i++) {
        [fp appendFormat:@"%@,", [self keyForTrack:cleanNext[i]]];
    }
    if (!forceRebuild && [_lastStateFingerprint isEqualToString:fp]) {
        [self updateNowPlayingCardWithTrack:np state:state];
        return;
    }
    _lastStateFingerprint = [fp copy];

    _currentTrack = np;
    [_historyTracks setArray:cleanHist];
    [_futureTracks setArray:cleanNext];

    [self updateNowPlayingCardWithTrack:np state:state];
    [self rebuildTrackRows];
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (void)updateNowPlayingCardWithTrack:(SPTPlayerTrack *)track state:(SPTPlayerState *)state {
    NSDictionary *meta = ([track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class]) ? track.metadata : nil;
    NSString *title = [track respondsToSelector:@selector(trackTitle)] ? track.trackTitle : nil;
    if (!title.length) title = meta[@"title"] ?: @"Not Playing";
    _npTitleLabel.text = title;

    NSString *artist = [track respondsToSelector:@selector(artistName)] ? track.artistName : nil;
    if (!artist.length) artist = meta[@"artist_name"] ?: @"";
    _npArtistLabel.text = artist;

    BOOL exp = NO;
    NSString *e = meta[@"is_explicit"] ?: meta[@"explicit"];
    if ([e isKindOfClass:NSString.class] && ([e isEqualToString:@"true"] || [e isEqualToString:@"1"])) exp = YES;
    _npExplicitView.hidden = !exp;

    // Context source subtitle ("From <Album>.")
    NSString *album = meta[@"album_title"] ?: meta[@"context_description"];
    if (album.length) {
        _continueSubtitleLabel.text = [NSString stringWithFormat:@"From %@%@", album, [album hasSuffix:@"."] ? @"" : @"."];
    } else {
        _continueSubtitleLabel.text = @"Autoplay";
    }

    [self updateNowPlayingStarAppearance];

    UIImage *liveArt = SGRNowPlayingArtwork(NULL, NULL);
    if (liveArt) {
        _npArtView.image = liveArt;
    } else {
        NSURL *artURL = SGRQueueArtworkURLForTrack(track);
        NSString *u = artURL.absoluteString ?: @"";
        if (artURL && ![u isEqualToString:_loadedNPArtURL]) {
            _loadedNPArtURL = [u copy];
            __weak typeof(self) weakSelf = self;
            SGRLoadQueueArtwork(artURL, ^(UIImage *image) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf && image) strongSelf->_npArtView.image = image;
            });
        }
    }
}

- (void)rebuildTrackRows {
    for (UIView *v in _historyRowViews) [v removeFromSuperview];
    [_historyRowViews removeAllObjects];

    for (NSUInteger i = 0; i < _historyTracks.count; i++) {
        SGRQueueRowView *row = [[SGRQueueRowView alloc] initWithFrame:CGRectMake(0, i * kHistoryRowPitch, self.bounds.size.width, kHistoryRowPitch)];
        row.delegate = self;
        [row configureWithTrack:_historyTracks[i] isHistory:YES rowIndex:(NSInteger)i];
        [_historyRowsContainerView addSubview:row];
        [_historyRowViews addObject:row];
    }

    for (UIView *v in _queueRowViews) [v removeFromSuperview];
    [_queueRowViews removeAllObjects];

    for (NSUInteger i = 0; i < _futureTracks.count; i++) {
        SGRQueueRowView *row = [[SGRQueueRowView alloc] initWithFrame:CGRectMake(0, i * kQueueRowPitch, self.bounds.size.width, kQueueRowPitch)];
        row.delegate = self;
        [row configureWithTrack:_futureTracks[i] isHistory:NO rowIndex:(NSInteger)i];
        [_queueRowsContainerView addSubview:row];
        [_queueRowViews addObject:row];
    }
}

#pragma mark - Layout, Dual Sticky Headers & Dynamic Clipping Planes

- (CGFloat)historyTotalHeight {
    if (_historyTracks.count == 0) return 0.0;
    return kHistoryHeaderHeight + _historyTracks.count * kHistoryRowPitch + kHistoryBottomGap;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 100.0 || h < 100.0) return;

    _grabberPill.frame = CGRectMake((w - kGrabberWidth) * 0.5, 0.0, kGrabberWidth, kGrabberHeight);

    CGFloat viewportH = MAX(100.0, h - kViewportTopOffset);
    _viewportClipView.frame = CGRectMake(0.0, kViewportTopOffset, w, viewportH);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _bottomFadeMask.frame = _viewportClipView.bounds;
    CGFloat fadeStart = MAX(0.75, (viewportH - 42.0) / viewportH);
    CGFloat fadeMid = MAX(0.85, (viewportH - 18.0) / viewportH);
    _bottomFadeMask.locations = @[@0.0, @(fadeStart), @(fadeMid), @1.0];
    [CATransaction commit];

    _scrollView.frame = _viewportClipView.bounds;

    CGFloat histH = [self historyTotalHeight];
    UIEdgeInsets targetInset = UIEdgeInsetsMake(histH, 0.0, 36.0, 0.0);
    if (!UIEdgeInsetsEqualToEdgeInsets(_scrollView.contentInset, targetInset)) {
        CGFloat prevOffset = _scrollView.contentOffset.y;
        _scrollView.contentInset = targetInset;
        if (_didSetInitialOffset) {
            _scrollView.contentOffset = CGPointMake(0, prevOffset);
        }
    }

    if (!_didSetInitialOffset) {
        _didSetInitialOffset = YES;
        _scrollView.contentOffset = CGPointZero; // Always open at scrollY = 0 (Now Playing + Continue Playing)
    }

    // Section 1: Now Playing Card (docY = 14.7, height = 85.0)
    _nowPlayingCard.frame = CGRectMake(0.0, kNowPlayingDocY, w, kNowPlayingHeight);
    _npArtView.frame = CGRectMake(20.0, 4.0, 62.0, 62.0);
    _npStarButton.frame = CGRectMake(w - 90.0, 19.0, 32.0, 32.0);
    _npMoreButton.frame = CGRectMake(w - 49.0, 19.0, 32.0, 32.0);

    CGFloat npTextLeft = 93.7;
    CGFloat npMaxRight = w - 98.0;
    CGFloat npAvailW = MAX(40.0, npMaxRight - npTextLeft);
    BOOL npHasExp = !_npExplicitView.hidden;
    CGFloat npBadgeW = npHasExp ? (13.5 + 5.0) : 0.0;
    CGSize npTitleNat = [_npTitleLabel sizeThatFits:CGSizeMake(npAvailW - npBadgeW, 24.0)];
    CGFloat npTitleW = MIN(npAvailW - npBadgeW, ceil(npTitleNat.width));
    _npTitleLabel.frame = CGRectMake(npTextLeft, 13.0, npTitleW, 21.0);
    if (npHasExp) {
        _npExplicitView.frame = CGRectMake(npTextLeft + npTitleW + 5.0, 17.0, 13.5, 13.5);
    }
    _npArtistLabel.frame = CGRectMake(npTextLeft, 36.0, npAvailW, 19.0);

    // Section 2 Header subviews: 4 pills (height = 36, cornerRadius = 18) + Continue Playing title & subtitle
    CGFloat pillsMargin = 20.0;
    CGFloat pillGap = 9.0;
    CGFloat pillW = (w - pillsMargin * 2.0 - pillGap * 3.0) / 4.0;
    NSArray<UIButton *> *pills = @[_shufflePill, _repeatPill, _autoplayPill, _transitionsPill];
    for (NSUInteger i = 0; i < pills.count; i++) {
        pills[i].frame = CGRectMake(pillsMargin + i * (pillW + pillGap), 0.0, pillW, 36.0);
    }
    _continueTitleLabel.frame = CGRectMake(20.0, 47.0, w - 40.0, 22.0);
    _continueSubtitleLabel.frame = CGRectMake(20.0, 69.0, w - 40.0, 18.0);

    // Section 0 Header subviews: "History" + "Clear"
    _historyTitleLabel.frame = CGRectMake(20.0, 10.0, 160.0, 24.0);
    _historyClearButton.frame = CGRectMake(w - 72.0, 6.0, 56.0, 32.0);

    // Position rows inside their containers
    for (NSUInteger i = 0; i < _historyRowViews.count; i++) {
        SGRQueueRowView *row = _historyRowViews[i];
        row.frame = CGRectMake(0.0, i * kHistoryRowPitch, w, kHistoryRowPitch);
    }
    for (NSUInteger i = 0; i < _queueRowViews.count; i++) {
        SGRQueueRowView *row = _queueRowViews[i];
        if (row == _draggingRow) continue;
        row.frame = CGRectMake(0.0, i * kQueueRowPitch, w, kQueueRowPitch);
    }

    CGFloat totalQueueBottom = kQueueRowsStartDocY + MAX((NSUInteger)1, _queueRowViews.count) * kQueueRowPitch + 24.0;
    CGFloat minScrollContentH = MAX(viewportH + 90.0, totalQueueBottom);
    _scrollView.contentSize = CGSizeMake(w, minScrollContentH);

    [self updateStickyHeadersAndClipping];
}

- (void)updateStickyHeadersAndClipping {
    CGFloat w = self.bounds.size.width;
    CGFloat scrollY = _scrollView.contentOffset.y;
    CGFloat histH = [self historyTotalHeight];

    // 1. Section 0: History Sticky Header + Push-Off Formula & Dynamic Row Clipping
    if (histH > 0.0) {
        _historyHeaderView.hidden = NO;
        _historyRowsClipView.hidden = NO;

        CGFloat histHeaderDocY = MIN(MAX(-histH + kHistoryHeaderPinOffset, scrollY + kHistoryHeaderPinOffset), kHistoryHeaderPushOffDocY);
        _historyHeaderView.frame = CGRectMake(0.0, histHeaderDocY, w, kHistoryHeaderHeight);

        CGFloat histClipTopDocY = CGRectGetMaxY(_historyHeaderView.frame);
        CGFloat histClipBottomDocY = 4.0;
        CGFloat clipH = MAX(0.0, histClipBottomDocY - histClipTopDocY);
        _historyRowsClipView.frame = CGRectMake(0.0, histClipTopDocY, w, clipH);

        CGFloat histFirstRowDocY = -histH + kHistoryHeaderHeight + 6.0;
        _historyRowsContainerView.frame = CGRectMake(0.0, histFirstRowDocY - histClipTopDocY, w, _historyRowViews.count * kHistoryRowPitch);
    } else {
        _historyHeaderView.hidden = YES;
        _historyRowsClipView.hidden = YES;
    }

    // 2. Section 2: Continue Playing Sticky Header & Dynamic Row Clipping at y = 175pt
    CGFloat queueHeaderDocY = MAX(kContinueHeaderDocY, scrollY + kContinueHeaderPinOffset);
    _continueHeaderView.frame = CGRectMake(0.0, queueHeaderDocY, w, kContinueHeaderHeight);

    CGFloat queueClipTopDocY = CGRectGetMaxY(_continueHeaderView.frame);
    CGFloat queueBottomDocY = kQueueRowsStartDocY + _queueRowViews.count * kQueueRowPitch + 120.0;
    CGFloat queueClipH = MAX(0.0, queueBottomDocY - queueClipTopDocY);
    _queueRowsClipView.frame = CGRectMake(0.0, queueClipTopDocY, w, queueClipH);
    _queueRowsContainerView.frame = CGRectMake(0.0, kQueueRowsStartDocY - queueClipTopDocY, w, _queueRowViews.count * kQueueRowPitch);
}

#pragma mark - Bidirectional Scroll-Stop Detent at scrollY = 0 (Clip 2)

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    for (SGRQueueRowView *row in _queueRowViews) {
        if (row.isSwipeParked) [row closeSwipeAnimated:YES];
    }
    _dragStartOffsetY = scrollView.contentOffset.y;
    // If user started dragging inside the Queue (scrollY > 1.5), clamp upward flings at scrollY = 0
    _clampAtZeroOnDeceleration = (_dragStartOffsetY > 1.5);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // If user started at scrollY <= 1.5 and actively pulls down into negative scrollY, unlock History pull-down
    if (scrollView.isTracking && _dragStartOffsetY <= 1.5 && scrollView.contentOffset.y < -2.0) {
        _clampAtZeroOnDeceleration = NO;
    }

    // Hard stop at scrollY = 0 with zero overshoot when decelerating upward from inside the Queue
    if (!scrollView.isTracking && _clampAtZeroOnDeceleration && scrollView.contentOffset.y < 0.0) {
        scrollView.contentOffset = CGPointZero;
        _clampAtZeroOnDeceleration = NO;
    }

    [self updateStickyHeadersAndClipping];
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset {
    CGFloat histH = [self historyTotalHeight];
    if (histH <= 0.0) {
        if (targetContentOffset->y < 0.0) targetContentOffset->y = 0.0;
        return;
    }

    CGFloat currentY = scrollView.contentOffset.y;

    // Case 1: Dragging started inside Queue (_dragStartOffsetY > 1.5) and flung upward toward top
    if (_dragStartOffsetY > 1.5) {
        if (targetContentOffset->y < 0.0) {
            targetContentOffset->y = 0.0;
            _clampAtZeroOnDeceleration = YES;
        }
        return;
    }

    // Case 2: Dragging started at Queue top (_dragStartOffsetY <= 1.5) and pulled down to reveal History
    if (_dragStartOffsetY >= -4.0 && currentY < -8.0 && velocity.y <= 0.15) {
        targetContentOffset->y = -histH;
        _clampAtZeroOnDeceleration = NO;
        return;
    }

    // Case 3: Dragging started inside History (_dragStartOffsetY < -4.0)
    if (_dragStartOffsetY < -4.0) {
        if (velocity.y > 1.35) {
            // High-velocity fling upward from History passes through scrollY = 0 into the Queue (Clip 2 Phase 5)
            _clampAtZeroOnDeceleration = NO;
        } else if (velocity.y >= -0.05 && (currentY > -histH * 0.78 || velocity.y > 0.20)) {
            // Moderate upward swipe from History snaps cleanly to scrollY = 0 detent (Clip 2 Phase 4)
            targetContentOffset->y = 0.0;
            _clampAtZeroOnDeceleration = YES;
        } else {
            // Stay open in History
            targetContentOffset->y = -histH;
            _clampAtZeroOnDeceleration = NO;
        }
    }
}

#pragma mark - 4-Pill Playback Controls & Now Playing Actions

- (void)stylePill:(UIButton *)pill active:(BOOL)active dimmedWhenOff:(BOOL)dimmed symbol:(NSString *)symbol customImage:(UIImage *)customImg {
    UIColor *bg = active ? [UIColor colorWithWhite:1.0 alpha:0.92] : [UIColor colorWithWhite:1.0 alpha:0.11];
    UIColor *fg = active ? [UIColor colorWithWhite:0.08 alpha:0.96] : (dimmed ? [UIColor colorWithWhite:1.0 alpha:0.35] : [UIColor colorWithWhite:1.0 alpha:0.92]);
    pill.backgroundColor = bg;
    if (customImg) {
        [pill setImage:[customImg imageWithTintColor:fg renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
    } else {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15.5 weight:UIImageSymbolWeightMedium];
        UIImage *img = [[UIImage systemImageNamed:symbol withConfiguration:cfg] imageWithTintColor:fg renderingMode:UIImageRenderingModeAlwaysOriginal];
        [pill setImage:img forState:UIControlStateNormal];
    }
}

- (void)updatePlaybackPillsWithState:(SPTPlayerState *)state {
    BOOL shuffling = NO;
    BOOL repeatTrack = NO;
    BOOL repeatContext = NO;
    if (state && [state respondsToSelector:@selector(options)]) {
        SPTPlayerOptions *opts = state.options;
        if (opts) {
            shuffling = opts.shufflingContext;
            repeatTrack = opts.repeatingTrack;
            repeatContext = opts.repeatingContext;
        }
    }
    [self stylePill:_shufflePill active:shuffling dimmedWhenOff:NO symbol:@"shuffle" customImage:nil];
    [self stylePill:_repeatPill active:(repeatTrack || repeatContext) dimmedWhenOff:NO symbol:(repeatTrack ? @"repeat.1" : @"repeat") customImage:nil];
    [self stylePill:_autoplayPill active:_autoplayEnabled dimmedWhenOff:YES symbol:@"infinity" customImage:nil];
    [self stylePill:_transitionsPill active:_transitionsEnabled dimmedWhenOff:NO symbol:nil customImage:SGRTransitionsGlyphImage(UIColor.whiteColor)];
}

- (void)handleShufflePillTap {
    SPTPlayerState *state = SGPlayerState();
    BOOL next = !(state.options.shufflingContext);
    id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
    @try {
        if ([player respondsToSelector:@selector(setShufflingContext:)]) {
            [player setShufflingContext:next];
        }
    } @catch (__unused NSException *e) {}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updatePlaybackPillsWithState:SGPlayerState()];
    });
}

- (void)handleRepeatPillTap {
    SPTPlayerState *state = SGPlayerState();
    BOOL repCtx = state.options.repeatingContext;
    BOOL repTrk = state.options.repeatingTrack;
    id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
    @try {
        if (!repCtx && !repTrk) {
            if ([player respondsToSelector:@selector(setRepeatingContext:)]) [player setRepeatingContext:YES];
        } else if (repCtx && !repTrk) {
            if ([player respondsToSelector:@selector(setRepeatingTrack:)]) [player setRepeatingTrack:YES];
        } else {
            if ([player respondsToSelector:@selector(setRepeatingTrack:)]) [player setRepeatingTrack:NO];
            if ([player respondsToSelector:@selector(setRepeatingContext:)]) [player setRepeatingContext:NO];
        }
    } @catch (__unused NSException *e) {}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updatePlaybackPillsWithState:SGPlayerState()];
    });
}

- (void)handleAutoplayPillTap {
    _autoplayEnabled = !_autoplayEnabled;
    [self updatePlaybackPillsWithState:SGPlayerState()];
}

- (void)handleTransitionsPillTap {
    _transitionsEnabled = !_transitionsEnabled;
    [self updatePlaybackPillsWithState:SGPlayerState()];
}

- (void)updateNowPlayingStarAppearance {
    NSString *npURI = SGURIString(_currentTrack.URI);
    BOOL starred = npURI.length ? [_starredURIs containsObject:npURI] : NO;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14.5 weight:UIImageSymbolWeightMedium];
    NSString *sym = starred ? @"star.fill" : @"star";
    UIImage *img = [[UIImage systemImageNamed:sym withConfiguration:cfg] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    [_npStarButton setImage:img forState:UIControlStateNormal];
}

- (void)handleNowPlayingStarTap {
    NSString *npURI = SGURIString(_currentTrack.URI);
    if (!npURI.length) return;
    if ([_starredURIs containsObject:npURI]) [_starredURIs removeObject:npURI];
    else [_starredURIs addObject:npURI];
    [self updateNowPlayingStarAppearance];
}

- (void)handleNowPlayingArtTap {
    SGRPlayerToggleQueue();
}

- (void)handleClearHistoryTap {
    if (_historyTracks.count == 0) return;
    _historyClearedByUser = YES;
    [_historyTracks removeAllObjects];
    for (UIView *v in _historyRowViews) [v removeFromSuperview];
    [_historyRowViews removeAllObjects];

    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_scrollView.contentInset = UIEdgeInsetsMake(0.0, 0.0, 36.0, 0.0);
        self->_scrollView.contentOffset = CGPointZero;
        [self updateStickyHeadersAndClipping];
    } completion:nil];
}

#pragma mark - SGRQueueRowViewDelegate (Tap, Swipe-to-Delete Collapse, Drag-to-Reorder)

- (void)queueRowWillBeginSwipe:(SGRQueueRowView *)row {
    for (SGRQueueRowView *other in _queueRowViews) {
        if (other != row && other.isSwipeParked) {
            [other closeSwipeAnimated:YES];
        }
    }
}

- (void)queueRowDidTap:(SGRQueueRowView *)row {
    SPTPlayerTrack *t = row.track;
    if (!t) return;
    id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();

    if (!row.isHistory) {
        @try {
            if ([player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) {
                [player skipToNextTrackWithOptions:nil track:t];
                return;
            }
            if (row.rowIndex == 0 && [player respondsToSelector:@selector(skipToNextTrack)]) {
                [player skipToNextTrack];
                return;
            }
        } @catch (__unused NSException *e) {}
    } else {
        @try {
            if ([player respondsToSelector:@selector(skipToPreviousTrackWithOptions:track:)]) {
                [player skipToPreviousTrackWithOptions:nil track:t];
                return;
            }
        } @catch (__unused NSException *e) {}
    }
    NSString *u = SGURIString(t.URI);
    if (u.length) SGOpenSpotifyURI([NSURL URLWithString:u]);
}

- (void)queueRowDidCommitDelete:(SGRQueueRowView *)row {
    NSUInteger idx = [_queueRowViews indexOfObject:row];
    if (idx == NSNotFound || idx >= _futureTracks.count) return;

    SPTPlayerTrack *removedTrack = _futureTracks[idx];
    NSString *key = [self keyForTrack:removedTrack];
    if (key.length) [_locallyDeletedKeys addObject:key];

    [_futureTracks removeObjectAtIndex:idx];
    [_queueRowViews removeObjectAtIndex:idx];

    for (NSUInteger i = 0; i < _queueRowViews.count; i++) {
        _queueRowViews[i].rowIndex = (NSInteger)i;
    }

    // Top-pinned flat-clip collapse (0.14s) while rows below slide up 56pt with ease-out (0.25s) per Clip 1
    CGFloat w = self.bounds.size.width;
    CGRect startFrame = row.frame;
    [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        row.frame = CGRectMake(startFrame.origin.x, startFrame.origin.y, w, 0.5);
        row.alpha = 0.25;
    } completion:^(BOOL finished) {
        [row removeFromSuperview];
    }];

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        for (NSUInteger i = idx; i < self->_queueRowViews.count; i++) {
            SGRQueueRowView *below = self->_queueRowViews[i];
            below.frame = CGRectMake(0.0, i * kQueueRowPitch, w, kQueueRowPitch);
        }
        [self updateStickyHeadersAndClipping];
    } completion:nil];
}

- (void)queueRowHandlePan:(UIPanGestureRecognizer *)pan forRow:(SGRQueueRowView *)row {
    if (row.isHistory) return;
    CGPoint locInContainer = [pan locationInView:_queueRowsContainerView];
    CGFloat w = self.bounds.size.width;

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            for (SGRQueueRowView *r in _queueRowViews) {
                if (r.isSwipeParked) [r closeSwipeAnimated:NO];
            }
            _draggingRow = row;
            _dragCurrentIndex = (NSInteger)[_queueRowViews indexOfObject:row];
            if (_dragCurrentIndex == NSNotFound) {
                _draggingRow = nil;
                return;
            }
            _dragGrabOffsetY = locInContainer.y - row.center.y;

            UIView *snap = [row snapshotViewAfterScreenUpdates:NO];
            snap.frame = row.frame;
            snap.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
            snap.layer.cornerRadius = 10.0;
            snap.layer.shadowColor = UIColor.blackColor.CGColor;
            snap.layer.shadowOpacity = 0.35;
            snap.layer.shadowRadius = 12.0;
            snap.layer.shadowOffset = CGSizeMake(0, 6);
            [_queueRowsContainerView addSubview:snap];
            _dragSnapshotView = snap;
            row.alpha = 0.0;

            UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [gen impactOccurred];

            [UIView animateWithDuration:0.18 animations:^{
                snap.transform = CGAffineTransformMakeScale(1.03, 1.03);
            }];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!_draggingRow || !_dragSnapshotView) return;
            CGFloat targetCenterY = locInContainer.y - _dragGrabOffsetY;
            CGFloat maxCenterY = MAX(kQueueRowPitch * 0.5, (_queueRowViews.count - 0.5) * kQueueRowPitch);
            targetCenterY = MIN(maxCenterY, MAX(kQueueRowPitch * 0.5, targetCenterY));
            _dragSnapshotView.center = CGPointMake(w * 0.5, targetCenterY);

            NSInteger hoverIndex = (NSInteger)floor(targetCenterY / kQueueRowPitch);
            hoverIndex = MAX(0, MIN((NSInteger)_queueRowViews.count - 1, hoverIndex));

            if (hoverIndex != _dragCurrentIndex) {
                SPTPlayerTrack *movedTrack = _futureTracks[_dragCurrentIndex];
                [_futureTracks removeObjectAtIndex:_dragCurrentIndex];
                [_futureTracks insertObject:movedTrack atIndex:hoverIndex];

                [_queueRowViews removeObjectAtIndex:_dragCurrentIndex];
                [_queueRowViews insertObject:_draggingRow atIndex:hoverIndex];

                _dragCurrentIndex = hoverIndex;
                UISelectionFeedbackGenerator *sel = [[UISelectionFeedbackGenerator alloc] init];
                [sel selectionChanged];

                [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                    for (NSUInteger i = 0; i < self->_queueRowViews.count; i++) {
                        SGRQueueRowView *r = self->_queueRowViews[i];
                        r.rowIndex = (NSInteger)i;
                        r.frame = CGRectMake(0.0, i * kQueueRowPitch, w, kQueueRowPitch);
                    }
                } completion:nil];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            if (!_draggingRow) return;
            SGRQueueRowView *finishedRow = _draggingRow;
            UIView *snap = _dragSnapshotView;
            CGRect finalFrame = CGRectMake(0.0, _dragCurrentIndex * kQueueRowPitch, w, kQueueRowPitch);
            _draggingRow = nil;
            _dragSnapshotView = nil;

            [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                snap.transform = CGAffineTransformIdentity;
                snap.frame = finalFrame;
                finishedRow.frame = finalFrame;
            } completion:^(BOOL finished) {
                finishedRow.alpha = 1.0;
                [snap removeFromSuperview];
            }];
            break;
        }
        default:
            break;
    }
}

#pragma mark - 1:1 Apple Music Long-Press Context Menu & Preview Card (Clip 1, 6.12-8.93s)

- (UIViewController *)previewControllerForTrack:(SPTPlayerTrack *)track artImage:(UIImage *)artImage {
    UIViewController *vc = [[UIViewController alloc] init];
    CGFloat cardW = 250.0;
    CGFloat cardH = 86.0;
    vc.preferredContentSize = CGSizeMake(cardW, cardH);
    vc.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.16 blue:0.15 alpha:0.96];

    UIImageView *art = [[UIImageView alloc] initWithFrame:CGRectMake(14.0, 15.0, 56.0, 56.0)];
    art.contentMode = UIViewContentModeScaleAspectFill;
    art.clipsToBounds = YES;
    art.layer.cornerRadius = 8.0;
    art.layer.cornerCurve = kCACornerCurveContinuous;
    art.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    art.image = artImage;
    NSURL *artURL = SGRQueueArtworkURLForTrack(track);
    if (!artImage && artURL) {
        SGRLoadQueueArtwork(artURL, ^(UIImage *loaded) {
            if (loaded) art.image = loaded;
        });
    }
    [vc.view addSubview:art];

    NSDictionary *meta = ([track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class]) ? track.metadata : nil;
    NSString *title = [track respondsToSelector:@selector(trackTitle)] ? track.trackTitle : (meta[@"title"] ?: @"Track");
    NSString *artist = [track respondsToSelector:@selector(artistName)] ? track.artistName : (meta[@"artist_name"] ?: @"");
    NSString *album = meta[@"album_title"] ?: @"";

    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(82.0, 16.0, 140.0, 19.0)];
    l1.text = title;
    l1.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    l1.textColor = UIColor.whiteColor;
    [vc.view addSubview:l1];

    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(82.0, 35.0, 140.0, 17.0)];
    l2.text = artist;
    l2.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    l2.textColor = [UIColor colorWithWhite:1.0 alpha:0.90];
    [vc.view addSubview:l2];

    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(82.0, 52.0, 140.0, 16.0)];
    l3.text = album;
    l3.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    l3.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    [vc.view addSubview:l3];

    UIImageSymbolConfiguration *chevCfg = [UIImageSymbolConfiguration configurationWithPointSize:12.5 weight:UIImageSymbolWeightSemibold];
    UIImageView *chev = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"chevron.right" withConfiguration:chevCfg] imageWithTintColor:[UIColor colorWithWhite:1.0 alpha:0.42] renderingMode:UIImageRenderingModeAlwaysOriginal]];
    chev.frame = CGRectMake(cardW - 22.0, (cardH - 14.0) * 0.5, 10.0, 14.0);
    chev.contentMode = UIViewContentModeScaleAspectFit;
    [vc.view addSubview:chev];

    return vc;
}

- (UIMenu *)buildAppleMusicMenuForTrack:(SPTPlayerTrack *)track row:(SGRQueueRowView *)row {
    if (!track) return nil;
    NSDictionary *meta = ([track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class]) ? track.metadata : nil;
    NSString *albumTitle = meta[@"album_title"] ?: @"";
    NSString *trackURI = SGURIString(track.URI);
    BOOL isStarred = trackURI.length ? [_starredURIs containsObject:trackURI] : NO;

    __weak typeof(self) weakSelf = self;

    // Top 3-button row (Download, Favorite, Share) with UIMenuElementSizeMedium
    UIAction *downloadAct = [UIAction actionWithTitle:@"Download" image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:nil handler:^(__kindof UIAction *action) {}];
    UIAction *favoriteAct = [UIAction actionWithTitle:@"Favorite" image:[UIImage systemImageNamed:isStarred ? @"star.fill" : @"star"] identifier:nil handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !trackURI.length) return;
        if ([strongSelf->_starredURIs containsObject:trackURI]) [strongSelf->_starredURIs removeObject:trackURI];
        else [strongSelf->_starredURIs addObject:trackURI];
        [strongSelf updateNowPlayingStarAppearance];
    }];
    UIAction *shareAct = [UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !trackURI.length) return;
        UIViewController *top = strongSelf.window.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        if (top) {
            UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[trackURI] applicationActivities:nil];
            [top presentViewController:avc animated:YES completion:nil];
        }
    }];
    UIMenu *topRowMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[downloadAct, favoriteAct, shareAct]];
    if (@available(iOS 16.0, *)) {
        topRowMenu.preferredElementSize = UIMenuElementSizeMedium;
    }

    // Standard Action Rows
    NSMutableArray<UIMenuElement *> *mainActions = [NSMutableArray array];

    UIAction *addPlaylistAct = [UIAction actionWithTitle:@"Add to a Playlist…" image:[UIImage systemImageNamed:@"text.badge.plus"] identifier:nil handler:^(__kindof UIAction *action) {
        if (trackURI.length) SGOpenSpotifyURI([NSURL URLWithString:trackURI]);
    }];
    [mainActions addObject:addPlaylistAct];

    if (row && !row.isHistory) {
        UIAction *moveTopAct = [UIAction actionWithTitle:@"Move to the Top" image:[UIImage systemImageNamed:@"text.line.first.and.arrowtriangle.forward"] identifier:nil handler:^(__kindof UIAction *action) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSUInteger idx = [strongSelf->_queueRowViews indexOfObject:row];
            if (idx != NSNotFound && idx > 0 && idx < strongSelf->_futureTracks.count) {
                SPTPlayerTrack *t = strongSelf->_futureTracks[idx];
                [strongSelf->_futureTracks removeObjectAtIndex:idx];
                [strongSelf->_futureTracks insertObject:t atIndex:0];
                [strongSelf->_queueRowViews removeObjectAtIndex:idx];
                [strongSelf->_queueRowViews insertObject:row atIndex:0];
                [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                    for (NSUInteger i = 0; i < strongSelf->_queueRowViews.count; i++) {
                        strongSelf->_queueRowViews[i].rowIndex = (NSInteger)i;
                        strongSelf->_queueRowViews[i].frame = CGRectMake(0.0, i * kQueueRowPitch, strongSelf.bounds.size.width, kQueueRowPitch);
                    }
                } completion:nil];
            }
        }];
        [mainActions addObject:moveTopAct];
    }

    UIAction *goAlbumAct = [UIAction actionWithTitle:@"Go to Album" image:[UIImage systemImageNamed:@"square.stack"] identifier:nil handler:^(__kindof UIAction *action) {
        NSString *albumURI = meta[@"album_uri"] ?: meta[@"context_uri"];
        if (albumURI.length) SGOpenSpotifyURI([NSURL URLWithString:albumURI]);
    }];
    if (@available(iOS 15.0, *)) {
        if (albumTitle.length) goAlbumAct.subtitle = albumTitle;
    }
    [mainActions addObject:goAlbumAct];

    UIAction *suggestLessAct = [UIAction actionWithTitle:@"Suggest Less" image:[UIImage systemImageNamed:@"hand.thumbsdown"] identifier:nil handler:^(__kindof UIAction *action) {}];
    [mainActions addObject:suggestLessAct];

    UIMenu *middleMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:mainActions];

    // Destructive Delete / Remove Row
    UIAction *deleteAct = [UIAction actionWithTitle:@"Delete from Library" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__kindof UIAction *action) {
        if (row && !row.isHistory) {
            [weakSelf queueRowDidCommitDelete:row];
        }
    }];
    deleteAct.attributes = UIMenuElementAttributesDestructive;
    UIMenu *destructiveMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[deleteAct]];

    return [UIMenu menuWithTitle:@"" children:@[topRowMenu, middleMenu, destructiveMenu]];
}

- (UIViewController *)queueRowPreviewControllerForRow:(SGRQueueRowView *)row {
    return [self previewControllerForTrack:row.track artImage:row.artView.image];
}

- (UIMenu *)queueRowContextMenuForRow:(SGRQueueRowView *)row {
    return [self buildAppleMusicMenuForTrack:row.track row:row];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    if (!_currentTrack) return nil;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:^UIViewController * _Nullable{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        return [strongSelf previewControllerForTrack:strongSelf->_currentTrack artImage:strongSelf->_npArtView.image];
    } actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        return [strongSelf buildAppleMusicMenuForTrack:strongSelf->_currentTrack row:nil];
    }];
}

@end

// Apple Music style inline queue view for the redesigned player.
// Shows history (pull-down), currently playing track with star & more options,
// 4 Apple Music pill buttons (pinned on scroll), and upcoming tracks ("Continue Playing")
// with explicit badges, artwork thumbnails, grabber handles, swipe-to-delete,
// drag-to-reorder, and 1:1 Apple Music context menus.

#import "Redesigned/Player/SGRQueueView.h"
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Core/SGPrefs.h"
#import "Core/SGGlass.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Headers/SPTPlayer.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Shared/HeadGestures/HeadGestures.h"
#import "Shared/Navigation/Links.h"
#import "Redesigned/Player/Player.h"
#import "Settings/SGPageStyle.h"

static const CGFloat kSideMargin = 20.0;
static const CGFloat kThumbSide = 42.0;
static const CGFloat kCurrentThumbSide = 52.0;
static const CGFloat kRowHeight = 56.0;
static const CGFloat kCurrentRowHeight = 68.0;
static const CGFloat kPillsHeight = 36.0;
static const CGFloat kQueueHeaderHeight = 104.0;
static const CGFloat kHistoryHeaderHeight = 44.0;

#define SGKeyQueueAutoplay @"spotifyglass.queue.autoplay"

typedef NS_ENUM(NSInteger, SGRQueueSection) {
    SGRQueueSectionHistory = 0,
    SGRQueueSectionCurrent = 1,
    SGRQueueSectionQueue   = 2,
    SGRQueueSectionCount   = 3,
};

static NSCache<NSString *, UIImage *> *sg_queueImageCache;

static NSURL *queueArtworkURLForTrack(SPTPlayerTrack *track) {
    if (!track) return nil;
    NSDictionary *metadata = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *field in @[@"image_small_url", @"image_url", @"image_large_url", @"image_xlarge_url"]) {
        NSString *val = metadata[field];
        if (![val isKindOfClass:NSString.class] || !val.length) continue;
        NSString *local = SGLocalFileCoverInURL(val);
        if (local.length) return [NSURL fileURLWithPath:local];
        if ([val hasPrefix:@"https://"] || [val hasPrefix:@"http://"]) return [NSURL URLWithString:val];
        if ([val hasPrefix:@"spotify:image:"]) {
            NSString *ident = [val substringFromIndex:@"spotify:image:".length];
            return [NSURL URLWithString:[@"https://i.scdn.co/image/" stringByAppendingString:ident]];
        }
    }
    return nil;
}

static BOOL trackIsExplicit(SPTPlayerTrack *track) {
    if (!track) return NO;
    NSDictionary *m = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    if (![m isKindOfClass:NSDictionary.class]) return NO;
    id val = m[@"is_explicit"] ?: m[@"explicit"];
    if ([val respondsToSelector:@selector(boolValue)]) return [val boolValue];
    if ([val isKindOfClass:NSString.class]) return [val isEqualToString:@"true"] || [val isEqualToString:@"1"];
    return NO;
}

static void loadArtworkForTrack(SPTPlayerTrack *track, UIImageView *imageView, void (^done)(UIImage *)) {
    if (!track) return;
    id uri = track.URI;
    NSString *uriString = [uri isKindOfClass:NSURL.class] ? [(NSURL *)uri absoluteString] : ([uri isKindOfClass:NSString.class] ? uri : nil);
    UIImage *cached = uriString ? [sg_queueImageCache objectForKey:uriString] : nil;
    if (cached) {
        imageView.image = cached;
        if (done) done(cached);
        return;
    }

    UIImageSymbolConfiguration *noteConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightRegular];
    UIImage *noteSymbol = [UIImage systemImageNamed:@"music.note" withConfiguration:noteConfig];
    imageView.image = [noteSymbol imageWithTintColor:SGRTertiary() renderingMode:UIImageRenderingModeAlwaysOriginal];

    NSURL *url = queueArtworkURLForTrack(track);
    if (!url) return;

    __weak UIImageView *weakView = imageView;
    NSString *expectedURI = uriString;
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data.length || error) return;
        UIImage *downloaded = [UIImage imageWithData:data];
        if (!downloaded) return;
        if (expectedURI) [sg_queueImageCache setObject:downloaded forKey:expectedURI];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImageView *strongView = weakView;
            if (strongView) {
                if (SGRReduceMotion()) {
                    strongView.image = downloaded;
                } else {
                    [UIView transitionWithView:strongView duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                        strongView.image = downloaded;
                    } completion:nil];
                }
            }
            if (done) done(downloaded);
        });
    }] resume];
}

#pragma mark - Pill Button

@interface SGRQueuePillButton : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, copy) void (^onTap)(void);
- (void)setSymbol:(NSString *)symbol;
@end

@implementation SGRQueuePillButton

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.layer.cornerRadius = frame.size.height > 0 ? frame.size.height / 2.0 : 18.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];

    _iconView = [[UIImageView alloc] initWithFrame:self.bounds];
    _iconView.contentMode = UIViewContentModeCenter;
    _iconView.userInteractionEnabled = NO;
    _iconView.tintColor = SGRSecondary();
    _iconView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_iconView];

    [self addTarget:self action:@selector(touchUpInside) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)setSymbol:(NSString *)symbol {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular];
    UIImage *img = [UIImage systemImageNamed:symbol withConfiguration:config];
    _iconView.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (void)setIsActive:(BOOL)isActive {
    _isActive = isActive;
    void (^apply)(void) = ^{
        self.backgroundColor = isActive ? [UIColor colorWithWhite:1.0 alpha:0.25] : [UIColor colorWithWhite:1.0 alpha:0.08];
        self.iconView.tintColor = isActive ? SGRPrimary() : SGRSecondary();
    };
    if (self.window && !SGRReduceMotion()) {
        [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:apply completion:nil];
    } else {
        apply();
    }
}

- (void)touchUpInside {
    if (self.onTap) self.onTap();
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    void (^apply)(void) = ^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.94, 0.94) : CGAffineTransformIdentity;
        self.alpha = highlighted ? 0.75 : 1.0;
    };
    if (!SGRReduceMotion()) {
        [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:apply completion:nil];
    } else {
        apply();
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.height / 2.0;
}

@end

#pragma mark - Current Track Cell

@interface SGRQueueCurrentTrackCell : UITableViewCell
@property (nonatomic, readonly) UIImageView *coverImageView;
@property (nonatomic, readonly) UILabel *titleLabel;
@property (nonatomic, readonly) UIView *explicitBadge;
@property (nonatomic, readonly) UILabel *artistLabel;
@property (nonatomic, readonly) UIButton *starButton;
@property (nonatomic, readonly) UIButton *moreButton;
@property (nonatomic, copy) NSString *representedTrackURI;
@property (nonatomic, copy) void (^onStarTap)(void);
- (void)configureWithTrack:(SPTPlayerTrack *)track;
- (void)setStarred:(BOOL)starred animated:(BOOL)animated;
@end

@implementation SGRQueueCurrentTrackCell {
    UIImageView *_coverImageView;
    UILabel *_titleLabel;
    UIView *_explicitBadge;
    UILabel *_explicitLabel;
    UILabel *_artistLabel;
    UIButton *_starButton;
    UIButton *_moreButton;
    BOOL _isStarred;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _coverImageView = [UIImageView new];
    _coverImageView.contentMode = UIViewContentModeScaleAspectFill;
    _coverImageView.clipsToBounds = YES;
    _coverImageView.layer.cornerRadius = 6.0;
    _coverImageView.layer.cornerCurve = kCACornerCurveContinuous;
    _coverImageView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    [self.contentView addSubview:_coverImageView];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];
    _titleLabel.textColor = SGRPrimary();
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_titleLabel];

    _explicitBadge = [UIView new];
    _explicitBadge.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    _explicitBadge.layer.cornerRadius = 2.5;
    _explicitBadge.layer.cornerCurve = kCACornerCurveContinuous;
    _explicitBadge.clipsToBounds = YES;
    _explicitBadge.hidden = YES;
    [self.contentView addSubview:_explicitBadge];

    _explicitLabel = [UILabel new];
    _explicitLabel.text = @"E";
    _explicitLabel.font = [UIFont boldSystemFontOfSize:8.5];
    _explicitLabel.textColor = SGRSecondary();
    _explicitLabel.textAlignment = NSTextAlignmentCenter;
    [_explicitBadge addSubview:_explicitLabel];

    _artistLabel = [UILabel new];
    _artistLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    _artistLabel.textColor = SGRSecondary();
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_artistLabel];

    UIImageSymbolConfiguration *btnConfig = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightRegular];

    _starButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_starButton setImage:[UIImage systemImageNamed:@"star" withConfiguration:btnConfig] forState:UIControlStateNormal];
    _starButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    [_starButton addTarget:self action:@selector(starTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_starButton];

    _moreButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_moreButton setImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:btnConfig] forState:UIControlStateNormal];
    _moreButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    if (@available(iOS 14.0, *)) {
        _moreButton.showsMenuAsPrimaryAction = YES;
    }
    [self.contentView addSubview:_moreButton];

    return self;
}

- (void)starTapped {
    [self setStarred:!_isStarred animated:YES];
    if (self.onStarTap) self.onStarTap();
}

- (void)setStarred:(BOOL)starred animated:(BOOL)animated {
    _isStarred = starred;
    UIImageSymbolConfiguration *btnConfig = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightRegular];
    UIImage *img = [UIImage systemImageNamed:starred ? @"star.fill" : @"star" withConfiguration:btnConfig];
    [_starButton setImage:img forState:UIControlStateNormal];
    _starButton.tintColor = starred ? [UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:0.45];

    if (animated && !SGRReduceMotion()) {
        _starButton.transform = CGAffineTransformMakeScale(1.3, 1.3);
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.8 options:0 animations:^{
            self->_starButton.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

- (void)configureWithTrack:(SPTPlayerTrack *)track {
    _titleLabel.text = track.trackTitle ?: @"Unknown Title";
    _artistLabel.text = track.artistName ?: @"Unknown Artist";

    BOOL isExp = trackIsExplicit(track);
    _explicitBadge.hidden = !isExp;

    id uri = track.URI;
    NSString *uriString = [uri isKindOfClass:NSURL.class] ? [(NSURL *)uri absoluteString] : ([uri isKindOfClass:NSString.class] ? uri : nil);
    self.representedTrackURI = uriString;

    NSDictionary *meta = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    id inCol = [meta isKindOfClass:NSDictionary.class] ? (meta[@"in_collection"] ?: meta[@"is_liked"]) : nil;
    BOOL isLiked = [inCol respondsToSelector:@selector(boolValue)] ? [inCol boolValue] : NO;
    [self setStarred:isLiked animated:NO];

    loadArtworkForTrack(track, _coverImageView, nil);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;

    CGFloat thumbY = round((h - kCurrentThumbSide) / 2.0);
    _coverImageView.frame = CGRectMake(kSideMargin, thumbY, kCurrentThumbSide, kCurrentThumbSide);

    CGFloat btnSide = 36.0;
    CGFloat btnY = round((h - btnSide) / 2.0);
    _moreButton.frame = CGRectMake(w - kSideMargin - btnSide, btnY, btnSide, btnSide);
    _starButton.frame = CGRectMake(CGRectGetMinX(_moreButton.frame) - btnSide - 6.0, btnY, btnSide, btnSide);

    CGFloat textX = CGRectGetMaxX(_coverImageView.frame) + 12.0;
    CGFloat maxTextW = MAX(0, CGRectGetMinX(_starButton.frame) - textX - 8.0);

    CGFloat badgeW = 14.0, badgeH = 14.0, badgeGap = 5.0;
    BOOL isExp = !_explicitBadge.hidden;
    CGFloat titleAvailableW = isExp ? MAX(0, maxTextW - badgeW - badgeGap) : maxTextW;

    CGSize titleSize = [_titleLabel sizeThatFits:CGSizeMake(titleAvailableW, CGFLOAT_MAX)];
    CGFloat titleW = MIN(titleSize.width, titleAvailableW);

    CGSize artistSize = [_artistLabel sizeThatFits:CGSizeMake(maxTextW, CGFLOAT_MAX)];
    CGFloat totalTextH = titleSize.height + artistSize.height + 3.0;
    CGFloat textY = round((h - totalTextH) / 2.0);

    _titleLabel.frame = CGRectMake(textX, textY, titleW, titleSize.height);

    if (isExp) {
        CGFloat badgeY = textY + round((titleSize.height - badgeH) / 2.0);
        _explicitBadge.frame = CGRectMake(CGRectGetMaxX(_titleLabel.frame) + badgeGap, badgeY, badgeW, badgeH);
        _explicitLabel.frame = _explicitBadge.bounds;
    }

    _artistLabel.frame = CGRectMake(textX, CGRectGetMaxY(_titleLabel.frame) + 3.0, maxTextW, artistSize.height);
}

@end

#pragma mark - Track Cell (History & Queue)

@interface SGRQueueTrackCell : UITableViewCell
@property (nonatomic, readonly) UIImageView *coverImageView;
@property (nonatomic, readonly) UILabel *titleLabel;
@property (nonatomic, readonly) UIView *explicitBadge;
@property (nonatomic, readonly) UILabel *artistLabel;
@property (nonatomic, readonly) UIImageView *reorderImageView;
@property (nonatomic, assign) BOOL isHistoryRow;
@property (nonatomic, copy) NSString *representedTrackURI;
- (void)configureWithTrack:(SPTPlayerTrack *)track isHistory:(BOOL)isHistory;
@end

@implementation SGRQueueTrackCell {
    UIImageView *_coverImageView;
    UILabel *_titleLabel;
    UIView *_explicitBadge;
    UILabel *_explicitLabel;
    UILabel *_artistLabel;
    UIImageView *_reorderImageView;
    UIView *_hairline;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _coverImageView = [UIImageView new];
    _coverImageView.contentMode = UIViewContentModeScaleAspectFill;
    _coverImageView.clipsToBounds = YES;
    _coverImageView.layer.cornerRadius = 5.0;
    _coverImageView.layer.cornerCurve = kCACornerCurveContinuous;
    _coverImageView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    [self.contentView addSubview:_coverImageView];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    _titleLabel.textColor = SGRPrimary();
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_titleLabel];

    _explicitBadge = [UIView new];
    _explicitBadge.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    _explicitBadge.layer.cornerRadius = 2.5;
    _explicitBadge.layer.cornerCurve = kCACornerCurveContinuous;
    _explicitBadge.clipsToBounds = YES;
    _explicitBadge.hidden = YES;
    [self.contentView addSubview:_explicitBadge];

    _explicitLabel = [UILabel new];
    _explicitLabel.text = @"E";
    _explicitLabel.font = [UIFont boldSystemFontOfSize:8.5];
    _explicitLabel.textColor = SGRSecondary();
    _explicitLabel.textAlignment = NSTextAlignmentCenter;
    [_explicitBadge addSubview:_explicitLabel];

    _artistLabel = [UILabel new];
    _artistLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    _artistLabel.textColor = SGRSecondary();
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_artistLabel];

    UIImageSymbolConfiguration *reorderConfig = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    UIImage *reorderImg = [UIImage systemImageNamed:@"line.3.horizontal" withConfiguration:reorderConfig];
    _reorderImageView = [[UIImageView alloc] initWithImage:[reorderImg imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    _reorderImageView.contentMode = UIViewContentModeCenter;
    _reorderImageView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    [self.contentView addSubview:_reorderImageView];

    _hairline = [UIView new];
    _hairline.backgroundColor = SGRHairline();
    [self.contentView addSubview:_hairline];

    return self;
}

- (void)configureWithTrack:(SPTPlayerTrack *)track isHistory:(BOOL)isHistory {
    _isHistoryRow = isHistory;
    _reorderImageView.hidden = isHistory;

    _titleLabel.text = track.trackTitle ?: @"Unknown Title";
    _artistLabel.text = track.artistName ?: @"Unknown Artist";

    BOOL isExp = trackIsExplicit(track);
    _explicitBadge.hidden = !isExp;

    id uri = track.URI;
    NSString *uriString = [uri isKindOfClass:NSURL.class] ? [(NSURL *)uri absoluteString] : ([uri isKindOfClass:NSString.class] ? uri : nil);
    self.representedTrackURI = uriString;

    loadArtworkForTrack(track, _coverImageView, nil);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;

    CGFloat thumbY = round((h - kThumbSide) / 2.0);
    _coverImageView.frame = CGRectMake(kSideMargin, thumbY, kThumbSide, kThumbSide);

    CGFloat reorderW = 22.0, reorderH = 22.0;
    _reorderImageView.frame = CGRectMake(w - kSideMargin - reorderW, round((h - reorderH) / 2.0), reorderW, reorderH);

    CGFloat textX = CGRectGetMaxX(_coverImageView.frame) + 12.0;
    CGFloat rightBoundary = _isHistoryRow ? (w - kSideMargin) : CGRectGetMinX(_reorderImageView.frame) - 10.0;
    CGFloat maxTextW = MAX(0, rightBoundary - textX);

    CGFloat badgeW = 14.0, badgeH = 14.0, badgeGap = 5.0;
    BOOL isExp = !_explicitBadge.hidden;
    CGFloat titleAvailableW = isExp ? MAX(0, maxTextW - badgeW - badgeGap) : maxTextW;

    CGSize titleSize = [_titleLabel sizeThatFits:CGSizeMake(titleAvailableW, CGFLOAT_MAX)];
    CGFloat titleW = MIN(titleSize.width, titleAvailableW);

    CGSize artistSize = [_artistLabel sizeThatFits:CGSizeMake(maxTextW, CGFLOAT_MAX)];
    CGFloat totalTextH = titleSize.height + artistSize.height + 2.0;
    CGFloat textY = round((h - totalTextH) / 2.0);

    _titleLabel.frame = CGRectMake(textX, textY, titleW, titleSize.height);

    if (isExp) {
        CGFloat badgeY = textY + round((titleSize.height - badgeH) / 2.0);
        _explicitBadge.frame = CGRectMake(CGRectGetMaxX(_titleLabel.frame) + badgeGap, badgeY, badgeW, badgeH);
        _explicitLabel.frame = _explicitBadge.bounds;
    }

    _artistLabel.frame = CGRectMake(textX, CGRectGetMaxY(_titleLabel.frame) + 2.0, maxTextW, artistSize.height);

    CGFloat pixel = 1.0 / (self.window.screen.scale ?: 2.0);
    _hairline.frame = CGRectMake(textX, h - pixel, w - textX - kSideMargin, pixel);
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    void (^apply)(void) = ^{
        self.contentView.backgroundColor = highlighted ? [UIColor colorWithWhite:1.0 alpha:0.12] : UIColor.clearColor;
    };
    if (animated && !SGRReduceMotion()) {
        [UIView animateWithDuration:0.15 animations:apply];
    } else {
        apply();
    }
}

@end

#pragma mark - SGRQueueView

@interface SGRQueueView () <UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate, UITableViewDropDelegate>
@end

@implementation SGRQueueView {
    UIView *_topGrabber;
    UITableView *_tableView;
    UILabel *_emptyLabel;

    // Header views
    UIView *_historyHeaderView;
    UIButton *_historyClearButton;

    UIView *_queueHeaderView;
    UIVisualEffectView *_queueHeaderBlur;
    UIView *_pillsContainer;
    SGRQueuePillButton *_shufflePill;
    SGRQueuePillButton *_repeatPill;
    SGRQueuePillButton *_autoplayPill;
    SGRQueuePillButton *_automixPill;
    UILabel *_queueTitleLabel;
    UILabel *_queueSubtitleLabel;
    UIButton *_queueClearButton;

    // Data models
    SPTPlayerTrack *_currentTrack;
    NSArray<SPTPlayerTrack *> *_historyTracks;
    NSArray<SPTPlayerTrack *> *_futureTracks;
    BOOL _historyCleared;
    BOOL _hasScrolledToCurrent;
    NSString *_lastTrackURI;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = YES;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_queueImageCache = [NSCache new];
        sg_queueImageCache.countLimit = 200;
    });

    _historyTracks = @[];
    _futureTracks = @[];

    [self buildTopGrabber];
    [self buildHistoryHeader];
    [self buildQueueHeader];
    [self buildTableView];

    SGAddPlayerStateObserver(self);
    [self reloadTracks];
    return self;
}

- (void)buildTopGrabber {
    _topGrabber = [UIView new];
    _topGrabber.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.32];
    _topGrabber.layer.cornerRadius = 2.5;
    _topGrabber.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_topGrabber];
}

- (void)buildHistoryHeader {
    _historyHeaderView = [UIView new];
    _historyHeaderView.backgroundColor = UIColor.clearColor;

    UILabel *histTitle = [UILabel new];
    histTitle.text = @"History";
    histTitle.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    histTitle.textColor = SGRPrimary();
    histTitle.tag = 1001;
    [_historyHeaderView addSubview:histTitle];

    _historyClearButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_historyClearButton setTitle:@"Clear" forState:UIControlStateNormal];
    [_historyClearButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.5] forState:UIControlStateNormal];
    [_historyClearButton setTitleColor:SGRPrimary() forState:UIControlStateHighlighted];
    _historyClearButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    [_historyClearButton addTarget:self action:@selector(clearHistoryTapped) forControlEvents:UIControlEventTouchUpInside];
    [_historyHeaderView addSubview:_historyClearButton];
}

- (void)clearHistoryTapped {
    _historyCleared = YES;
    _historyTracks = @[];
    if (!SGRReduceMotion()) {
        [_tableView reloadSections:[NSIndexSet indexSetWithIndex:SGRQueueSectionHistory] withRowAnimation:UITableViewRowAnimationFade];
    } else {
        [_tableView reloadData];
    }
}

- (void)buildQueueHeader {
    _queueHeaderView = [UIView new];
    _queueHeaderView.backgroundColor = UIColor.clearColor;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    _queueHeaderBlur = [[UIVisualEffectView alloc] initWithEffect:blur];
    _queueHeaderBlur.alpha = 0.94;
    [_queueHeaderView addSubview:_queueHeaderBlur];

    _pillsContainer = [UIView new];
    _pillsContainer.backgroundColor = UIColor.clearColor;
    [_queueHeaderView addSubview:_pillsContainer];

    __weak typeof(self) weakSelf = self;

    _shufflePill = [[SGRQueuePillButton alloc] initWithFrame:CGRectZero];
    [_shufflePill setSymbol:@"shuffle"];
    _shufflePill.onTap = ^{
        SGRQueueView *strongSelf = weakSelf;
        if (!strongSelf) return;
        id player = SGPlayer();
        SPTPlayerState *state = SGPlayerState();
        SPTPlayerOptions *opts = [state respondsToSelector:@selector(options)] ? state.options : nil;
        BOOL nextVal = !opts.shufflingContext;
        if ([player respondsToSelector:@selector(setShufflingContext:)]) {
            [(id<SPTPlayer>)player setShufflingContext:nextVal];
        }
        [strongSelf->_shufflePill setIsActive:nextVal];
    };
    [_pillsContainer addSubview:_shufflePill];

    _repeatPill = [[SGRQueuePillButton alloc] initWithFrame:CGRectZero];
    [_repeatPill setSymbol:@"repeat"];
    _repeatPill.onTap = ^{
        SGRQueueView *strongSelf = weakSelf;
        if (!strongSelf) return;
        id player = SGPlayer();
        SPTPlayerState *state = SGPlayerState();
        SPTPlayerOptions *opts = [state respondsToSelector:@selector(options)] ? state.options : nil;
        if (opts.repeatingTrack) {
            if ([player respondsToSelector:@selector(setRepeatingTrack:)]) [(id<SPTPlayer>)player setRepeatingTrack:NO];
            if ([player respondsToSelector:@selector(setRepeatingContext:)]) [(id<SPTPlayer>)player setRepeatingContext:NO];
            [strongSelf->_repeatPill setSymbol:@"repeat"];
            [strongSelf->_repeatPill setIsActive:NO];
        } else if (opts.repeatingContext) {
            if ([player respondsToSelector:@selector(setRepeatingTrack:)]) [(id<SPTPlayer>)player setRepeatingTrack:YES];
            [strongSelf->_repeatPill setSymbol:@"repeat.1"];
            [strongSelf->_repeatPill setIsActive:YES];
        } else {
            if ([player respondsToSelector:@selector(setRepeatingContext:)]) [(id<SPTPlayer>)player setRepeatingContext:YES];
            [strongSelf->_repeatPill setSymbol:@"repeat"];
            [strongSelf->_repeatPill setIsActive:YES];
        }
    };
    [_pillsContainer addSubview:_repeatPill];

    _autoplayPill = [[SGRQueuePillButton alloc] initWithFrame:CGRectZero];
    [_autoplayPill setSymbol:@"infinity"];
    _autoplayPill.onTap = ^{
        SGRQueueView *strongSelf = weakSelf;
        if (!strongSelf) return;
        BOOL current = SGFlag(SGKeyQueueAutoplay, YES);
        SGSetEnabled(SGKeyQueueAutoplay, !current);
        [strongSelf->_autoplayPill setIsActive:!current];
    };
    [_pillsContainer addSubview:_autoplayPill];

    _automixPill = [[SGRQueuePillButton alloc] initWithFrame:CGRectZero];
    UIImage *waveImg = [UIImage systemImageNamed:@"point.topleft.down.curvedto.point.bottomright.up"];
    [_automixPill setSymbol:waveImg ? @"point.topleft.down.curvedto.point.bottomright.up" : @"arrow.triangle.merge"];
    _automixPill.onTap = ^{
        SGRQueueView *strongSelf = weakSelf;
        if (!strongSelf) return;
        BOOL nextVal = !SGFlag(SGKeyAutoMix, NO);
        SGAutoMixApply(nextVal);
        [strongSelf->_automixPill setIsActive:nextVal];
    };
    [_pillsContainer addSubview:_automixPill];

    _queueTitleLabel = [UILabel new];
    _queueTitleLabel.text = @"Continue Playing";
    _queueTitleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    _queueTitleLabel.textColor = SGRPrimary();
    [_queueHeaderView addSubview:_queueTitleLabel];

    _queueSubtitleLabel = [UILabel new];
    _queueSubtitleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    _queueSubtitleLabel.textColor = SGRSecondary();
    [_queueHeaderView addSubview:_queueSubtitleLabel];

    _queueClearButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_queueClearButton setTitle:@"Clear" forState:UIControlStateNormal];
    [_queueClearButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.5] forState:UIControlStateNormal];
    [_queueClearButton setTitleColor:SGRPrimary() forState:UIControlStateHighlighted];
    _queueClearButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    [_queueClearButton addTarget:self action:@selector(clearQueueTapped) forControlEvents:UIControlEventTouchUpInside];
    [_queueHeaderView addSubview:_queueClearButton];
}

- (void)clearQueueTapped {
    _futureTracks = @[];
    _emptyLabel.hidden = (_currentTrack != nil);
    _queueClearButton.hidden = YES;
    if (!SGRReduceMotion()) {
        [_tableView reloadSections:[NSIndexSet indexSetWithIndex:SGRQueueSectionQueue] withRowAnimation:UITableViewRowAnimationFade];
    } else {
        [_tableView reloadData];
    }
}

- (void)buildTableView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.dragDelegate = self;
    _tableView.dropDelegate = self;
    _tableView.dragInteractionEnabled = YES;
    _tableView.showsVerticalScrollIndicator = YES;
    _tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, 110.0, 0);
    _tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, 110.0, 0);

    [_tableView registerClass:SGRQueueCurrentTrackCell.class forCellReuseIdentifier:@"CurrentTrackCell"];
    [_tableView registerClass:SGRQueueTrackCell.class forCellReuseIdentifier:@"TrackCell"];
    [self addSubview:_tableView];

    _emptyLabel = [UILabel new];
    _emptyLabel.text = @"No Upcoming Tracks";
    _emptyLabel.font = SGRFont(UIFontTextStyleHeadline, UIFontWeightMedium, UIContentSizeCategoryAccessibilityMedium);
    _emptyLabel.textColor = SGRSecondary();
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.hidden = YES;
    [self addSubview:_emptyLabel];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 1 || h < 1) return;

    // Top grabber
    CGFloat grabberW = 36.0, grabberH = 5.0;
    _topGrabber.frame = CGRectMake(round((w - grabberW) / 2.0), 8.0, grabberW, grabberH);

    // Table view
    CGFloat tableY = 16.0;
    _tableView.frame = CGRectMake(0, tableY, w, MAX(0, h - tableY));
    _emptyLabel.frame = _tableView.frame;

    // History header layout
    _historyHeaderView.frame = CGRectMake(0, 0, w, kHistoryHeaderHeight);
    CGFloat histTitleW = 140.0;
    UIView *histTitle = [_historyHeaderView viewWithTag:1001];
    histTitle.frame = CGRectMake(kSideMargin, 12.0, histTitleW, 26.0);
    _historyClearButton.frame = CGRectMake(w - kSideMargin - 60.0, 12.0, 60.0, 26.0);

    // Queue header layout
    _queueHeaderView.frame = CGRectMake(0, 0, w, kQueueHeaderHeight);
    _queueHeaderBlur.frame = CGRectMake(0, 0, w, kQueueHeaderHeight);

    CGFloat pillsW = w - (2 * kSideMargin);
    _pillsContainer.frame = CGRectMake(kSideMargin, 6.0, pillsW, kPillsHeight);
    CGFloat gap = 8.0;
    CGFloat pillW = floor((pillsW - (3.0 * gap)) / 4.0);
    _shufflePill.frame = CGRectMake(0, 0, pillW, kPillsHeight);
    _repeatPill.frame = CGRectMake(pillW + gap, 0, pillW, kPillsHeight);
    _autoplayPill.frame = CGRectMake(2.0 * (pillW + gap), 0, pillW, kPillsHeight);
    _automixPill.frame = CGRectMake(3.0 * (pillW + gap), 0, pillsW - (3.0 * (pillW + gap)), kPillsHeight);

    CGFloat titleY = CGRectGetMaxY(_pillsContainer.frame) + 10.0;
    _queueClearButton.frame = CGRectMake(w - kSideMargin - 60.0, titleY, 60.0, 26.0);
    _queueTitleLabel.frame = CGRectMake(kSideMargin, titleY, w - (2 * kSideMargin) - 65.0, 26.0);
    _queueSubtitleLabel.frame = CGRectMake(kSideMargin, CGRectGetMaxY(_queueTitleLabel.frame) + 1.0, w - (2 * kSideMargin), 20.0);
}

- (void)refreshPillStatesWithState:(SPTPlayerState *)state {
    SPTPlayerOptions *opts = [state respondsToSelector:@selector(options)] ? state.options : nil;
    _shufflePill.isActive = opts.shufflingContext;

    BOOL repTrack = opts.repeatingTrack;
    BOOL repContext = opts.repeatingContext;
    _repeatPill.isActive = repTrack || repContext;
    [_repeatPill setSymbol:repTrack ? @"repeat.1" : @"repeat"];

    _autoplayPill.isActive = SGFlag(SGKeyQueueAutoplay, YES);
    _automixPill.isActive = SGFlag(SGKeyAutoMix, NO);
}

- (void)updateWithState:(SPTPlayerState *)state {
    if (!state) state = SGPlayerState();
    if (!state) {
        id player = SGPlayer();
        if ([player respondsToSelector:@selector(state)]) {
            state = [(id<SPTPlayer>)player state];
        }
    }

    [self refreshPillStatesWithState:state];

    // Current playing track
    _currentTrack = [state respondsToSelector:@selector(track)] ? state.track : nil;
    NSString *currentURI = SGURIString(_currentTrack.URI);
    if (currentURI.length && ![currentURI isEqualToString:_lastTrackURI]) {
        _lastTrackURI = currentURI;
        _historyCleared = NO;
        _hasScrolledToCurrent = NO;
    }

    // Context / Album subtitle
    NSDictionary *metadata = [_currentTrack respondsToSelector:@selector(metadata)] ? _currentTrack.metadata : nil;
    NSString *album = [metadata isKindOfClass:NSDictionary.class] ? metadata[@"album_title"] : nil;
    if (album.length) {
        _queueSubtitleLabel.text = [NSString stringWithFormat:@"From %@", album];
        _queueSubtitleLabel.hidden = NO;
    } else {
        _queueSubtitleLabel.text = @"";
        _queueSubtitleLabel.hidden = YES;
    }

    // Future tracks
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    NSMutableArray<SPTPlayerTrack *> *futureList = [NSMutableArray array];
    Class trackClass = objc_getClass("SPTPlayerTrack");
    for (id item in [future isKindOfClass:NSArray.class] ? future : @[]) {
        if (trackClass && ![item isKindOfClass:trackClass]) continue;
        SPTPlayerTrack *track = (SPTPlayerTrack *)item;
        if (track.trackTitle.length) [futureList addObject:track];
    }
    _futureTracks = [futureList copy];

    // History tracks (from state.reverse)
    if (!_historyCleared) {
        id reverse = [state respondsToSelector:@selector(reverse)] ? state.reverse : nil;
        NSMutableArray<SPTPlayerTrack *> *histList = [NSMutableArray array];
        for (id item in [reverse isKindOfClass:NSArray.class] ? reverse : @[]) {
            if (trackClass && ![item isKindOfClass:trackClass]) continue;
            SPTPlayerTrack *track = (SPTPlayerTrack *)item;
            if (track.trackTitle.length) [histList addObject:track];
        }
        // reverse has nearest first; Apple Music displays oldest at top and nearest right above current
        _historyTracks = [[histList reverseObjectEnumerator] allObjects];
    } else {
        _historyTracks = @[];
    }

    _emptyLabel.hidden = (_futureTracks.count > 0 || _currentTrack != nil);
    _queueClearButton.hidden = (_futureTracks.count == 0);

    [_tableView reloadData];

    // Scroll to Current Track initially so History is tucked above it
    if (!_hasScrolledToCurrent && _historyTracks.count > 0) {
        _hasScrolledToCurrent = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_historyTracks.count > 0 && self->_currentTrack) {
                [self->_tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:SGRQueueSectionCurrent] atScrollPosition:UITableViewScrollPositionTop animated:NO];
            }
        });
    }

    // Retry if future tracks not yet loaded on initial cold launch
    if (_futureTracks.count == 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGRQueueView *strongSelf = weakSelf;
            if (strongSelf && strongSelf->_futureTracks.count == 0) [strongSelf reloadTracks];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGRQueueView *strongSelf = weakSelf;
            if (strongSelf && strongSelf->_futureTracks.count == 0) [strongSelf reloadTracks];
        });
    }
}

- (void)reloadTracks {
    SPTPlayerState *state = SGPlayerState();
    if (!state || ![state respondsToSelector:@selector(future)] || ![(NSArray *)state.future count]) {
        id player = SGPlayer();
        if ([player respondsToSelector:@selector(state)]) {
            SPTPlayerState *playerState = [(id<SPTPlayer>)player state];
            if (playerState) state = playerState;
        }
    }
    [self updateWithState:state];
}

#pragma mark - SGPlayerStateObserver

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self updateWithState:state];
}

- (void)playerStateDidReport:(SPTPlayerState *)state {
    [self updateWithState:state];
}

#pragma mark - Track Lookup

- (SPTPlayerTrack *)trackForIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == SGRQueueSectionHistory && indexPath.row < (NSInteger)_historyTracks.count) {
        return _historyTracks[indexPath.row];
    }
    if (indexPath.section == SGRQueueSectionCurrent) {
        return _currentTrack;
    }
    if (indexPath.section == SGRQueueSectionQueue && indexPath.row < (NSInteger)_futureTracks.count) {
        return _futureTracks[indexPath.row];
    }
    return nil;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return SGRQueueSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == SGRQueueSectionHistory) {
        return _historyCleared ? 0 : _historyTracks.count;
    }
    if (section == SGRQueueSectionCurrent) {
        return _currentTrack ? 1 : 0;
    }
    if (section == SGRQueueSectionQueue) {
        return _futureTracks.count;
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == SGRQueueSectionCurrent) {
        SGRQueueCurrentTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CurrentTrackCell" forIndexPath:indexPath];
        [cell configureWithTrack:_currentTrack];
        cell.onStarTap = ^{
            SGLikePlayingTrack();
        };
        if (@available(iOS 14.0, *)) {
            cell.moreButton.menu = [self contextMenuForTrack:_currentTrack atIndexPath:indexPath];
        }
        return cell;
    }

    SGRQueueTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"TrackCell" forIndexPath:indexPath];
    SPTPlayerTrack *track = [self trackForIndexPath:indexPath];
    [cell configureWithTrack:track isHistory:(indexPath.section == SGRQueueSectionHistory)];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == SGRQueueSectionCurrent) return kCurrentRowHeight;
    return kRowHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section == SGRQueueSectionHistory) {
        return (_historyTracks.count > 0 && !_historyCleared) ? kHistoryHeaderHeight : 0.01;
    }
    if (section == SGRQueueSectionCurrent) {
        return 0.01;
    }
    if (section == SGRQueueSectionQueue) {
        return kQueueHeaderHeight;
    }
    return 0.01;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section == SGRQueueSectionHistory) {
        return (_historyTracks.count > 0 && !_historyCleared) ? _historyHeaderView : nil;
    }
    if (section == SGRQueueSectionQueue) {
        return _queueHeaderView;
    }
    return nil;
}

#pragma mark - Swipe to Delete (1:1 Apple Music)

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != SGRQueueSectionQueue && indexPath.section != SGRQueueSectionHistory) return nil;

    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [weakSelf deleteRowAtIndexPath:indexPath];
        completionHandler(YES);
    }];

    UIImageSymbolConfiguration *symConfig = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightMedium];
    deleteAction.image = [UIImage systemImageNamed:@"minus.circle.fill" withConfiguration:symConfig];
    deleteAction.backgroundColor = [UIColor colorWithRed:0.95 green:0.25 blue:0.28 alpha:1.0];

    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

- (void)deleteRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == SGRQueueSectionQueue) {
        if (indexPath.row >= (NSInteger)_futureTracks.count) return;
        NSMutableArray *mut = [_futureTracks mutableCopy];
        [mut removeObjectAtIndex:indexPath.row];
        _futureTracks = [mut copy];
        [_tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        if (_futureTracks.count == 0) {
            _emptyLabel.hidden = (_currentTrack != nil);
            _queueClearButton.hidden = YES;
        }
    } else if (indexPath.section == SGRQueueSectionHistory) {
        if (indexPath.row >= (NSInteger)_historyTracks.count) return;
        NSMutableArray *mut = [_historyTracks mutableCopy];
        [mut removeObjectAtIndex:indexPath.row];
        _historyTracks = [mut copy];
        [_tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

#pragma mark - Reordering (Drag and Drop & Move)

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == SGRQueueSectionQueue;
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    if (proposedDestinationIndexPath.section < SGRQueueSectionQueue) {
        return [NSIndexPath indexPathForRow:0 inSection:SGRQueueSectionQueue];
    }
    return proposedDestinationIndexPath;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.section != SGRQueueSectionQueue || destinationIndexPath.section != SGRQueueSectionQueue) return;
    if (sourceIndexPath.row == destinationIndexPath.row || sourceIndexPath.row >= (NSInteger)_futureTracks.count) return;
    NSMutableArray *mut = [_futureTracks mutableCopy];
    SPTPlayerTrack *moved = mut[sourceIndexPath.row];
    [mut removeObjectAtIndex:sourceIndexPath.row];
    NSInteger dest = destinationIndexPath.row;
    if (dest > (NSInteger)mut.count) dest = mut.count;
    [mut insertObject:moved atIndex:dest];
    _futureTracks = [mut copy];
}

- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != SGRQueueSectionQueue || indexPath.row >= (NSInteger)_futureTracks.count) return @[];
    SPTPlayerTrack *track = _futureTracks[indexPath.row];
    NSItemProvider *provider = [[NSItemProvider alloc] initWithObject:track.trackTitle ?: @"track"];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:provider];
    item.localObject = track;
    return @[item];
}

- (UITableViewDropProposal *)tableView:(UITableView *)tableView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    if (destinationIndexPath && destinationIndexPath.section == SGRQueueSectionQueue) {
        return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove intent:UITableViewDropIntentInsertAtDestinationIndexPath];
    }
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    NSIndexPath *destinationIndexPath = coordinator.destinationIndexPath;
    if (!destinationIndexPath || destinationIndexPath.section != SGRQueueSectionQueue) return;
    id<UITableViewDropItem> dropItem = coordinator.items.firstObject;
    if (!dropItem || !dropItem.sourceIndexPath || dropItem.sourceIndexPath.section != SGRQueueSectionQueue) return;

    NSInteger sourceRow = dropItem.sourceIndexPath.row;
    NSInteger destRow = destinationIndexPath.row;
    if (sourceRow == destRow || sourceRow >= (NSInteger)_futureTracks.count || destRow > (NSInteger)_futureTracks.count) return;

    NSMutableArray *mut = [_futureTracks mutableCopy];
    SPTPlayerTrack *moved = mut[sourceRow];
    [mut removeObjectAtIndex:sourceRow];
    if (destRow > (NSInteger)mut.count) destRow = mut.count;
    [mut insertObject:moved atIndex:destRow];
    _futureTracks = [mut copy];

    [coordinator dropItem:dropItem toRowAtIndexPath:destinationIndexPath];
}

#pragma mark - Context Menu (1:1 Apple Music)

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    SPTPlayerTrack *track = [self trackForIndexPath:indexPath];
    if (!track) return nil;

    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:^UIViewController *{
        return [weakSelf previewViewControllerForTrack:track];
    } actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        return [weakSelf contextMenuForTrack:track atIndexPath:indexPath];
    }];
}

- (UIViewController *)previewViewControllerForTrack:(SPTPlayerTrack *)track {
    UIViewController *vc = [UIViewController new];
    vc.preferredContentSize = CGSizeMake(280.0, 72.0);
    UIView *view = vc.view;
    view.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.9];

    UIImageView *cover = [[UIImageView alloc] initWithFrame:CGRectMake(12.0, 9.0, 54.0, 54.0)];
    cover.contentMode = UIViewContentModeScaleAspectFill;
    cover.layer.cornerRadius = 6.0;
    cover.layer.cornerCurve = kCACornerCurveContinuous;
    cover.clipsToBounds = YES;
    cover.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    [view addSubview:cover];

    loadArtworkForTrack(track, cover, nil);

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(76.0, 14.0, 175.0, 20.0)];
    title.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.text = track.trackTitle ?: @"Track";
    [view addSubview:title];

    NSDictionary *meta = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    NSString *album = [meta isKindOfClass:NSDictionary.class] ? meta[@"album_title"] : nil;
    NSString *subText = track.artistName ?: @"Artist";
    if (album.length) subText = [NSString stringWithFormat:@"%@ • %@", subText, album];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(76.0, 36.0, 175.0, 18.0)];
    subtitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    subtitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    subtitle.text = subText;
    [view addSubview:subtitle];

    UIImageSymbolConfiguration *chevConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:chevConfig]];
    chevron.tintColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    chevron.frame = CGRectMake(255.0, 28.0, 14.0, 16.0);
    chevron.contentMode = UIViewContentModeCenter;
    [view addSubview:chevron];

    return vc;
}

- (UIMenu *)contextMenuForTrack:(SPTPlayerTrack *)track atIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];

    if (indexPath.section == SGRQueueSectionQueue && indexPath.row > 0) {
        UIAction *playNext = [UIAction actionWithTitle:@"Move to Top" image:[UIImage systemImageNamed:@"arrow.up.to.line"] identifier:nil handler:^(__kindof UIAction *action) {
            SGRQueueView *strongSelf = weakSelf;
            if (!strongSelf || indexPath.row >= (NSInteger)strongSelf->_futureTracks.count) return;
            NSMutableArray *mut = [strongSelf->_futureTracks mutableCopy];
            SPTPlayerTrack *item = mut[indexPath.row];
            [mut removeObjectAtIndex:indexPath.row];
            [mut insertObject:item atIndex:0];
            strongSelf->_futureTracks = [mut copy];
            [strongSelf->_tableView reloadData];
        }];
        [actions addObject:playNext];
    }

    if (indexPath.section == SGRQueueSectionQueue && indexPath.row < (NSInteger)_futureTracks.count - 1) {
        UIAction *playLast = [UIAction actionWithTitle:@"Move to Bottom" image:[UIImage systemImageNamed:@"arrow.down.to.line"] identifier:nil handler:^(__kindof UIAction *action) {
            SGRQueueView *strongSelf = weakSelf;
            if (!strongSelf || indexPath.row >= (NSInteger)strongSelf->_futureTracks.count) return;
            NSMutableArray *mut = [strongSelf->_futureTracks mutableCopy];
            SPTPlayerTrack *item = mut[indexPath.row];
            [mut removeObjectAtIndex:indexPath.row];
            [mut addObject:item];
            strongSelf->_futureTracks = [mut copy];
            [strongSelf->_tableView reloadData];
        }];
        [actions addObject:playLast];
    }

    UIAction *playlistAction = [UIAction actionWithTitle:@"Add to Playlist" image:[UIImage systemImageNamed:@"music.note.list"] identifier:nil handler:^(__kindof UIAction *action) {
    }];
    [actions addObject:playlistAction];

    UIAction *favoriteAction = [UIAction actionWithTitle:@"Favorite" image:[UIImage systemImageNamed:@"star"] identifier:nil handler:^(__kindof UIAction *action) {
        SGLikePlayingTrack();
    }];
    [actions addObject:favoriteAction];

    if (track.artistURI) {
        UIAction *artistAction = [UIAction actionWithTitle:@"Go to Artist" image:[UIImage systemImageNamed:@"person.crop.circle"] identifier:nil handler:^(__kindof UIAction *action) {
            id auri = track.artistURI;
            NSURL *url = [auri isKindOfClass:NSURL.class] ? (NSURL *)auri : ([auri isKindOfClass:NSString.class] ? [NSURL URLWithString:auri] : nil);
            if (url) SGOpenSpotifyURI(url);
        }];
        [actions addObject:artistAction];
    }

    NSDictionary *meta = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    NSString *albumURI = [meta isKindOfClass:NSDictionary.class] ? meta[@"album_uri"] : nil;
    if (albumURI.length) {
        UIAction *albumAction = [UIAction actionWithTitle:@"Go to Album" image:[UIImage systemImageNamed:@"square.stack"] identifier:nil handler:^(__kindof UIAction *action) {
            SGOpenSpotifyURI([NSURL URLWithString:albumURI]);
        }];
        [actions addObject:albumAction];
    }

    if (indexPath.section == SGRQueueSectionQueue) {
        UIAction *removeAction = [UIAction actionWithTitle:@"Remove from Queue" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf deleteRowAtIndexPath:indexPath];
        }];
        removeAction.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:removeAction];
    }

    UIAction *shareAction = [UIAction actionWithTitle:@"Share Song" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__kindof UIAction *action) {
        NSString *title = track.trackTitle ?: @"Track";
        NSString *artist = track.artistName ?: @"Artist";
        NSString *text = [NSString stringWithFormat:@"%@ by %@", title, artist];
        UIActivityViewController *act = [[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];
        SGPresentDark(act);
        UIViewController *top = SGTopController();
        while (top.presentedViewController) top = top.presentedViewController;
        [top presentViewController:act animated:YES completion:nil];
    }];
    [actions addObject:shareAction];

    return [UIMenu menuWithTitle:@"" children:actions];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == SGRQueueSectionCurrent) return;

    if (indexPath.section == SGRQueueSectionHistory) {
        if (indexPath.row >= (NSInteger)_historyTracks.count) return;
        SPTPlayerTrack *track = _historyTracks[indexPath.row];
        id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
        if ([player respondsToSelector:@selector(skipToPreviousTrackWithOptions:track:)]) {
            [player skipToPreviousTrackWithOptions:nil track:track];
        } else if ([player respondsToSelector:@selector(skipToPreviousTrackWithOptions:)]) {
            [player skipToPreviousTrackWithOptions:nil];
        }
        return;
    }

    if (indexPath.section == SGRQueueSectionQueue) {
        if (indexPath.row >= (NSInteger)_futureTracks.count) return;
        SPTPlayerTrack *track = _futureTracks[indexPath.row];
        id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
        if ([player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) {
            [player skipToNextTrackWithOptions:nil track:track];
        } else if ([player respondsToSelector:@selector(skipToNextTrack)]) {
            [player skipToNextTrack];
        }
    }
}

@end

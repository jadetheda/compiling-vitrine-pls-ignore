// Apple Music style inline queue view for the redesigned player.
// Shows upcoming tracks ("Continue Playing" / "Playing Next") with Apple Music pill buttons,
// explicit badges, reorder handles, artwork thumbnails, and dynamic context headers.

#import "SGRQueueView.h"
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Headers/SPTPlayer.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Player.h"

static const CGFloat kSideMargin = 20.0;
static const CGFloat kThumbSide = 42.0;
static const CGFloat kRowHeight = 56.0;
static const CGFloat kPillsHeight = 36.0;
static const CGFloat kHeaderHeight = 48.0;

#define SGKeyQueueAutoplay @"spotifyglass.queue.autoplay"

static NSCache<NSString *, UIImage *> *sg_queueImageCache;

static NSURL *queueArtworkURLForTrack(SPTPlayerTrack *track) {
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
    NSDictionary *m = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    if (![m isKindOfClass:NSDictionary.class]) return NO;
    id val = m[@"is_explicit"] ?: m[@"explicit"];
    if ([val respondsToSelector:@selector(boolValue)]) return [val boolValue];
    if ([val isKindOfClass:NSString.class]) return [val isEqualToString:@"true"] || [val isEqualToString:@"1"];
    return NO;
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

#pragma mark - Track Cell

@interface SGRQueueTrackCell : UITableViewCell
@property (nonatomic, readonly) UIImageView *coverImageView;
@property (nonatomic, readonly) UILabel *titleLabel;
@property (nonatomic, readonly) UIView *explicitBadge;
@property (nonatomic, readonly) UILabel *artistLabel;
@property (nonatomic, readonly) UIImageView *reorderImageView;
@property (nonatomic, copy) NSString *representedTrackURI;
- (void)configureWithTrack:(SPTPlayerTrack *)track;
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

    _coverImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _coverImageView.contentMode = UIViewContentModeScaleAspectFill;
    _coverImageView.clipsToBounds = YES;
    _coverImageView.layer.cornerRadius = 6.0;
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

- (void)configureWithTrack:(SPTPlayerTrack *)track {
    _titleLabel.text = track.trackTitle ?: @"Unknown Title";
    _artistLabel.text = track.artistName ?: @"Unknown Artist";

    BOOL isExp = trackIsExplicit(track);
    _explicitBadge.hidden = !isExp;

    id uri = track.URI;
    NSString *uriString = [uri isKindOfClass:NSURL.class] ? [(NSURL *)uri absoluteString] : ([uri isKindOfClass:NSString.class] ? uri : nil);
    self.representedTrackURI = uriString;

    UIImage *cached = uriString ? [sg_queueImageCache objectForKey:uriString] : nil;
    if (cached) {
        _coverImageView.image = cached;
    } else {
        UIImageSymbolConfiguration *noteConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightRegular];
        UIImage *noteSymbol = [UIImage systemImageNamed:@"music.note" withConfiguration:noteConfig];
        _coverImageView.image = [noteSymbol imageWithTintColor:SGRTertiary() renderingMode:UIImageRenderingModeAlwaysOriginal];

        NSURL *url = queueArtworkURLForTrack(track);
        if (url) {
            __weak SGRQueueTrackCell *weakCell = self;
            NSString *expectedURI = uriString;
            [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (!data.length || error) return;
                UIImage *downloaded = [UIImage imageWithData:data];
                if (!downloaded) return;
                if (expectedURI) [sg_queueImageCache setObject:downloaded forKey:expectedURI];
                dispatch_async(dispatch_get_main_queue(), ^{
                    SGRQueueTrackCell *strongCell = weakCell;
                    if (strongCell && [strongCell.representedTrackURI isEqualToString:expectedURI]) {
                        if (SGRReduceMotion()) {
                            strongCell.coverImageView.image = downloaded;
                        } else {
                            [UIView transitionWithView:strongCell.coverImageView duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                                strongCell.coverImageView.image = downloaded;
                            } completion:nil];
                        }
                    }
                });
            }] resume];
        }
    }
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
    CGFloat maxTextW = MAX(0, CGRectGetMinX(_reorderImageView.frame) - textX - 10.0);

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

@interface SGRQueueView () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation SGRQueueView {
    UIView *_pillsContainer;
    SGRQueuePillButton *_shufflePill;
    SGRQueuePillButton *_repeatPill;
    SGRQueuePillButton *_autoplayPill;
    SGRQueuePillButton *_automixPill;

    UIView *_headerView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;

    UITableView *_tableView;
    UILabel *_emptyLabel;
    NSArray<SPTPlayerTrack *> *_tracks;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = YES;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_queueImageCache = [NSCache new];
        sg_queueImageCache.countLimit = 150;
    });

    [self buildPills];
    [self buildHeader];
    [self buildTableView];

    SGAddPlayerStateObserver(self);
    [self reloadTracks];
    return self;
}

- (void)dealloc {
    // Weak observer table handles cleanup automatically
}

- (void)buildPills {
    _pillsContainer = [UIView new];
    _pillsContainer.backgroundColor = UIColor.clearColor;
    [self addSubview:_pillsContainer];

    __weak typeof(self) weakSelf = self;

    _shufflePill = [[SGRQueuePillButton alloc] initWithFrame:CGRectZero];
    [_shufflePill setSymbol:@"shuffle"];
    _shufflePill.onTap = ^{
        id player = SGPlayer();
        SPTPlayerState *state = SGPlayerState();
        SPTPlayerOptions *opts = [state respondsToSelector:@selector(options)] ? state.options : nil;
        BOOL nextVal = !opts.shufflingContext;
        if ([player respondsToSelector:@selector(setShufflingContext:)]) {
            [(id<SPTPlayer>)player setShufflingContext:nextVal];
        }
        [weakSelf->_shufflePill setIsActive:nextVal];
    };
    [_pillsContainer addSubview:_shufflePill];

    _repeatPill = [[SGRQueuePillButton alloc] initWithFrame:CGRectZero];
    [_repeatPill setSymbol:@"repeat"];
    _repeatPill.onTap = ^{
        id player = SGPlayer();
        SPTPlayerState *state = SGPlayerState();
        SPTPlayerOptions *opts = [state respondsToSelector:@selector(options)] ? state.options : nil;
        if (opts.repeatingTrack) {
            if ([player respondsToSelector:@selector(setRepeatingTrack:)]) [(id<SPTPlayer>)player setRepeatingTrack:NO];
            if ([player respondsToSelector:@selector(setRepeatingContext:)]) [(id<SPTPlayer>)player setRepeatingContext:NO];
            [weakSelf->_repeatPill setSymbol:@"repeat"];
            [weakSelf->_repeatPill setIsActive:NO];
        } else if (opts.repeatingContext) {
            if ([player respondsToSelector:@selector(setRepeatingTrack:)]) [(id<SPTPlayer>)player setRepeatingTrack:YES];
            [weakSelf->_repeatPill setSymbol:@"repeat.1"];
            [weakSelf->_repeatPill setIsActive:YES];
        } else {
            if ([player respondsToSelector:@selector(setRepeatingContext:)]) [(id<SPTPlayer>)player setRepeatingContext:YES];
            [weakSelf->_repeatPill setSymbol:@"repeat"];
            [weakSelf->_repeatPill setIsActive:YES];
        }
    };
    [_pillsContainer addSubview:_repeatPill];

    _autoplayPill = [[SGRQueuePillButton alloc] initWithFrame:CGRectZero];
    [_autoplayPill setSymbol:@"infinity"];
    _autoplayPill.onTap = ^{
        BOOL current = SGFlag(SGKeyQueueAutoplay, YES);
        SGSetFlag(SGKeyQueueAutoplay, !current);
        [weakSelf->_autoplayPill setIsActive:!current];
    };
    [_pillsContainer addSubview:_autoplayPill];

    _automixPill = [[SGRQueuePillButton alloc] initWithFrame:CGRectZero];
    UIImage *waveImg = [UIImage systemImageNamed:@"point.topleft.down.curvedto.point.bottomright.up"];
    [_automixPill setSymbol:waveImg ? @"point.topleft.down.curvedto.point.bottomright.up" : @"arrow.triangle.merge"];
    _automixPill.onTap = ^{
        BOOL nextVal = !SGFlag(SGKeyAutoMix, NO);
        SGAutoMixApply(nextVal);
        [weakSelf->_automixPill setIsActive:nextVal];
    };
    [_pillsContainer addSubview:_automixPill];
}

- (void)buildHeader {
    _headerView = [UIView new];
    _headerView.backgroundColor = UIColor.clearColor;
    [self addSubview:_headerView];

    _titleLabel = [UILabel new];
    _titleLabel.text = @"Continue Playing";
    _titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    _titleLabel.textColor = SGRPrimary();
    [_headerView addSubview:_titleLabel];

    _subtitleLabel = [UILabel new];
    _subtitleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    _subtitleLabel.textColor = SGRSecondary();
    [_headerView addSubview:_subtitleLabel];
}

- (void)buildTableView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = kRowHeight;
    _tableView.showsVerticalScrollIndicator = YES;
    _tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, 110.0, 0);
    _tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, 110.0, 0);
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

    // Pills row
    CGFloat pillsW = w - (2 * kSideMargin);
    _pillsContainer.frame = CGRectMake(kSideMargin, 2.0, pillsW, kPillsHeight);
    CGFloat gap = 8.0;
    CGFloat pillW = floor((pillsW - (3.0 * gap)) / 4.0);
    _shufflePill.frame = CGRectMake(0, 0, pillW, kPillsHeight);
    _repeatPill.frame = CGRectMake(pillW + gap, 0, pillW, kPillsHeight);
    _autoplayPill.frame = CGRectMake(2.0 * (pillW + gap), 0, pillW, kPillsHeight);
    _automixPill.frame = CGRectMake(3.0 * (pillW + gap), 0, pillsW - (3.0 * (pillW + gap)), kPillsHeight);

    // Header row
    CGFloat headerY = CGRectGetMaxY(_pillsContainer.frame) + 12.0;
    _headerView.frame = CGRectMake(kSideMargin, headerY, pillsW, kHeaderHeight);
    _titleLabel.frame = CGRectMake(0, 0, pillsW, 26.0);
    _subtitleLabel.frame = CGRectMake(0, 26.0, pillsW, 20.0);

    // Table view
    CGFloat tableY = CGRectGetMaxY(_headerView.frame) + 6.0;
    _tableView.frame = CGRectMake(0, tableY, w, MAX(0, h - tableY));
    _emptyLabel.frame = _tableView.frame;
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

    // Context / Album subtitle
    NSDictionary *metadata = [state.track respondsToSelector:@selector(metadata)] ? state.track.metadata : nil;
    NSString *album = [metadata isKindOfClass:NSDictionary.class] ? metadata[@"album_title"] : nil;
    if (album.length) {
        _subtitleLabel.text = [NSString stringWithFormat:@"From %@", album];
        _subtitleLabel.hidden = NO;
    } else {
        _subtitleLabel.text = @"";
        _subtitleLabel.hidden = YES;
    }

    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    NSMutableArray<SPTPlayerTrack *> *list = [NSMutableArray array];
    Class trackClass = objc_getClass("SPTPlayerTrack");
    for (id item in [future isKindOfClass:NSArray.class] ? future : @[]) {
        if (trackClass && ![item isKindOfClass:trackClass]) continue;
        SPTPlayerTrack *track = (SPTPlayerTrack *)item;
        if (track.trackTitle.length) [list addObject:track];
    }
    _tracks = [list copy];

    NSUInteger count = _tracks.count;
    _emptyLabel.hidden = (count > 0);
    _tableView.hidden = (count == 0);

    [_tableView reloadData];

    // If initial launch had no future tracks loaded yet, retry shortly
    if (count == 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf && weakSelf->_tracks.count == 0) [weakSelf reloadTracks];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf && weakSelf->_tracks.count == 0) [weakSelf reloadTracks];
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

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SGRQueueTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"TrackCell" forIndexPath:indexPath];
    if (indexPath.row >= (NSInteger)_tracks.count) return cell;

    SPTPlayerTrack *track = _tracks[indexPath.row];
    [cell configureWithTrack:track];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.row == destinationIndexPath.row || sourceIndexPath.row >= (NSInteger)_tracks.count) return;
    NSMutableArray *mut = [_tracks mutableCopy];
    SPTPlayerTrack *moved = mut[sourceIndexPath.row];
    [mut removeObjectAtIndex:sourceIndexPath.row];
    [mut insertObject:moved atIndex:destinationIndexPath.row];
    _tracks = [mut copy];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)_tracks.count) return;

    SPTPlayerTrack *track = _tracks[indexPath.row];
    id player = SGPlayer();
    if ([player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) {
        [(id<SPTPlayer>)player skipToNextTrackWithOptions:nil track:track];
    } else if ([player respondsToSelector:@selector(skipToNextTrack)]) {
        [(id<SPTPlayer>)player skipToNextTrack];
    }
}

@end

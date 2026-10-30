// Apple Music style inline queue view for the redesigned player.
// Shows upcoming tracks ("Playing Next") directly on the player stage.

#import "SGRQueueView.h"
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Headers/SPTPlayer.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Shared/Player/PlayerState.h"
#import "Player.h"

static const CGFloat kThumbSide = 42;
static const CGFloat kHeaderHeight = 36;
static const CGFloat kRowHeight = 54;

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

@interface SGRQueueTrackCell : UITableViewCell
@property (nonatomic, readonly) UIImageView *coverImageView;
@property (nonatomic, readonly) UILabel *titleLabel;
@property (nonatomic, readonly) UILabel *artistLabel;
@property (nonatomic, copy) NSString *representedTrackURI;
@end

@implementation SGRQueueTrackCell {
    UIImageView *_coverImageView;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UIView *_hairline;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _coverImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _coverImageView.contentMode = UIViewContentModeScaleAspectFill;
    _coverImageView.clipsToBounds = YES;
    _coverImageView.layer.cornerRadius = SGRRadiusThumb;
    _coverImageView.layer.cornerCurve = kCACornerCurveContinuous;
    _coverImageView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    [self.contentView addSubview:_coverImageView];

    _titleLabel = [UILabel new];
    _titleLabel.font = SGRFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, UIContentSizeCategoryAccessibilityMedium);
    _titleLabel.textColor = SGRPrimary();
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_titleLabel];

    _artistLabel = [UILabel new];
    _artistLabel.font = SGRFont(UIFontTextStyleCaption1, UIFontWeightRegular, UIContentSizeCategoryAccessibilityMedium);
    _artistLabel.textColor = SGRSecondary();
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_artistLabel];

    _hairline = [UIView new];
    _hairline.backgroundColor = SGRHairline();
    [self.contentView addSubview:_hairline];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;

    CGFloat thumbY = round((h - kThumbSide) / 2);
    _coverImageView.frame = CGRectMake(4, thumbY, kThumbSide, kThumbSide);

    CGFloat textX = CGRectGetMaxX(_coverImageView.frame) + 12;
    CGFloat textW = MAX(0, w - textX - 8);

    CGSize titleSize = [_titleLabel sizeThatFits:CGSizeMake(textW, CGFLOAT_MAX)];
    CGSize artistSize = [_artistLabel sizeThatFits:CGSizeMake(textW, CGFLOAT_MAX)];
    CGFloat totalTextH = titleSize.height + artistSize.height + 2;
    CGFloat textY = round((h - totalTextH) / 2);

    _titleLabel.frame = CGRectMake(textX, textY, textW, titleSize.height);
    _artistLabel.frame = CGRectMake(textX, CGRectGetMaxY(_titleLabel.frame) + 2, textW, artistSize.height);

    CGFloat pixel = 1.0 / (self.window.screen.scale ?: 2.0);
    _hairline.frame = CGRectMake(textX, h - pixel, textW + 8, pixel);
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

@interface SGRQueueView () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation SGRQueueView {
    UIView *_headerView;
    UILabel *_titleLabel;
    UILabel *_countLabel;
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
        sg_queueImageCache.countLimit = 120;
    });

    _headerView = [UIView new];
    _headerView.backgroundColor = UIColor.clearColor;
    [self addSubview:_headerView];

    _titleLabel = [UILabel new];
    _titleLabel.text = @"Playing Next";
    _titleLabel.font = SGRFont(UIFontTextStyleHeadline, UIFontWeightBold, UIContentSizeCategoryAccessibilityMedium);
    _titleLabel.textColor = SGRPrimary();
    [_headerView addSubview:_titleLabel];

    _countLabel = [UILabel new];
    _countLabel.font = SGRFont(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryAccessibilityMedium);
    _countLabel.textColor = SGRSecondary();
    _countLabel.textAlignment = NSTextAlignmentRight;
    [_headerView addSubview:_countLabel];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = kRowHeight;
    _tableView.showsVerticalScrollIndicator = YES;
    _tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, 16, 0);
    [_tableView registerClass:SGRQueueTrackCell.class forCellReuseIdentifier:@"TrackCell"];
    [self addSubview:_tableView];

    _emptyLabel = [UILabel new];
    _emptyLabel.text = @"No Upcoming Tracks";
    _emptyLabel.font = SGRFont(UIFontTextStyleHeadline, UIFontWeightMedium, UIContentSizeCategoryAccessibilityMedium);
    _emptyLabel.textColor = SGRSecondary();
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.hidden = YES;
    [self addSubview:_emptyLabel];

    [self reloadTracks];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 1 || h < 1) return;

    _headerView.frame = CGRectMake(0, 0, w, kHeaderHeight);
    CGFloat countW = 80;
    _titleLabel.frame = CGRectMake(4, 0, MAX(0, w - countW - 8), kHeaderHeight);
    _countLabel.frame = CGRectMake(w - countW - 4, 0, countW, kHeaderHeight);

    _tableView.frame = CGRectMake(0, kHeaderHeight, w, MAX(0, h - kHeaderHeight));
    _emptyLabel.frame = _tableView.frame;
}

- (void)updateWithState:(SPTPlayerState *)state {
    if (!state) state = SGPlayerState();
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
    _countLabel.text = count > 0 ? [NSString stringWithFormat:@"%lu %@", (unsigned long)count, count == 1 ? @"track" : @"tracks"] : @"";
    _emptyLabel.hidden = (count > 0);
    _tableView.hidden = (count == 0);

    [_tableView reloadData];
}

- (void)reloadTracks {
    [self updateWithState:SGPlayerState()];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SGRQueueTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"TrackCell" forIndexPath:indexPath];
    if (indexPath.row >= (NSInteger)_tracks.count) return cell;

    SPTPlayerTrack *track = _tracks[indexPath.row];
    cell.titleLabel.text = track.trackTitle ?: @"Unknown Title";
    cell.artistLabel.text = track.artistName ?: @"Unknown Artist";

    id uri = track.URI;
    NSString *uriString = [uri isKindOfClass:NSURL.class] ? [(NSURL *)uri absoluteString] : ([uri isKindOfClass:NSString.class] ? uri : nil);
    cell.representedTrackURI = uriString;

    UIImage *cached = uriString ? [sg_queueImageCache objectForKey:uriString] : nil;
    if (cached) {
        cell.coverImageView.image = cached;
    } else {
        UIImage *noteSymbol = [UIImage systemImageNamed:@"music.note" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightRegular]];
        cell.coverImageView.image = [noteSymbol imageWithTintColor:SGRTertiary() renderingMode:UIImageRenderingModeAlwaysOriginal];

        NSURL *url = queueArtworkURLForTrack(track);
        if (url) {
            __weak SGRQueueTrackCell *weakCell = cell;
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

    return cell;
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

// Album redesign: the track rows on the field, the way the Music app has them -- no surface of their own
// and a hairline from the text's edge between one row and the next.
//
// Tree (trees/clean/album/03.txt:524-575): every row of the page is an Element_List.CollectionViewCell
// holding an Encore.ListRow, id=Components.UI.RetrievalRowElementUI, with the title
// (EncoreConsumerMobile.View.Granular.Title), the artists under it (…Granular.Subtitle) and, at the
// trailing edge, Components.UI.ContextMenuButton. An album row carries no artwork -- every track on the
// page shares the cover the header is already showing -- so the hairline runs from the page's own margin,
// where the text starts.
//
// The row's paint is cleared here rather than left to the Kit's repaint hook, which only hears about a
// color when Spotify sets it and not when a reused cell already carries one.
//
// Spotify's type and its spacing are left alone: the row is 56pt for a title of 13pt, and a larger font of
// the Kit's would be cut off by the box the element framework measured for it.
//
// **The artist line, where it only repeats the album's.** The Music app shows a track's title alone on a
// standard album, so the line goes where AlbumCredits.m finds it says nothing the header does not. It goes by
// alpha on the Subtitle wrapper: Encore sets its inner label's alpha again later, `hidden` inside its stacks
// crashes, and the row keeps the height Spotify measured for it. The title is moved down to the middle of the
// row by a translation. The explicit badge is a sibling of the line, not inside it, so it is drawn again as a
// picture after the title's text, 4pt on, and the badge itself goes by alpha; the title is narrowed by the
// badge's room so a long one cannot run under it or under ⋯. Right to left, all of it the other way round.
// The row's own accessibility label still names the artists and says explicit; the picture is not an element.
//
// Everything changed is put back at the start of the cell's next pass and when the cell is prepared for reuse,
// which also asks for a pass: Spotify can show a cached row again at the same size without one, and the last
// row's state would stay on it.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Album.h"

// Under the text rather than the whole row, as the Music app draws it; the trailing end clears the page
// margin.
static const CGFloat kHairline = 0.5;
// Between the end of the title's text and the badge drawn after it.
static const CGFloat kBadgeGap = 4;

static char kRowKey, kSubtitleKey, kLineKey, kTitleKey, kBadgeKey, kArtistKey, kChangeKey;

static void clearSurface(UIView *view) {
    UIColor *color = view.backgroundColor;
    if (color && SGIsBaseSurface(color.CGColor)) view.backgroundColor = UIColor.clearColor;
}

static void applyHairline(UIView *row) {
    CALayer *line = objc_getAssociatedObject(row, &kLineKey);
    if (!line) {
        line = [CALayer layer];
        line.zPosition = 1;
        objc_setAssociatedObject(row, &kLineKey, line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    line.backgroundColor = SGRHairline().CGColor;
    if (line.superlayer != row.layer) [row.layer addSublayer:line];
    CGRect bounds = row.bounds;
    CGRect frame = CGRectMake(SGRSideMargin, bounds.size.height - kHairline,
                              MAX(0, bounds.size.width - 2 * SGRSideMargin), kHairline);
    if (CGRectEqualToRect(line.frame, frame)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    line.frame = frame;
    [CATransaction commit];
}

#pragma mark - the artist line

// What a row's credit change touched, and what each was before, to be put back.
@interface SGRCreditChange : NSObject
@property (nonatomic, weak) UIView *subtitle, *badge;
@property (nonatomic, weak) UILabel *title;
@property (nonatomic) CGFloat subtitleAlpha, badgeAlpha;
@property (nonatomic) CGRect titleFrame, narrowFrame;
@property (nonatomic) CGAffineTransform shift;
@property (nonatomic, strong) UIImageView *drawnBadge;
@end

@implementation SGRCreditChange
@end

static BOOL hidesCredits(void) {
    static NSInteger on = -1;
    if (on < 0) on = SGEnabled(SGRKeyAlbumHideTrackArtists);
    return on;
}

// The one label under `view`, itself included, with text in it; nil for none or for more than one.
static UILabel *onlyLabel(UIView *view) {
    __block UILabel *found = nil;
    __block NSUInteger count = 0;
    SGForEachView(view, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class]) return;
        NSString *text = [((UILabel *)v).text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!text.length) return;
        found = (UILabel *)v;
        count++;
    });
    return count == 1 ? found : nil;
}

// The badge as it draws, rendered the moment before it goes: an unplayable row's is grayed, so it is not cached.
static UIImage *pictureOf(UIView *badge) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:badge.traitCollection];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:badge.bounds.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [badge.layer renderInContext:context.CGContext];
    }];
}

// Puts back what the last change took. YES when there was one.
static BOOL restoreCredit(UIView *cell) {
    SGRCreditChange *change = objc_getAssociatedObject(cell, &kChangeKey);
    if (!change) return NO;
    objc_setAssociatedObject(cell, &kChangeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [change.drawnBadge removeFromSuperview];
    // The transform before the frame, which is meaningless under one. Each only where it is still this change's:
    // a pass of Spotify's since may have put its own there.
    UILabel *title = change.title;
    if (title && CGAffineTransformEqualToTransform(title.transform, change.shift)) title.transform = CGAffineTransformIdentity;
    if (title && !CGRectIsNull(change.narrowFrame) && CGRectEqualToRect(title.frame, change.narrowFrame)) title.frame = change.titleFrame;
    if (change.subtitle.alpha == 0) change.subtitle.alpha = change.subtitleAlpha;
    if (change.badge.alpha == 0) change.badge.alpha = change.badgeAlpha;
    return YES;
}

void SGRAlbumSetArtist(UIView *view, NSString *artist) {
    UIView *page = SGRAlbumPageOf(view);
    NSString *known = objc_getAssociatedObject(page, &kArtistKey);
    if (!page || known == artist || [known isEqualToString:artist]) return;
    objc_setAssociatedObject(page, &kArtistKey, artist, OBJC_ASSOCIATION_COPY_NONATOMIC);
    // The rows on screen were laid out against the artist before; the rest are laid out as they come.
    if (!hidesCredits()) return;
    SGForEachView(page, ^(UIView *v) {
        if ([v isKindOfClass:%c(_TtC12Element_List18CollectionViewCell)]) [v setNeedsLayout];
    });
}

static void applyCredit(UIView *cell, UIView *row, UIView *page) {
    NSString *album = objc_getAssociatedObject(page, &kArtistKey);
    if (!album) return;
    // The content's own pass first: a new row has no size in its text before it.
    [((UICollectionViewCell *)cell).contentView layoutIfNeeded];
    UIView *subtitle = SGRFindByIdentifier(row, @"EncoreConsumerMobile.View.Granular.Subtitle", &kSubtitleKey);
    UILabel *title = onlyLabel(SGRFindByIdentifier(row, @"EncoreConsumerMobile.View.Granular.Title", &kTitleKey));
    UILabel *artist = onlyLabel(subtitle);
    if (!title || !artist || !SGRCreditRepeatsAlbum(album, artist.text, title.text)) return;
    // Mid animation the title's frame is not where it is going.
    if (!CGAffineTransformIsIdentity(title.transform) || title.layer.animationKeys.count) return;

    UIView *badge = SGRFindByIdentifier(row, @"Components.UI.ExplicitIcon", &kBadgeKey);
    if (badge && (badge.hidden || badge.alpha < 0.01 || CGRectIsEmpty(badge.bounds))) badge = nil;
    CGRect frame = title.frame;
    CGFloat room = badge ? badge.bounds.size.width + kBadgeGap : 0;
    if (frame.size.width - room < title.font.lineHeight) return;
    NSTextAlignment alignment = title.textAlignment;
    BOOL rtl = title.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    BOOL textAtRight = alignment == NSTextAlignmentRight || (alignment == NSTextAlignmentNatural && rtl);
    CGFloat narrowWidth = frame.size.width - room;
    CGSize text = [title textRectForBounds:CGRectMake(0, 0, narrowWidth, CGFLOAT_MAX) limitedToNumberOfLines:title.numberOfLines].size;
    // ponytail: one line only. A wrapped title's last line ends somewhere this does not measure, so its badge
    // would be placed against the widest line; such a row keeps its artist line instead.
    if (badge && (alignment == NSTextAlignmentCenter || text.height > title.font.lineHeight * 1.5)) return;

    SGRCreditChange *change = [SGRCreditChange new];
    change.subtitle = subtitle;
    change.subtitleAlpha = subtitle.alpha;
    change.title = title;
    change.titleFrame = frame;
    change.narrowFrame = CGRectNull;
    subtitle.alpha = 0;
    if (badge) {
        CGRect narrow = frame;
        narrow.size.width = narrowWidth;
        if (rtl) narrow.origin.x += room;
        title.frame = narrow;
        change.narrowFrame = narrow;
    }
    CGFloat scale = row.window.screen.scale ?: UIScreen.mainScreen.scale;
    CGPoint centre = [title.superview convertPoint:title.center toView:row];
    CGFloat dy = round((CGRectGetMidY(row.bounds) - centre.y) * scale) / scale;
    change.shift = CGAffineTransformMakeTranslation(0, dy);
    title.transform = change.shift;

    if (badge) {
        UIImageView *drawn = [[UIImageView alloc] initWithImage:pictureOf(badge)];
        drawn.userInteractionEnabled = NO;
        drawn.isAccessibilityElement = NO;
        CGSize size = badge.bounds.size;
        CGFloat textWidth = MIN(ceil(text.width), narrowWidth);
        CGFloat x = textAtRight ? narrowWidth - textWidth - kBadgeGap - size.width : textWidth + kBadgeGap;
        CGRect inTitle = CGRectMake(x, (title.bounds.size.height - size.height) / 2, size.width, size.height);
        // Through the title, whose transform the conversion takes along.
        drawn.frame = [title convertRect:inTitle toView:row];
        [row addSubview:drawn];
        change.drawnBadge = drawn;
        change.badge = badge;
        change.badgeAlpha = badge.alpha;
        badge.alpha = 0;
    }
    objc_setAssociatedObject(cell, &kChangeKey, change, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    static BOOL logged;
    if (!logged) {
        logged = YES;
        SGLog(@"redesign album: a track's artist line hidden as the album's, badge %@", badge ? @"moved up" : @"none");
    }
}

#pragma mark - the rows


NSNotificationName const SGRAlbumTrackFocusRequestedNotification = @"SGRAlbumTrackFocusRequestedNotification";

static NSString *sgr_focusTrackURI;
static NSString *sgr_focusTrackTitle;
static CFTimeInterval sgr_focusSetTimestamp;
static __weak UICollectionView *sgr_lastAlbumCollectionView;
static BOOL sgr_focusStepScheduled = NO;

static NSString *normalizedTrackTitle(NSString *text) {
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

static BOOL trackTitleMatchesFocus(NSString *candidate, NSString *focus) {
    NSString *a = normalizedTrackTitle(candidate);
    NSString *b = normalizedTrackTitle(focus);
    if (!a.length || !b.length) return NO;
    return [a caseInsensitiveCompare:b] == NSOrderedSame;
}

static void scrollAndPulseMatchedCell(UIView *cell, UIScrollView *scroller) {
    if (!cell) return;
    void (^animatePulse)(void) = ^{
        if (scroller) {
            CGRect rectInScroll = [scroller convertRect:cell.bounds fromView:cell];
            CGFloat maxY = MAX(0.0, scroller.contentSize.height - scroller.bounds.size.height);
            CGFloat visibleTop = scroller.contentOffset.y + 110.0;
            CGFloat visibleBot = scroller.contentOffset.y + scroller.bounds.size.height - 96.0;
            if (maxY > 0 && (CGRectGetMinY(rectInScroll) < visibleTop || CGRectGetMaxY(rectInScroll) > visibleBot)) {
                CGFloat targetY = CGRectGetMidY(rectInScroll) - scroller.bounds.size.height * 0.42;
                targetY = MAX(0.0, MIN(maxY, targetY));
                [scroller setContentOffset:CGPointMake(scroller.contentOffset.x, targetY) animated:YES];
            }
        }
        UIView *pulse = [[UIView alloc] initWithFrame:cell.bounds];
        pulse.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        pulse.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
        pulse.userInteractionEnabled = NO;
        pulse.accessibilityElementsHidden = YES;
        [cell addSubview:pulse];
        [UIView animateWithDuration:0.85 delay:0.25 options:UIViewAnimationOptionCurveEaseOut animations:^{
            pulse.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            [pulse removeFromSuperview];
        }];
    };

    if (scroller && scroller.contentSize.height <= scroller.bounds.size.height) {
        __weak UIView *weakCell = cell;
        __weak UIScrollView *weakScroller = scroller;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *sc = weakCell;
            UIScrollView *ss = weakScroller;
            if (!sc || !sc.window) return;
            if (ss && ss.contentSize.height > ss.bounds.size.height) {
                CGRect r = [ss convertRect:sc.bounds fromView:sc];
                CGFloat maxY = MAX(0.0, ss.contentSize.height - ss.bounds.size.height);
                CGFloat targetY = MAX(0.0, MIN(maxY, CGRectGetMidY(r) - ss.bounds.size.height * 0.42));
                [ss setContentOffset:CGPointMake(ss.contentOffset.x, targetY) animated:YES];
            }
        });
    }
    dispatch_async(dispatch_get_main_queue(), animatePulse);
}

static BOOL isTrackContent(UIView *content);

static BOOL tryFocusVisibleCellsInCollectionView(UICollectionView *list) {
    NSString *focus = SGRFocusTrackTitle();
    if (!focus.length || !list || !list.window) return NO;
    for (UICollectionViewCell *cell in list.visibleCells) {
        if (!isTrackContent(cell.contentView.subviews.firstObject)) continue;
        UIView *titleWrap = SGRFindByIdentifier(cell, @"EncoreConsumerMobile.View.Granular.Title", &kTitleKey);
        UILabel *tLabel = onlyLabel(titleWrap);
        if (trackTitleMatchesFocus(tLabel.text, focus)) {
            SGRClearAlbumTrackFocus();
            scrollAndPulseMatchedCell(cell, list);
            return YES;
        }
    }
    return NO;
}

static void scheduleFocusScanStep(UICollectionView *list, NSInteger stepsLeft) {
    if (stepsLeft <= 0 || !list || !list.window || !SGRFocusTrackTitle().length) {
        sgr_focusStepScheduled = NO;
        return;
    }
    if (list.isTracking || list.isDecelerating) {
        sgr_focusStepScheduled = NO;
        return;
    }
    if (tryFocusVisibleCellsInCollectionView(list)) {
        sgr_focusStepScheduled = NO;
        return;
    }
    CGFloat maxY = list.contentSize.height - list.bounds.size.height;
    if (maxY > 0 && list.contentOffset.y < maxY - 2.0) {
        CGFloat step = MAX(180.0, list.bounds.size.height * 0.65);
        CGFloat nextY = MIN(maxY, list.contentOffset.y + step);
        [list setContentOffset:CGPointMake(list.contentOffset.x, nextY) animated:NO];
        [list layoutIfNeeded];
        if (tryFocusVisibleCellsInCollectionView(list)) {
            sgr_focusStepScheduled = NO;
            return;
        }
    }
    __weak UICollectionView *weakList = list;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        scheduleFocusScanStep(weakList, stepsLeft - 1);
    });
}

static void triggerFocusScanIfNeeded(void) {
    UICollectionView *list = sgr_lastAlbumCollectionView;
    if (!list || !list.window || !SGRFocusTrackTitle().length) return;
    if (tryFocusVisibleCellsInCollectionView(list)) return;
    if (sgr_focusStepScheduled) return;
    sgr_focusStepScheduled = YES;
    __weak UICollectionView *weakList = list;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        scheduleFocusScanStep(weakList, 35);
    });
}

void SGRSetAlbumTrackToFocus(NSString *uri, NSString *title) {
    sgr_focusTrackURI = [uri copy];
    sgr_focusTrackTitle = [title copy];
    sgr_focusSetTimestamp = CACurrentMediaTime();
    sgr_focusStepScheduled = NO;
    [NSNotificationCenter.defaultCenter postNotificationName:SGRAlbumTrackFocusRequestedNotification object:nil];
}

NSString *SGRFocusTrackTitle(void) {
    if (sgr_focusTrackTitle.length && CACurrentMediaTime() - sgr_focusSetTimestamp < 12.0) {
        return sgr_focusTrackTitle;
    }
    return nil;
}

NSString *SGRFocusTrackURI(void) {
    if (sgr_focusTrackURI.length && CACurrentMediaTime() - sgr_focusSetTimestamp < 12.0) {
        return sgr_focusTrackURI;
    }
    return nil;
}

void SGRClearAlbumTrackFocus(void) {
    sgr_focusTrackTitle = nil;
    sgr_focusTrackURI = nil;
    sgr_focusStepScheduled = NO;
}

static void applyRow(UIView *cell, UIView *page) {
    clearSurface(cell);
    UIView *row = SGRFindByIdentifier(cell, @"Components.UI.RetrievalRow*", &kRowKey);
    if (!row) return;
    // The row, and every box the element framework wraps it in on the way back up to the cell.
    for (UIView *v = row; v; v = v.superview) {
        clearSurface(v);
        if (v == cell) break;
    }

    UIView *subtitle = SGRFindByIdentifier(row, @"EncoreConsumerMobile.View.Granular.Subtitle", &kSubtitleKey);
    SGForEachView(subtitle, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class]) return;
        UILabel *label = (UILabel *)v;
        if (![label.textColor isEqual:SGRSecondary()]) label.textColor = SGRSecondary();
    });

    applyHairline(row);
    if (hidesCredits()) applyCredit(cell, row, page);

    UICollectionView *listView = nil;
    for (UIView *p = cell.superview; p; p = p.superview) {
        if ([p isKindOfClass:UICollectionView.class]) {
            listView = (UICollectionView *)p;
            break;
        }
    }
    if (listView) sgr_lastAlbumCollectionView = listView;

    NSString *focus = SGRFocusTrackTitle();
    if (focus.length) {
        UIView *titleWrap = SGRFindByIdentifier(row, @"EncoreConsumerMobile.View.Granular.Title", &kTitleKey);
        UILabel *tLabel = onlyLabel(titleWrap);
        if (trackTitleMatchesFocus(tLabel.text, focus)) {
            SGRClearAlbumTrackFocus();
            scrollAndPulseMatchedCell(cell, listView);
        } else if (listView && !sgr_focusStepScheduled) {
            triggerFocusScanIfNeeded();
        }
    }
}

#pragma mark - the cells

// Which cells of Element_List belong to an album's track list, answered once per content class: the same
// cell class carries Home's sections and the album's footer too, and a walk up to the page on every pass of
// every cell is what the answer is cached to avoid.
static BOOL isTrackContent(UIView *content) {
    static NSMutableDictionary<id, NSNumber *> *answers;
    if (!answers) answers = [NSMutableDictionary dictionary];
    Class cls = object_getClass(content);
    if (!cls) return NO;
    NSNumber *answer = answers[(id<NSCopying>)cls];
    if (!answer) {
        answer = @([NSStringFromClass(cls) containsString:@"RetrievalListStructuredData"]);
        answers[(id<NSCopying>)cls] = answer;
    }
    return answer.boolValue;
}

%hook _TtC12Element_List18CollectionViewCell
- (void)layoutSubviews {
    restoreCredit((UIView *)self);
    %orig;
    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    if (!isTrackContent(cell.contentView.subviews.firstObject)) return;
    UIView *page = SGRAlbumPageOf(cell);
    if (page) applyRow(cell, page);
}

- (void)prepareForReuse {
    %orig;
    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    if (restoreCredit(cell) || isTrackContent(cell.contentView.subviews.firstObject)) [cell setNeedsLayout];
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC12Element_List18CollectionViewCell"]);
    [NSNotificationCenter.defaultCenter addObserverForName:SGRAlbumTrackFocusRequestedNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(__unused NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            triggerFocusScanIfNeeded();
        });
    }];
}

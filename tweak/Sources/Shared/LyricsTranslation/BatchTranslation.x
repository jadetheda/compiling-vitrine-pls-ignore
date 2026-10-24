#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/AlbumQueue/AlbumQueue.h"
#import "LyricsTranslation.h"
#import "BatchTranslation.h"

@interface SGEntityPage : NSObject
+ (NSString *)entityURI:(id)controller;
+ (NSString *)playlistURI:(id)controller;
@end

@interface SGBatchCandidateSong : NSObject
@property (nonatomic, copy) NSString *trackID;
@property (nonatomic, copy) NSString *trackURI;
@property (nonatomic, strong) NSArray<SGKaraokeLine *> *lines;
@property (nonatomic, strong) NSArray<NSString *> *texts;
@end
@implementation SGBatchCandidateSong
@end

static char kURIKey, kRowKey;
static NSString *sg_pendingURI;
static CFTimeInterval sg_markedAt;
static BOOL sg_translating;

static NSString *SGResolveEntityURIForView(UIView *view) {
    if (!view) return nil;
    NSString *identifier = view.accessibilityIdentifier;
    NSString *prefix = SGAlbumQueueButtonPrefix;
    NSString *entityID = nil;
    if ([identifier hasPrefix:prefix]) {
        entityID = [identifier substringFromIndex:prefix.length];
        if (entityID.length != 22) entityID = nil;
    }

    UIViewController *vc = nil;
    for (UIResponder *r = view.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) {
            vc = (UIViewController *)r;
            break;
        }
    }
    if (vc) {
        Class pageClass = NSClassFromString(@"SGEntityPage");
        if (pageClass && [pageClass respondsToSelector:@selector(entityURI:)]) {
            NSString *uri = [pageClass performSelector:@selector(entityURI:) withObject:vc];
            if (SGIsValidEntityURI(uri)) return uri;
        }
        Class albumPage = NSClassFromString(@"SGAlbumQueuePage");
        if (albumPage && [albumPage respondsToSelector:@selector(albumURI:)]) {
            NSString *uri = [albumPage performSelector:@selector(albumURI:) withObject:vc];
            if (SGAlbumQueueIsAlbumURI(uri)) return uri;
        }
        NSString *name = NSStringFromClass(vc.class);
        if (entityID && ([name containsString:@"FTP"] || [name containsString:@"Playlist"])) {
            return [@"spotify:playlist:" stringByAppendingString:entityID];
        }
        if (entityID && [name containsString:@"CreativeWork"]) {
            return [@"spotify:album:" stringByAppendingString:entityID];
        }
    }
    if (entityID) {
        // Fallback: check if view is within a playlist or album page hierarchy
        UIView *parent = view;
        while (parent) {
            NSString *pName = NSStringFromClass(parent.class);
            if ([pName containsString:@"CreativeWork"]) return [@"spotify:album:" stringByAppendingString:entityID];
            if ([pName containsString:@"Playlist"] || [pName containsString:@"FTP"]) return [@"spotify:playlist:" stringByAppendingString:entityID];
            parent = parent.superview;
        }
    }
    return nil;
}

void SGBatchTranslationMarkSource(UIView *view) {
    sg_pendingURI = SGResolveEntityURIForView(view);
    sg_markedAt = CACurrentMediaTime();
}

BOOL SGBatchTranslationIsRunning(void) {
    return sg_translating;
}

static NSArray<NSString *> *textsOfLines(NSArray<SGKaraokeLine *> *lines) {
    NSMutableArray *texts = [NSMutableArray arrayWithCapacity:lines.count];
    for (SGKaraokeLine *line in lines) {
        NSString *text = SGKaraokeLineText(line);
        [texts addObject:text ?: @""];
    }
    return texts;
}

#pragma mark - Track resolution

static void resolveTracks(NSString *uri, void (^completion)(NSArray<NSString *> *trackIDs, NSString *error)) {
    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *headers) {
        if (!headers) {
            completion(nil, @"Spotify is not ready.");
            return;
        }
        NSMutableArray<NSString *> *collected = [NSMutableArray array];
        void (^fetchPage)(NSString *);
        __block void (^weakFetchPage)(NSString *);
        weakFetchPage = fetchPage = ^(NSString *address) {
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
            req.timeoutInterval = 15;
            req.allHTTPHeaderFields = headers;
            [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
            [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
                NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                id json = (status == 200 && data.length) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                if (![json isKindOfClass:NSDictionary.class]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (collected.count) completion(collected, nil);
                        else completion(nil, err ? err.localizedDescription : @"Could not load tracks.");
                    });
                    return;
                }
                id pages = json[@"pages"];
                NSString *nextURL = nil;
                if ([pages isKindOfClass:NSArray.class]) {
                    for (id page in pages) {
                        if (![page isKindOfClass:NSDictionary.class]) continue;
                        id next = page[@"next_page_url"];
                        if ([next isKindOfClass:NSString.class] && [next length]) nextURL = next;
                        id tracks = page[@"tracks"];
                        if (![tracks isKindOfClass:NSArray.class]) continue;
                        for (id entry in tracks) {
                            if (![entry isKindOfClass:NSDictionary.class]) continue;
                            NSString *tURI = entry[@"uri"];
                            if ([tURI hasPrefix:@"spotify:track:"]) {
                                NSString *tID = [tURI substringFromIndex:@"spotify:track:".length];
                                if (tID.length == 22 && ![collected containsObject:tID]) {
                                    [collected addObject:tID];
                                    if (collected.count >= 500) { nextURL = nil; break; }
                                }
                            }
                        }
                    }
                }
                if (nextURL && collected.count < 500) {
                    weakFetchPage(nextURL);
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(collected, nil);
                    });
                }
            }] resume];
        };
        weakFetchPage([@"https://spclient.wg.spotify.com/context-resolve/v1/" stringByAppendingString:uri]);
    });
}

#pragma mark - Lyrics fetching for candidates

static void fetchLyricsForTrack(NSString *trackID, NSDictionary<NSString *, NSString *> *headers,
                                void (^completion)(NSArray<SGKaraokeLine *> *lines)) {
    NSArray *cached = SGKaraokeLinesForTrack(trackID);
    if (cached.count) {
        completion(cached);
        return;
    }
    NSString *address = [NSString stringWithFormat:@"https://spclient.wg.spotify.com/color-lyrics/v2/track/%@?format=json&vocalRemoval=false&market=from_token", trackID];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
    req.allHTTPHeaderFields = headers;
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [NSURLProtocol setProperty:@YES forKey:SGLyricsOwnRequestKey inRequest:req];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesFromBody(body);
        if (lines.count) SGKaraokeKeepLines(trackID, lines);
        completion(lines);
    }] resume];
}

static void filterCandidateSongs(NSArray<NSString *> *trackIDs, NSString *targetLang,
                                 void (^completion)(NSArray<SGBatchCandidateSong *> *candidates)) {
    BOOL skipSaved = SGLyricsBatchSkipSaved();
    BOOL translateAny = SGHidden(SGKeyLyricsTranslateEverySong);
    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *headers) {
        NSMutableArray<SGBatchCandidateSong *> *candidates = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();
        for (NSString *trackID in trackIDs) {
            if (skipSaved && SGLyricsHasSavedTranslation(trackID, targetLang)) {
                continue;
            }
            dispatch_group_enter(group);
            fetchLyricsForTrack(trackID, headers, ^(NSArray<SGKaraokeLine *> *lines) {
                if (lines.count) {
                    // Check if instrumental only (only ♪ or empty)
                    BOOL hasActualWords = NO;
                    for (SGKaraokeLine *l in lines) {
                        NSString *t = SGKaraokeLineText(l);
                        if (t.length && ![t isEqualToString:@"♪"]) { hasActualWords = YES; break; }
                    }
                    if (hasActualWords && (translateAny || SGKaraokeInAnotherLanguage(lines, targetLang))) {
                        SGBatchCandidateSong *song = [SGBatchCandidateSong new];
                        song.trackID = trackID;
                        song.trackURI = [@"spotify:track:" stringByAppendingString:trackID];
                        song.lines = lines;
                        song.texts = textsOfLines(lines);
                        @synchronized (candidates) {
                            [candidates addObject:song];
                        }
                    }
                }
                dispatch_group_leave(group);
            });
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            completion(candidates);
        });
    });
}

#pragma mark - Batch translation execution

void SGBatchTranslateURI(NSString *uri, SGBatchTranslationEngine engine, UIWindow *window) {
    if (sg_translating) {
        [SGAlbumQueueNotice showIn:window title:@"Translation in Progress" detail:@"Another batch translation is already running." symbol:@"exclamationmark.circle"];
        return;
    }
    sg_translating = YES;
    BOOL isAlbum = SGAlbumQueueIsAlbumURI(uri);
    NSString *entityName = isAlbum ? @"Album" : @"Playlist";
    NSString *targetLang = SGLyricsTranslationTarget();
    
    [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"Translating %@", entityName] detail:@"Resolving songs…" symbol:@"translate"];
    
    resolveTracks(uri, ^(NSArray<NSString *> *trackIDs, NSString *resolveError) {
        if (!trackIDs.count) {
            sg_translating = NO;
            [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"Could Not Load %@", entityName] detail:resolveError ?: @"No songs found." symbol:@"exclamationmark.circle"];
            return;
        }
        [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"Translating %@", entityName] detail:@"Checking lyrics…" symbol:@"translate"];
        filterCandidateSongs(trackIDs, targetLang, ^(NSArray<SGBatchCandidateSong *> *candidates) {
            if (!candidates.count) {
                sg_translating = NO;
                [SGAlbumQueueNotice showIn:window title:@"Already Translated" detail:@"All songs are already translated or in your language." symbol:@"checkmark.circle"];
                return;
            }
            NSUInteger total = candidates.count;
            __block NSUInteger completed = 0;
            
            if (engine == SGBatchTranslationEngineAI) {
                NSUInteger batchSize = SGLyricsBatchSize();
                if (batchSize == 0) batchSize = total; // All at once
                
                NSMutableArray<NSArray<SGBatchCandidateSong *> *> *chunks = [NSMutableArray array];
                for (NSUInteger i = 0; i < total; i += batchSize) {
                    NSUInteger len = MIN(batchSize, total - i);
                    [chunks addObject:[candidates subarrayWithRange:NSMakeRange(i, len)]];
                }
                
                void (^processChunk)(NSUInteger);
                __block void (^weakProcessChunk)(NSUInteger);
                weakProcessChunk = processChunk = ^(NSUInteger chunkIndex) {
                    if (chunkIndex >= chunks.count) {
                        sg_translating = NO;
                        NSString *detail = completed == 1 ? @"1 song translated and saved." : [NSString stringWithFormat:@"%lu songs translated and saved.", (unsigned long)completed];
                        [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"%@ Translated", entityName] detail:detail symbol:@"checkmark.circle"];
                        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
                        return;
                    }
                    NSArray<SGBatchCandidateSong *> *chunk = chunks[chunkIndex];
                    NSMutableDictionary<NSString *, NSArray<NSString *> *> *songsMap = [NSMutableDictionary dictionary];
                    for (SGBatchCandidateSong *song in chunk) {
                        songsMap[song.trackURI] = song.texts;
                    }
                    [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"Translating %@", entityName] detail:[NSString stringWithFormat:@"%lu of %lu songs…", (unsigned long)completed, (unsigned long)total] symbol:@"sparkles"];
                    
                    SGLyricsTranslateBatchWithAI(songsMap, targetLang, ^(NSDictionary<NSString *, NSArray<NSString *> *> *results, NSString *error) {
                        if (error && !results.count) {
                            sg_translating = NO;
                            [SGAlbumQueueNotice showIn:window title:@"Translation Stopped" detail:error symbol:@"exclamationmark.circle"];
                            return;
                        }
                        SGTranslationSource *source = SGAITranslatorSource();
                        for (SGBatchCandidateSong *song in chunk) {
                            NSArray<NSString *> *trans = results[song.trackURI] ?: results[song.trackID];
                            if (trans.count) {
                                for (NSUInteger idx = 0; idx < song.lines.count; idx++) {
                                    SGKaraokeLine *line = song.lines[idx];
                                    NSString *t = (idx < trans.count) ? trans[idx] : nil;
                                    if (t.length) {
                                        line.translation = t;
                                        line.translationMade = YES;
                                    }
                                }
                                SGLyricsSaveTranslation(song.trackID, targetLang, song.lines, source);
                                completed++;
                            }
                        }
                        weakProcessChunk(chunkIndex + 1);
                    });
                };
                weakProcessChunk(0);
            } else if (engine == SGBatchTranslationEngineOnDevice) {
                void (^translateNext)(NSUInteger);
                __block void (^weakTranslateNext)(NSUInteger);
                weakTranslateNext = translateNext = ^(NSUInteger idx) {
                    if (idx >= total) {
                        sg_translating = NO;
                        NSString *detail = completed == 1 ? @"1 song translated and saved." : [NSString stringWithFormat:@"%lu songs translated and saved.", (unsigned long)completed];
                        [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"%@ Translated", entityName] detail:detail symbol:@"checkmark.circle"];
                        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
                        return;
                    }
                    SGBatchCandidateSong *song = candidates[idx];
                    [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"Translating %@", entityName] detail:[NSString stringWithFormat:@"%lu of %lu songs…", (unsigned long)completed, (unsigned long)total] symbol:@"translate"];
                    [SGOnDeviceTranslation translate:song.texts to:targetLang done:^(NSArray<NSString *> *translations, NSString *err) {
                        if (translations.count) {
                            for (NSUInteger lIdx = 0; lIdx < song.lines.count; lIdx++) {
                                SGKaraokeLine *line = song.lines[lIdx];
                                NSString *t = (lIdx < translations.count) ? translations[lIdx] : nil;
                                if (t.length) {
                                    line.translation = t;
                                    line.translationMade = YES;
                                }
                            }
                            SGLyricsSaveTranslation(song.trackID, targetLang, song.lines, [SGTranslationSource by:SGTranslatedOnDevice model:nil made:nil]);
                            completed++;
                        }
                        weakTranslateNext(idx + 1);
                    }];
                };
                weakTranslateNext(0);
            } else if (engine == SGBatchTranslationEngineAppleIntelligence) {
                void (^translateNext)(NSUInteger);
                __block void (^weakTranslateNext)(NSUInteger);
                weakTranslateNext = translateNext = ^(NSUInteger idx) {
                    if (idx >= total) {
                        sg_translating = NO;
                        NSString *detail = completed == 1 ? @"1 song translated and saved." : [NSString stringWithFormat:@"%lu songs translated and saved.", (unsigned long)completed];
                        [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"%@ Translated", entityName] detail:detail symbol:@"checkmark.circle"];
                        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
                        return;
                    }
                    SGBatchCandidateSong *song = candidates[idx];
                    [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"Translating %@", entityName] detail:[NSString stringWithFormat:@"%lu of %lu songs…", (unsigned long)completed, (unsigned long)total] symbol:@"apple.intelligence"];
                    [SGOnDeviceTranslation translateWithAppleIntelligence:song.texts to:targetLang song:SGLyricsSongName(song.trackID) progress:nil done:^(NSArray<NSString *> *translations, NSString *err) {
                        if (translations.count) {
                            for (NSUInteger lIdx = 0; lIdx < song.lines.count; lIdx++) {
                                SGKaraokeLine *line = song.lines[lIdx];
                                NSString *t = (lIdx < translations.count) ? translations[lIdx] : nil;
                                if (t.length) {
                                    line.translation = t;
                                    line.translationMade = YES;
                                }
                            }
                            SGLyricsSaveTranslation(song.trackID, targetLang, song.lines, [SGTranslationSource by:SGTranslatedByAppleIntelligence model:nil made:nil]);
                            completed++;
                        }
                        weakTranslateNext(idx + 1);
                    }];
                };
                weakTranslateNext(0);
            }
        });
    });
}

#pragma mark - Menu & Row UI

@interface SGBatchTranslateRow : UIButton
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, weak) UIViewController *menuController;
@end

@implementation SGBatchTranslateRow {
    UILabel *_title;
    UIImageView *_icon;
    UIImageView *_chevron;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _title = [UILabel new];
    _title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _title.adjustsFontForContentSizeCategory = YES;
    _title.textColor = UIColor.whiteColor;
    
    _icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"translate"]];
    _icon.tintColor = [UIColor colorWithWhite:1 alpha:0.65];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    
    _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    _chevron.tintColor = [UIColor colorWithWhite:1 alpha:0.35];
    _chevron.contentMode = UIViewContentModeScaleAspectFit;
    
    for (UIView *v in @[_title, _icon, _chevron]) {
        v.userInteractionEnabled = NO;
        [self addSubview:v];
    }
    self.isAccessibilityElement = YES;
    self.showsMenuAsPrimaryAction = YES;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    _icon.frame = CGRectMake(16, (h - 24) / 2, 24, 24);
    _chevron.frame = CGRectMake(MAX(0, w - 32), (h - 16) / 2, 16, 16);
    _title.frame = CGRectMake(56, 0, MAX(0, w - 96), h);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:highlighted ? 0.08 : 0];
}

- (void)configureForURI:(NSString *)uri menuController:(UIViewController *)menu {
    _uri = [uri copy];
    _menuController = menu;
    BOOL isAlbum = SGAlbumQueueIsAlbumURI(uri);
    NSString *rowTitle = isAlbum ? @"Translate Album" : @"Translate Playlist";
    _title.text = rowTitle;
    self.accessibilityLabel = rowTitle;
    self.accessibilityIdentifier = @"spotifyglass.batchTranslate";
    
    UIWindow *window = nil;
    for (UIWindow *w in menu.viewIfLoaded.window.windowScene.windows) {
        if (!w.hidden && w.windowLevel == UIWindowLevelNormal) { window = w; break; }
    }
    if (!window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (!w.hidden && w.windowLevel == UIWindowLevelNormal) { window = w; break; }
            }
            if (window) break;
        }
    }
    
    NSString *targetLang = SGLyricsTranslationTarget();
    BOOL onDevice = SGFlag(SGKeyLyricsTranslateOnDevice, YES) && SGOnDeviceTranslation.translationAvailable;
    BOOL intelligence = SGFlag(SGKeyLyricsAppleIntelligence, YES) && [SGOnDeviceTranslation appleIntelligenceAvailable:targetLang];
    BOOL ai = SGAITranslatorReady();
    
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    __weak UIViewController *weakMenu = menu;
    __weak UIWindow *weakWindow = window;
    
    if (onDevice) {
        UIAction *action = [UIAction actionWithTitle:@"Translate on iPhone" image:[UIImage systemImageNamed:@"translate"] identifier:nil handler:^(UIAction *a) {
            [weakMenu dismissViewControllerAnimated:YES completion:nil];
            SGBatchTranslateURI(uri, SGBatchTranslationEngineOnDevice, weakWindow);
        }];
        action.subtitle = @"Apple's Translate, on this iPhone";
        [items addObject:action];
    }
    if (intelligence) {
        UIAction *action = [UIAction actionWithTitle:@"Translate with Apple Intelligence" image:[UIImage systemImageNamed:@"apple.intelligence"] identifier:nil handler:^(UIAction *a) {
            [weakMenu dismissViewControllerAnimated:YES completion:nil];
            SGBatchTranslateURI(uri, SGBatchTranslationEngineAppleIntelligence, weakWindow);
        }];
        action.subtitle = @"On this iPhone";
        [items addObject:action];
    }
    if (ai) {
        NSString *title = [@"Translate with " stringByAppendingString:SGAITranslatorName()];
        NSString *subtitle = [@"Sends the lyrics to " stringByAppendingString:SGAITranslatorRecipient()];
        UIAction *action = [UIAction actionWithTitle:title image:[UIImage systemImageNamed:@"sparkles"] identifier:nil handler:^(UIAction *a) {
            [weakMenu dismissViewControllerAnimated:YES completion:nil];
            SGBatchTranslateURI(uri, SGBatchTranslationEngineAI, weakWindow);
        }];
        action.subtitle = subtitle;
        [items addObject:action];
    }
    self.menu = [UIMenu menuWithTitle:rowTitle image:[UIImage systemImageNamed:@"translate"] identifier:nil options:0 children:items];
    self.enabled = (items.count > 0);
}
@end

static UITableView *tableInView(UIView *view, NSUInteger depth) {
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    if (depth > 6) return nil;
    for (UIView *child in view.subviews) {
        UITableView *table = tableInView(child, depth + 1);
        if (table) return table;
    }
    return nil;
}

void SGBatchTranslationInstall(UIViewController *menu) {
    NSString *uri = objc_getAssociatedObject(menu, &kURIKey);
    if (!uri) {
        uri = (CACurrentMediaTime() - sg_markedAt <= 1.5) ? sg_pendingURI : nil;
        if (uri) objc_setAssociatedObject(menu, &kURIKey, uri, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    if (!SGIsValidEntityURI(uri)) return;
    
    NSString *targetLang = SGLyricsTranslationTarget();
    BOOL onDevice = SGFlag(SGKeyLyricsTranslateOnDevice, YES) && SGOnDeviceTranslation.translationAvailable;
    BOOL intelligence = SGFlag(SGKeyLyricsAppleIntelligence, YES) && [SGOnDeviceTranslation appleIntelligenceAvailable:targetLang];
    BOOL ai = SGAITranslatorReady();
    if (!onDevice && !intelligence && !ai) return;
    
    UITableView *table = tableInView(menu.viewIfLoaded, 0);
    if (table.bounds.size.width <= 0) return;
    
    SGBatchTranslateRow *row = objc_getAssociatedObject(menu, &kRowKey);
    if (!row) {
        row = [[SGBatchTranslateRow alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(menu, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [row configureForURI:uri menuController:menu];
    
    CGFloat rowHeight = MAX(56, [UIFont preferredFontForTextStyle:UIFontTextStyleBody].lineHeight + 24);
    CGFloat width = table.bounds.size.width;
    
    UIView *existingFooter = table.tableFooterView;
    if (existingFooter == row) {
        if (!CGSizeEqualToSize(row.bounds.size, CGSizeMake(width, rowHeight))) {
            [UIView performWithoutAnimation:^{
                row.frame = CGRectMake(0, 0, width, rowHeight);
                table.tableFooterView = row;
                [table invalidateIntrinsicContentSize];
                [table layoutIfNeeded];
            }];
        }
        return;
    }
    
    // If tableFooterView already contains a stack or another mod view (e.g. SGAlbumQueueRow)
    if (existingFooter && [existingFooter.subviews containsObject:row]) {
        return;
    }
    if (existingFooter && existingFooter.bounds.size.height > 0) {
        // Container view stacking existing rows + our row
        if (![existingFooter.subviews containsObject:row]) {
            UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, existingFooter.bounds.size.height + rowHeight)];
            container.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            CGFloat y = 0;
            for (UIView *sub in existingFooter.subviews) {
                sub.frame = CGRectMake(0, y, width, sub.bounds.size.height);
                y += sub.bounds.size.height;
                [container addSubview:sub];
            }
            if (existingFooter.subviews.count == 0 && [existingFooter isKindOfClass:UIControl.class]) {
                existingFooter.frame = CGRectMake(0, y, width, existingFooter.bounds.size.height);
                y += existingFooter.bounds.size.height;
                [container addSubview:existingFooter];
            }
            row.frame = CGRectMake(0, y, width, rowHeight);
            [container addSubview:row];
            container.frame = CGRectMake(0, 0, width, y + rowHeight);
            [UIView performWithoutAnimation:^{
                table.tableFooterView = container;
                [table invalidateIntrinsicContentSize];
                [table layoutIfNeeded];
            }];
        }
        return;
    }
    
    // Set row directly as footer view
    [UIView performWithoutAnimation:^{
        row.frame = CGRectMake(0, 0, width, rowHeight);
        table.tableFooterView = row;
        [table invalidateIntrinsicContentSize];
        [table layoutIfNeeded];
    }];
}

%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController
- (void)viewDidLayoutSubviews {
    %orig;
    SGBatchTranslationInstall((UIViewController *)self);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC24ContextMenu_InternalImpl25ContextMenuViewController"]);
}

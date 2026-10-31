#import "SGRQueueView.h"
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AdBlock/Protobuf.h"
#import "Shared/ArtistBlock/ArtistBlock.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/Navigation/Links.h"
#import "Player.h"

@interface SPTPlayerTrack (SGRQueueConstruct)
- (instancetype)initWithURI:(NSURL *)uri albumURI:(NSURL *)album artistURI:(NSURL *)artist andUID:(NSString *)uid;
@end

#define SGRKeyQueueAutoplay @"spotifyglass.redesign.queue.autoplay"
#define SGRKeyQueueTransitions @"spotifyglass.redesign.queue.transitions"

static NSNotificationName const SGRQueueSessionDidUpdateNotification = @"SGRQueueSessionDidUpdateNotification";

// ============================================================================
// Constants & Geometry (Measured 1:1 from Apple Music @ 390x844 pt)
// ============================================================================

static const CGFloat kGrabberWidth = 36.0;
static const CGFloat kGrabberHeight = 5.0;
static const CGFloat kViewportTopOffset = 17.0;       // Grabber at y=0 (screenY=55), Viewport at y=17 (screenY=72)
static const CGFloat kSideMargin = 28.0;              // Left/right column alignment across artwork, pills, headers & rows
static const CGFloat kNowPlayingDocY = 14.7;          // screenY = 72.0 + 14.7 = 86.7 at scrollY = 0
static const CGFloat kNowPlayingHeight = 76.0;        // 62pt thumbnail at y=0..62 + breathing room above 4-pill bar
static const CGFloat kContinueHeaderDocY = 99.7;      // screenY = 171.7 at scrollY = 0
static const CGFloat kContinueHeaderPinOffset = 12.7; // Pins at viewportY = 12.7 (screenY = 84.7, bottom = 174.7)
static const CGFloat kContinueHeaderHeight = 90.0;    // 36pt pills + 11pt gap + 43pt title/subtitle
static const CGFloat kQueueRowsStartDocY = 196.5;     // Fits 5 full 56pt queue rows inside y = 72..538 (466pt viewport)
static const CGFloat kQueueRowPitch = 56.0;
static const CGFloat kHistoryHeaderHeight = 46.0;
static const CGFloat kHistoryHeaderClipOffset = 31.0; // Clips scrolling History rows at screenY = 79.0 + 31.0 = 110.0 pt
static const CGFloat kHistoryRowPitch = 58.0;
static const CGFloat kHistoryBottomGap = 22.0;
static const CGFloat kHistoryHeaderPinOffset = 7.0;   // Pins at viewportY = 7.0 (screenY = 79.0)
static const CGFloat kHistoryHeaderPushOffDocY = -43.7; // Rises off-screen as scrollY travels from -50.7 pt to 0 pt

static const CGFloat kSwipeParkOffset = -80.0;
static const CGFloat kSwipeCommitRatio = 0.58;

// ============================================================================
// Artwork URL Resolution & Async Loader (i.scdn.co + LocalFiles cache)
// ============================================================================

static NSURL *SGRNormalizedArtworkURLFromString(NSString *val) {
    if (![val isKindOfClass:NSString.class] || !val.length) return nil;
    NSString *stored = SGLocalFileCoverInURL(val);
    if (stored.length) return [NSURL fileURLWithPath:stored];
    if ([val hasPrefix:@"spotify:image:"]) {
        NSString *imgID = [val substringFromIndex:@"spotify:image:".length];
        if (imgID.length) return [NSURL URLWithString:[@"https://i.scdn.co/image/" stringByAppendingString:imgID]];
    }
    if ([val hasPrefix:@"https://"] || [val hasPrefix:@"http://"]) {
        return [NSURL URLWithString:val];
    }
    if (val.length == 40 && [val rangeOfString:@"^[0-9a-fA-F]{40}$" options:NSRegularExpressionSearch].location != NSNotFound) {
        return [NSURL URLWithString:[@"https://i.scdn.co/image/" stringByAppendingString:val.lowercaseString]];
    }
    return nil;
}

static NSURL *SGRQueueArtworkURLForTrack(SPTPlayerTrack *track) {
    if (!track || ![track respondsToSelector:@selector(metadata)]) return nil;
    NSDictionary *metadata = track.metadata;
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *field in @[@"image_url", @"image_large_url", @"image_small_url", @"image_xlarge_url"]) {
        NSURL *url = SGRNormalizedArtworkURLFromString(metadata[field]);
        if (url) return url;
    }
    return nil;
}

static NSCache<NSString *, UIImage *> *SGRQueueImageCache(void) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 250;
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
// Multi-Artist & Explicit Helpers for SPTPlayerTrack
// ============================================================================

static NSString *SGRFormattedArtistsForTrack(SPTPlayerTrack *track) {
    if (!track) return @"";
    NSArray<NSDictionary *> *artists = SGArtistsOfTrack(track);
    if (artists.count > 0) {
        NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:artists.count];
        for (NSDictionary *entry in artists) {
            NSString *name = entry[SGArtistName];
            if ([name isKindOfClass:NSString.class] && name.length && ![names containsObject:name]) {
                [names addObject:name];
            }
        }
        if (names.count > 0) return [names componentsJoinedByString:@", "];
    }
    NSDictionary *meta = ([track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class]) ? track.metadata : nil;
    NSString *artist = [track respondsToSelector:@selector(artistName)] ? track.artistName : nil;
    if (!artist.length) artist = meta[@"artist_name"] ?: @"";
    return artist;
}

static BOOL SGRIsPlayerTrackExplicit(SPTPlayerTrack *track) {
    if (!track) return NO;
    @try {
        NSDictionary *meta = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
        if ([meta isKindOfClass:NSDictionary.class]) {
            id exp = meta[@"is_explicit"] ?: meta[@"explicit"];
            if ([exp isKindOfClass:NSString.class]) {
                return [exp isEqualToString:@"true"] || [exp isEqualToString:@"1"];
            }
            if ([exp isKindOfClass:NSNumber.class]) {
                return [exp boolValue];
            }
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

// ============================================================================
// SGRQueueItem: Unified Track Model for History & Continue Playing
// ============================================================================

@interface SGRQueueItem : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSString *uid;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *albumTitle;
@property (nonatomic, copy) NSString *albumURI;
@property (nonatomic, copy) NSString *artistURI;
@property (nonatomic, assign) BOOL isExplicit;
@property (nonatomic, strong) NSURL *artworkURL;
@property (nonatomic, assign) BOOL isUserQueued;
@property (nonatomic, strong) SPTPlayerTrack *playerTrack;
@end

@implementation SGRQueueItem

+ (instancetype)itemFromPlayerTrack:(SPTPlayerTrack *)track fallbackContextURI:(NSString *)contextURI occurrence:(NSUInteger)occurrence {
    if (!track || ![track respondsToSelector:@selector(URI)]) return nil;
    NSString *uri = SGURIString(track.URI);
    if (!uri.length) return nil;

    NSDictionary *meta = ([track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class]) ? track.metadata : nil;
    NSString *uid = [meta[@"uid"] isKindOfClass:NSString.class] ? meta[@"uid"] : @"";
    NSString *title = [track respondsToSelector:@selector(trackTitle)] ? track.trackTitle : nil;
    if (!title.length) title = [meta[@"title"] isKindOfClass:NSString.class] ? meta[@"title"] : @"";

    SGRQueueItem *item = [[SGRQueueItem alloc] init];
    item.uri = uri;
    item.uid = uid;
    item.key = uid.length ? [NSString stringWithFormat:@"%@|%@", uri, uid] : [NSString stringWithFormat:@"%@|#%lu", uri, (unsigned long)occurrence];
    item.title = title;
    item.artist = SGRFormattedArtistsForTrack(track);
    item.albumTitle = [meta[@"album_title"] isKindOfClass:NSString.class] ? meta[@"album_title"] : @"";
    item.albumURI = [meta[@"album_uri"] isKindOfClass:NSString.class] ? meta[@"album_uri"] : (contextURI ?: @"");
    item.artistURI = SGURIString([track respondsToSelector:@selector(artistURI)] ? track.artistURI : nil) ?: ([meta[@"artist_uri"] isKindOfClass:NSString.class] ? meta[@"artist_uri"] : @"");
    item.isExplicit = SGRIsPlayerTrackExplicit(track);
    item.artworkURL = SGRQueueArtworkURLForTrack(track);
    NSString *provider = ([track respondsToSelector:@selector(provider)] && [track.provider isKindOfClass:NSString.class]) ? track.provider : @"";
    NSString *queuedMeta = [meta[@"is_queued"] isKindOfClass:NSString.class] ? meta[@"is_queued"] : @"";
    item.isUserQueued = [provider isEqualToString:@"queue"] || [queuedMeta isEqualToString:@"true"] || [queuedMeta isEqualToString:@"1"];
    item.playerTrack = track;
    return item;
}

- (SPTPlayerTrack *)resolvedPlayerTrack {
    if (_playerTrack) return _playerTrack;
    if (!_uri.length) return nil;
    Class cls = NSClassFromString(@"SPTPlayerTrack");
    if ([cls instancesRespondToSelector:@selector(initWithURI:albumURI:artistURI:andUID:)]) {
        NSURL *u = [NSURL URLWithString:_uri];
        NSURL *alb = _albumURI.length ? [NSURL URLWithString:_albumURI] : nil;
        NSURL *art = _artistURI.length ? [NSURL URLWithString:_artistURI] : nil;
        _playerTrack = [[cls alloc] initWithURI:u albumURI:alb artistURI:art andUID:(_uid.length ? _uid : nil)];
    }
    return _playerTrack;
}

@end

// ============================================================================
// Protobuf Extended-Metadata Parser (spotify.metadata.Track, TRACK_V4 = 10)
// ============================================================================

@interface SGRResolvedTrackMeta : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *albumTitle;
@property (nonatomic, assign) BOOL isExplicit;
@property (nonatomic, strong) NSURL *artworkURL;
@end

@implementation SGRResolvedTrackMeta
@end

static NSArray<SGPBField *> *SGRPBAll(NSArray<SGPBField *> *fields, uint32_t number, uint8_t wire) {
    NSMutableArray<SGPBField *> *out = [NSMutableArray array];
    for (SGPBField *f in fields) {
        if (f.number == number && f.wire == wire) [out addObject:f];
    }
    return out;
}

static NSString *SGRHexFromBytes(NSData *data) {
    if (!data.length) return nil;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

static NSURL *SGRArtworkURLFromImageFields(NSArray<SGPBField *> *imageMsgFields) {
    NSString *bestHex = nil;
    uint64_t bestSizeRank = 0;
    for (SGPBField *imgField in imageMsgFields) {
        NSArray<SGPBField *> *img = SGPBParse(imgField.payload);
        if (!img) continue;
        SGPBField *fileIdField = SGRPBAll(img, 1, 2).firstObject;
        if (fileIdField.payload.length != 20) continue;
        NSString *hex = SGRHexFromBytes(fileIdField.payload);
        if (hex.length != 40) continue;
        uint64_t sizeEnum = SGRPBAll(img, 2, 0).firstObject.varint; // 0=DEFAULT(300), 1=SMALL, 2=LARGE, 3=XLARGE
        uint64_t rank = (sizeEnum == 0) ? 4 : (sizeEnum == 2 ? 3 : (sizeEnum == 1 ? 2 : 1));
        if (rank > bestSizeRank) {
            bestSizeRank = rank;
            bestHex = hex;
        }
    }
    return bestHex ? [NSURL URLWithString:[@"https://i.scdn.co/image/" stringByAppendingString:bestHex]] : nil;
}

static NSData *SGRBuildBatchedTrackMetadataRequest(NSArray<NSString *> *trackURIs) {
    NSData *query = SGPBSerialize(@[SGPBVarint(1, 10)]); // ExtensionQuery { extension_kind = 10 (TRACK_V4) }
    NSMutableArray<SGPBField *> *entities = [NSMutableArray arrayWithCapacity:trackURIs.count];
    for (NSString *uri in trackURIs) {
        NSData *entity = SGPBSerialize(@[SGPBString(1, uri), SGPBBytes(2, query)]);
        [entities addObject:SGPBBytes(2, entity)]; // BatchedEntityRequest.entity_request = 2
    }
    return SGPBSerialize(entities);
}

static NSDictionary<NSString *, SGRResolvedTrackMeta *> *SGRParseBatchedTrackMetadataReply(NSData *replyData) {
    if (!replyData.length) return @{};
    NSMutableDictionary<NSString *, SGRResolvedTrackMeta *> *results = [NSMutableDictionary dictionary];
    // BatchedExtensionResponse.extended_metadata = 2
    for (SGPBField *arrayField in SGRPBAll(SGPBParse(replyData), 2, 2)) {
        NSArray<SGPBField *> *array = SGPBParse(arrayField.payload);
        if (!array) continue;
        SGPBField *kind = SGRPBAll(array, 2, 0).firstObject;
        if (kind && kind.varint != 10) continue;
        // EntityExtensionDataArray.extension_data = 3
        for (SGPBField *dataField in SGRPBAll(array, 3, 2)) {
            NSArray<SGPBField *> *data = SGPBParse(dataField.payload);
            NSString *uri = SGPBText(SGRPBAll(data, 2, 2).firstObject);
            if (!uri.length) continue;
            SGPBField *headerField = SGRPBAll(data, 1, 2).firstObject;
            NSArray<SGPBField *> *header = headerField ? SGPBParse(headerField.payload) : nil;
            uint64_t status = SGRPBAll(header, 1, 0).firstObject.varint;
            if (status != 0 && status != 200) continue;

            SGPBField *anyField = SGRPBAll(data, 3, 2).firstObject;
            NSArray<SGPBField *> *any = anyField ? SGPBParse(anyField.payload) : nil;
            NSString *typeURL = SGPBText(SGRPBAll(any, 1, 2).firstObject);
            if (![typeURL isEqualToString:@"type.googleapis.com/spotify.metadata.Track"]) continue;
            SGPBField *valField = SGRPBAll(any, 2, 2).firstObject;
            NSArray<SGPBField *> *track = valField ? SGPBParse(valField.payload) : nil;
            if (!track) continue;

            SGRResolvedTrackMeta *meta = [[SGRResolvedTrackMeta alloc] init];
            meta.title = SGPBText(SGRPBAll(track, 2, 2).firstObject) ?: @"";
            meta.isExplicit = (SGRPBAll(track, 9, 0).firstObject.varint != 0);

            // Track.artist = repeated field 4 (Artist.name = field 2)
            NSMutableArray<NSString *> *artistNames = [NSMutableArray array];
            for (SGPBField *artField in SGRPBAll(track, 4, 2)) {
                NSArray<SGPBField *> *artMsg = SGPBParse(artField.payload);
                NSString *aName = SGPBText(SGRPBAll(artMsg, 2, 2).firstObject);
                if (aName.length && ![artistNames containsObject:aName]) {
                    [artistNames addObject:aName];
                }
            }
            meta.artist = [artistNames componentsJoinedByString:@", "];

            // Track.album = field 3 (Album.name = field 2, Album.cover = repeated field 9, Album.cover_group = field 17 -> field 1)
            SGPBField *albumField = SGRPBAll(track, 3, 2).firstObject;
            NSArray<SGPBField *> *albumMsg = albumField ? SGPBParse(albumField.payload) : nil;
            if (albumMsg) {
                meta.albumTitle = SGPBText(SGRPBAll(albumMsg, 2, 2).firstObject) ?: @"";
                SGPBField *coverGroupField = SGRPBAll(albumMsg, 17, 2).firstObject;
                NSArray<SGPBField *> *coverGroup = coverGroupField ? SGPBParse(coverGroupField.payload) : nil;
                NSURL *artURL = coverGroup ? SGRArtworkURLFromImageFields(SGRPBAll(coverGroup, 1, 2)) : nil;
                if (!artURL) {
                    artURL = SGRArtworkURLFromImageFields(SGRPBAll(albumMsg, 9, 2));
                }
                meta.artworkURL = artURL;
            }
            results[uri] = meta;
        }
    }
    return results;
}

// ============================================================================
// SGRQueueSession: Persistent Chronological History & Full Context Resolver
// ============================================================================

@interface SGRContextTrackEntry : NSObject
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSString *uid;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSDictionary *entryMetadata;
@end

@implementation SGRContextTrackEntry
@end

@interface SGRQueueSession : NSObject <SGPlayerStateObserver>
@property (nonatomic, readonly) NSArray<SGRQueueItem *> *historyItems;
@property (nonatomic, readonly) NSArray<SGRQueueItem *> *continuePlayingItems;
@property (nonatomic, readonly) SGRQueueItem *nowPlayingItem;
@property (nonatomic, readonly) NSString *contextSubtitle;
@property (nonatomic, readonly) BOOL isShuffling;

+ (instancetype)shared;
- (void)clearHistory;
- (void)deleteContinuePlayingItemWithKey:(NSString *)key;
- (void)moveContinuePlayingItemFromIndex:(NSUInteger)fromIdx toIndex:(NSUInteger)toIdx;
- (void)setOptimisticShuffle:(BOOL)shuffling;
- (BOOL)isTrackStarred:(NSString *)uri;
- (void)toggleTrackStarred:(NSString *)uri;
@end

@implementation SGRQueueSession {
    NSMutableArray<SGRQueueItem *> *_historyItems;
    NSMutableArray<SGRQueueItem *> *_continuePlayingItems;
    NSMutableArray<SGRQueueItem *> *_unshuffledContinueItems;
    NSMutableArray<NSString *> *_shuffledOrderKeys;
    NSMutableArray<NSString *> *_customOrderedKeys;

    SGRQueueItem *_nowPlayingItem;
    NSString *_activeContextURI;
    NSString *_loadingContextURI;
    NSArray<SGRContextTrackEntry *> *_contextEntries;
    NSMutableDictionary<NSString *, SGRResolvedTrackMeta *> *_metadataCache;
    NSMutableSet<NSString *> *_inFlightMetadataURIs;
    NSMutableSet<NSString *> *_deletedKeys;
    NSMutableSet<NSString *> *_starredURIs;

    BOOL _historyClearedByUser;
    BOOL _historySeededFromContext;
    NSString *_initialSeedTrackURI;
    BOOL _isShuffling;
    BOOL _hasOptimisticShuffle;
    BOOL _optimisticShuffleValue;
    CFTimeInterval _optimisticShuffleUntil;
}

+ (instancetype)shared {
    static SGRQueueSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        session = [[SGRQueueSession alloc] init];
    });
    return session;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _historyItems = [NSMutableArray array];
    _continuePlayingItems = [NSMutableArray array];
    _unshuffledContinueItems = [NSMutableArray array];
    _shuffledOrderKeys = [NSMutableArray array];
    _customOrderedKeys = [NSMutableArray array];
    _metadataCache = [NSMutableDictionary dictionary];
    _inFlightMetadataURIs = [NSMutableSet set];
    _deletedKeys = [NSMutableSet set];
    _starredURIs = [NSMutableSet set];

    SGAddPlayerStateObserver(self);
    SPTPlayerState *initial = SGPlayerState();
    if (initial) [self ingestPlayerState:initial];
    return self;
}

- (NSArray<SGRQueueItem *> *)historyItems {
    return [_historyItems copy];
}

- (NSArray<SGRQueueItem *> *)continuePlayingItems {
    return [_continuePlayingItems copy];
}

- (SGRQueueItem *)nowPlayingItem {
    return _nowPlayingItem;
}

- (BOOL)isShuffling {
    return _isShuffling;
}

- (NSString *)contextSubtitle {
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *np = state.track;
    NSDictionary *meta = ([np respondsToSelector:@selector(metadata)] && [np.metadata isKindOfClass:NSDictionary.class]) ? np.metadata : nil;
    NSString *desc = [meta[@"context_description"] isKindOfClass:NSString.class] ? meta[@"context_description"] : @"";
    if (!desc.length) desc = [meta[@"album_title"] isKindOfClass:NSString.class] ? meta[@"album_title"] : @"";
    if (!desc.length) desc = _nowPlayingItem.albumTitle ?: @"";
    if ([desc hasSuffix:@"."]) desc = [desc substringToIndex:desc.length - 1];
    return desc.length ? [NSString stringWithFormat:@"From %@", desc] : @"Autoplay";
}

- (BOOL)isTrackStarred:(NSString *)uri {
    return uri.length ? [_starredURIs containsObject:uri] : NO;
}

- (void)toggleTrackStarred:(NSString *)uri {
    if (!uri.length) return;
    if ([_starredURIs containsObject:uri]) [_starredURIs removeObject:uri];
    else [_starredURIs addObject:uri];
}

- (void)clearHistory {
    _historyClearedByUser = YES;
    [_historyItems removeAllObjects];
    [self notifyObservers];
}

- (void)deleteContinuePlayingItemWithKey:(NSString *)key {
    if (!key.length) return;
    [_deletedKeys addObject:key];
    [_shuffledOrderKeys removeObject:key];
    [_customOrderedKeys removeObject:key];
    for (NSUInteger i = 0; i < _continuePlayingItems.count; i++) {
        if ([_continuePlayingItems[i].key isEqualToString:key]) {
            [_continuePlayingItems removeObjectAtIndex:i];
            break;
        }
    }
    for (NSUInteger i = 0; i < _unshuffledContinueItems.count; i++) {
        if ([_unshuffledContinueItems[i].key isEqualToString:key]) {
            [_unshuffledContinueItems removeObjectAtIndex:i];
            break;
        }
    }
}

- (void)moveContinuePlayingItemFromIndex:(NSUInteger)fromIdx toIndex:(NSUInteger)toIdx {
    if (fromIdx >= _continuePlayingItems.count || toIdx >= _continuePlayingItems.count || fromIdx == toIdx) return;
    SGRQueueItem *moved = _continuePlayingItems[fromIdx];
    [_continuePlayingItems removeObjectAtIndex:fromIdx];
    [_continuePlayingItems insertObject:moved atIndex:toIdx];

    [_customOrderedKeys removeAllObjects];
    for (SGRQueueItem *it in _continuePlayingItems) {
        [_customOrderedKeys addObject:it.key];
    }
    if (_isShuffling) {
        [_shuffledOrderKeys setArray:_customOrderedKeys];
    }
}

- (void)setOptimisticShuffle:(BOOL)shuffling {
    _hasOptimisticShuffle = YES;
    _optimisticShuffleValue = shuffling;
    _optimisticShuffleUntil = CACurrentMediaTime() + 1.0;
    [_customOrderedKeys removeAllObjects];
    if (shuffling != _isShuffling) {
        _isShuffling = shuffling;
        if (shuffling) {
            [_shuffledOrderKeys removeAllObjects];
        }
        [self rebuildContinuePlayingWithState:SGPlayerState() shuffleJustTurnedOn:shuffling];
        [self notifyObservers];
    }
}

- (void)notifyObservers {
    [NSNotificationCenter.defaultCenter postNotificationName:SGRQueueSessionDidUpdateNotification object:self];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (!state) return;
    [self ingestPlayerState:state];
}

- (void)harvestMetadataFromPlayerTrack:(SPTPlayerTrack *)track {
    if (!track || ![track respondsToSelector:@selector(URI)]) return;
    NSString *uri = SGURIString(track.URI);
    if (!uri.length) return;
    NSDictionary *meta = ([track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class]) ? track.metadata : nil;
    NSString *title = [track respondsToSelector:@selector(trackTitle)] ? track.trackTitle : meta[@"title"];
    if (![title isKindOfClass:NSString.class] || !title.length) return;

    SGRResolvedTrackMeta *resolved = _metadataCache[uri] ?: [[SGRResolvedTrackMeta alloc] init];
    resolved.title = title;
    NSString *artists = SGRFormattedArtistsForTrack(track);
    if (artists.length) resolved.artist = artists;
    NSString *album = [meta[@"album_title"] isKindOfClass:NSString.class] ? meta[@"album_title"] : @"";
    if (album.length) resolved.albumTitle = album;
    resolved.isExplicit = SGRIsPlayerTrackExplicit(track);
    NSURL *art = SGRQueueArtworkURLForTrack(track);
    if (art) resolved.artworkURL = art;
    _metadataCache[uri] = resolved;
}

- (NSString *)effectiveContextURIForState:(SPTPlayerState *)state {
    NSString *ctx = SGURIString([state respondsToSelector:@selector(contextURI)] ? state.contextURI : nil);
    SPTPlayerTrack *np = state.track;
    NSDictionary *meta = ([np respondsToSelector:@selector(metadata)] && [np.metadata isKindOfClass:NSDictionary.class]) ? np.metadata : nil;
    if (!ctx.length && [meta[@"context_uri"] isKindOfClass:NSString.class]) ctx = meta[@"context_uri"];
    if ((!ctx.length || [ctx hasPrefix:@"spotify:track:"]) && [meta[@"album_uri"] isKindOfClass:NSString.class]) {
        ctx = meta[@"album_uri"];
    }
    return ctx ?: @"";
}

- (void)ingestPlayerState:(SPTPlayerState *)state {
    SPTPlayerTrack *np = state.track;
    NSArray *rawReverse = ([state respondsToSelector:@selector(reverse)] && [state.reverse isKindOfClass:NSArray.class]) ? state.reverse : @[];
    NSArray *rawFuture = ([state respondsToSelector:@selector(future)] && [state.future isKindOfClass:NSArray.class]) ? state.future : @[];

    [self harvestMetadataFromPlayerTrack:np];
    for (id t in rawReverse) {
        if ([t respondsToSelector:@selector(URI)]) [self harvestMetadataFromPlayerTrack:(SPTPlayerTrack *)t];
    }
    for (id t in rawFuture) {
        if ([t respondsToSelector:@selector(URI)]) [self harvestMetadataFromPlayerTrack:(SPTPlayerTrack *)t];
    }

    NSString *ctxURI = [self effectiveContextURIForState:state];
    BOOL contextChanged = (ctxURI.length > 0 && ![_activeContextURI isEqualToString:ctxURI]);
    if (contextChanged) {
        _activeContextURI = [ctxURI copy];
        _contextEntries = nil;
        [_deletedKeys removeAllObjects];
        [_shuffledOrderKeys removeAllObjects];
        [_customOrderedKeys removeAllObjects];
        _historySeededFromContext = NO;
        [self resolveContextIfSupported:ctxURI];
    }

    BOOL reportedShuffle = state.options ? state.options.shufflingContext : NO;
    if (_hasOptimisticShuffle) {
        if (reportedShuffle == _optimisticShuffleValue || CACurrentMediaTime() >= _optimisticShuffleUntil) {
            _hasOptimisticShuffle = NO;
        } else {
            reportedShuffle = _optimisticShuffleValue;
        }
    }
    BOOL shuffleChanged = (reportedShuffle != _isShuffling);
    _isShuffling = reportedShuffle;
    if (shuffleChanged) {
        [_customOrderedKeys removeAllObjects];
        if (!_isShuffling) {
            [_shuffledOrderKeys removeAllObjects];
        }
    }

    SGRQueueItem *incomingNP = [SGRQueueItem itemFromPlayerTrack:np fallbackContextURI:ctxURI occurrence:0];
    [self enrichQueueItem:incomingNP];

    NSString *prevURI = _nowPlayingItem.uri;
    NSString *newURI = incomingNP.uri;

    // Update independent chronological History ONLY on genuine track transitions or one-time initial seed.
    // Toggling Shuffle NEVER mutates or re-slices _historyItems!
    if (!prevURI.length && newURI.length) {
        _nowPlayingItem = incomingNP;
        _initialSeedTrackURI = [newURI copy];
        if (!_historyClearedByUser && _historyItems.count == 0) {
            [self seedInitialHistoryFromState:state];
        }
    } else if (newURI.length && ![newURI isEqualToString:prevURI]) {
        if (_historyItems.count > 0 && [_historyItems.lastObject.uri isEqualToString:newURI]) {
            // User skipped backward into the most recent History item: pop it cleanly
            [_historyItems removeLastObject];
        } else if (_nowPlayingItem) {
            // Track advanced forward: append finished track chronologically to History
            _historyClearedByUser = NO;
            [_historyItems addObject:_nowPlayingItem];
            if (_historyItems.count > 100) {
                [_historyItems removeObjectsInRange:NSMakeRange(0, _historyItems.count - 100)];
            }
        }
        _nowPlayingItem = incomingNP;
        [_shuffledOrderKeys removeObject:incomingNP.key];
        [_customOrderedKeys removeObject:incomingNP.key];
    } else if (incomingNP) {
        _nowPlayingItem = incomingNP;
    }

    for (SGRQueueItem *h in _historyItems) [self enrichQueueItem:h];

    [self rebuildContinuePlayingWithState:state shuffleJustTurnedOn:(shuffleChanged && _isShuffling)];
    [self notifyObservers];
}

- (void)seedInitialHistoryFromState:(SPTPlayerState *)state {
    if (_historyClearedByUser) return;
    if (!_isShuffling && _contextEntries.count > 0 && _nowPlayingItem) {
        NSInteger idx = [self indexOfItem:_nowPlayingItem inContextEntries:_contextEntries];
        if (idx > 0) {
            [_historyItems removeAllObjects];
            for (NSInteger i = 0; i < idx; i++) {
                SGRQueueItem *it = [self itemFromContextEntry:_contextEntries[(NSUInteger)i] index:(NSUInteger)i];
                if (it) [_historyItems addObject:it];
            }
            _historySeededFromContext = YES;
            return;
        }
    }
    if (_historyItems.count > 0) return;
    NSArray *rawReverse = ([state respondsToSelector:@selector(reverse)] && [state.reverse isKindOfClass:NSArray.class]) ? state.reverse : @[];
    NSMutableArray<SGRQueueItem *> *recentFirst = [NSMutableArray array];
    NSString *lastURI = _nowPlayingItem.uri ?: @"";
    NSUInteger occ = 0;
    for (id obj in rawReverse) {
        if (![obj respondsToSelector:@selector(URI)]) continue;
        SPTPlayerTrack *t = (SPTPlayerTrack *)obj;
        NSString *u = SGURIString(t.URI);
        if (!u.length || [u isEqualToString:lastURI]) continue;
        lastURI = u;
        SGRQueueItem *it = [SGRQueueItem itemFromPlayerTrack:t fallbackContextURI:_activeContextURI occurrence:occ++];
        if (it) {
            [self enrichQueueItem:it];
            [recentFirst addObject:it];
        }
    }
    for (SGRQueueItem *it in [recentFirst reverseObjectEnumerator]) {
        [_historyItems addObject:it];
    }
}

- (NSInteger)indexOfItem:(SGRQueueItem *)item inContextEntries:(NSArray<SGRContextTrackEntry *> *)entries {
    if (!item || !entries.count) return NSNotFound;
    if (item.uid.length) {
        for (NSUInteger i = 0; i < entries.count; i++) {
            if ([entries[i].uid isEqualToString:item.uid]) return (NSInteger)i;
        }
    }
    for (NSUInteger i = 0; i < entries.count; i++) {
        if ([entries[i].uri isEqualToString:item.uri]) return (NSInteger)i;
    }
    return NSNotFound;
}

- (SGRQueueItem *)itemFromContextEntry:(SGRContextTrackEntry *)entry index:(NSUInteger)idx {
    if (!entry.uri.length) return nil;
    SGRQueueItem *item = [[SGRQueueItem alloc] init];
    item.uri = entry.uri;
    item.uid = entry.uid ?: @"";
    item.key = entry.key;
    if ([_activeContextURI hasPrefix:@"spotify:album:"]) {
        item.albumURI = _activeContextURI;
    }
    NSDictionary *em = entry.entryMetadata;
    if ([em isKindOfClass:NSDictionary.class]) {
        if ([em[@"title"] isKindOfClass:NSString.class]) item.title = em[@"title"];
        if ([em[@"artist_name"] isKindOfClass:NSString.class]) item.artist = em[@"artist_name"];
        if ([em[@"album_title"] isKindOfClass:NSString.class]) item.albumTitle = em[@"album_title"];
        if ([em[@"image_url"] isKindOfClass:NSString.class]) item.artworkURL = SGRNormalizedArtworkURLFromString(em[@"image_url"]);
    }
    [self enrichQueueItem:item];
    if (!item.title.length) {
        item.title = [NSString stringWithFormat:@"Track %lu", (unsigned long)(idx + 1)];
    }
    return item;
}

- (void)enrichQueueItem:(SGRQueueItem *)item {
    if (!item.uri.length) return;
    SGRResolvedTrackMeta *meta = _metadataCache[item.uri];
    if (meta) {
        if (meta.title.length) item.title = meta.title;
        if (meta.artist.length) item.artist = meta.artist;
        if (meta.albumTitle.length) item.albumTitle = meta.albumTitle;
        item.isExplicit = meta.isExplicit;
        if (meta.artworkURL) item.artworkURL = meta.artworkURL;
    }
    // Same-album fallback so album tracks immediately share cached album artwork & title even before metadata arrives
    if (!item.artworkURL && _nowPlayingItem.artworkURL &&
        ([_activeContextURI hasPrefix:@"spotify:album:"] || (item.albumTitle.length && [item.albumTitle isEqualToString:_nowPlayingItem.albumTitle]))) {
        item.artworkURL = _nowPlayingItem.artworkURL;
    }
    if (!item.albumTitle.length && [_activeContextURI hasPrefix:@"spotify:album:"] && _nowPlayingItem.albumTitle.length) {
        item.albumTitle = _nowPlayingItem.albumTitle;
    }
}

- (void)rebuildContinuePlayingWithState:(SPTPlayerState *)state shuffleJustTurnedOn:(BOOL)shuffleJustTurnedOn {
    NSArray *rawFuture = ([state respondsToSelector:@selector(future)] && [state.future isKindOfClass:NSArray.class]) ? state.future : @[];
    NSMutableArray<SGRQueueItem *> *userQueued = [NSMutableArray array];
    NSMutableArray<SGRQueueItem *> *liveContextFuture = [NSMutableArray array];
    NSMutableDictionary<NSString *, SPTPlayerTrack *> *liveTrackByURI = [NSMutableDictionary dictionary];

    NSUInteger occ = 0;
    for (id obj in rawFuture) {
        if (![obj respondsToSelector:@selector(URI)]) continue;
        SPTPlayerTrack *t = (SPTPlayerTrack *)obj;
        SGRQueueItem *it = [SGRQueueItem itemFromPlayerTrack:t fallbackContextURI:_activeContextURI occurrence:occ++];
        if (!it) continue;
        [self enrichQueueItem:it];
        if (!liveTrackByURI[it.uri]) liveTrackByURI[it.uri] = t;
        if ([_deletedKeys containsObject:it.key]) continue;
        if (it.isUserQueued) {
            [userQueued addObject:it];
        } else {
            [liveContextFuture addObject:it];
        }
    }

    // Build full unshuffled remaining context tracks: tracks[(currentIndex + 1)...] with ZERO 2-track cap
    NSMutableArray<SGRQueueItem *> *unshuffled = [NSMutableArray array];
    NSMutableArray<SGRQueueItem *> *allOtherContextItems = [NSMutableArray array];

    if (_contextEntries.count > 0 && _nowPlayingItem) {
        NSInteger curIdx = [self indexOfItem:_nowPlayingItem inContextEntries:_contextEntries];
        if (curIdx != NSNotFound) {
            for (NSUInteger i = 0; i < _contextEntries.count; i++) {
                if ((NSInteger)i == curIdx) continue;
                SGRContextTrackEntry *entry = _contextEntries[i];
                if ([_deletedKeys containsObject:entry.key]) continue;
                SGRQueueItem *it = [self itemFromContextEntry:entry index:i];
                if (!it) continue;
                if (liveTrackByURI[it.uri]) it.playerTrack = liveTrackByURI[it.uri];
                [allOtherContextItems addObject:it];
                if ((NSInteger)i > curIdx) {
                    [unshuffled addObject:it];
                }
            }
        }
    }

    if (unshuffled.count == 0 && allOtherContextItems.count == 0) {
        [unshuffled addObjectsFromArray:liveContextFuture];
        [allOtherContextItems addObjectsFromArray:liveContextFuture];
    }

    [_unshuffledContinueItems setArray:unshuffled];

    NSMutableArray<SGRQueueItem *> *finalList = [NSMutableArray array];
    [finalList addObjectsFromArray:userQueued];

    if (!_isShuffling) {
        [finalList addObjectsFromArray:unshuffled];
    } else {
        // Shuffled mode: preserve remaining tracks (or full context pool minus current track) in a stable shuffled order,
        // placing Spotify's live state.future lookahead first when Spotify itself is already shuffling.
        NSArray<SGRQueueItem *> *pool = unshuffled.count > 0 ? unshuffled : allOtherContextItems;
        NSMutableDictionary<NSString *, SGRQueueItem *> *poolByKey = [NSMutableDictionary dictionaryWithCapacity:pool.count];
        NSMutableDictionary<NSString *, SGRQueueItem *> *poolByURI = [NSMutableDictionary dictionaryWithCapacity:pool.count];
        for (SGRQueueItem *it in pool) {
            poolByKey[it.key] = it;
            if (!poolByURI[it.uri]) poolByURI[it.uri] = it;
        }

        if (_shuffledOrderKeys.count == 0 || shuffleJustTurnedOn) {
            NSMutableArray<SGRQueueItem *> *working = [pool mutableCopy];
            for (NSUInteger i = working.count; i > 1; i--) {
                NSUInteger j = arc4random_uniform((uint32_t)i);
                [working exchangeObjectAtIndex:i - 1 withObjectAtIndex:j];
            }
            [_shuffledOrderKeys removeAllObjects];
            if (state.options.shufflingContext) {
                for (SGRQueueItem *lf in liveContextFuture) {
                    SGRQueueItem *match = poolByKey[lf.key] ?: poolByURI[lf.uri];
                    if (match && ![_shuffledOrderKeys containsObject:match.key]) {
                        [_shuffledOrderKeys addObject:match.key];
                    }
                }
            }
            for (SGRQueueItem *it in working) {
                if (![_shuffledOrderKeys containsObject:it.key]) {
                    [_shuffledOrderKeys addObject:it.key];
                }
            }
        } else if (state.options.shufflingContext && liveContextFuture.count > 0) {
            // Keep Row 0 aligned with Spotify's actual next shuffled track when core advances
            SGRQueueItem *firstLive = liveContextFuture.firstObject;
            SGRQueueItem *match = poolByKey[firstLive.key] ?: poolByURI[firstLive.uri];
            if (match && ![_shuffledOrderKeys.firstObject isEqualToString:match.key]) {
                [_shuffledOrderKeys removeObject:match.key];
                [_shuffledOrderKeys insertObject:match.key atIndex:0];
            }
        }

        NSMutableSet<NSString *> *used = [NSMutableSet set];
        for (NSString *k in _shuffledOrderKeys) {
            SGRQueueItem *it = poolByKey[k];
            if (it && ![used containsObject:k]) {
                [used addObject:k];
                [finalList addObject:it];
            }
        }
        for (SGRQueueItem *it in pool) {
            if (![used containsObject:it.key]) {
                [used addObject:it.key];
                [_shuffledOrderKeys addObject:it.key];
                [finalList addObject:it];
            }
        }
    }

    if (_customOrderedKeys.count > 0) {
        NSMutableDictionary<NSString *, SGRQueueItem *> *byKey = [NSMutableDictionary dictionaryWithCapacity:finalList.count];
        for (SGRQueueItem *it in finalList) byKey[it.key] = it;
        NSMutableArray<SGRQueueItem *> *reordered = [NSMutableArray arrayWithCapacity:finalList.count];
        NSMutableSet<NSString *> *placed = [NSMutableSet set];
        for (NSString *k in _customOrderedKeys) {
            SGRQueueItem *it = byKey[k];
            if (it && ![placed containsObject:k]) {
                [placed addObject:k];
                [reordered addObject:it];
            }
        }
        for (SGRQueueItem *it in finalList) {
            if (![placed containsObject:it.key]) {
                [placed addObject:it.key];
                [reordered addObject:it];
            }
        }
        [finalList setArray:reordered];
    }

    [_continuePlayingItems setArray:finalList];
}

#pragma mark - spclient Context & Extended Metadata Resolution

- (void)resolveContextIfSupported:(NSString *)contextURI {
    if (!contextURI.length) return;
    if (!([contextURI hasPrefix:@"spotify:album:"] ||
          [contextURI hasPrefix:@"spotify:playlist:"] ||
          [contextURI hasPrefix:@"spotify:artist:"] ||
          [contextURI hasPrefix:@"spotify:collection"])) {
        return;
    }
    if ([_loadingContextURI isEqualToString:contextURI]) return;
    _loadingContextURI = [contextURI copy];

    __weak typeof(self) weakSelf = self;
    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *headers) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf->_activeContextURI isEqualToString:contextURI] || !headers.count) return;

        NSMutableArray<SGRContextTrackEntry *> *collected = [NSMutableArray array];
        __block NSUInteger pageCount = 0;
        __block void (^fetchPage)(NSString *) = ^(NSString *urlString) {
            if ([urlString hasPrefix:@"hm://"]) {
                urlString = [@"https://spclient.wg.spotify.com/" stringByAppendingString:[urlString substringFromIndex:5]];
            } else if ([urlString hasPrefix:@"/"]) {
                urlString = [@"https://spclient.wg.spotify.com" stringByAppendingString:urlString];
            }
            NSURL *url = [NSURL URLWithString:urlString];
            if (!url) {
                fetchPage = nil;
                return;
            }
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
            req.timeoutInterval = 12.0;
            req.allHTTPHeaderFields = headers;
            [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
            [NSURLProtocol setProperty:@YES forKey:SGLyricsOwnRequestKey inRequest:req];

            [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
                id json = (status == 200 && data.length > 0 && !err) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                NSString *nextPage = nil;
                if ([json isKindOfClass:NSDictionary.class]) {
                    NSArray *pages = json[@"pages"];
                    if ([pages isKindOfClass:NSArray.class]) {
                        for (id page in pages) {
                            if (![page isKindOfClass:NSDictionary.class]) continue;
                            if ([page[@"next_page_url"] isKindOfClass:NSString.class] && [page[@"next_page_url"] length]) {
                                nextPage = page[@"next_page_url"];
                            }
                            NSArray *tracks = page[@"tracks"];
                            if (![tracks isKindOfClass:NSArray.class]) continue;
                            for (id entry in tracks) {
                                if (![entry isKindOfClass:NSDictionary.class]) continue;
                                NSString *tURI = entry[@"uri"];
                                if (![tURI isKindOfClass:NSString.class] || ![tURI hasPrefix:@"spotify:track:"]) continue;
                                SGRContextTrackEntry *ce = [[SGRContextTrackEntry alloc] init];
                                ce.uri = tURI;
                                ce.uid = [entry[@"uid"] isKindOfClass:NSString.class] ? entry[@"uid"] : @"";
                                ce.key = ce.uid.length ? [NSString stringWithFormat:@"%@|%@", tURI, ce.uid]
                                                       : [NSString stringWithFormat:@"%@|#%lu", tURI, (unsigned long)collected.count];
                                if ([entry[@"metadata"] isKindOfClass:NSDictionary.class]) {
                                    ce.entryMetadata = entry[@"metadata"];
                                }
                                [collected addObject:ce];
                            }
                        }
                    }
                }
                pageCount++;
                if (nextPage.length && pageCount < 8 && collected.count < 500) {
                    fetchPage(nextPage);
                } else {
                    fetchPage = nil;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) s = weakSelf;
                        if (!s || ![s->_activeContextURI isEqualToString:contextURI]) return;
                        s->_loadingContextURI = nil;
                        if (collected.count == 0) return;
                        s->_contextEntries = [collected copy];
                        if (!s->_historyClearedByUser && !s->_historySeededFromContext && !s->_isShuffling &&
                            s->_nowPlayingItem && [s->_nowPlayingItem.uri isEqualToString:s->_initialSeedTrackURI]) {
                            [s seedInitialHistoryFromState:SGPlayerState()];
                        }
                        [s rebuildContinuePlayingWithState:SGPlayerState() shuffleJustTurnedOn:NO];
                        [s notifyObservers];
                        [s fetchMissingExtendedMetadataForEntries:collected headers:headers contextURI:contextURI];
                    });
                }
            }] resume];
        };
        fetchPage([@"https://spclient.wg.spotify.com/context-resolve/v1/" stringByAppendingString:contextURI]);
    });
}

- (void)fetchMissingExtendedMetadataForEntries:(NSArray<SGRContextTrackEntry *> *)entries
                                       headers:(NSDictionary<NSString *, NSString *> *)headers
                                    contextURI:(NSString *)contextURI {
    NSMutableArray<NSString *> *needed = [NSMutableArray array];
    for (SGRContextTrackEntry *ce in entries) {
        if (ce.uri.length == 36 && [ce.uri hasPrefix:@"spotify:track:"] &&
            !_metadataCache[ce.uri] && ![_inFlightMetadataURIs containsObject:ce.uri]) {
            [_inFlightMetadataURIs addObject:ce.uri];
            [needed addObject:ce.uri];
        }
    }
    if (needed.count == 0) return;

    __weak typeof(self) weakSelf = self;
    NSUInteger batchSize = 90;
    for (NSUInteger offset = 0; offset < needed.count; offset += batchSize) {
        NSArray<NSString *> *chunk = [needed subarrayWithRange:NSMakeRange(offset, MIN(batchSize, needed.count - offset))];
        NSData *body = SGRBuildBatchedTrackMetadataRequest(chunk);
        NSURL *url = [NSURL URLWithString:@"https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata"];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        req.timeoutInterval = 12.0;
        req.allHTTPHeaderFields = headers;
        [req setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
        [req setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];
        req.HTTPBody = body;
        [NSURLProtocol setProperty:@YES forKey:SGLyricsOwnRequestKey inRequest:req];

        [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
            NSDictionary<NSString *, SGRResolvedTrackMeta *> *parsed = (status == 200 && data.length > 0 && !err)
                ? SGRParseBatchedTrackMetadataReply(data) : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s = weakSelf;
                if (!s) return;
                for (NSString *u in chunk) [s->_inFlightMetadataURIs removeObject:u];
                if (parsed.count > 0) {
                    [s->_metadataCache addEntriesFromDictionary:parsed];
                    for (SGRQueueItem *h in s->_historyItems) [s enrichQueueItem:h];
                    if (s->_nowPlayingItem) [s enrichQueueItem:s->_nowPlayingItem];
                    if ([s->_activeContextURI isEqualToString:contextURI]) {
                        [s rebuildContinuePlayingWithState:SGPlayerState() shuffleJustTurnedOn:NO];
                    }
                    [s notifyObservers];
                }
            });
        }] resume];
    }
}

@end

// ============================================================================
// Explicit "E" Badge & Apple Music Overlapping Two-Circles AutoMix/Transitions Icon
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

// Draws Apple Music's exact overlapping two-circles AutoMix/Transitions glyph into the current context,
// centered at `center` (left 58%-opacity stroked ring occluded on the right by a 100%-opacity solid donut).
static void SGRDrawTransitionsOverlappingCircles(CGContextRef cg, CGPoint center, UIColor *inkColor) {
    CGFloat leftX = center.x - 4.2;
    CGFloat rightX = center.x + 4.2;
    CGFloat leftR = 5.6;
    CGFloat rightOuterR = 6.6;
    CGFloat rightInnerR = 2.2;

    // Render into a transparency layer so the right disc cleanly occludes the overlapping arc of the left ring
    CGContextSaveGState(cg);
    CGContextBeginTransparencyLayer(cg, NULL);

    // 1. Left circle ring at 58% alpha
    UIBezierPath *leftRing = [UIBezierPath bezierPathWithArcCenter:CGPointMake(leftX, center.y)
                                                            radius:leftR
                                                        startAngle:0
                                                          endAngle:(CGFloat)(M_PI * 2.0)
                                                         clockwise:YES];
    leftRing.lineWidth = 2.0;
    [[inkColor colorWithAlphaComponent:0.58] setStroke];
    [leftRing stroke];

    // 2. Clear overlapping interior under the right disc (+1.1pt separation gap)
    CGContextSetBlendMode(cg, kCGBlendModeClear);
    UIBezierPath *occluder = [UIBezierPath bezierPathWithArcCenter:CGPointMake(rightX, center.y)
                                                            radius:rightOuterR + 0.6
                                                        startAngle:0
                                                          endAngle:(CGFloat)(M_PI * 2.0)
                                                         clockwise:YES];
    [occluder fill];

    // 3. Draw right solid donut (outer disc minus center hole)
    CGContextSetBlendMode(cg, kCGBlendModeNormal);
    UIBezierPath *rightDonut = [UIBezierPath bezierPathWithArcCenter:CGPointMake(rightX, center.y)
                                                              radius:rightOuterR
                                                          startAngle:0
                                                            endAngle:(CGFloat)(M_PI * 2.0)
                                                           clockwise:YES];
    [rightDonut appendPath:[[UIBezierPath bezierPathWithArcCenter:CGPointMake(rightX, center.y)
                                                           radius:rightInnerR
                                                       startAngle:0
                                                         endAngle:(CGFloat)(M_PI * 2.0)
                                                        clockwise:YES] bezierPathByReversingPath]];
    [inkColor setFill];
    [rightDonut fill];

    CGContextEndTransparencyLayer(cg);
    CGContextRestoreGState(cg);
}

static UIImage *SGRRenderPillCapsuleImage(CGSize size, BOOL active, NSString *symbolName, BOOL isTransitionsGlyph) {
    if (size.width < 10.0 || size.height < 10.0) size = CGSizeMake(76.0, 36.0);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef cg = ctx.CGContext;
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        UIBezierPath *capsule = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:size.height * 0.5];

        // Inactive: rgba(255,255,255,0.12) + 100% white icon
        // Active:   rgba(255,255,255,0.88) + destinationOut knocked-out icon
        UIColor *fill = active ? [UIColor colorWithWhite:1.0 alpha:0.88] : [UIColor colorWithWhite:1.0 alpha:0.12];
        [fill setFill];
        [capsule fill];

        CGPoint center = CGPointMake(size.width * 0.5, size.height * 0.5);
        if (active) {
            CGContextSetBlendMode(cg, kCGBlendModeDestinationOut);
        }

        if (isTransitionsGlyph) {
            SGRDrawTransitionsOverlappingCircles(cg, center, UIColor.whiteColor);
        } else if (symbolName.length) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15.5 weight:UIImageSymbolWeightBold];
            UIImage *sym = [[UIImage systemImageNamed:symbolName withConfiguration:cfg] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            if (sym) {
                CGRect symRect = CGRectMake(center.x - sym.size.width * 0.5,
                                            center.y - sym.size.height * 0.5,
                                            sym.size.width,
                                            sym.size.height);
                [sym drawInRect:symRect blendMode:(active ? kCGBlendModeDestinationOut : kCGBlendModeNormal) alpha:1.0];
            }
        }
    }];
}

// ============================================================================
// SGRQueueRowView: Individual Track Row (Zero 1px Dividers, Cached Artwork)
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
@property (nonatomic, strong) SGRQueueItem *item;
@property (nonatomic, assign) NSInteger rowIndex;
@property (nonatomic, assign) BOOL isHistory;
@property (nonatomic, assign) BOOL showsHandle;
@property (nonatomic, assign, readonly) BOOL isSwipeParked;
@property (nonatomic, strong, readonly) UIImageView *artView;

- (void)configureWithItem:(SGRQueueItem *)item isHistory:(BOOL)isHistory rowIndex:(NSInteger)rowIndex;
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

    _rowContentView = [[UIView alloc] initWithFrame:self.bounds];
    _rowContentView.backgroundColor = UIColor.clearColor;
    [self addSubview:_rowContentView];

    _artView = [[UIImageView alloc] initWithFrame:CGRectMake(kSideMargin, 5.5, 45.0, 45.0)];
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

- (void)configureWithItem:(SGRQueueItem *)item isHistory:(BOOL)isHistory rowIndex:(NSInteger)rowIndex {
    _item = item;
    _isHistory = isHistory;
    _rowIndex = rowIndex;
    _showsHandle = !isHistory;
    _handleHitView.hidden = isHistory;
    _swipePan.enabled = !isHistory;

    _titleLabel.text = item.title.length ? item.title : @"Unknown Track";
    _subtitleLabel.text = item.artist ?: @"";
    _explicitView.hidden = !item.isExplicit;

    NSURL *artURL = item.artworkURL;
    NSString *urlKey = artURL.absoluteString ?: @"";
    if (urlKey.length && ![urlKey isEqualToString:_loadedArtURL]) {
        _loadedArtURL = [urlKey copy];
        UIImage *cached = [SGRQueueImageCache() objectForKey:urlKey];
        if (cached) {
            _artView.image = cached;
        } else {
            NSString *expected = _loadedArtURL;
            __weak typeof(self) weakSelf = self;
            SGRLoadQueueArtwork(artURL, ^(UIImage *image) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || ![strongSelf->_loadedArtURL isEqualToString:expected]) return;
                if (image) strongSelf->_artView.image = image;
            });
        }
    } else if (!urlKey.length && !_artView.image) {
        UIImage *liveNP = SGRNowPlayingArtwork(NULL, NULL);
        if (liveNP) _artView.image = liveNP;
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
    _artView.frame = CGRectMake(kSideMargin, artY, 45.0, 45.0);

    // 3-line handle aligned to right margin (bars at x = w - 49 .. w - 28)
    CGFloat handleTouchW = 54.0;
    _handleHitView.frame = CGRectMake(w - 60.0, 0, handleTouchW, h);
    CGFloat barLeft = 60.0 - 49.0;
    CGFloat barTop = (h - 10.0) * 0.5;
    UIBezierPath *bars = [UIBezierPath bezierPath];
    for (int i = 0; i < 3; i++) {
        CGRect r = CGRectMake(barLeft, barTop + i * 4.2, 21.0, 1.6);
        [bars appendPath:[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:0.8]];
    }
    _handleBarsLayer.path = bars.CGPath;

    CGFloat textLeft = kSideMargin + 45.0 + 14.0; // 87.0 pt
    CGFloat maxRight = _showsHandle ? (w - 64.0) : (w - kSideMargin);
    CGFloat availW = MAX(40.0, maxRight - textLeft);

    BOOL hasExp = !_explicitView.hidden;
    CGFloat badgeW = hasExp ? (13.5 + 5.0) : 0.0;
    CGSize naturalTitle = [_titleLabel sizeThatFits:CGSizeMake(availW - badgeW, 24.0)];
    CGFloat titleW = MIN(availW - badgeW, ceil(naturalTitle.width));

    _titleLabel.frame = CGRectMake(textLeft, 8.5, titleW, 20.5);
    if (hasExp) {
        _explicitView.frame = CGRectMake(textLeft + titleW + 5.0, 12.0, 13.5, 13.5);
    }
    _subtitleLabel.frame = CGRectMake(textLeft, 29.5, availW, 18.0);

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
                _isSwipeParked = YES;
                _committedFullSwipe = NO;
                _swipeOffsetX = kSwipeParkOffset;
                [UIView animateWithDuration:0.32 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction animations:^{
                    self->_rowContentView.frame = CGRectMake(kSwipeParkOffset, 0, w, self.bounds.size.height);
                    [self layoutDeleteCapsule];
                } completion:^(BOOL finished) {
                    if (finished && self->_isSwipeParked && !self->_isDeleting) {
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

- (void)handleDeleteCapsuleTap:(__unused UITapGestureRecognizer *)tap {
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
        } completion:^(__unused BOOL finished) {
            triggerCollapse();
        }];
    } else {
        triggerCollapse();
    }
}

- (void)handleRowTap:(__unused UITapGestureRecognizer *)tap {
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

- (UIContextMenuConfiguration *)contextMenuInteraction:(__unused UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(__unused CGPoint)location {
    if (_isSwipeParked || _isDeleting) return nil;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:^UIViewController * _Nullable{
        return [weakSelf.delegate queueRowPreviewControllerForRow:weakSelf];
    } actionProvider:^UIMenu * _Nullable(__unused NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
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
    NSMutableDictionary<NSString *, SGRQueueRowView *> *_historyRowsByKey;

    // Section 1: Now Playing Card (Clipped along y = 84.7pt so it never peeks above pinned 4-pill bar)
    UIView *_nowPlayingClipView;
    UIView *_nowPlayingCard;
    UIImageView *_npArtView;
    UIView *_npDetailsView;
    UILabel *_npTitleLabel;
    UIImageView *_npExplicitView;
    UILabel *_npArtistLabel;
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
    NSMutableDictionary<NSString *, SGRQueueRowView *> *_queueRowsByKey;

    // Displayed Items
    SGRQueueItem *_currentItem;
    NSMutableArray<SGRQueueItem *> *_historyItems;
    NSMutableArray<SGRQueueItem *> *_futureItems;
    NSString *_loadedNPArtURL;
    NSString *_lastStateFingerprint;
    BOOL _lastRenderedShuffling;
    BOOL _transitionArtHidden;

    // Pill States & Cached Pill Width
    BOOL _autoplayEnabled;
    BOOL _transitionsEnabled;
    CGSize _lastPillRenderSize;

    // Scroll Detent State (scrollY = 0 pt anchor)
    CGFloat _dragStartOffsetY;
    BOOL _historyUnlocked;
    BOOL _clampAtZeroOnDragOrDecel;
    BOOL _didSetInitialOffset;

    // Drag-to-Reorder State
    SGRQueueRowView *_draggingRow;
    UIView *_dragSnapshotView;
    NSInteger _dragCurrentIndex;
    CGFloat _dragGrabOffsetY;
}

+ (void)startSessionIfNeeded {
    [SGRQueueSession shared];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;

    [SGRQueueSession shared];

    _historyItems = [NSMutableArray array];
    _futureItems = [NSMutableArray array];
    _historyRowViews = [NSMutableArray array];
    _historyRowsByKey = [NSMutableDictionary dictionary];
    _queueRowViews = [NSMutableArray array];
    _queueRowsByKey = [NSMutableDictionary dictionary];

    _autoplayEnabled = [NSUserDefaults.standardUserDefaults boolForKey:SGRKeyQueueAutoplay];
    if ([NSUserDefaults.standardUserDefaults objectForKey:SGKeyAutoMix]) {
        _transitionsEnabled = SGEnabled(SGKeyAutoMix);
    } else {
        _transitionsEnabled = [NSUserDefaults.standardUserDefaults boolForKey:SGRKeyQueueTransitions];
    }

    [self buildViewHierarchy];
    SGAddPlayerStateObserver(self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleNowPlayingArtworkChanged:) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleSessionUpdated:) name:SGRQueueSessionDidUpdateNotification object:nil];
    [self syncFromSessionAnimatedReorder:NO forceRebuild:YES];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)handleNowPlayingArtworkChanged:(__unused NSNotification *)note {
    UIImage *art = SGRNowPlayingArtwork(NULL, NULL);
    if (art) _npArtView.image = art;
}

- (void)handleSessionUpdated:(__unused NSNotification *)note {
    BOOL sessionShuffle = [SGRQueueSession shared].isShuffling;
    BOOL animateShuffle = (self.window != nil && !self.hidden && self.alpha > 0.5 && sessionShuffle != _lastRenderedShuffling);
    [self syncFromSessionAnimatedReorder:animateShuffle forceRebuild:NO];
}

- (void)buildViewHierarchy {
    // 1. Top Sheet Grabber Pill (36x5 pt at y=0 -> screenY=55..60 pt)
    _grabberPill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kGrabberWidth, kGrabberHeight)];
    _grabberPill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
    _grabberPill.layer.cornerRadius = kGrabberHeight * 0.5;
    _grabberPill.userInteractionEnabled = NO;
    [self addSubview:_grabberPill];

    // 2. Scrollable Queue Viewport (starts at y=17 -> screenY=72..538 pt, height=466 pt)
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

    // 3. Section 0: History Rows Clipping Plane (clips at screenY = 110 pt) & Transparent Sticky Header (pins at screenY = 79.0 pt)
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

    // 4. Section 1: Now Playing Card inside top-clipped plane (never peeks above y = 84.7 pt 4-pill bar)
    _nowPlayingClipView = [[UIView alloc] initWithFrame:CGRectZero];
    _nowPlayingClipView.clipsToBounds = YES;
    _nowPlayingClipView.backgroundColor = UIColor.clearColor;
    [_scrollView addSubview:_nowPlayingClipView];

    _nowPlayingCard = [[UIView alloc] initWithFrame:CGRectZero];
    _nowPlayingCard.backgroundColor = UIColor.clearColor;
    [_nowPlayingClipView addSubview:_nowPlayingCard];

    _npArtView = [[UIImageView alloc] initWithFrame:CGRectMake(kSideMargin, 0.0, 62.0, 62.0)];
    _npArtView.contentMode = UIViewContentModeScaleAspectFill;
    _npArtView.clipsToBounds = YES;
    _npArtView.layer.cornerRadius = 8.0;
    _npArtView.layer.cornerCurve = kCACornerCurveContinuous;
    _npArtView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    _npArtView.userInteractionEnabled = YES;
    [_npArtView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleNowPlayingArtTap)]];
    [_nowPlayingCard addSubview:_npArtView];

    _npDetailsView = [[UIView alloc] initWithFrame:CGRectZero];
    _npDetailsView.backgroundColor = UIColor.clearColor;
    [_nowPlayingCard addSubview:_npDetailsView];

    _npTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _npTitleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    _npTitleLabel.textColor = UIColor.whiteColor;
    _npTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_npDetailsView addSubview:_npTitleLabel];

    _npExplicitView = [[UIImageView alloc] initWithImage:SGRExplicitBadgeImage()];
    _npExplicitView.contentMode = UIViewContentModeScaleAspectFit;
    _npExplicitView.hidden = YES;
    [_npDetailsView addSubview:_npExplicitView];

    _npArtistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _npArtistLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightRegular];
    _npArtistLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.58];
    _npArtistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_npDetailsView addSubview:_npArtistLabel];

    // Bare white ellipsis button matching Apple Music's Now Playing mini-card
    _npMoreButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _npMoreButton.backgroundColor = UIColor.clearColor;
    UIImageSymbolConfiguration *moreCfg = [UIImageSymbolConfiguration configurationWithPointSize:16.5 weight:UIImageSymbolWeightBold];
    [_npMoreButton setImage:[[UIImage systemImageNamed:@"ellipsis" withConfiguration:moreCfg] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
    UIContextMenuInteraction *npMenu = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    [_npMoreButton addInteraction:npMenu];
    [_npDetailsView addSubview:_npMoreButton];

    // 5. Section 2: Queue Track Rows Clipping Plane & Transparent Sticky Continue Playing Header (no Clear button, no #26222B box)
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
    _continueSubtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_continueHeaderView addSubview:_continueSubtitleLabel];

    [self updatePlaybackPillsWithState:SGPlayerState()];
}

- (UIButton *)createPlaybackPillWithAction:(SEL)action {
    UIButton *pill = [UIButton buttonWithType:UIButtonTypeCustom];
    pill.backgroundColor = UIColor.clearColor;
    pill.adjustsImageWhenHighlighted = NO;
    pill.layer.cornerRadius = 18.0;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.clipsToBounds = YES;
    [pill addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [pill addTarget:self action:@selector(handlePillTouchDown:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [pill addTarget:self action:@selector(handlePillTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    return pill;
}

- (void)handlePillTouchDown:(UIButton *)pill {
    [UIView animateWithDuration:0.10 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        pill.transform = CGAffineTransformMakeScale(0.94, 0.94);
    } completion:nil];
}

- (void)handlePillTouchUp:(UIButton *)pill {
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.68 initialSpringVelocity:0.4 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        pill.transform = CGAffineTransformIdentity;
    } completion:nil];
}

#pragma mark - Open / Close Transition Helpers

- (void)prepareForOpenTransition {
    _historyUnlocked = NO;
    _clampAtZeroOnDragOrDecel = NO;
    _didSetInitialOffset = YES;
    [self syncFromSessionAnimatedReorder:NO forceRebuild:YES];
    [self setNeedsLayout];
    [self layoutIfNeeded];
    _scrollView.contentInset = UIEdgeInsetsMake(0.0, 0.0, 36.0, 0.0);
    _scrollView.contentOffset = CGPointZero;
    [self updateStickyHeadersAndClipping];
}

- (void)setTransitionArtworkHidden:(BOOL)hidden {
    _transitionArtHidden = hidden;
    _npArtView.alpha = hidden ? 0.0 : 1.0;
}

- (void)setContentSlideOffset:(CGFloat)offsetY opacity:(CGFloat)opacity {
    CGAffineTransform slide = (fabs(offsetY) < 0.01) ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(0.0, offsetY);
    _grabberPill.alpha = opacity;
    _grabberPill.transform = slide;
    _npDetailsView.alpha = opacity;
    _npDetailsView.transform = slide;
    _continueHeaderView.alpha = opacity;
    _continueHeaderView.transform = slide;
    _queueRowsClipView.alpha = opacity;
    _queueRowsClipView.transform = slide;
    _historyHeaderView.alpha = opacity;
    _historyRowsClipView.alpha = opacity;
}

- (CGRect)nowPlayingArtworkFrameInView:(UIView *)targetView {
    CGRect localArt = CGRectMake(kSideMargin, kViewportTopOffset + kNowPlayingDocY, 62.0, 62.0);
    return targetView ? [self convertRect:localArt toView:targetView] : localArt;
}

#pragma mark - State Synchronization & Spring Row Reordering

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self updatePlaybackPillsWithState:state];
}

- (void)reloadTracks {
    _historyUnlocked = NO;
    _clampAtZeroOnDragOrDecel = NO;
    _didSetInitialOffset = YES;
    [self syncFromSessionAnimatedReorder:NO forceRebuild:YES];
    _scrollView.contentInset = UIEdgeInsetsMake(0.0, 0.0, 36.0, 0.0);
    _scrollView.contentOffset = CGPointZero;
    [self updateStickyHeadersAndClipping];
}

- (void)updateWithState:(SPTPlayerState *)state {
    [self updatePlaybackPillsWithState:state];
    [self syncFromSessionAnimatedReorder:NO forceRebuild:NO];
}

- (void)syncFromSessionAnimatedReorder:(BOOL)animateReorder forceRebuild:(BOOL)forceRebuild {
    SGRQueueSession *session = [SGRQueueSession shared];
    SPTPlayerState *state = SGPlayerState();
    if ([NSUserDefaults.standardUserDefaults objectForKey:SGKeyAutoMix]) {
        _transitionsEnabled = SGEnabled(SGKeyAutoMix);
    }
    [self updatePlaybackPillsWithState:state];

    if (!forceRebuild && _draggingRow) return;
    for (SGRQueueRowView *row in _queueRowViews) {
        if (!forceRebuild && row.isSwipeParked) return;
    }

    SGRQueueItem *np = session.nowPlayingItem;
    NSArray<SGRQueueItem *> *hist = session.historyItems;
    NSArray<SGRQueueItem *> *next = session.continuePlayingItems;

    NSMutableString *fp = [NSMutableString stringWithFormat:@"NP:%@|%@|H:%lu|N:%lu|S:%d|",
                           np.uri ?: @"", np.title ?: @"", (unsigned long)hist.count, (unsigned long)next.count, session.isShuffling ? 1 : 0];
    for (NSUInteger i = 0; i < MIN((NSUInteger)20, next.count); i++) {
        [fp appendFormat:@"%@:%@,", next[i].key, next[i].title ?: @""];
    }
    for (NSUInteger i = 0; i < MIN((NSUInteger)10, hist.count); i++) {
        [fp appendFormat:@"H%@:%@,", hist[i].key, hist[i].title ?: @""];
    }

    if (!forceRebuild && [_lastStateFingerprint isEqualToString:fp]) {
        [self updateNowPlayingCardWithItem:np subtitle:session.contextSubtitle];
        return;
    }
    _lastStateFingerprint = [fp copy];
    _lastRenderedShuffling = session.isShuffling;

    _currentItem = np;
    [_historyItems setArray:hist];
    [_futureItems setArray:next];

    [self updateNowPlayingCardWithItem:np subtitle:session.contextSubtitle];
    [self reconcileTrackRowsAnimated:animateReorder];
    [self setNeedsLayout];
    if (!animateReorder) {
        [self layoutIfNeeded];
    }
}

- (void)updateNowPlayingCardWithItem:(SGRQueueItem *)item subtitle:(NSString *)subtitle {
    _npTitleLabel.text = item.title.length ? item.title : @"Not Playing";
    _npArtistLabel.text = item.artist ?: @"";
    _npExplicitView.hidden = !item.isExplicit;
    _continueSubtitleLabel.text = subtitle ?: @"";

    UIImage *liveArt = SGRNowPlayingArtwork(NULL, NULL);
    if (liveArt) {
        _npArtView.image = liveArt;
    } else if (item.artworkURL) {
        NSString *u = item.artworkURL.absoluteString ?: @"";
        UIImage *cached = [SGRQueueImageCache() objectForKey:u];
        if (cached) {
            _npArtView.image = cached;
            _loadedNPArtURL = [u copy];
        } else if (![u isEqualToString:_loadedNPArtURL]) {
            _loadedNPArtURL = [u copy];
            __weak typeof(self) weakSelf = self;
            SGRLoadQueueArtwork(item.artworkURL, ^(UIImage *image) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf && image) strongSelf->_npArtView.image = image;
            });
        }
    }
    _npArtView.alpha = _transitionArtHidden ? 0.0 : 1.0;
}

- (void)reconcileTrackRowsAnimated:(BOOL)animateReorder {
    CGFloat w = MAX(320.0, self.bounds.size.width);

    // 1. Reconcile History Rows by key (reusing views & cached artwork)
    NSMutableDictionary<NSString *, SGRQueueRowView *> *nextHistMap = [NSMutableDictionary dictionaryWithCapacity:_historyItems.count];
    NSMutableArray<SGRQueueRowView *> *nextHistViews = [NSMutableArray arrayWithCapacity:_historyItems.count];

    for (NSUInteger i = 0; i < _historyItems.count; i++) {
        SGRQueueItem *it = _historyItems[i];
        SGRQueueRowView *row = _historyRowsByKey[it.key];
        if (row) {
            [_historyRowsByKey removeObjectForKey:it.key];
        } else {
            row = [[SGRQueueRowView alloc] initWithFrame:CGRectMake(0, i * kHistoryRowPitch, w, kHistoryRowPitch)];
            row.delegate = self;
            [_historyRowsContainerView addSubview:row];
        }
        [row configureWithItem:it isHistory:YES rowIndex:(NSInteger)i];
        row.frame = CGRectMake(0.0, i * kHistoryRowPitch, w, kHistoryRowPitch);
        nextHistMap[it.key] = row;
        [nextHistViews addObject:row];
    }
    for (SGRQueueRowView *obsolete in _historyRowsByKey.allValues) {
        [obsolete removeFromSuperview];
    }
    _historyRowsByKey = nextHistMap;
    [_historyRowViews setArray:nextHistViews];

    // 2. Reconcile Continue Playing Rows by key (smooth ~0.35s spring reorder on Shuffle toggle, zero artwork flash)
    NSMutableDictionary<NSString *, SGRQueueRowView *> *nextQueueMap = [NSMutableDictionary dictionaryWithCapacity:_futureItems.count];
    NSMutableArray<SGRQueueRowView *> *nextQueueViews = [NSMutableArray arrayWithCapacity:_futureItems.count];
    NSMutableArray<SGRQueueRowView *> *newlyInserted = [NSMutableArray array];

    for (NSUInteger i = 0; i < _futureItems.count; i++) {
        SGRQueueItem *it = _futureItems[i];
        SGRQueueRowView *row = _queueRowsByKey[it.key];
        CGRect targetFrame = CGRectMake(0.0, i * kQueueRowPitch, w, kQueueRowPitch);
        if (row) {
            [_queueRowsByKey removeObjectForKey:it.key];
            [row configureWithItem:it isHistory:NO rowIndex:(NSInteger)i];
            if (!animateReorder) {
                row.frame = targetFrame;
                row.alpha = 1.0;
            }
        } else {
            row = [[SGRQueueRowView alloc] initWithFrame:targetFrame];
            row.delegate = self;
            [row configureWithItem:it isHistory:NO rowIndex:(NSInteger)i];
            if (animateReorder) {
                row.alpha = 0.0;
                [newlyInserted addObject:row];
            }
            [_queueRowsContainerView addSubview:row];
        }
        nextQueueMap[it.key] = row;
        [nextQueueViews addObject:row];
    }

    NSArray<SGRQueueRowView *> *removedRows = _queueRowsByKey.allValues;
    _queueRowsByKey = nextQueueMap;
    [_queueRowViews setArray:nextQueueViews];

    if (animateReorder && !SGRReduceMotion()) {
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
            for (NSUInteger i = 0; i < self->_queueRowViews.count; i++) {
                SGRQueueRowView *r = self->_queueRowViews[i];
                r.frame = CGRectMake(0.0, i * kQueueRowPitch, w, kQueueRowPitch);
                r.alpha = 1.0;
            }
            for (SGRQueueRowView *oldRow in removedRows) {
                oldRow.alpha = 0.0;
            }
            [self updateStickyHeadersAndClipping];
        } completion:^(__unused BOOL finished) {
            for (SGRQueueRowView *oldRow in removedRows) {
                [oldRow removeFromSuperview];
            }
        }];
    } else {
        for (SGRQueueRowView *oldRow in removedRows) {
            [oldRow removeFromSuperview];
        }
        for (SGRQueueRowView *ins in newlyInserted) {
            ins.alpha = 1.0;
        }
    }
}

#pragma mark - Layout, Dual Sticky Headers & Sharp Clipping Planes

- (CGFloat)historyTotalHeight {
    if (_historyItems.count == 0) return 0.0;
    return kHistoryHeaderHeight + _historyItems.count * kHistoryRowPitch + kHistoryBottomGap;
}

- (void)applyLockedOrUnlockedHistoryInset {
    CGFloat histH = _historyUnlocked ? [self historyTotalHeight] : 0.0;
    UIEdgeInsets targetInset = UIEdgeInsetsMake(histH, 0.0, 36.0, 0.0);
    if (!UIEdgeInsetsEqualToEdgeInsets(_scrollView.contentInset, targetInset)) {
        CGPoint savedOffset = _scrollView.contentOffset;
        _scrollView.contentInset = targetInset;
        _scrollView.contentOffset = savedOffset;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 100.0 || h < 100.0) return;

    _grabberPill.bounds = CGRectMake(0.0, 0.0, kGrabberWidth, kGrabberHeight);
    _grabberPill.center = CGPointMake(w * 0.5, kGrabberHeight * 0.5);

    CGFloat viewportH = MAX(100.0, h - kViewportTopOffset);
    _viewportClipView.frame = CGRectMake(0.0, kViewportTopOffset, w, viewportH);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _bottomFadeMask.frame = _viewportClipView.bounds;
    CGFloat fadeStart = MAX(0.78, (viewportH - 34.0) / viewportH);
    CGFloat fadeMid = MAX(0.88, (viewportH - 14.0) / viewportH);
    _bottomFadeMask.locations = @[@0.0, @(fadeStart), @(fadeMid), @1.0];
    [CATransaction commit];

    _scrollView.frame = _viewportClipView.bounds;

    if (!_didSetInitialOffset) {
        _didSetInitialOffset = YES;
        _historyUnlocked = NO;
        _scrollView.contentInset = UIEdgeInsetsMake(0.0, 0.0, 36.0, 0.0);
        _scrollView.contentOffset = CGPointZero;
    } else {
        [self applyLockedOrUnlockedHistoryInset];
    }

    // Section 1: Now Playing Card subviews (62x62 art at x=28, docY=14.7 -> screen (28.0, 86.7))
    _npArtView.frame = CGRectMake(kSideMargin, 0.0, 62.0, 62.0);
    _npDetailsView.bounds = CGRectMake(0.0, 0.0, w, kNowPlayingHeight);
    _npDetailsView.center = CGPointMake(w * 0.5, kNowPlayingHeight * 0.5);
    _npMoreButton.frame = CGRectMake(w - 57.0, 13.0, 36.0, 36.0);

    CGFloat npTextLeft = kSideMargin + 62.0 + 14.0; // 104.0 pt
    CGFloat npMaxRight = w - 62.0;
    CGFloat npAvailW = MAX(40.0, npMaxRight - npTextLeft);
    BOOL npHasExp = !_npExplicitView.hidden;
    CGFloat npBadgeW = npHasExp ? (13.5 + 5.0) : 0.0;
    CGSize npTitleNat = [_npTitleLabel sizeThatFits:CGSizeMake(npAvailW - npBadgeW, 24.0)];
    CGFloat npTitleW = MIN(npAvailW - npBadgeW, ceil(npTitleNat.width));
    _npTitleLabel.frame = CGRectMake(npTextLeft, 10.0, npTitleW, 21.0);
    if (npHasExp) {
        _npExplicitView.frame = CGRectMake(npTextLeft + npTitleW + 5.0, 14.0, 13.5, 13.5);
    }
    _npArtistLabel.frame = CGRectMake(npTextLeft, 32.5, npAvailW, 19.0);

    // Section 2 Header subviews: 4 pills (height = 36, cornerRadius = 18, x = 28 .. w - 28) + Continue Playing title & subtitle
    CGFloat pillGap = 9.0;
    CGFloat pillW = floor(((w - kSideMargin * 2.0 - pillGap * 3.0) / 4.0) * 2.0) * 0.5;
    NSArray<UIButton *> *pills = @[_shufflePill, _repeatPill, _autoplayPill, _transitionsPill];
    for (NSUInteger i = 0; i < pills.count; i++) {
        UIButton *p = pills[i];
        p.bounds = CGRectMake(0.0, 0.0, pillW, 36.0);
        p.center = CGPointMake(kSideMargin + i * (pillW + pillGap) + pillW * 0.5, 18.0);
    }
    CGSize pillSize = CGSizeMake(pillW, 36.0);
    if (!CGSizeEqualToSize(pillSize, _lastPillRenderSize)) {
        _lastPillRenderSize = pillSize;
        [self updatePlaybackPillsWithState:SGPlayerState()];
    }

    _continueTitleLabel.frame = CGRectMake(kSideMargin, 47.0, w - kSideMargin * 2.0, 22.0);
    _continueSubtitleLabel.frame = CGRectMake(kSideMargin, 69.0, w - kSideMargin * 2.0, 18.0);

    // Section 0 Header subviews: "History" + "Clear" aligned at x = 28 .. w - 28
    _historyTitleLabel.frame = CGRectMake(kSideMargin, 6.0, 160.0, 24.0);
    _historyClearButton.frame = CGRectMake(w - kSideMargin - 52.0, 2.0, 52.0, 32.0);
    _historyClearButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;

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
    CGFloat minScrollContentH = MAX(viewportH + 92.0, totalQueueBottom);
    _scrollView.contentSize = CGSizeMake(w, minScrollContentH);

    [self updateStickyHeadersAndClipping];
}

- (void)updateStickyHeadersAndClipping {
    CGFloat w = self.bounds.size.width;
    CGFloat scrollY = _scrollView.contentOffset.y;
    CGFloat histH = [self historyTotalHeight];

    // 1. Section 2: Continue Playing Sticky Header (pins flush at screenY = 84.7 pt) & Sharp Row Clip at screenY = 174.7 pt
    CGFloat queueHeaderDocY = MAX(kContinueHeaderDocY, scrollY + kContinueHeaderPinOffset);
    _continueHeaderView.bounds = CGRectMake(0.0, 0.0, w, kContinueHeaderHeight);
    _continueHeaderView.center = CGPointMake(w * 0.5, queueHeaderDocY + kContinueHeaderHeight * 0.5);

    CGFloat queueClipTopDocY = queueHeaderDocY + kContinueHeaderHeight;
    CGFloat queueBottomDocY = kQueueRowsStartDocY + _queueRowViews.count * kQueueRowPitch + 120.0;
    CGFloat queueClipH = MAX(0.0, queueBottomDocY - queueClipTopDocY);
    _queueRowsClipView.bounds = CGRectMake(0.0, 0.0, w, queueClipH);
    _queueRowsClipView.center = CGPointMake(w * 0.5, queueClipTopDocY + queueClipH * 0.5);
    _queueRowsContainerView.frame = CGRectMake(0.0, kQueueRowsStartDocY - queueClipTopDocY, w, _queueRowViews.count * kQueueRowPitch);

    // 2. Section 1: Now Playing Card clipped strictly between top clip plane (screenY = 84.7 pt) and rising Continue Header
    // so "Now Playing" NEVER peeks above the pinned 4-pill bar!
    CGFloat npClipTopDocY = MAX(kNowPlayingDocY, scrollY + kContinueHeaderPinOffset);
    CGFloat npClipBottomDocY = MIN(kNowPlayingDocY + kNowPlayingHeight, queueHeaderDocY);
    CGFloat npClipH = MAX(0.0, npClipBottomDocY - npClipTopDocY);
    _nowPlayingClipView.frame = CGRectMake(0.0, npClipTopDocY, w, npClipH);
    _nowPlayingClipView.hidden = (npClipH <= 0.5);
    _nowPlayingCard.frame = CGRectMake(0.0, kNowPlayingDocY - npClipTopDocY, w, kNowPlayingHeight);

    // 3. Section 0: History Sticky Header (pins at screenY = 79.0 pt, pushes off from -50.7..0 pt) & Sharp Row Clip at screenY = 110.0 pt
    if (histH > 0.0 && scrollY < -0.5) {
        _historyHeaderView.hidden = NO;
        _historyRowsClipView.hidden = NO;

        CGFloat histHeaderDocY = MIN(MAX(-histH + kHistoryHeaderPinOffset, scrollY + kHistoryHeaderPinOffset), kHistoryHeaderPushOffDocY);
        _historyHeaderView.frame = CGRectMake(0.0, histHeaderDocY, w, kHistoryHeaderHeight);

        // Clip scrolling History rows sharply along y = 110 pt (histHeaderDocY + 31.0) so rows never bleed behind "History / Clear"
        CGFloat histClipTopDocY = histHeaderDocY + kHistoryHeaderClipOffset;
        CGFloat histClipBottomDocY = MIN(kNowPlayingDocY - 4.0, queueHeaderDocY);
        CGFloat clipH = MAX(0.0, histClipBottomDocY - histClipTopDocY);
        _historyRowsClipView.frame = CGRectMake(0.0, histClipTopDocY, w, clipH);

        CGFloat histFirstRowDocY = -histH + kHistoryHeaderHeight + 4.0;
        _historyRowsContainerView.frame = CGRectMake(0.0, histFirstRowDocY - histClipTopDocY, w, _historyRowViews.count * kHistoryRowPitch);
    } else {
        _historyHeaderView.hidden = YES;
        _historyRowsClipView.hidden = YES;
    }
}

#pragma mark - Scroll-Stop Detent at scrollY = 0 pt

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    for (SGRQueueRowView *row in _queueRowViews) {
        if (row.isSwipeParked) [row closeSwipeAnimated:YES];
    }
    _dragStartOffsetY = scrollView.contentOffset.y;
    if (_dragStartOffsetY > 2.0) {
        // User started dragging inside "Continue Playing": lock minContentOffset.y = 0 so downward pan/fling
        // stops cleanly at scrollY = 0 with zero overshoot into History.
        _clampAtZeroOnDragOrDecel = YES;
        if (_historyUnlocked) {
            _historyUnlocked = NO;
            [self applyLockedOrUnlockedHistoryInset];
        }
    } else {
        _clampAtZeroOnDragOrDecel = NO;
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat y = scrollView.contentOffset.y;
    CGFloat histH = [self historyTotalHeight];

    // Hard stop at scrollY = 0 whenever returning upward from "Continue Playing" (both finger drag & deceleration)
    if (_clampAtZeroOnDragOrDecel && y < 0.0) {
        scrollView.contentOffset = CGPointZero;
        if (!scrollView.isTracking) {
            _clampAtZeroOnDragOrDecel = NO;
        }
        [self updateStickyHeadersAndClipping];
        return;
    }

    // Unlock History ONLY when user pulls downward starting from rest at scrollY <= 2.0 pt
    if (scrollView.isTracking && _dragStartOffsetY <= 2.0 && y < -0.5 && histH > 0.0 && !_historyUnlocked) {
        CGPoint panVel = [scrollView.panGestureRecognizer velocityInView:scrollView];
        if (panVel.y > 0.0) { // Finger moving downward on screen -> negative scrollView velocityY
            _historyUnlocked = YES;
            [self applyLockedOrUnlockedHistoryInset];
        }
    }

    // Re-lock History once scrolled into "Continue Playing" (> 2 pt)
    if (!scrollView.isTracking && y > 2.0 && _historyUnlocked) {
        _historyUnlocked = NO;
        [self applyLockedOrUnlockedHistoryInset];
    }

    [self updateStickyHeadersAndClipping];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    _clampAtZeroOnDragOrDecel = NO;
    if (scrollView.contentOffset.y >= -0.5 && _historyUnlocked) {
        _historyUnlocked = NO;
        [self applyLockedOrUnlockedHistoryInset];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        _clampAtZeroOnDragOrDecel = NO;
        if (scrollView.contentOffset.y >= -0.5 && _historyUnlocked) {
            _historyUnlocked = NO;
            [self applyLockedOrUnlockedHistoryInset];
        }
    }
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset {
    CGFloat histH = [self historyTotalHeight];
    if (histH <= 0.0 || !_historyUnlocked) {
        if (targetContentOffset->y < 0.0) {
            targetContentOffset->y = 0.0;
            _clampAtZeroOnDragOrDecel = YES;
        }
        return;
    }

    CGFloat currentY = scrollView.contentOffset.y;

    // Case 1: Dragging started inside "Continue Playing" (_dragStartOffsetY > 2.0) -> clamp at 0
    if (_dragStartOffsetY > 2.0) {
        if (targetContentOffset->y < 0.0) {
            targetContentOffset->y = 0.0;
            _clampAtZeroOnDragOrDecel = YES;
        }
        return;
    }

    // Case 2: Dragging started at rest near 0 (_dragStartOffsetY >= -2.0) and pulled downward into History
    if (_dragStartOffsetY >= -2.0 && currentY < -8.0 && velocity.y <= 0.15) {
        targetContentOffset->y = -histH;
        _clampAtZeroOnDragOrDecel = NO;
        return;
    }

    // Case 3: Swiping inside History (_dragStartOffsetY < -2.0)
    if (_dragStartOffsetY < -2.0) {
        if (targetContentOffset->y > 120.0) {
            // Strong upward fling (projectedTargetY > +120 pt) continues smoothly into "Continue Playing"
            _clampAtZeroOnDragOrDecel = NO;
        } else if (velocity.y > 0.12 || currentY > -histH * 0.65 || targetContentOffset->y > -histH * 0.5) {
            // Moderate upward swipe (projectedTargetY <= +120 pt) docks cleanly on "Now Playing" at scrollY = 0 pt
            targetContentOffset->y = 0.0;
            _clampAtZeroOnDragOrDecel = YES;
        } else {
            targetContentOffset->y = -histH;
            _clampAtZeroOnDragOrDecel = NO;
        }
    }
}

#pragma mark - 4-Pill Playback Mode Bar & Actions

- (void)stylePill:(UIButton *)pill active:(BOOL)active symbol:(NSString *)symbol isTransitions:(BOOL)isTransitions {
    CGSize sz = pill.bounds.size;
    if (sz.width < 10.0 || sz.height < 10.0) {
        CGFloat w = MAX(320.0, self.bounds.size.width);
        sz = CGSizeMake(floor(((w - kSideMargin * 2.0 - 27.0) / 4.0) * 2.0) * 0.5, 36.0);
    }
    UIImage *bgImg = SGRRenderPillCapsuleImage(sz, active, symbol, isTransitions);
    [pill setBackgroundImage:bgImg forState:UIControlStateNormal];
    [pill setImage:nil forState:UIControlStateNormal];
}

- (void)updatePlaybackPillsWithState:(SPTPlayerState *)state {
    BOOL shuffling = [SGRQueueSession shared].isShuffling;
    BOOL repeatTrack = NO;
    BOOL repeatContext = NO;
    if (state && [state respondsToSelector:@selector(options)]) {
        SPTPlayerOptions *opts = state.options;
        if (opts) {
            repeatTrack = opts.repeatingTrack;
            repeatContext = opts.repeatingContext;
        }
    }
    [self stylePill:_shufflePill active:shuffling symbol:@"shuffle" isTransitions:NO];
    [self stylePill:_repeatPill active:(repeatTrack || repeatContext) symbol:(repeatTrack ? @"repeat.1" : @"repeat") isTransitions:NO];
    [self stylePill:_autoplayPill active:_autoplayEnabled symbol:@"infinity" isTransitions:NO];
    [self stylePill:_transitionsPill active:_transitionsEnabled symbol:nil isTransitions:YES];
}

- (void)handleShufflePillTap {
    BOOL next = !([SGRQueueSession shared].isShuffling);
    [[SGRQueueSession shared] setOptimisticShuffle:next];
    id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
    @try {
        if ([player respondsToSelector:@selector(setShufflingContext:)]) {
            [player setShufflingContext:next];
        }
    } @catch (__unused NSException *e) {}
    [self updatePlaybackPillsWithState:SGPlayerState()];
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updatePlaybackPillsWithState:SGPlayerState()];
    });
}

- (void)handleAutoplayPillTap {
    _autoplayEnabled = !_autoplayEnabled;
    [NSUserDefaults.standardUserDefaults setBool:_autoplayEnabled forKey:SGRKeyQueueAutoplay];
    [self updatePlaybackPillsWithState:SGPlayerState()];
}

- (void)handleTransitionsPillTap {
    _transitionsEnabled = !_transitionsEnabled;
    [NSUserDefaults.standardUserDefaults setBool:_transitionsEnabled forKey:SGRKeyQueueTransitions];
    if (SGAutoMixAccountAllows()) {
        [NSUserDefaults.standardUserDefaults setBool:_transitionsEnabled forKey:SGKeyAutoMix];
        SGAutoMixApply(_transitionsEnabled);
    }
    [self updatePlaybackPillsWithState:SGPlayerState()];
}

- (void)handleNowPlayingArtTap {
    SGRPlayerToggleQueue();
}

- (void)handleClearHistoryTap {
    if (_historyItems.count == 0) return;
    _historyUnlocked = NO;
    [[SGRQueueSession shared] clearHistory];
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
    SGRQueueItem *item = row.item;
    if (!item.uri.length) return;
    id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
    SPTPlayerState *state = SGPlayerState();

    if (!row.isHistory) {
        // Prefer exact live SPTPlayerTrack instance from state.future when within Spotify's lookahead window
        SPTPlayerTrack *targetTrack = nil;
        NSArray *future = ([state respondsToSelector:@selector(future)] && [state.future isKindOfClass:NSArray.class]) ? state.future : @[];
        for (id cand in future) {
            if ([cand respondsToSelector:@selector(URI)] && [SGURIString(((SPTPlayerTrack *)cand).URI) isEqualToString:item.uri]) {
                targetTrack = (SPTPlayerTrack *)cand;
                break;
            }
        }
        if (!targetTrack) targetTrack = [item resolvedPlayerTrack];

        @try {
            if (targetTrack && [player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) {
                [player skipToNextTrackWithOptions:nil track:targetTrack];
                return;
            }
            if (row.rowIndex == 0 && [player respondsToSelector:@selector(skipToNextTrack)]) {
                [player skipToNextTrack];
                return;
            }
        } @catch (__unused NSException *e) {}
    } else {
        SPTPlayerTrack *targetTrack = nil;
        NSArray *reverse = ([state respondsToSelector:@selector(reverse)] && [state.reverse isKindOfClass:NSArray.class]) ? state.reverse : @[];
        for (id cand in reverse) {
            if ([cand respondsToSelector:@selector(URI)] && [SGURIString(((SPTPlayerTrack *)cand).URI) isEqualToString:item.uri]) {
                targetTrack = (SPTPlayerTrack *)cand;
                break;
            }
        }
        if (!targetTrack) targetTrack = [item resolvedPlayerTrack];

        @try {
            if (targetTrack && [player respondsToSelector:@selector(skipToPreviousTrackWithOptions:track:)]) {
                [player skipToPreviousTrackWithOptions:nil track:targetTrack];
                return;
            }
        } @catch (__unused NSException *e) {}
    }
    SGOpenSpotifyURI([NSURL URLWithString:item.uri]);
}

- (void)queueRowDidCommitDelete:(SGRQueueRowView *)row {
    NSUInteger idx = [_queueRowViews indexOfObject:row];
    if (idx == NSNotFound || idx >= _futureItems.count) return;

    SGRQueueItem *removedItem = _futureItems[idx];
    [[SGRQueueSession shared] deleteContinuePlayingItemWithKey:removedItem.key];
    [_queueRowsByKey removeObjectForKey:removedItem.key];
    [_futureItems removeObjectAtIndex:idx];
    [_queueRowViews removeObjectAtIndex:idx];

    for (NSUInteger i = 0; i < _queueRowViews.count; i++) {
        _queueRowViews[i].rowIndex = (NSInteger)i;
    }

    CGFloat w = self.bounds.size.width;
    CGRect startFrame = row.frame;
    [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        row.frame = CGRectMake(startFrame.origin.x, startFrame.origin.y, w, 0.5);
        row.alpha = 0.25;
    } completion:^(__unused BOOL finished) {
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
            NSUInteger foundIdx = [_queueRowViews indexOfObject:row];
            if (foundIdx == NSNotFound) {
                _draggingRow = nil;
                return;
            }
            _dragCurrentIndex = (NSInteger)foundIdx;
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
                [[SGRQueueSession shared] moveContinuePlayingItemFromIndex:(NSUInteger)_dragCurrentIndex toIndex:(NSUInteger)hoverIndex];
                SGRQueueItem *movedItem = _futureItems[(NSUInteger)_dragCurrentIndex];
                [_futureItems removeObjectAtIndex:(NSUInteger)_dragCurrentIndex];
                [_futureItems insertObject:movedItem atIndex:(NSUInteger)hoverIndex];

                [_queueRowViews removeObjectAtIndex:(NSUInteger)_dragCurrentIndex];
                [_queueRowViews insertObject:_draggingRow atIndex:(NSUInteger)hoverIndex];

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
            } completion:^(__unused BOOL finished) {
                finishedRow.alpha = 1.0;
                [snap removeFromSuperview];
            }];
            break;
        }
        default:
            break;
    }
}

#pragma mark - Long-Press Context Menu & Preview Card

- (UIViewController *)previewControllerForItem:(SGRQueueItem *)item artImage:(UIImage *)artImage {
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
    if (!artImage && item.artworkURL) {
        SGRLoadQueueArtwork(item.artworkURL, ^(UIImage *loaded) {
            if (loaded) art.image = loaded;
        });
    }
    [vc.view addSubview:art];

    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(82.0, 16.0, 140.0, 19.0)];
    l1.text = item.title.length ? item.title : @"Track";
    l1.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    l1.textColor = UIColor.whiteColor;
    [vc.view addSubview:l1];

    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(82.0, 35.0, 140.0, 17.0)];
    l2.text = item.artist ?: @"";
    l2.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    l2.textColor = [UIColor colorWithWhite:1.0 alpha:0.90];
    [vc.view addSubview:l2];

    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(82.0, 52.0, 140.0, 16.0)];
    l3.text = item.albumTitle ?: @"";
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

- (UIMenu *)buildAppleMusicMenuForItem:(SGRQueueItem *)item row:(SGRQueueRowView *)row {
    if (!item) return nil;
    NSString *albumTitle = item.albumTitle ?: @"";
    NSString *albumURI = item.albumURI ?: @"";
    NSString *trackURI = item.uri ?: @"";
    BOOL isStarred = [[SGRQueueSession shared] isTrackStarred:trackURI];

    __weak typeof(self) weakSelf = self;

    UIAction *downloadAct = [UIAction actionWithTitle:@"Download" image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:nil handler:^(__unused __kindof UIAction *action) {}];
    UIAction *favoriteAct = [UIAction actionWithTitle:@"Favorite" image:[UIImage systemImageNamed:isStarred ? @"star.fill" : @"star"] identifier:nil handler:^(__unused __kindof UIAction *action) {
        [[SGRQueueSession shared] toggleTrackStarred:trackURI];
    }];
    UIAction *shareAct = [UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__unused __kindof UIAction *action) {
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

    NSMutableArray<UIMenuElement *> *mainActions = [NSMutableArray array];

    UIAction *addPlaylistAct = [UIAction actionWithTitle:@"Add to a Playlist…" image:[UIImage systemImageNamed:@"text.badge.plus"] identifier:nil handler:^(__unused __kindof UIAction *action) {
        if (trackURI.length) SGOpenSpotifyURI([NSURL URLWithString:trackURI]);
    }];
    [mainActions addObject:addPlaylistAct];

    if (row && !row.isHistory) {
        UIAction *moveTopAct = [UIAction actionWithTitle:@"Move to the Top" image:[UIImage systemImageNamed:@"text.line.first.and.arrowtriangle.forward"] identifier:nil handler:^(__unused __kindof UIAction *action) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSUInteger idx = [strongSelf->_queueRowViews indexOfObject:row];
            if (idx != NSNotFound && idx > 0 && idx < strongSelf->_futureItems.count) {
                [[SGRQueueSession shared] moveContinuePlayingItemFromIndex:idx toIndex:0];
                SGRQueueItem *t = strongSelf->_futureItems[idx];
                [strongSelf->_futureItems removeObjectAtIndex:idx];
                [strongSelf->_futureItems insertObject:t atIndex:0];
                [strongSelf->_queueRowViews removeObjectAtIndex:idx];
                [strongSelf->_queueRowViews insertObject:row atIndex:0];
                [UIView animateWithDuration:0.30 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
                    for (NSUInteger i = 0; i < strongSelf->_queueRowViews.count; i++) {
                        strongSelf->_queueRowViews[i].rowIndex = (NSInteger)i;
                        strongSelf->_queueRowViews[i].frame = CGRectMake(0.0, i * kQueueRowPitch, strongSelf.bounds.size.width, kQueueRowPitch);
                    }
                } completion:nil];
            }
        }];
        [mainActions addObject:moveTopAct];
    }

    UIAction *goAlbumAct = [UIAction actionWithTitle:@"Go to Album" image:[UIImage systemImageNamed:@"square.stack"] identifier:nil handler:^(__unused __kindof UIAction *action) {
        if (albumURI.length) SGOpenSpotifyURI([NSURL URLWithString:albumURI]);
    }];
    if (@available(iOS 15.0, *)) {
        if (albumTitle.length) goAlbumAct.subtitle = albumTitle;
    }
    [mainActions addObject:goAlbumAct];

    UIAction *suggestLessAct = [UIAction actionWithTitle:@"Suggest Less" image:[UIImage systemImageNamed:@"hand.thumbsdown"] identifier:nil handler:^(__unused __kindof UIAction *action) {}];
    [mainActions addObject:suggestLessAct];

    UIMenu *middleMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:mainActions];

    if (row && !row.isHistory) {
        UIAction *deleteAct = [UIAction actionWithTitle:@"Remove from Queue" image:[UIImage systemImageNamed:@"minus.circle"] identifier:nil handler:^(__unused __kindof UIAction *action) {
            [weakSelf queueRowDidCommitDelete:row];
        }];
        deleteAct.attributes = UIMenuElementAttributesDestructive;
        UIMenu *destructiveMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[deleteAct]];
        return [UIMenu menuWithTitle:@"" children:@[topRowMenu, middleMenu, destructiveMenu]];
    }

    return [UIMenu menuWithTitle:@"" children:@[topRowMenu, middleMenu]];
}

- (UIViewController *)queueRowPreviewControllerForRow:(SGRQueueRowView *)row {
    return [self previewControllerForItem:row.item artImage:row.artView.image];
}

- (UIMenu *)queueRowContextMenuForRow:(SGRQueueRowView *)row {
    return [self buildAppleMusicMenuForItem:row.item row:row];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(__unused UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(__unused CGPoint)location {
    if (!_currentItem) return nil;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:^UIViewController * _Nullable{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        return [strongSelf previewControllerForItem:strongSelf->_currentItem artImage:strongSelf->_npArtView.image];
    } actionProvider:^UIMenu * _Nullable(__unused NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        return [strongSelf buildAppleMusicMenuForItem:strongSelf->_currentItem row:nil];
    }];
}

@end

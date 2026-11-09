#import "SGRQueueView.h"
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AdBlock/Protobuf.h"
#import "Shared/ArtistBlock/ArtistBlock.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Shared/Fonts/Fonts.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/Navigation/Links.h"
#import "Shared/Player/SleepTimer.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/SpotifyPrefs/SpotifyPrefs.h"
#import "Player.h"

@interface SPTPlayerTrack (SGRQueueConstruct)
- (instancetype)initWithURI:(NSURL *)uri albumURI:(NSURL *)album artistURI:(NSURL *)artist andUID:(NSString *)uid;
@end

@interface SGRQueueSPTask : NSObject
- (id)addCallback:(void (^)(id))callback on:(dispatch_queue_t)queue;
- (id)addErrorCallback:(void (^)(NSError *))callback on:(dispatch_queue_t)queue;
@end

@interface SGRQueueWrapper : NSObject
- (instancetype)initWithPlayer:(id)player;
- (SGRQueueSPTask *)queueTrack:(SPTPlayerTrack *)track;
- (SGRQueueSPTask *)queueTrackPlayNext:(SPTPlayerTrack *)track;
- (SGRQueueSPTask *)queueMultipleTracks:(NSArray *)tracks loggingParams:(id)params;
@end

@protocol SGRSpotifyQueueObject <NSObject>
- (NSArray<SPTPlayerTrack *> *)nextTracks;
- (void)setNextTracks:(NSArray<SPTPlayerTrack *> *)tracks;
- (NSArray<SPTPlayerTrack *> *)prevTracks;
- (id)revision;
@end

#define SGRKeyQueueAutoplay @"spotifyglass.redesign.queue.autoplay"
#define SGRKeyQueueTransitions @"spotifyglass.redesign.queue.transitions"

static NSNotificationName const SGRQueueSessionDidUpdateNotification = @"SGRQueueSessionDidUpdateNotification";
static NSNotificationName const SGRQueuePillsDidChangeNotification = @"SGRQueuePillsDidChangeNotification";

// A font that follows the app font setting (Shared/Fonts). When the default Spotify font is chosen the
// UIFont hooks are inactive, so systemFontOfSize: would return SF Pro while Spotify's own views show
// Spotify Mix; ask for the family by name with the weight as a trait, the way Spotify's own views do
// (Spotify Mix is a variable font, so the weight axis renders any weight from one face). For any other
// setting the Designs hooks intercept systemFontOfSize:weight: and apply the chosen design, so that
// path is taken directly.
static UIFont *SGRQueueFont(CGFloat size, UIFontWeight weight) {
    if (SGAppFontChosen() == SGAppFontSpotify) {
        UIFontDescriptor *descriptor = [UIFontDescriptor fontDescriptorWithFontAttributes:@{
            UIFontDescriptorFamilyAttribute: @"Spotify Mix UI",
            UIFontDescriptorTraitsAttribute: @{UIFontWeightTrait: @(weight)},
        }];
        return [UIFont fontWithDescriptor:descriptor size:size];
    }
    return [UIFont systemFontOfSize:size weight:weight];
}

NSArray<NSString *> *SGRQueuePillNames(void) {
    return @[
        @"Shuffle",
        @"Repeat",
        @"Autoplay",
        @"AutoMix",
        @"Sleep Timer",
        @"Speed & Pitch",
        @"Lyrics Source",
        @"None",
    ];
}

static NSString *SGRQueuePillKeyForSlot(NSUInteger slot) {
    switch (slot) {
        case 0: return SGRKeyQueuePill1;
        case 1: return SGRKeyQueuePill2;
        case 2: return SGRKeyQueuePill3;
        default: return SGRKeyQueuePill4;
    }
}

static SGRQueuePillKind SGRDefaultQueuePillKindForSlot(NSUInteger slot) {
    switch (slot) {
        case 0: return SGRQueuePillShuffle;
        case 1: return SGRQueuePillRepeat;
        case 2: return SGRQueuePillAutoplay;
        default: return SGRQueuePillTransitions;
    }
}

SGRQueuePillKind SGRQueuePillKindForSlot(NSUInteger slot) {
    NSInteger raw = SGInt(SGRQueuePillKeyForSlot(slot), (NSInteger)SGRDefaultQueuePillKindForSlot(slot));
    if (raw < 0 || raw > (NSInteger)SGRQueuePillNone) return SGRDefaultQueuePillKindForSlot(slot);
    return (SGRQueuePillKind)raw;
}

void SGRSetQueuePillKindForSlot(NSUInteger slot, SGRQueuePillKind kind) {
    if (kind < 0 || kind > SGRQueuePillNone) kind = SGRQueuePillNone;
    SGSetInt(SGRQueuePillKeyForSlot(slot), (NSInteger)kind);
    [NSNotificationCenter.defaultCenter postNotificationName:SGRQueuePillsDidChangeNotification object:nil];
}

static BOOL SGRIsAutoplayTrack(SPTPlayerTrack *track) {
    if (!track) return NO;
    NSString *prov = ([track respondsToSelector:@selector(provider)] && [track.provider isKindOfClass:NSString.class]) ? track.provider : nil;
    if ([prov isEqualToString:@"autoplay"]) return YES;
    NSDictionary *meta = ([track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class]) ? track.metadata : nil;
    NSString *flag = [meta[@"autoplay.is_autoplay"] isKindOfClass:NSString.class] ? meta[@"autoplay.is_autoplay"] : nil;
    return [flag isEqualToString:@"true"] || [flag isEqualToString:@"1"];
}

static BOOL SGRIsUserQueuedTrack(SPTPlayerTrack *track) {
    if (!track) return NO;
    NSString *prov = ([track respondsToSelector:@selector(provider)] && [track.provider isKindOfClass:NSString.class]) ? track.provider : @"";
    if ([prov isEqualToString:@"queue"]) return YES;
    NSDictionary *meta = ([track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class]) ? track.metadata : nil;
    NSString *queuedMeta = [meta[@"is_queued"] description] ?: @"";
    return [queuedMeta isEqualToString:@"true"] || [queuedMeta isEqualToString:@"1"];
}

static NSString *SGRTrackUID(SPTPlayerTrack *track) {
    if (!track) return @"";
    if ([track respondsToSelector:@selector(UID)] && [track.UID isKindOfClass:NSString.class] && track.UID.length) {
        return track.UID;
    }
    NSDictionary *meta = ([track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class]) ? track.metadata : nil;
    return [meta[@"uid"] isKindOfClass:NSString.class] ? meta[@"uid"] : @"";
}

static NSString *SGRQueueKeyForPlayerTrack(SPTPlayerTrack *track, NSUInteger occurrence) {
    NSString *uri = SGURIString([track respondsToSelector:@selector(URI)] ? track.URI : nil);
    if (!uri.length) return @"";
    NSString *uid = SGRTrackUID(track);
    NSString *prefix = SGRIsUserQueuedTrack(track) ? @"uq|" : @"";
    return uid.length ? [NSString stringWithFormat:@"%@%@|%@", prefix, uri, uid]
                      : [NSString stringWithFormat:@"%@%@|#%lu", prefix, uri, (unsigned long)occurrence];
}

static id SGRShareItemForSpotifyURI(NSString *uri) {
    if (!uri.length) return nil;
    NSArray<NSString *> *parts = [uri componentsSeparatedByString:@":"];
    if (parts.count == 3 && [parts[0] isEqualToString:@"spotify"] && parts[1].length && parts[2].length) {
        NSURL *web = [NSURL URLWithString:[NSString stringWithFormat:@"https://open.spotify.com/%@/%@", parts[1], parts[2]]];
        if (web) return web;
    }
    return uri;
}

// ============================================================================
// Constants & Geometry (Measured 1:1 from Apple Music @ 390x844 pt)
// ============================================================================

static const CGFloat kGrabberWidth = 60.0;
static const CGFloat kGrabberHeight = 4.0;
static const CGFloat kViewportTopOffset = 26.0;             // Grabber at y=2.0 (screenY=56), Viewport at y=26 (screenY=80)
static const CGFloat kSideMargin = 32.0;                    // Left/right column alignment across artwork, pills, headers & rows
static const CGFloat kNowPlayingDocY = 0.0;                 // screenY = 80.0 + 0.0 = 80.0 at scrollY = 0
static const CGFloat kNowPlayingHeight = 87.0;              // 72pt thumbnail + 15pt gap below to pills (screenY = 167.0)
static const CGFloat kContinueHeaderDocY = 87.0;            // Now playing ends at 87.0, pills start at screenY = 167.0
static const CGFloat kContinueHeaderPinOffset = 2.0;        // Pins at viewportY = 2.0 (screenY = 82.0)
static const CGFloat kPillsBarHeight = 38.0;                // 4-pill bar height (screenY = 167.0..205.0)
static const CGFloat kFirstSectionHeaderOffset = 55.0;      // 38pt pills + 17pt gap to first section header (docY = 142.0, screenY = 222.0)
static const CGFloat kUserQueueHeaderHeight = 43.33;        // Queue header height (docY = 142.0..185.33, Row 0 at screenY = 265.33)
static const CGFloat kAddSongsRowHeight = 48.0;             // "+ Add Songs to Queue" control row height
static const CGFloat kUserQueueToContinueGap = 26.0;        // Gap between "+ Add Songs to Queue" bottom and "Continue Playing" header
static const CGFloat kContinueSectionHeaderHeight = 52.0;   // Continue Playing header height when Queue is empty (Row 0 at screenY = 274.0)
static const CGFloat kContinueAfterQueueHeaderHeight = 52.33; // Continue Playing header height below Queue (Row 0 at screenY = 447.67)
static const CGFloat kQueueRowPitch = 56.0;                 // 48pt art + 8pt vertical gap (shared across History, Queue, and Continue Playing)
static const CGFloat kHistoryHeaderHeight = 43.33;          // Matches kUserQueueHeaderHeight (43.33 pt from header top to first row)
static const CGFloat kHistoryHeaderClipOffset = 43.33;      // Clips scrolling History rows cleanly at the top edge of Row 0 below "History / Clear"
static const CGFloat kHistoryRowPitch = 56.0;               // 48pt art + 8pt vertical gap matching Apple Music History rows
static const CGFloat kHistoryBottomGap = 26.0;              // 26.0 pt gap below last History row to Now Playing card
static const CGFloat kHistoryHeaderPinOffset = 26.0;        // Pins at viewportY = 26.0 (screenY = 106.0 pt, cap-top = 109.0 pt)
static const CGFloat kHistoryHeaderPushOffDocY = -43.33;    // Rises off-screen as scrollY travels back to 0 pt

static const CGFloat kSwipeParkOffset = -80.0;
static const CGFloat kSwipeCommitRatio = 0.58;

// ============================================================================
// Artwork URL Resolution & Async Loader (i.scdn.co + LocalFiles cache)
// ============================================================================

static BOOL SGRIsHex40String(NSString *str) {
    if (str.length != 40) return NO;
    for (NSUInteger i = 0; i < 40; i++) {
        unichar c = [str characterAtIndex:i];
        BOOL isHex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!isHex) return NO;
    }
    return YES;
}

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
    if (SGRIsHex40String(val)) {
        return [NSURL URLWithString:[@"https://i.scdn.co/image/" stringByAppendingString:val.lowercaseString]];
    }
    return nil;
}

static NSURL *SGRQueueArtworkURLForTrack(SPTPlayerTrack *track) {
    if (!track) return nil;
    if ([track respondsToSelector:@selector(metadata)]) {
        NSDictionary *metadata = track.metadata;
        if ([metadata isKindOfClass:NSDictionary.class]) {
            for (NSString *field in @[@"image_url", @"image_large_url", @"image_small_url", @"image_xlarge_url"]) {
                NSURL *url = SGRNormalizedArtworkURLFromString(metadata[field]);
                if (url) return url;
            }
        }
    }
    if ([track respondsToSelector:@selector(imageURL)]) {
        NSURL *direct = SGRNormalizedArtworkURLFromString(SGURIString(track.imageURL));
        if (direct) return direct;
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
    if (!key.length) return;
    UIImage *cached = [SGRQueueImageCache() objectForKey:key];
    if (cached) {
        completion(cached);
        return;
    }

    static NSMutableDictionary<NSString *, NSMutableArray<void (^)(UIImage *)> *> *inFlight;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inFlight = [NSMutableDictionary dictionary];
    });

    NSMutableArray<void (^)(UIImage *)> *callbacks = inFlight[key];
    if (callbacks) {
        [callbacks addObject:[completion copy]];
        return;
    }
    inFlight[key] = [NSMutableArray arrayWithObject:[completion copy]];

    void (^finish)(UIImage *) = ^(UIImage *img) {
        if (img) [SGRQueueImageCache() setObject:img forKey:key];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<void (^)(UIImage *)> *waiting = inFlight[key];
            [inFlight removeObjectForKey:key];
            for (void (^cb)(UIImage *) in waiting) {
                cb(img);
            }
        });
    };

    if (url.isFileURL) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            finish([UIImage imageWithContentsOfFile:url.path]);
        });
        return;
    }
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, __unused NSURLResponse *response, NSError *error) {
        finish((data.length && !error) ? [UIImage imageWithData:data] : nil);
    }] resume];
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
    if (!artist.length) artist = [meta[@"artist_name"] isKindOfClass:NSString.class] ? meta[@"artist_name"] : @"";
    if (!artist.length) artist = [meta[@"show_name"] isKindOfClass:NSString.class] ? meta[@"show_name"] : @"";
    if (!artist.length) artist = ([track respondsToSelector:@selector(albumTitle)] && [track.albumTitle isKindOfClass:NSString.class]) ? track.albumTitle : @"";
    if (!artist.length) artist = [meta[@"album_title"] isKindOfClass:NSString.class] ? meta[@"album_title"] : @"";
    return artist ?: @"";
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
@property (nonatomic, assign) BOOL isAutoplay;
@property (nonatomic, assign) BOOL optimisticPlayNext;
@property (nonatomic, assign) CFTimeInterval optimisticUntil;
@property (nonatomic, strong) SPTPlayerTrack *playerTrack;
@end

@implementation SGRQueueItem

+ (instancetype)itemFromPlayerTrack:(SPTPlayerTrack *)track fallbackContextURI:(NSString *)contextURI occurrence:(NSUInteger)occurrence {
    if (!track || ![track respondsToSelector:@selector(URI)]) return nil;
    NSString *uri = SGURIString(track.URI);
    if (!uri.length) return nil;

    NSDictionary *meta = ([track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class]) ? track.metadata : nil;
    NSString *uid = SGRTrackUID(track);
    NSString *title = [track respondsToSelector:@selector(trackTitle)] ? track.trackTitle : nil;
    if (!title.length) title = [meta[@"title"] isKindOfClass:NSString.class] ? meta[@"title"] : @"";

    NSString *albumTitle = ([track respondsToSelector:@selector(albumTitle)] && [track.albumTitle isKindOfClass:NSString.class] && track.albumTitle.length)
        ? track.albumTitle
        : ([meta[@"album_title"] isKindOfClass:NSString.class] ? meta[@"album_title"] : @"");
    NSString *albumURI = SGURIString([track respondsToSelector:@selector(albumURI)] ? track.albumURI : nil);
    if (!albumURI.length && [meta[@"album_uri"] isKindOfClass:NSString.class]) albumURI = meta[@"album_uri"];
    if (!albumURI.length && [contextURI hasPrefix:@"spotify:album:"]) albumURI = contextURI;

    SGRQueueItem *item = [[SGRQueueItem alloc] init];
    item.uri = uri;
    item.uid = uid;
    item.key = SGRQueueKeyForPlayerTrack(track, occurrence);
    item.title = title;
    item.artist = SGRFormattedArtistsForTrack(track);
    item.albumTitle = albumTitle ?: @"";
    item.albumURI = albumURI ?: @"";
    item.artistURI = SGURIString([track respondsToSelector:@selector(artistURI)] ? track.artistURI : nil) ?: ([meta[@"artist_uri"] isKindOfClass:NSString.class] ? meta[@"artist_uri"] : @"");
    item.isExplicit = SGRIsPlayerTrackExplicit(track);
    item.artworkURL = SGRQueueArtworkURLForTrack(track);
    item.isUserQueued = SGRIsUserQueuedTrack(track);
    item.isAutoplay = SGRIsAutoplayTrack(track);
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
@property (nonatomic, copy) NSString *albumURI;
@property (nonatomic, copy) NSString *artistURI;
@property (nonatomic, assign) BOOL isExplicit;
@property (nonatomic, strong) NSURL *artworkURL;
@end

@implementation SGRResolvedTrackMeta
@end

static NSString *SGRBase62FromGID(NSData *gid) {
    if (gid.length != 16) return nil;
    static const char kAlphabet[] = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    uint8_t buf[16];
    memcpy(buf, gid.bytes, 16);
    char out[23];
    out[22] = '\0';
    for (int pos = 21; pos >= 0; pos--) {
        uint32_t rem = 0;
        for (int i = 0; i < 16; i++) {
            uint32_t cur = (rem << 8) | buf[i];
            buf[i] = (uint8_t)(cur / 62);
            rem = cur % 62;
        }
        out[pos] = kAlphabet[rem];
    }
    return [NSString stringWithUTF8String:out];
}

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

            // Track.artist = repeated field 4 (Artist.gid = field 1, Artist.name = field 2)
            NSMutableArray<NSString *> *artistNames = [NSMutableArray array];
            NSString *firstArtistURI = nil;
            for (SGPBField *artField in SGRPBAll(track, 4, 2)) {
                NSArray<SGPBField *> *artMsg = SGPBParse(artField.payload);
                if (!firstArtistURI) {
                    NSString *aID = SGRBase62FromGID(SGRPBAll(artMsg, 1, 2).firstObject.payload);
                    if (aID.length == 22) firstArtistURI = [@"spotify:artist:" stringByAppendingString:aID];
                }
                NSString *aName = SGPBText(SGRPBAll(artMsg, 2, 2).firstObject);
                if (aName.length && ![artistNames containsObject:aName]) {
                    [artistNames addObject:aName];
                }
            }
            meta.artist = [artistNames componentsJoinedByString:@", "];
            meta.artistURI = firstArtistURI ?: @"";

            // Track.album = field 3 (Album.gid = field 1, Album.name = field 2, Album.cover = repeated field 9, Album.cover_group = field 17 -> field 1)
            SGPBField *albumField = SGRPBAll(track, 3, 2).firstObject;
            NSArray<SGPBField *> *albumMsg = albumField ? SGPBParse(albumField.payload) : nil;
            if (albumMsg) {
                NSString *albID = SGRBase62FromGID(SGRPBAll(albumMsg, 1, 2).firstObject.payload);
                if (albID.length == 22) meta.albumURI = [@"spotify:album:" stringByAppendingString:albID];
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
@property (nonatomic, readonly) NSArray<SGRQueueItem *> *userQueuedItems;
@property (nonatomic, readonly) NSArray<SGRQueueItem *> *continuePlayingItems;
@property (nonatomic, readonly) SGRQueueItem *nowPlayingItem;
@property (nonatomic, readonly) NSString *contextSubtitle;
@property (nonatomic, readonly) BOOL isShuffling;

+ (instancetype)shared;
- (void)ensureResolvedIfNeeded;
- (void)clearHistory;
- (void)clearUserQueue;
- (void)deleteUserQueuedItemWithKey:(NSString *)key;
- (void)moveUserQueuedItemFromIndex:(NSUInteger)fromIdx toIndex:(NSUInteger)toIdx;
- (void)optimisticallyInsertUserQueuedItem:(SGRQueueItem *)item playNext:(BOOL)playNext;
- (void)deleteContinuePlayingItemWithKey:(NSString *)key;
- (void)moveContinuePlayingItemFromIndex:(NSUInteger)fromIdx toIndex:(NSUInteger)toIdx;
- (void)commitContinuePlayingReorder;
- (void)invalidateUncappedStateAndRefetch;
- (void)refreshForAutoplaySettingChange;
- (void)setOptimisticShuffle:(BOOL)shuffling;
- (BOOL)isTrackSaved:(NSString *)uri;
- (void)querySavedIfNeededForURI:(NSString *)uri;
- (void)setTrackURI:(NSString *)uri saved:(BOOL)saved;
@end

@implementation SGRQueueSession {
    NSMutableArray<SGRQueueItem *> *_historyItems;
    NSMutableArray<SGRQueueItem *> *_userQueuedItems;
    NSMutableArray<SGRQueueItem *> *_continuePlayingItems;
    NSMutableArray<SGRQueueItem *> *_unshuffledContinueItems;
    NSMutableArray<NSString *> *_shuffledOrderKeys;
    NSMutableArray<NSString *> *_customOrderedKeys;
    NSMutableArray<NSString *> *_customUserQueueOrderKeys;
    NSMutableArray<SGRQueueItem *> *_optimisticUserQueuedItems;
    BOOL _userQueueCleared;

    SGRQueueItem *_nowPlayingItem;
    NSString *_activeContextURI;
    NSString *_loadingContextURI;
    NSString *_resolvedContextTitle;
    NSArray<SGRContextTrackEntry *> *_contextEntries;
    NSMutableDictionary<NSString *, SGRResolvedTrackMeta *> *_metadataCache;
    NSMutableSet<NSString *> *_inFlightMetadataURIs;
    NSMutableSet<NSString *> *_deletedKeys;
    NSMutableDictionary<NSString *, NSNumber *> *_savedStateByURI;
    NSMutableSet<NSString *> *_checkingSavedURIs;

    SPTPlayerState *_uncappedState;
    NSString *_lastUncappedFetchKey;

    BOOL _historyClearedByUser;
    BOOL _historySeededFromContext;
    NSString *_initialSeedTrackURI;
    BOOL _isShuffling;
    BOOL _hasOptimisticShuffle;
    BOOL _optimisticShuffleValue;
    CFTimeInterval _optimisticShuffleUntil;
    BOOL _lastTrackWasNonAutoplay;
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
    _userQueuedItems = [NSMutableArray array];
    _continuePlayingItems = [NSMutableArray array];
    _unshuffledContinueItems = [NSMutableArray array];
    _shuffledOrderKeys = [NSMutableArray array];
    _customOrderedKeys = [NSMutableArray array];
    _customUserQueueOrderKeys = [NSMutableArray array];
    _optimisticUserQueuedItems = [NSMutableArray array];
    _metadataCache = [NSMutableDictionary dictionary];
    _inFlightMetadataURIs = [NSMutableSet set];
    _deletedKeys = [NSMutableSet set];
    _savedStateByURI = [NSMutableDictionary dictionary];
    _checkingSavedURIs = [NSMutableSet set];

    SGAddPlayerStateObserver(self);
    SPTPlayerState *initial = SGPlayerState();
    if (initial) [self ingestPlayerState:initial];
    return self;
}

- (NSArray<SGRQueueItem *> *)historyItems {
    return [_historyItems copy];
}

- (NSArray<SGRQueueItem *> *)userQueuedItems {
    return [_userQueuedItems copy];
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
    SPTPlayerState *state = SGPlayerState() ?: _uncappedState;
    SPTPlayerTrack *np = state.track;
    NSDictionary *trackMeta = ([np respondsToSelector:@selector(metadata)] && [np.metadata isKindOfClass:NSDictionary.class]) ? np.metadata : nil;
    NSDictionary *ctxMeta = ([state respondsToSelector:@selector(contextMetadata)] && [state.contextMetadata isKindOfClass:NSDictionary.class]) ? state.contextMetadata : nil;
    NSDictionary *pageMeta = ([state respondsToSelector:@selector(pageMetadata)] && [state.pageMetadata isKindOfClass:NSDictionary.class]) ? state.pageMetadata : nil;

    // 1. Live context title displayed at the top of Now Playing (HeaderElementsUnit)
    NSString *desc = SGRPlayerHeaderContextTitle();

    // 2. SPTPlayerState contextMetadata / pageMetadata / track.metadata context_description
    if (!desc.length && [ctxMeta[@"context_description"] isKindOfClass:NSString.class]) {
        desc = ctxMeta[@"context_description"];
    }
    if (!desc.length && [pageMeta[@"context_description"] isKindOfClass:NSString.class]) {
        desc = pageMeta[@"context_description"];
    }
    if (!desc.length && [pageMeta[@"page_title"] isKindOfClass:NSString.class]) {
        desc = pageMeta[@"page_title"];
    }
    if (!desc.length && [trackMeta[@"context_description"] isKindOfClass:NSString.class]) {
        desc = trackMeta[@"context_description"];
    }

    // 3. spclient context-resolve metadata.context_description
    if (!desc.length && _resolvedContextTitle.length) {
        desc = _resolvedContextTitle;
    }

    // 4. Context-URI-aware fallback (only use albumTitle when actually playing from an album context!)
    NSString *ctxURI = _activeContextURI ?: @"";
    if (!desc.length) {
        if ([ctxURI containsString:@":collection"]) {
            desc = @"Liked Songs";
        } else if ([ctxURI hasPrefix:@"spotify:album:"]) {
            desc = [trackMeta[@"album_title"] isKindOfClass:NSString.class] ? trackMeta[@"album_title"] : @"";
            if (!desc.length) desc = _nowPlayingItem.albumTitle ?: @"";
        } else if ([ctxURI hasPrefix:@"spotify:artist:"]) {
            desc = _nowPlayingItem.artist ?: @"";
        } else if ([ctxURI hasPrefix:@"spotify:station:"] || [ctxURI containsString:@":radio:"]) {
            desc = _nowPlayingItem.title.length ? [NSString stringWithFormat:@"%@ Radio", _nowPlayingItem.title] : @"Radio";
        } else if ([ctxURI hasPrefix:@"spotify:search"]) {
            desc = @"Search";
        }
    }

    desc = [desc stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if ([desc caseInsensitiveCompare:@"Collection"] == NSOrderedSame) {
        desc = @"Liked Songs";
    }
    NSRange fromPrefix = [desc rangeOfString:@"From " options:NSCaseInsensitiveSearch | NSAnchoredSearch];
    if (fromPrefix.location != NSNotFound && desc.length > fromPrefix.length) {
        desc = [[desc substringFromIndex:fromPrefix.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if ([desc hasSuffix:@"."] && desc.length > 1) {
        desc = [desc substringToIndex:desc.length - 1];
    }
    if (desc.length > 0) {
        return [NSString stringWithFormat:@"From %@", desc];
    }
    return _nowPlayingItem.isAutoplay ? @"Autoplay" : @"";
}

- (BOOL)isTrackSaved:(NSString *)uri {
    if (!uri.length) return NO;
    NSNumber *cached = _savedStateByURI[uri];
    if (cached) return cached.boolValue;
    [self querySavedIfNeededForURI:uri];
    SPTPlayerState *state = SGPlayerState();
    if (state.track && [SGURIString(state.track.URI) isEqualToString:uri]) {
        NSDictionary *meta = ([state.track respondsToSelector:@selector(metadata)] && [state.track.metadata isKindOfClass:NSDictionary.class]) ? state.track.metadata : nil;
        NSString *inCol = [meta[@"collection.in_collection"] isKindOfClass:NSString.class] ? meta[@"collection.in_collection"] : nil;
        if ([inCol isEqualToString:@"true"] || [inCol isEqualToString:@"1"]) return YES;
    }
    return NO;
}

- (void)querySavedIfNeededForURI:(NSString *)uri {
    if (!uri.length || ![uri hasPrefix:@"spotify:track:"] || _savedStateByURI[uri] || [_checkingSavedURIs containsObject:uri]) return;
    NSURL *url = [NSURL URLWithString:uri];
    if (!url) return;
    [_checkingSavedURIs addObject:uri];
    __weak typeof(self) weakSelf = self;
    SGRCollectionCheckSaved(url, ^(BOOL known, BOOL saved) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s->_checkingSavedURIs removeObject:uri];
        if (known) {
            NSNumber *prev = s->_savedStateByURI[uri];
            s->_savedStateByURI[uri] = @(saved);
            if (!prev || prev.boolValue != saved) {
                [s notifyObservers];
            }
        }
    });
}

- (void)setTrackURI:(NSString *)uri saved:(BOOL)saved {
    if (!uri.length) return;
    NSURL *url = [NSURL URLWithString:uri];
    if (!url) return;
    _savedStateByURI[uri] = @(saved);
    if (saved) {
        SGRCollectionAddURL(url, YES);
    } else {
        SGRCollectionRemoveURL(url, YES);
    }
    [self notifyObservers];
}

- (void)clearHistory {
    _historyClearedByUser = YES;
    [_historyItems removeAllObjects];
    [self notifyObservers];
}

- (void)clearUserQueue {
    for (SGRQueueItem *it in _userQueuedItems) {
        if (it.key.length) [_deletedKeys addObject:it.key];
    }
    _userQueueCleared = YES;
    [_userQueuedItems removeAllObjects];
    [_customUserQueueOrderKeys removeAllObjects];
    [_optimisticUserQueuedItems removeAllObjects];
    [self syncMutationsToSpotifyQueue];
    [self notifyObservers];
}

- (void)deleteUserQueuedItemWithKey:(NSString *)key {
    if (!key.length) return;
    [_deletedKeys addObject:key];
    [_customUserQueueOrderKeys removeObject:key];
    SGRRemoveItemWithKeyFromArray(_userQueuedItems, key);
    SGRRemoveItemWithKeyFromArray(_optimisticUserQueuedItems, key);
    [self syncMutationsToSpotifyQueue];
    [self notifyObservers];
}

- (void)moveUserQueuedItemFromIndex:(NSUInteger)fromIdx toIndex:(NSUInteger)toIdx {
    if (fromIdx >= _userQueuedItems.count || toIdx >= _userQueuedItems.count || fromIdx == toIdx) return;
    SGRQueueItem *moved = _userQueuedItems[fromIdx];
    [_userQueuedItems removeObjectAtIndex:fromIdx];
    [_userQueuedItems insertObject:moved atIndex:toIdx];

    [_customUserQueueOrderKeys removeAllObjects];
    for (SGRQueueItem *it in _userQueuedItems) {
        [_customUserQueueOrderKeys addObject:it.key];
    }
}

static void SGRRemoveItemWithKeyFromArray(NSMutableArray<SGRQueueItem *> *array, NSString *key) {
    for (NSUInteger i = 0; i < array.count; i++) {
        if ([array[i].key isEqualToString:key]) {
            [array removeObjectAtIndex:i];
            return;
        }
    }
}

static void SGRApplyCustomKeyOrder(NSMutableArray<SGRQueueItem *> *items, NSArray<NSString *> *orderedKeys) {
    if (orderedKeys.count == 0 || items.count <= 1) return;
    NSMutableDictionary<NSString *, SGRQueueItem *> *byKey = [NSMutableDictionary dictionaryWithCapacity:items.count];
    for (SGRQueueItem *it in items) byKey[it.key] = it;
    NSMutableArray<SGRQueueItem *> *reordered = [NSMutableArray arrayWithCapacity:items.count];
    NSMutableSet<NSString *> *placed = [NSMutableSet setWithCapacity:items.count];
    for (NSString *k in orderedKeys) {
        SGRQueueItem *it = byKey[k];
        if (it && ![placed containsObject:k]) {
            [placed addObject:k];
            [reordered addObject:it];
        }
    }
    for (SGRQueueItem *it in items) {
        if (![placed containsObject:it.key]) {
            [placed addObject:it.key];
            [reordered addObject:it];
        }
    }
    [items setArray:reordered];
}

- (void)optimisticallyInsertUserQueuedItem:(SGRQueueItem *)item playNext:(BOOL)playNext {
    if (!item.uri.length) return;
    _userQueueCleared = NO;
    static NSUInteger sOptSeq = 0;
    sOptSeq++;
    SGRQueueItem *copy = [[SGRQueueItem alloc] init];
    copy.uri = item.uri;
    copy.uid = [NSString stringWithFormat:@"opt_%lu_%lu", (unsigned long)(CACurrentMediaTime() * 1000.0), (unsigned long)sOptSeq];
    copy.key = [NSString stringWithFormat:@"uq|%@|%@", copy.uri, copy.uid];
    copy.title = item.title;
    copy.artist = item.artist;
    copy.albumTitle = item.albumTitle;
    copy.albumURI = item.albumURI;
    copy.artistURI = item.artistURI;
    copy.isExplicit = item.isExplicit;
    copy.artworkURL = item.artworkURL;
    copy.isUserQueued = YES;
    copy.isAutoplay = NO;
    copy.optimisticPlayNext = playNext;
    copy.optimisticUntil = CACurrentMediaTime() + 2.0;
    copy.playerTrack = item.playerTrack;

    if (playNext) {
        [_optimisticUserQueuedItems insertObject:copy atIndex:0];
        [_userQueuedItems insertObject:copy atIndex:0];
    } else {
        [_optimisticUserQueuedItems addObject:copy];
        [_userQueuedItems addObject:copy];
    }
    [self notifyObservers];
}

- (void)deleteContinuePlayingItemWithKey:(NSString *)key {
    if (!key.length) return;
    [_deletedKeys addObject:key];
    for (SGRQueueItem *it in _continuePlayingItems) {
        if ([it.key isEqualToString:key]) {
            if (it.uid.length && it.uri.length) {
                [_deletedKeys addObject:[NSString stringWithFormat:@"%@|%@", it.uri, it.uid]];
            }
            if (it.playerTrack) {
                NSString *ptKey = SGRQueueKeyForPlayerTrack(it.playerTrack, 0);
                if (ptKey.length) [_deletedKeys addObject:ptKey];
            }
            break;
        }
    }
    [_shuffledOrderKeys removeObject:key];
    [_customOrderedKeys removeObject:key];
    SGRRemoveItemWithKeyFromArray(_continuePlayingItems, key);
    SGRRemoveItemWithKeyFromArray(_unshuffledContinueItems, key);
    [self syncMutationsToSpotifyQueue];
    [self notifyObservers];
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

- (void)commitContinuePlayingReorder {
    [self syncMutationsToSpotifyQueue];
    [self notifyObservers];
}

- (void)syncMutationsToSpotifyQueue {
    id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
    if (![player respondsToSelector:@selector(fetchQueue:on:)] || ![player respondsToSelector:@selector(setQueue:)]) return;

    NSArray<SGRQueueItem *> *desiredUser = [_userQueuedItems copy];
    NSArray<SGRQueueItem *> *desiredContinue = [_continuePlayingItems copy];
    NSArray<SGRQueueItem *> *desiredItems = [desiredUser arrayByAddingObjectsFromArray:desiredContinue];
    NSSet<NSString *> *deleted = [_deletedKeys copy];
    BOOL clearedUserQueue = _userQueueCleared;
    BOOL hasCustomReorder = (_customOrderedKeys.count > 0 || _customUserQueueOrderKeys.count > 0);
    __weak typeof(self) weakSelf = self;

    @try {
        [player fetchQueue:^(id qObj) {
            if (!qObj || ![qObj respondsToSelector:@selector(nextTracks)] || ![qObj respondsToSelector:@selector(setNextTracks:)]) return;
            id<SGRSpotifyQueueObject> queue = (id<SGRSpotifyQueueObject>)qObj;
            NSArray *origNext = [queue.nextTracks isKindOfClass:NSArray.class] ? queue.nextTracks : nil;
            if (!origNext.count) return;

            NSMutableDictionary<NSString *, SPTPlayerTrack *> *byUID = [NSMutableDictionary dictionaryWithCapacity:origNext.count];
            NSMutableDictionary<NSString *, NSMutableArray<SPTPlayerTrack *> *> *byURI = [NSMutableDictionary dictionaryWithCapacity:origNext.count];
            NSMutableArray<SPTPlayerTrack *> *keptOrig = [NSMutableArray arrayWithCapacity:origNext.count];

            NSUInteger occ = 0;
            for (id obj in origNext) {
                if (![obj respondsToSelector:@selector(URI)]) continue;
                SPTPlayerTrack *t = (SPTPlayerTrack *)obj;
                NSString *u = SGURIString(t.URI);
                if (!u.length) continue;
                BOOL isTrackUserQueued = SGRIsUserQueuedTrack(t);
                NSString *uid = SGRTrackUID(t);
                NSString *key = SGRQueueKeyForPlayerTrack(t, occ++);
                if ([deleted containsObject:key]) continue;
                if (clearedUserQueue && isTrackUserQueued) continue;
                [keptOrig addObject:t];
                if (uid.length && !byUID[uid]) byUID[uid] = t;
                NSMutableArray<SPTPlayerTrack *> *bucket = byURI[u];
                if (!bucket) byURI[u] = bucket = [NSMutableArray array];
                [bucket addObject:t];
            }

            NSMutableArray<SPTPlayerTrack *> *rebuilt = [NSMutableArray arrayWithCapacity:keptOrig.count];
            NSMutableSet<NSValue *> *usedPtrs = [NSMutableSet setWithCapacity:keptOrig.count];

            for (SGRQueueItem *item in desiredItems) {
                SPTPlayerTrack *matched = nil;
                if (item.uid.length && byUID[item.uid]) {
                    SPTPlayerTrack *cand = byUID[item.uid];
                    NSValue *ptr = [NSValue valueWithNonretainedObject:cand];
                    if (![usedPtrs containsObject:ptr]) matched = cand;
                }
                if (!matched && item.uri.length) {
                    // First pass: match same user-queued vs context classification
                    for (SPTPlayerTrack *cand in byURI[item.uri]) {
                        NSValue *ptr = [NSValue valueWithNonretainedObject:cand];
                        if (![usedPtrs containsObject:ptr] && SGRIsUserQueuedTrack(cand) == item.isUserQueued) {
                            matched = cand;
                            break;
                        }
                    }
                    // Fallback pass: any unused candidate with matching URI
                    if (!matched) {
                        for (SPTPlayerTrack *cand in byURI[item.uri]) {
                            NSValue *ptr = [NSValue valueWithNonretainedObject:cand];
                            if (![usedPtrs containsObject:ptr]) {
                                matched = cand;
                                break;
                            }
                        }
                    }
                }
                if (matched) {
                    [usedPtrs addObject:[NSValue valueWithNonretainedObject:matched]];
                    [rebuilt addObject:matched];
                } else if (hasCustomReorder && !item.isUserQueued && rebuilt.count < origNext.count) {
                    SPTPlayerTrack *constructed = [item resolvedPlayerTrack];
                    if (constructed) [rebuilt addObject:constructed];
                }
            }

            @try {
                [queue setNextTracks:rebuilt];
                [player setQueue:queue];
                __strong typeof(weakSelf) s = weakSelf;
                if (s) [s invalidateUncappedStateAndRefetch];
            } @catch (__unused NSException *e) {}
        } on:dispatch_get_main_queue()];
    } @catch (__unused NSException *e) {}
}

- (void)invalidateUncappedStateAndRefetch {
    _uncappedState = nil;
    _lastUncappedFetchKey = nil;
    SPTPlayerState *st = SGPlayerState();
    if (st) [self requestUncappedStateForState:st];
}

- (void)refreshForAutoplaySettingChange {
    [self rebuildContinuePlayingWithState:(SGPlayerState() ?: _uncappedState) shuffleJustTurnedOn:NO];
    [self notifyObservers];
}

- (void)setOptimisticShuffle:(BOOL)shuffling {
    _hasOptimisticShuffle = YES;
    _optimisticShuffleValue = shuffling;
    _optimisticShuffleUntil = CACurrentMediaTime() + 1.0;
    [_customOrderedKeys removeAllObjects];
    _lastUncappedFetchKey = nil;
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
    NSString *album = ([track respondsToSelector:@selector(albumTitle)] && [track.albumTitle isKindOfClass:NSString.class] && track.albumTitle.length)
        ? track.albumTitle
        : ([meta[@"album_title"] isKindOfClass:NSString.class] ? meta[@"album_title"] : @"");
    if (album.length) resolved.albumTitle = album;
    NSString *albURI = SGURIString([track respondsToSelector:@selector(albumURI)] ? track.albumURI : nil);
    if (!albURI.length && [meta[@"album_uri"] isKindOfClass:NSString.class]) albURI = meta[@"album_uri"];
    if (albURI.length) resolved.albumURI = albURI;
    NSString *artURI = SGURIString([track respondsToSelector:@selector(artistURI)] ? track.artistURI : nil);
    if (!artURI.length && [meta[@"artist_uri"] isKindOfClass:NSString.class]) artURI = meta[@"artist_uri"];
    if (artURI.length) resolved.artistURI = artURI;
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

- (void)requestUncappedStateForState:(SPTPlayerState *)state {
    if (!state.track) return;
    id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
    if (![player respondsToSelector:@selector(fetchState:reverseCap:futureCap:on:)]) return;

    NSString *ctxURI = [self effectiveContextURIForState:state];
    NSString *trackURI = SGURIString(state.track.URI) ?: @"";
    if (!trackURI.length) return;
    BOOL shuf = state.options ? state.options.shufflingContext : NO;
    NSArray *rawFuture = ([state respondsToSelector:@selector(future)] && [state.future isKindOfClass:NSArray.class]) ? state.future : @[];
    NSUInteger uqCount = 0;
    for (id obj in rawFuture) {
        if ([obj respondsToSelector:@selector(URI)] && SGRIsUserQueuedTrack((SPTPlayerTrack *)obj)) uqCount++;
    }
    NSString *firstFut = (rawFuture.count > 0 && [rawFuture[0] respondsToSelector:@selector(URI)]) ? (SGURIString([(SPTPlayerTrack *)rawFuture[0] URI]) ?: @"") : @"";
    NSString *qRev = ([state respondsToSelector:@selector(queueRevision)] && state.queueRevision) ? [NSString stringWithFormat:@"%@", state.queueRevision] : @"";
    NSString *fetchKey = [NSString stringWithFormat:@"%@|%@|%d|%lu|uq:%lu|%@|%@", ctxURI, trackURI, shuf ? 1 : 0, (unsigned long)rawFuture.count, (unsigned long)uqCount, firstFut, qRev];
    if ([fetchKey isEqualToString:_lastUncappedFetchKey]) return;
    _lastUncappedFetchKey = [fetchKey copy];

    __weak typeof(self) weakSelf = self;
    @try {
        [player fetchState:^(SPTPlayerState *full) {
            __strong typeof(weakSelf) s = weakSelf;
            if (!s || ![full isKindOfClass:NSObject.class] || ![full respondsToSelector:@selector(track)]) return;
            NSString *fullURI = SGURIString(full.track.URI);
            if (!fullURI.length || (s->_nowPlayingItem.uri.length && ![fullURI isEqualToString:s->_nowPlayingItem.uri])) return;

            s->_uncappedState = full;
            [s harvestMetadataFromPlayerTrack:full.track];
            NSArray *rev = ([full respondsToSelector:@selector(reverse)] && [full.reverse isKindOfClass:NSArray.class]) ? full.reverse : @[];
            NSArray *fut = ([full respondsToSelector:@selector(future)] && [full.future isKindOfClass:NSArray.class]) ? full.future : @[];
            for (id t in rev) {
                if ([t respondsToSelector:@selector(URI)]) [s harvestMetadataFromPlayerTrack:(SPTPlayerTrack *)t];
            }
            for (id t in fut) {
                if ([t respondsToSelector:@selector(URI)]) [s harvestMetadataFromPlayerTrack:(SPTPlayerTrack *)t];
            }

            if (!s->_historyClearedByUser && !s->_historySeededFromContext && s->_historyItems.count <= 2 &&
                rev.count > s->_historyItems.count && [s->_nowPlayingItem.uri isEqualToString:s->_initialSeedTrackURI]) {
                [s->_historyItems removeAllObjects];
                [s seedInitialHistoryFromState:full];
            }

            [s rebuildContinuePlayingWithState:(SGPlayerState() ?: full) shuffleJustTurnedOn:NO];
            [s notifyObservers];
        } reverseCap:80 futureCap:80 on:dispatch_get_main_queue()];
    } @catch (__unused NSException *e) {}
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
        _loadingContextURI = nil;
        _resolvedContextTitle = nil;
        _uncappedState = nil;
        _lastUncappedFetchKey = nil;
        [_deletedKeys removeAllObjects];
        [_shuffledOrderKeys removeAllObjects];
        [_customOrderedKeys removeAllObjects];
        [_customUserQueueOrderKeys removeAllObjects];
        [_optimisticUserQueuedItems removeAllObjects];
        _userQueueCleared = NO;
        _historySeededFromContext = NO;
        [self resolveContextIfSupported:ctxURI triesLeft:3];
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
        _lastUncappedFetchKey = nil;
        if (!_isShuffling) {
            [_shuffledOrderKeys removeAllObjects];
        }
    }

    SGRQueueItem *incomingNP = [SGRQueueItem itemFromPlayerTrack:np fallbackContextURI:ctxURI occurrence:0];
    [self enrichQueueItem:incomingNP];
    if (incomingNP.uri.length) [self querySavedIfNeededForURI:incomingNP.uri];

    NSString *prevURI = _nowPlayingItem.uri;
    NSString *newURI = incomingNP.uri;

    // Enforce Autoplay off: when a context finishes and Spotify advances onto an autoplay track, pause cleanly.
    if (newURI.length && prevURI.length && ![newURI isEqualToString:prevURI]) {
        if (!SGFlag(SGRKeyQueueAutoplay, YES) && _lastTrackWasNonAutoplay && incomingNP.isAutoplay && !incomingNP.isUserQueued && !state.isPaused) {
            id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
            if ([player respondsToSelector:@selector(pause:)]) {
                @try { [player pause:nil]; } @catch (__unused NSException *e) {}
            }
        }
    }
    if (incomingNP.uri.length) {
        _lastTrackWasNonAutoplay = !(incomingNP.isAutoplay && !incomingNP.isUserQueued);
    }

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
        [_customUserQueueOrderKeys removeObject:incomingNP.key];
        for (NSUInteger i = 0; i < _optimisticUserQueuedItems.count; i++) {
            if ([_optimisticUserQueuedItems[i].uri isEqualToString:newURI]) {
                [_optimisticUserQueuedItems removeObjectAtIndex:i];
                break;
            }
        }
    } else if (incomingNP) {
        _nowPlayingItem = incomingNP;
    }

    for (SGRQueueItem *h in _historyItems) [self enrichQueueItem:h];

    [self rebuildContinuePlayingWithState:state shuffleJustTurnedOn:(shuffleChanged && _isShuffling)];
    [self requestUncappedStateForState:state];
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
        if ([em[@"album_uri"] isKindOfClass:NSString.class] && !item.albumURI.length) item.albumURI = em[@"album_uri"];
        if ([em[@"artist_uri"] isKindOfClass:NSString.class] && !item.artistURI.length) item.artistURI = em[@"artist_uri"];
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
        if (meta.albumURI.length && !item.albumURI.length) item.albumURI = meta.albumURI;
        if (meta.artistURI.length && !item.artistURI.length) item.artistURI = meta.artistURI;
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
    if (!item.artist.length) {
        if (item.albumTitle.length) item.artist = item.albumTitle;
        else if (_resolvedContextTitle.length) item.artist = _resolvedContextTitle;
        else if (_nowPlayingItem.artist.length && ([_activeContextURI hasPrefix:@"spotify:show:"] || [item.uri hasPrefix:@"spotify:episode:"])) {
            item.artist = _nowPlayingItem.artist;
        }
    }
}

- (void)rebuildContinuePlayingWithState:(SPTPlayerState *)state shuffleJustTurnedOn:(BOOL)shuffleJustTurnedOn {
    NSArray *stateFuture = ([state respondsToSelector:@selector(future)] && [state.future isKindOfClass:NSArray.class]) ? state.future : @[];
    NSArray *uncappedFuture = (_uncappedState && _nowPlayingItem.uri.length &&
                               [SGURIString(_uncappedState.track.URI) isEqualToString:_nowPlayingItem.uri] &&
                               [_uncappedState respondsToSelector:@selector(future)] && [_uncappedState.future isKindOfClass:NSArray.class])
                              ? _uncappedState.future : nil;

    NSArray *rawFuture = stateFuture;
    if (uncappedFuture.count > stateFuture.count) {
        NSString *stFirst = (stateFuture.count > 0 && [stateFuture[0] respondsToSelector:@selector(URI)]) ? SGURIString([(SPTPlayerTrack *)stateFuture[0] URI]) : nil;
        NSString *unFirst = (uncappedFuture.count > 0 && [uncappedFuture[0] respondsToSelector:@selector(URI)]) ? SGURIString([(SPTPlayerTrack *)uncappedFuture[0] URI]) : nil;
        if (!stFirst.length || [stFirst isEqualToString:unFirst]) {
            rawFuture = uncappedFuture;
        }
    }

    BOOL autoplayOn = SGFlag(SGRKeyQueueAutoplay, YES);
    NSMutableArray<SGRQueueItem *> *userQueued = [NSMutableArray array];
    NSMutableArray<SGRQueueItem *> *liveContextFuture = [NSMutableArray array];
    NSMutableDictionary<NSString *, SPTPlayerTrack *> *liveTrackByUID = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, SPTPlayerTrack *> *liveTrackByURI = [NSMutableDictionary dictionary];

    NSUInteger occ = 0;
    for (id obj in rawFuture) {
        if (![obj respondsToSelector:@selector(URI)]) continue;
        SPTPlayerTrack *t = (SPTPlayerTrack *)obj;
        SGRQueueItem *it = [SGRQueueItem itemFromPlayerTrack:t fallbackContextURI:_activeContextURI occurrence:occ++];
        if (!it) continue;
        if (!autoplayOn && it.isAutoplay && !it.isUserQueued) continue;
        [self enrichQueueItem:it];
        if (it.uid.length && !liveTrackByUID[it.uid]) liveTrackByUID[it.uid] = t;
        if (!liveTrackByURI[it.uri]) liveTrackByURI[it.uri] = t;
        if ([_deletedKeys containsObject:it.key]) continue;
        if (it.isUserQueued) {
            if (!_userQueueCleared) [userQueued addObject:it];
        } else {
            [liveContextFuture addObject:it];
        }
    }
    if (userQueued.count == 0 && _userQueueCleared) {
        // Spotify core has finished removing cleared user-queue tracks
        _userQueueCleared = NO;
    }
    if (_optimisticUserQueuedItems.count > 0 && !_userQueueCleared) {
        CFTimeInterval now = CACurrentMediaTime();
        NSMutableSet<NSString *> *liveURIs = [NSMutableSet setWithCapacity:userQueued.count];
        for (SGRQueueItem *lq in userQueued) {
            if (lq.uri.length) [liveURIs addObject:lq.uri];
        }
        NSMutableArray<SGRQueueItem *> *stillPending = [NSMutableArray array];
        for (SGRQueueItem *opt in _optimisticUserQueuedItems) {
            if (now >= opt.optimisticUntil || [liveURIs containsObject:opt.uri]) {
                continue;
            }
            [stillPending addObject:opt];
            if (opt.optimisticPlayNext) {
                [userQueued insertObject:opt atIndex:0];
            } else {
                [userQueued addObject:opt];
            }
        }
        [_optimisticUserQueuedItems setArray:stillPending];
    }
    SGRApplyCustomKeyOrder(userQueued, _customUserQueueOrderKeys);
    [_userQueuedItems setArray:userQueued];
    if (userQueued.count > 0) {
        NSMutableArray<SGRContextTrackEntry *> *missingUQ = [NSMutableArray array];
        for (SGRQueueItem *uqItem in userQueued) {
            if (uqItem.uri.length == 36 && [uqItem.uri hasPrefix:@"spotify:track:"] &&
                !_metadataCache[uqItem.uri] && ![_inFlightMetadataURIs containsObject:uqItem.uri]) {
                SGRContextTrackEntry *ce = [[SGRContextTrackEntry alloc] init];
                ce.uri = uqItem.uri;
                ce.uid = uqItem.uid ?: @"";
                ce.key = uqItem.key ?: uqItem.uri;
                [missingUQ addObject:ce];
            }
        }
        if (missingUQ.count > 0) {
            [self fetchMissingExtendedMetadataForEntries:missingUQ contextURI:_activeContextURI triesLeft:2];
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
                if (it.uid.length && liveTrackByUID[it.uid]) {
                    it.playerTrack = liveTrackByUID[it.uid];
                } else if (liveTrackByURI[it.uri]) {
                    it.playerTrack = liveTrackByURI[it.uri];
                }
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
    } else if (!_isShuffling && liveContextFuture.count > unshuffled.count) {
        // Append any autoplay/tail tracks that Spotify's 80-track lookahead resolved after the end of the context
        NSMutableSet<NSString *> *existingKeys = [NSMutableSet setWithCapacity:unshuffled.count];
        for (SGRQueueItem *u in unshuffled) [existingKeys addObject:u.key];
        for (SGRQueueItem *lf in liveContextFuture) {
            if (![existingKeys containsObject:lf.key]) {
                [existingKeys addObject:lf.key];
                [unshuffled addObject:lf];
            }
        }
    }

    [_unshuffledContinueItems setArray:unshuffled];

    // Continue Playing holds ONLY natural context/autoplay tracks; manually queued tracks live in _userQueuedItems ("Queue")
    NSMutableArray<SGRQueueItem *> *finalList = [NSMutableArray array];

    if (!_isShuffling) {
        [finalList addObjectsFromArray:unshuffled];
    } else if (state.options.shufflingContext && liveContextFuture.count > 2) {
        // Spotify's C++ core returned its genuine active shuffled queue (up to 80 real SPTPlayerTrack items)!
        NSMutableSet<NSString *> *placedKeys = [NSMutableSet setWithCapacity:liveContextFuture.count];
        NSMutableSet<NSString *> *placedURIs = [NSMutableSet setWithCapacity:liveContextFuture.count];
        if (_nowPlayingItem.uri.length) [placedURIs addObject:_nowPlayingItem.uri];
        for (SGRQueueItem *lf in liveContextFuture) {
            [placedKeys addObject:lf.key];
            if (lf.uri.length) [placedURIs addObject:lf.uri];
            [finalList addObject:lf];
        }
        // For playlists larger than 80 tracks, append remaining unplayed context tracks in stable shuffled order
        if (allOtherContextItems.count > liveContextFuture.count) {
            NSMutableArray<SGRQueueItem *> *extraPool = [NSMutableArray array];
            for (SGRQueueItem *cand in allOtherContextItems) {
                if (![placedKeys containsObject:cand.key] && ![placedURIs containsObject:cand.uri]) {
                    [extraPool addObject:cand];
                }
            }
            [self appendShuffledPool:extraPool into:finalList resetOrder:shuffleJustTurnedOn seedLive:nil];
        }
    } else {
        // Optimistic/fallback shuffled mode while core shuffle response is still arriving
        NSArray<SGRQueueItem *> *pool = unshuffled.count > 0 ? unshuffled : allOtherContextItems;
        NSArray<SGRQueueItem *> *seedLive = state.options.shufflingContext ? liveContextFuture : nil;
        [self appendShuffledPool:pool into:finalList resetOrder:shuffleJustTurnedOn seedLive:seedLive];
    }

    SGRApplyCustomKeyOrder(finalList, _customOrderedKeys);

    [_continuePlayingItems setArray:finalList];
}

- (void)appendShuffledPool:(NSArray<SGRQueueItem *> *)pool
                      into:(NSMutableArray<SGRQueueItem *> *)finalList
                resetOrder:(BOOL)resetOrder
                  seedLive:(NSArray<SGRQueueItem *> *)seedLive {
    if (!pool.count) return;
    NSMutableDictionary<NSString *, SGRQueueItem *> *poolByKey = [NSMutableDictionary dictionaryWithCapacity:pool.count];
    NSMutableDictionary<NSString *, SGRQueueItem *> *poolByURI = [NSMutableDictionary dictionaryWithCapacity:pool.count];
    for (SGRQueueItem *it in pool) {
        poolByKey[it.key] = it;
        if (!poolByURI[it.uri]) poolByURI[it.uri] = it;
    }

    if (_shuffledOrderKeys.count == 0 || resetOrder) {
        NSMutableArray<SGRQueueItem *> *working = [pool mutableCopy];
        for (NSUInteger i = working.count; i > 1; i--) {
            NSUInteger j = arc4random_uniform((uint32_t)i);
            [working exchangeObjectAtIndex:i - 1 withObjectAtIndex:j];
        }
        [_shuffledOrderKeys removeAllObjects];
        for (SGRQueueItem *lf in seedLive) {
            SGRQueueItem *match = poolByKey[lf.key] ?: poolByURI[lf.uri];
            if (match && ![_shuffledOrderKeys containsObject:match.key]) {
                [_shuffledOrderKeys addObject:match.key];
            }
        }
        for (SGRQueueItem *it in working) {
            if (![_shuffledOrderKeys containsObject:it.key]) {
                [_shuffledOrderKeys addObject:it.key];
            }
        }
    } else if (seedLive.count > 0) {
        SGRQueueItem *firstLive = seedLive.firstObject;
        SGRQueueItem *match = poolByKey[firstLive.key] ?: poolByURI[firstLive.uri];
        if (match && ![_shuffledOrderKeys.firstObject isEqualToString:match.key]) {
            [_shuffledOrderKeys removeObject:match.key];
            [_shuffledOrderKeys insertObject:match.key atIndex:0];
        }
    }

    NSMutableSet<NSString *> *used = [NSMutableSet setWithCapacity:pool.count];
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

#pragma mark - spclient Context & Extended Metadata Resolution

static NSString *SGRNormalizedContextURIForResolve(NSString *contextURI) {
    if ([contextURI hasPrefix:@"spotify:user:"]) {
        NSRange r = [contextURI rangeOfString:@":playlist:"];
        if (r.location != NSNotFound) {
            NSString *pid = [contextURI substringFromIndex:r.location + r.length];
            if (pid.length > 0) return [@"spotify:playlist:" stringByAppendingString:pid];
        }
    }
    return contextURI;
}

- (void)ensureResolvedIfNeeded {
    SPTPlayerState *st = SGPlayerState();
    if (st) [self requestUncappedStateForState:st];
    if (!_activeContextURI.length) return;
    if (!_contextEntries) {
        if (!_loadingContextURI) {
            [self resolveContextIfSupported:_activeContextURI triesLeft:3];
        }
        return;
    }
    for (SGRContextTrackEntry *ce in _contextEntries) {
        if (ce.uri.length == 36 && [ce.uri hasPrefix:@"spotify:track:"] &&
            !_metadataCache[ce.uri] && ![_inFlightMetadataURIs containsObject:ce.uri]) {
            [self fetchMissingExtendedMetadataForEntries:_contextEntries contextURI:_activeContextURI triesLeft:3];
            break;
        }
    }
}

- (void)resolveContextIfSupported:(NSString *)contextURI triesLeft:(NSInteger)triesLeft {
    if (!contextURI.length || triesLeft <= 0) return;
    NSString *resolveURI = SGRNormalizedContextURIForResolve(contextURI);
    if (!([resolveURI hasPrefix:@"spotify:album:"] ||
          [resolveURI hasPrefix:@"spotify:playlist:"] ||
          [resolveURI hasPrefix:@"spotify:artist:"] ||
          [resolveURI hasPrefix:@"spotify:collection"])) {
        return;
    }
    if ([_loadingContextURI isEqualToString:contextURI]) return;
    _loadingContextURI = [contextURI copy];

    __weak typeof(self) weakSelf = self;
    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *headers) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf->_activeContextURI isEqualToString:contextURI]) return;
        if (!headers.count) {
            strongSelf->_loadingContextURI = nil;
            if (triesLeft > 1) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) retrySelf = weakSelf;
                    if (retrySelf && [retrySelf->_activeContextURI isEqualToString:contextURI] && !retrySelf->_contextEntries) {
                        [retrySelf resolveContextIfSupported:contextURI triesLeft:triesLeft - 1];
                    }
                });
            }
            return;
        }

        NSMutableArray<SGRContextTrackEntry *> *collected = [NSMutableArray array];
        __block NSString *resolvedDesc = nil;
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
                    NSDictionary *topMeta = [json[@"metadata"] isKindOfClass:NSDictionary.class] ? json[@"metadata"] : nil;
                    if (!resolvedDesc.length) {
                        NSString *cand = [topMeta[@"context_description"] isKindOfClass:NSString.class] ? topMeta[@"context_description"] : nil;
                        if (!cand.length && [topMeta[@"title"] isKindOfClass:NSString.class]) cand = topMeta[@"title"];
                        if (cand.length) resolvedDesc = [cand copy];
                    }
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
                        if (resolvedDesc.length) {
                            s->_resolvedContextTitle = resolvedDesc;
                        }
                        if (collected.count == 0) {
                            if (resolvedDesc.length) [s notifyObservers];
                            if (triesLeft > 1) {
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                    __strong typeof(weakSelf) retrySelf = weakSelf;
                                    if (retrySelf && [retrySelf->_activeContextURI isEqualToString:contextURI] && !retrySelf->_contextEntries) {
                                        [retrySelf resolveContextIfSupported:contextURI triesLeft:triesLeft - 1];
                                    }
                                });
                            }
                            return;
                        }
                        s->_contextEntries = [collected copy];
                        if (!s->_historyClearedByUser && !s->_historySeededFromContext && !s->_isShuffling &&
                            s->_nowPlayingItem && [s->_nowPlayingItem.uri isEqualToString:s->_initialSeedTrackURI]) {
                            [s seedInitialHistoryFromState:(s->_uncappedState ?: SGPlayerState())];
                        }
                        [s rebuildContinuePlayingWithState:SGPlayerState() shuffleJustTurnedOn:NO];
                        [s notifyObservers];
                        [s fetchMissingExtendedMetadataForEntries:collected contextURI:contextURI triesLeft:3];
                    });
                }
            }] resume];
        };
        fetchPage([@"https://spclient.wg.spotify.com/context-resolve/v1/" stringByAppendingString:resolveURI]);
    });
}

- (void)fetchMissingExtendedMetadataForEntries:(NSArray<SGRContextTrackEntry *> *)entries
                                    contextURI:(NSString *)contextURI
                                     triesLeft:(NSInteger)triesLeft {
    if (triesLeft <= 0 || !entries.count) return;
    __weak typeof(self) weakSelf = self;
    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *headers) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!headers.count) {
            if (triesLeft > 1) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) retrySelf = weakSelf;
                    if (retrySelf) {
                        [retrySelf fetchMissingExtendedMetadataForEntries:entries contextURI:contextURI triesLeft:triesLeft - 1];
                    }
                });
            }
            return;
        }

        NSMutableArray<NSString *> *needed = [NSMutableArray array];
        for (SGRContextTrackEntry *ce in entries) {
            if (ce.uri.length == 36 && [ce.uri hasPrefix:@"spotify:track:"] &&
                !strongSelf->_metadataCache[ce.uri] && ![strongSelf->_inFlightMetadataURIs containsObject:ce.uri]) {
                [strongSelf->_inFlightMetadataURIs addObject:ce.uri];
                [needed addObject:ce.uri];
            }
        }
        if (needed.count == 0) return;

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
                        for (SGRQueueItem *q in s->_userQueuedItems) [s enrichQueueItem:q];
                        for (SGRQueueItem *oq in s->_optimisticUserQueuedItems) [s enrichQueueItem:oq];
                        if (s->_nowPlayingItem) [s enrichQueueItem:s->_nowPlayingItem];
                        if ([s->_activeContextURI isEqualToString:contextURI]) {
                            [s rebuildContinuePlayingWithState:SGPlayerState() shuffleJustTurnedOn:NO];
                        }
                        [s notifyObservers];
                    } else if (triesLeft > 1) {
                        NSMutableArray<SGRContextTrackEntry *> *retryChunkEntries = [NSMutableArray arrayWithCapacity:chunk.count];
                        for (NSString *u in chunk) {
                            SGRContextTrackEntry *ce = [[SGRContextTrackEntry alloc] init];
                            ce.uri = u;
                            [retryChunkEntries addObject:ce];
                        }
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            __strong typeof(weakSelf) retrySelf = weakSelf;
                            if (retrySelf) {
                                [retrySelf fetchMissingExtendedMetadataForEntries:retryChunkEntries contextURI:contextURI triesLeft:triesLeft - 1];
                            }
                        });
                    }
                });
            }] resume];
        }
    });
}

@end

// ============================================================================
// Explicit "E" Badge & Apple Music Overlapping Two-Circles AutoMix/Transitions Icon
// ============================================================================

static UIImage *SGRRenderExplicitBadgeImage(CGFloat side, CGFloat cornerRadius, CGFloat fillAlpha) {
    CGSize size = CGSizeMake(side, side);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.0, 0.0, side, side) cornerRadius:cornerRadius];
        [[UIColor colorWithWhite:1.0 alpha:fillAlpha] setFill];
        [bg fill];

        // Vector "E" knockout calibrated 1:1 to Apple Music's 37x37 px (12.33 pt) Explicit badge:
        // Spine = 4 px (1.33 pt), 3 bars = 3 px (1.00 pt) each, counters = 4 px & 5 px tall, rounded terminals.
        CGFloat s = side / 12.3333;
        CGFloat r = 0.28 * s;
        CGContextSetBlendMode(ctx.CGContext, kCGBlendModeDestinationOut);
        [[UIColor blackColor] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4.00 * s, 3.17 * s, 1.3333 * s, 6.00 * s) cornerRadius:r] fill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4.00 * s, 3.17 * s, 4.3333 * s, 1.00 * s) cornerRadius:r] fill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4.00 * s, 5.67 * s, 4.0000 * s, 1.00 * s) cornerRadius:r] fill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4.00 * s, 8.17 * s, 4.3333 * s, 1.00 * s) cornerRadius:r] fill];
    }];
}

static UIImage *SGRExplicitBadgeImageNP(void) {
    static UIImage *badge = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ badge = SGRRenderExplicitBadgeImage(12.33, 2.67, 0.58); });
    return badge;
}

static UIImage *SGRExplicitBadgeImageRow(void) {
    static UIImage *badge = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ badge = SGRRenderExplicitBadgeImage(12.0, 2.50, 0.56); });
    return badge;
}

// Draws Apple Music's exact overlapping two-circles AutoMix/Transitions glyph into the current context,
// centered at `center`. Measured 1:1 from Apple Music: total width 21.3 pt, height 12.7 pt, right hole 4.0 pt.
static void SGRDrawTransitionsOverlappingCircles(CGContextRef cg, CGPoint center, BOOL active) {
    CGFloat leftX = center.x - 4.3;
    CGFloat rightX = center.x + 5.0;
    CGFloat leftR = 5.8;
    CGFloat rightOuterR = 6.2;
    CGFloat rightInnerR = 2.0;

    if (active) {
        // Render glyph in transparency layer then knock out of capsule so center hole is preserved
        CGContextSaveGState(cg);
        CGContextSetBlendMode(cg, kCGBlendModeDestinationOut);
        CGContextBeginTransparencyLayer(cg, NULL);

        // 1. Left circle ring at 44% knockout so it renders coral-pink while the right donut is deep crimson
        UIBezierPath *leftRing = [UIBezierPath bezierPathWithArcCenter:CGPointMake(leftX, center.y)
                                                                radius:leftR
                                                            startAngle:0
                                                              endAngle:(CGFloat)(M_PI * 2.0)
                                                             clockwise:YES];
        leftRing.lineWidth = 1.55;
        [[UIColor colorWithWhite:0.0 alpha:0.44] setStroke];
        [leftRing stroke];

        // 2. Cut out where right donut overlaps the left ring
        CGContextSetBlendMode(cg, kCGBlendModeClear);
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
        [rightDonut fill];

        // 3. Right donut at 100% knockout with center hole intact
        CGContextSetBlendMode(cg, kCGBlendModeNormal);
        [[UIColor colorWithWhite:0.0 alpha:1.0] setFill];
        [rightDonut fill];

        CGContextEndTransparencyLayer(cg);
        CGContextRestoreGState(cg);
    } else {
        // Inactive / grayed-out: solid white right donut and 55% white left ring matching Apple Music exactly
        CGContextSaveGState(cg);
        CGContextBeginTransparencyLayer(cg, NULL);

        UIBezierPath *leftRing = [UIBezierPath bezierPathWithArcCenter:CGPointMake(leftX, center.y)
                                                                radius:leftR
                                                            startAngle:0
                                                              endAngle:(CGFloat)(M_PI * 2.0)
                                                             clockwise:YES];
        leftRing.lineWidth = 1.5;
        [[UIColor colorWithWhite:1.0 alpha:0.55] setStroke];
        [leftRing stroke];

        CGContextSetBlendMode(cg, kCGBlendModeClear);
        UIBezierPath *occluder = [UIBezierPath bezierPathWithArcCenter:CGPointMake(rightX, center.y)
                                                                radius:rightOuterR
                                                            startAngle:0
                                                              endAngle:(CGFloat)(M_PI * 2.0)
                                                             clockwise:YES];
        [occluder fill];

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
        [[UIColor colorWithWhite:1.0 alpha:1.0] setFill];
        [rightDonut fill];

        CGContextEndTransparencyLayer(cg);
        CGContextRestoreGState(cg);
    }
}

static UIImage *SGRRenderPillCapsuleImage(CGSize size, BOOL active, NSString *symbolName, BOOL isTransitionsGlyph) {
    if (size.width < 10.0 || size.height < 10.0) size = CGSizeMake(72.5, 38.0);
    static NSCache<NSString *, UIImage *> *pillCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pillCache = [[NSCache alloc] init];
        pillCache.countLimit = 64;
    });
    NSString *cacheKey = [NSString stringWithFormat:@"%.1fx%.1f|%d|%@|%d", size.width, size.height, active ? 1 : 0, symbolName ?: @"", isTransitionsGlyph ? 1 : 0];
    UIImage *cached = [pillCache objectForKey:cacheKey];
    if (cached) return cached;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    UIImage *rendered = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef cg = ctx.CGContext;
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        UIBezierPath *capsule = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:size.height * 0.5];

        // Active:   rgba(255, 255, 255, 0.72) over backdrop blur
        // Inactive: rgba(255, 255, 255, 0.12)
        UIColor *fill = active ? [UIColor colorWithWhite:1.0 alpha:0.72] : [UIColor colorWithWhite:1.0 alpha:0.12];
        [fill setFill];
        [capsule fill];

        CGPoint center = CGPointMake(size.width * 0.5, size.height * 0.5);

        if (isTransitionsGlyph) {
            SGRDrawTransitionsOverlappingCircles(cg, center, active);
        } else if (symbolName.length) {
            CGFloat ptSize = [symbolName isEqualToString:@"infinity"] ? 16.0 : 15.8;
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:ptSize weight:UIImageSymbolWeightSemibold];
            if (active) {
                // Render symbol masked out via DestinationOut knockout
                UIImage *sym = [[UIImage systemImageNamed:symbolName withConfiguration:cfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
                if (sym) {
                    CGRect symRect = CGRectMake(center.x - sym.size.width * 0.5,
                                                center.y - sym.size.height * 0.5,
                                                sym.size.width,
                                                sym.size.height);
                    CGContextSetBlendMode(cg, kCGBlendModeDestinationOut);
                    [[UIColor colorWithWhite:0.0 alpha:1.0] setFill];
                    [sym drawInRect:symRect];
                }
            } else {
                // Inactive / grayed out icon: crisp opaque white (rgba(255, 255, 255, 1.0)) matching Apple Music exactly
                UIImage *sym = [[UIImage systemImageNamed:symbolName withConfiguration:cfg] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
                if (sym) {
                    CGRect symRect = CGRectMake(center.x - sym.size.width * 0.5,
                                                center.y - sym.size.height * 0.5,
                                                sym.size.width,
                                                sym.size.height);
                    [sym drawInRect:symRect];
                }
            }
        }
    }];
    if (rendered) [pillCache setObject:rendered forKey:cacheKey];
    return rendered;
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
@property (nonatomic, assign) BOOL isUserQueue;
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

    _artView = [[UIImageView alloc] initWithFrame:CGRectMake(kSideMargin, 4.0, 48.0, 48.0)];
    _artView.contentMode = UIViewContentModeScaleAspectFill;
    _artView.clipsToBounds = YES;
    _artView.layer.cornerRadius = 7.0;
    _artView.layer.cornerCurve = kCACornerCurveContinuous;
    _artView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    [_rowContentView addSubview:_artView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = SGRQueueFont(16.5, UIFontWeightRegular);
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_rowContentView addSubview:_titleLabel];

    _explicitView = [[UIImageView alloc] initWithImage:SGRExplicitBadgeImageRow()];
    _explicitView.contentMode = UIViewContentModeScaleAspectFit;
    _explicitView.hidden = YES;
    _explicitView.layer.compositingFilter = @"plusL";
    [_rowContentView addSubview:_explicitView];

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.font = SGRQueueFont(13.8, UIFontWeightRegular);
    _subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    _subtitleLabel.layer.compositingFilter = @"plusL";
    _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_rowContentView addSubview:_subtitleLabel];

    _handleHitView = [[UIView alloc] initWithFrame:CGRectZero];
    _handleHitView.backgroundColor = UIColor.clearColor;
    [_rowContentView addSubview:_handleHitView];

    static CGPathRef sharedBarsPath;
    static dispatch_once_t barsOnce;
    dispatch_once(&barsOnce, ^{
        // Apple Music 3-bar grab handle: 21.5 pt wide, 1.67 pt (5 px) bar thickness, 4.67 pt (14 px) center-to-center pitch -> 11.0 pt height
        CGFloat barLeft = 15.3, barW = 21.5, barH = 5.0 / 3.0, barPitch = 14.0 / 3.0;
        CGFloat barTop = 18.33;
        UIBezierPath *bars = [UIBezierPath bezierPath];
        for (int i = 0; i < 3; i++) {
            CGRect r = CGRectMake(barLeft, barTop + i * barPitch, barW, barH);
            [bars appendPath:[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:barH * 0.5]];
        }
        sharedBarsPath = CGPathRetain(bars.CGPath);
    });
    _handleBarsLayer = [CAShapeLayer layer];
    _handleBarsLayer.fillColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    _handleBarsLayer.compositingFilter = @"plusL";
    _handleBarsLayer.path = sharedBarsPath;
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

    self.isAccessibilityElement = YES;
    NSString *trackTitle = item.title.length ? item.title : @"Unknown Track";
    NSString *trackArtist = item.artist.length ? [NSString stringWithFormat:@", by %@", item.artist] : @"";
    NSString *explicitTag = item.isExplicit ? @", Explicit" : @"";
    self.accessibilityLabel = [NSString stringWithFormat:@"%@%@%@", trackTitle, trackArtist, explicitTag];
    self.accessibilityHint = isHistory ? @"Plays track from history" : @"Plays track. Swipe left to delete or drag handle to reorder.";
    self.accessibilityTraits = UIAccessibilityTraitButton;

    NSURL *artURL = item.artworkURL;
    NSString *urlKey = artURL.absoluteString ?: @"";
    if (urlKey.length) {
        if (![urlKey isEqualToString:_loadedArtURL] || !_artView.image) {
            _loadedArtURL = [urlKey copy];
            UIImage *cached = [SGRQueueImageCache() objectForKey:urlKey];
            if (cached) {
                _artView.image = cached;
            } else {
                _artView.image = nil;
                NSString *expected = _loadedArtURL;
                __weak typeof(self) weakSelf = self;
                SGRLoadQueueArtwork(artURL, ^(UIImage *image) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf || ![strongSelf->_loadedArtURL isEqualToString:expected]) return;
                    if (image) strongSelf->_artView.image = image;
                });
            }
        }
    } else {
        _loadedArtURL = nil;
        if ([item.uri isEqualToString:[SGRQueueSession shared].nowPlayingItem.uri]) {
            _artView.image = SGRNowPlayingArtwork(NULL, NULL);
        } else {
            _artView.image = nil;
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

    CGFloat artY = 0.0;
    _artView.frame = CGRectMake(kSideMargin, artY, 48.0, 48.0);

    // 3-line handle aligned to right margin (x = 333.0..354.33 pt, 35.67 pt inset from right edge of 390 pt screen)
    CGFloat barW = 22.0;
    CGFloat handleTouchW = 52.0;
    _handleHitView.frame = CGRectMake(w - 35.33 - barW - 15.0, 0, handleTouchW, 48.0);

    CGFloat textLeft = kSideMargin + 48.0 + 12.0; // 92.0 pt (glyph leading at 93.0 pt)
    CGFloat maxRight = _showsHandle ? (w - 36.0 - barW - 21.0) : (w - kSideMargin); // 311.0 pt matching Apple Music
    CGFloat availW = MAX(40.0, maxRight - textLeft);

    BOOL hasExp = !_explicitView.hidden;
    BOOL hasSub = (_subtitleLabel.text.length > 0);
    CGFloat badgeGap = 6.5;
    CGFloat badgeW = hasExp ? (12.0 + badgeGap) : 0.0;
    CGSize naturalTitle = [_titleLabel sizeThatFits:CGSizeMake(availW - badgeW, 22.0)];
    CGFloat titleW = MIN(availW - badgeW, ceil(naturalTitle.width));

    CGFloat rowTitleY = hasSub ? (_isHistory ? 4.5 : 5.5) : 13.0;
    _titleLabel.frame = CGRectMake(textLeft, rowTitleY, titleW, 22.0);
    if (hasExp) {
        _explicitView.frame = CGRectMake(textLeft + titleW + badgeGap, rowTitleY + 4.8, 12.0, 12.0);
    }
    _subtitleLabel.frame = CGRectMake(textLeft, (_isHistory ? 26.8 : 27.8), availW, 18.0);

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

    UIColor *activeRed = [UIColor colorWithRed:240.0/255.0 green:56.0/255.0 blue:80.0/255.0 alpha:1.0];
    if (_committedFullSwipe || absOffset > 82.0) {
        CGFloat extra = _committedFullSwipe ? 1.0 : MIN(1.0, (absOffset - 80.0) / 140.0);
        CGFloat capRight = _committedFullSwipe ? (w - 10.0) : ((w - 11.0) + 2.0 * extra);
        CGFloat capLeft  = _committedFullSwipe ? 12.0 : MAX(12.0, capRight - MAX(59.0, absOffset - 14.0));
        CGFloat capW = MAX(59.0, capRight - capLeft);
        CGFloat capH = _committedFullSwipe ? 46.5 : (46.0 + 1.0 * extra);
        _deleteCapsuleView.frame = CGRectMake(capLeft, (self.bounds.size.height - capH) * 0.5, capW, capH);
        _deleteCapsuleView.layer.cornerRadius = capH * 0.5;
        _deleteCapsuleView.alpha = 1.0;
        _deleteCapsuleView.backgroundColor = activeRed;
        _deleteCapsuleRim.frame = CGRectMake(0, capH - 2.0, capW, 2.0);
        _minusDiscView.center = CGPointMake(_committedFullSwipe ? 25.0 : capW * 0.5, capH * 0.5);
        _minusDiscView.transform = CGAffineTransformIdentity;
        return;
    }

    CGFloat t = MIN(1.0, MAX(0.0, (absOffset - 10.0) / 70.0));
    CGFloat eased = 1.0 - (1.0 - t) * (1.0 - t);
    CGFloat capW = 16.0 + 43.0 * eased;
    CGFloat capH = 16.0 + 30.0 * eased;
    _deleteCapsuleView.frame = CGRectMake((w - 40.5) - capW * 0.5, (self.bounds.size.height - capH) * 0.5, capW, capH);
    _deleteCapsuleView.layer.cornerRadius = capH * 0.5;
    _deleteCapsuleView.alpha = MIN(1.0, t * 1.35);
    _deleteCapsuleView.backgroundColor = [UIColor colorWithRed:(140.0 + 100.0 * eased) / 255.0
                                                         green:(24.0 + 32.0 * eased) / 255.0
                                                          blue:(40.0 + 40.0 * eased) / 255.0
                                                         alpha:1.0];
    _deleteCapsuleRim.frame = CGRectMake(0, capH - 2.0, capW, 2.0);
    _minusDiscView.center = CGPointMake(capW * 0.5, capH * 0.5);
    CGFloat discScale = 0.4 + 0.6 * eased;
    _minusDiscView.transform = CGAffineTransformMakeScale(discScale, discScale);
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
    SGMarqueeLabel *_npTitleLabel;
    SGMarqueeLabel *_npArtistLabel;
    UIButton *_npStarButton;
    UIButton *_npMoreButton;

    // 4-Pill Playback Mode Bar (Pinned at top of viewport when scrolling)
    UIView *_pillsBarView;
    UIButton *_pillButtons[4];

    // Section 2A: User Queue ("Queue" + "Clear", manually queued rows, and "+ Add Songs to Queue")
    UIView *_userQueueHeaderView;
    UILabel *_userQueueTitleLabel;
    UIButton *_userQueueClearButton;
    UIView *_userQueueRowsClipView;
    UIView *_userQueueRowsContainerView;
    UIControl *_addSongsRowControl;
    UIView *_addSongsPlusBox;
    UIImageView *_addSongsPlusIcon;
    UILabel *_addSongsLabel;
    NSMutableArray<SGRQueueRowView *> *_userQueueRowViews;
    NSMutableDictionary<NSString *, SGRQueueRowView *> *_userQueueRowsByKey;

    // Unified Clear Confirmation Prompt Overlay ("Are you sure you want to clear your queue/history?")
    UIControl *_clearPromptOverlay;
    CAShapeLayer *_clearPromptDimLayer;
    UIView *_clearPromptCard;
    UIVisualEffectView *_clearPromptGlass;
    UILabel *_clearPromptTitleLabel;
    UIControl *_clearPromptCancelControl;
    UIControl *_clearPromptConfirmControl;
    UILabel *_clearPromptConfirmLabel;
    BOOL _clearPromptIsForHistory;

    // Section 2B: Continue Playing Sticky Header & Rows
    UIView *_continueHeaderView;
    UILabel *_continueTitleLabel;
    UILabel *_continueSubtitleLabel;
    UILabel *_emptyQueuePromptLabel;

    UIView *_queueRowsClipView;
    UIView *_queueRowsContainerView;
    NSMutableArray<SGRQueueRowView *> *_queueRowViews;
    NSMutableDictionary<NSString *, SGRQueueRowView *> *_queueRowsByKey;

    // Displayed Items
    SGRQueueItem *_currentItem;
    NSMutableArray<SGRQueueItem *> *_historyItems;
    NSMutableArray<SGRQueueItem *> *_userQueueItems;
    NSMutableArray<SGRQueueItem *> *_futureItems;
    NSString *_loadedNPArtURL;
    NSString *_lastNPTitleKey;
    NSString *_lastNPArtistKey;
    NSString *_lastStateFingerprint;
    BOOL _lastRenderedShuffling;
    BOOL _transitionArtHidden;

    // Cached Pill Render Size & Refresh Timer
    CGSize _lastPillRenderSize;
    NSTimer *_pillRefreshTimer;

    // Scroll Detent State (scrollY = 0 pt anchor, steady contentInset.top = histH with zero mid-drag mutation)
    CGFloat _dragStartOffsetY;
    BOOL _clampAtZeroOnDragOrDecel;
    BOOL _didSetInitialOffset;
    CGFloat _pendingScrollOffset;
    BOOL _hasPendingScrollOffset;

    // Drag-to-Reorder & Row Delete State
    SGRQueueRowView *_draggingRow;
    UIView *_dragSnapshotView;
    NSInteger _dragCurrentIndex;
    CGFloat _dragGrabOffsetY;
    BOOL _isAnimatingRowDelete;
    BOOL _landscapeMode;
}

@synthesize landscapeMode = _landscapeMode;

+ (void)startSessionIfNeeded {
    [SGRQueueSession shared];
}

- (void)setLandscapeMode:(BOOL)landscapeMode {
    if (_landscapeMode == landscapeMode) return;
    _landscapeMode = landscapeMode;
    _lastPillRenderSize = CGSizeZero;
    if (_didSetInitialOffset && _scrollView) {
        [self applyHistoryInsetPreservingOffset];
    }
    [self updateNowPlayingCardWithItem:_currentItem subtitle:[SGRQueueSession shared].contextSubtitle];
    [self setNeedsLayout];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;

    [SGRQueueSession shared];

    _historyItems = [NSMutableArray array];
    _userQueueItems = [NSMutableArray array];
    _futureItems = [NSMutableArray array];
    _historyRowViews = [NSMutableArray array];
    _historyRowsByKey = [NSMutableDictionary dictionary];
    _userQueueRowViews = [NSMutableArray array];
    _userQueueRowsByKey = [NSMutableDictionary dictionary];
    _queueRowViews = [NSMutableArray array];
    _queueRowsByKey = [NSMutableDictionary dictionary];

    [self buildViewHierarchy];
    SGAddPlayerStateObserver(self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleNowPlayingArtworkChanged:) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleSessionUpdated:) name:SGRQueueSessionDidUpdateNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handlePillsChanged:) name:SGRQueuePillsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateNowPlayingSaveStateOnly) name:SGRPlayerCoverAccentDidChangeNotification object:nil];
    [self syncFromSessionAnimatedReorder:NO forceRebuild:YES];
    return self;
}

- (void)dealloc {
    [self stopPillRefreshTimer];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // Let touches in the top grabber band (y < kViewportTopOffset) pass through to Spotify's sheet dismiss pan.
    return (hit == self) ? nil : hit;
}

- (void)updatePillTimerForVisibility {
    if (self.window && !self.hidden && self.alpha > 0.01) {
        [self startPillRefreshTimer];
    } else {
        [self stopPillRefreshTimer];
    }
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self updatePillTimerForVisibility];
}

- (void)setAlpha:(CGFloat)alpha {
    [super setAlpha:alpha];
    [self updatePillTimerForVisibility];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        SGRPlayerMenuWatchProxy(_npMoreButton);
    }
    [self updatePillTimerForVisibility];
}

- (void)startPillRefreshTimer {
    if (_pillRefreshTimer) return;
    __weak typeof(self) weakSelf = self;
    _pillRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.hidden || strongSelf.alpha < 0.01 || !strongSelf.window) {
            [strongSelf stopPillRefreshTimer];
            return;
        }
        [strongSelf updatePlaybackPillsWithState:SGPlayerState()];
    }];
}

- (void)stopPillRefreshTimer {
    [_pillRefreshTimer invalidate];
    _pillRefreshTimer = nil;
}

- (void)handlePillsChanged:(__unused NSNotification *)note {
    _lastPillRenderSize = CGSizeZero;
    [self setNeedsLayout];
    [self updatePlaybackPillsWithState:SGPlayerState()];
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
    _grabberPill.layer.compositingFilter = @"plusL";
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

    _historyTitleLabel = [self createSectionTitleLabelWithText:@"History"];
    [_historyHeaderView addSubview:_historyTitleLabel];

    _historyClearButton = [self createSectionClearButtonWithAction:@selector(handleClearHistoryTap)];
    _historyClearButton.accessibilityLabel = @"Clear History";
    [_historyHeaderView addSubview:_historyClearButton];

    // 4. Section 1: Now Playing Card inside top-clipped plane (never peeks above pinned bar)
    _nowPlayingClipView = [[UIView alloc] initWithFrame:CGRectZero];
    _nowPlayingClipView.clipsToBounds = YES;
    _nowPlayingClipView.backgroundColor = UIColor.clearColor;
    [_scrollView addSubview:_nowPlayingClipView];

    _nowPlayingCard = [[UIView alloc] initWithFrame:CGRectZero];
    _nowPlayingCard.backgroundColor = UIColor.clearColor;
    UIContextMenuInteraction *npCardMenu = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    [_nowPlayingCard addInteraction:npCardMenu];
    [_nowPlayingClipView addSubview:_nowPlayingCard];

    _npArtView = [[UIImageView alloc] initWithFrame:CGRectMake(kSideMargin, 6.0, 72.0, 72.0)];
    _npArtView.contentMode = UIViewContentModeScaleAspectFill;
    _npArtView.clipsToBounds = YES;
    _npArtView.layer.cornerRadius = 11.0;
    _npArtView.layer.cornerCurve = kCACornerCurveContinuous;
    _npArtView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    _npArtView.userInteractionEnabled = YES;
    [_npArtView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleNowPlayingArtTap)]];
    [_nowPlayingCard addSubview:_npArtView];

    _npDetailsView = [[UIView alloc] initWithFrame:CGRectZero];
    _npDetailsView.backgroundColor = UIColor.clearColor;
    [_nowPlayingCard addSubview:_npDetailsView];

    _npTitleLabel = [[SGMarqueeLabel alloc] initWithFrame:CGRectZero];
    _npTitleLabel.font = SGRFont(UIFontTextStyleTitle3, UIFontWeightBold, UIContentSizeCategoryExtraLarge);
    _npTitleLabel.textColor = UIColor.whiteColor;
    [_npDetailsView addSubview:_npTitleLabel];

    _npArtistLabel = [[SGMarqueeLabel alloc] initWithFrame:CGRectZero];
    _npArtistLabel.font = SGRFont(UIFontTextStyleCallout, UIFontWeightRegular, UIContentSizeCategoryExtraLarge);
    _npArtistLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    _npArtistLabel.layer.compositingFilter = @"plusL";
    [_npDetailsView addSubview:_npArtistLabel];

    // Star favorite button matching Apple Music's Now Playing mini-card (center x = 295 pt)
    _npStarButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _npStarButton.backgroundColor = UIColor.clearColor;
    [_npStarButton addTarget:self action:@selector(handleNowPlayingStarTap) forControlEvents:UIControlEventTouchUpInside];
    [_npDetailsView addSubview:_npStarButton];

    // Bare white ellipsis button matching Apple Music's Now Playing mini-card; single-tap opens the full system menu
    _npMoreButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _npMoreButton.backgroundColor = UIColor.clearColor;
    _npMoreButton.accessibilityLabel = @"More options";
    UIImageSymbolConfiguration *moreCfg = [UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightBold];
    [_npMoreButton setImage:[[UIImage systemImageNamed:@"ellipsis" withConfiguration:moreCfg] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
    [_npDetailsView addSubview:_npMoreButton];
    SGRPlayerMenuWatchProxy(_npMoreButton);

    // 5. Section 2A: User Queue ("Queue" + "Clear", manually queued tracks, and "+ Add Songs to Queue")
    _userQueueRowsClipView = [[UIView alloc] initWithFrame:CGRectZero];
    _userQueueRowsClipView.clipsToBounds = YES;
    _userQueueRowsClipView.backgroundColor = UIColor.clearColor;
    _userQueueRowsClipView.hidden = YES;
    [_scrollView addSubview:_userQueueRowsClipView];

    _userQueueRowsContainerView = [[UIView alloc] initWithFrame:CGRectZero];
    _userQueueRowsContainerView.backgroundColor = UIColor.clearColor;
    [_userQueueRowsClipView addSubview:_userQueueRowsContainerView];

    _addSongsRowControl = [[UIControl alloc] initWithFrame:CGRectZero];
    _addSongsRowControl.backgroundColor = UIColor.clearColor;
    _addSongsRowControl.isAccessibilityElement = YES;
    _addSongsRowControl.accessibilityLabel = @"Add Songs to Queue";
    _addSongsRowControl.accessibilityTraits = UIAccessibilityTraitButton;
    [_addSongsRowControl addTarget:self action:@selector(handleAddSongsToQueueTap) forControlEvents:UIControlEventTouchUpInside];
    [_userQueueRowsContainerView addSubview:_addSongsRowControl];

    _addSongsPlusBox = [[UIView alloc] initWithFrame:CGRectMake(kSideMargin, 0.0, 48.0, 48.0)];
    _addSongsPlusBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    _addSongsPlusBox.layer.compositingFilter = @"plusL";
    _addSongsPlusBox.layer.cornerRadius = 7.0;
    _addSongsPlusBox.layer.cornerCurve = kCACornerCurveContinuous;
    _addSongsPlusBox.userInteractionEnabled = NO;
    [_addSongsRowControl addSubview:_addSongsPlusBox];

    UIImageSymbolConfiguration *plusCfg = [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightSemibold];
    UIImage *plusImg = [[UIImage systemImageNamed:@"plus" withConfiguration:plusCfg] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    _addSongsPlusIcon = [[UIImageView alloc] initWithImage:plusImg];
    _addSongsPlusIcon.contentMode = UIViewContentModeCenter;
    _addSongsPlusIcon.frame = _addSongsPlusBox.frame;
    [_addSongsRowControl addSubview:_addSongsPlusIcon];

    _addSongsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _addSongsLabel.attributedText = [[NSAttributedString alloc] initWithString:@"Add Songs to Queue" attributes:@{
        NSFontAttributeName: SGRQueueFont(17.0, UIFontWeightRegular),
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSKernAttributeName: @(-0.35),
    }];
    [_addSongsRowControl addSubview:_addSongsLabel];

    _userQueueHeaderView = [[UIView alloc] initWithFrame:CGRectZero];
    _userQueueHeaderView.backgroundColor = UIColor.clearColor;
    _userQueueHeaderView.hidden = YES;
    [_scrollView addSubview:_userQueueHeaderView];

    _userQueueTitleLabel = [self createSectionTitleLabelWithText:@"Queue"];
    [_userQueueHeaderView addSubview:_userQueueTitleLabel];

    _userQueueClearButton = [self createSectionClearButtonWithAction:@selector(handleClearUserQueueTap)];
    _userQueueClearButton.accessibilityLabel = @"Clear Queue";
    [_userQueueHeaderView addSubview:_userQueueClearButton];

    // 6. Section 2B: Continue Playing Track Rows Clipping Plane & Sticky Continue Playing Header
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

    _pillsBarView = [[UIView alloc] initWithFrame:CGRectZero];
    _pillsBarView.backgroundColor = UIColor.clearColor;
    [_scrollView addSubview:_pillsBarView];

    for (NSUInteger i = 0; i < 4; i++) {
        _pillButtons[i] = [self createPlaybackPillWithSlot:i];
        [_pillsBarView addSubview:_pillButtons[i]];
    }

    _continueTitleLabel = [self createSectionTitleLabelWithText:@"Continue Playing"];
    [_continueHeaderView addSubview:_continueTitleLabel];

    _continueSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _continueSubtitleLabel.font = SGRQueueFont(13.0, UIFontWeightRegular);
    _continueSubtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    _continueSubtitleLabel.layer.compositingFilter = @"plusL";
    _continueSubtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_continueHeaderView addSubview:_continueSubtitleLabel];

    _emptyQueuePromptLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyQueuePromptLabel.numberOfLines = 2;
    _emptyQueuePromptLabel.textAlignment = NSTextAlignmentCenter;
    _emptyQueuePromptLabel.hidden = YES;
    _emptyQueuePromptLabel.layer.compositingFilter = @"plusL";

    UIFont *promptFont = SGRQueueFont(17.0, UIFontWeightRegular);
    UIColor *promptColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    NSMutableAttributedString *promptStr = [[NSMutableAttributedString alloc] initWithString:@"To keep music playing, turn on\n"
                                                                                  attributes:@{NSFontAttributeName: promptFont, NSForegroundColorAttributeName: promptColor}];
    UIImageSymbolConfiguration *infCfg = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightBold];
    UIImage *infImg = [[UIImage systemImageNamed:@"infinity" withConfiguration:infCfg] imageWithTintColor:promptColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (infImg) {
        NSTextAttachment *att = [[NSTextAttachment alloc] init];
        att.image = infImg;
        att.bounds = CGRectMake(0, -1.0, infImg.size.width, infImg.size.height);
        [promptStr appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
    }
    [promptStr appendAttributedString:[[NSAttributedString alloc] initWithString:@" AutoPlay."
                                                                      attributes:@{NSFontAttributeName: promptFont, NSForegroundColorAttributeName: promptColor}]];
    _emptyQueuePromptLabel.attributedText = promptStr;
    [_scrollView addSubview:_emptyQueuePromptLabel];

    [self updatePlaybackPillsWithState:SGPlayerState()];
}

- (UILabel *)createSectionTitleLabelWithText:(NSString *)text {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: SGRQueueFont(17.0, UIFontWeightBold),
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSKernAttributeName: @(-0.40),
    }];
    return label;
}

- (UIButton *)createSectionClearButtonWithAction:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    [btn setTitle:@"Clear" forState:UIControlStateNormal];
    btn.titleLabel.font = SGRQueueFont(17.0, UIFontWeightRegular);
    [btn setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.65] forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.35] forState:UIControlStateHighlighted];
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    btn.layer.compositingFilter = @"plusL";
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (UIButton *)createPlaybackPillWithSlot:(NSUInteger)slot {
    UIButton *pill = [UIButton buttonWithType:UIButtonTypeCustom];
    pill.tag = (NSInteger)slot;
    pill.backgroundColor = UIColor.clearColor;
    pill.layer.cornerRadius = 19.0;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.clipsToBounds = YES;
    [pill addTarget:self action:@selector(handlePillTap:) forControlEvents:UIControlEventTouchUpInside];
    [pill addTarget:self action:@selector(handlePillTouchDown:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [pill addTarget:self action:@selector(handlePillTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    UIContextMenuInteraction *ctx = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    [pill addInteraction:ctx];
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
    [[SGRQueueSession shared] ensureResolvedIfNeeded];
    _clampAtZeroOnDragOrDecel = NO;
    _pendingScrollOffset = 0.0;
    _hasPendingScrollOffset = YES;
    [self syncFromSessionAnimatedReorder:NO forceRebuild:YES];
    [self setNeedsLayout];
    [self layoutIfNeeded];
    if (self.bounds.size.width >= 100.0 && self.bounds.size.height >= 100.0) {
        _didSetInitialOffset = YES;
        _scrollView.contentInset = UIEdgeInsetsMake([self historyTotalHeight], 0.0, 36.0, 0.0);
        _scrollView.contentOffset = CGPointZero;
        _hasPendingScrollOffset = NO;
        [self updateStickyHeadersAndClipping];
    }
}

- (CGFloat)currentScrollOffset {
    if (_hasPendingScrollOffset) return _pendingScrollOffset;
    if (!_scrollView) return 0.0;
    CGFloat y = _scrollView.contentOffset.y;
    if (y < -2.0 && [self historyTotalHeight] > 0.0) {
        y -= (kHistoryHeaderPinOffset - [self historyHeaderPinOffset]);
    }
    return y;
}

- (void)setCurrentScrollOffset:(CGFloat)currentScrollOffset {
    _pendingScrollOffset = currentScrollOffset;
    _hasPendingScrollOffset = YES;
    if (!_scrollView) return;
    if (self.bounds.size.width < 100.0 || self.bounds.size.height < 100.0 || _scrollView.contentSize.height <= 0.0) {
        return;
    }
    CGFloat histH = [self historyTotalHeight];
    _scrollView.contentInset = UIEdgeInsetsMake(histH, 0.0, 36.0, 0.0);
    CGFloat targetY = currentScrollOffset;
    if (targetY < -2.0 && histH > 0.0) {
        targetY += (kHistoryHeaderPinOffset - [self historyHeaderPinOffset]);
    }
    CGFloat minY = -histH;
    CGFloat maxY = (_scrollView.contentSize.height > 0.0 && _scrollView.bounds.size.height > 0.0)
        ? MAX(0.0, _scrollView.contentSize.height - _scrollView.bounds.size.height + 36.0)
        : MAX(0.0, targetY);
    CGFloat clampedY = MAX(minY, MIN(maxY, targetY));
    _scrollView.contentOffset = CGPointMake(0.0, clampedY);
    _hasPendingScrollOffset = NO;
    [self updateStickyHeadersAndClipping];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    if (!newWindow && _clearPromptOverlay) {
        _clearPromptOverlay.hidden = YES;
        [_clearPromptOverlay removeFromSuperview];
    }
}

- (void)setTransitionArtworkHidden:(BOOL)hidden {
    _transitionArtHidden = hidden;
    _npArtView.alpha = hidden ? 0.0 : 1.0;
    if (hidden && _clearPromptOverlay && !_clearPromptOverlay.hidden) {
        _clearPromptOverlay.hidden = YES;
        [_clearPromptOverlay removeFromSuperview];
    }
}

- (void)setHeaderSlideOffset:(CGFloat)headerOffsetY listSlideOffset:(CGFloat)listOffsetY {
    CGAffineTransform hdrSlide = (fabs(headerOffsetY) < 0.01) ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(0.0, headerOffsetY);
    CGAffineTransform listSlide = (fabs(listOffsetY) < 0.01) ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(0.0, listOffsetY);
    _grabberPill.transform = hdrSlide;
    _npDetailsView.transform = hdrSlide;
    _pillsBarView.transform = listSlide;
    _userQueueHeaderView.transform = listSlide;
    _userQueueRowsClipView.transform = listSlide;
    _continueHeaderView.transform = listSlide;
    _queueRowsClipView.transform = listSlide;
    _emptyQueuePromptLabel.transform = listSlide;
    _historyHeaderView.transform = listSlide;
    _historyRowsClipView.transform = listSlide;
}

- (void)setHeaderOpacity:(CGFloat)headerOpacity {
    _grabberPill.alpha = headerOpacity;
    _npDetailsView.alpha = headerOpacity;
}

- (void)setListOpacity:(CGFloat)listOpacity {
    _pillsBarView.alpha = listOpacity;
    _userQueueHeaderView.alpha = listOpacity;
    _userQueueRowsClipView.alpha = listOpacity;
    _continueHeaderView.alpha = listOpacity;
    _queueRowsClipView.alpha = listOpacity;
    _emptyQueuePromptLabel.alpha = listOpacity;
    _historyHeaderView.alpha = listOpacity;
    _historyRowsClipView.alpha = listOpacity;
}

- (void)setContentSlideOffset:(CGFloat)offsetY opacity:(CGFloat)opacity {
    [self setHeaderSlideOffset:offsetY listSlideOffset:offsetY];
    [self setHeaderOpacity:opacity];
    [self setListOpacity:opacity];
}

- (CGRect)nowPlayingArtworkFrameInView:(UIView *)targetView {
    CGRect localArt = CGRectMake(kSideMargin, kViewportTopOffset + kNowPlayingDocY, 72.0, 72.0);
    return targetView ? [self convertRect:localArt toView:targetView] : localArt;
}

- (CGRect)visibleNowPlayingArtworkFrameInView:(UIView *)targetView {
    if (_npArtView && !_nowPlayingClipView.hidden && _scrollView.contentOffset.y <= 4.0) {
        CGRect rect = [_npArtView convertRect:_npArtView.bounds toView:targetView ?: self];
        if (rect.size.width >= 40.0 && rect.size.height >= 40.0) return rect;
    }
    return [self nowPlayingArtworkFrameInView:targetView];
}

#pragma mark - State Synchronization & Spring Row Reordering

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self updatePlaybackPillsWithState:state];
}

- (void)reloadTracks {
    [[SGRQueueSession shared] ensureResolvedIfNeeded];
    _clampAtZeroOnDragOrDecel = NO;
    _didSetInitialOffset = YES;
    [self syncFromSessionAnimatedReorder:NO forceRebuild:YES];
    _scrollView.contentInset = UIEdgeInsetsMake([self historyTotalHeight], 0.0, 36.0, 0.0);
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
    [self updatePlaybackPillsWithState:state];

    if (!forceRebuild && (_draggingRow || _isAnimatingRowDelete)) return;
    for (SGRQueueRowView *row in _userQueueRowViews) {
        if (!forceRebuild && row.isSwipeParked) return;
    }
    for (SGRQueueRowView *row in _queueRowViews) {
        if (!forceRebuild && row.isSwipeParked) return;
    }

    SGRQueueItem *np = session.nowPlayingItem;
    NSArray<SGRQueueItem *> *hist = session.historyItems;
    NSArray<SGRQueueItem *> *uq   = session.userQueuedItems;
    NSArray<SGRQueueItem *> *next = session.continuePlayingItems;

    NSMutableString *fp = [NSMutableString stringWithFormat:@"NP:%@|%@|H:%lu|Q:%lu|N:%lu|S:%d|",
                           np.uri ?: @"", np.title ?: @"", (unsigned long)hist.count, (unsigned long)uq.count, (unsigned long)next.count, session.isShuffling ? 1 : 0];
    for (NSUInteger i = 0; i < MIN((NSUInteger)20, uq.count); i++) {
        [fp appendFormat:@"Q%@:%@,", uq[i].key, uq[i].title ?: @""];
    }
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
    [_userQueueItems setArray:uq];
    [_futureItems setArray:next];

    [self updateNowPlayingCardWithItem:np subtitle:session.contextSubtitle];
    [self reconcileTrackRowsAnimated:animateReorder];
    [self setNeedsLayout];
    if (!animateReorder) {
        [self layoutIfNeeded];
    }
}

static UIImage *SGRNowPlayingSaveImage(BOOL isSaved) {
    BOOL plain = SGRPlainCheckOn();
    if (plain) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:21.0 weight:UIImageSymbolWeightBold];
        NSString *sym = isSaved ? @"checkmark" : @"plus";
        UIColor *tint = isSaved ? SGRPlayerCurrentAccent() : UIColor.whiteColor;
        return [[UIImage systemImageNamed:sym withConfiguration:cfg] imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
    } else {
        // Point size 22.5 produces exact 52x50px bounds at 2.37 scale matching Apple Music's star
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22.5 weight:UIImageSymbolWeightRegular];
        NSString *sym = isSaved ? @"checkmark.circle.fill" : @"plus.circle";
        UIColor *tint = isSaved ? SGRPlayerCurrentAccent() : UIColor.whiteColor;
        return [[UIImage systemImageNamed:sym withConfiguration:cfg] imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
}

- (void)applyNowPlayingSaveStateForURI:(NSString *)trackURI {
    NSString *uri = trackURI ?: @"";
    BOOL isSaved = [[SGRQueueSession shared] isTrackSaved:uri];
    [_npStarButton setImage:SGRNowPlayingSaveImage(isSaved) forState:UIControlStateNormal];
    _npStarButton.hidden = (uri.length == 0);
    _npStarButton.accessibilityLabel = isSaved ? @"Remove from Your Library" : @"Add to Your Library";
}

- (void)updateNowPlayingSaveStateOnly {
    [self applyNowPlayingSaveStateForURI:[SGRQueueSession shared].nowPlayingItem.uri];
}

- (void)updateNowPlayingCardWithItem:(SGRQueueItem *)item subtitle:(NSString *)subtitle {
    NSString *titleText = item.title.length ? item.title : @"Not Playing";
    UIFont *npTitleFont = SGRFont(UIFontTextStyleTitle3, UIFontWeightBold, UIContentSizeCategoryExtraLarge);
    NSString *titleKey = [NSString stringWithFormat:@"%@|%d|%d", titleText, item.isExplicit ? 1 : 0, _landscapeMode ? 1 : 0];
    if (![_lastNPTitleKey isEqualToString:titleKey]) {
        _lastNPTitleKey = [titleKey copy];
        _npTitleLabel.attributedText = [[NSAttributedString alloc] initWithString:titleText attributes:@{
            NSFontAttributeName: npTitleFont,
            NSForegroundColorAttributeName: UIColor.whiteColor,
            NSKernAttributeName: @(-0.40),
        }];
        _npTitleLabel.trailingBadgeImage = item.isExplicit ? SGRExplicitBadgeImageNP() : nil;
        _npTitleLabel.trailingBadgeGap = 6.33;
    }

    NSString *artistText = item.artist ?: @"";
    if (!artistText.length) {
        NSString *stateArtist = SGPlayerState().track.artistName ?: @"";
        if (stateArtist.length) artistText = stateArtist;
    }
    if (!artistText.length && item.albumURI.length) {
        for (SGRQueueItem *cand in _futureItems) {
            if (cand.artist.length && [cand.albumURI isEqualToString:item.albumURI]) {
                artistText = cand.artist;
                break;
            }
        }
    }
    NSString *artistKey = [NSString stringWithFormat:@"%@|%d", artistText, _landscapeMode ? 1 : 0];
    if (![_lastNPArtistKey isEqualToString:artistKey]) {
        _lastNPArtistKey = [artistKey copy];
        UIFont *npArtistFont = SGRFont(UIFontTextStyleCallout, UIFontWeightRegular, UIContentSizeCategoryExtraLarge);
        CGFloat artistKern = _landscapeMode ? -0.35 : -0.24;
        _npArtistLabel.attributedText = [[NSAttributedString alloc] initWithString:artistText attributes:@{
            NSFontAttributeName: npArtistFont,
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.62],
            NSKernAttributeName: @(artistKern),
        }];
    }
    _continueSubtitleLabel.text = subtitle ?: @"";
    [self applyNowPlayingSaveStateForURI:item.uri];

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

- (void)reconcileStaticSectionItems:(NSArray<SGRQueueItem *> *)items
                          rowsByKey:(NSMutableDictionary<NSString *, SGRQueueRowView *> * __strong *)rowsByKeyPtr
                           rowViews:(NSMutableArray<SGRQueueRowView *> *)rowViews
                          container:(UIView *)container
                          isHistory:(BOOL)isHistory
                        isUserQueue:(BOOL)isUserQueue
                              width:(CGFloat)w {
    NSMutableDictionary<NSString *, SGRQueueRowView *> *oldMap = *rowsByKeyPtr;
    NSMutableDictionary<NSString *, SGRQueueRowView *> *nextMap = [NSMutableDictionary dictionaryWithCapacity:items.count];
    NSMutableArray<SGRQueueRowView *> *nextViews = [NSMutableArray arrayWithCapacity:items.count];
    CGFloat pitch = isHistory ? kHistoryRowPitch : kQueueRowPitch;

    for (NSUInteger i = 0; i < items.count; i++) {
        SGRQueueItem *it = items[i];
        SGRQueueRowView *row = oldMap[it.key];
        CGRect targetFrame = CGRectMake(0.0, i * pitch, w, pitch);
        if (row) {
            [oldMap removeObjectForKey:it.key];
        } else {
            row = [[SGRQueueRowView alloc] initWithFrame:targetFrame];
            row.delegate = self;
            [container addSubview:row];
        }
        row.isUserQueue = isUserQueue;
        [row configureWithItem:it isHistory:isHistory rowIndex:(NSInteger)i];
        row.frame = targetFrame;
        row.alpha = 1.0;
        nextMap[it.key] = row;
        [nextViews addObject:row];
    }
    for (SGRQueueRowView *obsolete in oldMap.allValues) {
        [obsolete removeFromSuperview];
    }
    *rowsByKeyPtr = nextMap;
    [rowViews setArray:nextViews];
}

- (void)reconcileTrackRowsAnimated:(BOOL)animateReorder {
    CGFloat w = MAX(320.0, self.bounds.size.width);

    // 1 & 2A. Reconcile History and User Queue ("Queue") rows via shared helper
    [self reconcileStaticSectionItems:_historyItems
                            rowsByKey:&_historyRowsByKey
                             rowViews:_historyRowViews
                            container:_historyRowsContainerView
                            isHistory:YES
                          isUserQueue:NO
                                width:w];
    [self reconcileStaticSectionItems:_userQueueItems
                            rowsByKey:&_userQueueRowsByKey
                             rowViews:_userQueueRowViews
                            container:_userQueueRowsContainerView
                            isHistory:NO
                          isUserQueue:YES
                                width:w];

    // 2B. Reconcile Continue Playing Rows by key (smooth ~0.35s spring reorder on Shuffle toggle, zero artwork flash)
    NSMutableDictionary<NSString *, SGRQueueRowView *> *nextQueueMap = [NSMutableDictionary dictionaryWithCapacity:_futureItems.count];
    NSMutableArray<SGRQueueRowView *> *nextQueueViews = [NSMutableArray arrayWithCapacity:_futureItems.count];
    NSMutableArray<SGRQueueRowView *> *newlyInserted = [NSMutableArray array];

    for (NSUInteger i = 0; i < _futureItems.count; i++) {
        SGRQueueItem *it = _futureItems[i];
        SGRQueueRowView *row = _queueRowsByKey[it.key];
        CGRect targetFrame = CGRectMake(0.0, i * kQueueRowPitch, w, kQueueRowPitch);
        if (row) {
            [_queueRowsByKey removeObjectForKey:it.key];
            row.isUserQueue = NO;
            [row configureWithItem:it isHistory:NO rowIndex:(NSInteger)i];
            if (!animateReorder) {
                row.frame = targetFrame;
                row.alpha = 1.0;
            }
        } else {
            row = [[SGRQueueRowView alloc] initWithFrame:targetFrame];
            row.delegate = self;
            row.isUserQueue = NO;
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

- (void)placeEmptyQueuePromptForWidth:(CGFloat)w {
    _emptyQueuePromptLabel.bounds = CGRectMake(0.0, 0.0, 280.0, 50.0);
    _emptyQueuePromptLabel.center = CGPointMake(w * 0.5, _landscapeMode ? 185.0 : 230.5);
}

- (CGFloat)historyHeaderPinOffset {
    return _landscapeMode ? 14.0 : kHistoryHeaderPinOffset;
}

- (CGFloat)continueHeaderPinOffset {
    return _landscapeMode ? 0.0 : kContinueHeaderPinOffset;
}

- (CGFloat)continueSectionHeaderHeight {
    return _landscapeMode ? 48.0 : kContinueSectionHeaderHeight;
}

- (CGFloat)historyTotalHeight {
    if (_historyItems.count == 0) return 0.0;
    return [self historyHeaderPinOffset] + kHistoryHeaderHeight + _historyItems.count * kHistoryRowPitch + kHistoryBottomGap;
}

- (void)applyHistoryInsetPreservingOffset {
    CGFloat histH = [self historyTotalHeight];
    UIEdgeInsets targetInset = UIEdgeInsetsMake(histH, 0.0, 36.0, 0.0);
    if (UIEdgeInsetsEqualToEdgeInsets(_scrollView.contentInset, targetInset)) return;
    // Never mutate UIScrollView.contentInset mid-drag or mid-deceleration, which shifts UIKit's pan anchor under the finger.
    if (histH > 0.0 && (_scrollView.isTracking || _scrollView.isDecelerating)) return;

    CGFloat oldTop = _scrollView.contentInset.top;
    CGPoint savedOffset = _scrollView.contentOffset;
    if (histH == 0.0 && savedOffset.y < 0.0) {
        savedOffset.y = 0.0;
    } else if (savedOffset.y < -2.0 && oldTop > 0.0 && histH > 0.0) {
        // A finished track appended at the bottom of History shifts upper History rows by -(histH - oldTop) in docY
        savedOffset.y -= (histH - oldTop);
    }
    _scrollView.contentInset = targetInset;
    _scrollView.contentOffset = savedOffset;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 100.0 || h < 100.0) return;

    _grabberPill.hidden = _landscapeMode;
    _grabberPill.bounds = CGRectMake(0.0, 0.0, kGrabberWidth, kGrabberHeight);
    _grabberPill.center = CGPointMake(w * 0.5, 2.0);

    CGFloat viewportTop = _landscapeMode ? 52.0 : kViewportTopOffset;
    CGFloat viewportBottomInset = _landscapeMode ? 82.0 : 0.0;
    CGFloat viewportH = MAX(100.0, h - viewportTop - viewportBottomInset);
    _viewportClipView.frame = CGRectMake(0.0, viewportTop, w, viewportH);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _bottomFadeMask.frame = _viewportClipView.bounds;
    // Linear ramp matching Apple Music's exact bottom row alpha profile
    CGFloat locStart   = MAX(0.0, MIN(1.0, (viewportH - 68.0) / viewportH));
    CGFloat locRow5Top = MAX(0.0, MIN(1.0, (viewportH - 48.0) / viewportH));
    CGFloat locRow5Mid = MAX(0.0, MIN(1.0, (viewportH - 24.0) / viewportH));
    _bottomFadeMask.locations = @[@0.0, @(locStart), @(locRow5Top), @(locRow5Mid), @1.0];
    _bottomFadeMask.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:1.0].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:1.0].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.67].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.35].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
    ];
    [CATransaction commit];

    CGFloat targetScrollOffset = _hasPendingScrollOffset ? _pendingScrollOffset : [self currentScrollOffset];
    BOOL hadPending = _hasPendingScrollOffset;

    _scrollView.frame = _viewportClipView.bounds;
    _scrollView.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0.0, 0.0, 0.0, _landscapeMode ? 18.0 : 0.0);

    // Section 1: Now Playing Card subviews
    _npArtView.hidden = _landscapeMode;
    _npArtView.frame = CGRectMake(kSideMargin, 0.0, 72.0, 72.0);
    _npDetailsView.bounds = CGRectMake(0.0, 0.0, w, 72.0);
    _npDetailsView.center = CGPointMake(w * 0.5, 36.0);
    CGFloat moreW = 28.0;
    CGFloat starW = 26.0;
    CGFloat moreCenterX = _landscapeMode ? (w - kSideMargin - 17.0) : round(w * (341.5 / 390.0));
    CGFloat starCenterX = _landscapeMode ? (w - kSideMargin - 64.67) : round(w * (294.0 / 390.0));
    CGFloat npBtnCenterY = _landscapeMode ? 22.83 : 36.0;
    _npMoreButton.bounds = CGRectMake(0.0, 0.0, moreW, moreW);
    _npMoreButton.center = CGPointMake(moreCenterX, npBtnCenterY);
    _npStarButton.bounds = CGRectMake(0.0, 0.0, starW, starW);
    _npStarButton.center = CGPointMake(starCenterX, npBtnCenterY);

    CGFloat npTextLeft = _landscapeMode ? kSideMargin : (kSideMargin + 72.0 + 12.0);
    CGFloat npMaxRight = (starCenterX - starW * 0.5) - 7.0;
    CGFloat npAvailW = MAX(40.0, npMaxRight - npTextLeft);
    CGFloat titleY = _landscapeMode ? 1.2 : 17.2;
    CGFloat titleH = _landscapeMode ? 23.0 : 21.0;
    _npTitleLabel.frame = CGRectMake(npTextLeft, titleY, npAvailW, titleH);
    _npArtistLabel.frame = CGRectMake(npTextLeft, _landscapeMode ? 25.0 : 36.3, npAvailW, _landscapeMode ? 21.0 : 19.0);

    // Section 2 Header subviews: configurable pills (height = 38, cornerRadius = 19, x = 32 .. w - 32) + Continue Playing title & subtitle
    NSArray<NSNumber *> *activeSlots = [self activePillSlots];
    NSUInteger numPills = activeSlots.count;
    for (NSUInteger i = 0; i < 4; i++) {
        _pillButtons[i].hidden = YES;
    }
    CGFloat pillW = _landscapeMode ? 83.0 : 72.5;
    if (numPills > 0) {
        CGFloat pillGap = 12.0;
        pillW = floor(((w - kSideMargin * 2.0 - pillGap * (numPills - 1)) / (CGFloat)numPills) * 4.0) * 0.25;
        for (NSUInteger idx = 0; idx < numPills; idx++) {
            NSUInteger slot = [activeSlots[idx] unsignedIntegerValue];
            UIButton *p = _pillButtons[slot];
            p.hidden = NO;
            p.bounds = CGRectMake(0.0, 0.0, pillW, 38.0);
            p.center = CGPointMake(kSideMargin + idx * (pillW + pillGap) + pillW * 0.5, 19.0);
        }
    }
    CGSize pillSize = CGSizeMake(pillW, 38.0);
    if (!CGSizeEqualToSize(pillSize, _lastPillRenderSize)) {
        _lastPillRenderSize = pillSize;
        [self updatePlaybackPillsWithState:SGPlayerState()];
    }

    BOOL hasUserQueue = (_userQueueItems.count > 0);
    BOOL hasContinue  = (_futureItems.count > 0);
    BOOL queueEmpty   = (!hasUserQueue && !hasContinue && !SGFlag(SGRKeyQueueAutoplay, YES));
    _emptyQueuePromptLabel.hidden = !queueEmpty;
    _userQueueHeaderView.hidden   = !hasUserQueue;
    _userQueueRowsClipView.hidden = !hasUserQueue;
    _continueHeaderView.hidden    = (!hasContinue || queueEmpty);
    _queueRowsClipView.hidden     = !hasContinue;
    _continueTitleLabel.hidden    = (!hasContinue || queueEmpty);
    _continueSubtitleLabel.hidden = (!hasContinue || queueEmpty);

    if (queueEmpty) {
        [self placeEmptyQueuePromptForWidth:w];
    }

    // Section 2A ("Queue" + "Clear") header subviews:
    _userQueueTitleLabel.frame = CGRectMake(kSideMargin, 3.0, 140.0, 22.0);
    _userQueueClearButton.frame = CGRectMake(w - kSideMargin - 52.0, -1.33, 52.0, 30.0);
    _userQueueClearButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;

    // Section 2B ("Continue Playing" + "From ...") header subviews:
    _continueTitleLabel.frame = CGRectMake(kSideMargin, 0.0, w - kSideMargin * 2.0, 21.0);
    _continueSubtitleLabel.frame = CGRectMake(kSideMargin, 20.5, w - kSideMargin * 2.0, 17.0);

    // Section 0 Header subviews: "History" + "Clear" matching "Queue" + "Clear" (x = 32 .. w - 32)
    _historyTitleLabel.frame = CGRectMake(kSideMargin, 3.0, 140.0, 22.0);
    _historyClearButton.frame = CGRectMake(w - kSideMargin - 52.0, -1.33, 52.0, 30.0);

    for (NSUInteger i = 0; i < _historyRowViews.count; i++) {
        SGRQueueRowView *row = _historyRowViews[i];
        row.frame = CGRectMake(0.0, i * kHistoryRowPitch, w, kHistoryRowPitch);
    }
    for (NSUInteger i = 0; i < _userQueueRowViews.count; i++) {
        SGRQueueRowView *row = _userQueueRowViews[i];
        if (row == _draggingRow) continue;
        row.frame = CGRectMake(0.0, i * kQueueRowPitch, w, kQueueRowPitch);
    }
    if (hasUserQueue) {
        CGFloat addRowY = _userQueueRowViews.count * kQueueRowPitch;
        _addSongsRowControl.frame = CGRectMake(0.0, addRowY, w, kAddSongsRowHeight);
        _addSongsPlusBox.frame = CGRectMake(kSideMargin, 0.0, 48.0, 48.0);
        _addSongsPlusIcon.frame = _addSongsPlusBox.frame;
        CGFloat addTextLeft = kSideMargin + 48.0 + 12.0;
        _addSongsLabel.frame = CGRectMake(addTextLeft, 13.33, w - addTextLeft - kSideMargin, 22.0);
    }
    for (NSUInteger i = 0; i < _queueRowViews.count; i++) {
        SGRQueueRowView *row = _queueRowViews[i];
        if (row == _draggingRow) continue;
        row.frame = CGRectMake(0.0, i * kQueueRowPitch, w, kQueueRowPitch);
    }

    CGFloat totalBottom = 0.0;
    if (hasContinue) {
        totalBottom = [self continueRowsStartDocY] + MAX((NSUInteger)1, _queueRowViews.count) * kQueueRowPitch + 24.0;
    } else if (hasUserQueue) {
        totalBottom = [self userQueueRowsStartDocY] + _userQueueRowViews.count * kQueueRowPitch + 48.0 + 24.0;
    } else {
        totalBottom = [self continueRowsStartDocY] + kQueueRowPitch + 24.0;
    }
    CGFloat minScrollContentH = MAX(viewportH + 92.0, totalBottom);
    _scrollView.contentSize = CGSizeMake(w, minScrollContentH);
    CGFloat histH = [self historyTotalHeight];
    _scrollView.contentInset = UIEdgeInsetsMake(histH, 0.0, 36.0, 0.0);

    if (hadPending || !_didSetInitialOffset || (!_scrollView.isTracking && !_scrollView.isDecelerating)) {
        _didSetInitialOffset = YES;
        _hasPendingScrollOffset = NO;
        [self setCurrentScrollOffset:targetScrollOffset];
    }

    if (_clearPromptOverlay && !_clearPromptOverlay.hidden) {
        [self layoutClearPromptOverlay];
    }

    [self updateStickyHeadersAndClipping];
}

- (CGFloat)pillsBarTopDocY {
    return kContinueHeaderDocY; // 87.0 pt in both Portrait (screenY = 167.0) and Landscape (screenY = 139.0)
}

- (CGFloat)firstSectionHeaderOffset {
    return _landscapeMode ? 56.0 : kFirstSectionHeaderOffset; // 56.0 pt in Landscape (screenY = 195.0 -> cap-top 198.33)
}

- (CGFloat)firstSectionHeaderNaturalDocY {
    BOOL hasPills = ([self activePillSlots].count > 0);
    return [self pillsBarTopDocY] + (hasPills ? [self firstSectionHeaderOffset] : 0.0);
}

- (CGFloat)userQueueRowsStartDocY {
    return [self firstSectionHeaderNaturalDocY] + kUserQueueHeaderHeight;
}

- (CGFloat)continueHeaderNaturalDocY {
    if (_userQueueItems.count > 0) {
        CGFloat uqBottom = [self userQueueRowsStartDocY] + _userQueueRowViews.count * kQueueRowPitch + kAddSongsRowHeight;
        return uqBottom + kUserQueueToContinueGap;
    }
    return [self firstSectionHeaderNaturalDocY];
}

- (CGFloat)continueRowsStartDocY {
    if (_userQueueItems.count > 0) {
        return [self continueHeaderNaturalDocY] + kContinueAfterQueueHeaderHeight;
    }
    return [self firstSectionHeaderNaturalDocY] + [self continueSectionHeaderHeight];
}

- (NSArray<NSNumber *> *)activePillSlots {
    NSMutableArray<NSNumber *> *slots = [NSMutableArray arrayWithCapacity:4];
    for (NSUInteger i = 0; i < 4; i++) {
        if (SGRQueuePillKindForSlot(i) != SGRQueuePillNone) {
            [slots addObject:@(i)];
        }
    }
    return slots;
}

- (void)closeParkedSwipeRowsExcept:(SGRQueueRowView *)excludedRow animated:(BOOL)animated {
    for (SGRQueueRowView *row in _userQueueRowViews) {
        if (row != excludedRow && row.isSwipeParked) [row closeSwipeAnimated:animated];
    }
    for (SGRQueueRowView *row in _queueRowViews) {
        if (row != excludedRow && row.isSwipeParked) [row closeSwipeAnimated:animated];
    }
}

- (void)updateStickyHeadersAndClipping {
    CGFloat w = self.bounds.size.width;
    CGFloat scrollY = _scrollView.contentOffset.y;
    CGFloat histH = [self historyTotalHeight];
    BOOL hasPills = ([self activePillSlots].count > 0);
    BOOL hasUserQueue = (_userQueueItems.count > 0);
    BOOL hasContinue  = (_futureItems.count > 0);
    CGFloat pinOffset = [self continueHeaderPinOffset];

    // 1. 4-Pill Bar pins at docY = MAX(pillsBarTopDocY, scrollY + pinOffset)
    CGFloat pillsPinDocY = MAX([self pillsBarTopDocY], scrollY + pinOffset);
    _pillsBarView.hidden = !hasPills;
    _pillsBarView.bounds = CGRectMake(0.0, 0.0, w, kPillsBarHeight);
    _pillsBarView.center = CGPointMake(w * 0.5, pillsPinDocY + kPillsBarHeight * 0.5);

    CGFloat subHeaderPinTop = pillsPinDocY + (hasPills ? [self firstSectionHeaderOffset] : 0.0);
    CGFloat continueNatDocY = [self continueHeaderNaturalDocY];
    CGFloat continueHdrH    = hasUserQueue ? kContinueAfterQueueHeaderHeight : [self continueSectionHeaderHeight];

    // 2A. Section 2A: User Queue ("Queue" + "Clear" & "+ Add Songs to Queue")
    if (hasUserQueue) {
        CGFloat uqNatDocY = [self firstSectionHeaderNaturalDocY];
        CGFloat uqHdrH    = kUserQueueHeaderHeight;
        CGFloat uqHdrDocY = MAX(uqNatDocY, subHeaderPinTop);
        if (hasContinue) {
            uqHdrDocY = MIN(uqHdrDocY, continueNatDocY - uqHdrH);
        }
        // Smoothly fade out "Queue / Clear" as Continue Playing pushes it up toward the 4-pill bar
        CGFloat pushDist = MAX(0.0, subHeaderPinTop - uqHdrDocY);
        CGFloat uqAlpha  = MAX(0.0, 1.0 - (pushDist / 20.0));
        CGFloat clampedHdrDocY = MAX(subHeaderPinTop - 14.0, uqHdrDocY);
        if (!_isAnimatingRowDelete) {
            _userQueueHeaderView.alpha = uqAlpha;
        }
        _userQueueHeaderView.bounds = CGRectMake(0.0, 0.0, w, uqHdrH);
        _userQueueHeaderView.center = CGPointMake(w * 0.5, clampedHdrDocY + uqHdrH * 0.5);

        CGFloat uqRowsStart = [self userQueueRowsStartDocY];
        CGFloat uqContentH  = _userQueueRowViews.count * kQueueRowPitch + kAddSongsRowHeight;
        CGFloat uqClipTop   = MAX(uqHdrDocY + uqHdrH, subHeaderPinTop + uqHdrH);
        CGFloat uqClipBot   = hasContinue ? MIN(uqRowsStart + uqContentH + 16.0, MAX(continueNatDocY, subHeaderPinTop)) : (uqRowsStart + uqContentH + 120.0);
        CGFloat uqClipH     = MAX(0.0, uqClipBot - uqClipTop);
        _userQueueRowsClipView.bounds = CGRectMake(0.0, 0.0, w, uqClipH);
        _userQueueRowsClipView.center = CGPointMake(w * 0.5, uqClipTop + uqClipH * 0.5);
        _userQueueRowsContainerView.frame = CGRectMake(0.0, uqRowsStart - uqClipTop, w, uqContentH);
    }

    // 2B. Section 2B: Continue Playing Sticky Header & Rows
    if (hasContinue) {
        CGFloat contHdrDocY = MAX(continueNatDocY, subHeaderPinTop);
        _continueHeaderView.bounds = CGRectMake(0.0, 0.0, w, continueHdrH);
        _continueHeaderView.center = CGPointMake(w * 0.5, contHdrDocY + continueHdrH * 0.5);

        CGFloat contClipTop = contHdrDocY + continueHdrH;
        CGFloat rowsStartY  = [self continueRowsStartDocY];
        CGFloat contBotDocY = rowsStartY + _queueRowViews.count * kQueueRowPitch + 120.0;
        CGFloat contClipH   = MAX(0.0, contBotDocY - contClipTop);
        _queueRowsClipView.bounds = CGRectMake(0.0, 0.0, w, contClipH);
        _queueRowsClipView.center = CGPointMake(w * 0.5, contClipTop + contClipH * 0.5);
        _queueRowsContainerView.frame = CGRectMake(0.0, rowsStartY - contClipTop, w, _queueRowViews.count * kQueueRowPitch);
    }

    // 3. Section 1: Now Playing Card clipped strictly between top clip plane and rising 4-pill bar / header
    CGFloat topPinnedBoundary = hasPills ? pillsPinDocY : subHeaderPinTop;
    CGFloat npClipTopDocY = (scrollY > 0.0) ? (scrollY + pinOffset) : 0.0;
    CGFloat npClipBottomDocY = MIN(kNowPlayingDocY + kNowPlayingHeight, topPinnedBoundary);
    CGFloat npClipH = MAX(0.0, npClipBottomDocY - npClipTopDocY);
    _nowPlayingClipView.frame = CGRectMake(0.0, npClipTopDocY, w, npClipH);
    _nowPlayingClipView.hidden = (npClipH <= 0.5);
    _nowPlayingCard.frame = CGRectMake(0.0, kNowPlayingDocY - npClipTopDocY, w, kNowPlayingHeight);

    // 4. Section 0: History Sticky Header & Sharp Row Clip
    if (histH > 0.0 && scrollY < -0.5) {
        _historyHeaderView.hidden = NO;
        _historyRowsClipView.hidden = NO;

        CGFloat histPin = [self historyHeaderPinOffset];
        CGFloat histHeaderDocY = MIN(MAX(-histH + histPin, scrollY + histPin), kHistoryHeaderPushOffDocY);
        _historyHeaderView.frame = CGRectMake(0.0, histHeaderDocY, w, kHistoryHeaderHeight);

        CGFloat histClipTopDocY = histHeaderDocY + kHistoryHeaderClipOffset;
        CGFloat histClipBottomDocY = MIN(kNowPlayingDocY - 4.0, topPinnedBoundary);
        CGFloat clipH = MAX(0.0, histClipBottomDocY - histClipTopDocY);
        _historyRowsClipView.frame = CGRectMake(0.0, histClipTopDocY, w, clipH);

        CGFloat histFirstRowDocY = -histH + histPin + kHistoryHeaderHeight;
        _historyRowsContainerView.frame = CGRectMake(0.0, histFirstRowDocY - histClipTopDocY, w, _historyRowViews.count * kHistoryRowPitch);
    } else {
        _historyHeaderView.hidden = YES;
        _historyRowsClipView.hidden = YES;
    }
}

#pragma mark - Scroll-Stop Detent at scrollY = 0 pt

- (BOOL)scrollViewShouldScrollToTop:(UIScrollView *)scrollView {
    _clampAtZeroOnDragOrDecel = NO;
    [scrollView setContentOffset:CGPointZero animated:YES];
    return NO;
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self closeParkedSwipeRowsExcept:nil animated:YES];
    _dragStartOffsetY = scrollView.contentOffset.y;
    // Clamping detent at scrollY = 0 is active when dragging back toward Now Playing from either Queue or History
    _clampAtZeroOnDragOrDecel = (fabs(_dragStartOffsetY) > 2.0);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat y = scrollView.contentOffset.y;

    // Hard stop at scrollY = 0 whenever returning towards "Now Playing" from either direction
    if (_clampAtZeroOnDragOrDecel) {
        if (_dragStartOffsetY > 2.0 && y < 0.0) {
            scrollView.contentOffset = CGPointZero;
            if (!scrollView.isTracking) {
                _clampAtZeroOnDragOrDecel = NO;
            }
            [self updateStickyHeadersAndClipping];
            return;
        } else if (_dragStartOffsetY < -2.0 && y > 0.0) {
            scrollView.contentOffset = CGPointZero;
            if (!scrollView.isTracking) {
                _clampAtZeroOnDragOrDecel = NO;
            }
            [self updateStickyHeadersAndClipping];
            return;
        }
    }

    [self updateStickyHeadersAndClipping];
}

- (void)scrollViewDidEndDecelerating:(__unused UIScrollView *)scrollView {
    _clampAtZeroOnDragOrDecel = NO;
    [self applyHistoryInsetPreservingOffset];
}

- (void)scrollViewDidEndDragging:(__unused UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        _clampAtZeroOnDragOrDecel = NO;
        [self applyHistoryInsetPreservingOffset];
    }
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset {
    CGFloat histH = [self historyTotalHeight];
    if (histH <= 0.0) {
        if (targetContentOffset->y < 0.0) {
            targetContentOffset->y = 0.0;
            _clampAtZeroOnDragOrDecel = YES;
        }
        return;
    }

    CGFloat currentY = scrollView.contentOffset.y;

    // Case 1: Dragging started inside "Continue Playing" (_dragStartOffsetY > 2.0) -> clamp deceleration cleanly at 0
    if (_dragStartOffsetY > 2.0) {
        if (targetContentOffset->y < 0.0) {
            targetContentOffset->y = 0.0;
            _clampAtZeroOnDragOrDecel = YES;
        }
        return;
    }

    NSInteger maxTopRowIndex = MAX((NSInteger)0, (NSInteger)_historyItems.count - 2);
    CGFloat maxHistoryStopY = -histH + maxTopRowIndex * kHistoryRowPitch;
    CGFloat (^snapHistoryY)(CGFloat) = ^CGFloat(CGFloat targetY) {
        CGFloat rawY = MIN(maxHistoryStopY, MAX(-histH, targetY));
        NSInteger rowIdx = MAX((NSInteger)0, MIN(maxTopRowIndex, (NSInteger)llround((rawY + histH) / kHistoryRowPitch)));
        return -histH + rowIdx * kHistoryRowPitch;
    };

    // Case 2: Dragging started at rest near 0 (_dragStartOffsetY >= -2.0) and pulled downward into History.
    if (_dragStartOffsetY >= -2.0) {
        if ((currentY < -22.0 && velocity.y <= 0.08) || targetContentOffset->y < -22.0) {
            targetContentOffset->y = snapHistoryY(targetContentOffset->y);
            _clampAtZeroOnDragOrDecel = NO;
        } else if (targetContentOffset->y < 0.0) {
            targetContentOffset->y = 0.0;
            _clampAtZeroOnDragOrDecel = YES;
        }
        return;
    }

    // Case 3: Swiping or scrolling inside History (_dragStartOffsetY < -2.0)
    if (_dragStartOffsetY < -2.0) {
        if (velocity.y > 0.05 || targetContentOffset->y > maxHistoryStopY + 18.0 || targetContentOffset->y > 0.0) {
            targetContentOffset->y = 0.0;
            _clampAtZeroOnDragOrDecel = YES;
        } else {
            targetContentOffset->y = snapHistoryY(targetContentOffset->y);
            _clampAtZeroOnDragOrDecel = NO;
        }
        return;
    }
}

#pragma mark - Configurable Playback Mode Bar & Actions

- (void)stylePill:(UIButton *)pill active:(BOOL)active symbol:(NSString *)symbol isTransitions:(BOOL)isTransitions {
    CGSize sz = pill.bounds.size;
    if (sz.width < 10.0 || sz.height < 10.0) {
        CGFloat w = MAX(320.0, self.bounds.size.width);
        sz = CGSizeMake(floor(((w - kSideMargin * 2.0 - 36.0) / 4.0) * 2.0) * 0.5, 38.0);
    }
    UIImage *bgImg = SGRRenderPillCapsuleImage(sz, active, symbol, isTransitions);
    [pill setBackgroundImage:bgImg forState:UIControlStateNormal];
    [pill setBackgroundImage:bgImg forState:UIControlStateHighlighted];
    [pill setImage:nil forState:UIControlStateNormal];
}

- (UIMenu *)customizeMenuForPillSlot:(NSUInteger)slot {
    SGRQueuePillKind currentKind = SGRQueuePillKindForSlot(slot);
    NSArray<NSString *> *names = SGRQueuePillNames();
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray arrayWithCapacity:names.count];
    __weak typeof(self) weakSelf = self;
    for (NSUInteger k = 0; k < names.count; k++) {
        NSString *name = names[k];
        BOOL isSel = ((NSUInteger)currentKind == k);
        UIAction *act = [UIAction actionWithTitle:name image:nil identifier:nil handler:^(__unused __kindof UIAction *action) {
            SGRSetQueuePillKindForSlot(slot, (SGRQueuePillKind)k);
            [weakSelf handlePillsChanged:nil];
        }];
        act.state = isSel ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:act];
    }
    return [UIMenu menuWithTitle:[NSString stringWithFormat:@"Button %lu", (unsigned long)(slot + 1)] children:actions];
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

    __weak typeof(self) weakSelf = self;
    for (NSUInteger slot = 0; slot < 4; slot++) {
        UIButton *pill = _pillButtons[slot];
        SGRQueuePillKind kind = SGRQueuePillKindForSlot(slot);
        switch (kind) {
            case SGRQueuePillShuffle:
                [self stylePill:pill active:shuffling symbol:@"shuffle" isTransitions:NO];
                pill.showsMenuAsPrimaryAction = NO;
                pill.menu = nil;
                pill.accessibilityLabel = @"Shuffle";
                pill.accessibilityValue = shuffling ? @"On" : @"Off";
                break;
            case SGRQueuePillRepeat:
                [self stylePill:pill active:(repeatTrack || repeatContext) symbol:(repeatTrack ? @"repeat.1" : @"repeat") isTransitions:NO];
                pill.showsMenuAsPrimaryAction = NO;
                pill.menu = nil;
                pill.accessibilityLabel = @"Repeat";
                pill.accessibilityValue = repeatTrack ? @"Repeat One" : (repeatContext ? @"Repeat All" : @"Off");
                break;
            case SGRQueuePillAutoplay:
                [self stylePill:pill active:SGFlag(SGRKeyQueueAutoplay, YES) symbol:@"infinity" isTransitions:NO];
                pill.showsMenuAsPrimaryAction = NO;
                pill.menu = nil;
                pill.accessibilityLabel = @"Autoplay";
                pill.accessibilityValue = SGFlag(SGRKeyQueueAutoplay, YES) ? @"On" : @"Off";
                break;
            case SGRQueuePillTransitions: {
                SGTransitionSettings ts = {0};
                BOOL transActive = SGTransitionSettingsRead(&ts) ? (ts.automix || ts.crossfade) : SGFlag(SGKeyAutoMix, NO);
                [self stylePill:pill active:transActive symbol:nil isTransitions:YES];
                pill.showsMenuAsPrimaryAction = NO;
                pill.menu = nil;
                pill.accessibilityLabel = @"Transitions";
                pill.accessibilityValue = transActive ? @"On" : @"Off";
                break;
            }
            case SGRQueuePillSleepTimer: {
                BOOL timerActive = NO;
                NSString *sleepSummary = SGRPlayerSleepTimerSummary(&timerActive);
                [self stylePill:pill active:timerActive symbol:(timerActive ? @"moon.zzz.fill" : @"moon.zzz") isTransitions:NO];
                pill.showsMenuAsPrimaryAction = YES;
                UIMenu *timerMenu = SGRPlayerSleepTimerMenu(nil, ^{
                    [weakSelf updatePlaybackPillsWithState:SGPlayerState()];
                });
                UIMenu *customMenu = [self customizeMenuForPillSlot:slot];
                NSMutableArray<UIMenuElement *> *menuElements = [NSMutableArray arrayWithArray:timerMenu.children];
                [menuElements addObject:customMenu];
                pill.menu = [UIMenu menuWithTitle:@"" children:menuElements];
                pill.accessibilityLabel = @"Sleep Timer";
                pill.accessibilityValue = sleepSummary.length ? sleepSummary : (timerActive ? @"On" : @"Off");
                break;
            }
            case SGRQueuePillSpeedPitch: {
                BOOL spActive = (SGPlayerSpeedAllowed() && fabs(SGPlayerSpeed() - 1.0) >= 0.01) ||
                                (SGPlayerPitchAvailable() && SGPlayerPitch() != 0) ||
                                (SGPlayerReverb() > 0);
                [self stylePill:pill active:spActive symbol:@"slider.horizontal.3" isTransitions:NO];
                pill.showsMenuAsPrimaryAction = NO;
                pill.menu = nil;
                pill.accessibilityLabel = @"Speed and pitch";
                pill.accessibilityValue = spActive ? @"Active" : @"Normal";
                break;
            }
            case SGRQueuePillLyricsSource: {
                BOOL lsActive = (SGLyricsChosenSource(SGKaraokePlayingTrack()) != nil);
                [self stylePill:pill active:lsActive symbol:@"quote.bubble" isTransitions:NO];
                pill.showsMenuAsPrimaryAction = NO;
                pill.menu = nil;
                pill.accessibilityLabel = @"Lyrics source";
                pill.accessibilityValue = lsActive ? @"Custom" : @"Default";
                break;
            }
            case SGRQueuePillNone:
                pill.showsMenuAsPrimaryAction = NO;
                pill.menu = nil;
                pill.hidden = YES;
                pill.accessibilityLabel = nil;
                break;
        }
    }
}

- (void)handlePillTap:(UIButton *)pill {
    NSUInteger slot = (NSUInteger)pill.tag;
    SGRQueuePillKind kind = SGRQueuePillKindForSlot(slot);
    switch (kind) {
        case SGRQueuePillShuffle:
            [self handleShufflePillTap];
            break;
        case SGRQueuePillRepeat:
            [self handleRepeatPillTap];
            break;
        case SGRQueuePillAutoplay:
            [self handleAutoplayPillTap];
            break;
        case SGRQueuePillTransitions:
            [self handleTransitionsPillTap];
            break;
        case SGRQueuePillSleepTimer:
            break;
        case SGRQueuePillSpeedPitch:
            SGPlayerShowSpeedPitchPanel(pill);
            break;
        case SGRQueuePillLyricsSource:
            SGRPlayerShowLyricsSourcePanel(pill);
            break;
        case SGRQueuePillNone:
            break;
    }
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
    BOOL next = !SGFlag(SGRKeyQueueAutoplay, YES);
    SGSetEnabled(SGRKeyQueueAutoplay, next);
    [[SGRQueueSession shared] refreshForAutoplaySettingChange];
    [self updatePlaybackPillsWithState:SGPlayerState()];
}

- (void)handleTransitionsPillTap {
    SGTransitionSettings ts = {0};
    BOOL cur = SGTransitionSettingsRead(&ts) ? (ts.automix || ts.crossfade) : SGFlag(SGKeyAutoMix, NO);
    BOOL next = !cur;
    SGSetEnabled(SGKeyAutoMix, next);
    SGAutoMixApply(next);
    if (!next && !SGFlag(SGKeyAutoMixSaved, NO)) {
        SGTransitionSettings off = {NO, NO, ts.milliseconds};
        SGTransitionSettingsWrite(off);
    }
    [self updatePlaybackPillsWithState:SGPlayerState()];
}

- (void)handleNowPlayingArtTap {
    SGRPlayerToggleQueue();
}

- (void)handleNowPlayingStarTap {
    NSString *trackURI = _currentItem.uri ?: @"";
    if (!trackURI.length) return;
    BOOL wasSaved = [[SGRQueueSession shared] isTrackSaved:trackURI];
    BOOL newSaved = !wasSaved;
    [[SGRQueueSession shared] setTrackURI:trackURI saved:newSaved];

    [_npStarButton setImage:SGRNowPlayingSaveImage(newSaved) forState:UIControlStateNormal];
    _npStarButton.accessibilityLabel = newSaved ? @"Remove from Your Library" : @"Add to Your Library";

    [UIView animateWithDuration:0.12 animations:^{
        self->_npStarButton.transform = CGAffineTransformMakeScale(1.22, 1.22);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.15 animations:^{
            self->_npStarButton.transform = CGAffineTransformIdentity;
        }];
    }];
}

- (void)handleAddSongsToQueueTap {
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [gen impactOccurred];
    SGRPlayerMinimizeIfOpen();
}

- (void)handleClearHistoryTap {
    if (_historyItems.count == 0) return;
    [self presentClearPromptForHistory:YES];
}

- (void)handleClearUserQueueTap {
    if (_userQueueItems.count == 0) return;
    [self presentClearPromptForHistory:NO];
}

- (UIControl *)createClearPromptCapsuleWithFrame:(CGRect)frame
                                           title:(NSString *)title
                                           color:(UIColor *)color
                                          action:(SEL)action
                                     isProminent:(__unused BOOL)isProminent
                                        outLabel:(UILabel * __strong *)outLabel {
    // Built as a custom UIControl + UILabel with flat translucent fill so global UIButton hooks never re-tint "Cancel"
    UIControl *ctrl = [[UIControl alloc] initWithFrame:frame];
    ctrl.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    ctrl.layer.compositingFilter = @"plusL";
    ctrl.layer.cornerRadius = frame.size.height * 0.5;
    ctrl.layer.cornerCurve = kCACornerCurveContinuous;
    ctrl.clipsToBounds = YES;
    ctrl.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [ctrl addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [ctrl addTarget:self action:@selector(handlePromptCapsuleTouchDown:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [ctrl addTarget:self action:@selector(handlePromptCapsuleTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];

    UIView *highlightView = [[UIView alloc] initWithFrame:ctrl.bounds];
    highlightView.tag = 8881;
    highlightView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.0];
    highlightView.layer.compositingFilter = @"plusL";
    highlightView.layer.cornerRadius = frame.size.height * 0.5;
    highlightView.layer.cornerCurve = kCACornerCurveContinuous;
    highlightView.clipsToBounds = YES;
    highlightView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    highlightView.userInteractionEnabled = NO;
    [ctrl addSubview:highlightView];

    UILabel *lbl = [[UILabel alloc] initWithFrame:ctrl.bounds];
    lbl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.userInteractionEnabled = NO;
    lbl.attributedText = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: SGRQueueFont(17.0, UIFontWeightSemibold),
        NSForegroundColorAttributeName: color,
        NSKernAttributeName: @(-0.35),
    }];
    [ctrl addSubview:lbl];
    if (outLabel) *outLabel = lbl;
    return ctrl;
}

- (void)handlePromptCapsuleTouchDown:(UIControl *)sender {
    UIView *hl = [sender viewWithTag:8881];
    [UIView animateWithDuration:0.08 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        // Subtle +17 RGB press lift matching Apple Music's capsule button highlight
        if (hl) hl.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.068];
    } completion:nil];
}

- (void)handlePromptCapsuleTouchUp:(UIControl *)sender {
    UIView *hl = [sender viewWithTag:8881];
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        if (hl) hl.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.0];
    } completion:nil];
}

- (void)layoutClearPromptButtonsForCardWidth:(CGFloat)cardW {
    if (!_clearPromptCancelControl || !_clearPromptConfirmControl) return;
    CGFloat sideMargin = 16.0;
    CGFloat gap = 8.33;
    CGFloat btnW = (cardW - (sideMargin * 2.0) - gap) * 0.5;
    CGFloat btnH = 48.0;
    CGFloat btnY = 84.33;
    _clearPromptCancelControl.frame = CGRectMake(sideMargin, btnY, btnW, btnH);
    _clearPromptConfirmControl.frame = CGRectMake(sideMargin + btnW + gap, btnY, btnW, btnH);
}

- (void)resetPromptCapsuleControl:(UIControl *)ctrl {
    if (!ctrl) return;
    ctrl.transform = CGAffineTransformIdentity;
    ctrl.alpha = 1.0;
    ctrl.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    UIView *hl = [ctrl viewWithTag:8881];
    if (hl) hl.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.0];
}

- (void)layoutClearPromptOverlay {
    if (!_clearPromptOverlay) return;
    UIView *hostView = _clearPromptOverlay.superview ?: (self.window ?: (self.superview ?: self));
    CGRect hostBounds = hostView.bounds;
    _clearPromptOverlay.frame = hostBounds;

    CGFloat w = hostBounds.size.width;
    CGFloat cardW = MIN(320.67, w - 69.33);
    CGFloat cardH = 148.33;
    CGFloat cardX, cardY;
    if (_landscapeMode || hostBounds.size.width > hostBounds.size.height) {
        CGPoint queueCenterInHost = [self convertPoint:CGPointMake(self.bounds.size.width * 0.5, self.bounds.size.height * 0.5) toView:hostView];
        cardX = round((queueCenterInHost.x - cardW * 0.5) * 3.0) / 3.0;
        cardX = MAX(16.0, MIN(hostBounds.size.width - cardW - 16.0, cardX));
        cardY = round(((hostBounds.size.height - cardH) * 0.5) * 3.0) / 3.0;
    } else {
        cardX = round((w - cardW) * 0.5 * 3.0) / 3.0;
        // In Apple Music @ 390x844, card spans screenY = 354.00 .. 502.33 pt (height 148.33 pt)
        CGPoint originInHost = [self convertPoint:CGPointMake(0.0, 300.0) toView:hostView];
        cardY = round(originInHost.y * 3.0) / 3.0;
    }
    CGRect cardRect = CGRectMake(cardX, cardY, cardW, cardH);

    if (_clearPromptDimLayer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _clearPromptDimLayer.frame = hostBounds;
        _clearPromptDimLayer.path = [UIBezierPath bezierPathWithRect:hostBounds].CGPath;
        [CATransaction commit];
    }

    CGAffineTransform savedTx = _clearPromptCard.transform;
    _clearPromptCard.transform = CGAffineTransformIdentity;
    _clearPromptCard.frame = cardRect;
    _clearPromptCard.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_clearPromptCard.bounds cornerRadius:32.0].CGPath;
    if (_clearPromptGlass) {
        _clearPromptGlass.frame = _clearPromptCard.bounds;
    }
    _clearPromptTitleLabel.frame = CGRectMake(30.67, 21.0, cardW - 60.0, 48.0);
    [self layoutClearPromptButtonsForCardWidth:cardW];
    _clearPromptCard.transform = savedTx;
}

- (void)presentClearPromptForHistory:(BOOL)isHistory {
    [self closeParkedSwipeRowsExcept:nil animated:YES];
    _clearPromptIsForHistory = isHistory;

    UIView *hostView = self.window ?: (self.superview ?: self);
    CGFloat w = hostView.bounds.size.width;
    CGFloat cardW = MIN(320.67, w - 69.33);
    CGFloat cardH = 148.33;

    if (!_clearPromptOverlay) {
        _clearPromptOverlay = [[UIControl alloc] initWithFrame:hostView.bounds];
        _clearPromptOverlay.backgroundColor = UIColor.clearColor;
        _clearPromptOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_clearPromptOverlay addTarget:self action:@selector(handleCancelClearPromptTap) forControlEvents:UIControlEventTouchUpInside];

        // Full-screen uniform dim backdrop so the confirmation card has Apple Music's deep dark charcoal base
        _clearPromptDimLayer = [CAShapeLayer layer];
        _clearPromptDimLayer.fillColor = [UIColor colorWithWhite:0.0 alpha:0.45].CGColor;
        [_clearPromptOverlay.layer addSublayer:_clearPromptDimLayer];

        _clearPromptCard = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, cardW, cardH)];
        _clearPromptCard.backgroundColor = UIColor.clearColor;
        _clearPromptCard.clipsToBounds = NO;
        _clearPromptCard.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        _clearPromptCard.layer.shadowColor = UIColor.blackColor.CGColor;
        _clearPromptCard.layer.shadowOpacity = 0.35;
        _clearPromptCard.layer.shadowRadius = 24.0;
        _clearPromptCard.layer.shadowOffset = CGSizeMake(0.0, 10.0);
        _clearPromptCard.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_clearPromptCard.bounds cornerRadius:32.0].CGPath;

        // Heavily diffused dark Gaussian blur matching Apple Music's alert card material
        UIVisualEffect *cardEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
        _clearPromptGlass = [[UIVisualEffectView alloc] initWithEffect:cardEffect];
        _clearPromptGlass.frame = _clearPromptCard.bounds;
        _clearPromptGlass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _clearPromptGlass.layer.cornerRadius = 32.0;
        _clearPromptGlass.layer.cornerCurve = kCACornerCurveContinuous;
        _clearPromptGlass.layer.borderWidth = 0.50;
        _clearPromptGlass.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
        _clearPromptGlass.clipsToBounds = YES;
        _clearPromptGlass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [_clearPromptCard addSubview:_clearPromptGlass];

        UIView *glassLiftOverlay = [[UIView alloc] initWithFrame:_clearPromptCard.bounds];
        glassLiftOverlay.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.055];
        glassLiftOverlay.layer.compositingFilter = @"plusL";
        glassLiftOverlay.layer.cornerRadius = 32.0;
        glassLiftOverlay.layer.cornerCurve = kCACornerCurveContinuous;
        glassLiftOverlay.clipsToBounds = YES;
        glassLiftOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glassLiftOverlay.userInteractionEnabled = NO;
        [_clearPromptGlass.contentView addSubview:glassLiftOverlay];

        _clearPromptTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(30.67, 21.0, cardW - 60.0, 48.0)];
        _clearPromptTitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _clearPromptTitleLabel.numberOfLines = 2;
        _clearPromptTitleLabel.userInteractionEnabled = NO;
        [_clearPromptCard addSubview:_clearPromptTitleLabel];

        CGFloat sideMargin = 16.0;
        CGFloat gap = 8.33;
        CGFloat btnW = (cardW - (sideMargin * 2.0) - gap) * 0.5;
        CGFloat btnH = 48.0;
        CGFloat btnY = 84.33;
        _clearPromptCancelControl = [self createClearPromptCapsuleWithFrame:CGRectMake(sideMargin, btnY, btnW, btnH)
                                                                      title:@"Cancel"
                                                                      color:UIColor.whiteColor
                                                                     action:@selector(handleCancelClearPromptTap)
                                                                isProminent:NO
                                                                   outLabel:NULL];
        _clearPromptCancelControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleRightMargin;
        [_clearPromptCard addSubview:_clearPromptCancelControl];

        UIColor *coralColor = [UIColor colorWithRed:238.0/255.0 green:120.0/255.0 blue:121.0/255.0 alpha:1.0];
        UILabel *confirmLbl = nil;
        _clearPromptConfirmControl = [self createClearPromptCapsuleWithFrame:CGRectMake(sideMargin + btnW + gap, btnY, btnW, btnH)
                                                                       title:@"Clear"
                                                                       color:coralColor
                                                                      action:@selector(confirmClearPromptAction)
                                                                 isProminent:NO
                                                                    outLabel:&confirmLbl];
        _clearPromptConfirmControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
        _clearPromptConfirmLabel = confirmLbl;
        [_clearPromptCard addSubview:_clearPromptConfirmControl];

        [_clearPromptOverlay addSubview:_clearPromptCard];
    }

    NSString *promptText = isHistory ? @"Are you sure you want to clear\nyour history?"
                                     : @"Are you sure you want to clear\nyour queue?";
    NSMutableParagraphStyle *pStyle = [[NSMutableParagraphStyle alloc] init];
    pStyle.lineSpacing = 1.67;
    pStyle.alignment = NSTextAlignmentLeft;
    _clearPromptTitleLabel.attributedText = [[NSAttributedString alloc] initWithString:promptText attributes:@{
        NSFontAttributeName: SGRQueueFont(17.0, UIFontWeightSemibold),
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSKernAttributeName: @(-0.43),
        NSParagraphStyleAttributeName: pStyle,
    }];

    NSString *confirmTitle = isHistory ? @"Clear" : @"Clear Queue";
    UIColor *coralColor = [UIColor colorWithRed:238.0/255.0 green:120.0/255.0 blue:121.0/255.0 alpha:1.0];
    _clearPromptConfirmLabel.attributedText = [[NSAttributedString alloc] initWithString:confirmTitle attributes:@{
        NSFontAttributeName: SGRQueueFont(17.0, UIFontWeightSemibold),
        NSForegroundColorAttributeName: coralColor,
        NSKernAttributeName: @(-0.35),
    }];
    [self resetPromptCapsuleControl:_clearPromptCancelControl];
    [self resetPromptCapsuleControl:_clearPromptConfirmControl];

    if (_clearPromptOverlay.superview != hostView) {
        [_clearPromptOverlay removeFromSuperview];
        [hostView addSubview:_clearPromptOverlay];
    }
    _clearPromptCard.transform = CGAffineTransformIdentity;
    [self layoutClearPromptOverlay];
    _clearPromptOverlay.hidden = NO;
    _clearPromptOverlay.alpha = 0.0;
    // Matches Apple Music's exact 1.09x -> 1.00x alert entrance scale
    _clearPromptCard.transform = CGAffineTransformMakeScale(1.09, 1.09);
    [hostView bringSubviewToFront:_clearPromptOverlay];

    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [gen impactOccurred];

    [UIView animateWithDuration:0.24 delay:0 usingSpringWithDamping:1.0 initialSpringVelocity:0.0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut animations:^{
        self->_clearPromptOverlay.alpha = 1.0;
        self->_clearPromptCard.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)handleCancelClearPromptTap {
    [self dismissClearQueuePromptWithCompletion:nil];
}

- (void)dismissClearQueuePrompt {
    [self dismissClearQueuePromptWithCompletion:nil];
}

- (void)dismissClearQueuePromptWithCompletion:(void (^)(void))completion {
    if (!_clearPromptOverlay || _clearPromptOverlay.hidden) {
        if (completion) completion();
        return;
    }
    // Matches Apple Music's exact 1.00x pure fade-out dismissal over 0.20s (no scale shrinking)
    [UIView animateWithDuration:0.20 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        self->_clearPromptOverlay.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        self->_clearPromptOverlay.hidden = YES;
        self->_clearPromptCard.transform = CGAffineTransformIdentity;
        [self->_clearPromptOverlay removeFromSuperview];
        if (completion) completion();
    }];
}

- (void)confirmClearPromptAction {
    BOOL clearingHistory = _clearPromptIsForHistory;
    _isAnimatingRowDelete = YES;
    // Fade out the confirmation prompt (0.20s) simultaneously with the section collapse matching Apple Music
    [self dismissClearQueuePromptWithCompletion:nil];

    if (clearingHistory) {
        _clampAtZeroOnDragOrDecel = NO;
        [UIView animateKeyframesWithDuration:0.28 delay:0 options:UIViewKeyframeAnimationOptionCalculationModeCubic animations:^{
            [UIView addKeyframeWithRelativeStartTime:0.0 relativeDuration:0.45 animations:^{
                self->_historyHeaderView.alpha = 0.0;
                self->_historyRowsClipView.alpha = 0.0;
            }];
            [UIView addKeyframeWithRelativeStartTime:0.0 relativeDuration:1.0 animations:^{
                self->_scrollView.contentOffset = CGPointZero;
                [self updateStickyHeadersAndClipping];
            }];
        } completion:^(__unused BOOL finished) {
            self->_isAnimatingRowDelete = NO;
            self->_historyHeaderView.alpha = 1.0;
            self->_historyRowsClipView.alpha = 1.0;
            [[SGRQueueSession shared] clearHistory];
            [self syncFromSessionAnimatedReorder:NO forceRebuild:YES];
        }];
    } else {
        CGFloat w = self.bounds.size.width;
        BOOL hasContinue = (_futureItems.count > 0);
        BOOL showEmptyPrompt = (!hasContinue && !SGFlag(SGRKeyQueueAutoplay, YES));
        if (showEmptyPrompt) {
            [self placeEmptyQueuePromptForWidth:w];
            _emptyQueuePromptLabel.alpha = 0.0;
            _emptyQueuePromptLabel.hidden = NO;
        }
        CGFloat contHdrH = [self continueSectionHeaderHeight];
        CGFloat targetHdrTop = [self firstSectionHeaderNaturalDocY];
        CGFloat targetRowsTop = targetHdrTop + contHdrH;
        if (hasContinue) {
            // Pre-expand _queueRowsClipView downward so rows 4 and 5 slide up cleanly from beneath the bottom fade mask
            CGRect curClip = _queueRowsClipView.frame;
            CGFloat slideDelta = MAX(0.0, curClip.origin.y - targetRowsTop);
            _queueRowsClipView.frame = CGRectMake(curClip.origin.x, curClip.origin.y, curClip.size.width, curClip.size.height + slideDelta);
        }
        [UIView animateKeyframesWithDuration:0.26 delay:0 options:UIViewKeyframeAnimationOptionCalculationModeCubic animations:^{
            [UIView addKeyframeWithRelativeStartTime:0.0 relativeDuration:0.42 animations:^{
                self->_userQueueHeaderView.alpha = 0.0;
                self->_userQueueRowsClipView.alpha = 0.0;
            }];
            [UIView addKeyframeWithRelativeStartTime:0.0 relativeDuration:1.0 animations:^{
                if (showEmptyPrompt) {
                    self->_emptyQueuePromptLabel.alpha = 1.0;
                } else if (hasContinue) {
                    self->_continueHeaderView.bounds = CGRectMake(0.0, 0.0, w, contHdrH);
                    self->_continueHeaderView.center = CGPointMake(w * 0.5, targetHdrTop + contHdrH * 0.5);
                    CGFloat contClipH = self->_queueRowsClipView.bounds.size.height;
                    self->_queueRowsClipView.center = CGPointMake(w * 0.5, targetRowsTop + contClipH * 0.5);
                }
            }];
        } completion:^(__unused BOOL finished) {
            self->_isAnimatingRowDelete = NO;
            self->_userQueueHeaderView.alpha = 1.0;
            self->_userQueueRowsClipView.alpha = 1.0;
            [[SGRQueueSession shared] clearUserQueue];
            [self syncFromSessionAnimatedReorder:NO forceRebuild:YES];
        }];
    }
}

#pragma mark - SGRQueueRowViewDelegate (Tap, Swipe-to-Delete Collapse, Drag-to-Reorder)

- (void)queueRowWillBeginSwipe:(SGRQueueRowView *)row {
    [self closeParkedSwipeRowsExcept:row animated:YES];
}

- (void)playQueueItemViaQueueAndSkip:(SGRQueueItem *)item {
    if (!item.uri.length) return;
    id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
    Class wrapperCls = NSClassFromString(@"SPTPlayerQueueWrapperImpl");
    Class trackCls = NSClassFromString(@"SPTPlayerTrack");
    if (player &&
        [wrapperCls instancesRespondToSelector:@selector(initWithPlayer:)] &&
        [trackCls instancesRespondToSelector:@selector(initWithURI:albumURI:artistURI:andUID:)]) {
        NSURL *u = [NSURL URLWithString:item.uri];
        NSURL *alb = item.albumURI.length ? [NSURL URLWithString:item.albumURI] : nil;
        SPTPlayerTrack *fresh = u ? [[trackCls alloc] initWithURI:u albumURI:alb artistURI:nil andUID:nil] : nil;
        if (fresh) {
            SGRQueueWrapper *wrapper = [[wrapperCls alloc] initWithPlayer:player];
            // When user queue has items, queueTrackPlayNext: inserts at the front so skipToNextTrack plays `fresh` immediately
            if (_userQueueItems.count > 0 && [wrapperCls instancesRespondToSelector:@selector(queueTrackPlayNext:)]) {
                [wrapper queueTrackPlayNext:fresh];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    (void)wrapper;
                    if ([player respondsToSelector:@selector(skipToNextTrackWithOptions:)]) {
                        [player skipToNextTrackWithOptions:nil];
                    } else if ([player respondsToSelector:@selector(skipToNextTrack)]) {
                        [player skipToNextTrack];
                    }
                });
                return;
            }
            if ([wrapperCls instancesRespondToSelector:@selector(queueMultipleTracks:loggingParams:)]) {
                SGRQueueSPTask *task = [wrapper queueMultipleTracks:@[fresh] loggingParams:nil];
                if ([task respondsToSelector:@selector(addCallback:on:)]) {
                    // Retain wrapper across async callback so ARC does not release it early
                    [task addCallback:^(__unused id val) {
                        (void)wrapper;
                        if ([player respondsToSelector:@selector(skipToNextTrackWithOptions:)]) {
                            [player skipToNextTrackWithOptions:nil];
                        } else if ([player respondsToSelector:@selector(skipToNextTrack)]) {
                            [player skipToNextTrack];
                        }
                    } on:dispatch_get_main_queue()];
                    if ([task respondsToSelector:@selector(addErrorCallback:on:)]) {
                        [task addErrorCallback:^(__unused NSError *err) {
                            (void)wrapper;
                            SGOpenSpotifyURI([NSURL URLWithString:item.uri]);
                        } on:dispatch_get_main_queue()];
                    }
                    return;
                }
            }
        }
    }
    SGOpenSpotifyURI([NSURL URLWithString:item.uri]);
}

- (void)attachQueueAndSkipFallbackToTask:(id)task forItem:(SGRQueueItem *)item {
    if ([task respondsToSelector:@selector(addErrorCallback:on:)]) {
        __weak typeof(self) weakSelf = self;
        [(SGRQueueSPTask *)task addErrorCallback:^(__unused NSError *err) {
            [weakSelf playQueueItemViaQueueAndSkip:item];
        } on:dispatch_get_main_queue()];
    }
}

- (void)queueRowDidTap:(SGRQueueRowView *)row {
    SGRQueueItem *item = row.item;
    if (!item.uri.length) return;
    id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
    SPTPlayerState *state = SGPlayerState();

    if (!row.isHistory) {
        SPTPlayerTrack *liveFutureTrack = item.playerTrack;
        if (!liveFutureTrack) {
            NSArray *future = ([state respondsToSelector:@selector(future)] && [state.future isKindOfClass:NSArray.class]) ? state.future : @[];
            for (id cand in future) {
                if ([cand respondsToSelector:@selector(URI)] &&
                    [SGURIString(((SPTPlayerTrack *)cand).URI) isEqualToString:item.uri] &&
                    SGRIsUserQueuedTrack((SPTPlayerTrack *)cand) == row.isUserQueue) {
                    liveFutureTrack = (SPTPlayerTrack *)cand;
                    break;
                }
            }
            if (!liveFutureTrack) {
                for (id cand in future) {
                    if ([cand respondsToSelector:@selector(URI)] && [SGURIString(((SPTPlayerTrack *)cand).URI) isEqualToString:item.uri]) {
                        liveFutureTrack = (SPTPlayerTrack *)cand;
                        break;
                    }
                }
            }
        }

        @try {
            if (liveFutureTrack && [player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) {
                id res = [player skipToNextTrackWithOptions:nil track:liveFutureTrack];
                [self attachQueueAndSkipFallbackToTask:res forItem:item];
                return;
            }
            BOOL isVeryNextTrack = (row.rowIndex == 0 && (row.isUserQueue || _userQueueItems.count == 0));
            if (isVeryNextTrack && liveFutureTrack && [player respondsToSelector:@selector(skipToNextTrackWithOptions:)]) {
                [player skipToNextTrackWithOptions:nil];
                return;
            }
            SPTPlayerTrack *constructed = item.uid.length ? [item resolvedPlayerTrack] : nil;
            if (constructed && [player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) {
                id res = [player skipToNextTrackWithOptions:nil track:constructed];
                if ([res respondsToSelector:@selector(addErrorCallback:on:)]) {
                    [self attachQueueAndSkipFallbackToTask:res forItem:item];
                    return;
                }
            }
        } @catch (__unused NSException *e) {}

        [self playQueueItemViaQueueAndSkip:item];
    } else {
        SPTPlayerTrack *liveReverseTrack = item.playerTrack;
        if (!liveReverseTrack) {
            NSArray *reverse = ([state respondsToSelector:@selector(reverse)] && [state.reverse isKindOfClass:NSArray.class]) ? state.reverse : @[];
            for (id cand in reverse) {
                if ([cand respondsToSelector:@selector(URI)] && [SGURIString(((SPTPlayerTrack *)cand).URI) isEqualToString:item.uri]) {
                    liveReverseTrack = (SPTPlayerTrack *)cand;
                    break;
                }
            }
        }

        @try {
            if (liveReverseTrack && [player respondsToSelector:@selector(skipToPreviousTrackWithOptions:track:)]) {
                id res = [player skipToPreviousTrackWithOptions:nil track:liveReverseTrack];
                [self attachQueueAndSkipFallbackToTask:res forItem:item];
                return;
            }
        } @catch (__unused NSException *e) {}

        [self playQueueItemViaQueueAndSkip:item];
    }
}

- (void)queueRowDidCommitDelete:(SGRQueueRowView *)row {
    BOOL isUQ = row.isUserQueue;
    NSMutableArray<SGRQueueRowView *> *rowViews = isUQ ? _userQueueRowViews : _queueRowViews;
    NSMutableArray<SGRQueueItem *> *itemsList = isUQ ? _userQueueItems : _futureItems;
    NSMutableDictionary<NSString *, SGRQueueRowView *> *rowsByKey = isUQ ? _userQueueRowsByKey : _queueRowsByKey;

    NSUInteger idx = [rowViews indexOfObject:row];
    if (idx == NSNotFound || idx >= itemsList.count) return;

    SGRQueueItem *removedItem = itemsList[idx];
    _isAnimatingRowDelete = YES;
    [rowsByKey removeObjectForKey:removedItem.key];
    [itemsList removeObjectAtIndex:idx];
    [rowViews removeObjectAtIndex:idx];

    if (isUQ) {
        [[SGRQueueSession shared] deleteUserQueuedItemWithKey:removedItem.key];
    } else {
        [[SGRQueueSession shared] deleteContinuePlayingItemWithKey:removedItem.key];
    }

    for (NSUInteger i = 0; i < rowViews.count; i++) {
        rowViews[i].rowIndex = (NSInteger)i;
    }

    CGFloat w = self.bounds.size.width;
    CGRect startFrame = row.frame;
    [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        row.frame = CGRectMake(startFrame.origin.x, startFrame.origin.y, w, 0.5);
        row.alpha = 0.25;
    } completion:^(__unused BOOL finished) {
        [row removeFromSuperview];
    }];

    BOOL uqBecameEmpty = (isUQ && _userQueueItems.count == 0);
    BOOL cpBecameEmpty = (!isUQ && _futureItems.count == 0);
    BOOL queueEmpty = (_userQueueItems.count == 0 && _futureItems.count == 0 && !SGFlag(SGRKeyQueueAutoplay, YES));
    if (queueEmpty) {
        [self placeEmptyQueuePromptForWidth:w];
        _emptyQueuePromptLabel.alpha = 0.0;
        _emptyQueuePromptLabel.hidden = NO;
    }

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        for (NSUInteger i = idx; i < rowViews.count; i++) {
            SGRQueueRowView *below = rowViews[i];
            below.frame = CGRectMake(0.0, i * kQueueRowPitch, w, kQueueRowPitch);
        }
        if (isUQ) {
            self->_addSongsRowControl.frame = CGRectMake(0.0, self->_userQueueRowViews.count * kQueueRowPitch, w, kAddSongsRowHeight);
        }
        if (uqBecameEmpty) {
            self->_userQueueHeaderView.alpha = 0.0;
            self->_userQueueRowsClipView.alpha = 0.0;
        }
        if (cpBecameEmpty) {
            self->_continueHeaderView.alpha = 0.0;
            self->_queueRowsClipView.alpha = 0.0;
        }
        if (queueEmpty) {
            self->_emptyQueuePromptLabel.alpha = 1.0;
        }
        [self updateStickyHeadersAndClipping];
    } completion:^(__unused BOOL finished) {
        self->_isAnimatingRowDelete = NO;
        self->_userQueueHeaderView.alpha = 1.0;
        self->_userQueueRowsClipView.alpha = 1.0;
        self->_continueHeaderView.alpha = 1.0;
        self->_queueRowsClipView.alpha = 1.0;
        [self syncFromSessionAnimatedReorder:NO forceRebuild:NO];
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }];
}

- (void)queueRowHandlePan:(UIPanGestureRecognizer *)pan forRow:(SGRQueueRowView *)row {
    if (row.isHistory) return;
    BOOL isUQ = row.isUserQueue;
    UIView *containerView = isUQ ? _userQueueRowsContainerView : _queueRowsContainerView;
    NSMutableArray<SGRQueueRowView *> *rowViews = isUQ ? _userQueueRowViews : _queueRowViews;
    NSMutableArray<SGRQueueItem *> *itemsList = isUQ ? _userQueueItems : _futureItems;

    CGPoint locInContainer = [pan locationInView:containerView];
    CGFloat w = self.bounds.size.width;

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            [self closeParkedSwipeRowsExcept:nil animated:NO];
            _draggingRow = row;
            NSUInteger foundIdx = [rowViews indexOfObject:row];
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
            [containerView addSubview:snap];
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
            CGFloat maxCenterY = MAX(kQueueRowPitch * 0.5, (rowViews.count - 0.5) * kQueueRowPitch);
            targetCenterY = MIN(maxCenterY, MAX(kQueueRowPitch * 0.5, targetCenterY));
            _dragSnapshotView.center = CGPointMake(w * 0.5, targetCenterY);

            NSInteger hoverIndex = (NSInteger)floor(targetCenterY / kQueueRowPitch);
            hoverIndex = MAX(0, MIN((NSInteger)rowViews.count - 1, hoverIndex));

            if (hoverIndex != _dragCurrentIndex && (NSUInteger)_dragCurrentIndex < itemsList.count && (NSUInteger)hoverIndex < itemsList.count) {
                if (isUQ) {
                    [[SGRQueueSession shared] moveUserQueuedItemFromIndex:(NSUInteger)_dragCurrentIndex toIndex:(NSUInteger)hoverIndex];
                } else {
                    [[SGRQueueSession shared] moveContinuePlayingItemFromIndex:(NSUInteger)_dragCurrentIndex toIndex:(NSUInteger)hoverIndex];
                }
                SGRQueueItem *movedItem = itemsList[(NSUInteger)_dragCurrentIndex];
                [itemsList removeObjectAtIndex:(NSUInteger)_dragCurrentIndex];
                [itemsList insertObject:movedItem atIndex:(NSUInteger)hoverIndex];

                [rowViews removeObjectAtIndex:(NSUInteger)_dragCurrentIndex];
                [rowViews insertObject:_draggingRow atIndex:(NSUInteger)hoverIndex];

                _dragCurrentIndex = hoverIndex;
                UISelectionFeedbackGenerator *sel = [[UISelectionFeedbackGenerator alloc] init];
                [sel selectionChanged];

                [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                    for (NSUInteger i = 0; i < rowViews.count; i++) {
                        SGRQueueRowView *r = rowViews[i];
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
            [[SGRQueueSession shared] commitContinuePlayingReorder];
            break;
        }
        default:
            break;
    }
}

#pragma mark - Long-Press Context Menu & Preview Card

- (UIViewController *)previewControllerForItem:(SGRQueueItem *)item artImage:(UIImage *)artImage {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
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
    l1.font = SGRQueueFont(15.0, UIFontWeightSemibold);
    l1.textColor = UIColor.whiteColor;
    [vc.view addSubview:l1];

    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(82.0, 35.0, 140.0, 17.0)];
    l2.text = item.artist ?: @"";
    l2.font = SGRQueueFont(13.5, UIFontWeightRegular);
    l2.textColor = [UIColor colorWithWhite:1.0 alpha:0.90];
    [vc.view addSubview:l2];

    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(82.0, 52.0, 140.0, 16.0)];
    l3.text = item.albumTitle ?: @"";
    l3.font = SGRQueueFont(13.0, UIFontWeightRegular);
    l3.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    [vc.view addSubview:l3];

    UIImageSymbolConfiguration *chevCfg = [UIImageSymbolConfiguration configurationWithPointSize:12.5 weight:UIImageSymbolWeightSemibold];
    UIImageView *chev = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"chevron.right" withConfiguration:chevCfg] imageWithTintColor:[UIColor colorWithWhite:1.0 alpha:0.42] renderingMode:UIImageRenderingModeAlwaysOriginal]];
    chev.frame = CGRectMake(cardW - 22.0, (cardH - 14.0) * 0.5, 10.0, 14.0);
    chev.contentMode = UIViewContentModeScaleAspectFit;
    [vc.view addSubview:chev];

    return vc;
}

- (void)enqueueMenuItem:(SGRQueueItem *)item resolvedTrack:(SPTPlayerTrack *)resolvedTrack playNext:(BOOL)playNext {
    [[SGRQueueSession shared] optimisticallyInsertUserQueuedItem:item playNext:playNext];
    if (!resolvedTrack) return;
    id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
    Class wrapperCls = NSClassFromString(@"SPTPlayerQueueWrapperImpl");
    SEL queueSel = playNext ? @selector(queueTrackPlayNext:) : @selector(queueTrack:);
    if (player && [wrapperCls instancesRespondToSelector:@selector(initWithPlayer:)] && [wrapperCls instancesRespondToSelector:queueSel]) {
        SGRQueueWrapper *wrapper = [[wrapperCls alloc] initWithPlayer:player];
        if (playNext) {
            [wrapper queueTrackPlayNext:resolvedTrack];
        } else {
            [wrapper queueTrack:resolvedTrack];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[SGRQueueSession shared] invalidateUncappedStateAndRefetch];
        });
    }
}

- (UIMenu *)buildAppleMusicMenuForItem:(SGRQueueItem *)item row:(SGRQueueRowView *)row {
    if (!item) return nil;
    NSString *albumTitle = item.albumTitle ?: @"";
    NSString *albumURI = item.albumURI ?: @"";
    NSString *artistURI = item.artistURI ?: @"";
    NSString *artistName = item.artist ?: @"";
    NSString *trackURI = item.uri ?: @"";
    BOOL isSaved = [[SGRQueueSession shared] isTrackSaved:trackURI];
    SPTPlayerTrack *resolvedTrack = [item resolvedPlayerTrack];

    __weak typeof(self) weakSelf = self;

    UIAction *likeAct = [UIAction actionWithTitle:isSaved ? @"Liked" : @"Like"
                                            image:[UIImage systemImageNamed:isSaved ? @"heart.fill" : @"heart"]
                                       identifier:nil
                                          handler:^(__unused __kindof UIAction *action) {
        [[SGRQueueSession shared] setTrackURI:trackURI saved:!isSaved];
    }];

    UIAction *playNextAct = [UIAction actionWithTitle:@"Play Next"
                                                image:[UIImage systemImageNamed:@"text.line.first.and.arrowtriangle.forward"]
                                           identifier:nil
                                              handler:^(__unused __kindof UIAction *action) {
        [weakSelf enqueueMenuItem:item resolvedTrack:resolvedTrack playNext:YES];
    }];

    UIAction *shareAct = [UIAction actionWithTitle:@"Share"
                                             image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                        identifier:nil
                                           handler:^(__unused __kindof UIAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !trackURI.length) return;
        UIViewController *top = strongSelf.window.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        if (top) {
            id shareItem = SGRShareItemForSpotifyURI(trackURI);
            UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[shareItem] applicationActivities:nil];
            avc.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            avc.popoverPresentationController.sourceView = row ?: strongSelf;
            avc.popoverPresentationController.sourceRect = row ? row.bounds : strongSelf.bounds;
            SGPresentDark(avc);
            [top presentViewController:avc animated:YES completion:nil];
        }
    }];

    UIMenu *topRowMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[likeAct, playNextAct, shareAct]];
    if (@available(iOS 16.0, *)) {
        topRowMenu.preferredElementSize = UIMenuElementSizeMedium;
    }

    NSMutableArray<UIMenuElement *> *mainActions = [NSMutableArray array];

    UIAction *addToQueueAct = [UIAction actionWithTitle:@"Add to Queue"
                                                  image:[UIImage systemImageNamed:@"text.line.last.and.arrowtriangle.forward"]
                                             identifier:nil
                                                handler:^(__unused __kindof UIAction *action) {
        [weakSelf enqueueMenuItem:item resolvedTrack:resolvedTrack playNext:NO];
    }];
    [mainActions addObject:addToQueueAct];

    if (row && !row.isHistory && row.rowIndex > 0) {
        UIAction *moveTopAct = [UIAction actionWithTitle:@"Move to the Top"
                                                   image:[UIImage systemImageNamed:@"arrow.up.to.line"]
                                              identifier:nil
                                                 handler:^(__unused __kindof UIAction *action) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            BOOL isUQ = row.isUserQueue;
            NSMutableArray<SGRQueueRowView *> *rowViews = isUQ ? strongSelf->_userQueueRowViews : strongSelf->_queueRowViews;
            NSMutableArray<SGRQueueItem *> *itemsList = isUQ ? strongSelf->_userQueueItems : strongSelf->_futureItems;
            NSUInteger idx = [rowViews indexOfObject:row];
            if (idx != NSNotFound && idx > 0 && idx < itemsList.count) {
                if (isUQ) {
                    [[SGRQueueSession shared] moveUserQueuedItemFromIndex:idx toIndex:0];
                } else {
                    [[SGRQueueSession shared] moveContinuePlayingItemFromIndex:idx toIndex:0];
                }
                [[SGRQueueSession shared] commitContinuePlayingReorder];
                SGRQueueItem *t = itemsList[idx];
                [itemsList removeObjectAtIndex:idx];
                [itemsList insertObject:t atIndex:0];
                [rowViews removeObjectAtIndex:idx];
                [rowViews insertObject:row atIndex:0];
                [UIView animateWithDuration:0.30 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
                    for (NSUInteger i = 0; i < rowViews.count; i++) {
                        rowViews[i].rowIndex = (NSInteger)i;
                        rowViews[i].frame = CGRectMake(0.0, i * kQueueRowPitch, strongSelf.bounds.size.width, kQueueRowPitch);
                    }
                } completion:nil];
            }
        }];
        [mainActions addObject:moveTopAct];
    }

    if (albumURI.length) {
        UIAction *goAlbumAct = [UIAction actionWithTitle:@"Go to Album"
                                                   image:[UIImage systemImageNamed:@"square.stack"]
                                              identifier:nil
                                                 handler:^(__unused __kindof UIAction *action) {
            SGRPlayerMinimizeIfOpen();
            SGOpenSpotifyURI([NSURL URLWithString:albumURI]);
        }];
        if (@available(iOS 15.0, *)) {
            if (albumTitle.length) goAlbumAct.subtitle = albumTitle;
        }
        [mainActions addObject:goAlbumAct];
    }

    if (artistURI.length) {
        UIAction *goArtistAct = [UIAction actionWithTitle:@"Go to Artist"
                                                    image:[UIImage systemImageNamed:@"music.mic"]
                                               identifier:nil
                                                  handler:^(__unused __kindof UIAction *action) {
            SGRPlayerMinimizeIfOpen();
            SGOpenSpotifyURI([NSURL URLWithString:artistURI]);
        }];
        if (@available(iOS 15.0, *)) {
            if (artistName.length) goArtistAct.subtitle = artistName;
        }
        [mainActions addObject:goArtistAct];
    }

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

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    for (NSUInteger i = 0; i < 4; i++) {
        if (interaction.view == _pillButtons[i]) {
            if (_pillButtons[i].showsMenuAsPrimaryAction) return nil;
            NSUInteger slot = i;
            __weak typeof(self) weakSelf = self;
            return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(__unused NSArray<UIMenuElement *> *suggested) {
                return [weakSelf customizeMenuForPillSlot:slot];
            }];
        }
    }

    if (interaction.view == _nowPlayingCard) {
        CGPoint ptInDetails = [_nowPlayingCard convertPoint:location toView:_npDetailsView];
        if (CGRectContainsPoint(CGRectInset(_npMoreButton.frame, -10.0, -10.0), ptInDetails)) {
            return nil;
        }
        if (!_currentItem) return nil;
        __weak typeof(self) weakSelf = self;
        return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:^UIViewController * _Nullable{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return nil;
            return [strongSelf previewControllerForItem:strongSelf->_currentItem artImage:strongSelf->_npArtView.image];
        } actionProvider:^UIMenu * _Nullable(__unused NSArray<UIMenuElement *> *suggestedActions) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return nil;
            return [strongSelf buildAppleMusicMenuForItem:strongSelf->_currentItem row:nil];
        }];
    }
    return nil;
}

@end

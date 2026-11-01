// SponsorBlock API client, category metadata, and statistics persistence.
// Queries sponsor.ajay.app using a 4-character SHA-256 prefix of the podcast episode ID so the full
// episode URI is not sent in plaintext, then filters the returned entries locally.
#import <CommonCrypto/CommonDigest.h>
#import "SGSponsorBlockAPI.h"
#import "SGSponsorBlock.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"

static NSString *const kSponsorBlockEndpoint = @"https://sponsor.ajay.app/api/skipSegments";
static NSString *const kCategoryActionKeyPrefix = @"spotifyglass.sponsorblock.cat.";
static NSString *const kCategoryColorKeyPrefix  = @"spotifyglass.sponsorblock.color.";

@implementation SGSponsorBlockSegment

- (instancetype)initWithUUID:(NSString *)uuid category:(NSString *)category startTime:(double)start endTime:(double)end {
    if (!(self = [super init])) return nil;
    _uuid = [uuid copy] ?: @"";
    _category = [category copy] ?: @"sponsor";
    _startTime = start;
    _endTime = end;
    _duration = MAX(0.0, end - start);
    return self;
}

@end

@interface SGSponsorBlockCategoryInfo ()
- (instancetype)initWithID:(NSString *)identifier
               displayName:(NSString *)displayName
             settingsTitle:(NSString *)settingsTitle
                   summary:(NSString *)summary
             defaultAction:(SGSponsorBlockAction)defaultAction
           defaultColorRGB:(NSInteger)defaultColorRGB;
@end

@implementation SGSponsorBlockCategoryInfo

- (instancetype)initWithID:(NSString *)identifier
               displayName:(NSString *)displayName
             settingsTitle:(NSString *)settingsTitle
                   summary:(NSString *)summary
             defaultAction:(SGSponsorBlockAction)defaultAction
           defaultColorRGB:(NSInteger)defaultColorRGB {
    if (!(self = [super init])) return nil;
    _identifier = [identifier copy];
    _displayName = [displayName copy];
    _settingsTitle = [settingsTitle copy];
    _summary = [summary copy];
    _defaultAction = defaultAction;
    _defaultColorRGB = defaultColorRGB;
    return self;
}

@end

NSArray<SGSponsorBlockCategoryInfo *> *SGSponsorBlockAllCategories(void) {
    static NSArray<SGSponsorBlockCategoryInfo *> *categories;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        categories = @[
            [[SGSponsorBlockCategoryInfo alloc] initWithID:@"sponsor"
                                               displayName:@"Sponsor"
                                             settingsTitle:@"Sponsors"
                                                   summary:@"Paid promotions, referrals, and product reads"
                                             defaultAction:SGSponsorBlockActionSkip
                                           defaultColorRGB:0x00D400],
            [[SGSponsorBlockCategoryInfo alloc] initWithID:@"selfpromo"
                                               displayName:@"Self-Promo"
                                             settingsTitle:@"Self-promotion"
                                                   summary:@"Merchandise, companion shows, and social links"
                                             defaultAction:SGSponsorBlockActionSkip
                                           defaultColorRGB:0xFFFF00],
            [[SGSponsorBlockCategoryInfo alloc] initWithID:@"interaction"
                                               displayName:@"Interaction"
                                             settingsTitle:@"Interaction reminders"
                                                   summary:@"Prompts to follow, rate, or subscribe"
                                             defaultAction:SGSponsorBlockActionSkip
                                           defaultColorRGB:0xCC00FF],
            [[SGSponsorBlockCategoryInfo alloc] initWithID:@"intro"
                                               displayName:@"Intro"
                                             settingsTitle:@"Intros & recaps"
                                                   summary:@"Opening sequences, theme music, and recaps"
                                             defaultAction:SGSponsorBlockActionPrompt
                                           defaultColorRGB:0x00FFFF],
            [[SGSponsorBlockCategoryInfo alloc] initWithID:@"outro"
                                               displayName:@"Outro"
                                             settingsTitle:@"Outros & credits"
                                                   summary:@"Closing credits, end music, and supporter lists"
                                             defaultAction:SGSponsorBlockActionPrompt
                                           defaultColorRGB:0x0202ED],
            [[SGSponsorBlockCategoryInfo alloc] initWithID:@"preview"
                                               displayName:@"Preview"
                                             settingsTitle:@"Previews & teasers"
                                                   summary:@"Upcoming episode previews and clips"
                                             defaultAction:SGSponsorBlockActionPrompt
                                           defaultColorRGB:0x008FD6],
            [[SGSponsorBlockCategoryInfo alloc] initWithID:@"hook"
                                               displayName:@"Hook"
                                             settingsTitle:@"Hooks"
                                                   summary:@"Cold opens and teasers before the intro"
                                             defaultAction:SGSponsorBlockActionPrompt
                                           defaultColorRGB:0x395699],
            [[SGSponsorBlockCategoryInfo alloc] initWithID:@"filler"
                                               displayName:@"Filler"
                                             settingsTitle:@"Filler & tangents"
                                                   summary:@"Off-topic banter and tangents"
                                             defaultAction:SGSponsorBlockActionPrompt
                                           defaultColorRGB:0x7300FF],
            [[SGSponsorBlockCategoryInfo alloc] initWithID:@"exclusive_access"
                                               displayName:@"Exclusive"
                                             settingsTitle:@"Exclusive access"
                                                   summary:@"Bonus previews and subscriber-only pitches"
                                             defaultAction:SGSponsorBlockActionPrompt
                                           defaultColorRGB:0x008A5C],
        ];
    });
    return categories;
}

SGSponsorBlockCategoryInfo *SGSponsorBlockInfoForCategory(NSString *category) {
    if (!category.length) return nil;
    for (SGSponsorBlockCategoryInfo *info in SGSponsorBlockAllCategories()) {
        if ([info.identifier isEqualToString:category]) return info;
    }
    return nil;
}

NSString *SGSponsorBlockCategoryDisplayName(NSString *category) {
    return SGSponsorBlockInfoForCategory(category).displayName ?: @"Sponsor";
}

UIColor *SGSponsorBlockCategoryColor(NSString *category) {
    SGSponsorBlockCategoryInfo *info = SGSponsorBlockInfoForCategory(category);
    NSInteger fallback = info ? info.defaultColorRGB : 0x00D400;
    NSString *key = [kCategoryColorKeyPrefix stringByAppendingString:category ?: @"sponsor"];
    NSInteger rgb = SGInt(key, fallback);
    if (rgb < 0 || rgb > 0xFFFFFF) rgb = fallback;
    return SGColorRGB(rgb);
}

SGSponsorBlockAction SGSponsorBlockActionForCategory(NSString *category) {
    SGSponsorBlockCategoryInfo *info = SGSponsorBlockInfoForCategory(category);
    if (!info) return SGSponsorBlockActionOff;
    NSInteger val = SGInt([kCategoryActionKeyPrefix stringByAppendingString:info.identifier], info.defaultAction);
    if (val < SGSponsorBlockActionOff || val > SGSponsorBlockActionShowOnly) return info.defaultAction;
    return (SGSponsorBlockAction)val;
}

void SGSponsorBlockSetActionForCategory(NSString *category, SGSponsorBlockAction action) {
    if (!category.length) return;
    SGSetInt([kCategoryActionKeyPrefix stringByAppendingString:category], action);
}

void SGSponsorBlockResetCategoriesToDefaults(void) {
    for (SGSponsorBlockCategoryInfo *info in SGSponsorBlockAllCategories()) {
        SGSetInt([kCategoryActionKeyPrefix stringByAppendingString:info.identifier], info.defaultAction);
    }
}

NSUInteger SGSponsorBlockActiveCategoryCount(void) {
    NSUInteger count = 0;
    for (SGSponsorBlockCategoryInfo *info in SGSponsorBlockAllCategories()) {
        if (SGSponsorBlockActionForCategory(info.identifier) != SGSponsorBlockActionOff) count++;
    }
    return count;
}

#pragma mark - durations & statistics

double SGSponsorBlockMinDuration(void) {
    NSNumber *num = [NSUserDefaults.standardUserDefaults objectForKey:SGKeySponsorBlockMinDuration];
    if (![num isKindOfClass:NSNumber.class]) return 0.0;
    return MAX(0.0, MIN(10.0, num.doubleValue));
}

void SGSponsorBlockSetMinDuration(double duration) {
    double clamped = round(MAX(0.0, MIN(10.0, duration)) * 2.0) / 2.0;
    SGPrefsWriteUnmemoized(^{
        [NSUserDefaults.standardUserDefaults setDouble:clamped forKey:SGKeySponsorBlockMinDuration];
    });
}

NSTimeInterval SGSponsorBlockToastDuration(void) {
    NSInteger val = SGInt(SGKeySponsorBlockToastDuration, 4);
    return (NSTimeInterval)MAX(2, MIN(10, val));
}

void SGSponsorBlockSetToastDuration(NSTimeInterval duration) {
    SGSetInt(SGKeySponsorBlockToastDuration, MAX(2, MIN(10, lround(duration))));
}

NSTimeInterval SGSponsorBlockPromptDuration(void) {
    NSInteger val = SGInt(SGKeySponsorBlockPromptDuration, 8);
    if (val <= 0 || val >= (NSInteger)SGSponsorBlockPromptDurationInfinite) return SGSponsorBlockPromptDurationInfinite;
    return (NSTimeInterval)MAX(3, val);
}

void SGSponsorBlockSetPromptDuration(NSTimeInterval duration) {
    NSInteger rounded = lround(duration);
    if (rounded >= (NSInteger)SGSponsorBlockPromptDurationInfinite) {
        SGSetInt(SGKeySponsorBlockPromptDuration, (NSInteger)SGSponsorBlockPromptDurationInfinite);
    } else {
        SGSetInt(SGKeySponsorBlockPromptDuration, MAX(3, rounded));
    }
}

NSInteger SGSponsorBlockSkipCount(void) {
    return MAX(0, [NSUserDefaults.standardUserDefaults integerForKey:SGKeySponsorBlockSkipCount]);
}

double SGSponsorBlockTimeSaved(void) {
    return MAX(0.0, [NSUserDefaults.standardUserDefaults doubleForKey:SGKeySponsorBlockTimeSaved]);
}

void SGRecordSponsorBlockSkip(double secondsSaved) {
    if (secondsSaved <= 0) return;
    SGPrefsWriteUnmemoized(^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setInteger:SGSponsorBlockSkipCount() + 1 forKey:SGKeySponsorBlockSkipCount];
        [defaults setDouble:SGSponsorBlockTimeSaved() + secondsSaved forKey:SGKeySponsorBlockTimeSaved];
    });
}

void SGUndoSponsorBlockSkip(double secondsSaved) {
    SGPrefsWriteUnmemoized(^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setInteger:MAX(0, SGSponsorBlockSkipCount() - 1) forKey:SGKeySponsorBlockSkipCount];
        [defaults setDouble:MAX(0.0, SGSponsorBlockTimeSaved() - MAX(0.0, secondsSaved)) forKey:SGKeySponsorBlockTimeSaved];
    });
}

void SGResetSponsorBlockStats(void) {
    SGPrefsWriteUnmemoized(^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults removeObjectForKey:SGKeySponsorBlockSkipCount];
        [defaults removeObjectForKey:SGKeySponsorBlockTimeSaved];
    });
}

NSString *SGFormatSponsorBlockDuration(double seconds) {
    NSInteger total = (NSInteger)llround(MAX(0.0, seconds));
    if (total < 60) return [NSString stringWithFormat:@"%ld s", (long)total];
    NSInteger mins = total / 60;
    NSInteger secs = total % 60;
    if (mins < 60) {
        return secs > 0 ? [NSString stringWithFormat:@"%ldm %lds", (long)mins, (long)secs]
                        : [NSString stringWithFormat:@"%ldm", (long)mins];
    }
    NSInteger hours = mins / 60;
    mins %= 60;
    return mins > 0 ? [NSString stringWithFormat:@"%ldh %ldm", (long)hours, (long)mins]
                    : [NSString stringWithFormat:@"%ldh", (long)hours];
}

#pragma mark - segment lookup

static NSCache<NSString *, NSArray<SGSponsorBlockSegment *> *> *segmentCache(void) {
    static NSCache<NSString *, NSArray<SGSponsorBlockSegment *> *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 128;
    });
    return cache;
}

void SGInvalidateSponsorBlockCache(void) {
    [segmentCache() removeAllObjects];
}

static NSString *sha256Prefix4(NSString *input) {
    const char *utf8 = input.UTF8String;
    if (!utf8) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(utf8, (CC_LONG)strlen(utf8), digest);
    return [NSString stringWithFormat:@"%02x%02x", digest[0], digest[1]];
}

static NSURLSession *apiSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 8.0;
        config.timeoutIntervalForResource = 12.0;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": [NSString stringWithFormat:@"Vitrine/%s (iOS)", SG_VERSION],
            @"Accept": @"application/json",
        };
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

static NSArray<SGSponsorBlockSegment *> *parseSegments(id json, NSString *episodeID) {
    if (![json isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<SGSponsorBlockSegment *> *parsed = [NSMutableArray array];
    NSMutableSet<NSString *> *seenUUIDs = [NSMutableSet set];

    for (NSDictionary *entry in (NSArray *)json) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *videoID = entry[@"videoID"];
        if (![videoID isKindOfClass:NSString.class]) continue;
        if (![videoID isEqualToString:episodeID] && ![videoID isEqualToString:[@"spotify:episode:" stringByAppendingString:episodeID]]) {
            continue;
        }
        NSArray *segArray = entry[@"segments"];
        if (![segArray isKindOfClass:NSArray.class]) continue;

        for (NSDictionary *item in segArray) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSArray *bounds = item[@"segment"];
            if (![bounds isKindOfClass:NSArray.class] || bounds.count < 2) continue;
            if (![bounds[0] respondsToSelector:@selector(doubleValue)] || ![bounds[1] respondsToSelector:@selector(doubleValue)]) continue;
            double start = [bounds[0] doubleValue];
            double end = [bounds[1] doubleValue];
            if (end <= start || start < 0) continue;

            NSString *category = [item[@"category"] isKindOfClass:NSString.class] ? item[@"category"] : @"sponsor";
            NSString *uuid = [item[@"UUID"] isKindOfClass:NSString.class] ? item[@"UUID"]
                           : [NSString stringWithFormat:@"%@:%.2f-%.2f", category, start, end];
            if ([seenUUIDs containsObject:uuid]) continue;
            [seenUUIDs addObject:uuid];
            [parsed addObject:[[SGSponsorBlockSegment alloc] initWithUUID:uuid category:category startTime:start endTime:end]];
        }
    }

    [parsed sortUsingComparator:^NSComparisonResult(SGSponsorBlockSegment *a, SGSponsorBlockSegment *b) {
        if (a.startTime < b.startTime) return NSOrderedAscending;
        if (a.startTime > b.startTime) return NSOrderedDescending;
        if (a.endTime > b.endTime) return NSOrderedAscending;
        if (a.endTime < b.endTime) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return [parsed copy];
}

void SGFetchSponsorBlockSegments(NSString *episodeID, void (^completion)(NSArray<SGSponsorBlockSegment *> *segments, NSError *error)) {
    if (!episodeID.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], nil); });
        return;
    }

    NSArray<SGSponsorBlockSegment *> *cached = [segmentCache() objectForKey:episodeID];
    if (cached) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, nil); });
        return;
    }

    NSString *prefix = sha256Prefix4(episodeID);
    if (!prefix) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], nil); });
        return;
    }

    static NSString *categoriesParam;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        for (SGSponsorBlockCategoryInfo *info in SGSponsorBlockAllCategories()) [ids addObject:info.identifier];
        NSData *json = [NSJSONSerialization dataWithJSONObject:ids options:0 error:nil];
        NSString *raw = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: @"[\"sponsor\"]";
        categoriesParam = [raw stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    });

    NSString *urlString = [NSString stringWithFormat:@"%@/%@?service=Spotify&categories=%@", kSponsorBlockEndpoint, prefix, categoriesParam];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], nil); });
        return;
    }

    [[apiSession() dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (http.statusCode == 404) {
            [segmentCache() setObject:@[] forKey:episodeID];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], nil); });
            return;
        }
        if (error || http.statusCode != 200 || !data.length) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray<SGSponsorBlockSegment *> *segments = parseSegments(json, episodeID);
        [segmentCache() setObject:segments forKey:episodeID];
        SGLog(@"sponsorblock: %lu segment(s) for %@", (unsigned long)segments.count, episodeID);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(segments, nil); });
    }] resume];
}

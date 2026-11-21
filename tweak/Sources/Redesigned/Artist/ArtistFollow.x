// Whether the user follows the page's artist, read from Spotify's collection state (following saves the
// artist to the collection) rather than the Follow button, whose only state is its localized title.
// The provider is the one Spotify's own code uses, kept weakly.
#import <os/lock.h>
#import "Core/SGCore.h"
#import "Artist.h"

@protocol SGRCollectionState <NSObject>
+ (id)saved;
- (BOOL)contains:(id)state;
- (NSInteger)rawValue;
@end

@protocol SGRCollectionStateProvider <NSObject>
- (id)subscribeCollectionStateForURL:(NSURL *)url completion:(void (^)(id state, NSError *error))completion;
@end

@protocol SGRCollectionPlatform <NSObject>
- (void)addURL:(NSURL *)url showUIConfirmation:(BOOL)show completion:(id)completion;
- (void)removeURL:(NSURL *)url showUIConfirmation:(BOOL)show completion:(id)completion;
- (id)stateProvider;
@end

static __weak id sg_provider;
// Guards sg_provider, sg_platform and keepProvider's `logged`; a lock of this file's own, so Spotify's threads
// binding rows never queue behind another file's.
static os_unfair_lock sg_providerLock = OS_UNFAIR_LOCK_INIT;

// Called from wherever Spotify reaches for its provider, any thread.
static void keepProvider(id provider) {
    if (!provider || ![provider respondsToSelector:@selector(subscribeCollectionStateForURL:completion:)]) return;
    // Nearly every call brings the provider already kept; a weak load is atomic, and the lock below decides.
    if (provider == sg_provider) return;
    static NSMutableSet<NSString *> *logged;
    NSString *name = nil;
    os_unfair_lock_lock(&sg_providerLock);
    if (provider != sg_provider) {
        sg_provider = provider;
        if (!logged) logged = [NSMutableSet set];
        name = NSStringFromClass([provider class]);
        if ([logged containsObject:name]) name = nil;
        else [logged addObject:name];
    }
    os_unfair_lock_unlock(&sg_providerLock);
    if (name) SGLog(@"redesign artist: collection state from %@", name);
}

static __weak id sg_platform;

static void keepPlatform(id platform) {
    if (!platform || ![platform respondsToSelector:@selector(addURL:showUIConfirmation:completion:)]) return;
    if (platform == sg_platform) return;
    os_unfair_lock_lock(&sg_providerLock);
    sg_platform = platform;
    os_unfair_lock_unlock(&sg_providerLock);
}

static id currentPlatform(void) {
    os_unfair_lock_lock(&sg_providerLock);
    id platform = sg_platform;
    os_unfair_lock_unlock(&sg_providerLock);
    return platform;
}

static id currentProvider(void) {
    os_unfair_lock_lock(&sg_providerLock);
    id provider = sg_provider;
    id platform = sg_platform;
    os_unfair_lock_unlock(&sg_providerLock);
    if (!provider && [platform respondsToSelector:@selector(stateProvider)]) {
        provider = [(id<SGRCollectionPlatform>)platform stateProvider];
        keepProvider(provider);
    }
    return provider;
}

%hook SPTCollectionPlatformImplementation
- (id)initWithCosmosDataLoader:(id)loader isGatedEntityRelationsEnabled:(BOOL)gated {
    id platform = %orig;
    keepPlatform(platform);
    return platform;
}
- (id)stateProvider {
    keepPlatform(self);
    id provider = %orig;
    keepProvider(provider);
    return provider;
}
%end

%hook _TtC23Collection_PlatformImpl22CollectionPlatformImpl
- (id)stateProvider {
    keepPlatform(self);
    id provider = %orig;
    keepProvider(provider);
    return provider;
}
%end

%hook _TtC23Collection_PlatformImpl27CollectionPlatformMigration
- (id)stateProvider {
    keepPlatform(self);
    id provider = %orig;
    keepProvider(provider);
    return provider;
}
%end

%hook _TtC26AlignedCuration_CommonImpl21ACUCollectionPlatform
- (id)stateProvider {
    keepPlatform(self);
    id provider = %orig;
    keepProvider(provider);
    return provider;
}
%end

%hook _TtC23Collection_PlatformImpl35CollectionPlatformStateProviderImpl
- (id)subscribeCollectionStateForURL:(id)url completion:(id)completion {
    keepProvider(self);
    return %orig;
}
- (id)subscribeCollectionStateForURLs:(id)urls completion:(id)completion {
    keepProvider(self);
    return %orig;
}
- (id)subscribeCollectionStateForURL:(id)url inContextURL:(id)context completion:(id)completion {
    keepProvider(self);
    return %orig;
}
- (id)subscribeCollectionStateForURLs:(id)urls inContextURL:(id)context completion:(id)completion {
    keepProvider(self);
    return %orig;
}
%end

%hook _TtC26AlignedCuration_CommonImpl25ACUEsperantoStateProvider
- (id)subscribeCollectionStateForURL:(id)url completion:(id)completion {
    keepProvider(self);
    return %orig;
}
- (id)subscribeCollectionStateForURLs:(id)urls completion:(id)completion {
    keepProvider(self);
    return %orig;
}
- (id)subscribeCollectionStateForURL:(id)url inContextURL:(id)context completion:(id)completion {
    keepProvider(self);
    return %orig;
}
- (id)subscribeCollectionStateForURLs:(id)urls inContextURL:(id)context completion:(id)completion {
    keepProvider(self);
    return %orig;
}
%end

// The Follow element asks Curation's provider, which wraps the collection one.
%hook _TtC21Curation_PlatformImpl30CUPStateProviderImplementation
- (id)subscribeCollectionStateForURL:(id)url inContext:(id)context completion:(id)completion {
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "collectionPlatformStateProvider");
    if (ivar) keepProvider(object_getIvar(self, ivar));
    return %orig;
}
%end

#pragma mark - one subscription per page

// Held by the page, so the subscription ends with it.
@interface SGRFollowWatch : NSObject
@property (nonatomic, copy) NSURL *uri;
@property (nonatomic, strong) id token;
@property (nonatomic) BOOL subscribed;
@property (nonatomic) NSInteger following;   // -1 until the first state arrives
@property (nonatomic, copy) void (^changed)(void);
@end

@implementation SGRFollowWatch
- (void)dealloc {
    if ([_token respondsToSelector:@selector(cancel)]) [_token cancel];
}
@end

static char kWatchKey;

// The artist the page is for. The artist page's controllers carry no URI, but the header's ⋯ does:
// Components.UI.ContextMenuButton-<artist id>.
static NSURL *artistURI(UIView *page, NSString *moreIdentifier) {
    for (UIResponder *responder = page; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class] || ![responder respondsToSelector:@selector(spt_pageURI)]) continue;
        id uri = [(id)responder performSelector:@selector(spt_pageURI)];
        if ([uri isKindOfClass:NSURL.class] && [[uri absoluteString] hasPrefix:@"spotify:artist:"]) return uri;
    }
    NSString *prefix = @"Components.UI.ContextMenuButton-";
    if (![moreIdentifier hasPrefix:prefix]) return nil;
    NSString *identifier = [moreIdentifier substringFromIndex:prefix.length];
    NSCharacterSet *base62 = [NSCharacterSet alphanumericCharacterSet].invertedSet;
    if (identifier.length != 22 || [identifier rangeOfCharacterFromSet:base62].location != NSNotFound) return nil;
    return [NSURL URLWithString:[@"spotify:artist:" stringByAppendingString:identifier]];
}

static void subscribe(SGRFollowWatch *watch, id provider) {
    Class stateClass = NSClassFromString(@"SPTCollectionPlatformState");
    if (![stateClass respondsToSelector:@selector(saved)]) return;
    id saved = [(Class<SGRCollectionState>)stateClass saved];
    __weak SGRFollowWatch *weakWatch = watch;
    NSURL *uri = watch.uri;
    watch.subscribed = YES;
    SGLog(@"redesign artist: follow subscribes for %@ on %@", uri.absoluteString, NSStringFromClass([provider class]));
    watch.token = [(id<SGRCollectionStateProvider>)provider subscribeCollectionStateForURL:uri completion:^(id state, NSError *error) {
        if (error || ![state respondsToSelector:@selector(contains:)]) {
            SGLog(@"redesign artist: follow state for %@ unreadable: %@ %@", uri.absoluteString, [state class], error);
            return;
        }
        NSInteger raw = [state respondsToSelector:@selector(rawValue)] ? [(id<SGRCollectionState>)state rawValue] : -1;
        BOOL following = [(id<SGRCollectionState>)state contains:saved];
        dispatch_async(dispatch_get_main_queue(), ^{
            SGRFollowWatch *current = weakWatch;
            if (!current || current.following == following) return;
            SGLog(@"redesign kit: follow state %ld for %@", (long)raw, uri.absoluteString);
            current.following = following;
            if (current.changed) current.changed();
        });
    }];
}

BOOL SGRArtistFollowing(UIView *page, NSString *moreIdentifier, BOOL *following, void (^changed)(void)) {
    if (!page) return NO;
    SGRFollowWatch *watch = objc_getAssociatedObject(page, &kWatchKey);
    if (!watch) {
        NSURL *uri = artistURI(page, moreIdentifier);
        if (!uri) {
            static __weak UIView *loggedPage;
            if (loggedPage != page) {
                loggedPage = page;
                SGLog(@"redesign artist: follow has no artist URI, more is %@", moreIdentifier);
            }
            return NO;
        }
        watch = [SGRFollowWatch new];
        watch.uri = uri;
        watch.following = -1;
        objc_setAssociatedObject(page, &kWatchKey, watch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    watch.changed = changed;
    id provider = watch.subscribed ? nil : currentProvider();
    if (provider) subscribe(watch, provider);
    if (watch.following < 0) return NO;
    if (following) *following = watch.following == 1;
    return YES;
}

@interface SGROneShotCollectionCheck : NSObject
@property (nonatomic, strong) id token;
@property (nonatomic) BOOL done;
- (void)cancel;
@end

@implementation SGROneShotCollectionCheck
- (void)cancel {
    if ([_token respondsToSelector:@selector(cancel)]) [_token cancel];
    _token = nil;
}
@end

BOOL SGRCollectionAddURL(NSURL *url, BOOL showConfirmation) {
    if (!url) return NO;
    id platform = currentPlatform();
    if (![platform respondsToSelector:@selector(addURL:showUIConfirmation:completion:)]) return NO;
    [(id<SGRCollectionPlatform>)platform addURL:url showUIConfirmation:showConfirmation completion:nil];
    return YES;
}

BOOL SGRCollectionRemoveURL(NSURL *url, BOOL showConfirmation) {
    if (!url) return NO;
    id platform = currentPlatform();
    if (![platform respondsToSelector:@selector(removeURL:showUIConfirmation:completion:)]) return NO;
    [(id<SGRCollectionPlatform>)platform removeURL:url showUIConfirmation:showConfirmation completion:nil];
    return YES;
}

void SGRCollectionCheckSaved(NSURL *url, void (^completion)(BOOL known, BOOL saved)) {
    if (!completion) return;
    id provider = url ? currentProvider() : nil;
    Class stateClass = NSClassFromString(@"SPTCollectionPlatformState");
    if (!url || !provider || ![stateClass respondsToSelector:@selector(saved)]) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, NO); });
        return;
    }
    id savedFlag = [(Class<SGRCollectionState>)stateClass saved];
    SGROneShotCollectionCheck *box = [SGROneShotCollectionCheck new];
    box.token = [(id<SGRCollectionStateProvider>)provider subscribeCollectionStateForURL:url completion:^(id state, NSError *error) {
        BOOL ok = (!error && [state respondsToSelector:@selector(contains:)]);
        BOOL isSaved = ok ? [(id<SGRCollectionState>)state contains:savedFlag] : NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (box.done) return;
            box.done = YES;
            [box cancel];
            completion(ok, isSaved);
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (box.done) return;
        box.done = YES;
        [box cancel];
        completion(NO, NO);
    });
}

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"SPTCollectionPlatformState", @"_TtC23Collection_PlatformImpl35CollectionPlatformStateProviderImpl"]);
}

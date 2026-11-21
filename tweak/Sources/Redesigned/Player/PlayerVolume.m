// Player redesign: a volume slider under the controls, as the Music app has. The row draws its own pill: it grows while
// held, its glyphs move out, a drag anywhere on the row moves the volume by the finger's travel, and VoiceOver steps it.
// Under it sits a hidden MPVolumeView whose slider the row reads and moves for this iPhone's volume; while a Connect
// device with volume support plays, the row and system volume follow Spotify's Connect volume instead. No route button:
// the footer's Connect glyph is the route.
//
// It sits in Spotify's bottom stack, outside its arranged views, between the controls and the footer row, so the
// lyrics fade it with the rest of the stack (PlayerLyrics.x) and its touches stay inside the stack. The footer's
// layout places it on every pass, and lowers the footer row to the bottom edge.

#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Player/PlayerEvents.h"
#import "Player.h"

// The row's height (the touch area) and the glyphs' point size and gap to the track.
static const CGFloat kRowHeight = 32, kGlyphSize = 13, kGlyphGap = 10;
// Half the footer glyphs' height: the row stops this far above their middle.
static const CGFloat kGlyphsHalf = 14;
// The track's height at rest and held, how far it grows past each end, how far the glyphs move out and by how much they
// scale (each clamped to the room the row has on that side). Music's own held numbers are 18, 7, 9 and 1.08.
static const CGFloat kTrackRest = 7, kTrackHeld = 12, kStretch = 5, kGlyphShift = 6, kGlyphHeldScale = 1.02;
// White's opacity: the fill at rest and held, the empty part, the glyphs at rest (held they are full white).
static const CGFloat kFillRest = 0.65, kFillHeld = 1, kEmpty = 0.16, kGlyphRest = 0.62;

static char kSessionContext;
static atomic_bool s_connectActive;

@protocol SGRConnectEntity <NSObject>
- (BOOL)isSelf;
- (BOOL)isVolumeSupported;
- (NSString *)connectStateIdentifier;
- (NSString *)localIdentifier;
@end

@protocol SGRConnectAggregator <NSObject>
- (id)activeConnectEntity;
- (BOOL)isPlayingRemotely;
@end

@protocol SGRConnectVolume <NSObject>
- (double)connectVolume;
- (void)add:(id)observer;
- (void)setVolume:(double)volume reason:(NSString *)reason;
@optional
- (void)remove:(id)observer;
@end

@class SGRVolumeRow;

static void onMain(dispatch_block_t block) {
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static UIWindow *activeWindow(void) {
    UIWindow *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.windowLevel != UIWindowLevelNormal) continue;
            if (!best || window.isKeyWindow) best = window;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return best ?: UIApplication.sharedApplication.keyWindow ?: UIApplication.sharedApplication.windows.firstObject;
#pragma clang diagnostic pop
}

@interface SGRVolumeRow : UIControl
// The footer row it was last placed against, for the stack's layout. Weak: the stack owns it.
@property (nonatomic, weak) UIView *footer;
@property (nonatomic, readonly, getter=isHeld) BOOL held;
- (UISlider *)systemSlider;
- (UISlider *)liveSystemSliderInWindow:(UIWindow *)window;
- (void)systemSliderSet;
- (void)connectVolumeChanged:(CGFloat)value;
- (void)connectEntityChanged;
- (void)refreshFromSystem;
- (void)refreshTo:(CGFloat)system;
- (void)setValue:(CGFloat)value fromUser:(BOOL)fromUser;
@end

// Coordinates Spotify's Connect volume service with AVAudioSession KVO, system HUD/Control Center drags,
// and all live SGRVolumeRow instances. Lives on the main thread; notification/KVO callbacks hop via onMain().
@interface SGRConnectVolumeController : NSObject
+ (instancetype)shared;
- (id<SGRConnectEntity>)activeEntity;
- (BOOL)readVolume:(CGFloat *)out;
- (BOOL)readPendingLocalVolume:(CGFloat *)out;
- (BOOL)isPushPendingOrRecent;
- (void)setLocalPushTimestamp:(CFTimeInterval)time;
- (void)pushVolume:(CGFloat)target;
- (void)setSystemVolumeTo:(CGFloat)volume;
- (void)registerRow:(SGRVolumeRow *)row;
- (void)bindVolume:(id)volume;
- (void)bindAggregator:(id)aggregator;
- (void)entityChanged:(id)entity aggregator:(id)aggregator;
- (BOOL)isConnectActive;
@end

@implementation SGRConnectVolumeController {
    __weak id<SGRConnectVolume> _volume;
    __weak id<SGRConnectAggregator> _aggregator;
    __weak id<SGRConnectEntity> _entity;
    BOOL _explicitNilEntity;
    NSString *_deviceKey;

    CGFloat _cachedVolume;
    BOOL _hasConnectPropertyData;
    BOOL _usesRemoteSession;
    BOOL _wasBackgrounded;
    BOOL _didSyncSystemForConnect;
    CGFloat _savedLocalVolume;
    CGFloat _backgroundSystemVolume;

    CGFloat _priorSystemVolume;
    CFTimeInterval _priorSystemVolumeTime;
    CFTimeInterval _lastScrubTime;
    CFTimeInterval _lastRouteChange;
    CGFloat _expectedSystemVolume;
    CGFloat _prevExpectedSystemVolume;
    CFTimeInterval _lastSystemVolumeSet;

    CFTimeInterval _lastPushTime;
    CFTimeInterval _lastSentTime;
    CGFloat _pendingTarget;
    BOOL _pushScheduled;
    NSUInteger _pushGen;
    NSUInteger _settleGen;
    NSUInteger _syncDetachGen;

    MPVolumeView *_syncVolumeView;
    UISlider *_syncSlider;
    NSHashTable<SGRVolumeRow *> *_rows;
}

+ (void)initialize {
    if (self != SGRConnectVolumeController.class) return;
    Protocol *protocol = objc_getProtocol("SPTConnectVolumeObserver");
    if (protocol) class_addProtocol(self, protocol);
}

+ (instancetype)shared {
    static SGRConnectVolumeController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [SGRConnectVolumeController new]; });
    return controller;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _cachedVolume = -1;
    _savedLocalVolume = -1;
    _backgroundSystemVolume = -1;
    _expectedSystemVolume = -1;
    _prevExpectedSystemVolume = -1;
    _pendingTarget = -1;
    _rows = [NSHashTable weakObjectsHashTable];
    _priorSystemVolume = AVAudioSession.sharedInstance.outputVolume;

    [AVAudioSession.sharedInstance addObserver:self forKeyPath:@"outputVolume"
                                       options:NSKeyValueObservingOptionNew
                                       context:&kSessionContext];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(appDidEnterBackground)
                   name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(appDidBecomeActive)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(routeChanged:)
                   name:AVAudioSessionRouteChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [AVAudioSession.sharedInstance removeObserver:self forKeyPath:@"outputVolume" context:&kSessionContext];
}

- (void)registerRow:(SGRVolumeRow *)row {
    if (row) [_rows addObject:row];
}

- (void)clearExpectedSystemVolume {
    _expectedSystemVolume = -1;
    _prevExpectedSystemVolume = -1;
    _lastSystemVolumeSet = 0;
}

- (BOOL)readPendingLocalVolume:(CGFloat *)out {
    if ([self activeEntity] || _expectedSystemVolume < 0) return NO;
    if ((CACurrentMediaTime() - _lastSystemVolumeSet) >= 0.35) return NO;
    *out = _expectedSystemVolume;
    return YES;
}

- (id<SGRConnectEntity>)activeEntity {
    if (!_volume || _explicitNilEntity) return nil;
    id<SGRConnectAggregator> aggregator = _aggregator;
    id<SGRConnectEntity> entity = _entity
        ?: ([aggregator respondsToSelector:@selector(activeConnectEntity)] ? [aggregator activeConnectEntity] : nil);
    if (!entity) return nil;
    if ([entity respondsToSelector:@selector(isSelf)] && [entity isSelf]) return nil;
    if ([aggregator respondsToSelector:@selector(isPlayingRemotely)] && ![aggregator isPlayingRemotely]) return nil;
    if ([entity respondsToSelector:@selector(isVolumeSupported)] && ![entity isVolumeSupported]) return nil;
    return entity;
}

- (NSString *)activeDeviceKey {
    id<SGRConnectEntity> entity = [self activeEntity];
    if (!entity) return nil;
    if ([entity respondsToSelector:@selector(connectStateIdentifier)]) {
        NSString *identifier = [entity connectStateIdentifier];
        if (identifier.length) return identifier;
    }
    if ([entity respondsToSelector:@selector(localIdentifier)]) {
        NSString *identifier = [entity localIdentifier];
        if (identifier.length) return identifier;
    }
    return [NSString stringWithFormat:@"%p", entity];
}

- (BOOL)isConnectActive {
    BOOL active = ([self activeEntity] != nil);
    BOOL previous = atomic_load_explicit(&s_connectActive, memory_order_relaxed);
    if (active != previous) {
        [self syncDevice];
        active = ([self activeEntity] != nil);
    }
    atomic_store_explicit(&s_connectActive, active, memory_order_relaxed);
    return active;
}

- (BOOL)isPushPendingOrRecent {
    return _pushScheduled || (_lastPushTime > 0 && (CACurrentMediaTime() - _lastPushTime) < 0.6);
}

- (void)setLocalPushTimestamp:(CFTimeInterval)time {
    _lastPushTime = time;
}

- (BOOL)readVolume:(CGFloat *)out {
    if (![self activeEntity]) return NO;
    if (_cachedVolume >= 0) {
        *out = _cachedVolume;
        return YES;
    }
    if (![_volume respondsToSelector:@selector(connectVolume)]) return NO;
    double value = [_volume connectVolume];
    if (!isfinite(value)) return NO;
    CGFloat clamped = MIN(1, MAX(0, (CGFloat)value));
    if (clamped > 0 || _hasConnectPropertyData) {
        if (clamped > 0) _hasConnectPropertyData = YES;
        _cachedVolume = clamped;
        *out = clamped;
        return YES;
    }
    return NO;
}

- (void)setSystemVolumeTo:(CGFloat)volume {
    if (!isfinite(volume)) return;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    volume = MIN(1, MAX(0, volume));

    CGFloat currentSystem = AVAudioSession.sharedInstance.outputVolume;
    if (fabs(currentSystem - volume) <= 0.002 &&
        (_expectedSystemVolume < 0 || fabs(_expectedSystemVolume - volume) <= 0.002)) {
        return;
    }

    UIWindow *window = activeWindow();
    if (!window) return;

    UISlider *liveSlider = nil;
    if (SGPlayerIsOpen()) {
        for (SGRVolumeRow *row in _rows.allObjects) {
            UISlider *candidate = [row liveSystemSliderInWindow:window];
            if (candidate) {
                liveSlider = candidate;
                break;
            }
        }
    }

    UISlider *targetSlider = liveSlider;
    BOOL needsAttach = NO;
    if (!targetSlider) {
        if (!_syncVolumeView) {
            _syncVolumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 100, 100)];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            _syncVolumeView.showsRouteButton = NO;
#pragma clang diagnostic pop
            _syncVolumeView.userInteractionEnabled = NO;
            _syncVolumeView.accessibilityElementsHidden = YES;
            _syncVolumeView.alpha = 0.01;
        }

        needsAttach = (_syncVolumeView.superview != window);
        if (needsAttach) {
            _syncVolumeView.alpha = 0.01;
            [window addSubview:_syncVolumeView];
        }

        // _syncSlider is cached, but MPVolumeView can rebuild its slider after a route change.
        if (!_syncSlider || ![_syncVolumeView.subviews containsObject:_syncSlider]) {
            _syncSlider = nil;
            [_syncVolumeView setNeedsLayout];
            [_syncVolumeView layoutIfNeeded];
            for (UIView *view in _syncVolumeView.subviews) {
                if ([view isKindOfClass:UISlider.class]) {
                    _syncSlider = (UISlider *)view;
                    break;
                }
            }
        }

        if (!_syncSlider) {
            [_syncVolumeView removeFromSuperview];
            return;
        }
        targetSlider = _syncSlider;
    } else if (_syncVolumeView.superview) {
        [_syncVolumeView removeFromSuperview];
    }

    if (_expectedSystemVolume >= 0 && (CACurrentMediaTime() - _lastSystemVolumeSet) < 0.35 &&
        fabs(_expectedSystemVolume - volume) > 0.015) {
        _prevExpectedSystemVolume = _expectedSystemVolume;
    } else {
        _prevExpectedSystemVolume = -1;
    }
    _expectedSystemVolume = volume;
    _lastSystemVolumeSet = CACurrentMediaTime();

    if ([self activeEntity]) _didSyncSystemForConnect = YES;

    [targetSlider setValue:volume animated:NO];
    [targetSlider sendActionsForControlEvents:UIControlEventValueChanged];

    NSUInteger gen = ++_syncDetachGen;
    if (needsAttach) {
        void (^retryColdSync)(void) = ^{
            if (gen != self->_syncDetachGen || self->_expectedSystemVolume < 0 ||
                fabs(self->_expectedSystemVolume - volume) > 0.001 ||
                !self->_syncVolumeView.superview || !self->_syncSlider) return;
            if (fabs(AVAudioSession.sharedInstance.outputVolume - volume) > 0.015) {
                self->_lastSystemVolumeSet = CACurrentMediaTime();
                [self->_syncSlider setValue:volume animated:NO];
                [self->_syncSlider sendActionsForControlEvents:UIControlEventValueChanged];
            }
        };
        // MPVolumeSlider connects its MPVolumeController asynchronously on didMoveToWindow and can overwrite
        // an immediate setValue: on the next turn or shortly after; retry if KVO has not confirmed it yet.
        dispatch_async(dispatch_get_main_queue(), retryColdSync);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), retryColdSync);
    }

    if (!liveSlider) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gen != self->_syncDetachGen) return;
            if (self->_syncVolumeView.superview) [self->_syncVolumeView removeFromSuperview];
            if (![self activeEntity]) {
                self->_syncSlider = nil;
                self->_syncVolumeView = nil;
            }
        });
    }
}

- (void)scheduleSettle {
    NSUInteger gen = ++_settleGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.80 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != self->_settleGen || ![self activeEntity] || self->_pushScheduled) return;
        for (SGRVolumeRow *row in self->_rows.allObjects) {
            if (row.isHeld) return;
        }
        CGFloat settled = self->_cachedVolume;
        if (settled < 0 && ![self readVolume:&settled]) return;
        for (SGRVolumeRow *row in self->_rows.allObjects) [row refreshTo:settled];
        CGFloat settleTolerance = (settled <= 0.001 || settled >= 0.999) ? 0.015 : 0.05;
        if (fabs(AVAudioSession.sharedInstance.outputVolume - settled) > settleTolerance &&
            (settled > 0 || self->_hasConnectPropertyData || self->_cachedVolume >= 0)) {
            [self setSystemVolumeTo:settled];
        }
    });
}

- (void)pushVolume:(CGFloat)target {
    if (![self activeEntity] || ![_volume respondsToSelector:@selector(setVolume:reason:)]) return;
    target = MIN(1, MAX(0, target));
    _cachedVolume = target;
    _lastPushTime = CACurrentMediaTime();

    CFTimeInterval now = _lastPushTime;
    CFTimeInterval elapsed = now - _lastSentTime;
    const CFTimeInterval kThrottleInterval = 0.150;

    if (elapsed >= kThrottleInterval) {
        _lastSentTime = now;
        _pendingTarget = -1;
        [_volume setVolume:target reason:@"DevicePickerUIImpl"];
        [self scheduleSettle];
    } else {
        _pendingTarget = target;
        if (!_pushScheduled) {
            _pushScheduled = YES;
            NSUInteger pushGen = _pushGen;
            CFTimeInterval delay = MAX(0, kThrottleInterval - elapsed);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (pushGen != self->_pushGen) return;
                self->_pushScheduled = NO;
                if (self->_pendingTarget >= 0) {
                    CGFloat finalTarget = self->_pendingTarget;
                    self->_pendingTarget = -1;
                    self->_lastSentTime = CACurrentMediaTime();
                    self->_lastPushTime = self->_lastSentTime;
                    if ([self activeEntity] && [self->_volume respondsToSelector:@selector(setVolume:reason:)]) {
                        [self->_volume setVolume:finalTarget reason:@"DevicePickerUIImpl"];
                        [self scheduleSettle];
                    }
                }
            });
        }
    }
}

- (void)applySystemVolume:(CGFloat)sysVolume at:(CFTimeInterval)now {
    CGFloat delta = sysVolume - _priorSystemVolume;
    CFTimeInterval timeSincePrior = now - _priorSystemVolumeTime;
    _priorSystemVolumeTime = now;
    _priorSystemVolume = sysVolume;

    for (SGRVolumeRow *row in _rows.allObjects) {
        if (row.isHeld) return;
    }

    if ([self activeEntity]) {
        if (_lastRouteChange > 0 && (now - _lastRouteChange) < 0.4) return;
        BOOL edgeScrub = (timeSincePrior < 0.1) && (sysVolume <= 0.001 || sysVolume >= 0.999);
        if (fabs(delta) > 0.001 || edgeScrub) {
            CGFloat current;
            if (![self readVolume:&current]) current = sysVolume;

            // Hardware volume buttons step by ~0.0625 (or clamp to 0/1 from <= 0.065 away). Any other
            // delta comes from dragging the system HUD or Control Center slider, which should track
            // the thumb position directly even at moderate/slow drag speeds when out of sync.
            BOOL inSync = fabs(sysVolume - current) <= 0.10;
            BOOL largeJump = fabs(delta) > 0.12;
            BOOL buttonStep = (fabs(fabs(delta) - 0.0625) <= 0.015) ||
                              (fabs(delta) > 0.001 && fabs(delta) <= 0.065 && (sysVolume <= 0.001 || sysVolume >= 0.999));
            BOOL continuousScrub = !buttonStep && (fabs(delta) > 0.001);
            if (continuousScrub) _lastScrubTime = now;
            BOOL scrubbing = continuousScrub || (_lastScrubTime > 0 && (now - _lastScrubTime) < 0.25);
            CGFloat target = (inSync || largeJump || scrubbing) ? sysVolume : MIN(1, MAX(0, current + delta));
            target = MIN(1, MAX(0, target));

            if (fabs(target - current) > 0.001) {
                _didSyncSystemForConnect = YES;
                [self pushVolume:target];
                for (SGRVolumeRow *row in _rows.allObjects) {
                    [row setValue:target fromUser:NO];
                }
            }
        }
        return;
    }

    for (SGRVolumeRow *row in _rows.allObjects) {
        [row refreshFromSystem];
    }
}

- (void)restoreSavedLocalVolumeIfForeground {
    if (_savedLocalVolume < 0 || [self activeEntity]) return;
    if (!_didSyncSystemForConnect) {
        _savedLocalVolume = -1;
        return;
    }
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    CGFloat restore = _savedLocalVolume;
    _savedLocalVolume = -1;
    _didSyncSystemForConnect = NO;
    [self setSystemVolumeTo:restore];
}

- (void)syncDevice {
    BOOL wasConnect = (_deviceKey != nil);
    NSString *key = [self activeDeviceKey];
    BOOL isConnect = (key != nil);
    BOOL same = (key == _deviceKey) || [key isEqualToString:_deviceKey];
    BOOL switched = !same;
    _deviceKey = [key copy];
    atomic_store_explicit(&s_connectActive, isConnect, memory_order_relaxed);
    if (switched) {
        _lastPushTime = 0;
        _lastSentTime = 0;
        _pendingTarget = -1;
        _pushScheduled = NO;
        _pushGen++;
        _settleGen++;
        [self clearExpectedSystemVolume];
        _priorSystemVolume = AVAudioSession.sharedInstance.outputVolume;
        _priorSystemVolumeTime = 0;
        _lastScrubTime = 0;
        _cachedVolume = -1;
        _hasConnectPropertyData = NO;
        _usesRemoteSession = NO;

        if (!wasConnect && isConnect) {
            if (_savedLocalVolume < 0) _savedLocalVolume = _priorSystemVolume;
        } else if (wasConnect && !isConnect) {
            [self restoreSavedLocalVolumeIfForeground];
        }

        CGFloat remote;
        if (isConnect && [self readVolume:&remote]) {
            [self setSystemVolumeTo:remote];
        }
    }
    for (SGRVolumeRow *row in _rows.allObjects) {
        if (switched) [row connectEntityChanged];
        else [row refreshFromSystem];
    }
}

- (void)bindVolume:(id)volume {
    if (!volume || volume == _volume) return;
    id<SGRConnectVolume> oldVolume = _volume;
    _volume = volume;
    if (oldVolume && [oldVolume respondsToSelector:@selector(remove:)]) {
        [oldVolume remove:self];
    }
    if ([volume respondsToSelector:@selector(add:)]) [volume add:self];
    [self syncDevice];
}

- (void)bindAggregator:(id)aggregator {
    if (!aggregator || aggregator == _aggregator) return;
    BOOL replacing = (_aggregator != nil);
    _aggregator = aggregator;
    if (replacing) {
        _entity = nil;
        _explicitNilEntity = NO;
    }
    [self syncDevice];
}

- (void)entityChanged:(id)entity aggregator:(id)aggregator {
    if (aggregator) _aggregator = aggregator;
    _entity = entity;
    _explicitNilEntity = (entity == nil);
    [self syncDevice];
}

#pragma mark - Notifications & KVO

- (void)appDidEnterBackground {
    onMain(^{
        self->_wasBackgrounded = YES;
        self->_backgroundSystemVolume = AVAudioSession.sharedInstance.outputVolume;
    });
}

- (void)appDidBecomeActive {
    onMain(^{
        BOOL fromBackground = self->_wasBackgrounded;
        CGFloat backgroundSystemVolume = self->_backgroundSystemVolume;
        self->_wasBackgrounded = NO;
        self->_backgroundSystemVolume = -1;
        CGFloat sysVolume = AVAudioSession.sharedInstance.outputVolume;
        CFTimeInterval now = CACurrentMediaTime();

        if (!fromBackground) {
            BOOL expectedMatch = self->_expectedSystemVolume >= 0 && (now - self->_lastSystemVolumeSet) < 0.35 &&
                                 (fabs(sysVolume - self->_expectedSystemVolume) <= 0.015 ||
                                  (self->_prevExpectedSystemVolume >= 0 && fabs(sysVolume - self->_prevExpectedSystemVolume) <= 0.015));
            [self clearExpectedSystemVolume];
            if (expectedMatch) {
                self->_priorSystemVolume = sysVolume;
                for (SGRVolumeRow *row in self->_rows.allObjects) [row refreshFromSystem];
            } else if (fabs(sysVolume - self->_priorSystemVolume) > 0.002) {
                [self applySystemVolume:sysVolume at:now];
            } else {
                for (SGRVolumeRow *row in self->_rows.allObjects) [row refreshFromSystem];
            }
            return;
        }

        [self clearExpectedSystemVolume];
        self->_priorSystemVolume = sysVolume;
        if ([self activeEntity]) {
            BOOL noRecentPush = (self->_lastPushTime == 0 || (now - self->_lastPushTime) > 2.0);
            if (!self->_usesRemoteSession && !self->_pushScheduled && noRecentPush &&
                [self->_volume respondsToSelector:@selector(connectVolume)]) {
                double live = [self->_volume connectVolume];
                if (isfinite(live)) {
                    CGFloat clamped = MIN(1, MAX(0, (CGFloat)live));
                    if (clamped > 0) self->_hasConnectPropertyData = YES;
                    if (clamped > 0 || self->_hasConnectPropertyData) self->_cachedVolume = clamped;
                }
            }
            CGFloat remote;
            if ([self readVolume:&remote]) {
                [self setSystemVolumeTo:remote];
            }
        } else {
            if (backgroundSystemVolume >= 0 && fabs(sysVolume - backgroundSystemVolume) > 0.03) {
                self->_savedLocalVolume = -1;
                self->_didSyncSystemForConnect = NO;
            } else {
                [self restoreSavedLocalVolumeIfForeground];
            }
        }
        for (SGRVolumeRow *row in self->_rows.allObjects) [row refreshFromSystem];
    });
}

- (void)routeChanged:(NSNotification *)note {
    NSUInteger reason = [note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    if (reason == AVAudioSessionRouteChangeReasonUnknown) return;
    onMain(^{
        self->_lastRouteChange = CACurrentMediaTime();
        self->_priorSystemVolume = AVAudioSession.sharedInstance.outputVolume;
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &kSessionContext) return;
    id newValue = change[NSKeyValueChangeNewKey];
    onMain(^{
        CGFloat sysVolume = [newValue isKindOfClass:NSNumber.class] ? ((NSNumber *)newValue).floatValue : AVAudioSession.sharedInstance.outputVolume;
        if (!isfinite(sysVolume)) return;

        CFTimeInterval now = CACurrentMediaTime();
        if (self->_expectedSystemVolume >= 0 && (now - self->_lastSystemVolumeSet) < 0.35) {
            if (fabs(sysVolume - self->_expectedSystemVolume) <= 0.015) {
                // This KVO fired because setSystemVolumeTo: moved the hidden slider (echo suppression).
                // Preserve _priorSystemVolumeTime so the next real user step is timed from the last real event.
                [self clearExpectedSystemVolume];
                self->_priorSystemVolume = sysVolume;
                if (![self activeEntity]) {
                    for (SGRVolumeRow *row in self->_rows.allObjects) [row refreshFromSystem];
                }
                return;
            }
            if (self->_prevExpectedSystemVolume >= 0 && fabs(sysVolume - self->_prevExpectedSystemVolume) <= 0.015) {
                self->_prevExpectedSystemVolume = -1;
                self->_priorSystemVolume = sysVolume;
                return;
            }
        }
        [self clearExpectedSystemVolume];

        [self applySystemVolume:sysVolume at:now];
    });
}

#pragma mark - SPTConnectVolumeObserver

- (void)handleConnectVolume:(double)value isRemoteSession:(BOOL)remoteSession {
    onMain(^{
        if (![self activeEntity] || !isfinite(value)) return;
        if (remoteSession) self->_usesRemoteSession = YES;
        else self->_hasConnectPropertyData = YES;
        if (self->_pushScheduled) return;

        CGFloat clamped = MIN(1, MAX(0, (CGFloat)value));
        CFTimeInterval sincePush = (self->_lastPushTime > 0) ? (CACurrentMediaTime() - self->_lastPushTime) : 10.0;
        BOOL matchesPush = (self->_cachedVolume >= 0 && fabs(clamped - self->_cachedVolume) <= 0.025);
        // Suppress delayed network echoes from earlier steps while letting matching ACKs settle.
        if (sincePush < 2.0 && !matchesPush) return;

        self->_cachedVolume = clamped;
        BOOL anyHeld = NO;
        for (SGRVolumeRow *row in self->_rows.allObjects) {
            if (row.isHeld) anyHeld = YES;
            [row connectVolumeChanged:clamped];
        }
        if (!anyHeld && sincePush >= 2.0) [self setSystemVolumeTo:clamped];
    });
}

- (void)connectVolumeDidChangeToValue:(double)value {
    [self handleConnectVolume:value isRemoteSession:NO];
}

- (void)remoteMediaSessionVolumeDidChangeToValue:(double)value {
    [self handleConnectVolume:value isRemoteSession:YES];
}

- (void)groupedDeviceVolumeDidChangeToValue:(double)value groupDeviceIdentifier:(NSString *)identifier {
    [self handleConnectVolume:value isRemoteSession:YES];
}

@end

static UIImageView *glyph(NSString *symbol) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:kGlyphSize weight:UIImageSymbolWeightSemibold];
    UIImageView *view = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]];
    view.tintColor = UIColor.whiteColor;
    view.alpha = kGlyphRest;
    view.contentMode = UIViewContentModeCenter;
    view.isAccessibilityElement = NO;
    return view;
}

// MPVolumeView makes its slider when it lays out and may make another later, for example after a route change, so the
// row looks for it again after each of its layouts.
@interface SGRVolumeView : MPVolumeView
@end

@implementation SGRVolumeView

- (void)layoutSubviews {
    [super layoutSubviews];
    [(SGRVolumeRow *)self.superview systemSlider];
}

@end

@implementation SGRVolumeRow {
    MPVolumeView *_system;
    UISlider *_systemSlider;
    UIView *_track, *_fill;
    UIImageView *_quiet, *_loud;
    CGFloat _value, _startValue, _startX, _trackMin, _trackMax;
    BOOL _held, _dirtyDuringHold;
    CFTimeInterval _lastPush;
    NSUInteger _refreshGeneration;
    NSHashTable<UIGestureRecognizer *> *_suspended;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    [[SGRConnectVolumeController shared] registerRow:self];
    // Only plumbing: the slider inside moves the system's volume, nobody sees or touches the view.
    _system = [SGRVolumeView new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _system.showsRouteButton = NO;
#pragma clang diagnostic pop
    _system.userInteractionEnabled = NO;
    [self updateSystemViewVisibility];
    [self addSubview:_system];

    _track = [UIView new];
    _track.clipsToBounds = YES;
    _track.userInteractionEnabled = NO;
    _track.layer.cornerCurve = kCACornerCurveContinuous;
    _track.backgroundColor = [UIColor colorWithWhite:1 alpha:kEmpty];
    _fill = [UIView new];
    _fill.userInteractionEnabled = NO;
    [_track addSubview:_fill];
    [self addSubview:_track];

    _quiet = glyph(@"speaker.fill");
    _loud = glyph(@"speaker.wave.3.fill");
    [self addSubview:_quiet];
    [self addSubview:_loud];

    CGFloat remote;
    _value = [[SGRConnectVolumeController shared] readVolume:&remote] ? remote : AVAudioSession.sharedInstance.outputVolume;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(playerTransitionChanged)
                   name:SGPlayerTransitionNotification object:nil];
    [center addObserver:self selector:@selector(playerTransitionChanged)
                   name:SGPlayerTransitionEndedNotification object:nil];
    [center addObserver:self selector:@selector(willResignActive)
                   name:UIApplicationWillResignActiveNotification object:nil];

    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Volume";
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    return self;
}

- (void)dealloc {
    [self restoreAncestorGestures];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)updateSystemViewVisibility {
    BOOL open = SGPlayerIsOpen();
    CGFloat alpha = open ? 0.01 : 0.0;
    if (_system.hidden != !open) _system.hidden = !open;
    if (fabs(_system.alpha - alpha) > 0.001) _system.alpha = alpha;
}

- (void)playerTransitionChanged {
    [self updateSystemViewVisibility];
}

- (void)willResignActive {
    if (self.tracking) [self cancelTrackingWithEvent:nil];
    else if (_held) [self setHeld:NO];
}

- (BOOL)isHeld {
    return _held;
}

// The volume view builds its slider itself and may replace it, so the one it has now is looked for each time.
- (UISlider *)liveSystemSliderInWindow:(UIWindow *)window {
    if (!window || self.window != window || self.hidden || self.alpha <= 0.005) return nil;
    if (!_system || _system.hidden || _system.alpha <= 0.005 || CGRectIsEmpty(_system.bounds)) return nil;
    UISlider *slider = [self systemSlider];
    if (!slider || slider.window != window || slider.hidden) return nil;
    return slider;
}

- (UISlider *)systemSlider {
    UISlider *current = nil;
    for (UIView *view in _system.subviews) {
        if (![view isKindOfClass:UISlider.class]) continue;
        current = (UISlider *)view;
        break;
    }
    if (current == _systemSlider) return current;

    _systemSlider = current;
    // Hide the system slider's visible artwork.
    current.thumbTintColor = UIColor.clearColor;
    current.minimumTrackTintColor = UIColor.clearColor;
    current.maximumTrackTintColor = UIColor.clearColor;
    return current;
}

// The system has just set the slider: its value is the volume. Our own pushVolume sets it too, and refreshTo: skips
// that echo.
- (void)systemSliderSet {
    SGRConnectVolumeController *controller = [SGRConnectVolumeController shared];
    if ([controller activeEntity]) return;
    CGFloat pending;
    if ([controller readPendingLocalVolume:&pending]) {
        [self refreshTo:pending];
        return;
    }
    UISlider *slider = [self systemSlider];
    if (slider) [self refreshTo:slider.value];
}

// The session's volume, not the slider's: a volume view made at launch holds 0 in its slider until it has asked the
// system, which it does with no setValue: the row then stood empty until touched (the session said 0.6, the slider 0).
- (void)refreshFromSystem {
    SGRConnectVolumeController *controller = [SGRConnectVolumeController shared];
    CGFloat current;
    if (![controller readVolume:&current] && ![controller readPendingLocalVolume:&current]) {
        current = AVAudioSession.sharedInstance.outputVolume;
    }
    [self refreshTo:current];
}

- (void)refreshTo:(CGFloat)system {
    // Not while the finger is on it, nor just after it let go: the system or Connect device settles a moment later.
    if (_held || (_lastPush > 0 && CACurrentMediaTime() - _lastPush < 0.6) ||
        [[SGRConnectVolumeController shared] isPushPendingOrRecent]) return;
    if (fabs(system - _value) > 0.002) [self setValue:system fromUser:NO];
}

- (void)connectVolumeChanged:(CGFloat)value {
    if (![[SGRConnectVolumeController shared] activeEntity] || !isfinite(value)) return;
    [self refreshTo:MIN(1, MAX(0, value))];
}

- (void)connectEntityChanged {
    _lastPush = 0;
    _dirtyDuringHold = NO;
    _refreshGeneration++;
    if (self.tracking) [self cancelTrackingWithEvent:nil];
    else if (_held) [self setHeld:NO];
    [self refreshFromSystem];
}

// The KVO or Connect update sent as the volume settles falls inside the guard above, so the row reads it once the guard has passed.
- (void)refreshAfterPush {
    NSUInteger gen = ++_refreshGeneration;
    __weak SGRVolumeRow *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGRVolumeRow *strongSelf = weakSelf;
        if (!strongSelf || gen != strongSelf->_refreshGeneration) return;
        [strongSelf refreshFromSystem];
    });
}

- (void)pushVolume {
    SGRConnectVolumeController *controller = [SGRConnectVolumeController shared];
    if ([controller activeEntity]) {
        _lastPush = CACurrentMediaTime();
        if (_held) _dirtyDuringHold = YES;
        [controller pushVolume:_value];
        if (!_held) {
            [controller setSystemVolumeTo:_value];
            [self refreshAfterPush];
        }
        return;
    }
    UISlider *slider = [self systemSlider];
    if (!slider) return;
    _lastPush = CACurrentMediaTime();
    [controller setLocalPushTimestamp:_lastPush];
    if (_held) _dirtyDuringHold = YES;
    [slider setValue:_value animated:NO];
    [slider sendActionsForControlEvents:UIControlEventValueChanged];
    if (!_held) [self refreshAfterPush];
}

// The room the row has to either side inside its stack: what the held track and glyphs may grow into.
- (CGFloat)roomLeft { return MAX(0, CGRectGetMinX(self.frame)); }

- (CGFloat)roomRight {
    UIView *stack = self.superview;
    return stack ? MAX(0, stack.bounds.size.width - CGRectGetMaxX(self.frame)) : 0;
}

// The track's frame for the state it is in: it grows past both ends while held.
- (void)syncTrack {
    CGFloat height = _held ? kTrackHeld : kTrackRest;
    CGFloat left = _held ? MIN(kStretch, [self roomLeft]) : 0, right = _held ? MIN(kStretch, [self roomRight]) : 0;
    CGFloat scale = self.traitCollection.displayScale ?: 3;
    CGFloat top = round((CGRectGetMidY(self.bounds) - height / 2) * scale) / scale;
    _track.frame = CGRectMake(_trackMin - left, top, MAX(0, _trackMax - _trackMin) + left + right, height);
    _track.layer.cornerRadius = height / 2;
    [self syncFill];
}

// The fill is a plain rectangle the pill's clipping rounds, so its right edge stays straight, as in Music.
- (void)syncFill {
    CGSize size = _track.bounds.size;
    _fill.frame = CGRectMake(0, 0, size.width * _value, size.height);
}

- (void)syncStyle {
    _fill.backgroundColor = [UIColor colorWithWhite:1 alpha:_held ? kFillHeld : kFillRest];
    CGFloat scale = _held ? kGlyphHeldScale : 1;
    CGFloat left = _held ? MIN(kGlyphShift, [self roomLeft]) : 0, right = _held ? MIN(kGlyphShift, [self roomRight]) : 0;
    CGAffineTransform grown = CGAffineTransformMakeScale(scale, scale);
    _quiet.transform = CGAffineTransformConcat(grown, CGAffineTransformMakeTranslation(-left, 0));
    _loud.transform = CGAffineTransformConcat(grown, CGAffineTransformMakeTranslation(right, 0));
    _quiet.alpha = _loud.alpha = _held ? 1 : kGlyphRest;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateSystemViewVisibility];
    CGRect bounds = self.bounds;
    CGFloat side = kRowHeight, middle = CGRectGetMidY(bounds);
    _system.frame = CGRectMake(0, 0, MAX(140, bounds.size.width), side);
    [_system layoutIfNeeded];
    [self systemSlider];

    BOOL queueOpen = SGRPlayerQueueOpen();
    if (queueOpen) {
        CGFloat quietW = 13.0, loudW = 22.0;
        _quiet.bounds = CGRectMake(0, 0, quietW, side);
        _loud.bounds = CGRectMake(0, 0, loudW, side);
        _quiet.center = CGPointMake(quietW * 0.5, middle);
        _loud.center = CGPointMake(bounds.size.width - loudW * 0.5, middle);
        _trackMin = 25.0; // 32.0 + 25.0 = 57.0 pt on 390 pt screen
        _trackMax = bounds.size.width - (loudW + 12.0); // 326.0 - 34.0 = 292.0 pt (screen x = 324.0 pt, width = 267.0 pt)
    } else {
        CGFloat glyphWidth = side / 2 + kGlyphSize / 2;
        CGFloat loudMin = CGRectGetMaxX(bounds) - side / 2 - kGlyphSize;
        _quiet.bounds = CGRectMake(0, 0, glyphWidth, side);
        _loud.bounds = CGRectMake(0, 0, glyphWidth, side);
        _quiet.center = CGPointMake(glyphWidth / 2, middle);
        _loud.center = CGPointMake(loudMin + glyphWidth / 2, middle);
        _trackMin = glyphWidth + kGlyphGap;
        _trackMax = loudMin - kGlyphGap;
    }
    [self syncTrack];
    [self syncStyle];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        // A lock or a call can take the row off screen mid-drag, and then end or cancel tracking may not come.
        if (self.tracking) [self cancelTrackingWithEvent:nil];
        else [self setHeld:NO];
        _system.hidden = YES;
        _system.alpha = 0.0;
        return;
    }
    [self updateSystemViewVisibility];
    [self systemSlider];
    [self refreshFromSystem];
}

// Prevent the player from stealing volume swipe gesture.
- (void)suspendAncestorGestures {
    if (_suspended) return;
    _suspended = [NSHashTable weakObjectsHashTable];
    for (UIView *view = self.superview; view; view = view.superview) {
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
            BOOL pan = [recognizer isKindOfClass:UIPanGestureRecognizer.class];
            if (!pan || [recognizer isKindOfClass:UIScreenEdgePanGestureRecognizer.class] || !recognizer.enabled) continue;
            recognizer.enabled = NO;
            [_suspended addObject:recognizer];
        }
    }
}

- (void)restoreAncestorGestures {
    for (UIGestureRecognizer *recognizer in _suspended) recognizer.enabled = YES;
    _suspended = nil;
}

- (void)setValue:(CGFloat)value fromUser:(BOOL)fromUser {
    if (!isfinite(value)) return;
    value = MIN(1, MAX(0, value));
    BOOL changed = fabs(value - _value) > 0.0001;
    _value = value;
    // Ease any non-drag change (hardware buttons on local or Connect, remote updates, VoiceOver); drags track the finger.
    if (!_held && self.window) {
        UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction |
                                         UIViewAnimationOptionCurveEaseOut;
        [UIView animateWithDuration:0.15 delay:0 options:options animations:^{ [self syncFill]; } completion:nil];
    } else {
        [self syncFill];
    }
    if (fromUser && changed) [self pushVolume];
}

- (void)setHeld:(BOOL)held {
    if (_held == held) return;
    _held = held;
    if (held) {
        _dirtyDuringHold = NO;
        [self suspendAncestorGestures];
    } else {
        [self restoreAncestorGestures];
        if (_dirtyDuringHold) {
            _dirtyDuringHold = NO;
            SGRConnectVolumeController *controller = [SGRConnectVolumeController shared];
            if ([controller activeEntity]) [controller setSystemVolumeTo:_value];
            [self refreshAfterPush];
        } else {
            [self refreshFromSystem];
        }
    }
    void (^apply)(void) = ^{ [self syncTrack]; [self syncStyle]; };
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;
    if (held) {
        [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:options
                         animations:apply completion:nil];
    } else {
        [UIView animateWithDuration:0.16 delay:0 options:options | UIViewAnimationOptionCurveEaseOut
                         animations:apply completion:nil];
    }
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    _startX = [touch locationInView:self].x;
    _startValue = _value;
    [self setHeld:YES];
    return YES;
}

// Relative to where the finger came down: the value moves by the finger's travel over the track's length.
- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    if (!_held) return NO;
    CGFloat span = MAX(1, _trackMax - _trackMin);
    [self setValue:_startValue + ([touch locationInView:self].x - _startX) / span fromUser:YES];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event { [self setHeld:NO]; }
- (void)cancelTrackingWithEvent:(UIEvent *)event { [self setHeld:NO]; }

- (NSString *)accessibilityValue { return [NSString stringWithFormat:@"%d%%", (int)round(_value * 100)]; }
- (void)accessibilityIncrement { [self setValue:_value + 0.0625 fromUser:YES]; }
- (void)accessibilityDecrement { [self setValue:_value - 0.0625 fromUser:YES]; }

@end

void SGRPlayerConnectVolumeInit(void) {
    // Defer AVAudioSession/KVO setup off dyld %ctor until the main run loop starts.
    dispatch_async(dispatch_get_main_queue(), ^{
        [SGRConnectVolumeController shared];
    });
}

void SGRPlayerConnectVolumeProvided(id volume) {
    if (!volume) return;
    onMain(^{
        [[SGRConnectVolumeController shared] bindVolume:volume];
    });
}

void SGRPlayerConnectAggregatorProvided(id aggregator) {
    if (!aggregator) return;
    onMain(^{
        [[SGRConnectVolumeController shared] bindAggregator:aggregator];
    });
}

void SGRPlayerConnectEntityChanged(id aggregator, id entity) {
    onMain(^{
        [[SGRConnectVolumeController shared] entityChanged:entity aggregator:aggregator];
    });
}

BOOL SGRPlayerConnectVolumeActive(void) {
    if (!NSThread.isMainThread) {
        return atomic_load_explicit(&s_connectActive, memory_order_relaxed);
    }
    return [[SGRConnectVolumeController shared] isConnectActive];
}

static char kVolumeKey, kPlayKey, kSettleKey;
// Passes the footer's layout is asked for again while the row's place keeps changing, at most.
static const NSUInteger kSettlePasses = 6;

// Read at launch, as the player's other switches are: the footer asks on every layout pass.
BOOL SGRPlayerVolumeOn(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGEnabled(SGRKeyPlayerVolume); });
    return on;
}

// The footer lays out before Spotify's bottom stack has arranged its views the first time the player opens (the
// controls then stand near the stack's top), and nothing lays the footer out again once the stack has: the row was
// placed against the controls' old place and stayed there, over their buttons. A row that moved asks the footer's
// layout once more on the next turn of the run loop, which finds the settled places; one that did not move ends it.
static void settle(UIView *stack, UIView *row, BOOL moved, CGRect frame) {
    NSUInteger passes = [objc_getAssociatedObject(stack, &kSettleKey) unsignedIntegerValue];
    if (!moved) {
        if (passes) objc_setAssociatedObject(stack, &kSettleKey, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (passes >= kSettlePasses) return;
    objc_setAssociatedObject(stack, &kSettleKey, @(passes + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (passes > 0) SGLog(@"redesign player: volume row placed again at %.0f (pass %lu)", frame.origin.y, (unsigned long)passes + 1);
    __weak UIView *weakStack = stack, *weakRow = row;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *settledStack = weakStack, *settledRow = weakRow;
        if (!settledStack.window || !settledRow.window) return;
        [settledStack layoutIfNeeded];
        SGRPlayerLowerRow(settledRow);
    });
}

BOOL SGRPlayerPlaceVolume(UIView *stack, UIView *controls, UIView *row, CGFloat margin) {
    SGRVolumeRow *volume = objc_getAssociatedObject(stack, &kVolumeKey);
    if (!SGRPlayerVolumeOn() || !controls) {
        SGRPlayerLyricsFadeView(volume, NO);
        return NO;
    }
    if (!volume) {
        volume = [SGRVolumeRow new];
        objc_setAssociatedObject(stack, &kVolumeKey, volume, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRObserveLayout(stack, ^(UIView *laidOut) {
            SGRVolumeRow *placed = objc_getAssociatedObject(laidOut, &kVolumeKey);
            UIView *footer = placed.footer;
            if (footer.superview == laidOut) SGRPlayerLowerRow(footer);
        });
    }
    if (volume.superview != stack) [stack addSubview:volume];
    volume.footer = row;
    // Halfway between the play button's bottom and the footer glyphs' top, each where it is drawn (convertRect: takes
    // the moves' transforms in). Without the button there is nothing to stand under: a guess from the controls' unit
    // put the row across the buttons on an iPhone 13 Pro with iOS 17 (issue #32) and took their taps, so no row.
    UIView *play = SGRFindByIdentifier(controls, @"SPTNowPlayingPlayButton", &kPlayKey);
    if (!play) {
        static BOOL logged;
        if (!logged) {
            logged = YES;
            SGLog(@"redesign player: no play button in %@, so no volume row", NSStringFromClass(controls.class));
        }
        SGRPlayerLyricsFadeView(volume, NO);
        return NO;
    }
    CGFloat above = CGRectGetMaxY([play convertRect:play.bounds toView:stack]);
    CGFloat below = [row convertPoint:CGPointMake(CGRectGetMidX(row.bounds), CGRectGetMidY(row.bounds)) toView:stack].y - kGlyphsHalf;
    CGFloat height = kRowHeight, room = below - above;
    CGRect frame = CGRectMake(margin, round((above + below - height) / 2), MAX(0, stack.bounds.size.width - 2 * margin), height);
    if (SGRPlayerQueueOpen()) {
        // Apple Music target: volume track at y = 722.7 pt on 844 pt screen (height - (83.9 + safeBottom)).
        UIView *player = stack.superview;
        UIWindow *window = stack.window ?: player.window;
        CGFloat safeBottom = window ? window.safeAreaInsets.bottom : 34.0;
        CGFloat playerHeight = player ? player.bounds.size.height : (window ? window.bounds.size.height : 844.0);
        CGFloat targetTrackY = playerHeight - (83.9 + safeBottom);
        CGFloat stackY = player ? [stack convertPoint:CGPointZero toView:player].y : stack.frame.origin.y;
        CGFloat targetCenterY = targetTrackY - stackY;
        frame.origin.y = round(targetCenterY - height * 0.5);
    }
    BOOL moved = !CGRectEqualToRect(volume.frame, frame);
    if (moved) {
        volume.frame = frame;
        [volume setNeedsLayout];
        [volume layoutIfNeeded];
    }
    if (!SGRPlayerQueueOpen()) {
        settle(stack, row, moved, frame);
    }
    // The lyrics fade the stack's views by their alpha and bring back only the ones they faded.
    // The track is 7pt of the row's 32: it fits with the glyphs' and buttons' own clearance around it.
    BOOL fits = SGRPlayerQueueOpen() ? YES : (room >= height * 0.6);
    BOOL faded = SGRPlayerLyricsFadeView(volume, fits);
    if (!faded && volume.alpha < 0.01 && (SGRPlayerQueueOpen() || controls.alpha > 0.99)) volume.alpha = 1;
    return fits;
}

// MPVolumeSlider takes an outside change (AirPlay, Connect) through super's setValue:animated:, which sends no KVO, and
// sends ValueChanged only when the change shows the system's HUD, which Spotify's own Connect HUD turns off.
void SGRPlayerVolumeSliderSet(UISlider *slider) {
    UIView *row = slider.superview.superview;
    if (![slider.superview isKindOfClass:SGRVolumeView.class] || ![row isKindOfClass:SGRVolumeRow.class]) return;
    if (slider != ((SGRVolumeRow *)row).systemSlider) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [(SGRVolumeRow *)row systemSliderSet]; });
}

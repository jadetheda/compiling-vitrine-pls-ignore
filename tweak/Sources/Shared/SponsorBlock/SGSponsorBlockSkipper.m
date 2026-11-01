// SponsorBlock playback observer and segment skipper for podcasts.
// Observes Spotify's player state through Shared/Player/PlayerState.h and runs a 250ms tick only
// while a podcast episode with segments is actively playing.
#import "SGSponsorBlockSkipper.h"
#import "SGSponsorBlockOverlay.h"
#import "SGSponsorBlockToast.h"
#import "SGSponsorBlock.h"
#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"

static const NSTimeInterval kPollInterval = 0.25;
static const NSTimeInterval kSeekSettleTimeout = 2.0;
static const NSTimeInterval kFetchRetryCooldown = 15.0;

static id<SPTPlayer> livePlayer(void) {
    id player = SGPlayer() ?: SGKaraokePlayer();
    return [player respondsToSelector:@selector(seekTo:)] ? player : nil;
}

static SPTPlayerState *liveState(void) {
    id<SPTPlayer> player = livePlayer();
    SPTPlayerState *state = [player respondsToSelector:@selector(state)] ? player.state : nil;
    return state ?: SGPlayerState();
}

static double statePosition(SPTPlayerState *state) {
    if (!state) return -1;
    if (state.isPaused && [state respondsToSelector:@selector(positionAsOfTimestamp)]) {
        return state.positionAsOfTimestamp;
    }
    if ([state respondsToSelector:@selector(position)]) return state.position;
    return [state respondsToSelector:@selector(positionAsOfTimestamp)] ? state.positionAsOfTimestamp : -1;
}

static double stateDuration(SPTPlayerState *state) {
    if (!state) return 0;
    if ([state respondsToSelector:@selector(duration)] && state.duration > 0) return state.duration;
    NSDictionary *metadata = [state.track respondsToSelector:@selector(metadata)] && [state.track.metadata isKindOfClass:NSDictionary.class]
        ? state.track.metadata : nil;
    id raw = metadata[@"duration"];
    if ([raw respondsToSelector:@selector(doubleValue)] && [raw doubleValue] > 0) {
        double val = [raw doubleValue];
        return val > 100000.0 ? val / 1000.0 : val;
    }
    return 0;
}

static NSString *episodeIDFromURI(NSString *uri) {
    static NSString *const kPrefix = @"spotify:episode:";
    if (![uri hasPrefix:kPrefix]) return nil;
    NSString *rest = [uri substringFromIndex:kPrefix.length];
    NSRange stop = [rest rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#:"]];
    if (stop.location != NSNotFound) rest = [rest substringToIndex:stop.location];
    return rest.length >= 10 ? rest : nil;
}

@implementation SGSponsorBlockSkipper {
    NSString *_currentEpisodeID;
    NSArray<SGSponsorBlockSegment *> *_segments;
    double _currentDuration;
    BOOL _isPaused;
    BOOL _fetching;
    CFTimeInterval _lastFetchFailureTime;

    NSMutableSet<NSString *> *_whitelistedUUIDs;
    NSMutableSet<NSString *> *_promptedUUIDs;

    double _lastPosition;
    CFTimeInterval _lastPositionTime;

    double _seekTarget;
    CFTimeInterval _seekDeadline;

    NSTimer *_pollTimer;
}

+ (instancetype)sharedSkipper {
    static SGSponsorBlockSkipper *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [SGSponsorBlockSkipper new];
    });
    return shared;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _whitelistedUUIDs = [NSMutableSet set];
    _promptedUUIDs = [NSMutableSet set];
    _lastPosition = -1;
    SGAddPlayerStateObserver(self);
    return self;
}

- (NSString *)currentEpisodeID {
    return _currentEpisodeID;
}

- (NSArray<SGSponsorBlockSegment *> *)currentSegments {
    return _segments ?: @[];
}

- (double)currentDuration {
    return _currentDuration;
}

#pragma mark - timer

- (void)updatePollTimer {
    BOOL shouldRun = SGFlag(SGKeySponsorBlockEnabled, NO)
        && _currentEpisodeID.length > 0
        && _segments.count > 0
        && !_isPaused;
    if (shouldRun && !_pollTimer) {
        __weak typeof(self) weakSelf = self;
        _pollTimer = [NSTimer timerWithTimeInterval:kPollInterval repeats:YES block:^(NSTimer *timer) {
            [weakSelf tick];
        }];
        [NSRunLoop.mainRunLoop addTimer:_pollTimer forMode:NSRunLoopCommonModes];
    } else if (!shouldRun && _pollTimer) {
        [_pollTimer invalidate];
        _pollTimer = nil;
    }
}

- (void)tick {
    SPTPlayerState *state = liveState();
    if (state) [self evaluateState:state];
}

#pragma mark - state observation

- (void)playerStateDidReport:(SPTPlayerState *)state {
    [self handlePlayerState:state];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self handlePlayerState:state];
}

- (void)refreshCurrentState {
    void (^work)(void) = ^{
        if (!SGFlag(SGKeySponsorBlockEnabled, NO)) {
            [self updatePollTimer];
            [SGSponsorBlockToast dismissImmediate:YES];
            SGRefreshSponsorBlockOverlays();
            return;
        }
        SPTPlayerState *state = liveState();
        if (state) [self handlePlayerState:state];
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

- (void)categoryActionsDidChange {
    void (^work)(void) = ^{
        [_promptedUUIDs removeAllObjects];
        for (SGSponsorBlockSegment *seg in _segments) {
            if ([SGSponsorBlockToast isPresentingPromptForSegment:seg] &&
                SGSponsorBlockActionForCategory(seg.category) != SGSponsorBlockActionPrompt) {
                [SGSponsorBlockToast dismissImmediate:NO];
            }
        }
        SGRefreshSponsorBlockOverlays();
        SPTPlayerState *state = liveState();
        if (state) [self evaluateState:state];
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

- (void)clearEpisodeState {
    _currentEpisodeID = nil;
    _segments = nil;
    _currentDuration = 0;
    _isPaused = YES;
    _fetching = NO;
    _lastFetchFailureTime = 0;
    _lastPosition = -1;
    _lastPositionTime = 0;
    _seekDeadline = 0;
    [_whitelistedUUIDs removeAllObjects];
    [_promptedUUIDs removeAllObjects];
    [self updatePollTimer];
    [SGSponsorBlockToast dismissImmediate:YES];
    SGRefreshSponsorBlockOverlays();
}

- (void)handlePlayerState:(SPTPlayerState *)state {
    NSString *episodeID = episodeIDFromURI(SGURIString(state.track.URI));
    if (!episodeID) {
        if (_currentEpisodeID) [self clearEpisodeState];
        return;
    }

    double dur = stateDuration(state);
    if (dur > 0 && fabs(dur - _currentDuration) > 0.5) {
        _currentDuration = dur;
        SGRefreshSponsorBlockOverlays();
    }

    if (![episodeID isEqualToString:_currentEpisodeID]) {
        _currentEpisodeID = [episodeID copy];
        _segments = nil;
        _fetching = NO;
        _lastFetchFailureTime = 0;
        _lastPosition = -1;
        _lastPositionTime = 0;
        _seekDeadline = 0;
        [_whitelistedUUIDs removeAllObjects];
        [_promptedUUIDs removeAllObjects];
        [SGSponsorBlockToast dismissImmediate:YES];
        SGRefreshSponsorBlockOverlays();
    }

    if (!SGFlag(SGKeySponsorBlockEnabled, NO)) {
        [self updatePollTimer];
        return;
    }

    if (!_segments && !_fetching && (CACurrentMediaTime() - _lastFetchFailureTime >= kFetchRetryCooldown)) {
        _fetching = YES;
        NSString *requestedID = _currentEpisodeID;
        __weak typeof(self) weakSelf = self;
        SGFetchSponsorBlockSegments(requestedID, ^(NSArray<SGSponsorBlockSegment *> *segments, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf->_currentEpisodeID isEqualToString:requestedID]) return;
            strongSelf->_fetching = NO;
            if (!segments) {
                strongSelf->_lastFetchFailureTime = CACurrentMediaTime();
                return;
            }
            strongSelf->_segments = segments;
            SGRefreshSponsorBlockOverlays();
            [strongSelf updatePollTimer];
            SPTPlayerState *nowState = liveState();
            if (nowState) [strongSelf evaluateState:nowState];
        });
        return;
    }

    [self evaluateState:state];
}

#pragma mark - evaluation & skipping

- (BOOL)seekToPosition:(double)seconds {
    id<SPTPlayer> player = livePlayer();
    if (!player) return NO;
    double target = MAX(0.0, seconds);
    _seekTarget = target;
    _seekDeadline = CACurrentMediaTime() + kSeekSettleTimeout;
    _lastPosition = target;
    _lastPositionTime = CACurrentMediaTime();
    [player seekTo:target];
    return YES;
}

- (void)evaluateState:(SPTPlayerState *)state {
    _isPaused = state.isPaused || ([state respondsToSelector:@selector(isLoading)] && state.isLoading);
    double dur = stateDuration(state);
    if (dur > 0 && fabs(dur - _currentDuration) > 0.5) {
        _currentDuration = dur;
        SGRefreshSponsorBlockOverlays();
    }
    [self updatePollTimer];

    if (!SGFlag(SGKeySponsorBlockEnabled, NO) || _isPaused || !_segments.count) return;

    double pos = statePosition(state);
    if (pos < 0) return;

    CFTimeInterval now = CACurrentMediaTime();
    if (now < _seekDeadline) {
        if (fabs(pos - _seekTarget) < 1.5 || pos >= _seekTarget - 0.25) {
            _seekDeadline = 0;
            _lastPosition = pos;
            _lastPositionTime = now;
        }
        return;
    }
    _seekDeadline = 0;

    BOOL manualScrub = NO;
    if (_lastPosition < 0) {
        manualScrub = YES;
    } else {
        double speed = [state respondsToSelector:@selector(playbackSpeed)] && state.playbackSpeed > 0 ? state.playbackSpeed : 1.0;
        double expected = _lastPosition + MAX(0.0, now - _lastPositionTime) * speed;
        if (fabs(pos - expected) > 3.0) manualScrub = YES;
    }
    _lastPosition = pos;
    _lastPositionTime = now;

    for (SGSponsorBlockSegment *seg in _segments) {
        BOOL inside = (pos >= seg.startTime - 2.0 && pos < seg.endTime + 0.5);
        if (!inside) {
            [_whitelistedUUIDs removeObject:seg.uuid];
            [_promptedUUIDs removeObject:seg.uuid];
            if ([SGSponsorBlockToast isPresentingPromptForSegment:seg]) {
                [SGSponsorBlockToast dismissImmediate:NO];
            }
        }
    }

    double minDur = SGSponsorBlockMinDuration();
    for (SGSponsorBlockSegment *seg in _segments) {
        if (seg.duration < minDur) continue;
        if (pos < seg.startTime || pos >= seg.endTime - 0.25) continue;
        if ([_whitelistedUUIDs containsObject:seg.uuid]) continue;

        SGSponsorBlockAction action = SGSponsorBlockActionForCategory(seg.category);
        if (action == SGSponsorBlockActionOff || action == SGSponsorBlockActionShowOnly) continue;

        if (action == SGSponsorBlockActionSkip && manualScrub && pos > seg.startTime + 1.5 &&
            SGFlag(SGKeySponsorBlockIgnoreManualScrub, NO)) {
            action = SGSponsorBlockActionPrompt;
        }

        if (action == SGSponsorBlockActionSkip) {
            [self performAutoSkipForSegment:seg atPosition:pos];
            return;
        }
        if (action == SGSponsorBlockActionPrompt) {
            if (![_promptedUUIDs containsObject:seg.uuid]) {
                [_promptedUUIDs addObject:seg.uuid];
                [self presentPromptForSegment:seg atPosition:pos];
            }
            return;
        }
    }
}

- (void)performAutoSkipForSegment:(SGSponsorBlockSegment *)firstSeg atPosition:(double)pos {
    double targetEnd = firstSeg.endTime;
    NSMutableArray<NSString *> *skippedUUIDs = [NSMutableArray arrayWithObject:firstSeg.uuid];
    double minDur = SGSponsorBlockMinDuration();

    BOOL chained = YES;
    while (chained) {
        chained = NO;
        for (SGSponsorBlockSegment *other in _segments) {
            if ([skippedUUIDs containsObject:other.uuid] || other.duration < minDur) continue;
            if (SGSponsorBlockActionForCategory(other.category) != SGSponsorBlockActionSkip) continue;
            if (other.startTime <= targetEnd + 0.5 && other.endTime > targetEnd) {
                targetEnd = other.endTime;
                [skippedUUIDs addObject:other.uuid];
                chained = YES;
            }
        }
    }

    if (_currentDuration > 0 && targetEnd >= _currentDuration - 0.5) {
        targetEnd = MAX(firstSeg.startTime, _currentDuration - 0.5);
    }
    if (targetEnd <= pos + 0.1) return;
    if (![self seekToPosition:targetEnd]) return;

    double undoTarget = firstSeg.startTime;
    double savedSeconds = MAX(0.0, targetEnd - firstSeg.startTime);
    for (NSString *uuid in skippedUUIDs) [_whitelistedUUIDs addObject:uuid];
    SGRecordSponsorBlockSkip(savedSeconds);

    if (SGEnabled(SGKeySponsorBlockHaptics)) {
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    }

    if (SGEnabled(SGKeySponsorBlockShowToast)) {
        NSString *episodeID = _currentEpisodeID;
        __weak typeof(self) weakSelf = self;
        [SGSponsorBlockToast showWithCategory:firstSeg.category duration:savedSeconds undoHandler:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf->_currentEpisodeID isEqualToString:episodeID]) return;
            for (NSString *uuid in skippedUUIDs) [strongSelf->_whitelistedUUIDs addObject:uuid];
            SGUndoSponsorBlockSkip(savedSeconds);
            [strongSelf seekToPosition:undoTarget];
        }];
    }
}

- (void)presentPromptForSegment:(SGSponsorBlockSegment *)seg atPosition:(double)pos {
    double remaining = MAX(1.0, seg.endTime - pos);
    if (SGEnabled(SGKeySponsorBlockHaptics)) {
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    }
    NSString *episodeID = _currentEpisodeID;
    __weak typeof(self) weakSelf = self;
    [SGSponsorBlockToast showPromptForSegment:seg remaining:remaining skipHandler:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf->_currentEpisodeID isEqualToString:episodeID]) return;
        SPTPlayerState *nowState = liveState();
        double nowPos = statePosition(nowState);
        if (nowPos < 0) nowPos = pos;
        double targetEnd = seg.endTime;
        if (strongSelf->_currentDuration > 0 && targetEnd >= strongSelf->_currentDuration - 0.5) {
            targetEnd = MAX(seg.startTime, strongSelf->_currentDuration - 0.5);
        }
        if ([strongSelf seekToPosition:targetEnd]) {
            [strongSelf->_whitelistedUUIDs addObject:seg.uuid];
            SGRecordSponsorBlockSkip(MAX(0.0, targetEnd - nowPos));
            if (SGEnabled(SGKeySponsorBlockHaptics)) {
                [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
            }
        }
    }];
}

@end

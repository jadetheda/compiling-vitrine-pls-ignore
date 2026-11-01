// Pill banner for SponsorBlock skip notifications (Undo) and skip prompts (Skip).
#import "SGSponsorBlockToast.h"
#import "SGSponsorBlock.h"
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"

static UIImage *dotImageForColor(UIColor *color) {
    if (!color) return nil;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(8, 8)]
        imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [color setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 8, 8)] fill];
        }];
}

@interface SGSponsorBlockToastView : UIView
@end

@implementation SGSponsorBlockToastView {
    UIVisualEffectView *_blur;
    UIImageView *_dotView;
    UILabel *_label;
    UIButton *_actionButton;
    void (^_actionHandler)(void);
}

- (instancetype)initWithMessage:(NSString *)message
                    buttonTitle:(NSString *)buttonTitle
                  categoryColor:(UIColor *)categoryColor
                         action:(void (^)(void))action {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _actionHandler = [action copy];

    self.layer.cornerRadius = 20;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_blur];

    if (categoryColor) {
        _dotView = [[UIImageView alloc] initWithImage:dotImageForColor(categoryColor)];
        [_blur.contentView addSubview:_dotView];
    }

    _label = [UILabel new];
    _label.text = message;
    _label.textColor = UIColor.whiteColor;
    _label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    [_blur.contentView addSubview:_label];

    _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_actionButton setTitle:buttonTitle ?: @"Skip" forState:UIControlStateNormal];
    _actionButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    UIColor *btnColor = [buttonTitle isEqualToString:@"Skip"]
        ? [UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:1.0]
        : SGGreen();
    [_actionButton setTitleColor:btnColor forState:UIControlStateNormal];
    [_actionButton addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
    [_blur.contentView addSubview:_actionButton];

    UISwipeGestureRecognizer *swipeUp = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipedUp)];
    swipeUp.direction = UISwipeGestureRecognizerDirectionUp;
    [self addGestureRecognizer:swipeUp];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _blur.frame = self.bounds;

    CGSize buttonSize = [_actionButton sizeThatFits:CGSizeMake(80, 30)];
    CGFloat btnWidth = MAX(56.0, buttonSize.width + 20.0);
    CGFloat left = 14;
    if (_dotView) {
        _dotView.frame = CGRectMake(left, (self.bounds.size.height - 8) / 2, 8, 8);
        left += 16;
    }

    CGFloat right = self.bounds.size.width - btnWidth - 6;
    _actionButton.frame = CGRectMake(right, 0, btnWidth, self.bounds.size.height);

    CGFloat maxLabelWidth = MAX(40, right - left - 8);
    CGSize labelSize = [_label sizeThatFits:CGSizeMake(maxLabelWidth, 30)];
    CGFloat labelWidth = MIN(labelSize.width, maxLabelWidth);
    _label.frame = CGRectMake(left, (self.bounds.size.height - labelSize.height) / 2, labelWidth, labelSize.height);
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGFloat maxTotalWidth = size.width > 0 ? size.width : 340;
    CGSize buttonSize = [_actionButton sizeThatFits:CGSizeMake(80, 30)];
    CGFloat btnWidth = MAX(56.0, buttonSize.width + 20.0);
    CGFloat overhead = 14 + (_dotView ? 16 : 0) + 8 + btnWidth + 6;
    CGFloat maxLabelWidth = MAX(40, maxTotalWidth - overhead);
    CGSize labelSize = [_label sizeThatFits:CGSizeMake(maxLabelWidth, 30)];
    CGFloat totalWidth = MIN(maxTotalWidth, MIN(labelSize.width, maxLabelWidth) + overhead);
    return CGSizeMake(totalWidth, 40);
}

- (void)buttonTapped {
    self.userInteractionEnabled = NO;
    void (^handler)(void) = _actionHandler;
    _actionHandler = nil;
    [SGSponsorBlockToast dismissImmediate:YES];
    if (handler) handler();
}

- (void)swipedUp {
    [SGSponsorBlockToast dismissImmediate:NO];
}

@end

static SGSponsorBlockToastView *sg_currentToast;
static NSString *sg_currentToastSegmentUUID;
static dispatch_block_t sg_dismissBlock;
static CFTimeInterval sg_toastShownStamp;

static UIView *targetToastParent(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive &&
            windowScene.activationState != UISceneActivationStateForegroundInactive) continue;
        UIWindow *fallback = nil;
        for (UIWindow *w in windowScene.windows) {
            if (w.hidden || w.alpha < 0.01 || !w.rootViewController) continue;
            NSString *cls = NSStringFromClass(w.class);
            if ([cls containsString:@"SheetWindow"] || [cls containsString:@"TextEffects"] || [cls containsString:@"Keyboard"]) continue;
            if (w.isKeyWindow) return w;
            if (!fallback) fallback = w;
        }
        if (fallback) return fallback;
    }
    UIViewController *top = SGTopController();
    return top.view.window ?: top.view;
}

@implementation SGSponsorBlockToast

+ (void)showWithMessage:(NSString *)message
            buttonTitle:(NSString *)buttonTitle
          categoryColor:(UIColor *)categoryColor
            segmentUUID:(NSString *)segmentUUID
        displayDuration:(NSTimeInterval)displayDuration
                 action:(void (^)(void))action {
    void (^work)(void) = ^{
        [self dismissImmediate:YES];

        UIView *parent = targetToastParent();
        if (!parent || parent.bounds.size.width <= 0) return;

        SGSponsorBlockToastView *toast = [[SGSponsorBlockToastView alloc] initWithMessage:message
                                                                              buttonTitle:buttonTitle
                                                                            categoryColor:categoryColor
                                                                                   action:action];
        CGFloat maxWidth = MAX(200, parent.bounds.size.width - 32);
        CGSize size = [toast sizeThatFits:CGSizeMake(maxWidth, 40)];
        CGFloat topInset = 30;
        if (parent.safeAreaInsets.top > 0) {
            topInset = parent.safeAreaInsets.top + 10;
        } else if ([parent isKindOfClass:UIWindow.class]) {
            UIViewController *root = ((UIWindow *)parent).rootViewController;
            if (root.view.safeAreaInsets.top > 0) topInset = root.view.safeAreaInsets.top + 10;
        }
        toast.frame = CGRectMake((parent.bounds.size.width - size.width) / 2, topInset, size.width, size.height);
        toast.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        [toast layoutIfNeeded];

        toast.alpha = 0;
        toast.transform = CGAffineTransformMakeScale(0.85, 0.85);
        [parent addSubview:toast];
        sg_currentToast = toast;
        sg_currentToastSegmentUUID = [segmentUUID copy];
        sg_toastShownStamp = CACurrentMediaTime();

        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction animations:^{
            toast.alpha = 1.0;
            toast.transform = CGAffineTransformIdentity;
        } completion:nil];

        if (displayDuration > 0) {
            sg_dismissBlock = dispatch_block_create(0, ^{ [self dismiss]; });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(displayDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), sg_dismissBlock);
        }
    };

    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

+ (void)showWithCategory:(NSString *)category
                duration:(NSTimeInterval)duration
             undoHandler:(void (^)(void))undoHandler {
    NSString *name = SGSponsorBlockCategoryDisplayName(category);
    NSString *msg = duration >= 1.0
        ? [NSString stringWithFormat:@"Skipped %@ (%@)", name, SGFormatSponsorBlockDuration(duration)]
        : [NSString stringWithFormat:@"Skipped %@", name];
    [self showWithMessage:msg
              buttonTitle:@"Undo"
            categoryColor:SGSponsorBlockCategoryColor(category)
              segmentUUID:nil
          displayDuration:SGSponsorBlockToastDuration()
                   action:undoHandler];
}

+ (void)showPromptForSegment:(SGSponsorBlockSegment *)segment
                   remaining:(NSTimeInterval)remaining
                 skipHandler:(void (^)(void))skipHandler {
    if (!segment.uuid.length) return;
    NSString *name = SGSponsorBlockCategoryDisplayName(segment.category);
    NSString *msg = remaining >= 1.0
        ? [NSString stringWithFormat:@"%@ (%@)", name, SGFormatSponsorBlockDuration(remaining)]
        : name;
    NSTimeInterval promptPref = SGSponsorBlockPromptDuration();
    NSTimeInterval displaySeconds = (promptPref > 0 && promptPref < SGSponsorBlockPromptDurationInfinite)
        ? MIN(promptPref, MAX(1.0, remaining))
        : 0;
    [self showWithMessage:msg
              buttonTitle:@"Skip"
            categoryColor:SGSponsorBlockCategoryColor(segment.category)
              segmentUUID:segment.uuid
          displayDuration:displaySeconds
                   action:skipHandler];
}

+ (BOOL)isPresentingPromptForSegment:(SGSponsorBlockSegment *)segment {
    return segment.uuid.length && sg_currentToast != nil && [sg_currentToastSegmentUUID isEqualToString:segment.uuid];
}

+ (void)updateActiveToastTimeout {
    void (^work)(void) = ^{
        if (!sg_currentToast) return;
        if (sg_dismissBlock) {
            dispatch_block_cancel(sg_dismissBlock);
            sg_dismissBlock = nil;
        }
        NSTimeInterval timeout = 0;
        if (sg_currentToastSegmentUUID.length) {
            NSTimeInterval promptPref = SGSponsorBlockPromptDuration();
            if (promptPref > 0 && promptPref < SGSponsorBlockPromptDurationInfinite) timeout = promptPref;
        } else {
            if (!SGEnabled(SGKeySponsorBlockShowToast)) {
                [self dismiss];
                return;
            }
            timeout = SGSponsorBlockToastDuration();
        }
        if (timeout > 0) {
            CFTimeInterval elapsed = sg_toastShownStamp > 0 ? MAX(0.0, CACurrentMediaTime() - sg_toastShownStamp) : 0.0;
            NSTimeInterval remaining = MAX(0.25, timeout - elapsed);
            sg_dismissBlock = dispatch_block_create(0, ^{ [self dismiss]; });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), dispatch_get_main_queue(), sg_dismissBlock);
        }
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

+ (void)dismiss {
    [self dismissImmediate:NO];
}

+ (void)dismissImmediate:(BOOL)immediate {
    void (^work)(void) = ^{
        if (sg_dismissBlock) {
            dispatch_block_cancel(sg_dismissBlock);
            sg_dismissBlock = nil;
        }
        sg_currentToastSegmentUUID = nil;
        sg_toastShownStamp = 0;
        if (!sg_currentToast) return;
        SGSponsorBlockToastView *toast = sg_currentToast;
        sg_currentToast = nil;
        toast.userInteractionEnabled = NO;

        if (immediate) {
            [toast removeFromSuperview];
            return;
        }

        [UIView animateWithDuration:0.2 animations:^{
            toast.alpha = 0;
            toast.transform = CGAffineTransformMakeScale(0.9, 0.9);
        } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    };

    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

@end

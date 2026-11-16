#import "SGMarquee.h"

// Speed in pt/s, initial/cycle rest duration in seconds, gap between wrap-around text copies, and edge fade width.
// Measured 1:1 against Apple Music: exactly 4.0 s rest delay, 40.0 pt/s speed, 36.0 pt loop gap, and 14.0 pt edge fade.
static const CGFloat kSpeed = 40.0;
static const CGFloat kLoopGap = 36.0;
static const CGFloat kFade = 14.0;
static const CFTimeInterval kRest = 4.0;
static NSString *const kScroll = @"sg.marquee";

static NSAttributedString *SGRStripTruncatingParagraphStyle(NSAttributedString *attr) {
    if (!attr || attr.length == 0) return attr;
    NSMutableAttributedString *clean = [attr mutableCopy];
    [clean enumerateAttribute:NSParagraphStyleAttributeName inRange:NSMakeRange(0, clean.length) options:0 usingBlock:^(NSParagraphStyle *style, NSRange range, __unused BOOL *stop) {
        if (style && style.lineBreakMode != NSLineBreakByClipping) {
            NSMutableParagraphStyle *m = [style mutableCopy];
            m.lineBreakMode = NSLineBreakByClipping;
            [clean addAttribute:NSParagraphStyleAttributeName value:m range:range];
        }
    }];
    return clean;
}

@implementation SGMarqueeLabel {
    UIView *_maskView;
    UIView *_contentView;
    UILabel *_label1;
    UILabel *_label2;
    UIImageView *_badge1;
    UIImageView *_badge2;
    CAGradientLayer *_fade;
    CGFloat _scrolled;   // how far the running animation travels, 0 while still
    CGFloat _lastWidth;  // last bounds width used to compute fade stop locations
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.clipsToBounds = YES;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitStaticText;

    _maskView = [UIView new];
    _maskView.userInteractionEnabled = NO;
    _maskView.clipsToBounds = YES;
    [self addSubview:_maskView];

    _contentView = [UIView new];
    _contentView.userInteractionEnabled = NO;
    [_maskView addSubview:_contentView];

    _label1 = [UILabel new];
    [_contentView addSubview:_label1];

    _label2 = [UILabel new];
    _label2.hidden = YES;
    [_contentView addSubview:_label2];

    _badge1 = [UIImageView new];
    _badge1.contentMode = UIViewContentModeScaleAspectFit;
    _badge1.layer.compositingFilter = @"plusL";
    _badge1.hidden = YES;
    [_contentView addSubview:_badge1];

    _badge2 = [UIImageView new];
    _badge2.contentMode = UIViewContentModeScaleAspectFit;
    _badge2.layer.compositingFilter = @"plusL";
    _badge2.hidden = YES;
    [_contentView addSubview:_badge2];

    _fade = [CAGradientLayer layer];
    _fade.startPoint = CGPointMake(0, 0.5);
    _fade.endPoint = CGPointMake(1, 0.5);

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(setNeedsLayout)
                                               name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSString *)text { return _label1.text; }
- (NSAttributedString *)attributedText { return _label1.attributedText; }
- (UIFont *)font { return _label1.font; }
- (UIColor *)textColor { return _label1.textColor; }

- (void)resetScrollAnimation {
    _scrolled = -1;
    _lastWidth = -1;
    [_contentView.layer removeAnimationForKey:kScroll];
    [_fade removeAnimationForKey:@"mask.fade"];
    _contentView.transform = CGAffineTransformIdentity;
    [self setNeedsLayout];
}

- (void)setText:(NSString *)text {
    if ([text isEqualToString:_label1.text]) return;
    _label1.text = text;
    _label2.text = text;
    self.accessibilityLabel = text;
    [self resetScrollAnimation];
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    NSAttributedString *clean = SGRStripTruncatingParagraphStyle(attributedText);
    if ((clean == nil && _label1.attributedText == nil) ||
        (clean && _label1.attributedText && [clean isEqualToAttributedString:_label1.attributedText])) {
        return;
    }
    _label1.attributedText = clean;
    _label2.attributedText = clean;
    self.accessibilityLabel = clean.string;
    [self resetScrollAnimation];
}

- (void)setTrailingBadgeImage:(UIImage *)trailingBadgeImage {
    if (_trailingBadgeImage == trailingBadgeImage) return;
    _trailingBadgeImage = trailingBadgeImage;
    _badge1.image = trailingBadgeImage;
    _badge2.image = trailingBadgeImage;
    [self resetScrollAnimation];
}

- (void)setTrailingBadgeGap:(CGFloat)trailingBadgeGap {
    if (fabs(_trailingBadgeGap - trailingBadgeGap) < 0.01) return;
    _trailingBadgeGap = trailingBadgeGap;
    [self resetScrollAnimation];
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize s = [_label1 sizeThatFits:size];
    if (_trailingBadgeImage) {
        s.width += (_trailingBadgeGap > 0.0 ? _trailingBadgeGap : 6.33) + _trailingBadgeImage.size.width;
    }
    return s;
}

- (void)setFont:(UIFont *)font {
    if (_label1.font == font || [_label1.font isEqual:font]) return;
    _label1.font = font;
    _label2.font = font;
    [self resetScrollAnimation];
}

- (void)setTextColor:(UIColor *)textColor {
    _label1.textColor = textColor;
    _label2.textColor = textColor;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self resetScrollAnimation];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;
    _maskView.frame = self.bounds;

    CGFloat textWidth = ceil([_label1 sizeThatFits:CGSizeMake(CGFLOAT_MAX, size.height)].width);
    CGSize badgeSize = _trailingBadgeImage ? _trailingBadgeImage.size : CGSizeZero;
    BOOL hasBadge = (_trailingBadgeImage != nil && badgeSize.width > 0.0);
    CGFloat badgeGap = hasBadge ? (_trailingBadgeGap > 0.0 ? _trailingBadgeGap : 6.33) : 0.0;
    CGFloat badgeTotalW = hasBadge ? (badgeGap + badgeSize.width) : 0.0;
    CGFloat itemWidth = textWidth + badgeTotalW;
    CGFloat badgeY = round(((size.height - badgeSize.height) * 0.5 + 0.33) * 3.0) / 3.0;

    CGFloat overflow = itemWidth - size.width;
    BOOL scrolls = overflow > 0.5 && !UIAccessibilityIsReduceMotionEnabled() && self.window;

    if (!scrolls) {
        _label2.hidden = YES;
        _badge2.hidden = YES;
        _label1.lineBreakMode = NSLineBreakByTruncatingTail;
        CGFloat availTextW = MAX(0.0, size.width - badgeTotalW);
        CGFloat dispTextW = MIN(textWidth, availTextW);
        _label1.frame = CGRectMake(0, 0, dispTextW, size.height);
        if (hasBadge) {
            _badge1.hidden = NO;
            _badge1.frame = CGRectMake(dispTextW + badgeGap, badgeY, badgeSize.width, badgeSize.height);
        } else {
            _badge1.hidden = YES;
        }
        _contentView.frame = CGRectMake(0, 0, size.width, size.height);
        _contentView.transform = CGAffineTransformIdentity;
        [_contentView.layer removeAnimationForKey:kScroll];
        [_fade removeAnimationForKey:@"mask.fade"];
        _maskView.layer.mask = nil;
        _scrolled = 0;
        _lastWidth = size.width;
        return;
    }

    _label1.lineBreakMode = NSLineBreakByClipping;
    _label2.lineBreakMode = NSLineBreakByClipping;
    _label2.hidden = NO;

    CGFloat travel = itemWidth + kLoopGap;
    _contentView.frame = CGRectMake(0, 0, travel * 2.0, size.height);
    _label1.frame = CGRectMake(0, 0, textWidth, size.height);
    _label2.frame = CGRectMake(travel, 0, textWidth, size.height);
    if (hasBadge) {
        _badge1.hidden = NO;
        _badge2.hidden = NO;
        _badge1.frame = CGRectMake(textWidth + badgeGap, badgeY, badgeSize.width, badgeSize.height);
        _badge2.frame = CGRectMake(travel + textWidth + badgeGap, badgeY, badgeSize.width, badgeSize.height);
    } else {
        _badge1.hidden = YES;
        _badge2.hidden = YES;
    }

    CGFloat leftEdge = MIN(kFade / size.width, 0.15);
    CGFloat rightEdge = MIN(kFade / size.width, 0.15);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _maskView.layer.mask = _fade;
    _fade.frame = _maskView.bounds;
    _fade.colors = @[
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.blackColor.CGColor,
        (id)UIColor.blackColor.CGColor,
        (id)UIColor.clearColor.CGColor,
    ];
    _fade.locations = @[@0, @0, @(1.0 - rightEdge), @1.0];
    [CATransaction commit];

    if (fabs(travel - _scrolled) < 0.5 && fabs(size.width - _lastWidth) < 0.5 &&
        [_contentView.layer animationForKey:kScroll] && [_fade animationForKey:@"mask.fade"]) {
        return;
    }
    _scrolled = travel;
    _lastWidth = size.width;

    [_contentView.layer removeAnimationForKey:kScroll];
    [_fade removeAnimationForKey:@"mask.fade"];

    CFTimeInterval glide = travel / kSpeed;
    CFTimeInterval total = kRest + glide;

    CAKeyframeAnimation *scroll = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    scroll.values = @[@0, @0, @(-travel)];
    scroll.keyTimes = @[@0, @(kRest / total), @1.0];
    scroll.timingFunctions = @[
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
    ];
    scroll.duration = total;
    scroll.repeatCount = HUGE_VALF;
    scroll.removedOnCompletion = NO;
    scroll.fillMode = kCAFillModeForwards;
    if (@available(iOS 15.0, *)) scroll.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    [_contentView.layer addAnimation:scroll forKey:kScroll];

    CAKeyframeAnimation *maskAnim = [CAKeyframeAnimation animationWithKeyPath:@"locations"];
    NSArray *crisp = @[@0, @0, @(1.0 - rightEdge), @1.0];
    NSArray *faded = @[@0, @(leftEdge), @(1.0 - rightEdge), @1.0];
    CFTimeInterval fadeDuration = MIN(0.35, glide * 0.1);
    maskAnim.values = @[crisp, crisp, faded, faded, crisp];
    maskAnim.keyTimes = @[
        @0,
        @(kRest / total),
        @((kRest + fadeDuration) / total),
        @((total - fadeDuration) / total),
        @1.0,
    ];
    maskAnim.timingFunctions = @[
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
    ];
    maskAnim.duration = total;
    maskAnim.repeatCount = HUGE_VALF;
    maskAnim.removedOnCompletion = NO;
    maskAnim.fillMode = kCAFillModeForwards;
    if (@available(iOS 15.0, *)) maskAnim.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    [_fade addAnimation:maskAnim forKey:@"mask.fade"];
}

@end

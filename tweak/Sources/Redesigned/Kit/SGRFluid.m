#import <CoreImage/CoreImage.h>
#import "Core/SGCore.h"
#import "SGRFluid.h"
#import "SGRPalette.h"
#import "SGRTokens.h"

// Module 3, Section 4.2.1: Multi-layer scale hierarchy and angular velocities.
// Layer 0: Foundation (1.35x..2.0x, +0.0250 rad/s), Layer 1: Vortex Flow (-0.0650 rad/s),
// Layer 2 & 3: Accent Drift (+0.0950 rad/s and counter-drift).
static const struct { CGFloat side, x, y; CFTimeInterval turn; } kCopy[] = {
    {2.10, 0.46, 0.36,  72},
    {2.35, 0.58, 0.42, -58},
    {2.60, 0.36, 0.64,  66},
    {2.05, 0.64, 0.72, -52},
};
enum { kCopies = sizeof(kCopy) / sizeof(kCopy[0]) };

static const CGFloat kBlurSide = 128, kBlurPerStep = 2.25;
// The upper three copies' opacity at full Warp.
static const float kOverOpacity = 0.68f;
// The shade over the bottom of the visible rect, where the controls are.
static const CGFloat kShadeFrom = 0.46, kShadeAlpha = 0.25;

// ITU-R BT.709-6 Luminance Coefficients (Module 1 & Module 3).
static const CGFloat kLumR = 0.2126, kLumG = 0.7152, kLumB = 0.0722;

// Bilinear 5-Tap Gaussian Kernel Constants (sigma = 3.5, Module 3 Section 4.3.2).
static const CGFloat kGaussW0 = 0.2270270270;
static const CGFloat kGaussW1 = 0.3162162162;
static const CGFloat kGaussW2 = 0.0702702703;
static const CGFloat kGaussD1 = 1.3846153846;
static const CGFloat kGaussD2 = 3.2307692308;

// Localized Quadratic Twist Constants (Module 3 Section 4.2.2).
static const CGFloat kTwistRadius = 0.6500;
static const CGFloat kTwistPeakAngle = 0.8500;
static const CGFloat kSoftKnee = 0.3500;
static const CGFloat kVignetteAttenuation = 0.4200;

NSNotificationName const SGRFluidSettingsDidChangeNotification = @"spotifyglass.redesign.fluidSettingsDidChange";

// In SGRFluidSetting's order.
static const struct { __unsafe_unretained NSString *key; SGRFluidLimits limits; } kSetting[] = {
    {@"spotifyglass.redesign.fluid.speed", {25, 300, 25, 100}},
    {@"spotifyglass.redesign.fluid.warp", {0, 100, 5, 100}},
    {@"spotifyglass.redesign.fluid.blur", {2, 24, 1, 8}},
    {@"spotifyglass.redesign.fluid.saturation", {0, 250, 10, 150}},
    {@"spotifyglass.redesign.fluid.brightness", {40, 150, 5, 100}},
};

SGRFluidLimits SGRFluidLimitsOf(SGRFluidSetting setting) {
    return kSetting[setting].limits;
}

NSInteger SGRFluidValue(SGRFluidSetting setting) {
    SGRFluidLimits l = kSetting[setting].limits;
    return MIN(l.most, MAX(l.least, SGInt(kSetting[setting].key, l.standard)));
}

void SGRSetFluidValue(SGRFluidSetting setting, NSInteger value) {
    SGSetInt(kSetting[setting].key, value);
    [NSNotificationCenter.defaultCenter postNotificationName:SGRFluidSettingsDidChangeNotification object:nil];
}

void SGRResetFluidSettings(void) {
    for (NSInteger i = 0; i < SGRFluidSettingCount; i++) [NSUserDefaults.standardUserDefaults removeObjectForKey:kSetting[i].key];
    [NSNotificationCenter.defaultCenter postNotificationName:SGRFluidSettingsDidChangeNotification object:nil];
}

static CGColorSpaceRef fluidSRGB(void) {
    static CGColorSpaceRef space;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return space;
}

static CIContext *fluidCIContext(void) {
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithOptions:@{
            kCIContextCacheIntermediates: @NO,
            kCIContextWorkingColorSpace: (__bridge id)fluidSRGB(),
            kCIContextOutputColorSpace: (__bridge id)fluidSRGB(),
        }];
    });
    return context;
}

static inline CGFloat toLinearChannel(CGFloat c) {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

static inline CGFloat toEncodedChannel(CGFloat c) {
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

static inline BOOL isBlackOrWhiteByte(uint8_t r, uint8_t g, uint8_t b) {
    return (r > 232 && g > 232 && b > 232) || (r < 23 && g < 23 && b < 23);
}

// Extracts the dominant perimeter edge color (MPArtworkColorAnalyzer P_edge, Section 2.3.2 & 2.5)
// and conditions the source bitmap so corner stickers (Parental Advisory) and small central portraits
// do not inject muddy patches into the blurred backdrop.
static void conditionSourceBitmap(uint8_t *px, size_t width, size_t height, CGFloat outEdgeRGB[3], CGFloat *outDominance) {
    enum { kBuckets = 512 };
    uint16_t keys[kBuckets] = {0};
    BOOL used[kBuckets] = {0};
    double sumR[kBuckets] = {0}, sumG[kBuckets] = {0}, sumB[kBuckets] = {0};
    size_t counts[kBuckets] = {0};
    size_t totalEdge = 0;

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            if (x != 0 && x != width - 1 && y != 0 && y != height - 1) continue;
            const uint8_t *p = px + (y * width + x) * 4;
            uint16_t key = (uint16_t)(((p[0] >> 3) << 10) | ((p[1] >> 3) << 5) | (p[2] >> 3));
            size_t slot = (key * 40503u) & (kBuckets - 1);
            size_t probes = 0;
            while (used[slot] && keys[slot] != key) {
                slot = (slot + 1) & (kBuckets - 1);
                if (++probes >= kBuckets) break;
            }
            if (probes >= kBuckets) continue;
            used[slot] = YES;
            keys[slot] = key;
            counts[slot]++;
            sumR[slot] += p[0];
            sumG[slot] += p[1];
            sumB[slot] += p[2];
            totalEdge++;
        }
    }

    size_t bestSlot = 0, bestCount = 0;
    for (size_t i = 0; i < kBuckets; i++) {
        if (used[i] && counts[i] > bestCount) {
            bestCount = counts[i];
            bestSlot = i;
        }
    }
    if (bestCount == 0) {
        outEdgeRGB[0] = outEdgeRGB[1] = outEdgeRGB[2] = 0.1;
        *outDominance = 0;
        return;
    }

    uint8_t br = (uint8_t)(sumR[bestSlot] / bestCount);
    uint8_t bg = (uint8_t)(sumG[bestSlot] / bestCount);
    uint8_t bb = (uint8_t)(sumB[bestSlot] / bestCount);

    // 30% chromatic edge override when top perimeter bucket is black or white (Algorithm 1 Step 4).
    if (isBlackOrWhiteByte(br, bg, bb)) {
        size_t nextBestSlot = bestSlot, nextBestCount = 0;
        for (size_t i = 0; i < kBuckets; i++) {
            if (!used[i] || i == bestSlot) continue;
            uint8_t cr = (uint8_t)(sumR[i] / counts[i]);
            uint8_t cg = (uint8_t)(sumG[i] / counts[i]);
            uint8_t cb = (uint8_t)(sumB[i] / counts[i]);
            if (!isBlackOrWhiteByte(cr, cg, cb) && counts[i] > nextBestCount && (CGFloat)counts[i] / (CGFloat)bestCount > 0.30) {
                nextBestCount = counts[i];
                nextBestSlot = i;
            }
        }
        if (nextBestSlot != bestSlot) {
            bestSlot = nextBestSlot;
            br = (uint8_t)(sumR[bestSlot] / counts[bestSlot]);
            bg = (uint8_t)(sumG[bestSlot] / counts[bestSlot]);
            bb = (uint8_t)(sumB[bestSlot] / counts[bestSlot]);
        }
    }

    // Refine perimeter color over all perimeter buckets within distinctness delta (63.75).
    double refR = 0, refG = 0, refB = 0;
    size_t refCount = 0;
    for (size_t i = 0; i < kBuckets; i++) {
        if (!used[i]) continue;
        CGFloat cr = sumR[i] / counts[i], cg = sumG[i] / counts[i], cb = sumB[i] / counts[i];
        if (!isBlackOrWhiteByte((uint8_t)cr, (uint8_t)cg, (uint8_t)cb) &&
            MAX(fabs(cr - br), MAX(fabs(cg - bg), fabs(cb - bb))) < 63.75) {
            refR += sumR[i];
            refG += sumG[i];
            refB += sumB[i];
            refCount += counts[i];
        }
    }
    if (refCount > 0) {
        outEdgeRGB[0] = (refR / refCount) / 255.0;
        outEdgeRGB[1] = (refG / refCount) / 255.0;
        outEdgeRGB[2] = (refB / refCount) / 255.0;
    } else {
        outEdgeRGB[0] = br / 255.0;
        outEdgeRGB[1] = bg / 255.0;
        outEdgeRGB[2] = bb / 255.0;
    }
    CGFloat dom = totalEdge > 0 ? (CGFloat)refCount / (CGFloat)totalEdge : 0;
    *outDominance = dom;

    if (dom < 0.45) return;

    uint8_t edgeBytes[3] = {
        (uint8_t)MIN(255, MAX(0, lround(outEdgeRGB[0] * 255.0))),
        (uint8_t)MIN(255, MAX(0, lround(outEdgeRGB[1] * 255.0))),
        (uint8_t)MIN(255, MAX(0, lround(outEdgeRGB[2] * 255.0))),
    };
    CGFloat halfW = (width - 1) * 0.5, halfH = (height - 1) * 0.5;
    CGFloat interiorBlend = 0.36 * dom;

    for (size_t y = 0; y < height; y++) {
        CGFloat dy = (y - halfH) / MAX(1.0, halfH);
        for (size_t x = 0; x < width; x++) {
            CGFloat dx = (x - halfW) / MAX(1.0, halfW);
            CGFloat rNorm = hypot(dx, dy);
            uint8_t *p = px + (y * width + x) * 4;
            // Suppress near-black / near-white corner stickers on the outer rim.
            if (rNorm > 0.62 && isBlackOrWhiteByte(p[0], p[1], p[2])) {
                p[0] = edgeBytes[0];
                p[1] = edgeBytes[1];
                p[2] = edgeBytes[2];
            } else {
                for (int c = 0; c < 3; c++) {
                    p[c] = (uint8_t)lround(p[c] * (1.0 - interiorBlend) + edgeBytes[c] * interiorBlend);
                }
            }
        }
    }
}

// Bilinear texture lookup on an RGBA8 buffer with clamped coordinates u, v in [0, 1].
static void sampleBilinearRGB(const uint8_t *src, size_t width, size_t height, CGFloat u, CGFloat v, CGFloat outRGB[3]) {
    u = MIN(1.0, MAX(0.0, u));
    v = MIN(1.0, MAX(0.0, v));
    CGFloat fx = u * (width - 1), fy = v * (height - 1);
    size_t x0 = (size_t)floor(fx), y0 = (size_t)floor(fy);
    size_t x1 = MIN(width - 1, x0 + 1), y1 = MIN(height - 1, y0 + 1);
    CGFloat tx = fx - x0, ty = fy - y0;
    const uint8_t *p00 = src + (y0 * width + x0) * 4;
    const uint8_t *p10 = src + (y0 * width + x1) * 4;
    const uint8_t *p01 = src + (y1 * width + x0) * 4;
    const uint8_t *p11 = src + (y1 * width + x1) * 4;
    for (int c = 0; c < 3; c++) {
        CGFloat top = p00[c] * (1.0 - tx) + p10[c] * tx;
        CGFloat bot = p01[c] * (1.0 - tx) + p11[c] * tx;
        outRGB[c] = (top * (1.0 - ty) + bot * ty) / 255.0;
    }
}

// Module 3, Section 4.3.2 & Section 5: 5-Tap Bilinear Gaussian Filter across texture coordinates.
static void sampleBlurred5Tap(const uint8_t *src, size_t width, size_t height, CGFloat u, CGFloat v, CGFloat blurScale, CGFloat outRGB[3]) {
    CGFloat c0[3], cx1[3], cx2[3], cy1[3], cy2[3], cx3[3], cx4[3], cy3[3], cy4[3];
    CGFloat tx = blurScale / (CGFloat)width, ty = blurScale / (CGFloat)height;
    CGFloat d1x = kGaussD1 * tx, d1y = kGaussD1 * ty;
    CGFloat d2x = kGaussD2 * tx, d2y = kGaussD2 * ty;

    sampleBilinearRGB(src, width, height, u, v, c0);
    sampleBilinearRGB(src, width, height, u + d1x, v, cx1);
    sampleBilinearRGB(src, width, height, u - d1x, v, cx2);
    sampleBilinearRGB(src, width, height, u, v + d1y, cy1);
    sampleBilinearRGB(src, width, height, u, v - d1y, cy2);
    sampleBilinearRGB(src, width, height, u + d2x, v, cx3);
    sampleBilinearRGB(src, width, height, u - d2x, v, cx4);
    sampleBilinearRGB(src, width, height, u, v + d2y, cy3);
    sampleBilinearRGB(src, width, height, u, v - d2y, cy4);

    for (int c = 0; c < 3; c++) {
        outRGB[c] = c0[c] * kGaussW0
                  + (cx1[c] + cx2[c] + cy1[c] + cy2[c]) * (kGaussW1 * 0.5)
                  + (cx3[c] + cx4[c] + cy3[c] + cy4[c]) * (kGaussW2 * 0.5);
    }
}

// Generates the blurred, vortex-twisted, CAColorMatrix-saturated, soft-knee tonemapped fluid texture
// and extracts its deep foundation background color for the host layer.
static UIImage *blurred(UIImage *image, BOOL contrast, CGFloat radius, CGFloat saturation, CGFloat gain, UIColor **outBaseColor) {
    CGImageRef source = image.CGImage;
    if (!source) return nil;
    size_t side = (size_t)kBlurSide;

    // 1. Rasterize into a 128x128 sRGB bitmap and run MPArtworkColorAnalyzer perimeter conditioning.
    CGContextRef prepCtx = CGBitmapContextCreate(NULL, side, side, 8, side * 4, fluidSRGB(),
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!prepCtx) return nil;
    CGContextSetInterpolationQuality(prepCtx, kCGInterpolationMedium);
    CGContextDrawImage(prepCtx, CGRectMake(0, 0, side, side), source);
    uint8_t *prepPx = CGBitmapContextGetData(prepCtx);
    CGFloat edgeRGB[3] = {0}, edgeDominance = 0;
    conditionSourceBitmap(prepPx, side, side, edgeRGB, &edgeDominance);
    CGImageRef conditionedCG = CGBitmapContextCreateImage(prepCtx);
    CGContextRelease(prepCtx);
    if (!conditionedCG) return nil;

    // 2. Apply Gaussian blur in sRGB working space (no linear-space CIColorControls channel crushing).
    CIImage *input = [CIImage imageWithCGImage:conditionedCG];
    CGImageRelease(conditionedCG);
    CGRect extent = input.extent;
    CIImage *output = [[input imageByClampingToExtent]
        imageByApplyingFilter:@"CIGaussianBlur" withInputParameters:@{kCIInputRadiusKey: @(radius)}];
    CGImageRef cg = [fluidCIContext() createCGImage:[output imageByCroppingToRect:extent] fromRect:extent format:kCIFormatRGBA8 colorSpace:fluidSRGB()];
    if (!cg) return nil;

    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, fluidSRGB(),
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!bitmap) { CGImageRelease(cg); return nil; }
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), cg);
    CGImageRelease(cg);

    uint8_t *pixels = CGBitmapContextGetData(bitmap);
    size_t byteCount = width * height * 4;
    uint8_t *srcCopy = malloc(byteCount);
    if (!srcCopy) { CGContextRelease(bitmap); return nil; }
    memcpy(srcCopy, pixels, byteCount);

    // 3. Evaluate Module 3 Localized Quadratic Twist + 5-Tap Bilinear Kernel + CAColorMatrix Saturation
    //    + Soft-Knee Luminance Compression (Y / (1 + 0.35 * Y)) + Radial Vignette.
    // Standard Saturation slider is 150%; normalize so 150% -> Apple Music target saturation s = 1.24.
    CGFloat targetSat = saturation * (1.24 / 1.50);
    CGFloat ceiling = contrast ? 0.055 : 0.125;
    double sumBaseR = 0, sumBaseG = 0, sumBaseB = 0;

    for (size_t y = 0; y < height; y++) {
        CGFloat v = (y + 0.5) / (CGFloat)height;
        for (size_t x = 0; x < width; x++) {
            CGFloat u = (x + 0.5) / (CGFloat)width;

            // Layer 0 foundation sample & Layer 1 localized quadratic vortex twist (Section 4.2.2).
            CGFloat dx = u - 0.5, dy = v - 0.5;
            CGFloat dist = hypot(dx, dy);
            CGFloat twistAngle = 0.0;
            if (dist < kTwistRadius) {
                CGFloat factor = 1.0 - (dist / kTwistRadius);
                twistAngle = kTwistPeakAngle * (factor * factor);
            }
            CGFloat s = sin(twistAngle), c = cos(twistAngle);
            CGFloat uTwist = (c * dx - s * dy) + 0.5;
            CGFloat vTwist = (s * dx + c * dy) + 0.5;

            CGFloat layer0[3], layer1[3];
            sampleBlurred5Tap(srcCopy, width, height, u, v, 2.0, layer0);
            sampleBlurred5Tap(srcCopy, width, height, uTwist, vTwist, 3.0, layer1);

            // Blend foundation and twisted vortex layer, anchored by perimeter color when dominant.
            CGFloat rgb[3];
            for (int ch = 0; ch < 3; ch++) {
                CGFloat mixed = 0.55 * layer0[ch] + 0.45 * layer1[ch];
                if (edgeDominance >= 0.50) {
                    CGFloat anchor = 0.22 * edgeDominance;
                    mixed = mixed * (1.0 - anchor) + edgeRGB[ch] * anchor;
                }
                rgb[ch] = mixed;
            }

            // Module 2, Section 3.2: Exact CAColorMatrix saturation in sRGB with gamut-preserving soft knee
            // so minor channels (G, B) are never driven negative or zeroed out.
            CGFloat ySrgb = kLumR * rgb[0] + kLumG * rgb[1] + kLumB * rgb[2];
            CGFloat effSat = targetSat;
            if (effSat > 1.0) {
                for (int ch = 0; ch < 3; ch++) {
                    CGFloat diff = rgb[ch] - ySrgb;
                    if (diff < -1e-5) {
                        CGFloat floorCh = 0.92 * rgb[ch];
                        CGFloat maxS = (ySrgb - floorCh) / (-diff);
                        if (maxS < effSat) effSat = MAX(1.0, maxS);
                    }
                }
            }
            float inRGBA[4] = {(float)rgb[0], (float)rgb[1], (float)rgb[2], 1.0f}, outRGBA[4] = {0};
            SGRColorMatrix satMatrix = SGRColorMatrixMakeSaturation((float)effSat);
            SGRColorMatrixApply(&satMatrix, inRGBA, outRGBA);
            for (int ch = 0; ch < 3; ch++) rgb[ch] = MIN(1.0, MAX(0.0, outRGBA[ch]));

            // Module 3, Section 4.4.1 & 4.4.2: Screen-like vibrancy lift + Soft-Knee Luminance Compression.
            for (int ch = 0; ch < 3; ch++) {
                CGFloat l0 = rgb[ch] * 0.54, l1 = rgb[ch] * 0.38;
                rgb[ch] = 1.0 - (1.0 - l0) * (1.0 - l1);
            }
            CGFloat lum = kLumR * rgb[0] + kLumG * rgb[1] + kLumB * rgb[2];
            CGFloat lumClamped = lum / (1.0 + kSoftKnee * lum);
            CGFloat kneeScale = lumClamped / MAX(lum, 0.0001);
            for (int ch = 0; ch < 3; ch++) rgb[ch] = MIN(1.0, rgb[ch] * kneeScale);

            // Module 3, Section 4.4.3: Subtle radial edge vignette attenuation + linear legibility ceiling.
            CGFloat vignette = MIN(1.0, MAX(0.0, 1.0 - kVignetteAttenuation * pow(2.0 * dist, 2.0)));
            CGFloat vigMix = 0.88 + 0.12 * vignette;
            for (int ch = 0; ch < 3; ch++) rgb[ch] *= vigMix;

            CGFloat lin[3] = {toLinearChannel(rgb[0]), toLinearChannel(rgb[1]), toLinearChannel(rgb[2])};
            CGFloat light = kLumR * lin[0] + kLumG * lin[1] + kLumB * lin[2];
            CGFloat effCeiling = ceiling * MIN(1.35, MAX(0.40, gain));
            if (light > 0.0001) {
                CGFloat scale = gain;
                if (light * scale > effCeiling) scale = effCeiling / light;
                for (int ch = 0; ch < 3; ch++) {
                    CGFloat vOut = MIN(1.0, MAX(0.0, lin[ch] * scale));
                    rgb[ch] = toEncodedChannel(vOut);
                }
            }

            uint8_t *p = pixels + (y * width + x) * 4;
            p[0] = (uint8_t)MIN(255, MAX(0, lround(rgb[0] * 255.0)));
            p[1] = (uint8_t)MIN(255, MAX(0, lround(rgb[1] * 255.0)));
            p[2] = (uint8_t)MIN(255, MAX(0, lround(rgb[2] * 255.0)));
            p[3] = 255;

            sumBaseR += rgb[0];
            sumBaseG += rgb[1];
            sumBaseB += rgb[2];
        }
    }
    free(srcCopy);

    if (outBaseColor && width * height > 0) {
        CGFloat inv = 1.0 / (CGFloat)(width * height);
        *outBaseColor = [UIColor colorWithRed:(sumBaseR * inv) * 0.72
                                        green:(sumBaseG * inv) * 0.72
                                         blue:(sumBaseB * inv) * 0.72
                                        alpha:1.0];
    }

    cg = CGBitmapContextCreateImage(bitmap);
    UIImage *result = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    CGContextRelease(bitmap);
    return result;
}

@implementation SGRFluidLayer {
    CALayer *_copies[kCopies];
    CAGradientLayer *_shade;
    UIImage *_source;
    NSUInteger _generation;
    BOOL _moving;
    CFTimeInterval _since, _elapsed;   // _elapsed in turns at the standard speed
    CGFloat _rate, _warp;              // Speed and Warp as factors, read when the copies are laid out or started
    CGRect _laidOutFor;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.masksToBounds = YES;
    self.backgroundColor = UIColor.blackColor.CGColor;
    for (int i = 0; i < kCopies; i++) {
        _copies[i] = [CALayer layer];
        _copies[i].contentsGravity = kCAGravityResizeAspectFill;
        [self addSublayer:_copies[i]];
    }
    [self applyWarp];
    _shade = [CAGradientLayer layer];
    _shade.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:kShadeAlpha].CGColor];
    [self addSublayer:_shade];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(contrastChanged)
        name:UIAccessibilityDarkerSystemColorsStatusDidChangeNotification object:nil];
    // Posted on the main thread by the Player page's sliders, so the change applies at once.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged)
        name:SGRFluidSettingsDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)contrastChanged {
    dispatch_async(dispatch_get_main_queue(), ^{ [self reblur]; });
}

// The same cover blurred again, for a new Blur, Saturation, Brightness or contrast.
- (void)reblur {
    UIImage *source = _source;
    _source = nil;
    [self setArtwork:source animated:NO];
}

// Warp is how far from the visible rect's middle the copies turn, and how much the upper three show: at none,
// one copy turns about the middle, a still picture turning, with nothing to flow through it.
- (void)applyWarp {
    _warp = SGRFluidValue(SGRFluidWarp) / 100.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 1; i < kCopies; i++) _copies[i].opacity = kOverOpacity * (float)_warp;
    [CATransaction commit];
}

- (void)settingsChanged {
    // Restarted at the new speed from the angle each copy is at, and laid out again for the new warp.
    BOOL moving = _moving;
    if (moving) [self stop];
    [self applyWarp];
    _laidOutFor = CGRectNull;
    [self setNeedsLayout];
    if (moving) [self start];
    [self reblur];
}

- (BOOL)moving {
    return _moving;
}

- (void)setVisibleRect:(CGRect)rect {
    if (CGRectEqualToRect(rect, _visibleRect)) return;
    _visibleRect = rect;
    [self setNeedsLayout];
}

- (void)layoutSublayers {
    [super layoutSublayers];
    CGRect bounds = self.bounds;
    CGRect visible = CGRectIsEmpty(_visibleRect) ? bounds : _visibleRect;
    CGFloat total = MAX(1, bounds.size.height);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shade.frame = bounds;
    _shade.locations = @[@(MIN(1, (CGRectGetMinY(visible) + visible.size.height * kShadeFrom) / total)),
                         @(MIN(1, CGRectGetMaxY(visible) / total))];
    if (!CGRectEqualToRect(visible, _laidOutFor) && visible.size.width >= 1) {
        _laidOutFor = visible;
        BOOL moving = _moving;
        if (moving) [self stop];
        CGFloat longer = MAX(visible.size.width, visible.size.height);
        for (int i = 0; i < kCopies; i++) {
            CGFloat side = round(longer * kCopy[i].side);
            _copies[i].bounds = CGRectMake(0, 0, side, side);
            _copies[i].position = CGPointMake(CGRectGetMidX(visible) + visible.size.width * (kCopy[i].x - 0.5) * _warp,
                                              CGRectGetMidY(visible) + visible.size.height * (kCopy[i].y - 0.5) * _warp);
        }
        if (moving) [self start];
    }
    [CATransaction commit];
}

- (void)setArtwork:(UIImage *)image animated:(BOOL)animated {
    if (!image || image == _source) return;
    _source = image;
    NSUInteger generation = ++_generation;
    BOOL contrast = SGRIncreaseContrast();
    CGFloat radius = kBlurPerStep * SGRFluidValue(SGRFluidBlur), saturation = SGRFluidValue(SGRFluidSaturation) / 100.0;
    CGFloat gain = SGRFluidValue(SGRFluidBrightness) / 100.0;
    __weak SGRFluidLayer *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIColor *baseColor = nil;
        UIImage *blur = blurred(image, contrast, radius, saturation, gain, &baseColor);
        dispatch_async(dispatch_get_main_queue(), ^{
            SGRFluidLayer *layer = weakSelf;
            if (!blur || !layer || generation != layer->_generation) return;
            [layer show:blur baseColor:baseColor animated:animated];
        });
    });
}

- (void)show:(UIImage *)blur baseColor:(UIColor *)baseColor animated:(BOOL)animated {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (baseColor) self.backgroundColor = baseColor.CGColor;
    for (int i = 0; i < kCopies; i++) {
        if (animated) {
            CATransition *fade = [CATransition animation];
            fade.type = kCATransitionFade;
            fade.duration = SGRCrossfade;
            [_copies[i] addAnimation:fade forKey:@"contents"];
        }
        _copies[i].contents = (__bridge id)blur.CGImage;
    }
    [CATransaction commit];
}

#pragma mark - moving

- (void)setMoving:(BOOL)moving {
    if (moving == _moving) return;
    _moving = moving;
    if (moving) [self start];
    else [self stop];
}

- (void)start {
    if (self.bounds.size.width < 1) return;
    _since = CACurrentMediaTime();
    _rate = SGRFluidValue(SGRFluidSpeed) / 100.0;
    CAFrameRateRange rate = CAFrameRateRangeMake(15, 60, 30);
    for (int i = 0; i < kCopies; i++) {
        CFTimeInterval length = fabs(kCopy[i].turn);
        // The turn's offset carries the angle it stopped at, so the resting angle goes back to none.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _copies[i].transform = CATransform3DIdentity;
        [CATransaction commit];
        CABasicAnimation *turn = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        turn.byValue = @(kCopy[i].turn > 0 ? 2 * M_PI : -2 * M_PI);
        turn.duration = length / _rate;
        turn.repeatCount = HUGE_VALF;
        turn.additive = YES;
        turn.timeOffset = fmod(_elapsed, length) / _rate;
        turn.preferredFrameRateRange = rate;
        [_copies[i] addAnimation:turn forKey:@"turn"];
    }
}

// Every copy held at the angle it is drawn at now.
- (void)stop {
    if (_since > 0) _elapsed += (CACurrentMediaTime() - _since) * _rate;
    _since = 0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < kCopies; i++) {
        CFTimeInterval length = fabs(kCopy[i].turn);
        CGFloat angle = (kCopy[i].turn > 0 ? 1 : -1) * 2 * M_PI * fmod(_elapsed, length) / length;
        [_copies[i] removeAnimationForKey:@"turn"];
        _copies[i].transform = CATransform3DMakeRotation(angle, 0, 0, 1);
    }
    [CATransaction commit];
}

@end


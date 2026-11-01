#import <CoreImage/CoreImage.h>
#import "Core/SGCore.h"
#import "SGRPalette.h"
#import "SGRTokens.h"

static const size_t kSample = 64;      // the artwork shrunk to this square before its colors are read
static const size_t kEdgeRows = 10;    // the bottom rows of it averaged into the edge color
static const CGFloat kMaxSaturation = 0.76;
static const CGFloat kMaxLuminance = 0.085, kMaxLuminanceContrast = 0.04;
static const CGFloat kBackdropWidth = 160, kBackdropMaxHeight = 400, kBackdropSigma = 18;
static const CGFloat kDissolveWidth = 96, kDissolveSigma = 5;
static const CGFloat kFadeFrom = 0.55, kDissolveOpaque = 0.85;
// A tint: the artwork's dominant color, its saturation lifted by kTintSaturationLift up to kTintSaturationMax,
// brought down to kTintLuminance, then kTintShare of it mixed into the surface it tints.
static const CGFloat kTintLuminance = 0.04, kTintShare = 1.0;
static const CGFloat kTintSaturationLift = 1.2, kTintSaturationMax = 0.85;
// The faint tint of before (strong NO): no lift, 35% of the color held under 0.05 mixed into the surface.
static const CGFloat kFaintTintLuminance = 0.05, kFaintTintShare = 0.35;
// A moving field's colors: luminance held between these (the ceiling 0.07 with Increase Contrast, as a
// field's), saturation lifted by this much up to a cap, and a near-black one lifted by at most this factor.
static const CGFloat kFlowLuminanceMin = 0.035, kFlowLuminanceMax = 0.14;
static const CGFloat kFlowSaturationLift = 1.20, kFlowSaturationMax = 0.78, kFlowMaxLift = 4;

// ITU-R BT.709-6 luminance weights (Module 1 & Module 2).
static const CGFloat kLumR = 0.2126, kLumG = 0.7152, kLumB = 0.0722;

// MPArtworkColorAnalyzer / ITColor exact filtering thresholds (Module 1, Section 2.4).
static const CGFloat kNearWhiteThreshold = 232.0;      // 0.9098 * 255
static const CGFloat kNearBlackThreshold = 23.0;       // 0.0902 * 255
static const CGFloat kDarkBackgroundMidpoint = 127.5;  // 0.5000 * 255
static const CGFloat kMinTextSaturation = 0.1500;
static const CGFloat kEdgeDominanceRatio = 0.3000;     // 30% chromatic edge override
static const CGFloat kWCAGContrastThreshold = 1.6000;
static const CGFloat kAccessibleContrastThreshold = 3.0000;
static const CGFloat kDistinctnessChannelDelta = 63.7500; // 25% of 255
static const CGFloat kNeutralGrayDelta = 7.6500;          // 3% of 255
static const CGFloat kSoftKneeFactor = 0.3500;

@interface SGRPalette ()
@property (nonatomic, readwrite) UIColor *edgeColor;
@property (nonatomic, readwrite) UIColor *fieldColor;
@property (nonatomic, readwrite) UIColor *backgroundColor;
@property (nonatomic, readwrite) UIColor *primaryColor;
@property (nonatomic, readwrite) UIColor *secondaryColor;
@property (nonatomic, readwrite) UIColor *tertiaryColor;
@property (nonatomic, readwrite, getter=isBackgroundColorLight) BOOL backgroundColorLight;
@property (nonatomic, readwrite) UIImage *backdrop;
@property (nonatomic, readwrite) UIImage *dissolve;
@property (nonatomic, readwrite) NSArray<UIColor *> *flowColors;
@end

static dispatch_queue_t paletteQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("spotifyglass.redesign.palette", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    });
    return queue;
}

static CGColorSpaceRef sRGB(void) {
    static CGColorSpaceRef space;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return space;
}

// One context for the whole launch; CIContext is safe to share and costly to make.
static CIContext *blurContext(void) {
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO, kCIContextWorkingColorSpace: (__bridge id)sRGB()}];
    });
    return context;
}

static CGContextRef newBitmap(size_t width, size_t height) {
    return CGBitmapContextCreate(NULL, width, height, 8, width * 4, sRGB(), (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
}

static void drawFilling(CGContextRef context, CGImageRef image, size_t width, size_t height) {
    CGFloat iw = CGImageGetWidth(image), ih = CGImageGetHeight(image);
    CGFloat scale = MAX(width / iw, height / ih);
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake((width - iw * scale) / 2, (height - ih * scale) / 2, iw * scale, ih * scale), image);
}

#pragma mark - CAColorMatrix & WCAG math

SGRColorMatrix SGRColorMatrixMakeSaturation(float s) {
    float wr = (float)kLumR, wg = (float)kLumG, wb = (float)kLumB;
    float inv = 1.0f - s;
    return (SGRColorMatrix){
        inv * wr + s, inv * wg,     inv * wb,     0.0f, 0.0f,
        inv * wr,     inv * wg + s, inv * wb,     0.0f, 0.0f,
        inv * wr,     inv * wg,     inv * wb + s, 0.0f, 0.0f,
        0.0f,         0.0f,         0.0f,         1.0f, 0.0f,
    };
}

SGRColorMatrix SGRColorMatrixMakeBrightness(float b) {
    return (SGRColorMatrix){
        b,    0.0f, 0.0f, 0.0f, 0.0f,
        0.0f, b,    0.0f, 0.0f, 0.0f,
        0.0f, 0.0f, b,    0.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f, 0.0f,
    };
}

SGRColorMatrix SGRColorMatrixMakeContrast(float c) {
    float offset = 0.5f * (1.0f - c);
    return (SGRColorMatrix){
        c,    0.0f, 0.0f, 0.0f, offset,
        0.0f, c,    0.0f, 0.0f, offset,
        0.0f, 0.0f, c,    0.0f, offset,
        0.0f, 0.0f, 0.0f, 1.0f, 0.0f,
    };
}

void SGRColorMatrixApply(const SGRColorMatrix *m, const float inRGBA[4], float outRGBA[4]) {
    float r = inRGBA[0], g = inRGBA[1], b = inRGBA[2], a = inRGBA[3];
    float ro = m->m11 * r + m->m12 * g + m->m13 * b + m->m14 * a + m->m15;
    float go = m->m21 * r + m->m22 * g + m->m23 * b + m->m24 * a + m->m25;
    float bo = m->m31 * r + m->m32 * g + m->m33 * b + m->m34 * a + m->m35;
    float ao = m->m41 * r + m->m42 * g + m->m43 * b + m->m44 * a + m->m45;
    outRGBA[0] = fminf(1.0f, fmaxf(0.0f, ro));
    outRGBA[1] = fminf(1.0f, fmaxf(0.0f, go));
    outRGBA[2] = fminf(1.0f, fmaxf(0.0f, bo));
    outRGBA[3] = fminf(1.0f, fmaxf(0.0f, ao));
}

static inline CGFloat luminance255(CGFloat r, CGFloat g, CGFloat b) {
    return kLumR * r + kLumG * g + kLumB * b;
}

CGFloat SGRScaledLuminance255(CGFloat r255, CGFloat g255, CGFloat b255) {
    return luminance255(r255, g255, b255) + 12.75;
}

CGFloat SGRContrastRatio255(CGFloat r1, CGFloat g1, CGFloat b1, CGFloat r2, CGFloat g2, CGFloat b2) {
    CGFloat l1 = SGRScaledLuminance255(r1, g1, b1);
    CGFloat l2 = SGRScaledLuminance255(r2, g2, b2);
    return MAX(l1, l2) / MAX(MIN(l1, l2), 0.0001);
}

#pragma mark - MPArtworkColorAnalyzer / ITColor pipeline

typedef struct {
    CGFloat r, g, b; // [0.0, 255.0]
    size_t count;
    double score;
} SGRColorCluster;

static inline BOOL isNearWhite255(CGFloat r, CGFloat g, CGFloat b) {
    return r > kNearWhiteThreshold && g > kNearWhiteThreshold && b > kNearWhiteThreshold;
}

static inline BOOL isNearBlack255(CGFloat r, CGFloat g, CGFloat b) {
    return r < kNearBlackThreshold && g < kNearBlackThreshold && b < kNearBlackThreshold;
}

static inline BOOL isBlackOrWhite255(CGFloat r, CGFloat g, CGFloat b) {
    return isNearBlack255(r, g, b) || isNearWhite255(r, g, b);
}

static inline BOOL isDark255(CGFloat r, CGFloat g, CGFloat b) {
    return luminance255(r, g, b) < kDarkBackgroundMidpoint;
}

static inline BOOL isNeutralGray255(CGFloat r, CGFloat g, CGFloat b) {
    return fabs(r - g) < kNeutralGrayDelta && fabs(r - b) < kNeutralGrayDelta;
}

static inline BOOL isDistinct255(CGFloat r1, CGFloat g1, CGFloat b1, CGFloat r2, CGFloat g2, CGFloat b2) {
    return MAX(fabs(r1 - r2), MAX(fabs(g1 - g2), fabs(b1 - b2))) > kDistinctnessChannelDelta;
}

static inline BOOL isContrasting255(CGFloat r1, CGFloat g1, CGFloat b1, CGFloat r2, CGFloat g2, CGFloat b2) {
    return SGRContrastRatio255(r1, g1, b1, r2, g2, b2) >= kWCAGContrastThreshold;
}

// Exact RGB-to-HSV and minimum saturation booster (Section 2.2.3 & Algorithm 1 Step 8).
static void rgb255ToHSV(CGFloat r, CGFloat g, CGFloat b, CGFloat *outH, CGFloat *outS, CGFloat *outV) {
    CGFloat maxC = MAX(r, MAX(g, b)), minC = MIN(r, MIN(g, b)), delta = maxC - minC;
    *outV = maxC / 255.0;
    *outS = maxC > 0 ? delta / maxC : 0;
    if (delta <= 0) {
        *outH = 0;
        return;
    }
    CGFloat h;
    if (maxC == r) h = fmod((g - b) / delta, 6.0);
    else if (maxC == g) h = ((b - r) / delta) + 2.0;
    else h = ((r - g) / delta) + 4.0;
    if (h < 0) h += 6.0;
    *outH = h * 60.0;
}

static void hsvToRGB255(CGFloat h, CGFloat s, CGFloat v, CGFloat *outR, CGFloat *outG, CGFloat *outB) {
    CGFloat c = v * s;
    CGFloat x = c * (1.0 - fabs(fmod(h / 60.0, 2.0) - 1.0));
    CGFloat m = v - c;
    CGFloat r1 = 0, g1 = 0, b1 = 0;
    if (h < 60.0) { r1 = c; g1 = x; }
    else if (h < 120.0) { r1 = x; g1 = c; }
    else if (h < 180.0) { g1 = c; b1 = x; }
    else if (h < 240.0) { g1 = x; b1 = c; }
    else if (h < 300.0) { r1 = x; b1 = c; }
    else { r1 = c; b1 = x; }
    *outR = (r1 + m) * 255.0;
    *outG = (g1 + m) * 255.0;
    *outB = (b1 + m) * 255.0;
}

static void withMinSaturation255(CGFloat r, CGFloat g, CGFloat b, CGFloat minSat, CGFloat *outR, CGFloat *outG, CGFloat *outB) {
    CGFloat h, s, v;
    rgb255ToHSV(r, g, b, &h, &s, &v);
    if (s >= minSat || v <= 0) {
        *outR = r; *outG = g; *outB = b;
        return;
    }
    hsvToRGB255(h, minSat, v, outR, outG, outB);
}

// Section 2.6.2: Iterative lightness tuning loop for high-contrast accessibility mode.
static void tuneAccessibleLightness255(CGFloat *fgR, CGFloat *fgG, CGFloat *fgB, CGFloat bgR, CGFloat bgG, CGFloat bgB, BOOL findDarkText) {
    if (!SGRIncreaseContrast()) return;
    if (SGRContrastRatio255(*fgR, *fgG, *fgB, bgR, bgG, bgB) >= kAccessibleContrastThreshold) return;
    BOOL bgDark = isDark255(bgR, bgG, bgB);
    const CGFloat deltaL = 0.0500;
    for (int k = 0; k < 10; k++) {
        if (bgDark) {
            *fgR += deltaL * (255.0 - *fgR);
            *fgG += deltaL * (255.0 - *fgG);
            *fgB += deltaL * (255.0 - *fgB);
        } else {
            *fgR -= deltaL * (*fgR);
            *fgG -= deltaL * (*fgG);
            *fgB -= deltaL * (*fgB);
        }
        if (SGRContrastRatio255(*fgR, *fgG, *fgB, bgR, bgG, bgB) >= kAccessibleContrastThreshold) return;
    }
    CGFloat fallback = findDarkText ? 0.0 : 255.0;
    *fgR = *fgG = *fgB = fallback;
}

static int compareClustersByCountDesc(const void *a, const void *b) {
    const SGRColorCluster *ca = (const SGRColorCluster *)a;
    const SGRColorCluster *cb = (const SGRColorCluster *)b;
    if (cb->count != ca->count) return cb->count > ca->count ? 1 : -1;
    return cb->score > ca->score ? 1 : (cb->score < ca->score ? -1 : 0);
}

static int compareClustersByScoreDesc(const void *a, const void *b) {
    const SGRColorCluster *ca = (const SGRColorCluster *)a;
    const SGRColorCluster *cb = (const SGRColorCluster *)b;
    if (cb->score != ca->score) return cb->score > ca->score ? 1 : -1;
    return cb->count > ca->count ? 1 : (cb->count < ca->count ? -1 : 0);
}

// Extracts quantized RGB555 clusters over a pixel region (or perimeter P_edge when perimeterOnly is YES).
static size_t extractClusters(const uint8_t *px, size_t width, size_t height, BOOL perimeterOnly, SGRColorCluster *outClusters, size_t maxClusters) {
    enum { kHashSize = 2048 };
    uint16_t keys[kHashSize];
    BOOL occupied[kHashSize] = {0};
    double sumR[kHashSize] = {0}, sumG[kHashSize] = {0}, sumB[kHashSize] = {0}, scores[kHashSize] = {0};
    size_t counts[kHashSize] = {0};

    for (size_t y = 0; px && y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            if (perimeterOnly && x != 0 && x != width - 1 && y != 0 && y != height - 1) continue;
            const uint8_t *p = px + (y * width + x) * 4;
            if (p[3] < 128) continue;
            // Unpremultiply if needed
            CGFloat r = p[3] < 255 ? MIN(255.0, p[0] * 255.0 / p[3]) : p[0];
            CGFloat g = p[3] < 255 ? MIN(255.0, p[1] * 255.0 / p[3]) : p[1];
            CGFloat b = p[3] < 255 ? MIN(255.0, p[2] * 255.0 / p[3]) : p[2];
            uint16_t bucketKey = (uint16_t)((((int)r >> 3) << 10) | (((int)g >> 3) << 5) | ((int)b >> 3));
            size_t slot = (bucketKey * 40503u) & (kHashSize - 1);
            while (occupied[slot] && keys[slot] != bucketKey) {
                slot = (slot + 1) & (kHashSize - 1);
            }
            occupied[slot] = YES;
            keys[slot] = bucketKey;
            counts[slot]++;
            sumR[slot] += r;
            sumG[slot] += g;
            sumB[slot] += b;
            CGFloat h, s, v;
            rgb255ToHSV(r, g, b, &h, &s, &v);
            CGFloat bwPenalty = isBlackOrWhite255(r, g, b) ? 0.25 : 1.0;
            CGFloat grayPenalty = isNeutralGray255(r, g, b) ? 0.45 : 1.0;
            scores[slot] += (0.30 + s) * bwPenalty * grayPenalty;
        }
    }

    size_t minCount = (size_t)floor(0.01 * (double)height);
    size_t n = 0;
    for (size_t i = 0; i < kHashSize && n < maxClusters; i++) {
        if (!occupied[i] || counts[i] <= minCount) continue;
        CGFloat inv = 1.0 / (CGFloat)counts[i];
        outClusters[n++] = (SGRColorCluster){
            .r = sumR[i] * inv,
            .g = sumG[i] * inv,
            .b = sumB[i] * inv,
            .count = counts[i],
            .score = scores[i],
        };
    }
    return n;
}

typedef struct {
    CGFloat bg[3];
    CGFloat primary[3];
    CGFloat secondary[3];
    CGFloat tertiary[3];
    BOOL isLight;
    CGFloat edgeDominance;
} SGRArtworkColorAnalysis;

// Module 1, Section 2.5: Algorithm 1 (`MPArtworkColorAnalyzer` Color Assignment Pipeline).
static BOOL analyzeArtworkPixels(const uint8_t *px, size_t width, size_t height, SGRArtworkColorAnalysis *outAnalysis) {
    if (!px || !outAnalysis) return NO;
    enum { kMaxClusters = 512 };
    SGRColorCluster edgeClusters[kMaxClusters];
    size_t edgeCount = extractClusters(px, width, height, YES, edgeClusters, kMaxClusters);
    if (edgeCount == 0) return NO;
    qsort(edgeClusters, edgeCount, sizeof(SGRColorCluster), compareClustersByCountDesc);

    SGRColorCluster proposedBg = edgeClusters[0];
    // Step 4: 30% chromatic edge override when top perimeter bucket is black/white (or neutral gray border).
    if (isBlackOrWhite255(proposedBg.r, proposedBg.g, proposedBg.b) || isNeutralGray255(proposedBg.r, proposedBg.g, proposedBg.b)) {
        for (size_t i = 1; i < edgeCount; i++) {
            CGFloat ratio = (CGFloat)edgeClusters[i].count / (CGFloat)MAX((size_t)1, edgeClusters[0].count);
            if (ratio > kEdgeDominanceRatio && !isBlackOrWhite255(edgeClusters[i].r, edgeClusters[i].g, edgeClusters[i].b)) {
                proposedBg = edgeClusters[i];
                break;
            }
        }
    }

    // Refine proposedBg by averaging all non-BW perimeter clusters within distinctness threshold of proposedBg.
    double refineR = 0, refineG = 0, refineB = 0;
    size_t refineCount = 0, totalEdge = 0;
    for (size_t i = 0; i < edgeCount; i++) {
        totalEdge += edgeClusters[i].count;
        if (!isBlackOrWhite255(edgeClusters[i].r, edgeClusters[i].g, edgeClusters[i].b) &&
            !isDistinct255(edgeClusters[i].r, edgeClusters[i].g, edgeClusters[i].b, proposedBg.r, proposedBg.g, proposedBg.b)) {
            refineR += edgeClusters[i].r * edgeClusters[i].count;
            refineG += edgeClusters[i].g * edgeClusters[i].count;
            refineB += edgeClusters[i].b * edgeClusters[i].count;
            refineCount += edgeClusters[i].count;
        }
    }
    if (refineCount > 0) {
        proposedBg.r = refineR / refineCount;
        proposedBg.g = refineG / refineCount;
        proposedBg.b = refineB / refineCount;
    }

    outAnalysis->bg[0] = proposedBg.r;
    outAnalysis->bg[1] = proposedBg.g;
    outAnalysis->bg[2] = proposedBg.b;
    outAnalysis->edgeDominance = totalEdge > 0 ? (CGFloat)refineCount / (CGFloat)totalEdge : 0;

    // Step 5: Determine target text polarity.
    BOOL bgIsDark = isDark255(proposedBg.r, proposedBg.g, proposedBg.b);
    BOOL findDarkText = !bgIsDark;
    outAnalysis->isLight = !bgIsDark;

    // Steps 6-10: Extract all pixels from entire image into multiset M_all and rank candidates.
    SGRColorCluster allClusters[kMaxClusters];
    size_t allCount = extractClusters(px, width, height, NO, allClusters, kMaxClusters);
    qsort(allClusters, allCount, sizeof(SGRColorCluster), compareClustersByScoreDesc);

    BOOL hasPrimary = NO, hasSecondary = NO, hasTertiary = NO;
    for (size_t i = 0; i < allCount; i++) {
        CGFloat cr, cg, cb;
        withMinSaturation255(allClusters[i].r, allClusters[i].g, allClusters[i].b, kMinTextSaturation, &cr, &cg, &cb);
        if (isDark255(cr, cg, cb) != findDarkText) continue;
        if (!isContrasting255(cr, cg, cb, proposedBg.r, proposedBg.g, proposedBg.b)) continue;

        if (!hasPrimary) {
            outAnalysis->primary[0] = cr; outAnalysis->primary[1] = cg; outAnalysis->primary[2] = cb;
            hasPrimary = YES;
        } else if (!hasSecondary) {
            if (isDistinct255(cr, cg, cb, outAnalysis->primary[0], outAnalysis->primary[1], outAnalysis->primary[2])) {
                outAnalysis->secondary[0] = cr; outAnalysis->secondary[1] = cg; outAnalysis->secondary[2] = cb;
                hasSecondary = YES;
            }
        } else if (!hasTertiary) {
            if (isDistinct255(cr, cg, cb, outAnalysis->primary[0], outAnalysis->primary[1], outAnalysis->primary[2]) &&
                isDistinct255(cr, cg, cb, outAnalysis->secondary[0], outAnalysis->secondary[1], outAnalysis->secondary[2])) {
                outAnalysis->tertiary[0] = cr; outAnalysis->tertiary[1] = cg; outAnalysis->tertiary[2] = cb;
                hasTertiary = YES;
                break;
            }
        }
    }

    // Step 11: Fallback assignment (Guaranteed Contrast) + Section 2.6.2 Iterative Lightness Tuning.
    CGFloat fallback = findDarkText ? 0.0 : 255.0;
    if (!hasPrimary) { outAnalysis->primary[0] = outAnalysis->primary[1] = outAnalysis->primary[2] = fallback; }
    if (!hasSecondary) { outAnalysis->secondary[0] = outAnalysis->secondary[1] = outAnalysis->secondary[2] = fallback; }
    if (!hasTertiary) { outAnalysis->tertiary[0] = outAnalysis->tertiary[1] = outAnalysis->tertiary[2] = fallback; }

    tuneAccessibleLightness255(&outAnalysis->primary[0], &outAnalysis->primary[1], &outAnalysis->primary[2],
                               proposedBg.r, proposedBg.g, proposedBg.b, findDarkText);
    tuneAccessibleLightness255(&outAnalysis->secondary[0], &outAnalysis->secondary[1], &outAnalysis->secondary[2],
                               proposedBg.r, proposedBg.g, proposedBg.b, findDarkText);
    tuneAccessibleLightness255(&outAnalysis->tertiary[0], &outAnalysis->tertiary[1], &outAnalysis->tertiary[2],
                               proposedBg.r, proposedBg.g, proposedBg.b, findDarkText);
    return YES;
}

#pragma mark - color

static CGFloat toLinear(CGFloat c) {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

static CGFloat toEncoded(CGFloat c) {
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055;
}

// Applies Rec. 709 CAColorMatrix saturation in sRGB with a gamut-preserving soft chroma knee so minor
// channels are never driven negative (preserving rose/warm undertones), then applies the soft-knee
// luminance compression Y_comp = Y / (1 + 0.35 * Y) and holds linear luminance under `ceiling`.
static UIColor *fieldColorFor(UIColor *color, CGFloat ceiling) {
    CGFloat r = 0, g = 0, b = 0, a = 1, h = 0, s = 0, v = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat white = 0;
        if (![color getWhite:&white alpha:&a]) return SGRNeutralField();
        r = g = b = white;
    }
    r = MIN(1, MAX(0, r));
    g = MIN(1, MAX(0, g));
    b = MIN(1, MAX(0, b));

    // Apply gamut-safe Rec. 709 saturation boost in sRGB (Module 2, Section 3.2).
    CGFloat ySrgb = kLumR * r + kLumG * g + kLumB * b;
    CGFloat dr = r - ySrgb, dg = g - ySrgb, db = b - ySrgb;
    CGFloat satFactor = 1.25;
    CGFloat rgb[3] = {r, g, b}, diff[3] = {dr, dg, db};
    for (int ch = 0; ch < 3; ch++) {
        if (diff[ch] < -1e-5) {
            CGFloat floorCh = 0.65 * rgb[ch];
            CGFloat maxS = (ySrgb - floorCh) / (-diff[ch]);
            if (maxS < satFactor) satFactor = MAX(1.0, maxS);
        }
    }
    float inRGBA[4] = {(float)r, (float)g, (float)b, 1.0f}, outRGBA[4] = {0};
    SGRColorMatrix satMatrix = SGRColorMatrixMakeSaturation((float)satFactor);
    SGRColorMatrixApply(&satMatrix, inRGBA, outRGBA);
    r = MIN(1, MAX(0, outRGBA[0]));
    g = MIN(1, MAX(0, outRGBA[1]));
    b = MIN(1, MAX(0, outRGBA[2]));

    // Cap HSV saturation at kMaxSaturation so minor channels remain rich and warm.
    [[UIColor colorWithRed:r green:g blue:b alpha:1] getHue:&h saturation:&s brightness:&v alpha:&a];
    if (s > kMaxSaturation) {
        [[UIColor colorWithHue:h saturation:kMaxSaturation brightness:v alpha:1] getRed:&r green:&g blue:&b alpha:&a];
    }

    // Module 3, Section 4.4.2: Soft-knee luminance compression Y_compressed = Y / (1.0 + 0.35 * Y).
    CGFloat y = kLumR * r + kLumG * g + kLumB * b;
    if (y > 0.0001) {
        CGFloat yCompressed = y / (1.0 + kSoftKneeFactor * y);
        CGFloat scale = yCompressed / y;
        r = MIN(1, r * scale);
        g = MIN(1, g * scale);
        b = MIN(1, b * scale);
    }

    CGFloat lr = toLinear(r), lg = toLinear(g), lb = toLinear(b);
    CGFloat luminance = kLumR * lr + kLumG * lg + kLumB * lb;
    if (luminance > ceiling) {
        CGFloat k = ceiling / luminance;
        lr *= k, lg *= k, lb *= k;
    }
    return [UIColor colorWithRed:toEncoded(lr) green:toEncoded(lg) blue:toEncoded(lb) alpha:1];
}

UIColor *SGRFieldColorFor(UIColor *color) {
    return color ? fieldColorFor(color, SGRIncreaseContrast() ? kMaxLuminanceContrast : kMaxLuminance) : SGRNeutralField();
}

// The artwork squeezed into a small square, whatever its aspect, and the bottom rows of that averaged
// by coverage. A bitmap context keeps its rows top to bottom, so the last rows are the bottom edge.
static UIColor *edgeColorOf(const uint8_t *px) {
    if (!px) return nil;
    double r = 0, g = 0, b = 0, coverage = 0;
    for (size_t y = kSample - kEdgeRows; y < kSample; y++) {
        for (size_t x = 0; x < kSample; x++) {
            const uint8_t *p = px + (y * kSample + x) * 4;
            r += p[0], g += p[1], b += p[2], coverage += p[3];
        }
    }
    // Premultiplied, so the sums over the summed alpha are the average of what is actually there.
    if (coverage < 1) return nil;
    return [UIColor colorWithRed:r / coverage green:g / coverage blue:b / coverage alpha:1];
}

#pragma mark - bitmaps

// The artwork drawn to fill the size, then blurred with its edges clamped so the border does not
// darken. Returned retained.
static CGImageRef newBlurred(CGImageRef image, size_t width, size_t height, CGFloat sigma) {
    CGContextRef context = newBitmap(width, height);
    if (!context) return NULL;
    drawFilling(context, image, width, height);
    CGImageRef small = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!small) return NULL;
    CIImage *input = [CIImage imageWithCGImage:small];
    CGImageRelease(small);
    CIImage *output = [[input imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:sigma];
    return [blurContext() createCGImage:output fromRect:input.extent format:kCIFormatRGBA8 colorSpace:sRGB()];
}

// A black gradient from `a0` at `y0` to `a1` at `y1` (shares of the height, top down), extended
// past both ends; with kCGBlendModeDestinationIn it becomes an alpha ramp instead of a dim.
static void drawRamp(CGContextRef context, size_t height, CGFloat y0, CGFloat a0, CGFloat y1, CGFloat a1, CGBlendMode mode) {
    CGFloat components[] = {0, 0, 0, a0, 0, 0, 0, a1};
    CGFloat locations[] = {0, 1};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(sRGB(), components, locations, 2);
    CGContextSetBlendMode(context, mode);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, y0 * height), CGPointMake(0, y1 * height),
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(gradient);
}

static UIImage *finished(CGImageRef blurred, BOOL dim, CGFloat dimBottom, CGFloat rampFrom, CGFloat alphaFrom, CGFloat rampTo, CGFloat alphaTo) {
    size_t width = CGImageGetWidth(blurred), height = CGImageGetHeight(blurred);
    CGContextRef context = newBitmap(width, height);
    if (!context) return nil;
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), blurred);
    // Top down from here on.
    CGContextTranslateCTM(context, 0, height);
    CGContextScaleCTM(context, 1, -1);
    if (dim) drawRamp(context, height, 0, 0.25, kFadeFrom, dimBottom, kCGBlendModeNormal);
    drawRamp(context, height, rampFrom, alphaFrom, rampTo, alphaTo, kCGBlendModeDestinationIn);
    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    UIImage *image = result ? [UIImage imageWithCGImage:result scale:1 orientation:UIImageOrientationUp] : nil;
    CGImageRelease(result);
    return image;
}

#pragma mark - tint

// The artwork's dominant color in linear light: its pixels quantized into 15-bit RGB555 buckets (or 9-bit bins
// for small regions), scored by count weighted toward chromatic pixels while filtering near-black (< 23) and
// near-white (> 232) framing.
static BOOL dominantIn(const uint8_t *px, size_t x0, size_t y0, size_t x1, size_t y1, CGFloat out[3]) {
    enum { kBins = 512 };
    double sums[kBins][3] = {{0}}, scores[kBins] = {0};
    size_t counts[kBins] = {0};
    for (size_t i = 0; px && i < kSample * kSample; i++) {
        size_t x = i % kSample, y = i / kSample;
        if (x < x0 || x >= x1 || y < y0 || y >= y1) continue;
        const uint8_t *p = px + i * 4;
        if (p[3] < 128) continue;
        int bin = (p[0] >> 5) << 6 | (p[1] >> 5) << 3 | (p[2] >> 5);
        CGFloat high = MAX(p[0], MAX(p[1], p[2])) / 255.0, low = MIN(p[0], MIN(p[1], p[2])) / 255.0;
        CGFloat saturation = high > 0 ? (high - low) / high : 0;
        BOOL nearBlack = isNearBlack255(p[0], p[1], p[2]);
        BOOL nearWhite = isNearWhite255(p[0], p[1], p[2]);
        scores[bin] += (0.25 + saturation) * (nearBlack ? 0.25 : 1.0) * (nearWhite ? 0.25 : 1.0);
        counts[bin]++;
        sums[bin][0] += toLinear(p[0] / 255.0), sums[bin][1] += toLinear(p[1] / 255.0), sums[bin][2] += toLinear(p[2] / 255.0);
    }
    int best = 0;
    for (int i = 1; i < kBins; i++) {
        if (scores[i] > scores[best]) best = i;
    }
    if (!counts[best]) return NO;
    for (int k = 0; k < 3; k++) out[k] = sums[best][k] / counts[best];
    return YES;
}

static BOOL dominantColorOf(CGImageRef image, CGFloat out[3]) {
    CGContextRef context = newBitmap(kSample, kSample);
    if (!context) return NO;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, kSample, kSample), image);
    BOOL found = dominantIn(CGBitmapContextGetData(context), 0, 0, kSample, kSample, out);
    CGContextRelease(context);
    return found;
}

// Saturation lifted by `lift` up to `max`, using gamut-preserving Rec. 709 saturation and HSB cap;
// `linear` in and out in linear light.
static void liftSaturation(CGFloat linear[3], CGFloat lift, CGFloat max) {
    CGFloat r = toEncoded(linear[0]), g = toEncoded(linear[1]), b = toEncoded(linear[2]);
    CGFloat ySrgb = kLumR * r + kLumG * g + kLumB * b;
    CGFloat rgb[3] = {r, g, b}, diff[3] = {r - ySrgb, g - ySrgb, b - ySrgb};
    CGFloat effLift = lift;
    for (int ch = 0; ch < 3; ch++) {
        if (diff[ch] < -1e-5) {
            CGFloat floorCh = 0.65 * rgb[ch];
            CGFloat maxS = (ySrgb - floorCh) / (-diff[ch]);
            if (maxS < effLift) effLift = MAX(1.0, maxS);
        }
    }
    float inRGBA[4] = {(float)r, (float)g, (float)b, 1.0f}, outRGBA[4] = {0};
    SGRColorMatrix satMatrix = SGRColorMatrixMakeSaturation((float)effLift);
    SGRColorMatrixApply(&satMatrix, inRGBA, outRGBA);
    r = MIN(1, MAX(0, outRGBA[0]));
    g = MIN(1, MAX(0, outRGBA[1]));
    b = MIN(1, MAX(0, outRGBA[2]));

    CGFloat h = 0, s = 0, v = 0, a = 1;
    [[UIColor colorWithRed:r green:g blue:b alpha:1] getHue:&h saturation:&s brightness:&v alpha:&a];
    [[UIColor colorWithHue:h saturation:MIN(max, s) brightness:v alpha:1] getRed:&r green:&g blue:&b alpha:&a];
    linear[0] = toLinear(r), linear[1] = toLinear(g), linear[2] = toLinear(b);
}

#pragma mark - flow

// A dominant color in linear light made fit for a moving field: saturated via gamut-safe CAColorMatrix,
// compressed through the soft-knee curve Y / (1 + 0.35 * Y), and held within the legibility luminance band.
static UIColor *flowColorFor(const CGFloat linear[3], CGFloat ceiling) {
    CGFloat lifted[3] = {linear[0], linear[1], linear[2]};
    liftSaturation(lifted, kFlowSaturationLift, kFlowSaturationMax);
    CGFloat r = toEncoded(lifted[0]), g = toEncoded(lifted[1]), b = toEncoded(lifted[2]);
    CGFloat ySrgb = kLumR * r + kLumG * g + kLumB * b;
    if (ySrgb > 0.0001) {
        CGFloat yComp = ySrgb / (1.0 + kSoftKneeFactor * ySrgb);
        CGFloat scale = yComp / ySrgb;
        r = MIN(1, r * scale);
        g = MIN(1, g * scale);
        b = MIN(1, b * scale);
    }
    CGFloat lr = toLinear(r), lg = toLinear(g), lb = toLinear(b);
    CGFloat luminance = kLumR * lr + kLumG * lg + kLumB * lb;
    CGFloat k = 1;
    if (luminance > ceiling) k = ceiling / luminance;
    else if (luminance > 0 && luminance < kFlowLuminanceMin) k = MIN(kFlowMaxLift, kFlowLuminanceMin / luminance);
    return [UIColor colorWithRed:toEncoded(MIN(1, lr * k)) green:toEncoded(MIN(1, lg * k)) blue:toEncoded(MIN(1, lb * k)) alpha:1];
}

// The artwork's main color in each quarter, then over the whole of it, anchored by the MPArtworkColorAnalyzer
// perimeter background when the cover has a unified chromatic frame so interior patches never muddy the canvas.
static NSArray<UIColor *> *flowColorsOf(const uint8_t *px, const SGRArtworkColorAnalysis *analysis, CGFloat ceiling) {
    if (!px) return nil;
    size_t half = kSample / 2;
    size_t regions[5][4] = {{0, 0, half, half}, {half, 0, kSample, half}, {0, half, half, kSample}, {half, half, kSample, kSample}, {0, 0, kSample, kSample}};
    NSMutableArray<UIColor *> *colors = [NSMutableArray arrayWithCapacity:5];
    BOOL anchorEdge = analysis && analysis->edgeDominance >= 0.55 && !isBlackOrWhite255(analysis->bg[0], analysis->bg[1], analysis->bg[2]);
    CGFloat bgLin[3] = {0};
    if (anchorEdge) {
        bgLin[0] = toLinear(analysis->bg[0] / 255.0);
        bgLin[1] = toLinear(analysis->bg[1] / 255.0);
        bgLin[2] = toLinear(analysis->bg[2] / 255.0);
    }
    CGFloat linear[3];
    for (int i = 0; i < 5; i++) {
        if (!dominantIn(px, regions[i][0], regions[i][1], regions[i][2], regions[i][3], linear)) break;
        if (anchorEdge) {
            CGFloat blend = (i == 4) ? 0.65 * analysis->edgeDominance : 0.50 * analysis->edgeDominance;
            for (int c = 0; c < 3; c++) linear[c] = linear[c] * (1.0 - blend) + bgLin[c] * blend;
        }
        [colors addObject:flowColorFor(linear, ceiling)];
    }
    return colors.count == 5 ? colors : nil;
}

static UIColor *tintOf(CGImageRef image, UIColor *surface, BOOL strong) {
    CGFloat linear[3];
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (!dominantColorOf(image, linear) || ![surface getRed:&r green:&g blue:&b alpha:&a]) return nil;
    if (strong) liftSaturation(linear, kTintSaturationLift, kTintSaturationMax);
    CGFloat cap = strong ? kTintLuminance : kFaintTintLuminance;
    CGFloat luminance = kLumR * linear[0] + kLumG * linear[1] + kLumB * linear[2];
    if (luminance > cap) {
        for (int k = 0; k < 3; k++) linear[k] *= cap / luminance;
    }
    CGFloat t = strong ? kTintShare : kFaintTintShare;
    CGFloat mixed[3] = {r * (1 - t) + toEncoded(linear[0]) * t,
                        g * (1 - t) + toEncoded(linear[1]) * t,
                        b * (1 - t) + toEncoded(linear[2]) * t};

    // Never dimmer than `surface`: a mix dimmer than the surface is lifted back to the surface's luminance
    // in linear light across all three channels, preserving its hue (issue #36).
    CGFloat want = kLumR * toLinear(r) + kLumG * toLinear(g) + kLumB * toLinear(b);
    CGFloat lit[3] = {toLinear(mixed[0]), toLinear(mixed[1]), toLinear(mixed[2])};
    CGFloat have = kLumR * lit[0] + kLumG * lit[1] + kLumB * lit[2];
    if (have <= 0) return surface;
    if (have < want) {
        for (int k = 0; k < 3; k++) mixed[k] = toEncoded(MIN(1, lit[k] * want / have));
    }

    return [UIColor colorWithRed:mixed[0] green:mixed[1] blue:mixed[2] alpha:1];
}

@implementation SGRPalette

+ (void)paletteForImage:(UIImage *)image request:(SGRPaletteRequest)request completion:(void (^)(SGRPalette *palette))completion {
    if (!completion) return;
    CGFloat ceiling = SGRIncreaseContrast() ? kMaxLuminanceContrast : kMaxLuminance;
    CGFloat flowCeiling = SGRIncreaseContrast() ? kMaxLuminance : kFlowLuminanceMax;
    dispatch_async(paletteQueue(), ^{
        SGRPalette *palette = nil;
        CGImageRef cg = image.CGImage;
        if (cg && CGImageGetWidth(cg) && CGImageGetHeight(cg)) {
            CGContextRef sampleCtx = newBitmap(kSample, kSample);
            if (sampleCtx) {
                CGContextSetInterpolationQuality(sampleCtx, kCGInterpolationMedium);
                CGContextDrawImage(sampleCtx, CGRectMake(0, 0, kSample, kSample), cg);
                const uint8_t *px = CGBitmapContextGetData(sampleCtx);
                UIColor *edge = edgeColorOf(px);
                if (edge) {
                    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
                    palette = [SGRPalette new];
                    palette.edgeColor = edge;

                    SGRArtworkColorAnalysis analysis = {0};
                    BOOL hasAnalysis = analyzeArtworkPixels(px, kSample, kSample, &analysis);
                    if (hasAnalysis) {
                        palette.backgroundColor = [UIColor colorWithRed:analysis.bg[0] / 255.0 green:analysis.bg[1] / 255.0 blue:analysis.bg[2] / 255.0 alpha:1];
                        palette.primaryColor = [UIColor colorWithRed:analysis.primary[0] / 255.0 green:analysis.primary[1] / 255.0 blue:analysis.primary[2] / 255.0 alpha:1];
                        palette.secondaryColor = [UIColor colorWithRed:analysis.secondary[0] / 255.0 green:analysis.secondary[1] / 255.0 blue:analysis.secondary[2] / 255.0 alpha:1];
                        palette.tertiaryColor = [UIColor colorWithRed:analysis.tertiary[0] / 255.0 green:analysis.tertiary[1] / 255.0 blue:analysis.tertiary[2] / 255.0 alpha:1];
                        palette.backgroundColorLight = analysis.isLight;
                    } else {
                        palette.backgroundColor = edge;
                        palette.primaryColor = UIColor.whiteColor;
                        palette.secondaryColor = UIColor.whiteColor;
                        palette.tertiaryColor = UIColor.whiteColor;
                    }

                    CGFloat main[3];
                    UIColor *base = edge;
                    if (request.mainColor) {
                        if (hasAnalysis && analysis.edgeDominance >= 0.55 && !isBlackOrWhite255(analysis.bg[0], analysis.bg[1], analysis.bg[2])) {
                            base = palette.backgroundColor;
                        } else if (dominantIn(px, 0, 0, kSample, kSample, main)) {
                            base = [UIColor colorWithRed:toEncoded(main[0]) green:toEncoded(main[1]) blue:toEncoded(main[2]) alpha:1];
                        }
                    }
                    palette.fieldColor = fieldColorFor(base, ceiling);

                    CGSize area = request.backdropSize;
                    if (area.width > 0 && area.height > 0) {
                        size_t width = (size_t)kBackdropWidth, height = (size_t)MIN(kBackdropMaxHeight, round(kBackdropWidth * area.height / area.width));
                        CGImageRef blurred = newBlurred(cg, width, MAX(height, 1), kBackdropSigma);
                        if (blurred) palette.backdrop = finished(blurred, YES, request.amoled ? 0.55 : 0.45, kFadeFrom, 1, 1, 0);
                        CGImageRelease(blurred);
                    }
                    if (request.flow) palette.flowColors = flowColorsOf(px, hasAnalysis ? &analysis : NULL, flowCeiling);
                    if (request.dissolve) {
                        CGFloat aspect = (CGFloat)CGImageGetHeight(cg) / CGImageGetWidth(cg);
                        size_t height = (size_t)MIN(kDissolveWidth * 2, MAX(kDissolveWidth / 2, round(kDissolveWidth * aspect)));
                        CGImageRef blurred = newBlurred(cg, (size_t)kDissolveWidth, height, kDissolveSigma);
                        if (blurred) palette.dissolve = finished(blurred, NO, 0, kFadeFrom, 0, kDissolveOpaque, 1);
                        CGImageRelease(blurred);
                    }
                    static dispatch_once_t once;
                    double ms = (CFAbsoluteTimeGetCurrent() - start) * 1000;
                    dispatch_once(&once, ^{ SGLog(@"redesign kit: first palette %@ from %zux%zu in %.1f ms", palette.fieldColor, CGImageGetWidth(cg), CGImageGetHeight(cg), ms); });
                }
                CGContextRelease(sampleCtx);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(palette); });
    });
}

+ (void)tintForImage:(UIImage *)image surface:(UIColor *)surface strong:(BOOL)strong completion:(void (^)(UIColor *tint))completion {
    if (!completion) return;
    dispatch_async(paletteQueue(), ^{
        CGImageRef cg = image.CGImage;
        UIColor *tint = cg && CGImageGetWidth(cg) && CGImageGetHeight(cg) ? tintOf(cg, surface, strong) : nil;
        static dispatch_once_t once;
        if (tint) dispatch_once(&once, ^{ SGLog(@"redesign kit: first tint %@", tint); });
        dispatch_async(dispatch_get_main_queue(), ^{ completion(tint); });
    });
}

@end


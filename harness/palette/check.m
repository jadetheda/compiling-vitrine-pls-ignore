// The field color a page takes from its cover: the main color, not the bottom edge. A blue cover with a
// pale scanner border along its foot, which read by the edge turned the album page gray (device, 2026-09-18).
#import <UIKit/UIKit.h>
#import "Redesigned/Kit/SGRPalette.h"

// SGRTokens.m's accent comes from SGRAccent.x, which this does not compile.
UIColor *SGRAccentColor(void) { return UIColor.greenColor; }

static UIImage *cover(void) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(300, 300)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor colorWithRed:0.1 green:0.3 blue:0.9 alpha:1] setFill];
        UIRectFill(CGRectMake(0, 0, 300, 300));
        [[UIColor colorWithWhite:0.85 alpha:1] setFill];
        UIRectFill(CGRectMake(0, 255, 300, 45));
    }];
}

int main(void) {
    @autoreleasepool {
        __block int done = 0, fails = 0;

        // Section 6.1: Contrast test vector (Black vs White, Dark Gray vs Medium Red)
        CGFloat lBlack = SGRScaledLuminance255(0.0, 0.0, 0.0);
        CGFloat lWhite = SGRScaledLuminance255(255.0, 255.0, 255.0);
        CGFloat crBW = SGRContrastRatio255(0.0, 0.0, 0.0, 255.0, 255.0, 255.0);
        if (fabs(lBlack - 12.75) > 0.01 || fabs(lWhite - 267.75) > 0.01 || fabs(crBW - 21.0) > 0.01) {
            printf("FAIL: Section 6.1 Black/White contrast %.4f\n", crBW);
            fails++;
        }

        CGFloat lGray = SGRScaledLuminance255(30.0, 30.0, 30.0);
        CGFloat lRed = SGRScaledLuminance255(200.0, 40.0, 40.0);
        CGFloat crRedGray = SGRContrastRatio255(200.0, 40.0, 40.0, 30.0, 30.0, 30.0);
        if (fabs(lGray - 42.75) > 0.01 || fabs(lRed - 86.766) > 0.01 || fabs(crRedGray - 2.0296) > 0.01) {
            printf("FAIL: Section 6.1 Red/Gray contrast %.4f\n", crRedGray);
            fails++;
        }

        // Section 6.2: CAColorMatrix saturation test vector at s = 1.80 on (0.80, 0.30, 0.20)
        SGRColorMatrix satMat = SGRColorMatrixMakeSaturation(1.80f);
        float inRGBA[4] = {0.80f, 0.30f, 0.20f, 1.00f}, outRGBA[4] = {0};
        SGRColorMatrixApply(&satMat, inRGBA, outRGBA);
        if (fabs(outRGBA[0] - 1.000f) > 0.002f || fabs(outRGBA[1] - 0.2209f) > 0.002f || fabs(outRGBA[2] - 0.0409f) > 0.002f) {
            printf("FAIL: Section 6.2 CAColorMatrix saturation (%.4f, %.4f, %.4f)\n", outRGBA[0], outRGBA[1], outRGBA[2]);
            fails++;
        }

        for (int main = 0; main < 2; main++) {
            SGRPaletteRequest request = {CGSizeZero, NO, YES, main != 0, main != 0};
            [SGRPalette paletteForImage:cover() request:request completion:^(SGRPalette *palette) {
                CGFloat r, g, b, a;
                [palette.fieldColor getRed:&r green:&g blue:&b alpha:&a];
                BOOL blue = b > r + 0.05 && b > g;
                printf("%s: field %.3f %.3f %.3f, %s\n", main ? "main color" : "bottom edge", r, g, b, blue ? "blue" : "gray");
                if (blue != (BOOL)main) fails++;
                if (main && (!palette.backgroundColor || !palette.primaryColor || palette.flowColors.count != 5)) {
                    printf("FAIL: MPArtworkColorAnalyzer properties missing on main request\n");
                    fails++;
                }
                done++;
            }];
        }
        while (done < 2) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        printf(fails ? "FAIL\n" : "PASS\n");
        return fails;
    }
}

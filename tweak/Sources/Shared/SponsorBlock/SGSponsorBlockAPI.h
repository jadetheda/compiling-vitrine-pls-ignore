// SponsorBlock segment model, category metadata, preferences, and sponsor.ajay.app lookup.
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, SGSponsorBlockAction) {
    SGSponsorBlockActionOff = 0,
    SGSponsorBlockActionSkip = 1,
    SGSponsorBlockActionPrompt = 2,
    SGSponsorBlockActionShowOnly = 3,
};

static const NSTimeInterval SGSponsorBlockPromptDurationInfinite = 16.0;

@interface SGSponsorBlockSegment : NSObject
@property (nonatomic, copy, readonly) NSString *uuid;
@property (nonatomic, copy, readonly) NSString *category;
@property (nonatomic, assign, readonly) double startTime;
@property (nonatomic, assign, readonly) double endTime;
@property (nonatomic, assign, readonly) double duration;
- (instancetype)initWithUUID:(NSString *)uuid category:(NSString *)category startTime:(double)start endTime:(double)end;
@end

@interface SGSponsorBlockCategoryInfo : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, copy, readonly) NSString *settingsTitle;
@property (nonatomic, copy, readonly) NSString *summary;
@property (nonatomic, assign, readonly) SGSponsorBlockAction defaultAction;
@property (nonatomic, assign, readonly) NSInteger defaultColorRGB;
@end

NSArray<SGSponsorBlockCategoryInfo *> *SGSponsorBlockAllCategories(void);
SGSponsorBlockCategoryInfo *SGSponsorBlockInfoForCategory(NSString *category);
NSString *SGSponsorBlockCategoryDisplayName(NSString *category);
UIColor *SGSponsorBlockCategoryColor(NSString *category);

SGSponsorBlockAction SGSponsorBlockActionForCategory(NSString *category);
void SGSponsorBlockSetActionForCategory(NSString *category, SGSponsorBlockAction action);
void SGSponsorBlockResetCategoriesToDefaults(void);
NSUInteger SGSponsorBlockActiveCategoryCount(void);

double SGSponsorBlockMinDuration(void);
void SGSponsorBlockSetMinDuration(double duration);

NSTimeInterval SGSponsorBlockToastDuration(void);
void SGSponsorBlockSetToastDuration(NSTimeInterval duration);

NSTimeInterval SGSponsorBlockPromptDuration(void);
void SGSponsorBlockSetPromptDuration(NSTimeInterval duration);

void SGFetchSponsorBlockSegments(NSString *episodeID, void (^completion)(NSArray<SGSponsorBlockSegment *> *segments, NSError *error));
void SGInvalidateSponsorBlockCache(void);

NSInteger SGSponsorBlockSkipCount(void);
double SGSponsorBlockTimeSaved(void);
void SGRecordSponsorBlockSkip(double secondsSaved);
void SGUndoSponsorBlockSkip(double secondsSaved);
void SGResetSponsorBlockStats(void);
NSString *SGFormatSponsorBlockDuration(double seconds);

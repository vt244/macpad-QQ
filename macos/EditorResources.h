// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class ScintillaView;

@interface EditorResources : NSObject
@property(nonatomic, readonly) NSURL *profile;
@property(nonatomic, readonly) NSDictionary<NSString *, NSURL *> *themes;
@property(nonatomic, readonly) NSDictionary<NSString *, NSURL *> *translations;
@property(nonatomic, readonly) NSURL *selectedTheme;
@property(nonatomic, readonly) NSURL *selectedTranslation;
+ (instancetype)shared;
- (NSString *)label:(NSString *)identifier fallback:(NSString *)fallback;
- (NSString *)translationName:(NSURL *)url;
- (void)chooseTheme:(NSURL *)url;
- (void)chooseTranslation:(NSURL *)url;
- (NSURL *)importXML:(NSURL *)url theme:(BOOL)theme error:(NSError **)error;
- (void)configure:(ScintillaView *)view extension:(NSString *)extension;
@end

// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class ScintillaView;

@interface EditorResources : NSObject
@property(nonatomic, readonly) NSURL *profile;
@property(nonatomic, readonly) NSDictionary<NSString *, NSURL *> *themes;
@property(nonatomic, readonly) NSDictionary<NSString *, NSURL *> *translations;
@property(nonatomic, readonly) NSURL *selectedTheme;
@property(nonatomic, readonly) NSURL *selectedTranslation;
@property(nonatomic, readonly) BOOL usesDarkColors;
+ (instancetype)shared;
- (NSString *)label:(NSString *)identifier fallback:(NSString *)fallback;
- (NSString *)englishMenuLabel:(NSString *)identifier;
- (NSArray<NSString *> *)commandIDsWithEnglishTitle:(NSString *)title;
- (NSString *)findLabel:(NSString *)identifier fallback:(NSString *)fallback;
- (NSString *)translationName:(NSURL *)url;
- (void)chooseTheme:(NSURL *)url;
- (void)chooseTranslation:(NSURL *)url;
- (id)setting:(NSString *)name fallback:(id)fallback;
- (void)setSetting:(id)value forName:(NSString *)name;
- (void)setSettings:(NSDictionary<NSString *, id> *)settings;
- (BOOL)importWindowsConfiguration:(NSURL *)url error:(NSError **)error;
- (NSURL *)importXML:(NSURL *)url theme:(BOOL)theme error:(NSError **)error;
- (NSString *)configure:(ScintillaView *)view extension:(NSString *)extension language:(NSString *)name
	syntaxHighlighting:(BOOL)highlight identifier:(NSString **)identifier;
- (NSDictionary<NSString *, NSString *> *)languages;
- (NSArray<NSString *> *)commentSymbolsForLanguage:(NSString *)identifier;
- (NSColor *)widgetColor:(NSString *)name background:(BOOL)background;
- (void)styleSearchResults:(ScintillaView *)view;
@end

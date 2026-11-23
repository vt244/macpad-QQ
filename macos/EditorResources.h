// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class ScintillaView;
NSString *EditorUIString(NSString *english);

@interface EditorResources : NSObject
@property(nonatomic, readonly) NSURL *profile;
@property(nonatomic, readonly) NSDictionary<NSString *, NSURL *> *themes;
@property(nonatomic, readonly) NSDictionary<NSString *, NSURL *> *translations;
@property(nonatomic, readonly) NSURL *selectedTheme;
@property(nonatomic, readonly) NSURL *selectedTranslation;
@property(nonatomic, readonly) BOOL usesDarkColors;
+ (instancetype)shared;
- (NSString *)label:(NSString *)identifier fallback:(NSString *)fallback;
- (NSString *)text:(NSString *)english;
- (NSString *)englishMenuLabel:(NSString *)identifier;
- (NSArray<NSString *> *)commandIDsWithEnglishTitle:(NSString *)title;
- (BOOL)toolbarHidesCommand:(NSString *)identifier atIndex:(NSUInteger)index;
- (BOOL)toolbarHidesPluginAtIndex:(NSUInteger)index;
- (NSURL *)toolbarIconNamed:(NSString *)name disabled:(BOOL)disabled;
- (NSURL *)localURLForWindowsPath:(NSString *)path;
- (NSString *)findLabel:(NSString *)identifier fallback:(NSString *)fallback;
- (NSString *)translationName:(NSURL *)url;
- (void)chooseTheme:(NSURL *)url;
- (void)chooseTranslation:(NSURL *)url;
- (id)setting:(NSString *)name fallback:(id)fallback;
- (void)setSetting:(id)value forName:(NSString *)name;
- (void)setSettings:(NSDictionary<NSString *, id> *)settings;
- (BOOL)importWindowsConfiguration:(NSURL *)url error:(NSError **)error;
- (NSDictionary<NSString *, NSArray<NSDictionary *> *> *)styleDefinitions;
- (BOOL)saveStyles:(NSDictionary<NSString *, NSArray<NSDictionary *> *> *)styles error:(NSError **)error;
- (NSURL *)importXML:(NSURL *)url theme:(BOOL)theme error:(NSError **)error;
- (NSString *)configure:(ScintillaView *)view extension:(NSString *)extension language:(NSString *)name
	syntaxHighlighting:(BOOL)highlight identifier:(NSString **)identifier;
- (NSDictionary<NSString *, NSString *> *)languages;
- (NSArray<NSString *> *)userLanguages;
- (NSArray<NSString *> *)commentSymbolsForLanguage:(NSString *)identifier;
- (BOOL)importUserLanguages:(NSURL *)url error:(NSError **)error;
- (NSString *)userLanguageXML:(NSString *)name;
- (BOOL)saveUserLanguageXML:(NSString *)xml replacing:(NSString *)previousName error:(NSError **)error;
- (BOOL)removeUserLanguage:(NSString *)name error:(NSError **)error;
- (NSColor *)widgetColor:(NSString *)name background:(BOOL)background;
- (void)styleSearchResults:(ScintillaView *)view;
@end

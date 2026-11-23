// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class EditorDocument;

@interface EditorTabStrip : NSScrollView
- (CGFloat)layoutTabsForWidth:(CGFloat)width height:(CGFloat)height vertical:(BOOL)vertical multiline:(BOOL)multiline;
@end

@interface EditorChrome : NSView
@property(nonatomic, readonly) NSView *statusBar;
@property(nonatomic, readonly) NSView *primaryTabs;
@property(nonatomic, readonly) NSView *secondaryTabs;
@property(nonatomic, readonly) NSArray<NSButton *> *toolbarButtons;
- (instancetype)initWithDocument:(EditorDocument *)document commands:(NSArray<NSToolbarItem *> *)commands;
- (void)refreshMenus;
- (void)refreshTabs;
- (void)refreshToolbar;
- (void)refreshToolbarLabels:(NSArray<NSToolbarItem *> *)commands;
- (void)refreshColors;
- (void)refreshAppearancePreferences;
- (void)setStatusFields:(NSArray<NSString *> *)fields;
- (void)setTabsHidden:(BOOL)hidden;
@end

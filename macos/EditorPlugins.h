// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class EditorDocument;
struct SCNotification;
extern NSNotificationName const EditorPluginDocumentDidChange;
void EditorPublishPluginNotification(EditorDocument *document, const struct SCNotification *notification);

@interface EditorPlugins : NSObject
@property(nonatomic, readonly) NSURL *directory;
@property(nonatomic, readonly) NSArray<NSURL *> *pluginFiles;
- (instancetype)initWithDirectory:(NSURL *)directory;
- (NSString *)loadedTitleForFile:(NSURL *)file;
- (BOOL)installPluginAtURL:(NSURL *)source error:(NSError **)error;
- (BOOL)installCatalogPlugin:(NSData *)data filename:(NSString *)filename updating:(BOOL)updating error:(NSError **)error;
- (BOOL)disablePluginAtURL:(NSURL *)file error:(NSError **)error;
- (void)populateMenu:(NSMenu *)menu;
- (NSArray<NSToolbarItem *> *)toolbarItems;
- (NSString *)shortcutForWindowsModule:(NSString *)module internalID:(NSInteger)identifier;
- (BOOL)performCommand:(NSMenuItem *)item inDocument:(EditorDocument *)document;
@end

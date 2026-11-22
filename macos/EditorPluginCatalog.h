// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class EditorPlugins;

@interface EditorPluginPackage : NSObject
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSString *filename;
@property(nonatomic, readonly) NSString *version;
@property(nonatomic, readonly) NSString *sha256;
@property(nonatomic, readonly) NSURL *url;
@end

NSArray<EditorPluginPackage *> *EditorPluginPackages(NSData *data, NSURL *source, NSError **error);
void EditorShowPluginCatalog(EditorPlugins *plugins);
void EditorChoosePluginCatalog(void);

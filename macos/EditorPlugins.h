// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class EditorDocument;

@interface EditorPlugins : NSObject
- (instancetype)initWithDirectory:(NSURL *)directory;
- (void)populateMenu:(NSMenu *)menu;
- (BOOL)performCommand:(NSMenuItem *)item inDocument:(EditorDocument *)document;
@end

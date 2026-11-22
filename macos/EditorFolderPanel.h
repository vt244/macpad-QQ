// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@interface EditorFolderPanel : NSView
- (instancetype)initWithOpen:(void (^)(NSURL *))open add:(void (^)(void))add
	changeRoots:(void (^)(NSArray<NSURL *> *))changeRoots dismiss:(void (^)(void))dismiss;
- (void)setDirectories:(NSArray<NSURL *> *)directories;
@end

BOOL EditorIsWorkspaceDirectory(NSURL *url);

// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@interface EditorProjectWorkspace : NSObject
@property(nonatomic, readonly) NSArray<NSURL *> *files;
- (NSDictionary *)snapshot;
- (void)restore:(NSDictionary *)snapshot;
- (BOOL)readFromURL:(NSURL *)url error:(NSError **)error;
- (BOOL)writeToURL:(NSURL *)url error:(NSError **)error;
@end

@interface EditorProjectPanel : NSView
- (instancetype)initWithTitle:(NSString *)title workspace:(EditorProjectWorkspace *)workspace
	open:(void (^)(NSURL *))open changed:(void (^)(void))changed dismiss:(void (^)(void))dismiss;
- (void)reload;
@end

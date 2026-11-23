// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class ScintillaView;
@interface EditorCompletion : NSObject
- (void)completeIn:(ScintillaView *)editor language:(NSString *)language directory:(NSURL *)directory command:(NSInteger)command;
- (void)typed:(int)character inEditor:(ScintillaView *)editor language:(NSString *)language
	complete:(BOOL)complete closePairs:(BOOL)closePairs;
@end

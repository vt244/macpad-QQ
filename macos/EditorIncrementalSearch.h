// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class ScintillaView;

@interface EditorIncrementalSearch : NSView
- (instancetype)initWithDismiss:(void (^)(void))dismiss;
- (void)beginInEditor:(ScintillaView *)editor;
- (void)end;
@end

// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class ScintillaView;

@interface EditorDocumentMap : NSView
- (instancetype)initWithDismiss:(void (^)(void))dismiss;
- (void)showEditor:(ScintillaView *)editor;
- (void)refreshStyle;
- (void)updateViewport;
@end

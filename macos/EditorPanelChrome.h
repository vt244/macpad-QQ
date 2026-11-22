// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@interface EditorCrossButton : NSButton
@end

NSView *EditorPanelCaption(NSString *title, id target, SEL closeAction);
NSImage *EditorTabStateIcon(BOOL edited, BOOL readOnly, BOOL monitoring, BOOL dark);

// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@interface EditorCrossButton : NSButton
@end

NSView *EditorPanelCaption(NSString *title, id target, SEL closeAction);
void EditorSetPanelCaption(NSView *panel, NSString *title);
NSImage *EditorTabStateIcon(BOOL edited, BOOL readOnly, BOOL monitoring, BOOL dark);

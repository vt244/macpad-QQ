// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"

@class EditorDocument;

NSMenu *EditorTabMenu(EditorDocument *document);
void EditorRunTabCommand(EditorDocument *document, NSInteger command);
BOOL EditorCanRunTabCommand(EditorDocument *document, NSInteger command);
NSColor *EditorTabColor(NSInteger index);
void EditorCopyText(NSString *text);

@interface EditorContextView : ScintillaView
@property(nonatomic, weak) EditorDocument *document;
@end

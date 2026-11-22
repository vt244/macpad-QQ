// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class ScintillaView;
void EditorShowColumnDialog(ScintillaView *editor);
void EditorInsertColumnText(ScintillaView *editor, NSString *text);
void EditorAddMatchingSelections(ScintillaView *editor, NSInteger command);
void EditorCommentSelection(ScintillaView *editor, NSInteger command, NSString *linePrefix, NSString *blockStart, NSString *blockEnd);
void EditorReorderLines(ScintillaView *editor, NSInteger command);
void EditorBookmarkLines(ScintillaView *editor, NSInteger command, int marker);
void EditorNavigateChanges(ScintillaView *editor, NSInteger command);

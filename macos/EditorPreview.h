// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class EditorResources;
@class ScintillaView;

BOOL LoadEditorPreview(ScintillaView *view, NSURL *fileURL, EditorResources *resources, NSError **error);
BOOL IsEditorPreviewKey(NSEvent *event);
void PreviewEditorFile(NSURL *fileURL);

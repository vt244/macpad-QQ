// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>
#include "MacpadPlugin.h"

static __weak NSTextView *openDocuments;

static NSString *ListDocuments(const MacpadEditorV2 *editor)
{
	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	MacpadDocumentID active = editor->activeDocument(editor->context);
	for (size_t index = 0; index < editor->documentCount(editor->context); ++index)
	{
		MacpadDocumentID document = editor->documentAtIndex(editor->context, index);
		size_t length = editor->copyPath(editor->context, document, nullptr, 0);
		NSMutableData *path = [NSMutableData dataWithLength:length];
		editor->copyPath(editor->context, document, static_cast<char *>(path.mutableBytes), length);
		NSString *name = [[NSString alloc] initWithData:path encoding:NSUTF8StringEncoding];
		[lines addObject:[NSString stringWithFormat:@"%@%@",
			document == active ? @"● " : @"  ", name.length ? name : @"Untitled"]];
	}
	return [lines componentsJoinedByString:@"\n"];
}

static void Inventory(const MacpadEditorV2 *editor)
{
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 400, 220)];
	scroll.hasVerticalScroller = YES;
	NSTextView *text = [[NSTextView alloc] initWithFrame:scroll.bounds];
	text.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
	text.string = ListDocuments(editor);
	text.editable = NO;
	text.verticallyResizable = YES;
	text.autoresizingMask = NSViewWidthSizable;
	scroll.documentView = text;
	openDocuments = text;
	editor->showPanel(editor->context, "documents", "Open Documents", (__bridge void *)scroll);
}

static void UpdateInventory(const MacpadEditorV2 *editor, MacpadDocumentEventV2 event, MacpadDocumentID document)
{
	if (event != MACPAD_DOCUMENT_CHANGED && openDocuments.window.visible)
		openDocuments.string = ListDocuments(editor);
}

static void CopyActivePath(const MacpadEditorV2 *editor)
{
	MacpadDocumentID document = editor->activeDocument(editor->context);
	size_t size = editor->copyPath(editor->context, document, nullptr, 0);
	if (!size)
		return;
	NSMutableData *data = [NSMutableData dataWithLength:size];
	editor->copyPath(editor->context, document, static_cast<char *>(data.mutableBytes), size);
	NSString *path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	if (!path.length)
		return;
	NSPasteboard *clipboard = NSPasteboard.generalPasteboard;
	[clipboard clearContents];
	[clipboard setString:path forType:NSPasteboardTypeString];
}

extern "C" const MacpadPluginV2 *macpad_plugin_v2(void)
{
	static const MacpadPluginCommandV2 commands[] = {{"Open Documents", Inventory}, {"Copy Active Document Path", CopyActivePath}};
	static const MacpadPluginV2 plugin = {MACPAD_PLUGIN_ABI_V2, sizeof(MacpadPluginV2), "Document Tools", 2, commands, UpdateInventory};
	return &plugin;
}

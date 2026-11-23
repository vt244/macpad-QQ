// SPDX-License-Identifier: GPL-3.0-only
#import "EditorContextMenus.h"
#import "EditorDocument.h"
#import "EditorResources.h"

#include "pugiconfig.hpp"
#undef PUGIXML_CHARCONV_FLOAT
#include "pugixml.hpp"

void EditorCopyText(NSString *text)
{
	if (!text.length)
		return;
	NSPasteboard *clipboard = NSPasteboard.generalPasteboard;
	[clipboard clearContents];
	[clipboard setString:text forType:NSPasteboardTypeString];
}

NSColor *EditorTabColor(NSInteger index)
{
	if (index < 1 || index > 5)
		return nil;
	EditorResources *resources = EditorResources.shared;
	NSString *name = [NSString stringWithFormat:resources.usesDarkColors ? @"Tab color dark mode %ld" : @"Tab color %ld", index];
	return [resources widgetColor:name background:YES];
}

static NSMenuItem *Item(NSMenu *menu, NSString *title, id target, SEL action, BOOL enabled, NSInteger tag = 0)
{
	NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
	item.target = target;
	item.enabled = enabled;
	item.tag = tag;
	return item;
}

static NSString *Label(NSString *key, NSString *fallback)
{
	return [EditorResources.shared label:key fallback:fallback];
}

static NSMenu *Submenu(NSMenu *menu, NSString *title)
{
	NSMenuItem *parent = Item(menu, title, nil, nullptr, YES);
	parent.submenu = [[NSMenu alloc] initWithTitle:title];
	parent.submenu.autoenablesItems = NO;
	return parent.submenu;
}

static NSString *NormalizeMenuName(NSString *title)
{
	return [[title stringByReplacingOccurrencesOfString:@"..." withString:@"…"]
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
}

static NSMenuItem *FindMenuCommand(NSMenu *menu, NSArray<NSString *> *titles, NSInteger tag)
{
	for (NSMenuItem *item in menu.itemArray)
	{
		if (item.submenu)
		{
			if (NSMenuItem *child = FindMenuCommand(item.submenu, titles, tag))
				return child;
		}
		else if (item.action && ((tag > 0 && item.tag == tag) || [titles containsObject:NormalizeMenuName(item.title)]))
			return item;
	}
	return nil;
}

NSMenuItem *EditorFindMenuCommandByID(NSMenu *menu, NSString *identifier)
{
	EditorResources *resources = EditorResources.shared;
	NSString *english = [resources englishMenuLabel:identifier];
	NSString *local = [resources label:identifier fallback:english];
	NSMutableArray *titles = [NSMutableArray array];
	for (NSString *title in @[english ?: @"", local ?: @""])
		if (title.length)
			[titles addObject:NormalizeMenuName(title)];
	return FindMenuCommand(menu, titles, identifier.integerValue);
}

@interface ContextCommand : NSObject
@property(nonatomic, strong) NSMenuItem *item;
@property(nonatomic, weak) EditorDocument *document;
+ (void)perform:(NSMenuItem *)sender;
@end

@implementation ContextCommand
+ (void)perform:(NSMenuItem *)sender
{
	ContextCommand *command = sender.representedObject;
	[command.document showWindows];
	[NSApp sendAction:command.item.action to:command.item.target from:command.item];
}
@end

static NSMenu *CustomContextMenu(NSMenu *defaults, EditorDocument *document, BOOL tabs)
{
	EditorResources *resources = EditorResources.shared;
	NSString *filename = tabs ? @"tabContextMenu.xml" : @"contextMenu.xml";
	const char *section = tabs ? "TabContextMenu" : "ScintillaContextMenu";
	NSData *data = [NSData dataWithContentsOfURL:[resources.profile URLByAppendingPathComponent:filename]];
	pugi::xml_document xml;
	if (!data.length || !xml.load_buffer(data.bytes, data.length))
		return defaults;
	auto definition = xml.child("NotepadPlus").child(section);
	if (!definition)
		return defaults;
	NSMenu *menu = [[NSMenu alloc] initWithTitle:defaults.title];
	menu.autoenablesItems = NO;
	NSString *lastFolder = nil;
	NSMenu *destination = menu;
	for (auto entry : definition.children("Item"))
	{
		auto attribute = ^NSString *(const char *key) { return [NSString stringWithUTF8String:entry.attribute(key).value()] ?: @""; };
		NSString *identifier = attribute("id");
		BOOL separator = [identifier isEqualToString:@"0"];
		NSMenuItem *original = nil;
		BOOL fromDefault = NO;
		if (!separator)
		{
			NSString *name = attribute("MenuItemName");
			NSString *group = attribute("MenuEntryName");
			NSString *plugin = attribute("PluginEntryName");
			if (plugin.length)
			{
				NSMenu *plugins = [NSApp.mainMenu itemWithTitle:[resources label:@"Plugins" fallback:@"Plugins"]].submenu;
				original = FindMenuCommand([plugins itemWithTitle:plugin].submenu,
					@[NormalizeMenuName(attribute("PluginCommandItemName"))], 0);
			}
			else
			{
				NSMutableArray *ids = identifier.integerValue > 0 ? [NSMutableArray arrayWithObject:identifier] :
					[[resources commandIDsWithEnglishTitle:name] mutableCopy];
				if (tabs)
				{
					NSDictionary *tabAliases = @{@"explorer": @41019, @"move to recycle bin": @41016,
						@"close all but active document": @41005, @"close all but pinned documents": @41026,
						@"folder as workspace": @41025, @"copy current full file path": @42029};
					if (NSNumber *tag = tabAliases[NormalizeMenuName(name)])
						[ids insertObject:tag.stringValue atIndex:0];
					for (NSString *key in ids)
						if ((original = FindMenuCommand(defaults, @[], key.integerValue)))
							break;
					fromDefault = original != nil;
				}
				if (!original)
				{
					NSMutableArray *titles = [NSMutableArray arrayWithObject:NormalizeMenuName(name)];
					for (NSString *key in ids)
					{
						NSString *english = [resources englishMenuLabel:key] ?: @"";
						NSString *title = [resources label:key fallback:english];
						[titles addObject:NormalizeMenuName(title)];
						[titles addObject:NormalizeMenuName(english)];
					}
					NSMenu *root = NSApp.mainMenu;
					NSString *localized = [resources label:group.lowercaseString fallback:group];
					if (group.length)
						root = [root itemWithTitle:localized].submenu ?: root;
					original = FindMenuCommand(root, titles, 0);
				}
			}
			if (!original)
				continue;
		}
		NSString *folder = attribute("FolderName");
		if (![folder isEqual:lastFolder])
		{
			lastFolder = folder;
			destination = folder.length ? Submenu(menu, folder) : menu;
		}
		if (separator)
		{
			[destination addItem:NSMenuItem.separatorItem];
			continue;
		}
		NSMenuItem *item = [original copy];
		if (!fromDefault)
		{
			ContextCommand *command = [ContextCommand new];
			command.item = original;
			command.document = document;
			item.target = ContextCommand.class;
			item.action = @selector(perform:);
			item.representedObject = command;
		}
		NSString *title = attribute("ItemNameAs");
		if (title.length)
			item.title = [title stringByReplacingOccurrencesOfString:@"Notepad++" withString:@"macpad++"];
		item.keyEquivalent = @"";
		[destination addItem:item];
	}
	return menu.numberOfItems ? menu : defaults;
}

@interface TabMenuActions : NSObject
+ (instancetype)shared;
@end

@implementation TabMenuActions
{
	NSMutableArray<EditorDocument *> *_pending;
}

+ (instancetype)shared
{
	static TabMenuActions *actions = [[self alloc] init];
	return actions;
}

- (NSArray<EditorDocument *> *)targetsFor:(EditorDocument *)document command:(NSInteger)command
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	NSArray<EditorDocument *> *tabs = controller.tabDocuments;
	NSUInteger index = [tabs indexOfObjectIdenticalTo:document];
	if (index == NSNotFound)
		return @[];
	NSMutableArray<EditorDocument *> *targets = [NSMutableArray array];
	for (NSUInteger i = 0; i < tabs.count; ++i)
	{
		EditorDocument *candidate = tabs[i];
		BOOL matches = NO;
		switch (command)
		{
			case 41005: matches = candidate != document; break;
			case 41026: matches = !candidate.isTabPinned; break;
			case 41009: matches = i < index; break;
			case 41018: matches = i > index; break;
			case 41024: matches = !candidate.isDocumentEdited; break;
		}
		if (matches)
			[targets addObject:candidate];
	}
	return targets;
}

- (void)closeGroup:(NSMenuItem *)item
{
	if (_pending.count)
		return;
	_pending = [[self targetsFor:item.representedObject command:item.tag] mutableCopy];
	[self closeNext];
}

- (void)closeNext
{
	while (_pending.count)
	{
		EditorDocument *document = _pending.firstObject;
		if (![NSDocumentController.sharedDocumentController.documents containsObject:document])
		{
			[_pending removeObjectAtIndex:0];
			continue;
		}
		if (document.isDocumentEdited)
		{
			[document showWindows];
			[document canCloseDocumentWithDelegate:self shouldCloseSelector:@selector(document:shouldClose:contextInfo:) contextInfo:nullptr];
			return;
		}
		[_pending removeObjectAtIndex:0];
		[document close];
	}
}

- (void)document:(EditorDocument *)document shouldClose:(BOOL)close contextInfo:(void *)context
{
	if (!close)
	{
		_pending = nil;
		return;
	}
	[_pending removeObjectIdenticalTo:document];
	[document close];
	dispatch_async(dispatch_get_main_queue(), ^{ [self closeNext]; });
}

- (void)operateOnTab:(NSMenuItem *)item
{
	EditorDocument *document = item.representedObject;
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	NSURL *url = document.fileURL;
	switch (item.tag)
	{
		case 41003: [document closeEditorTab:nil]; return;
		case 41019: if (url) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]]; return;
		case 41023: if (url) [NSWorkspace.sharedWorkspace openURL:url]; return;
		case 41025: if (url) [controller addWorkspaceFolders:@[url.URLByDeletingLastPathComponent]]; return;
		case 42029: EditorCopyText(url.path); return;
		case 42030: EditorCopyText(url.lastPathComponent); return;
		case 42031: EditorCopyText(url.URLByDeletingLastPathComponent.path); return;
		case 44048: [document changeTabPin]; return;
		case 10005: case 10006: [controller moveTab:document toEnd:item.tag == 10006]; return;
		case 44110: case 44111: case 44112: case 44113: case 44114: case 44115:
			[document changeTabColor:item.tag - 44110]; return;
	}
	[document showWindows];
	switch (item.tag)
	{
		case 41006: [document saveDocument:nil]; break;
		case 41008: [document saveDocumentAs:nil]; break;
		case 41014: [document revertDocumentToSaved:nil]; break;
		case 41017: [document renameDocument:nil]; break;
		case 41016: [document moveFileToTrash:nil]; break;
		case 41010: [document printDocument:nil]; break;
		case 42028: [document toggleDocumentReadOnly:nil]; break;
		case 10001: [document moveToOtherView:nil]; break;
		case 10002: [document cloneToOtherView:nil]; break;
	}
}
@end

BOOL EditorCanRunTabCommand(EditorDocument *document, NSInteger command)
{
	if (command == 41019 || command == 41023 || command == 41025 || command == 41017)
		return document.fileURL != nil;
	return [TabMenuActions.shared targetsFor:document command:command].count > 0;
}

void EditorRunTabCommand(EditorDocument *document, NSInteger command)
{
	NSMenuItem *item = [NSMenuItem new];
	item.tag = command;
	item.representedObject = document;
	if (command == 41019 || command == 41023 || command == 41025 || command == 41017)
		[TabMenuActions.shared operateOnTab:item];
	else
		[TabMenuActions.shared closeGroup:item];
}

NSMenu *EditorTabMenu(EditorDocument *document)
{
	if (!document)
		return nil;
	TabMenuActions *actions = TabMenuActions.shared;
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tab"];
	menu.autoenablesItems = NO;
	auto titleFor = [](NSInteger tag, NSString *fallback) {
		return Label([NSString stringWithFormat:@"tab:%ld", tag], fallback);
	};
	auto item = [&](NSMenu *parent, NSInteger tag, NSString *title, BOOL enabled) {
		if (tag != 41019 && tag != 44048)
			title = titleFor(tag, title);
		NSMenuItem *entry = Item(parent, title, actions, @selector(operateOnTab:), enabled, tag);
		entry.representedObject = document;
		return entry;
	};
	const BOOL saved = document.fileURL != nil;
	item(menu, 41003, Label(@"41003", @"Close"), YES);
	NSMenu *multiple = Submenu(menu, titleFor(0, @"Close Multiple Tabs"));
	NSArray<NSString *> *groupLabels = @[@"Close All But This", @"Close All But Pinned", @"Close All to the Left",
		@"Close All to the Right", @"Close All Unchanged"];
	const NSInteger closeIDs[] = {41005, 41026, 41009, 41018, 41024};
	for (NSUInteger i = 0; i < groupLabels.count; ++i)
	{
		NSMenuItem *close = Item(multiple, titleFor(closeIDs[i], groupLabels[i]), actions, @selector(closeGroup:),
			[actions targetsFor:document command:closeIDs[i]].count > 0, closeIDs[i]);
		close.representedObject = document;
	}
	item(menu, 44048, document.isTabPinned ? Label(@"alt:tab:44048", @"Unpin Tab") : titleFor(44048, @"Pin Tab"), YES);
	item(menu, 41006, Label(@"41006", @"Save"), document.isDocumentEdited);
	item(menu, 41008, Label(@"41008", @"Save As…"), YES);
	NSMenu *open = Submenu(menu, titleFor(1, @"Open into"));
	item(open, 41019, @"Show in Finder", saved);
	item(open, 41023, @"Open in Default Viewer", saved);
	item(open, 41025, @"Open Containing Folder as Workspace", saved);
	item(menu, 41017, Label(@"41017", @"Rename…"), saved);
	item(menu, 41016, @"Move to Trash…", saved);
	item(menu, 41014, Label(@"41014", @"Reload from Disk"), saved);
	item(menu, 41010, Label(@"41010", @"Print…"), YES);
	[menu addItem:NSMenuItem.separatorItem];
	item(menu, 42028, @"Read-Only in macpad++", YES).state = [document.editor message:SCI_GETREADONLY] ?
		NSControlStateValueOn : NSControlStateValueOff;
	[menu addItem:NSMenuItem.separatorItem];
	NSMenu *copy = Submenu(menu, titleFor(2, @"Copy to Clipboard"));
	item(copy, 42029, Label(@"42029", @"Copy Full File Path"), saved);
	item(copy, 42030, Label(@"42030", @"Copy Filename"), saved);
	item(copy, 42031, Label(@"42031", @"Copy Current Directory Path"), saved);
	NSMenu *move = Submenu(menu, titleFor(3, @"Move Document"));
	item(move, 10005, @"Move to Start", YES);
	item(move, 10006, @"Move to End", YES);
	[move addItem:NSMenuItem.separatorItem];
	item(move, 10001, Label(@"10001", @"Move to Other View"), YES);
	item(move, 10002, Label(@"10002", @"Clone to Other View"), YES);
	for (NSInteger command : {10003, 10004})
	{
		NSMenuItem *instance = Item(move, Label([@(command) stringValue], command == 10003 ? @"Move to New Instance" : @"Open in New Instance"),
			NSApp.delegate, @selector(openDocumentInNewInstance:), command == 10003 || saved, command);
		instance.representedObject = document;
	}
	NSMenu *colors = Submenu(menu, titleFor(4, @"Apply Color to Tab"));
	for (NSInteger index = 1; index <= 5; ++index)
	{
		NSMenuItem *color = item(colors, 44110 + index, [NSString stringWithFormat:@"Apply Color %ld", index], YES);
		color.state = document.tabColorIndex == index ? NSControlStateValueOn : NSControlStateValueOff;
		NSColor *swatch = EditorTabColor(index);
		if (swatch)
			color.image = [NSImage imageWithSize:NSMakeSize(11, 11) flipped:NO drawingHandler:^BOOL(NSRect rect) {
				[swatch setFill];
				NSRectFill(rect);
				return YES;
			}];
	}
	item(colors, 44110, @"Remove Color", document.tabColorIndex != 0);
	return CustomContextMenu(menu, document, YES);
}

@implementation EditorContextView
- (NSMenu *)menuForEvent:(NSEvent *)event
{
	EditorDocument *document = self.document;
	if (!document)
		return [super menuForEvent:event];
	[self.window makeFirstResponder:self.content];
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Editor"];
	menu.autoenablesItems = NO;
	const BOOL writable = ![self message:SCI_GETREADONLY];
	const BOOL selected = ![self message:SCI_GETSELECTIONEMPTY];
	Item(menu, Label(@"42001", @"Cut"), self.content, @selector(cut:), selected && writable);
	Item(menu, Label(@"42002", @"Copy"), self.content, @selector(copy:), selected);
	Item(menu, Label(@"42005", @"Paste"), self.content, @selector(paste:), [self message:SCI_CANPASTE] != 0);
	Item(menu, Label(@"42006", @"Delete"), self, @selector(executeMenuCommand:), selected && writable, SCI_CLEAR);
	Item(menu, Label(@"42007", @"Select All"), self.content, @selector(selectAll:), YES);
	[menu addItem:NSMenuItem.separatorItem];
	Item(menu, Label(@"42003", @"Undo"), self.content, @selector(undo:), writable && [self message:SCI_CANUNDO]);
	Item(menu, Label(@"42004", @"Redo"), self.content, @selector(redo:), writable && [self message:SCI_CANREDO]);
	Item(menu, Label(@"42010", @"Duplicate Current Line"), self, @selector(executeMenuCommand:), writable, SCI_LINEDUPLICATE);
	[menu addItem:NSMenuItem.separatorItem];
	Item(menu, Label(@"43001", @"Find…"), self, @selector(findInEditor:), YES);
	Item(menu, Label(@"43003", @"Replace…"), self, @selector(replaceInEditor:), writable);
	Item(menu, Label(@"43054", @"Mark…"), self, @selector(markInEditor:), YES);
	Item(menu, Label(@"43009", @"Go to Matching Brace"), document, @selector(findMatchingBrace:), YES, 43009);
	[menu addItem:NSMenuItem.separatorItem];
	NSMenu *styles = Submenu(menu, Label(@"search-markAll", @"Style All Occurrences of Token"));
	for (NSInteger i = 0; i < 5; ++i)
	{
		const NSInteger command = 43022 + i * 2;
		Item(styles, Label([@(command) stringValue], [NSString stringWithFormat:@"Style %ld", i + 1]),
			document, @selector(useMarkStyle:), YES, command);
	}
	Item(menu, Label(@"43032", @"Clear All Styles"), document, @selector(useMarkStyle:), YES, 43032);
	NSMenu *selection = Submenu(menu, Label(@"edit-onSelection", @"On Selection"));
	Item(selection, Label(@"42073", @"Open File"), NSApp.delegate, @selector(actOnSelection:), selected, 42073);
	Item(selection, Label(@"native-showSelectionInFinder", @"Open Containing Folder in Finder"), NSApp.delegate,
		@selector(actOnSelection:), selected, 42074);
	Item(selection, Label(@"42075", @"Search on Internet"), NSApp.delegate, @selector(actOnSelection:), selected, 42075);
	Item(selection, Label(@"42106", @"Redact Selection"), NSApp.delegate, @selector(actOnSelection:), selected && writable, 42106);
	return CustomContextMenu(menu, document, NO);
}

- (void)executeMenuCommand:(NSMenuItem *)item { [self message:static_cast<unsigned int>(item.tag)]; }
- (void)focusEditorView { [self.window makeFirstResponder:self.content]; }
- (void)findInEditor:(id)sender { [self focusEditorView]; [self.document findText:nil]; }
- (void)replaceInEditor:(id)sender { [self focusEditorView]; [self.document replaceText:nil]; }
- (void)markInEditor:(id)sender { [self focusEditorView]; [self.document markText:nil]; }
@end

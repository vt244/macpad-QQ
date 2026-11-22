// SPDX-License-Identifier: GPL-3.0-only
#import "EditorSettings.h"
#import "EditorDocument.h"
#import "EditorResources.h"

static void Place(NSView *view, NSView *item, CGFloat x, CGFloat y, CGFloat width, CGFloat height = 24)
{
	item.frame = NSMakeRect(x, y, width, height);
	[view addSubview:item];
}

static NSString *SettingsLabel(NSString *text)
{
	return [EditorResources.shared label:[@"settings-" stringByAppendingString:text] fallback:text];
}

static void Label(NSView *view, NSString *name, CGFloat y)
{
	Place(view, [NSTextField labelWithString:SettingsLabel(name)], 0, y, 154);
}

void EditorShowPreferences(void)
{
	EditorResources *resources = EditorResources.shared;
	auto localized = ^NSString *(NSString *key, NSString *fallback) { return [resources label:key fallback:fallback]; };
	NSAlert *window = [NSAlert new];
	window.messageText = localized(@"Preference:title", @"Preferences");
	window.window.appearance = [NSAppearance appearanceNamed:resources.usesDarkColors ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
	[window addButtonWithTitle:localized(@"native-apply", @"Apply")];
	[window addButtonWithTitle:localized(@"native-cancel", @"Cancel")];
	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 520, 306)];
	NSMutableDictionary<NSString *, NSControl *> *controls = [NSMutableDictionary dictionary];
	auto tab = ^NSView *(NSString *key, NSString *title) {
		NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:key];
		item.label = localized(key, title);
		item.view = [[NSView alloc] initWithFrame:tabs.contentRect];
		[tabs addTabViewItem:item];
		return item.view;
	};
	auto checks = ^(NSView *view, NSArray<NSArray *> *rows, CGFloat y) {
		for (NSArray *row in rows)
		{
			NSString *name = row[0];
			NSButton *check = [NSButton checkboxWithTitle:localized([@"pref-" stringByAppendingString:name], row[1]) target:nil action:nil];
			check.state = [[resources setting:name fallback:row[2]] boolValue];
			Place(view, check, 12, y, 480);
			controls[name] = check;
			y -= 24;
		}
	};
	auto labeled = ^(NSView *view, NSString *name, NSString *title, NSControl *control, CGFloat y) {
		NSString *label = localized([@"pref-" stringByAppendingString:name], title);
		Place(view, [NSTextField labelWithString:label], 12, y, 220);
		[control setAccessibilityLabel:label];
		Place(view, control, 232, y, 252);
		controls[name] = control;
	};
	auto choice = ^(NSView *view, NSString *name, NSString *title, NSArray<NSString *> *options, NSInteger fallback, CGFloat y) {
		NSPopUpButton *control = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
		for (NSUInteger index = 0; index < options.count; ++index)
			[control addItemWithTitle:localized([NSString stringWithFormat:@"pref-%@-%lu", name, index], options[index])];
		NSInteger selected = [[resources setting:name fallback:@(fallback)] integerValue];
		[control selectItemAtIndex:MAX(0, MIN(selected, (NSInteger)options.count - 1))];
		labeled(view, name, title, control, y);
	};
	auto field = ^(NSView *view, NSString *name, NSString *title, NSString *fallback, CGFloat y) {
		NSTextField *control = [NSTextField textFieldWithString:[[resources setting:name fallback:fallback] description]];
		labeled(view, name, title, control, y);
	};
	NSView *editor = tab(@"pref-editor", @"Editing");
	checks(editor, @[@[@"insertSpaces", @"Insert spaces for indentation", @NO], @[@"backspaceUnindent", @"Backspace unindents", @NO],
		@[@"virtualSpace", @"Allow the caret beyond the end of a line", @NO], @[@"multipleSelections", @"Enable multiple selections", @YES]], 220);
	field(editor, @"dateTimeFormat", @"Custom date and time format", @"yyyy-MM-dd HH:mm:ss", 82);
	field(editor, @"tabWidth", @"Tab width", @"4", 52);

	NSView *display = tab(@"pref-display", @"Display");
	checks(display, @[@[@"wordWrap", @"Wrap long lines", @NO], @[@"lineNumbers", @"Show line numbers", @YES],
		@[@"bookmarkMargin", @"Show bookmark margin", @YES], @[@"indentGuide", @"Show indentation guides", @NO],
		@[@"whitespace", @"Show spaces and tabs", @NO], @[@"showEOL", @"Show end-of-line characters", @NO],
		@[@"showWrapSymbol", @"Show wrap symbols", @NO], @[@"scrollBeyondLastLine", @"Scroll beyond the last line", @NO]], 220);
	choice(display, @"toolbarStyle", @"Toolbar icons", @[@"Regular (small)", @"Regular (large)", @"Filled (small)", @"Filled (large)", @"Classic"], 0, 18);

	NSView *files = tab(@"pref-files", @"Files and tabs");
	checks(files, @[@[@"autoReload", @"Reload unchanged buffers automatically", @NO],
		@[@"reloadToEnd", @"Go to the end after reloading", @NO], @[@"hideToolbar", @"Hide the toolbar", @NO],
		@[@"hideTabBar", @"Hide the tab bar", @NO], @[@"tabCloseButtons", @"Show close buttons on tabs", @YES],
		@[@"doubleClickClosesTab", @"Double-click a tab to close it", @NO], @[@"hideStatusBar", @"Hide the status bar", @NO]], 242);
	choice(files, @"fileStatusMode", @"File change detection", @[@"Disabled", @"Active document", @"All open documents"], 1, 63);
	choice(files, @"newDocumentEOL", @"New document line ending", @[@"Windows (CRLF)", @"Classic Mac (CR)", @"Unix (LF)"], 0, 35);
	choice(files, @"newDocumentEncoding", @"New document encoding", @[@"Windows-1252", @"UTF-8 with BOM",
		@"UTF-16 BE with BOM", @"UTF-16 LE with BOM", @"UTF-8", @"ASCII", @"UTF-16 BE", @"UTF-16 LE"], 4, 7);

	NSView *tabOptions = tab(@"pref-tabs", @"Tabs");
	checks(tabOptions, @[@[@"mruTabSwitcher", @"Switch recent documents with Control-Tab", @YES],
		@[@"tabPreview", @"Preview an inactive tab on hover", @NO], @[@"verticalTabs", @"Show tabs on the left", @NO],
		@[@"multilineTabs", @"Wrap tabs to multiple rows", @NO]], 220);

	NSView *large = tab(@"pref-largeFiles", @"Large files");
	checks(large, @[@[@"limitLargeFiles", @"Skip syntax highlighting for large files", @NO],
		@[@"largeFileBraceMatch", @"Allow matching brace commands", @NO],
		@[@"largeFileDisableWrap", @"Disable word wrap for large files", @NO]], 220);
	field(large, @"largeFileMegabytes", @"Large file threshold (MiB)", @"200", 107);

	NSView *search = tab(@"pref-search", @"Searching");
	checks(search, @[@[@"fillFindSelection", @"Use selected text when opening Find", @YES],
		@[@"fillFindWord", @"Use the word under the caret if there is no selection", @NO],
		@[@"findFilesOnDisk", @"Search files on disk even if a buffer has unsaved edits", @NO]], 220);

	window.accessoryView = tabs;
	if ([window runModal] != NSAlertFirstButtonReturn)
		return;
	NSMutableDictionary *settings = [NSMutableDictionary dictionary];
	NSDictionary<NSString *, NSArray<NSNumber *> *> *ranges =
		@{@"tabWidth": @[@1, @32], @"autocompleteMinimum": @[@1, @9], @"checkpointMilliseconds": @[@250, @600000], @"largeFileMegabytes": @[@1, @4096]};
	for (NSString *name in controls)
	{
		NSControl *control = controls[name];
		if ([control isKindOfClass:NSButton.class] && ![control isKindOfClass:NSPopUpButton.class])
			settings[name] = @(((NSButton *)control).state == NSControlStateValueOn);
		else if ([control isKindOfClass:NSPopUpButton.class])
			settings[name] = @(((NSPopUpButton *)control).indexOfSelectedItem);
		else if (NSArray<NSNumber *> *range = ranges[name])
			settings[name] = @(MAX(range.firstObject.integerValue, MIN(range.lastObject.integerValue, control.integerValue)));
		else
			settings[name] = control.stringValue;
	}
	[resources setSettings:settings];
	for (EditorDocument *document in NSDocumentController.sharedDocumentController.documents)
		[document applyPreferences];
}

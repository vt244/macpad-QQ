// SPDX-License-Identifier: GPL-3.0-only
#import "EditorSettings.h"
#import "EditorDocument.h"
#import "EditorMacros.h"
#import "EditorResources.h"
#include "Scintilla.h"
#include "pugiconfig.hpp"
#undef PUGIXML_CHARCONV_FLOAT
#include "pugixml.hpp"
#include <cstring>
#include <sstream>
#include <vector>

static void Place(NSView *view, NSView *item, CGFloat x, CGFloat y, CGFloat width, CGFloat height = 24)
{
	item.frame = NSMakeRect(x, y, width, height);
	[view addSubview:item];
}

static NSString *SettingsLabel(NSString *text)
{
	return [EditorResources.shared label:[@"settings-" stringByAppendingString:text] fallback:text];
}

static void Label(NSView *view, NSString *name, CGFloat y, CGFloat width)
{
	NSTextField *label = [NSTextField labelWithString:SettingsLabel(name)];
	label.toolTip = label.stringValue;
	label.lineBreakMode = NSLineBreakByTruncatingTail;
	Place(view, label, 0, y, width);
}

@interface PreferencePage : NSView
- (void)addPreferenceRow:(NSView *)control label:(NSString *)label;
@end

@implementation PreferencePage
- (BOOL)isFlipped { return YES; }

- (void)addPreferenceRow:(NSView *)control label:(NSString *)label
{
	const CGFloat inset = 8, labelWidth = 240, gap = 14;
	CGFloat y = NSHeight(self.frame) ? NSHeight(self.frame) : inset;
	CGFloat width = NSWidth(self.bounds) - 2 * inset;
	NSTextField *caption = label ? [NSTextField wrappingLabelWithString:label] : nil;
	CGFloat captionHeight = label ? ceil([caption.cell cellSizeForBounds:NSMakeRect(0, 0, labelWidth, 1000)].height) : 0;
	CGFloat height = MAX(24, captionHeight);
	if ([control isKindOfClass:NSTextField.class] && ![(NSTextField *)control isEditable])
		height = MAX(height, ceil([[(NSTextField *)control cell] cellSizeForBounds:NSMakeRect(0, 0, width, 1000)].height));
	[self setFrameSize:NSMakeSize(NSWidth(self.frame), y + height + 8)];
	if (caption)
	{
		Place(self, caption, inset, y + floor((height - captionHeight) / 2), labelWidth, captionHeight);
		Place(self, control, inset + labelWidth + gap, y + floor((height - 24) / 2), width - labelWidth - gap);
	}
	else
		Place(self, control, inset, y, width, height);
}
@end

@interface PreferenceSectionPicker : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSTabView *tabs;
@property(nonatomic, strong) NSTextField *heading;
- (void)apply:(id)sender;
- (void)cancel:(id)sender;
@end

@implementation PreferenceSectionPicker
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return self.tabs.numberOfTabViewItems; }

- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
	NSTableCellView *cell = [table makeViewWithIdentifier:@"category" owner:nil];
	if (!cell)
	{
		cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, column.width, 26)];
		cell.identifier = @"category";
		cell.textField = [NSTextField labelWithString:@""];
		cell.textField.lineBreakMode = NSLineBreakByTruncatingTail;
		cell.textField.autoresizingMask = NSViewWidthSizable;
		Place(cell, cell.textField, 6, 4, column.width - 12, 18);
	}
	cell.textField.stringValue = [self.tabs tabViewItemAtIndex:row].label;
	cell.textField.toolTip = cell.textField.stringValue;
	return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	NSTableView *table = notification.object;
	if (table.selectedRow < 0)
		return;
	[self.tabs selectTabViewItemAtIndex:table.selectedRow];
	self.heading.stringValue = self.tabs.selectedTabViewItem.label;
	[self.tabs.window recalculateKeyViewLoop];
}

- (void)apply:(id)sender
{
	if ([self.tabs.window makeFirstResponder:nil])
		[NSApp stopModalWithCode:NSModalResponseOK];
}

- (void)cancel:(id)sender { [NSApp stopModalWithCode:NSModalResponseCancel]; }
- (BOOL)windowShouldClose:(NSWindow *)window
{
	[self cancel:nil];
	return NO;
}
@end

void EditorShowPreferences(void)
{
	EditorResources *resources = EditorResources.shared;
	auto localized = ^NSString *(NSString *key, NSString *fallback) { return [resources label:key fallback:fallback]; };
	NSPanel *window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 760, 472)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
	window.title = localized(@"Preference:title", @"Preferences");
	window.releasedWhenClosed = NO;
	window.appearance = [NSAppearance appearanceNamed:resources.usesDarkColors ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(222, 60, 522, 363)];
	tabs.tabViewType = NSNoTabsNoBorder;
	NSMutableDictionary<NSString *, NSControl *> *controls = [NSMutableDictionary dictionary];
	auto tab = ^PreferencePage *(NSString *key, NSString *title) {
		NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:key];
		item.label = localized(key, title);
		NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:tabs.contentRect];
		scroll.hasVerticalScroller = YES;
		scroll.drawsBackground = NO;
		PreferencePage *page = [[PreferencePage alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(tabs.contentRect) - 18, 0)];
		scroll.documentView = page;
		item.view = scroll;
		[tabs addTabViewItem:item];
		return page;
	};
	auto checks = ^(PreferencePage *view, NSArray<NSArray *> *rows) {
		for (NSArray *row in rows)
		{
			NSString *name = row[0];
			NSButton *check = [NSButton checkboxWithTitle:localized([@"pref-" stringByAppendingString:name], row[1]) target:nil action:nil];
			check.state = [[resources setting:name fallback:row[2]] boolValue];
			check.toolTip = check.title;
			[view addPreferenceRow:check label:nil];
			controls[name] = check;
		}
	};
	auto labeled = ^(PreferencePage *view, NSString *name, NSString *title, NSControl *control) {
		NSString *label = localized([@"pref-" stringByAppendingString:name], title);
		[control setAccessibilityLabel:label];
		[view addPreferenceRow:control label:label];
		controls[name] = control;
	};
	auto choice = ^(PreferencePage *view, NSString *name, NSString *title, NSArray<NSString *> *options, NSInteger fallback) {
		NSPopUpButton *control = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
		for (NSUInteger index = 0; index < options.count; ++index)
			[control addItemWithTitle:localized([NSString stringWithFormat:@"pref-%@-%lu", name, index], options[index])];
		NSInteger selected = [[resources setting:name fallback:@(fallback)] integerValue];
		[control selectItemAtIndex:MAX(0, MIN(selected, (NSInteger)options.count - 1))];
		labeled(view, name, title, control);
	};
	auto field = ^(PreferencePage *view, NSString *name, NSString *title, NSString *fallback) {
		NSTextField *control = [NSTextField textFieldWithString:[[resources setting:name fallback:fallback] description]];
		labeled(view, name, title, control);
	};
	PreferencePage *editor = tab(@"pref-editor", @"Editing");
	checks(editor, @[@[@"insertSpaces", @"Insert spaces for indentation", @NO], @[@"backspaceUnindent", @"Backspace unindents", @NO],
		@[@"virtualSpace", @"Allow the caret beyond the end of a line", @NO], @[@"multipleSelections", @"Enable multiple selections", @YES],
		@[@"autocomplete", @"Offer completions while typing", @YES], @[@"autoPairs", @"Insert matching delimiters and closing tags", @YES]]);
	field(editor, @"dateTimeFormat", @"Custom date and time format", @"yyyy-MM-dd HH:mm:ss");
	field(editor, @"tabWidth", @"Tab width", @"4");
	field(editor, @"autocompleteMinimum", @"Characters before completion", @"2");
	field(editor, @"caretWidth", @"Caret width", @"1");
	field(editor, @"caretBlink", @"Caret blink period (ms)", @"500");

	PreferencePage *display = tab(@"pref-display", @"Display");
	checks(display, @[@[@"wordWrap", @"Wrap long lines", @NO], @[@"lineNumbers", @"Show line numbers", @YES],
		@[@"bookmarkMargin", @"Show bookmark margin", @YES], @[@"indentGuide", @"Show indentation guides", @NO],
		@[@"whitespace", @"Show spaces and tabs", @NO], @[@"showEOL", @"Show end-of-line characters", @NO],
		@[@"showWrapSymbol", @"Show wrap symbols", @NO], @[@"scrollBeyondLastLine", @"Scroll beyond the last line", @NO]]);
	choice(display, @"toolbarStyle", @"Toolbar icons", @[@"Regular (small)", @"Regular (large)", @"Filled (small)", @"Filled (large)", @"Classic"], 0);
	checks(display, @[@[@"selectedTextForeground", @"Use the theme’s selected text color", @NO]]);
	PreferencePage *guides = tab(@"pref-guides", @"Editor guides");
	choice(guides, @"currentLineMode", @"Current line", @[@"Off", @"Highlight", @"Outline"], 0);
	field(guides, @"currentLineFrameWidth", @"Outline width", @"1");
	choice(guides, @"wrapIndent", @"Wrapped line indent", @[@"Default", @"Aligned", @"Indented"], 0);
	field(guides, @"edgeColumns", @"Vertical ruler columns", @"");
	checks(guides, @[@[@"edgeBackground", @"Shade beyond a single ruler", @NO]]);
	choice(guides, @"eolRepresentation", @"End-of-line markers", @[@"Plain text", @"Boxed", @"Plain text with theme color",
		@"Boxed with theme color"], 1);
	PreferencePage *styleOverride = tab(@"pref-styleOverride", @"Global style override");
	checks(styleOverride, @[@[@"styleOverrideForeground", @"Force foreground color for all styles", @NO],
		@[@"styleOverrideBackground", @"Force background color for all styles", @NO],
		@[@"styleOverrideFont", @"Force font choice for all styles", @NO],
		@[@"styleOverrideSize", @"Force font size choice for all styles", @NO],
		@[@"styleOverrideBold", @"Force bold choice for all styles", @NO],
		@[@"styleOverrideItalic", @"Force italic choice for all styles", @NO],
		@[@"styleOverrideUnderline", @"Force underline choice for all styles", @NO]]);

	PreferencePage *files = tab(@"pref-files", @"Files and tabs");
	checks(files, @[@[@"saveAllConfirm", @"Confirm Save All", @YES],
		@[@"detectEncoding", @"Automatically detect legacy encodings", @YES]]);
	checks(files, @[@[@"autoReload", @"Reload unchanged buffers automatically", @NO],
		@[@"reloadToEnd", @"Go to the end after reloading", @NO], @[@"hideToolbar", @"Hide the toolbar", @NO],
		@[@"hideTabBar", @"Hide the tab bar", @NO], @[@"tabCloseButtons", @"Show close buttons on tabs", @YES],
		@[@"doubleClickClosesTab", @"Double-click a tab to close it", @NO], @[@"hideStatusBar", @"Hide the status bar", @NO]]);
	choice(files, @"fileStatusMode", @"File change detection", @[@"Disabled", @"Active document", @"All open documents"], 1);
	choice(files, @"newDocumentEOL", @"New document line ending", @[@"Windows (CRLF)", @"Classic Mac (CR)", @"Unix (LF)"], 0);
	choice(files, @"newDocumentEncoding", @"New document encoding", @[@"Windows-1252", @"UTF-8 with BOM",
		@"UTF-16 BE with BOM", @"UTF-16 LE with BOM", @"UTF-8", @"ASCII", @"UTF-16 BE", @"UTF-16 LE"], 4);

	PreferencePage *tabOptions = tab(@"pref-tabs", @"Tabs");
	checks(tabOptions, @[@[@"mruTabSwitcher", @"Switch recent documents with Control-Tab", @YES],
		@[@"tabPreview", @"Preview an inactive tab on hover", @NO], @[@"verticalTabs", @"Show tabs on the left", @NO],
		@[@"multilineTabs", @"Wrap tabs to multiple rows", @NO], @[@"lockTabs", @"Prevent dragging tabs", @NO]]);

	PreferencePage *large = tab(@"pref-largeFiles", @"Large files");
	checks(large, @[@[@"limitLargeFiles", @"Skip syntax highlighting for large files", @NO],
		@[@"largeFileCompletion", @"Allow automatic completion", @NO],
		@[@"largeFileBraceMatch", @"Allow matching brace commands", @NO],
		@[@"largeFileDisableWrap", @"Disable word wrap for large files", @NO]]);
	field(large, @"largeFileMegabytes", @"Large file threshold (MiB)", @"200");

	PreferencePage *search = tab(@"pref-search", @"Searching");
	checks(search, @[@[@"fillFindSelection", @"Use selected text when opening Find", @YES],
		@[@"fillFindWord", @"Use the word under the caret if there is no selection", @NO],
		@[@"findFilesOnDisk", @"Search files on disk even if a buffer has unsaved edits", @NO],
		@[@"monospacedFontFindDlg", @"Use a monospaced font in Find", @NO]]);
	field(search, @"inSelectionAutocheckThreshold", @"Auto-select search scope from (chars)", @"1024");
	field(search, @"fillFindWhatThreshold", @"Max characters to fill Find", @"1024");
	NSTextField *selectionHint = [NSTextField wrappingLabelWithString:localized(@"pref-inSelectionHint",
		@"Set the selection threshold to 0 to keep manual control of “In selection”.")];
	selectionHint.textColor = NSColor.secondaryLabelColor;
	[search addPreferenceRow:selectionHint label:nil];

	PreferencePage *backup = tab(@"pref-backup", @"Backup and sessions");
	checks(backup, @[@[@"rememberSession", @"Restore the last session on startup", @YES],
		@[@"checkpointDrafts", @"Periodically save unsaved edits for recovery", @YES]]);
	choice(backup, @"instanceMode", @"Open files in", @[@"Current instance", @"New instance for sessions", @"New instance for every file"], 0);
	choice(backup, @"backupMode", @"Keep a backup of saved files", @[@"None", @"One .bak copy", @"Keep dated copies"], 0);
	field(backup, @"backupDirectory", @"Backup folder (optional)", @"");
	field(backup, @"checkpointMilliseconds", @"Recovery interval (ms)", @"1000");

	PreferencePage *printing = tab(@"pref-print", @"Printing");
	choice(printing, @"printColorMode", @"Color mode", @[@"Editor colors", @"Invert colors", @"Black on white", @"Colors without background"], SC_PRINT_BLACKONWHITE);
	checks(printing, @[@[@"printLineNumbers", @"Print line numbers", @NO]]);
	NSArray *directions = @[@"Left", @"Middle", @"Right"];
	NSArray *headerTitles = @[@"Left header", @"Center header", @"Right header"];
	NSArray *footerTitles = @[@"Left footer", @"Center footer", @"Right footer"];
	for (NSUInteger i = 0; i < directions.count; ++i)
		field(printing, [@"printHeader" stringByAppendingString:directions[i]], headerTitles[i], @"");
	for (NSUInteger i = 0; i < directions.count; ++i)
		field(printing, [@"printFooter" stringByAppendingString:directions[i]], footerTitles[i], @"");
	field(printing, @"printMargins", @"Margins in mm (left, top, right, bottom)",
		[NSString stringWithFormat:@"%@, %@, %@, %@", [resources setting:@"printMarginLeft" fallback:@18],
			[resources setting:@"printMarginTop" fallback:@18], [resources setting:@"printMarginRight" fallback:@18],
			[resources setting:@"printMarginBottom" fallback:@18]]);
	PreferencePage *printLayout = tab(@"pref-print-layout", @"Print layout");
	checks(printLayout, @[@[@"printFormFeedBreak", @"Print form feed as a page break", @NO]]);
	field(printLayout, @"printHeaderFontName", @"Header font", @"");
	field(printLayout, @"printHeaderFontSize", @"Header font size", @"9");
	field(printLayout, @"printFooterFontName", @"Footer font", @"");
	field(printLayout, @"printFooterFontSize", @"Footer font size", @"9");

	CGFloat sidebarWidth = 188;
	NSDictionary *categoryFont = @{NSFontAttributeName: [NSFont systemFontOfSize:NSFont.systemFontSize]};
	for (NSTabViewItem *item in tabs.tabViewItems)
		sidebarWidth = MAX(sidebarWidth, ceil([item.label sizeWithAttributes:categoryFont].width) + 72);
	sidebarWidth = MIN(sidebarWidth, 330);
	CGFloat extraWidth = sidebarWidth - 188;
	[window setContentSize:NSMakeSize(760 + extraWidth, 472)];
	NSView *content = window.contentView;
	tabs.frame = NSOffsetRect(tabs.frame, extraWidth, 0);
	[content addSubview:tabs];
	NSScrollView *sidebar = [[NSScrollView alloc] initWithFrame:NSMakeRect(14, 59, sidebarWidth, 393)];
	sidebar.hasVerticalScroller = YES;
	sidebar.drawsBackground = NO;
	NSTableView *sections = [[NSTableView alloc] initWithFrame:sidebar.contentView.bounds];
	sections.headerView = nil;
	sections.style = NSTableViewStyleSourceList;
	sections.rowHeight = 26;
	sections.allowsEmptySelection = NO;
	sections.accessibilityIdentifier = @"preferences-categories";
	[sections setAccessibilityLabel:localized(@"pref-category", @"Preferences category")];
	NSTableColumn *category = [[NSTableColumn alloc] initWithIdentifier:@"category"];
	category.width = NSWidth(sidebar.contentView.bounds) - 20;
	[sections addTableColumn:category];
	sidebar.documentView = sections;
	[content addSubview:sidebar];
	NSBox *divider = [NSBox new];
	divider.boxType = NSBoxSeparator;
	Place(content, divider, 211 + extraWidth, 54, 1, 401);
	NSTextField *heading = [NSTextField labelWithString:@""];
	heading.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
	Place(content, heading, 230 + extraWidth, 430, 510, 29);
	NSBox *footer = [NSBox new];
	footer.boxType = NSBoxSeparator;
	Place(content, footer, 14, 52, 732 + extraWidth, 1);
	__attribute__((objc_precise_lifetime)) PreferenceSectionPicker *picker = [PreferenceSectionPicker new];
	picker.tabs = tabs;
	picker.heading = heading;
	window.delegate = picker;
	sections.dataSource = picker;
	sections.delegate = picker;
	[sections reloadData];
	[sections selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	NSButton *apply = [NSButton buttonWithTitle:localized(@"native-apply", @"Apply") target:picker action:@selector(apply:)];
	NSButton *cancel = [NSButton buttonWithTitle:localized(@"native-cancel", @"Cancel") target:picker action:@selector(cancel:)];
	apply.keyEquivalent = @"\r";
	cancel.keyEquivalent = @"\033";
	CGFloat applyWidth = MAX(94, ceil(apply.cell.cellSize.width) + 12);
	CGFloat cancelWidth = MAX(94, ceil(cancel.cell.cellSize.width) + 12);
	Place(content, apply, 744 + extraWidth - applyWidth, 13, applyWidth, 28);
	Place(content, cancel, 736 + extraWidth - applyWidth - cancelWidth, 13, cancelWidth, 28);
	window.initialFirstResponder = sections;
	[window center];
	NSModalResponse response = [NSApp runModalForWindow:window];
	[window orderOut:nil];
	if (response != NSModalResponseOK)
		return;
	NSMutableDictionary *settings = [NSMutableDictionary dictionary];
	NSDictionary<NSString *, NSArray<NSNumber *> *> *ranges =
		@{@"tabWidth": @[@1, @32], @"autocompleteMinimum": @[@1, @9], @"checkpointMilliseconds": @[@250, @600000],
			@"largeFileMegabytes": @[@1, @4096], @"caretWidth": @[@0, @20], @"caretBlink": @[@0, @5000],
			@"printHeaderFontSize": @[@1, @72], @"printFooterFontSize": @[@1, @72], @"currentLineFrameWidth": @[@1, @6],
			@"inSelectionAutocheckThreshold": @[@0, @1024], @"fillFindWhatThreshold": @[@1, @16383]};
	for (NSString *name in controls)
	{
		NSControl *control = controls[name];
		if ([name isEqualToString:@"printMargins"])
		{
			NSArray *values = [control.stringValue componentsSeparatedByString:@","];
			NSArray *keys = @[@"printMarginLeft", @"printMarginTop", @"printMarginRight", @"printMarginBottom"];
			if (values.count == keys.count)
				for (NSUInteger i = 0; i < keys.count; ++i)
					settings[keys[i]] = @(MAX(0, MIN(100, [values[i] doubleValue])));
		}
		else if ([control isKindOfClass:NSButton.class] && ![control isKindOfClass:NSPopUpButton.class])
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

static NSColor *Color(NSString *hex, NSColor *fallback)
{
	unsigned number = 0;
	if (hex.length != 6 || ![[NSScanner scannerWithString:hex] scanHexInt:&number])
		return fallback;
	return [NSColor colorWithSRGBRed:(number >> 16) / 255.0 green:((number >> 8) & 255) / 255.0 blue:(number & 255) / 255.0 alpha:1];
}

static NSString *Hex(NSColor *color)
{
	color = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	return [NSString stringWithFormat:@"%02X%02X%02X", (int)lround(color.redComponent * 255),
		(int)lround(color.greenComponent * 255), (int)lround(color.blueComponent * 255)];
}

@interface StyleForm : NSObject
- (BOOL)edit;
@end

@implementation StyleForm
{
	NSMutableDictionary<NSString *, NSArray<NSMutableDictionary *> *> *_definitions;
	NSPopUpButton *_language;
	NSPopUpButton *_style;
	NSColorWell *_foreground;
	NSColorWell *_background;
	NSButton *_useForeground;
	NSButton *_useBackground;
	NSButton *_bold;
	NSButton *_italic;
	NSButton *_underline;
	NSTextField *_font;
	NSTextField *_size;
	NSMutableDictionary *_current;
}

- (void)saveCurrent
{
	if (!_current)
		return;
	_current[@"fgColor"] = Hex(_foreground.color);
	_current[@"bgColor"] = Hex(_background.color);
	_current[@"colorStyle"] = [@((_useForeground.state ? 1 : 0) | (_useBackground.state ? 2 : 0)) stringValue];
	_current[@"fontStyle"] = [@((_bold.state ? 1 : 0) | (_italic.state ? 2 : 0) | (_underline.state ? 4 : 0)) stringValue];
	_current[@"fontName"] = _font.stringValue;
	_current[@"fontSize"] = _size.stringValue.length ? [@(MIN(96, MAX(0, _size.integerValue))) stringValue] : @"";
}

- (void)chooseLanguage:(id)sender
{
	[self saveCurrent];
	_current = nil;
	[_style removeAllItems];
	NSArray *styles = _definitions[_language.selectedItem.representedObject];
	[_style addItemsWithTitles:[styles valueForKey:@"name"]];
	for (NSUInteger index = 0; index < styles.count; ++index)
		[_style itemAtIndex:index].representedObject = styles[index];
	[self chooseStyle:nil];
}

- (void)chooseStyle:(id)sender
{
	[self saveCurrent];
	_current = _style.selectedItem.representedObject;
	int fontStyle = [_current[@"fontStyle"] intValue];
	int colorStyle = _current[@"colorStyle"] ? [_current[@"colorStyle"] intValue] : 3;
	_foreground.color = Color(_current[@"fgColor"], NSColor.textColor);
	_background.color = Color(_current[@"bgColor"], NSColor.textBackgroundColor);
	_useForeground.state = (colorStyle & 1) != 0;
	_useBackground.state = (colorStyle & 2) != 0;
	_bold.state = (fontStyle & 1) != 0;
	_italic.state = (fontStyle & 2) != 0;
	_underline.state = (fontStyle & 4) != 0;
	_font.stringValue = _current[@"fontName"] ?: @"";
	_size.stringValue = _current[@"fontSize"] ?: @"";
}

- (BOOL)edit
{
	EditorResources *resources = EditorResources.shared;
	_definitions = [[resources styleDefinitions] mutableCopy];
	if (!_definitions.count)
		return NO;
	NSAlert *dialog = [NSAlert new];
	dialog.messageText = [resources label:@"StyleConfig:title" fallback:@"Style Configurator"];
	dialog.informativeText = [NSString stringWithFormat:SettingsLabel(@"Theme: %@"), resources.selectedTheme.URLByDeletingPathExtension.lastPathComponent ?: @"Default"];
	[dialog addButtonWithTitle:[resources label:@"StyleConfig:2301" fallback:@"Save & Close"]];
	[dialog addButtonWithTitle:[resources label:@"StyleConfig:2" fallback:@"Cancel"]];
	NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 470, 240)];
	_language = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_style = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_language.target = _style.target = self;
	_language.action = @selector(chooseLanguage:);
	_style.action = @selector(chooseStyle:);
	for (NSString *language in [_definitions.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)])
	{
		[_language addItemWithTitle:language.length ? language : SettingsLabel(@"Global Styles")];
		_language.lastItem.representedObject = language;
	}
	Label(form, @"Language", 212, 162);
	Place(form, _language, 176, 212, 294);
	Label(form, @"Style", 179, 162);
	Place(form, _style, 176, 179, 294);
	_foreground = [[NSColorWell alloc] initWithFrame:NSZeroRect];
	_background = [[NSColorWell alloc] initWithFrame:NSZeroRect];
	_useForeground = [NSButton checkboxWithTitle:SettingsLabel(@"Use foreground color") target:nil action:nullptr];
	_useBackground = [NSButton checkboxWithTitle:SettingsLabel(@"Use background color") target:nil action:nullptr];
	Place(form, _useForeground, 0, 144, 306);
	Place(form, _foreground, 320, 144, 72);
	Place(form, _useBackground, 0, 111, 306);
	Place(form, _background, 320, 111, 72);
	_font = [NSTextField textFieldWithString:@""];
	_font.placeholderString = SettingsLabel(@"Inherit");
	_size = [NSTextField textFieldWithString:@""];
	_size.placeholderString = SettingsLabel(@"Inherit");
	Label(form, @"Font family", 77, 162);
	Place(form, _font, 176, 77, 294);
	Label(form, @"Font size", 43, 162);
	Place(form, _size, 176, 43, 85);
	_bold = [NSButton checkboxWithTitle:[resources label:@"StyleConfig:2204" fallback:@"Bold"] target:nil action:nullptr];
	_italic = [NSButton checkboxWithTitle:[resources label:@"StyleConfig:2205" fallback:@"Italic"] target:nil action:nullptr];
	_underline = [NSButton checkboxWithTitle:[resources label:@"StyleConfig:2218" fallback:@"Underline"] target:nil action:nullptr];
	Place(form, _bold, 0, 8, 137);
	Place(form, _italic, 148, 8, 137);
	Place(form, _underline, 296, 8, 174);
	dialog.accessoryView = form;
	[self chooseLanguage:nil];
	if ([dialog runModal] != NSAlertFirstButtonReturn)
		return NO;
	[self saveCurrent];
	NSError *error = nil;
	if (![resources saveStyles:_definitions error:&error])
	{
		if (error)
			[NSApp presentError:error];
		return NO;
	}
	for (EditorDocument *document in NSDocumentController.sharedDocumentController.documents)
		[document applyTheme];
	return YES;
}
@end

BOOL EditorShowStyleConfigurator(void) { return [[StyleForm new] edit]; }

NSString *EditorShortcutIdentifier(NSMenuItem *item)
{
	NSString *action = item.action ? NSStringFromSelector(item.action) : @"";
	if ([action isEqualToString:@"assignScintillaShortcut:"])
		return [NSString stringWithFormat:@"scintilla/%ld", item.tag];
	if ([action isEqualToString:@"runPlugin:"] && [item.representedObject isKindOfClass:NSString.class])
		return item.representedObject;
	if ([action isEqualToString:@"selectLanguage:"] && [item.representedObject isKindOfClass:NSString.class])
		return [action stringByAppendingString:item.representedObject];
	if ([item.representedObject isKindOfClass:EditorMacro.class])
	{
		EditorMacro *macro = item.representedObject;
		return [NSString stringWithFormat:@"%@/%@/%@", action, macro.folder, macro.name];
	}
	if ([action isEqualToString:@"executeSavedRunCommand:"] && [item.representedObject isKindOfClass:NSString.class])
		return [action stringByAppendingString:item.representedObject];
	return [NSString stringWithFormat:@"%@/%ld", action, item.tag];
}

static void CollectCommands(NSMenu *menu, NSString *path, NSMutableDictionary<NSString *, NSMenuItem *> *commands)
{
	for (NSMenuItem *item in menu.itemArray)
	{
		NSString *name = path.length ? [NSString stringWithFormat:@"%@ › %@", path, item.title] : item.title;
		if (item.submenu)
			CollectCommands(item.submenu, name, commands);
		else if (item.action && item.title.length && item.action != @selector(showLicense:) && item.action != @selector(performZoom:))
			commands[name] = item;
	}
}

static void ApplyShortcutsToMenu(NSMenu *menu, NSDictionary *shortcuts)
{
	for (NSMenuItem *item in menu.itemArray)
	{
		if (item.submenu)
			ApplyShortcutsToMenu(item.submenu, shortcuts);
		else if (item.action)
		{
			NSDictionary *binding = shortcuts[EditorShortcutIdentifier(item)];
			if (![binding isKindOfClass:NSDictionary.class] ||
				![binding[@"key"] isKindOfClass:NSString.class] || ![binding[@"modifiers"] isKindOfClass:NSNumber.class])
				continue;
			item.keyEquivalent = binding[@"key"];
			item.keyEquivalentModifierMask = [binding[@"modifiers"] unsignedIntegerValue];
		}
	}
}

void EditorApplyShortcuts(NSMenu *menu)
{
	EditorResolvePendingPluginShortcuts(menu);
	NSDictionary *shortcuts = [EditorResources.shared setting:@"shortcuts" fallback:@{}];
	if (shortcuts.count)
		ApplyShortcutsToMenu(menu, shortcuts);
}

static NSString *DisplayKey(NSString *value)
{
	if (value.length == 1)
	{
		unichar key = [value characterAtIndex:0];
		if (key >= NSF1FunctionKey && key <= NSF20FunctionKey)
			return [NSString stringWithFormat:@"F%d", key - NSF1FunctionKey + 1];
		NSDictionary *special = @{@(NSLeftArrowFunctionKey): @"Left", @(NSRightArrowFunctionKey): @"Right",
			@(NSUpArrowFunctionKey): @"Up", @(NSDownArrowFunctionKey): @"Down", @(NSHomeFunctionKey): @"Home",
			@(NSEndFunctionKey): @"End", @(NSPageUpFunctionKey): @"Page Up", @(NSPageDownFunctionKey): @"Page Down",
			@(NSDeleteFunctionKey): @"Delete", @(NSInsertFunctionKey): @"Insert", @127: @"Backspace",
			@9: @"Tab", @13: @"Return", @27: @"Escape", @32: @"Space"};
		if (NSString *label = special[@(key)])
			return label;
	}
	return value;
}

static NSString *ReadKey(NSString *value)
{
	if (!value.length)
		return @"";
	if (value.length == 1)
		return value.lowercaseString;
	const unichar special[] = {NSLeftArrowFunctionKey, NSRightArrowFunctionKey, NSUpArrowFunctionKey, NSDownArrowFunctionKey,
		NSHomeFunctionKey, NSEndFunctionKey, NSPageUpFunctionKey, NSPageDownFunctionKey,
		NSDeleteFunctionKey, NSInsertFunctionKey, 127, 9, 13, 27, 32};
	for (const unichar &character : special)
	{
		NSString *key = [NSString stringWithCharacters:&character length:1];
		if ([DisplayKey(key) caseInsensitiveCompare:value] == NSOrderedSame)
			return key;
	}
	NSScanner *scanner = [NSScanner scannerWithString:[value substringFromIndex:1]];
	NSInteger function = 0;
	if ([value.uppercaseString hasPrefix:@"F"] && [scanner scanInteger:&function] && scanner.isAtEnd && function >= 1 && function <= 20)
		return [NSString stringWithFormat:@"%C", (unichar)(NSF1FunctionKey + function - 1)];
	return nil;
}

@interface ShortcutForm : NSObject
- (BOOL)edit:(NSMenu *)menu;
@end

@implementation ShortcutForm
{
	NSDictionary<NSString *, NSMenuItem *> *_commands;
	NSPopUpButton *_choice;
	NSTextField *_key;
	NSArray<NSButton *> *_modifiers;
	NSPopUpButton *_bindingPicker;
	NSButton *_addBinding;
	NSButton *_removeBinding;
	NSMutableArray<NSDictionary *> *_bindings;
	NSDictionary *_assigned;
	NSUInteger _bindingIndex;
}

static const NSEventModifierFlags ModifierFlags[] = {
	NSEventModifierFlagCommand, NSEventModifierFlagShift, NSEventModifierFlagOption, NSEventModifierFlagControl,
};

static NSArray<NSDictionary *> *ShortcutBindings(NSMenuItem *item, NSDictionary *assigned)
{
	NSMutableArray *bindings = [NSMutableArray array];
	if (item.keyEquivalent.length)
		[bindings addObject:@{@"key": item.keyEquivalent, @"modifiers": @(item.keyEquivalentModifierMask)}];
	if (item.action == @selector(assignScintillaShortcut:))
	{
		NSDictionary *record = assigned[EditorShortcutIdentifier(item)];
		NSArray *alternatives = [record isKindOfClass:NSDictionary.class] ? record[@"alternatives"] : nil;
		if ([alternatives isKindOfClass:NSArray.class])
			for (NSDictionary *alternative in alternatives)
				if ([alternative isKindOfClass:NSDictionary.class] && [alternative[@"key"] isKindOfClass:NSString.class] &&
					[alternative[@"key"] length] && [alternative[@"modifiers"] isKindOfClass:NSNumber.class] &&
					![bindings containsObject:alternative])
					[bindings addObject:alternative];
	}
	return bindings;
}

- (void)loadBinding
{
	[_bindingPicker removeAllItems];
	for (NSDictionary *binding in _bindings)
	{
		NSUInteger modifiers = [binding[@"modifiers"] unsignedIntegerValue];
		NSMutableString *label = [NSMutableString string];
		if (modifiers & NSEventModifierFlagControl) [label appendString:@"⌃"];
		if (modifiers & NSEventModifierFlagOption) [label appendString:@"⌥"];
		if (modifiers & NSEventModifierFlagShift) [label appendString:@"⇧"];
		if (modifiers & NSEventModifierFlagCommand) [label appendString:@"⌘"];
		NSString *key = binding[@"key"];
		[label appendString:key.length ? DisplayKey(key) : EditorUIString(@"Unassigned")];
		NSString *title = label;
		NSUInteger duplicate = 1;
		while ([_bindingPicker itemWithTitle:title])
			title = [NSString stringWithFormat:@"%@ (%lu)", label, ++duplicate];
		[_bindingPicker addItemWithTitle:title];
	}
	[_bindingPicker selectItemAtIndex:_bindingIndex];
	NSDictionary *binding = _bindings[_bindingIndex];
	_key.stringValue = DisplayKey(binding[@"key"]);
	for (NSUInteger i = 0; i < _modifiers.count; ++i)
		_modifiers[i].state = ([binding[@"modifiers"] unsignedIntegerValue] & ModifierFlags[i]) != 0;
}

- (BOOL)storeBinding
{
	NSString *key = ReadKey(_key.stringValue);
	if (!key)
		return NO;
	NSEventModifierFlags modifiers = 0;
	for (NSUInteger i = 0; i < _modifiers.count; ++i)
		if (_modifiers[i].state == NSControlStateValueOn)
			modifiers |= ModifierFlags[i];
	_bindings[_bindingIndex] = @{@"key": key, @"modifiers": @(modifiers)};
	return YES;
}

- (void)pickBinding:(NSPopUpButton *)sender
{
	if (![self storeBinding])
	{
		[sender selectItemAtIndex:_bindingIndex];
		NSBeep();
		return;
	}
	_bindingIndex = sender.indexOfSelectedItem;
	[self loadBinding];
}

- (void)addBinding:(id)sender
{
	if (![self storeBinding])
	{
		NSBeep();
		return;
	}
	[_bindings addObject:@{@"key": @"", @"modifiers": @0}];
	_bindingIndex = _bindings.count - 1;
	[self loadBinding];
	[_key.window makeFirstResponder:_key];
}

- (void)removeBinding:(id)sender
{
	[_bindings removeObjectAtIndex:_bindingIndex];
	if (!_bindings.count)
		[_bindings addObject:@{@"key": @"", @"modifiers": @0}];
	_bindingIndex = MIN(_bindingIndex, _bindings.count - 1);
	[self loadBinding];
}

- (void)choose:(id)sender
{
	NSMenuItem *item = _commands[_choice.titleOfSelectedItem ?: @""];
	_bindings = [ShortcutBindings(item, _assigned) mutableCopy];
	if (!_bindings.count)
		[_bindings addObject:@{@"key": @"", @"modifiers": @0}];
	_bindingIndex = 0;
	_bindingPicker.hidden = _addBinding.hidden = _removeBinding.hidden = item.action != @selector(assignScintillaShortcut:);
	[self loadBinding];
}

- (void)filter:(NSSearchField *)sender
{
	NSString *query = sender.stringValue;
	NSArray *names = [_commands.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
	if (query.length)
		names = [names filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
			if ([name localizedCaseInsensitiveContainsString:query])
				return YES;
			for (NSDictionary *binding in ShortcutBindings(_commands[name], _assigned))
				if ([DisplayKey(binding[@"key"]) localizedCaseInsensitiveContainsString:query])
					return YES;
			return NO;
		}]];
	[_choice removeAllItems];
	[_choice addItemsWithTitles:names];
	[self choose:nil];
}

- (BOOL)edit:(NSMenu *)menu
{
	NSMutableDictionary *commands = [NSMutableDictionary dictionary];
	CollectCommands(menu, @"", commands);
	_assigned = [EditorResources.shared setting:@"shortcuts" fallback:@{}];
	NSDictionary *scintilla = EditorScintillaCommandNames();
	for (NSNumber *command in scintilla)
	{
		NSString *title = [NSString stringWithFormat:@"%@ › %@", SettingsLabel(@"Scintilla commands"), SettingsLabel(scintilla[command])];
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(assignScintillaShortcut:) keyEquivalent:@""];
		item.tag = command.integerValue;
		NSDictionary *binding = _assigned[EditorShortcutIdentifier(item)];
		if ([binding isKindOfClass:NSDictionary.class])
		{
			if ([binding[@"key"] isKindOfClass:NSString.class])
				item.keyEquivalent = binding[@"key"];
			item.keyEquivalentModifierMask = [binding[@"modifiers"] unsignedIntegerValue];
		}
		commands[title] = item;
	}
	_commands = commands;
	if (!_commands.count)
		return NO;
	NSAlert *dialog = [NSAlert new];
	dialog.messageText = [EditorResources.shared label:@"ShortcutMapper:title" fallback:@"Shortcut Mapper"];
	dialog.informativeText = SettingsLabel(@"Enter a key, a key name such as Left, or F1–F20. Leave it empty to remove the shortcut.");
	[dialog addButtonWithTitle:SettingsLabel(@"Apply")];
	[dialog addButtonWithTitle:SettingsLabel(@"Cancel")];
	[dialog addButtonWithTitle:SettingsLabel(@"Restore Default")];
	NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 186)];
	NSSearchField *filter = [[NSSearchField alloc] initWithFrame:NSZeroRect];
	filter.placeholderString = SettingsLabel(@"Filter commands");
	filter.sendsSearchStringImmediately = YES;
	filter.target = self;
	filter.action = @selector(filter:);
	Place(form, filter, 0, 156, 520);
	_choice = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_choice.accessibilityIdentifier = @"shortcut-command";
	[_choice addItemsWithTitles:[_commands.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)]];
	_choice.target = self;
	_choice.action = @selector(choose:);
	Place(form, _choice, 0, 122, 520);
	_bindingPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_bindingPicker.accessibilityIdentifier = @"shortcut-binding";
	_bindingPicker.target = self;
	_bindingPicker.action = @selector(pickBinding:);
	[_bindingPicker setAccessibilityLabel:EditorUIString(@"Assigned shortcuts")];
	Place(form, _bindingPicker, 0, 88, 240);
	EditorResources *resources = EditorResources.shared;
	_addBinding = [NSButton buttonWithTitle:[resources label:@"ShortcutMapperSubDialg:5008" fallback:@"Add"]
		target:self action:@selector(addBinding:)];
	_addBinding.accessibilityIdentifier = @"shortcut-add";
	_removeBinding = [NSButton buttonWithTitle:[resources label:@"ShortcutMapperSubDialg:5009" fallback:@"Remove"]
		target:self action:@selector(removeBinding:)];
	Place(form, _addBinding, 248, 88, 132);
	Place(form, _removeBinding, 388, 88, 132);
	Label(form, @"Shortcut key", 54, 160);
	_key = [NSTextField textFieldWithString:@""];
	_key.accessibilityIdentifier = @"shortcut-key";
	[_key setAccessibilityLabel:SettingsLabel(@"Shortcut key")];
	Place(form, _key, 170, 54, 120);
	NSMutableArray *modifiers = [NSMutableArray array];
	for (NSString *name in @[@"Command", @"Shift", @"Option", @"Control"])
	{
		NSButton *modifier = [NSButton checkboxWithTitle:SettingsLabel(name) target:nil action:nullptr];
		Place(form, modifier, modifiers.count * 130, 14, 124);
		[modifiers addObject:modifier];
	}
	_modifiers = modifiers;
	dialog.accessoryView = form;
	dialog.window.initialFirstResponder = _key;
	[self choose:nil];
	while (true)
	{
		NSModalResponse response = [dialog runModal];
		if (response == NSAlertSecondButtonReturn)
			return NO;
		NSMutableDictionary *shortcuts = [[resources setting:@"shortcuts" fallback:@{}] mutableCopy];
		NSMenuItem *item = _commands[_choice.titleOfSelectedItem ?: @""];
		if (!item)
		{
			NSBeep();
			continue;
		}
		NSString *identifier = EditorShortcutIdentifier(item);
		if (response == NSAlertThirdButtonReturn)
		{
			[shortcuts removeObjectForKey:identifier];
			[resources setSetting:shortcuts forName:@"shortcuts"];
			return YES;
		}
		if (![self storeBinding])
		{
			dialog.informativeText = EditorUIString(@"Enter a single character or a function key from F1 to F20.");
			continue;
		}
		NSMutableOrderedSet<NSDictionary *> *active = [NSMutableOrderedSet orderedSet];
		for (NSDictionary *binding in _bindings)
			if ([binding[@"key"] length])
				[active addObject:binding];
		NSString *conflict = nil;
		for (NSString *name in _commands)
		{
			NSMenuItem *other = _commands[name];
			if ([EditorShortcutIdentifier(other) isEqual:identifier])
				continue;
			for (NSDictionary *binding in ShortcutBindings(other, shortcuts))
			{
				NSDictionary *normalized = @{@"key": [binding[@"key"] lowercaseString], @"modifiers": binding[@"modifiers"]};
				if ([active containsObject:normalized])
					conflict = name;
			}
			if (conflict)
				break;
		}
		if (conflict)
		{
			dialog.informativeText = [NSString stringWithFormat:EditorUIString(@"That shortcut is assigned to %@."), conflict];
			continue;
		}
		NSMutableDictionary *record = [active.firstObject mutableCopy] ?: [@{@"key": @"", @"modifiers": @0} mutableCopy];
		if (active.count > 1)
			record[@"alternatives"] = [active.array subarrayWithRange:NSMakeRange(1, active.count - 1)];
		shortcuts[identifier] = record;
		[resources setSetting:shortcuts forName:@"shortcuts"];
		return YES;
	}
}
@end

BOOL EditorShowShortcutMapper(NSMenu *menu) { return [[ShortcutForm new] edit:menu]; }

static NSString *ChooseLanguage(NSString *title, BOOL creating)
{
	NSArray *names = EditorResources.shared.userLanguages;
	if (!names.count && !creating)
		return nil;
	NSAlert *chooser = [NSAlert new];
	chooser.messageText = title;
	[chooser addButtonWithTitle:SettingsLabel(@"Continue")];
	[chooser addButtonWithTitle:SettingsLabel(@"Cancel")];
	NSPopUpButton *languages = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 286, 29) pullsDown:NO];
	if (creating)
		[languages addItemWithTitle:SettingsLabel(@"Create New Language…")];
	[languages addItemsWithTitles:names];
	chooser.accessoryView = languages;
	if ([chooser runModal] != NSAlertFirstButtonReturn)
		return nil;
	return creating && languages.indexOfSelectedItem == 0 ? @"" : languages.titleOfSelectedItem;
}

static NSString *UDLString(const char *value)
{
	return [NSString stringWithUTF8String:value] ?: @"";
}

static pugi::xml_node UDLChild(pugi::xml_node node, const char *name)
{
	auto child = node.child(name);
	return child ? child : node.append_child(name);
}

static pugi::xml_attribute UDLAttribute(pugi::xml_node node, const char *name)
{
	auto attribute = node.attribute(name);
	return attribute ? attribute : node.append_attribute(name);
}

static NSArray<NSString *> *UDLTokens(NSString *value)
{
	static NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"(?:\\(\\([\\s\\S]*?\\)\\)|[^ \\t\\r\\n])+" options:0 error:nullptr];
	NSMutableArray *tokens = [NSMutableArray array];
	for (NSTextCheckingResult *match in [pattern matchesInString:value options:0 range:NSMakeRange(0, value.length)])
		[tokens addObject:[value substringWithRange:match.range]];
	return tokens;
}

static NSArray<NSString *> *UDLTokenGroups(NSString *value, NSUInteger count)
{
	NSMutableArray<NSMutableArray<NSString *> *> *groups = [NSMutableArray arrayWithCapacity:count];
	for (NSUInteger i = 0; i < count; ++i)
		[groups addObject:[NSMutableArray array]];
	for (NSString *token in UDLTokens(value))
	{
		if (token.length < 3)
			continue;
		NSString *code = [token substringToIndex:2];
		NSUInteger index = code.integerValue;
		if (index < count && [code isEqualToString:[NSString stringWithFormat:@"%02lu", index]])
			[groups[index] addObject:[token substringFromIndex:2]];
	}
	NSMutableArray *result = [NSMutableArray array];
	for (NSArray *group in groups)
		[result addObject:[group componentsJoinedByString:@" "]];
	return result;
}

static constexpr CGFloat UDLFormWidth = 570;
static constexpr CGFloat UDLFormHeight = 356;

@interface EditorUDLForm : NSObject
@property(nonatomic, readonly) NSTabView *view;
- (instancetype)initWithLanguage:(NSString *)name;
- (NSString *)saveCopy:(BOOL)copy asName:(NSString *)name error:(NSError **)error;
@end

@implementation EditorUDLForm
{
	pugi::xml_document _xml;
	NSString *_original;
	std::vector<std::pair<pugi::xml_attribute, NSTextField *>> _attributes;
	std::vector<std::pair<pugi::xml_attribute, NSButton *>> _toggles;
	std::vector<std::pair<pugi::xml_node, NSTextField *>> _values;
	std::vector<std::pair<pugi::xml_node, NSMutableArray<NSTextField *> *>> _tokenGroups;
}

- (instancetype)initWithLanguage:(NSString *)name
{
	self = [super init];
	if (!self)
		return nil;
	_original = [name copy];
	NSString *old = [EditorResources.shared userLanguageXML:name];
	if (old.length && !_xml.load_string(old.UTF8String))
		return nil;
	auto language = UDLChild(UDLChild(_xml, "NotepadPlus"), "UserLang");
	if (!language.attribute("udlVersion"))
		language.append_attribute("udlVersion") = "2.1";
	auto settings = UDLChild(language, "Settings");
	auto global = UDLChild(settings, "Global");
	auto prefix = UDLChild(settings, "Prefix");
	auto lists = UDLChild(language, "KeywordLists");
	auto styles = UDLChild(language, "Styles");
	auto &attributes = _attributes;
	auto &toggles = _toggles;
	auto &values = _values;
	auto &tokenGroups = _tokenGroups;
	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, UDLFormWidth, UDLFormHeight)];
	tabs.allowsTruncatedLabels = NO;
	auto tab = ^NSView *(NSString *title) {
		NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:title];
		item.label = SettingsLabel(title);
		item.view = [[NSView alloc] initWithFrame:tabs.contentRect];
		[tabs addTabViewItem:item];
		return item.view;
	};
	auto field = [](NSView *parent, NSString *title, NSString *text, CGFloat y) {
		NSTextField *input = [NSTextField textFieldWithString:text ?: @""];
		[input setAccessibilityLabel:SettingsLabel(title)];
		Label(parent, title, y, 170);
		Place(parent, input, 180, y, NSWidth(parent.bounds) - 188);
		input.autoresizingMask = NSViewWidthSizable;
		return input;
	};
	auto bind = [&](NSView *parent, NSString *title, pugi::xml_node node, const char *key, CGFloat y) {
		auto value = UDLAttribute(node, key);
		attributes.emplace_back(value, field(parent, title, UDLString(value.value()), y));
	};
	auto toggle = [&](NSView *parent, NSString *title, pugi::xml_node node, const char *key, CGFloat x, CGFloat y) {
		auto value = UDLAttribute(node, key);
		NSButton *box = [NSButton checkboxWithTitle:SettingsLabel(title) target:nil action:nullptr];
		box.state = strcmp(value.value(), "yes") == 0;
		box.toolTip = box.title;
		Place(parent, box, x, y, NSWidth(parent.bounds) - x - 8);
		toggles.emplace_back(value, box);
	};
	auto keywordNode = [&](const char *key) {
		auto entry = lists.find_child_by_attribute("Keywords", "name", key);
		if (!entry)
		{
			entry = lists.append_child("Keywords");
			entry.append_attribute("name") = key;
		}
		return entry;
	};
	auto keyword = [&](NSView *parent, NSString *title, const char *key, CGFloat y) {
		auto entry = keywordNode(key);
		NSTextField *input = field(parent, title, UDLString(entry.child_value()), y);
		values.emplace_back(entry, input);
		return input;
	};
	auto groups = [&](const char *key, NSUInteger count) {
		auto node = keywordNode(key);
		NSMutableArray<NSTextField *> *fields = [NSMutableArray arrayWithCapacity:count];
		tokenGroups.emplace_back(node, fields);
		return UDLTokenGroups(UDLString(node.child_value()), count);
	};
	NSView *general = tab(@"General");
	bind(general, @"Name", language, "name", 263);
	bind(general, @"File extensions", language, "ext", 231);
	toggle(general, @"Ignore case", global, "caseIgnored", 0, 199);
	toggle(general, @"Fold comments", global, "allowFoldOfComments", 0, 167);
	toggle(general, @"Compact folding", global, "foldCompact", 0, 135);
	bind(general, @"Line comment position", global, "forcePureLC", 98);
	bind(general, @"Decimal separator", global, "decimalSeparator", 66);
	NSView *keywords = tab(@"Keywords");
	for (int index = 1; index <= 8; ++index)
	{
		NSString *key = [NSString stringWithFormat:@"Keywords%d", index];
		const CGFloat y = 275 - (index - 1) * 34;
		NSTextField *input = keyword(keywords, [NSString stringWithFormat:SettingsLabel(@"Keyword group %d"), index], key.UTF8String, y);
		input.frame = NSMakeRect(180, y, 234, 24);
		input.autoresizingMask = NSViewNotSizable;
		toggle(keywords, @"Prefix", prefix, key.UTF8String, 422, y);
	}
	NSView *comments = tab(@"Comments");
	NSArray *commentFields = @[@"Line start", @"Line continuation", @"Line end", @"Block start", @"Block end"];
	NSArray *commentValues = groups("Comments", commentFields.count);
	for (NSUInteger i = 0; i < commentFields.count; ++i)
		[tokenGroups.back().second addObject:field(comments, commentFields[i], commentValues[i], 275 - i * 35)];
	NSView *numbers = tab(@"Numbers");
	NSArray *numberFields = @[@"prefix1", @"prefix2", @"extras1", @"extras2", @"suffix1", @"suffix2", @"range"];
	const char *legacy[] = {nullptr, "Numbers, prefixes", nullptr, "Numbers, extras with prefixes", nullptr,
		"Numbers, suffixes", "Numbers, additional"};
	for (NSUInteger index = 0; index < numberFields.count; ++index)
	{
		NSString *key = [@"Numbers, " stringByAppendingString:numberFields[index]];
		NSTextField *input = keyword(numbers, key, key.UTF8String, 275 - index * 34);
		if (!input.stringValue.length && legacy[index])
			input.stringValue = UDLString(lists.find_child_by_attribute("Keywords", "name", legacy[index]).child_value());
	}
	NSView *operators = tab(@"Operators");
	keyword(operators, @"Operators 1", "Operators1", 273);
	keyword(operators, @"Operators 2", "Operators2", 235);
	NSView *delimiters = tab(@"Delimiters");
	NSArray *delimValues = groups("Delimiters", 24);
	NSArray *delimTitles = @[@"Start", @"Escape", @"End"];
	for (NSUInteger column = 0; column < delimTitles.count; ++column)
		Place(delimiters, [NSTextField labelWithString:SettingsLabel(delimTitles[column])], 34 + column * 165, 272, 155);
	for (NSUInteger delimiter = 0; delimiter < 8; ++delimiter)
	{
		CGFloat y = 240 - delimiter * 30;
		Place(delimiters, [NSTextField labelWithString:[@(delimiter + 1) stringValue]], 0, y, 30);
		for (NSUInteger column = 0; column < delimTitles.count; ++column)
		{
			NSTextField *input = [NSTextField textFieldWithString:delimValues[delimiter * 3 + column]];
			[input setAccessibilityLabel:[NSString stringWithFormat:@"%lu %@", delimiter + 1, SettingsLabel(delimTitles[column])]];
			Place(delimiters, input, 34 + column * 165, y, 155);
			[tokenGroups.back().second addObject:input];
		}
	}
	NSView *folding = tab(@"Folding");
	NSUInteger row = 0;
	for (NSString *group in @[@"Folders in code1", @"Folders in code2", @"Folders in comment"])
		for (NSString *side in @[@"open", @"middle", @"close"])
		{
			NSString *key = [NSString stringWithFormat:@"%@, %@", group, side];
			keyword(folding, key, key.UTF8String, 276 - row++ * 29);
		}
	NSView *styling = tab(@"Styles");
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:styling.bounds];
	scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	scroll.hasVerticalScroller = YES;
	NSArray *styleNames = @[@"DEFAULT", @"COMMENTS", @"LINE COMMENTS", @"NUMBERS", @"KEYWORDS1", @"KEYWORDS2",
		@"KEYWORDS3", @"KEYWORDS4", @"KEYWORDS5", @"KEYWORDS6", @"KEYWORDS7", @"KEYWORDS8", @"OPERATORS",
		@"FOLDER IN CODE1", @"FOLDER IN CODE2", @"FOLDER IN COMMENT", @"DELIMITERS1", @"DELIMITERS2", @"DELIMITERS3",
		@"DELIMITERS4", @"DELIMITERS5", @"DELIMITERS6", @"DELIMITERS7", @"DELIMITERS8"];
	NSView *styleRows = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, styleNames.count * 31 + 42)];
	scroll.documentView = styleRows;
	[styling addSubview:scroll];
	NSArray *styleKeys = @[@"fgColor", @"bgColor", @"fontName", @"fontSize", @"fontStyle", @"nesting"];
	NSArray *styleTitles = @[@"Foreground", @"Background", @"Font", @"Size", @"Flags", @"Nesting"];
	CGFloat widths[] = {65, 65, 86, 42, 42, 63};
	CGFloat headerX = 135;
	for (NSUInteger column = 0; column < styleKeys.count; ++column)
	{
		Place(styleRows, [NSTextField labelWithString:SettingsLabel(styleTitles[column])], headerX, NSHeight(styleRows.frame) - 30, widths[column]);
		headerX += widths[column] + 3;
	}
	for (NSUInteger index = 0; index < styleNames.count; ++index)
	{
		NSString *style = styleNames[index];
		auto node = styles.find_child_by_attribute("WordsStyle", "name", style.UTF8String);
		if (!node)
		{
			node = styles.append_child("WordsStyle");
			node.append_attribute("name") = style.UTF8String;
			node.append_attribute("styleID") = static_cast<unsigned>(index);
		}
		CGFloat y = NSHeight(styleRows.frame) - 61 - index * 31;
		Place(styleRows, [NSTextField labelWithString:style], 0, y, 134);
		CGFloat x = 135;
		for (NSUInteger column = 0; column < styleKeys.count; ++column)
		{
			auto value = UDLAttribute(node, [styleKeys[column] UTF8String]);
			NSTextField *input = [NSTextField textFieldWithString:UDLString(value.value())];
			[input setAccessibilityLabel:[NSString stringWithFormat:@"%@ %@", style, SettingsLabel(styleTitles[column])]];
			Place(styleRows, input, x, y, widths[column]);
			x += widths[column] + 3;
			attributes.emplace_back(value, input);
		}
	}
	[scroll.contentView scrollToPoint:NSMakePoint(0, NSHeight(styleRows.frame) - NSHeight(scroll.contentView.bounds))];
	[scroll reflectScrolledClipView:scroll.contentView];
	CGFloat labelWidth = 32;
	for (NSTabViewItem *item in tabs.tabViewItems)
		labelWidth += ceil([item sizeOfLabel:NO].width) + 24;
	[tabs setFrameSize:NSMakeSize(MAX(UDLFormWidth, labelWidth), UDLFormHeight)];
	_view = tabs;
	return self;
}

- (NSString *)saveCopy:(BOOL)copy asName:(NSString *)name error:(NSError **)error
{
	auto &attributes = _attributes;
	auto &toggles = _toggles;
	auto &values = _values;
	auto &tokenGroups = _tokenGroups;
	for (auto &[attribute, input] : attributes)
		attribute = input.stringValue.UTF8String;
	for (auto &[attribute, box] : toggles)
		attribute = box.state == NSControlStateValueOn ? "yes" : "no";
	for (auto &[node, input] : values)
		node.text().set(input.stringValue.UTF8String);
	for (auto &[node, fields] : tokenGroups)
	{
		NSArray *previous = UDLTokenGroups(UDLString(node.child_value()), fields.count);
		if ([previous isEqualToArray:[fields valueForKey:@"stringValue"]])
			continue;
		NSMutableArray *packed = [NSMutableArray array];
		for (NSUInteger i = 0; i < fields.count; ++i)
		{
			NSArray *tokens = UDLTokens(fields[i].stringValue);
			for (NSString *token in tokens.count ? tokens : @[@""])
				[packed addObject:[NSString stringWithFormat:@"%02lu%@", i, token]];
		}
		node.text().set([packed componentsJoinedByString:@" "].UTF8String);
	}
	auto nameAttribute = _xml.child("NotepadPlus").child("UserLang").attribute("name");
	NSString *result = name ?: [UDLString(nameAttribute.value()) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	nameAttribute = result.UTF8String;
	std::ostringstream output;
	_xml.save(output);
	if (![EditorResources.shared saveUserLanguageXML:UDLString(output.str().c_str()) replacing:copy || !_original.length ? nil : _original error:error])
		return nil;
	_original = result;
	return result;
}
@end

static NSString *NewUDLName(void)
{
	NSAlert *prompt = [NSAlert new];
	prompt.messageText = EditorUIString(@"Save User Defined Language As");
	[prompt addButtonWithTitle:EditorUIString(@"Save")];
	[prompt addButtonWithTitle:EditorUIString(@"Cancel")];
	NSTextField *input = [NSTextField textFieldWithString:@""];
	input.frame = NSMakeRect(0, 0, 320, 24);
	prompt.accessoryView = input;
	prompt.window.initialFirstResponder = input;
	if ([prompt runModal] != NSAlertFirstButtonReturn)
		return nil;
	return [input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

BOOL EditorShowUserLanguageEditor(void)
{
	NSString *name = ChooseLanguage(SettingsLabel(@"User Defined Language"), YES);
	if (!name)
		return NO;
	EditorUDLForm *form = [[EditorUDLForm alloc] initWithLanguage:name];
	if (!form)
		return NO;
	NSAlert *dialog = [NSAlert new];
	dialog.messageText = SettingsLabel(@"User Defined Language");
	dialog.informativeText = SettingsLabel(@"Edit the language definition. Changes are saved in the profile.");
	[dialog addButtonWithTitle:SettingsLabel(@"Save")];
	[dialog addButtonWithTitle:SettingsLabel(@"Cancel")];
	[dialog addButtonWithTitle:EditorUIString(@"Save As…")];
	dialog.accessoryView = form.view;
	for (;;)
	{
		NSModalResponse response = [dialog runModal];
		if (response == NSAlertSecondButtonReturn)
			return NO;
		BOOL copy = response == NSAlertThirdButtonReturn;
		NSString *destination = copy ? NewUDLName() : nil;
		if (copy && !destination)
			continue;
		NSError *error = nil;
		if ([form saveCopy:copy asName:destination error:&error])
			return YES;
		dialog.informativeText = error.localizedDescription ?: SettingsLabel(@"The language could not be saved.");
	}
}

static BOOL RemoveUDL(NSString *name)
{
	if (!name.length)
		return NO;
	NSAlert *confirmation = [NSAlert new];
	confirmation.messageText = [NSString stringWithFormat:EditorUIString(@"Remove the language “%@”?"), name];
	[confirmation addButtonWithTitle:EditorUIString(@"Cancel")];
	[confirmation addButtonWithTitle:EditorUIString(@"Remove")];
	if ([confirmation runModal] != NSAlertSecondButtonReturn)
		return NO;
	NSError *error = nil;
	BOOL removed = [EditorResources.shared removeUserLanguage:name error:&error];
	if (error)
		[NSApp presentError:error];
	return removed;
}

BOOL EditorRemoveUserLanguage(void)
{
	return RemoveUDL(ChooseLanguage(EditorUIString(@"Remove User Defined Language"), NO));
}

@interface EditorUDLPanel : NSScrollView
- (instancetype)initWithChanges:(void (^)(void))changes;
@end

@implementation EditorUDLPanel
{
	NSPopUpButton *_languages;
	EditorUDLForm *_form;
	void (^_changes)(void);
	BOOL _positionedAtTop;
}

- (void)refreshSelection:(NSString *)selection
{
	[_languages removeAllItems];
	[_languages addItemWithTitle:EditorUIString(@"Create New Language…")];
	_languages.lastItem.representedObject = @"";
	for (NSString *name in EditorResources.shared.userLanguages)
	{
		[_languages addItemWithTitle:name];
		_languages.lastItem.representedObject = name;
		if ([name isEqualToString:selection])
			[_languages selectItem:_languages.lastItem];
	}
}

- (void)selectLanguage:(id)sender
{
	[_form.view removeFromSuperview];
	_form = [[EditorUDLForm alloc] initWithLanguage:_languages.selectedItem.representedObject];
	if (_form)
	{
		CGFloat width = NSWidth(_form.view.frame);
		[self.documentView setFrameSize:NSMakeSize(width + 20, UDLFormHeight + 44)];
		Place(self.documentView, _form.view, 8, 4, width, UDLFormHeight);
	}
}

- (void)layout
{
	[super layout];
	CGFloat visibleHeight = NSHeight(self.contentView.bounds);
	if (!_positionedAtTop && visibleHeight > 0)
	{
		_positionedAtTop = YES;
		[self.contentView scrollToPoint:NSMakePoint(0, MAX(0, NSHeight(self.documentView.frame) - visibleHeight))];
		[self reflectScrolledClipView:self.contentView];
	}
}

- (instancetype)initWithChanges:(void (^)(void))changes
{
	self = [super initWithFrame:NSZeroRect];
	if (!self)
		return nil;
	_changes = [changes copy];
	self.hasHorizontalScroller = YES;
	self.hasVerticalScroller = YES;
	self.documentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, UDLFormWidth + 20, UDLFormHeight + 44)];
	_languages = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_languages.target = self;
	_languages.action = @selector(selectLanguage:);
	Place(self.documentView, _languages, 8, UDLFormHeight + 11, 239);
	NSArray *titles = @[@"Save", @"Save As…", @"Remove"];
	for (NSUInteger i = 0; i < titles.count; ++i)
	{
		NSButton *button = [NSButton buttonWithTitle:EditorUIString(titles[i]) target:self action:@selector(edit:)];
		button.tag = i;
		Place(self.documentView, button, 251 + i * 109, UDLFormHeight + 11, 106);
	}
	[self refreshSelection:nil];
	[self selectLanguage:nil];
	return self;
}

- (void)edit:(NSButton *)button
{
	if (button.tag == 2)
	{
		if (!RemoveUDL(_languages.selectedItem.representedObject))
			return;
		[self refreshSelection:nil];
	}
	else
	{
		BOOL copy = button.tag == 1;
		NSString *name = copy ? NewUDLName() : nil;
		if (copy && !name)
			return;
		NSError *error = nil;
		NSString *saved = [_form saveCopy:copy asName:name error:&error];
		if (!saved)
		{
			if (error)
				[NSApp presentError:error];
			return;
		}
		[self refreshSelection:saved];
	}
	[self selectLanguage:nil];
	if (_changes)
		_changes();
}
@end

NSView *EditorCreateUDLPanel(void (^changes)(void)) { return [[EditorUDLPanel alloc] initWithChanges:changes]; }

void EditorExportUserLanguage(void)
{
	NSString *name = ChooseLanguage(SettingsLabel(@"Export User Defined Language"), NO);
	if (!name)
		return;
	NSSavePanel *panel = NSSavePanel.savePanel;
	panel.nameFieldStringValue = [name stringByAppendingPathExtension:@"xml"];
	if ([panel runModal] != NSModalResponseOK)
		return;
	NSError *error = nil;
	if (![[EditorResources.shared userLanguageXML:name] writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error] && error)
		[NSApp presentError:error];
}

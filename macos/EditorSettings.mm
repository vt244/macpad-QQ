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

static void Label(NSView *view, NSString *name, CGFloat y)
{
	Place(view, [NSTextField labelWithString:SettingsLabel(name)], 0, y, 154);
}

@interface PreferenceSectionPicker : NSObject
@property(nonatomic, weak) NSTabView *tabs;
@end

@implementation PreferenceSectionPicker
- (void)select:(NSPopUpButton *)sender
{
	[self.tabs selectTabViewItemAtIndex:sender.indexOfSelectedItem];
}
@end

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
	tabs.tabViewType = NSNoTabsNoBorder;
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
		const BOOL searchLimit = [name isEqual:@"inSelectionAutocheckThreshold"] || [name isEqual:@"fillFindWhatThreshold"];
		NSTextField *caption = searchLimit ? [NSTextField wrappingLabelWithString:label] : [NSTextField labelWithString:label];
		Place(view, caption, 12, searchLimit ? y - 10 : y, 220, searchLimit ? 44 : 24);
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
		@[@"virtualSpace", @"Allow the caret beyond the end of a line", @NO], @[@"multipleSelections", @"Enable multiple selections", @YES],
		@[@"autocomplete", @"Offer completions while typing", @YES], @[@"autoPairs", @"Insert matching delimiters and closing tags", @YES]], 220);
	field(editor, @"dateTimeFormat", @"Custom date and time format", @"yyyy-MM-dd HH:mm:ss", 82);
	field(editor, @"tabWidth", @"Tab width", @"4", 52);
	field(editor, @"autocompleteMinimum", @"Characters before completion", @"2", 22);

	NSView *display = tab(@"pref-display", @"Display");
	checks(display, @[@[@"wordWrap", @"Wrap long lines", @NO], @[@"lineNumbers", @"Show line numbers", @YES],
		@[@"bookmarkMargin", @"Show bookmark margin", @YES], @[@"indentGuide", @"Show indentation guides", @NO],
		@[@"whitespace", @"Show spaces and tabs", @NO], @[@"showEOL", @"Show end-of-line characters", @NO],
		@[@"showWrapSymbol", @"Show wrap symbols", @NO], @[@"scrollBeyondLastLine", @"Scroll beyond the last line", @NO]], 220);
	choice(display, @"toolbarStyle", @"Toolbar icons", @[@"Regular (small)", @"Regular (large)", @"Filled (small)", @"Filled (large)", @"Classic"], 0, 18);
	checks(display, @[@[@"selectedTextForeground", @"Use the theme’s selected text color", @NO]], 50);
	NSView *guides = tab(@"pref-guides", @"Editor guides");
	choice(guides, @"currentLineMode", @"Current line", @[@"Off", @"Highlight", @"Outline"], 0, 232);
	field(guides, @"currentLineFrameWidth", @"Outline width", @"1", 194);
	choice(guides, @"wrapIndent", @"Wrapped line indent", @[@"Default", @"Aligned", @"Indented"], 0, 156);
	field(guides, @"edgeColumns", @"Vertical ruler columns", @"", 118);
	checks(guides, @[@[@"edgeBackground", @"Shade beyond a single ruler", @NO]], 78);
	choice(guides, @"eolRepresentation", @"End-of-line markers", @[@"Plain text", @"Boxed", @"Plain text with theme color",
		@"Boxed with theme color"], 1, 39);
	NSView *styleOverride = tab(@"pref-styleOverride", @"Global style override");
	checks(styleOverride, @[@[@"styleOverrideForeground", @"Force foreground color for all styles", @NO],
		@[@"styleOverrideBackground", @"Force background color for all styles", @NO],
		@[@"styleOverrideFont", @"Force font choice for all styles", @NO],
		@[@"styleOverrideSize", @"Force font size choice for all styles", @NO],
		@[@"styleOverrideBold", @"Force bold choice for all styles", @NO],
		@[@"styleOverrideItalic", @"Force italic choice for all styles", @NO],
		@[@"styleOverrideUnderline", @"Force underline choice for all styles", @NO]], 248);

	NSView *files = tab(@"pref-files", @"Files and tabs");
	checks(files, @[@[@"saveAllConfirm", @"Confirm Save All", @YES],
		@[@"detectEncoding", @"Automatically detect legacy encodings", @YES]], 278);
	checks(files, @[@[@"autoReload", @"Reload unchanged buffers automatically", @NO],
		@[@"reloadToEnd", @"Go to the end after reloading", @NO], @[@"hideToolbar", @"Hide the toolbar", @NO],
		@[@"hideTabBar", @"Hide the tab bar", @NO], @[@"tabCloseButtons", @"Show close buttons on tabs", @YES],
		@[@"doubleClickClosesTab", @"Double-click a tab to close it", @NO], @[@"hideStatusBar", @"Hide the status bar", @NO]], 230);
	choice(files, @"fileStatusMode", @"File change detection", @[@"Disabled", @"Active document", @"All open documents"], 1, 63);
	choice(files, @"newDocumentEOL", @"New document line ending", @[@"Windows (CRLF)", @"Classic Mac (CR)", @"Unix (LF)"], 0, 35);
	choice(files, @"newDocumentEncoding", @"New document encoding", @[@"Windows-1252", @"UTF-8 with BOM",
		@"UTF-16 BE with BOM", @"UTF-16 LE with BOM", @"UTF-8", @"ASCII", @"UTF-16 BE", @"UTF-16 LE"], 4, 7);

	NSView *tabOptions = tab(@"pref-tabs", @"Tabs");
	checks(tabOptions, @[@[@"mruTabSwitcher", @"Switch recent documents with Control-Tab", @YES],
		@[@"tabPreview", @"Preview an inactive tab on hover", @NO], @[@"verticalTabs", @"Show tabs on the left", @NO],
		@[@"multilineTabs", @"Wrap tabs to multiple rows", @NO], @[@"lockTabs", @"Prevent dragging tabs", @NO]], 220);
	field(tabOptions, @"caretWidth", @"Caret width", @"1", 78);
	field(tabOptions, @"caretBlink", @"Caret blink period (ms)", @"500", 44);

	NSView *large = tab(@"pref-largeFiles", @"Large files");
	checks(large, @[@[@"limitLargeFiles", @"Skip syntax highlighting for large files", @NO],
		@[@"largeFileCompletion", @"Allow automatic completion", @NO],
		@[@"largeFileBraceMatch", @"Allow matching brace commands", @NO],
		@[@"largeFileDisableWrap", @"Disable word wrap for large files", @NO]], 220);
	field(large, @"largeFileMegabytes", @"Large file threshold (MiB)", @"200", 107);

	NSView *search = tab(@"pref-search", @"Searching");
	checks(search, @[@[@"fillFindSelection", @"Use selected text when opening Find", @YES],
		@[@"fillFindWord", @"Use the word under the caret if there is no selection", @NO],
		@[@"findFilesOnDisk", @"Search files on disk even if a buffer has unsaved edits", @NO],
		@[@"monospacedFontFindDlg", @"Use a monospaced font in Find", @NO]], 248);
	field(search, @"inSelectionAutocheckThreshold", @"Auto-select search scope from (chars)", @"1024", 132);
	field(search, @"fillFindWhatThreshold", @"Max characters to fill Find", @"1024", 83);
	NSTextField *selectionHint = [NSTextField wrappingLabelWithString:localized(@"pref-inSelectionHint",
		@"Set the selection threshold to 0 to keep manual control of “In selection”.")];
	Place(search, selectionHint, 12, 24, 472, 40);

	NSView *backup = tab(@"pref-backup", @"Backup and sessions");
	checks(backup, @[@[@"rememberSession", @"Restore the last session on startup", @YES],
		@[@"checkpointDrafts", @"Periodically save unsaved edits for recovery", @YES]], 220);
	choice(backup, @"instanceMode", @"Open files in", @[@"Current instance", @"New instance for sessions", @"New instance for every file"], 0, 159);
	choice(backup, @"backupMode", @"Keep a backup of saved files", @[@"None", @"One .bak copy", @"Keep dated copies"], 0, 123);
	field(backup, @"backupDirectory", @"Backup folder (optional)", @"", 87);
	field(backup, @"checkpointMilliseconds", @"Recovery interval (ms)", @"1000", 51);

	NSView *printing = tab(@"pref-print", @"Printing");
	choice(printing, @"printColorMode", @"Color mode", @[@"Editor colors", @"Invert colors", @"Black on white", @"Colors without background"], SC_PRINT_BLACKONWHITE, 242);
	checks(printing, @[@[@"printLineNumbers", @"Print line numbers", @NO]], 216);
	NSArray *directions = @[@"Left", @"Middle", @"Right"];
	NSArray *headerTitles = @[@"Left header", @"Center header", @"Right header"];
	NSArray *footerTitles = @[@"Left footer", @"Center footer", @"Right footer"];
	for (NSUInteger i = 0; i < directions.count; ++i)
	{
		field(printing, [@"printHeader" stringByAppendingString:directions[i]], headerTitles[i], @"", 190 - i * 24);
		field(printing, [@"printFooter" stringByAppendingString:directions[i]], footerTitles[i], @"", 118 - i * 24);
	}
	field(printing, @"printMargins", @"Margins in mm (left, top, right, bottom)",
		[NSString stringWithFormat:@"%@, %@, %@, %@", [resources setting:@"printMarginLeft" fallback:@18],
			[resources setting:@"printMarginTop" fallback:@18], [resources setting:@"printMarginRight" fallback:@18],
			[resources setting:@"printMarginBottom" fallback:@18]], 22);
	NSView *printLayout = tab(@"pref-print-layout", @"Print layout");
	checks(printLayout, @[@[@"printFormFeedBreak", @"Print form feed as a page break", @NO]], 236);
	field(printLayout, @"printHeaderFontName", @"Header font", @"", 194);
	field(printLayout, @"printHeaderFontSize", @"Header font size", @"9", 162);
	field(printLayout, @"printFooterFontName", @"Footer font", @"", 114);
	field(printLayout, @"printFooterFontSize", @"Footer font size", @"9", 82);

	NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 350)];
	[accessory addSubview:tabs];
	NSPopUpButton *sections = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	[sections addItemsWithTitles:[tabs.tabViewItems valueForKey:@"label"]];
	[sections setAccessibilityLabel:localized(@"pref-category", @"Preferences category")];
	__attribute__((objc_precise_lifetime)) PreferenceSectionPicker *picker = [PreferenceSectionPicker new];
	picker.tabs = tabs;
	sections.target = picker;
	sections.action = @selector(select:);
	Place(accessory, sections, 12, 316, 290, 26);
	window.accessoryView = accessory;
	if ([window runModal] != NSAlertFirstButtonReturn)
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
	NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 240)];
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
	Label(form, @"Language", 212);
	Place(form, _language, 152, 212, 245);
	Label(form, @"Style", 179);
	Place(form, _style, 152, 179, 245);
	_foreground = [[NSColorWell alloc] initWithFrame:NSZeroRect];
	_background = [[NSColorWell alloc] initWithFrame:NSZeroRect];
	_useForeground = [NSButton checkboxWithTitle:SettingsLabel(@"Use foreground color") target:nil action:nullptr];
	_useBackground = [NSButton checkboxWithTitle:SettingsLabel(@"Use background color") target:nil action:nullptr];
	Place(form, _useForeground, 0, 144, 230);
	Place(form, _foreground, 240, 144, 72);
	Place(form, _useBackground, 0, 111, 230);
	Place(form, _background, 240, 111, 72);
	_font = [NSTextField textFieldWithString:@""];
	_font.placeholderString = SettingsLabel(@"Inherit");
	_size = [NSTextField textFieldWithString:@""];
	_size.placeholderString = SettingsLabel(@"Inherit");
	Label(form, @"Font family", 77);
	Place(form, _font, 152, 77, 245);
	Label(form, @"Font size", 43);
	Place(form, _size, 152, 43, 85);
	_bold = [NSButton checkboxWithTitle:[resources label:@"StyleConfig:2204" fallback:@"Bold"] target:nil action:nullptr];
	_italic = [NSButton checkboxWithTitle:[resources label:@"StyleConfig:2205" fallback:@"Italic"] target:nil action:nullptr];
	_underline = [NSButton checkboxWithTitle:[resources label:@"StyleConfig:2218" fallback:@"Underline"] target:nil action:nullptr];
	Place(form, _bold, 0, 8, 87);
	Place(form, _italic, 92, 8, 87);
	Place(form, _underline, 184, 8, 115);
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
	NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 443, 186)];
	NSSearchField *filter = [[NSSearchField alloc] initWithFrame:NSZeroRect];
	filter.placeholderString = SettingsLabel(@"Filter commands");
	filter.sendsSearchStringImmediately = YES;
	filter.target = self;
	filter.action = @selector(filter:);
	Place(form, filter, 0, 156, 440);
	_choice = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_choice.accessibilityIdentifier = @"shortcut-command";
	[_choice addItemsWithTitles:[_commands.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)]];
	_choice.target = self;
	_choice.action = @selector(choose:);
	Place(form, _choice, 0, 122, 440);
	_bindingPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_bindingPicker.accessibilityIdentifier = @"shortcut-binding";
	_bindingPicker.target = self;
	_bindingPicker.action = @selector(pickBinding:);
	[_bindingPicker setAccessibilityLabel:EditorUIString(@"Assigned shortcuts")];
	Place(form, _bindingPicker, 0, 88, 210);
	EditorResources *resources = EditorResources.shared;
	_addBinding = [NSButton buttonWithTitle:[resources label:@"ShortcutMapperSubDialg:5008" fallback:@"Add"]
		target:self action:@selector(addBinding:)];
	_addBinding.accessibilityIdentifier = @"shortcut-add";
	_removeBinding = [NSButton buttonWithTitle:[resources label:@"ShortcutMapperSubDialg:5009" fallback:@"Remove"]
		target:self action:@selector(removeBinding:)];
	Place(form, _addBinding, 218, 88, 106);
	Place(form, _removeBinding, 332, 88, 108);
	Label(form, @"Shortcut key", 54);
	_key = [NSTextField textFieldWithString:@""];
	_key.accessibilityIdentifier = @"shortcut-key";
	Place(form, _key, 150, 54, 100);
	NSMutableArray *modifiers = [NSMutableArray array];
	for (NSString *name in @[@"Command", @"Shift", @"Option", @"Control"])
	{
		NSButton *modifier = [NSButton checkboxWithTitle:SettingsLabel(name) target:nil action:nullptr];
		Place(form, modifier, modifiers.count * 110, 14, 105);
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
	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 570, 333)];
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
		Label(parent, title, y);
		Place(parent, input, 159, y, 370);
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
		Place(parent, box, x, y, 160);
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
		input.frame = NSMakeRect(159, y, 255, 24);
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
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 546, 300)];
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
		Place(self.documentView, _form.view, 8, 4, 570, 333);
}

- (instancetype)initWithChanges:(void (^)(void))changes
{
	self = [super initWithFrame:NSZeroRect];
	if (!self)
		return nil;
	_changes = [changes copy];
	self.hasHorizontalScroller = YES;
	self.hasVerticalScroller = YES;
	self.documentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 590, 377)];
	_languages = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_languages.target = self;
	_languages.action = @selector(selectLanguage:);
	Place(self.documentView, _languages, 8, 344, 239);
	NSArray *titles = @[@"Save", @"Save As…", @"Remove"];
	for (NSUInteger i = 0; i < titles.count; ++i)
	{
		NSButton *button = [NSButton buttonWithTitle:EditorUIString(titles[i]) target:self action:@selector(edit:)];
		button.tag = i;
		Place(self.documentView, button, 251 + i * 109, 344, 106);
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

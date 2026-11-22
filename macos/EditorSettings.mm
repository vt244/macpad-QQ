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
		@[@"largeFileCompletion", @"Allow automatic completion", @NO],
		@[@"largeFileBraceMatch", @"Allow matching brace commands", @NO],
		@[@"largeFileDisableWrap", @"Disable word wrap for large files", @NO]], 220);
	field(large, @"largeFileMegabytes", @"Large file threshold (MiB)", @"200", 107);

	NSView *search = tab(@"pref-search", @"Searching");
	checks(search, @[@[@"fillFindSelection", @"Use selected text when opening Find", @YES],
		@[@"fillFindWord", @"Use the word under the caret if there is no selection", @NO],
		@[@"findFilesOnDisk", @"Search files on disk even if a buffer has unsaved edits", @NO]], 220);

	NSView *backup = tab(@"pref-backup", @"Backup and sessions");
	checks(backup, @[@[@"rememberSession", @"Restore the last session on startup", @YES],
		@[@"checkpointDrafts", @"Periodically save unsaved edits for recovery", @YES]], 220);
	choice(backup, @"instanceMode", @"Open files in", @[@"Current instance", @"New instance for sessions", @"New instance for every file"], 0, 159);
	choice(backup, @"backupMode", @"Keep a backup of saved files", @[@"None", @"One .bak copy", @"Keep dated copies"], 0, 123);
	field(backup, @"backupDirectory", @"Backup folder (optional)", @"", 87);
	field(backup, @"checkpointMilliseconds", @"Recovery interval (ms)", @"1000", 51);

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

BOOL EditorShowUserLanguageEditor(void)
{
	NSString *name = ChooseLanguage(SettingsLabel(@"User Defined Language"), YES);
	if (!name)
		return NO;
	NSString *initial = name.length ? [EditorResources.shared userLanguageXML:name] :
		@"<NotepadPlus>\n\t<UserLang name=\"My language\" ext=\"\" udlVersion=\"2.1\">\n"
		"\t\t<Settings><Global caseIgnored=\"no\" allowFoldOfComments=\"no\" foldCompact=\"no\"/></Settings>\n"
		"\t\t<KeywordLists>\n\t\t\t<Keywords name=\"Comments\">00# 01 02 03 04</Keywords>\n"
		"\t\t\t<Keywords name=\"Keywords1\"></Keywords>\n\t\t</KeywordLists>\n"
		"\t\t<Styles><WordsStyle name=\"KEYWORDS1\" styleID=\"4\" fgColor=\"000080\" fontStyle=\"1\"/></Styles>\n"
		"\t</UserLang>\n</NotepadPlus>\n";
	NSAlert *dialog = [NSAlert new];
	dialog.messageText = name.length ? name : SettingsLabel(@"New User Defined Language");
	dialog.informativeText = SettingsLabel(@"Edit the language name, extensions, keywords, comments and styles in the UDL XML definition.");
	[dialog addButtonWithTitle:SettingsLabel(@"Save")];
	[dialog addButtonWithTitle:SettingsLabel(@"Cancel")];
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 360)];
	scroll.hasVerticalScroller = YES;
	scroll.borderType = NSBezelBorder;
	NSTextView *text = [[NSTextView alloc] initWithFrame:scroll.bounds];
	text.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
	text.richText = NO;
	text.automaticQuoteSubstitutionEnabled = NO;
	text.automaticDashSubstitutionEnabled = NO;
	text.string = initial ?: @"";
	text.verticallyResizable = YES;
	text.autoresizingMask = NSViewWidthSizable;
	scroll.documentView = text;
	dialog.accessoryView = scroll;
	dialog.window.initialFirstResponder = text;
	while ([dialog runModal] == NSAlertFirstButtonReturn)
	{
		NSError *error = nil;
		if ([EditorResources.shared saveUserLanguageXML:text.string replacing:name.length ? name : nil error:&error])
			return YES;
		dialog.informativeText = error.localizedDescription ?: SettingsLabel(@"The language could not be saved.");
	}
	return NO;
}

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

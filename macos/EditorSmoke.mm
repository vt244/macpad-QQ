// SPDX-License-Identifier: GPL-3.0-only
#import "EditorDocument.h"
#import "EditorChrome.h"
#import "EditorCompletion.h"
#import "EditorContextMenus.h"
#import "EditorDock.h"
#import "EditorEditActions.h"
#import "EditorDocumentList.h"
#import "EditorDocumentMap.h"
#import "EditorFileSearch.h"
#import "EditorFolderPanel.h"
#import "EditorFunctionList.h"
#import "EditorIncrementalSearch.h"
#import "EditorInsertPanels.h"
#import "EditorLaunchOptions.h"
#import "EditorMacros.h"
#import "EditorPlugins.h"
#import "EditorProjectPanel.h"
#import "EditorResources.h"
#import "EditorSettings.h"
#import "EditorText.h"
#import "EditorWorkspace.h"
#import "ScintillaView.h"

#include "SciLexer.h"
#include "BoostRegexSearch.h"
#include <cstdlib>

static bool Check(bool condition, const char *description)
{
	if (!condition)
		fprintf(stderr, "macpad++ smoke test failed: %s\n", description);
	return condition;
}

static NSView *ViewMatching(NSView *view, BOOL (^match)(NSView *))
{
	if (match(view))
		return view;
	for (NSView *child in view.subviews)
		if (NSView *result = ViewMatching(child, match))
			return result;
	return nil;
}

static bool CheckDocumentDock(EditorDocument *document)
{
	NSWindow *window = document.editor.window;
	NSView *root = window.contentView;
	[document toggleDocumentList:nil];
	[root layoutSubtreeIfNeeded];
	EditorDocumentList *list = (EditorDocumentList *)ViewMatching(root, ^BOOL(NSView *view) {
		return [view isKindOfClass:EditorDocumentList.class];
	});
	EditorDockPane *pane = (EditorDockPane *)list.superview;
	NSView *area = pane.superview;
	if (!Check(pane.isShown && NSWidth(list.frame) >= 190, "lay out the docked document list"))
		return false;
	NSPoint edge = [area convertPoint:NSMakePoint(NSMaxX(area.bounds) - 4, NSMidY(area.bounds)) toView:nil];
	[pane dropAtScreenPoint:[window convertPointToScreen:edge]];
	[root layoutSubtreeIfNeeded];
	if (!Check(NSMaxX(pane.frame) == NSMaxX(area.bounds), "dock a panel when dropped near the right edge"))
		return false;
	NSView *grip = pane.subviews.lastObject;
	CGFloat width = NSWidth(pane.frame);
	auto event = ^NSEvent *(NSEventType type, CGFloat x) {
		return [NSEvent mouseEventWithType:type location:NSMakePoint(x, 100) modifierFlags:0 timestamp:0
			windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
	};
	[grip mouseDown:event(NSEventTypeLeftMouseDown, 200)];
	[grip mouseDragged:event(NSEventTypeLeftMouseDragged, 160)];
	if (!Check(NSWidth(pane.frame) == width + 40, "resize the panel at its divider"))
		return false;
	NSMenuItem *command = [[pane placementMenu] itemWithTag:EditorDockFloating];
	[NSApp sendAction:command.action to:command.target from:command];
	if (!Check(pane.window != window && pane.window.parentWindow == window && list.window == pane.window,
		"float the live panel in a child window"))
		return false;
	command = [[pane placementMenu] itemWithTitle:[EditorResources.shared label:@"dock-redock" fallback:@"Dock Panel"]];
	[NSApp sendAction:command.action to:command.target from:command];
	[root layoutSubtreeIfNeeded];
	if (!Check(pane.window == window && NSMaxX(pane.frame) == NSMaxX(area.bounds) && NSWidth(pane.frame) == width + 40,
		"redock the floating panel at its previous edge and size"))
		return false;
	[document toggleDocumentList:nil];
	return true;
}

static bool CheckFolderWorkspace(EditorDocumentController *controller, EditorDocument *document, NSURL *test)
{
	NSURL *folder = [test URLByAppendingPathComponent:@"workspace-fixture" isDirectory:YES];
	NSURL *nested = [folder URLByAppendingPathComponent:@"nested" isDirectory:YES];
	NSURL *file = [nested URLByAppendingPathComponent:@"example.txt"];
	NSFileManager *files = NSFileManager.defaultManager;
	if (!Check([files createDirectoryAtURL:nested withIntermediateDirectories:YES attributes:nil error:nullptr] &&
		[@"workspace" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nullptr], "create a workspace source tree"))
		return false;
	[controller addWorkspaceFolders:@[folder, folder]];
	NSOutlineView *outline = (NSOutlineView *)ViewMatching(document.editor.window.contentView, ^BOOL(NSView *view) {
		return [view isKindOfClass:NSOutlineView.class] && [[view accessibilityIdentifier] isEqualToString:@"folder-workspace"];
	});
	if (!Check(outline.numberOfRows == 2, "show one workspace root and its nested directory"))
		return false;
	[outline expandItem:[outline itemAtRow:1]];
	if (!Check(outline.numberOfRows == 3 &&
		[[controller captureWorkspace][@"workspaceFolders"] isEqual:@[folder.path]], "expand the workspace tree and save its root"))
		return false;
	[controller toggleFolderWorkspace:nil];
	return true;
}

static bool CheckProjectWorkspace(EditorDocumentController *controller, EditorDocument *document, NSURL *test)
{
	NSURL *input = [test URLByAppendingPathComponent:@"project.xml"];
	NSURL *exported = [test URLByAppendingPathComponent:@"exported-project.xml"];
	NSString *xml = @"<NotepadPlus><Project name=\"Example\"><Folder name=\"Sources\">"
		"<File name=\"workspace-fixture\\nested\\example.txt\"/><File name=\"X:\\other.txt\"/>"
		"</Folder></Project></NotepadPlus>";
	EditorProjectWorkspace *workspace = [EditorProjectWorkspace new];
	EditorProjectWorkspace *restored = [EditorProjectWorkspace new];
	if (!Check([xml writeToURL:input atomically:YES encoding:NSUTF8StringEncoding error:nullptr] &&
		[workspace readFromURL:input error:nullptr] && workspace.files.count == 1 &&
		[workspace writeToURL:exported error:nullptr] && [restored readFromURL:exported error:nullptr] &&
		[restored.files isEqualToArray:workspace.files], "round-trip the original project tree format and relative paths"))
		return false;
	[restored restore:workspace.snapshot];
	if (!Check([restored.files isEqualToArray:workspace.files], "recover project documents from the workspace snapshot"))
		return false;
	NSMenuItem *command = [NSMenuItem new];
	command.tag = 1;
	[controller toggleProjectPanel:command];
	NSString *title = [EditorResources.shared label:@"44082" fallback:@"Project Panel 2"];
	NSOutlineView *outline = (NSOutlineView *)ViewMatching(document.editor.window.contentView, ^BOOL(NSView *view) {
		return [view isKindOfClass:NSOutlineView.class] && [[view accessibilityLabel] isEqualToString:title];
	});
	if (!Check(outline && !outline.isHiddenOrHasHiddenAncestor && [controller captureWorkspace][@"projects"] != nil,
		"independently show and capture the second project panel"))
		return false;
	[controller toggleProjectPanel:command];
	return true;
}

static bool CheckFunctionList()
{
	NSString *python = @"# def ignore():\nclass Example:\n    def method(self):\n        pass\n\ndef outside():\n    pass\n";
	NSURL *rules = [NSBundle.mainBundle URLForResource:@"python" withExtension:@"xml" subdirectory:@"functionList"];
	NSArray<EditorFunction *> *symbols = EditorReadFunctions([python dataUsingEncoding:NSUTF8StringEncoding], rules, nil);
	return Check(symbols.count == 2 && [symbols[0].name isEqualToString:@"method(self)"] &&
		[symbols[0].group isEqualToString:@"Example"] && [symbols[1].name isEqualToString:@"outside()"] &&
		symbols[1].bytePosition == [python rangeOfString:@"outside"].location, "parse class methods and free functions using the bundled Python XML");
}

static bool CheckDocumentMap(EditorDocumentController *controller, EditorDocument *document)
{
	ScintillaView *source = controller.focusedDocument.editor;
	[controller toggleDocumentMap:nil];
	EditorDocumentMap *panel = (EditorDocumentMap *)ViewMatching(document.editor.window.contentView, ^BOOL(NSView *view) {
		return [view isKindOfClass:EditorDocumentMap.class];
	});
	ScintillaView *map = (ScintillaView *)ViewMatching(panel, ^BOOL(NSView *view) { return [view isKindOfClass:ScintillaView.class]; });
	if (!Check(map && !map.isHiddenOrHasHiddenAncestor && [map message:SCI_GETDOCPOINTER] == [source message:SCI_GETDOCPOINTER] &&
		[map message:SCI_STYLEGETSIZE wParam:STYLE_DEFAULT] < [source message:SCI_STYLEGETSIZE wParam:STYLE_DEFAULT],
		"preview the same live document in miniature without changing the editor"))
		return false;
	[controller toggleDocumentMap:nil];
	return Check([map message:SCI_GETDOCPOINTER] != [source message:SCI_GETDOCPOINTER], "release the preview buffer on hide");
}

static bool CheckInsertPanels()
{
	__block NSString *inserted = nil;
	EditorClipboardHistory *history = [[EditorClipboardHistory alloc] initWithInsert:^(NSString *text) { inserted = text; } dismiss:^{}];
	[history setEntries:@[@"first line\nsecond line"]];
	EditorCharacterPanel *characters = [[EditorCharacterPanel alloc] initWithInsert:^(NSString *text) { inserted = text; } dismiss:^{}];
	NSEvent *enter = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
		windowNumber:0 context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
	for (NSView *panel in @[history, characters])
	{
		NSTableView *table = (NSTableView *)ViewMatching(panel, ^BOOL(NSView *view) { return [view isKindOfClass:NSTableView.class]; });
		BOOL clipboard = panel == history;
		[table selectRowIndexes:[NSIndexSet indexSetWithIndex:clipboard ? 0 : 65] byExtendingSelection:NO];
		[table keyDown:enter];
		if (!Check([inserted isEqualToString:clipboard ? @"first line\nsecond line" : @"A"],
			"insert complete clipboard contents or the selected character when pressing Return"))
			return false;
	}
	return true;
}

static bool CheckSplitTabs(EditorDocumentController *controller, EditorDocument *main, EditorDocument *other)
{
	EditorDocument *third = [controller makeUntitledDocumentOfType:controller.defaultType error:nullptr];
	[controller addDocument:third];
	[third makeWindowControllers];
	[controller dropTab:third before:other otherView:YES];
	if (!Check([[controller tabsInOtherView:YES] isEqualToArray:@[third, other]] &&
		[controller selectedTabInOtherView:YES] == third && third.editor.window == main.editor.window &&
		main.chrome.secondaryTabs.window == main.editor.window, "drag one tab into the second strip before the existing tab"))
		return false;
	[controller dropTab:other before:third otherView:YES];
	if (!Check([[controller tabsInOtherView:YES] isEqualToArray:@[other, third]] && controller.focusedDocument == other,
		"reorder tabs and focus the moved tab within the second editor"))
		return false;
	[controller dropTab:third before:main otherView:NO];
	if (!Check([[controller tabsInOtherView:NO] isEqualToArray:@[third, main]] &&
		[[controller tabsInOtherView:YES] isEqualToArray:@[other]], "move a tab back to the primary view"))
		return false;
	[main showWindows];
	[third close];
	[other showWindows];
	NSWindow *window = main.editor.window;
	[window.contentView layoutSubtreeIfNeeded];
	NSSplitView *split = (NSSplitView *)ViewMatching(window.contentView, ^BOOL(NSView *view) {
		return [view isKindOfClass:NSSplitView.class];
	});
	for (int index = 0; index < 4; ++index)
	{
		NSRect first = split.arrangedSubviews.firstObject.frame;
		NSRect last = split.arrangedSubviews.lastObject.frame;
		NSPoint local = split.isVertical ? NSMakePoint((NSMaxX(first) + NSMinX(last)) / 2, NSMidY(first)) :
			NSMakePoint(NSMidX(first), (MIN(NSMaxY(first), NSMaxY(last)) + MAX(NSMinY(first), NSMinY(last))) / 2);
		NSEvent *click = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:[split convertPoint:local toView:nil]
			modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
		NSMenuItem *rotate = [[split menuForEvent:click] itemWithTitle:@"Rotate Right"];
		if (!Check(rotate != nil, "show rotation commands at the split divider"))
			return false;
		BOOL vertical = split.isVertical;
		[NSApp sendAction:rotate.action to:rotate.target from:rotate];
		if (!Check(split.isVertical != vertical && split.arrangedSubviews.count == 2, "rotate both live editor areas"))
			return false;
	}
	return true;
}

static bool CheckSearchScopes(EditorDocument *document, NSURL *test)
{
	NSString *text = @"match\nother\nmatch\n";
	NSURL *file = [test URLByAppendingPathComponent:@"search-source.txt"];
	if (!Check([text writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nullptr], "prepare a closed project file"))
		return false;
	NSData *buffer = [text dataUsingEncoding:NSUTF8StringEncoding];
	NSArray *sources = @[
		[[EditorSearchSource alloc] initWithName:@"Unsaved" url:nil document:document utf8:buffer range:NSMakeRange(0, 6)],
		[[EditorSearchSource alloc] initWithName:file.path url:file document:nil utf8:nil range:NSMakeRange(NSNotFound, 0)],
	];
	NSString *query = DecodeExtendedSearchText(@"match\\n");
	EditorSearchReport *report = SearchSources(sources, query, nil, 0, DecodeExtendedSearchText(@"new\\t"), nil, nullptr);
	if (!Check(report.hits == 3 && report.files.count == 2 && report.files.firstObject.document == document &&
		report.files.firstObject.matches.count == 1 && report.files.firstObject.matches.firstObject.document == document &&
		[report.files.lastObject.matches.lastObject.replacementBytes isEqual:[@"new\t" dataUsingEncoding:NSUTF8StringEncoding]],
		"find and prepare replacements in a selection, an untitled buffer, and a saved project file"))
		return false;
	EditorSearchSource *closed = sources.lastObject;
	closed.lines = [NSIndexSet indexSetWithIndex:2];
	EditorSearchReport *refined = SearchSources(@[closed], @"match", nil, 0, nil, nil, nullptr);
	if (!Check(refined.hits == 1 && refined.files.firstObject.matches.firstObject.line == 3,
		"refine a search to lines found by a previous result"))
		return false;
	NSArray *history = @[refined, report];
	EditorSearchResultsView *results = [[EditorSearchResultsView alloc] initWithOpenMatch:^(EditorSearchMatch *match) {} dismiss:^{}];
	results.reports = history;
	ScintillaView *output = (ScintillaView *)ViewMatching(results, ^BOOL(NSView *view) {
		return [view isKindOfClass:ScintillaView.class];
	});
	if (!Check([output message:SCI_GETLINEVISIBLE wParam:1] && ![output message:SCI_GETLINEVISIBLE wParam:4],
		"keep the latest result expanded and fold the previous search"))
		return false;
	NSArray *remaining = SearchReportsRemovingRows(history, [NSSet setWithObject:report.files.firstObject.matches.firstObject]);
	if (!Check([remaining[1] hits] == 2 && [[remaining[1] files] count] == 1 &&
		report.hits == 3, "remove selected matches and empty file headings without mutating the original report"))
		return false;
	ScintillaView *editor = document.editor;
	[editor setStringProperty:SCI_SETTEXT parameter:0 value:text];
	[document incrementalSearch:nil];
	NSSearchField *field = (NSSearchField *)ViewMatching(editor.window.contentView, ^BOOL(NSView *view) {
		return [view isKindOfClass:NSSearchField.class] && [[view accessibilityLabel] isEqualToString:@"Incremental Search"];
	});
	field.stringValue = @"other";
	[field.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:field]];
	if (!Check(field.isHiddenOrHasHiddenAncestor == NO && [editor message:SCI_GETSELECTIONSTART] == 6,
		"find while typing into the incremental search bar"))
		return false;
	[field.delegate control:field textView:[[NSTextView alloc] initWithFrame:NSZeroRect] doCommandBySelector:@selector(cancelOperation:)];
	[editor message:SCI_UNDO];
	return true;
}

static bool CheckEditingCommands()
{
	ScintillaView *editor = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 300, 150)];
	[editor message:SCI_SETMULTIPLESELECTION wParam:1];
	[editor setStringProperty:SCI_SETTEXT parameter:0 value:@"b\r\na\nb\r\n"];
	EditorReorderLines(editor, 42079);
	if (!Check([editor.string isEqualToString:@"b\r\na\r\n"], "remove duplicate lines while preserving line separators"))
		return false;
	EditorReorderLines(editor, 42059);
	if (!Check([editor.string isEqualToString:@"a\r\nb\r\n"], "sort the remaining lines"))
		return false;
	[editor setStringProperty:SCI_SETTEXT parameter:0 value:@"long\nx\n"];
	[editor message:SCI_GOTOPOS wParam:2];
	EditorInsertColumnText(editor, @"!");
	if (!Check([editor.string isEqualToString:@"lo!ng\nx !\n  !"], "insert into a column and pad short lines"))
		return false;
	[editor setStringProperty:SCI_SETTEXT parameter:0 value:@"foo foo foo"];
	[editor message:SCI_SETSEL wParam:0 lParam:3];
	EditorAddMatchingSelections(editor, 42093);
	if (!Check([editor message:SCI_GETSELECTIONS] == 3, "select all matching words"))
		return false;
	[editor setStringProperty:SCI_SETTEXT parameter:0 value:@"a\n  b\n"];
	[editor message:SCI_SETSEL wParam:0 lParam:4];
	EditorCommentSelection(editor, 42022, @"#", nil, nil);
	if (!Check([editor.string isEqualToString:@"# a\n  # b\n"], "use the language's line comment and preserve indentation"))
		return false;
	[editor message:SCI_MARKERADD wParam:0 lParam:20];
	EditorBookmarkLines(editor, 43051, 20);
	if (!Check([editor.string isEqualToString:@"# a\n"], "remove lines without bookmarks"))
		return false;
	[editor setStringProperty:SCI_SETTEXT parameter:0 value:@"("];
	[editor message:SCI_GOTOPOS wParam:1];
	EditorCompletion *completion = [EditorCompletion new];
	[completion typed:'(' inEditor:editor language:@"python" complete:NO closePairs:YES];
	return Check([editor.string isEqualToString:@"()"] && [editor message:SCI_GETCURRENTPOS] == 1,
		"insert the paired delimiter and keep the caret between the pair");
}
static bool CheckSearchPanel(EditorSearchReport *report)
{
	EditorSearchResultsView *panel = [[EditorSearchResultsView alloc] initWithOpenMatch:^(EditorSearchMatch *match) {}
		dismiss:^{}];
	panel.reports = @[report];
	ScintillaView *output = (ScintillaView *)ViewMatching(panel, ^BOOL(NSView *view) { return [view isKindOfClass:ScintillaView.class]; });
	const auto file = [output message:SCI_POSITIONFROMLINE wParam:1];
	const auto hit = [output message:SCI_POSITIONFROMLINE wParam:2];
	auto match = [output message:SCI_POSITIONAFTER wParam:hit + strlen("\tLine 1: def")];
	return Check(output && [output message:SCI_GETREADONLY] && [output message:SCI_GETSTYLEAT wParam:0] == 1 &&
		[output message:SCI_GETSTYLEAT wParam:file] == 2 && [output message:SCI_GETSTYLEAT wParam:hit] == 3 &&
		[output message:SCI_GETSTYLEAT wParam:match] == 4 &&
		([output message:SCI_GETFOLDLEVEL wParam:1] & SC_FOLDLEVELHEADERFLAG),
		"show a themed search header, foldable file headers, line numbers, and a highlighted hit");
}

@interface EditorDocument (MacroSmoke)
- (BOOL)saveRecordedMacroNamed:(NSString *)name replacing:(BOOL)replacing error:(NSError **)error;
- (void)checkDiskChanges:(BOOL)checkNormal allowPrompt:(BOOL)allowPrompt;
@end

static bool CheckFileModes(EditorDocumentController *controller, NSURL *test)
{
	NSURL *url = [test URLByAppendingPathComponent:@"monitor.log"];
	if (![@"first\n" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nullptr])
		return false;
	EditorDocument *document = [controller makeDocumentWithContentsOfURL:url ofType:controller.defaultType error:nullptr];
	[controller addDocument:document];
	[document makeWindowControllers];
	[document showWindows];
	[document monitorFile:nil];
	if (!Check(document.isMonitoring && [document.editor message:SCI_GETREADONLY], "make the monitored file read-only"))
		return false;
	[@"first\nsecond\n" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nullptr];
	[document checkDiskChanges:NO allowPrompt:NO];
	if (!Check([document.editor.string isEqualToString:@"first\nsecond\n"] && [document.editor message:SCI_GETREADONLY] &&
		[document.editor message:SCI_GETCURRENTPOS] == [document.editor message:SCI_GETLENGTH],
		"reload a monitored file and follow the appended lines"))
		return false;
	[document monitorFile:nil];
	if (!Check(![document.editor message:SCI_GETREADONLY], "restore write access when monitoring is stopped"))
		return false;
	[document.editor message:SCI_GOTOLINE wParam:1];
	[document hideSelectedLines:nil];
	if (!Check(![document.editor message:SCI_GETLINEVISIBLE wParam:1], "hide the selected line"))
		return false;
	[document showHiddenLines:nil];
	if (!Check([document.editor message:SCI_GETLINEVISIBLE wParam:1], "show the hidden line"))
		return false;
	NSMenuItem *mode = [NSMenuItem new];
	mode.tag = 1;
	[document togglePresentationMode:mode];
	if (!Check(document.chrome.hidden && document.chrome.primaryTabs.hidden, "hide editor chrome in Post-It mode"))
		return false;
	[document togglePresentationMode:mode];
	if (!Check(!document.chrome.hidden && !document.chrome.primaryTabs.hidden, "restore editor chrome when leaving Post-It mode"))
		return false;
	[document close];
	return true;
}

static bool CheckSettingsAndLaunch(EditorDocument *document)
{
	EditorResources *resources = EditorResources.shared;
	id width = [resources setting:@"tabWidth" fallback:@4];
	[resources setSetting:@6 forName:@"tabWidth"];
	[document applyPreferences];
	if (!Check([document.editor message:SCI_GETTABWIDTH] == 6, "apply the persisted preferences to an open editor"))
		return false;
	[resources setSetting:width forName:@"tabWidth"];
	[document applyPreferences];
	NSDictionary *styles = [resources styleDefinitions];
	if (!Check(styles[@"python"] && [resources saveStyles:@{@"": @[@{@"name": @"Document map", @"fgColor": @"123456"}]}
		error:nullptr] && [resources widgetColor:@"Document map" background:NO], "customize an XML theme and reload it"))
		return false;
	NSString *xml = @"<NotepadPlus><UserLang name=\"Smoke Custom Language\" ext=\"smokeudl\" udlVersion=\"2.1\"/></NotepadPlus>";
	if (!Check([resources saveUserLanguageXML:xml replacing:nil error:nullptr] &&
		[[resources userLanguageXML:@"Smoke Custom Language"] containsString:@"smokeudl"] &&
		[resources saveUserLanguageXML:[xml stringByReplacingOccurrencesOfString:@"smokeudl" withString:@"smoke2"]
		replacing:@"Smoke Custom Language" error:nullptr] &&
		[[resources userLanguageXML:@"Smoke Custom Language"] containsString:@"smoke2"],
		"create, edit and export a compatible user language"))
		return false;
	NSMenu *menu = [NSMenu new];
	NSMenuItem *item = [menu addItemWithTitle:@"Run Fixture" action:@selector(executeSavedRunCommand:) keyEquivalent:@""];
	item.representedObject = @"Fixture";
	NSDictionary *previous = [resources setting:@"shortcuts" fallback:@{}];
	[resources setSetting:@{EditorShortcutIdentifier(item): @{@"key": @"k", @"modifiers": @(NSEventModifierFlagCommand | NSEventModifierFlagShift)}}
		forName:@"shortcuts"];
	EditorApplyShortcuts(menu);
	[resources setSetting:previous forName:@"shortcuts"];
	if (!Check([item.keyEquivalent isEqualToString:@"k"] && (item.keyEquivalentModifierMask & NSEventModifierFlagShift),
		"apply a stored shortcut to a named Run command"))
		return false;
	EditorLaunchOptions *launch = [[EditorLaunchOptions alloc] initWithArguments:
		@[@"-n7", @"-c", @"3", @"-lPython", @"-nosession", @"-ro", @"-openFoldersAsWorkspace", @"--", @"-sample.txt"]];
	return Check(launch.line == 7 && launch.column == 3 && [launch.language isEqualToString:@"python"] && launch.noSession &&
		launch.readOnly && launch.openFoldersAsWorkspace && [launch.paths.firstObject.lastPathComponent isEqualToString:@"-sample.txt"],
		"parse the original command-line position, language, editing mode and a path starting with a dash");
}

static bool CheckSearchAndConfigurationParity(EditorDocumentController *controller, NSURL *test)
{
	EditorDocument *document = (EditorDocument *)[controller makeUntitledDocumentOfType:controller.defaultType error:nullptr];
	[document makeWindowControllers];
	ScintillaView *editor = document.editor;
	editor.string = @"foo (bar) foo\nFOO";
	NSMenuItem *action = [NSMenuItem new];
	action.tag = 43053;
	[editor message:SCI_GOTOPOS wParam:4];
	[document findMatchingBrace:action];
	if (!Check([editor.selectedString isEqualToString:@"(bar)"], "select a matching bracket pair"))
		return false;
	[editor message:SCI_SETSEL wParam:0 lParam:3];
	action.tag = 43022;
	[document useMarkStyle:action];
	if (!Check([editor message:SCI_INDICATORVALUEAT wParam:10 lParam:10] != 0 &&
		[editor message:SCI_INDICATORVALUEAT wParam:10 lParam:14] == 0, "mark every case-matching token with one style"))
		return false;
	[editor message:SCI_SETSEL wParam:5 lParam:8];
	action.tag = 43063;
	[document useMarkStyle:action];
	action.tag = 43023;
	[document useMarkStyle:action];
	if (!Check([editor message:SCI_INDICATORVALUEAT wParam:10 lParam:0] == 0 &&
		[editor message:SCI_INDICATORVALUEAT wParam:11 lParam:5] != 0, "clear one mark style without clearing the others"))
		return false;
	[editor message:SCI_SETSEL wParam:0 lParam:3];
	action.tag = 43048;
	[document findSelectedText:action];
	action.tag = 43014;
	[document findSelectedText:action];
	if (!Check([editor.selectedString isEqualToString:@"FOO"], "search forward from the selection temporarily"))
		return false;
	[editor message:SCI_SETSEL wParam:5 lParam:8];
	[document findSelectedText:action];
	if (!Check([editor.selectedString isEqualToString:@"bar"] &&
		![[EditorResources.shared setting:@"findHistory" fallback:@[]] containsObject:@"bar"],
		"keep volatile text out of search history"))
		return false;
	[document findNext:nil];
	if (!Check([editor message:SCI_GETSELECTIONSTART] == 10, "retain the previous search after a volatile search"))
		return false;
	action.tag = 42095;
	[document selectOccurrences:action];
	action.tag = 42098;
	[document adjustMatchingSelections:action];
	if (!Check([editor message:SCI_GETSELECTIONS] == 1, "undo the latest multi-selection"))
		return false;
	[editor message:SCI_CLEARALL];
	const char bytes[] = {'a', '\0', 'b'};
	[editor message:SCI_ADDTEXT wParam:sizeof(bytes) lParam:reinterpret_cast<sptr_t>(bytes)];
	[editor message:SCI_SELECTALL];
	action.tag = 42049;
	[document specialClipboard:action];
	if (!Check([editor message:SCI_GETLENGTH] == 0, "cut binary content from the editor"))
		return false;
	action.tag = 42050;
	[document specialClipboard:action];
	if (!Check([editor message:SCI_GETLENGTH] == 3 && [editor message:SCI_GETCHARAT wParam:1] == 0 &&
		[editor message:SCI_GETCHARAT wParam:2] == 'b', "paste raw bytes including a null byte"))
		return false;
	editor.string = @"abc DEF\n";
	[editor message:SCI_GOTOPOS wParam:0];
	action.tag = 42020;
	[document beginOrEndSelection:action];
	[editor message:SCI_GOTOPOS wParam:7];
	[document beginOrEndSelection:action];
	if (!Check([editor.selectedString isEqualToString:@"abc DEF"], "select a range in two steps"))
		return false;
	action.tag = 42067;
	[document transformSelectionCase:action];
	if (!Check([editor.string isEqualToString:@"Abc Def\n"], "apply proper case"))
		return false;
	editor.string = @"abc\ndef";
	[editor message:SCI_GOTOPOS wParam:0];
	action.tag = 42089;
	[document beginOrEndSelection:action];
	[editor message:SCI_GOTOPOS wParam:5];
	[document beginOrEndSelection:action];
	if (!Check([editor message:SCI_SELECTIONISRECTANGLE], "select columns between two caret positions"))
		return false;
	[editor message:SCI_CHANGESELECTIONMODE wParam:SC_SEL_STREAM];
	editor.string = @"  \tone  two\n    next";
	[editor message:SCI_SETTABWIDTH wParam:4];
	[editor message:SCI_GOTOPOS wParam:0];
	action.tag = 42046;
	[document runWhitespaceCommand:action];
	if (!Check([editor.string isEqualToString:@"    one  two\n    next"], "expand tabs using the starting column"))
		return false;
	action.tag = 42053;
	[document runWhitespaceCommand:action];
	if (!Check([editor.string isEqualToString:@"\tone  two\n\tnext"], "compress only indentation when specified"))
		return false;

	EditorResources *resources = EditorResources.shared;
	NSUInteger width = [[resources setting:@"tabWidth" fallback:@4] unsignedIntegerValue];
	NSInteger backup = [[resources setting:@"backupMode" fallback:@0] integerValue];
	NSString *directory = [resources setting:@"backupDirectory" fallback:@""];
	NSURL *config = [test URLByAppendingPathComponent:@"smoke-config.xml"];
	NSString *xml = @"<NotepadPlus><GUIConfigs><GUIConfig name='TabSetting' size='9'/>"
		"<GUIConfig name='Backup' action='1'/>"
		"<GUIConfig name='searchEngine' searchEngineChoice='0' searchEngineCustom='https://example.com/?q=$(CURRENT_WORD)'/>"
		"<GUIConfig name='largeFileRestriction' fileSizeMB='512' isEnabled='no'/>"
		"<GUIConfig name='DockingManager' rightWidth='315'>"
		"<PluginDlg pluginName='Notepad++::InternalFunction' id='44084' curr='1' prev='0' isVisible='yes'/>"
		"</GUIConfig></GUIConfigs></NotepadPlus>";
	if (!Check([xml writeToURL:config atomically:YES encoding:NSUTF8StringEncoding error:nullptr] &&
		[resources importWindowsConfiguration:config error:nullptr], "import a Windows configuration XML"))
		return false;
	[document applyPreferences];
	NSDictionary *dockLayout = [resources setting:@"windowsDockLayout" fallback:@{}];
	if (!Check([editor message:SCI_GETTABWIDTH] == 9 && [dockLayout[@"panes"][@"44084"][@"width"] isEqual:@315] &&
		[[resources setting:@"largeFileMegabytes" fallback:@0] isEqual:@512] &&
		[[resources setting:@"searchEngineCustom" fallback:@""] containsString:@"$(CURRENT_WORD)"] &&
		[[NSString stringWithContentsOfURL:[resources.profile URLByAppendingPathComponent:@"imported-config.xml"]
			encoding:NSUTF8StringEncoding error:nullptr] isEqual:xml], "apply imported preferences and retain the original XML"))
		return false;
	NSURL *file = [test URLByAppendingPathComponent:@"backup-fixture.txt"];
	editor.string = @"new contents";
	[resources setSetting:@"" forName:@"backupDirectory"];
	NSError *error = nil;
	bool saved = [@"before" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nullptr] &&
		[document writeSafelyToURL:file ofType:controller.defaultType forSaveOperation:NSSaveOperation error:&error];
	NSString *copy = [NSString stringWithContentsOfURL:[file URLByAppendingPathExtension:@"bak"]
		encoding:NSUTF8StringEncoding error:nullptr];
	[resources setSettings:@{@"tabWidth": @(width), @"backupMode": @(backup), @"backupDirectory": directory}];
	return Check(saved && [copy isEqualToString:@"before"], "write a backup of the old bytes before saving");
}

static bool CheckCustomMenus(EditorDocument *document, NSEvent *click)
{
	NSURL *profile = EditorResources.shared.profile;
	NSURL *tabFile = [profile URLByAppendingPathComponent:@"tabContextMenu.xml"];
	NSURL *editorFile = [profile URLByAppendingPathComponent:@"contextMenu.xml"];
	NSString *tabs = @"<NotepadPlus><TabContextMenu><Item id=\"41003\" FolderName=\"Actions\" ItemNameAs=\"Close This\"/><Item id=\"44048\"/></TabContextMenu></NotepadPlus>";
	NSString *editor = @"<NotepadPlus><ScintillaContextMenu><Item id=\"42002\" ItemNameAs=\"Copy This\"/></ScintillaContextMenu></NotepadPlus>";
	if (![tabs writeToURL:tabFile atomically:YES encoding:NSUTF8StringEncoding error:nullptr] ||
		![editor writeToURL:editorFile atomically:YES encoding:NSUTF8StringEncoding error:nullptr])
		return false;
	NSMenu *tabMenu = EditorTabMenu(document);
	NSMenuItem *close = [[[tabMenu itemWithTitle:@"Actions"] submenu] itemWithTitle:@"Close This"];
	NSMenuItem *copy = [[document.editor menuForEvent:click] itemWithTitle:@"Copy This"];
	[NSFileManager.defaultManager removeItemAtURL:tabFile error:nullptr];
	[NSFileManager.defaultManager removeItemAtURL:editorFile error:nullptr];
	return Check(close.representedObject == document && [tabMenu itemWithTag:44048] && copy,
		"apply custom context menu groups, stable command IDs and translated fallback labels");
}

static bool CheckSearchMacro(EditorDocument *document, NSURL *test)
{
	NSString *xml = @"<NotepadPlus><Macros><Macro name=\"Find and replace\">"
		"<Action type=\"3\" message=\"1700\" wParam=\"0\" lParam=\"0\" sParam=\"\"/>"
		"<Action type=\"3\" message=\"1601\" wParam=\"0\" lParam=\"0\" sParam=\"needle\"/>"
		"<Action type=\"3\" message=\"1602\" wParam=\"0\" lParam=\"0\" sParam=\"replacement\"/>"
		"<Action type=\"3\" message=\"1625\" wParam=\"0\" lParam=\"0\" sParam=\"\"/>"
		"<Action type=\"3\" message=\"1702\" wParam=\"0\" lParam=\"768\" sParam=\"\"/>"
		"<Action type=\"3\" message=\"1701\" wParam=\"0\" lParam=\"1609\" sParam=\"\"/>"
		"</Macro></Macros></NotepadPlus>";
	NSURL *directory = [test URLByAppendingPathComponent:@"search-macro" isDirectory:YES];
	NSURL *path = [test URLByAppendingPathComponent:@"search-macro.xml"];
	EditorMacroLibrary *library = [[EditorMacroLibrary alloc] initWithDirectory:directory];
	if (!Check([xml writeToURL:path atomically:YES encoding:NSUTF8StringEncoding error:nullptr] &&
		[library importShortcuts:path skipped:nullptr error:nullptr] == 1, "import an upstream search macro"))
		return false;
	EditorMacroLibrary *reopened = [[EditorMacroLibrary alloc] initWithDirectory:directory];
	NSMenuItem *command = [NSMenuItem new];
	command.representedObject = reopened.macros.firstObject;
	ScintillaView *editor = document.editor;
	[editor setStringProperty:SCI_SETTEXT parameter:0 value:@"needle needle"];
	[document playSavedMacro:command];
	if (!Check([editor.string isEqualToString:@"replacement replacement"], "replay saved search and replace actions"))
		return false;
	[editor message:SCI_UNDO];
	[editor message:SCI_UNDO];
	return true;
}

static bool CheckCharacterSet(NSURL *test, EditorDocumentController *controller)
{
	NSString *text = @"Привет, редактор!\r\n";
	NSData *bytes = [text dataUsingEncoding:NSWindowsCP1251StringEncoding];
	NSURL *file = [test URLByAppendingPathComponent:@"windows-1251.txt"];
	NSError *error = nil;
	if (!Check([bytes writeToURL:file options:NSDataWritingAtomic error:&error], "write Windows-1251 text"))
		return false;
	EditorDocument *document = [controller makeDocumentWithContentsOfURL:file ofType:controller.defaultType error:&error];
	if (!Check(document != nil, "open a legacy file before selecting its character set"))
		return false;
	[controller addDocument:document];
	[document makeWindowControllers];
	[document showWindows];
	NSView *content = document.windowControllers.firstObject.window.contentView;
	EditorDocumentList *documentList = (EditorDocumentList *)ViewMatching(content, ^BOOL(NSView *view) {
		return [view isKindOfClass:EditorDocumentList.class];
	});
	[document toggleDocumentList:nil];
	if (!Check(documentList && !documentList.isHiddenOrHasHiddenAncestor, "open the docked document list from the editor command"))
		return false;
	[content layoutSubtreeIfNeeded];
	NSRect editorFrame = [document.editor convertRect:document.editor.bounds toView:content];
	if (!Check(fabs(NSMinY(editorFrame) - NSMaxY(document.chrome.statusBar.frame)) < 1.0,
		"let the editor fill the window down to the status bar with search results hidden"))
		return false;
	[document toggleDocumentList:nil];
	if (!Check(documentList.isHiddenOrHasHiddenAncestor, "close the list and return its space to the editor"))
		return false;
	NSMenu *encoding = [NSApp.mainMenu itemWithTitle:@"Encoding"].submenu;
	NSMenu *sets = [encoding itemWithTitle:@"Character Set"].submenu;
	NSMenu *cyrillic = [sets itemWithTitle:@"Cyrillic"].submenu;
	NSMenuItem *windows1251 = [cyrillic itemWithTitle:@"Windows-1251"];
	if (!Check(windows1251 != nil, "show Windows-1251 in the Encoding menu"))
	{
		fprintf(stderr, "Encoding menu: %s; Character Set menu: %s; Cyrillic menu: %s\n", encoding.itemArray.description.UTF8String ?: "",
			sets.itemArray.description.UTF8String ?: "", cyrillic.itemArray.description.UTF8String ?: "");
		return false;
	}
	if (!Check([NSApp sendAction:windows1251.action to:windows1251.target from:windows1251], "dispatch the character-set command") ||
		!Check([document.editor.string isEqualToString:text], "reopen the Cyrillic file using Windows-1251") ||
		!Check(!document.isDocumentEdited, "leave file state clean after reinterpreting the bytes") ||
		!Check([[document dataOfType:controller.defaultType error:&error] isEqualToData:bytes], "round-trip the existing legacy bytes"))
		return false;
	NSDictionary *snapshot = [controller captureWorkspace];
	[document close];
	[controller restoreWorkspace:snapshot];
	document = (EditorDocument *)[controller documentForURL:file];
	BOOL restored = document && [document.editor.string isEqualToString:text] &&
		[[document dataOfType:controller.defaultType error:&error] isEqualToData:bytes];
	[document close];
	return Check(restored, "restore the explicitly selected character set on reopen");
}

void RunWorkspaceLifecycleTest(BOOL restore)
{
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
		dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
			Check(false, "quit through AppKit after saving the workspace without an unsaved-document prompt");
			std::exit(1);
		});
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	NSString *draft = @"Recover this unsaved draft after quitting.";
	if (restore)
	{
		EditorDocument *document = (EditorDocument *)controller.documents.firstObject;
		if (!Check(controller.documents.count == 1 && document.isDocumentEdited && [document.editor.string isEqualToString:draft] &&
			[document.editor message:SCI_GETSELECTIONEND] == 7, "restore the unsaved draft and clone selection on a fresh AppKit launch"))
			std::exit(1);
		puts("Passed: recovery through AppKit quit and relaunch.");
	}
	else
	{
		if (!controller.documents.count)
			[controller newDocument:nil];
		EditorDocument *document = (EditorDocument *)controller.documents.firstObject;
		[document.editor setStringProperty:SCI_REPLACESEL parameter:0 value:draft];
		if (!Check(controller.documents.count == 1 && document.isDocumentEdited && [document.editor.string isEqualToString:draft],
			"make an unsaved draft in a full AppKit launch"))
			std::exit(1);
		[document cloneToOtherView:nil];
		[document.editor message:SCI_SETSEL wParam:0 lParam:7];
	}
	[NSApp terminate:nil];
}

int RunSmokeTest(void)
{
	NSString *directory = NSProcessInfo.processInfo.environment[@"MACPAD_DATA_DIR"];
	if (!Check(directory.isAbsolutePath, "set MACPAD_DATA_DIR to an isolated absolute test directory"))
		return 1;
	EditorResources *resources = EditorResources.shared;
	NSURL *test = [NSURL fileURLWithPath:directory isDirectory:YES];
	NSURL *fixture = [test URLByAppendingPathComponent:@"данные smoke.py"];
	NSString *source = @"def пример():\r\n    pass\r\n";
	NSMutableData *encoded = [NSMutableData dataWithBytes:"\xff\xfe" length:2];
	[encoded appendData:[source dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
	NSError *error = nil;
	if (!Check([encoded writeToURL:fixture options:NSDataWritingAtomic error:&error], "write UTF-16 test file"))
		return 1;
	NSURL *searchFolder = [test URLByAppendingPathComponent:@"find in files" isDirectory:YES];
	NSURL *keptFolder = [searchFolder URLByAppendingPathComponent:@"sources" isDirectory:YES];
	NSURL *skippedFolder = [keptFolder URLByAppendingPathComponent:@"logs" isDirectory:YES];
	NSFileManager *files = NSFileManager.defaultManager;
	if (!Check([files createDirectoryAtURL:skippedFolder withIntermediateDirectories:YES attributes:nil error:&error],
		"create a nested search fixture"))
		return 1;
	NSURL *rootText = [searchFolder URLByAppendingPathComponent:@"root.py"];
	NSURL *nestedText = [keptFolder URLByAppendingPathComponent:@"nested.py"];
	NSURL *ignored = [skippedFolder URLByAppendingPathComponent:@"ignored.py"];
	if (!Check([encoded writeToURL:rootText options:NSDataWritingAtomic error:&error] &&
		[encoded writeToURL:nestedText options:NSDataWritingAtomic error:&error] &&
		[encoded writeToURL:ignored options:NSDataWritingAtomic error:&error], "write files of different search scopes"))
		return 1;
	NSDictionary *openFiles = @{rootText.URLByStandardizingPath: [@"def пример_edited():" dataUsingEncoding:NSUTF8StringEncoding]};
	NSProgress *progress = [NSProgress progressWithTotalUnitCount:-1];
	EditorSearchReport *report = SearchDirectory(searchFolder, @"(?<=def )пример(?:_edited)?", @"*.py !+\\log*",
		SCFIND_REGEXP, YES, NO, openFiles, nil, progress, &error);
	if (error && !report)
		fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
	EditorSearchMatch *rootMatch = report.files.firstObject.matches.firstObject;
	if (!Check(report.hits == 2 && report.searchedFiles == 2 && report.files.count == 2 &&
		[rootMatch.url isEqual:rootText] && rootMatch.line == 1 && rootMatch.byteRange.location == 4 &&
		[[rootMatch.lineText substringWithRange:rootMatch.highlight] isEqualToString:@"пример_edited"],
		"search nested UTF-16 files and unsaved text with Unicode lookbehind and directory exclusions"))
		return 1;
	if (!CheckSearchPanel(report))
		return 1;
	report = SearchDirectory(searchFolder, @"^", @"*.py", SCFIND_REGEXP | SCFIND_REGEXP_EMPTYMATCH_ALL, NO, NO, openFiles, nil, progress, &error);
	if (!Check(report.hits == 1 && report.searchedFiles == 1 && report.files.firstObject.matches.firstObject.byteRange.length == 0,
		"find a zero-width match without looping and honour the recursion checkbox"))
		return 1;
	NSError *regexError = nil;
	report = SearchDirectory(searchFolder, @"[", @"*.py", SCFIND_REGEXP, NO, NO, openFiles, nil, progress, &regexError);
	if (!Check(!report && regexError, "report an invalid multi-file regular expression"))
		return 1;
	report = SearchDirectory(searchFolder, @"(пример)", @"*.py !+\\log*", SCFIND_REGEXP,
		YES, NO, openFiles, @"новый_$1", progress, &error);
	NSMutableData *expectedReplacement = [NSMutableData dataWithBytes:"\xff\xfe" length:2];
	[expectedReplacement appendData:[@"def новый_пример():\r\n    pass\r\n" dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
	NSError *replacementError = nil;
	if (!Check(report.files.count == 2 && report.files.firstObject.fromOpenBuffer &&
		![report.files.firstObject replaceOnDisk:&replacementError] && replacementError &&
		[report.files.lastObject replaceOnDisk:&error] &&
		[[NSData dataWithContentsOfURL:nestedText] isEqualToData:expectedReplacement] &&
		[[NSData dataWithContentsOfURL:rootText] isEqualToData:encoded],
		"replace a capture group on disk while preserving UTF-16 BOM, CRLF and an open buffer's disk copy"))
		return 1;
	replacementError = nil;
	if (!Check(![report.files.lastObject replaceOnDisk:&replacementError] && replacementError &&
		[[NSData dataWithContentsOfURL:nestedText] isEqualToData:expectedReplacement], "skip a file that changed after the replacement was planned"))
		return 1;
	[progress cancel];
	report = SearchDirectory(searchFolder, @"def", @"*.py", 0, YES, NO, openFiles, nil, progress, &error);
	if (!Check(!report, "cancel a file search"))
		return 1;

	NSURL *customTheme = [resources importXML:[test URLByAppendingPathComponent:@"Smoke.xml"] theme:YES error:&error];
	NSURL *translation = [resources importXML:[NSBundle.mainBundle URLForResource:@"russian" withExtension:@"xml"
		subdirectory:@"localization"] theme:NO error:&error];
	if (!Check(customTheme && translation, "import theme and translation XML"))
		return 1;
	[resources chooseTheme:customTheme];
	[resources chooseTranslation:translation];
	if (!Check([[resources label:@"file" fallback:@"File"] isEqualToString:@"Файл"], "apply Russian menu labels"))
		return 1;
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	if (!CheckCharacterSet(test, controller) || !CheckFileModes(controller, test))
		return 1;
	EditorDocument *document = (EditorDocument *)[controller makeDocumentWithContentsOfURL:fixture
		ofType:controller.defaultType error:&error];
	if (!Check([document isKindOfClass:EditorDocument.class], "open fixture with the macOS document controller"))
		return 1;
	[controller addDocument:document];
	[document makeWindowControllers];
	NSArray<NSToolbarItemIdentifier> *toolbarItems = [document.chrome.toolbarButtons valueForKeyPath:@"command.itemIdentifier"];
	if (!Check([toolbarItems containsObject:@"save"] && [toolbarItems containsObject:@"findrep"] &&
		[toolbarItems containsObject:@"saveall"] && [toolbarItems containsObject:@"allChars"],
		"show file and search commands in the editor toolbar"))
		return 1;
	[document showWindows];
	EditorDocument *second = [controller makeUntitledDocumentOfType:controller.defaultType error:&error];
	if (!Check(second != nil, "create a second document tab"))
		return 1;
	[controller addDocument:second];
	[second makeWindowControllers];
	[controller refreshDocumentTabs];
	NSString *closeLabel = [NSString stringWithFormat:[resources label:@"native-closeNamedTab" fallback:@"Close %@"], second.displayName];
	NSButton *closeInactive = (NSButton *)ViewMatching(document.chrome.primaryTabs, ^BOOL(NSView *view) {
		return [view isKindOfClass:NSButton.class] && [[view accessibilityLabel] isEqualToString:closeLabel];
	});
	NSEvent *contextClick = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:NSZeroPoint
		modifierFlags:0 timestamp:0 windowNumber:document.chrome.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
	NSMenu *tabMenu = [closeInactive menuForEvent:contextClick];
	NSMenuItem *closeItem = [tabMenu itemWithTag:41003];
	if (!Check(closeInactive && closeItem.representedObject == second && [tabMenu itemWithTag:44048] != nil,
		"give inactive tabs a close button and a menu targeting that tab"))
		return 1;
	NSMenuItem *pin = [tabMenu itemWithTag:44048];
	[NSApp sendAction:pin.action to:pin.target from:pin];
	if (!Check(second.isTabPinned && controller.tabDocuments.firstObject == second, "pin a tab from its context menu"))
		return 1;
	[second changeTabPin];
	if (!Check([[document.editor menuForEvent:contextClick] itemWithTag:SCI_LINEDUPLICATE] != nil, "populate the editor's right-click menu"))
		return 1;
	if (!CheckCustomMenus(document, contextClick) || !CheckSettingsAndLaunch(document))
		return 1;
	[second showWindows];
	if (!Check(!document.windowControllers.firstObject.window.visible && second.windowControllers.firstObject.window.visible,
		"switch documents in a single visible window"))
		return 1;
	if (!CheckDocumentDock(second))
		return 1;
	[document moveToOtherView:nil];
	if (!Check(document.editor.window && document.editor.window == second.editor.window &&
		!document.windowControllers.firstObject.window.visible, "host two live editors in one visible window") ||
		!Check(controller.focusedDocument == document, "focus the editor in the other view") ||
		!Check([NSApp targetForAction:@selector(convertLineEndings:) to:nil from:nil] == document,
			"route menu commands to the focused view"))
		return 1;
	[document toggleZoomSync:nil];
	[document.editor message:SCI_SETZOOM wParam:3];
	if (!Check([second.editor message:SCI_GETZOOM] == 3, "synchronize zoom between focused and companion views"))
		return 1;
	[document.editor message:SCI_SETZOOM wParam:0];
	[document toggleZoomSync:nil];
	[second toggleDocumentList:nil];
	NSTableView *documentTable = (NSTableView *)ViewMatching(second.editor.window.contentView, ^BOOL(NSView *view) {
		return [view isKindOfClass:NSTableView.class] && [[view accessibilityIdentifier] isEqualToString:@"open-documents"];
	});
	if (!Check(documentTable.numberOfRows == 4 && [documentTable.delegate tableView:documentTable isGroupRow:0] &&
		[documentTable.delegate tableView:documentTable isGroupRow:2], "group the open documents by editor view"))
		return 1;
	NSString *groupTitle = [EditorResources.shared label:@"docList:ListGroups" fallback:@"Group by View"];
	NSMenuItem *group = [[documentTable.headerView menuForEvent:contextClick] itemWithTitle:groupTitle];
	[NSApp sendAction:group.action to:group.target from:group];
	if (!Check(documentTable.numberOfRows == 2, "switch to the flat document list from its heading"))
		return 1;
	[second toggleDocumentList:nil];
	if (!CheckFolderWorkspace(controller, second, test))
		return 1;
	if (!CheckProjectWorkspace(controller, second, test))
		return 1;
	if (!CheckFunctionList() || !CheckDocumentMap(controller, second) || !CheckInsertPanels())
		return 1;
	if (!CheckSplitTabs(controller, second, document))
		return 1;
	if (!CheckSearchScopes(second, test))
		return 1;
	if (!CheckEditingCommands())
		return 1;
	if (!CheckSearchAndConfigurationParity(controller, test))
		return 1;
	if (!CheckSearchMacro(second, test))
		return 1;
	[document.editor setStringProperty:SCI_REPLACESEL parameter:0 value:@"# Two views\r\n"];
	if (!Check([document.editor.string hasPrefix:@"# Two views"] && second.editor.string.length == 0 && document.isDocumentEdited,
		"edit the other view without altering the active host document"))
		return 1;
	[document.editor message:SCI_UNDO];
	NSString *scrollText = [@"" stringByPaddingToLength:2400 withString:@"scroll line\n" startingAtIndex:0];
	for (EditorDocument *pane in @[document, second])
		[pane.editor setStringProperty:SCI_REPLACESEL parameter:0 value:scrollText];
	[document.editor message:SCI_SETFIRSTVISIBLELINE wParam:12];
	[document toggleVerticalScrollSync:nil];
	if (!Check([document.editor message:SCI_GETFIRSTVISIBLELINE] > 0 &&
		[document.editor message:SCI_GETFIRSTVISIBLELINE] == [second.editor message:SCI_GETFIRSTVISIBLELINE],
		"synchronize vertical scrolling between the two visible editors"))
		return 1;
	[document toggleVerticalScrollSync:nil];
	for (EditorDocument *pane in @[document, second])
		[pane.editor message:SCI_UNDO];
	[second closeOtherView:nil];
	if (!Check(document.editor.window != second.editor.window &&
		[document.editor.string isEqualToString:source], "return the other document to its own tab without losing edits"))
		return 1;
	[second close];
	if (!Check(document.windowControllers.firstObject.window.visible, "restore the preceding tab after closing the active tab"))
		return 1;
	ScintillaView *primary = document.editor;
	[primary message:SCI_SETSEL wParam:0 lParam:0];
	[document cloneToOtherView:nil];
	ScintillaView *clone = document.editor;
	if (!Check(clone != primary && clone.window == primary.window &&
		[clone message:SCI_GETDOCPOINTER] == [primary message:SCI_GETDOCPOINTER],
		"clone one buffer into a second, separately focusable view"))
		return 1;
	[clone message:SCI_SETSEL wParam:0 lParam:3];
	if (!Check([primary message:SCI_GETSELECTIONEND] == 0, "keep independent cursor and selection state in the clone"))
		return 1;
	NSURL *clonedSession = [test URLByAppendingPathComponent:@"cloned-session.xml"];
	if (!Check([controller saveSessionToURL:clonedSession error:&error], "export a same-buffer split as an XML session"))
		return 1;
	[document closeOtherView:nil];
	if (!Check([controller loadSessionFromURL:clonedSession error:&error], "open the saved clone layout"))
		return 1;
	clone = document.editor;
	if (!Check(clone != primary && [clone message:SCI_GETSELECTIONEND] == 3 &&
		[primary message:SCI_GETSELECTIONEND] == 0, "restore the clone and its separate selection from the XML session"))
		return 1;
	[clone setStringProperty:SCI_REPLACESEL parameter:0 value:@"class"];
	if (!Check([primary.string hasPrefix:@"class пример"] && document.isDocumentEdited, "show edits from the clone in both views"))
		return 1;
	[primary message:SCI_UNDO];
	[document closeOtherView:nil];
	[primary message:SCI_COLOURISE wParam:0 lParam:-1];
	if (!Check(document.editor == primary && [primary.string isEqualToString:source] && !document.isDocumentEdited,
		"share undo history and keep the document when closing the clone"))
		return 1;
	ScintillaView *editor = document.editor;
	[editor message:SCI_SETTARGETRANGE wParam:0 lParam:[editor message:SCI_GETLENGTH]];
	NSString *regex = @"(?<=def )пример";
	if (!Check(SearchEditorTarget(editor, regex, SCFIND_REGEXP) == 4, "run an upstream Boost.Regex lookbehind in Unicode text"))
		return 1;
	[document markText:nil];
	NSWindow *markPanel = document.windowControllers.firstObject.window.childWindows.lastObject;
	NSTextField *query = nil;
	NSButton *markButton = nil;
	NSButton *clearButton = nil;
	for (NSView *view in markPanel.contentView.subviews)
	{
		if (!query && [view isKindOfClass:NSTextField.class] && [(NSTextField *)view isEditable])
			query = (NSTextField *)view;
		if ([view isKindOfClass:NSButton.class] && [(NSButton *)view tag] == 7)
			markButton = (NSButton *)view;
		if ([view isKindOfClass:NSButton.class] && [(NSButton *)view tag] == 8)
			clearButton = (NSButton *)view;
	}
	query.stringValue = @"пример";
	[markButton performClick:nil];
	if (!Check(controller.documents.count == 1, "leave the document count unchanged after applying marks"))
		return 1;
	if (!Check([editor message:SCI_INDICATORALLONFOR wParam:4] != 0 && !document.isDocumentEdited,
		"mark a match from the search dialog without editing the document"))
		return 1;
	[clearButton performClick:nil];
	if (!Check([editor message:SCI_INDICATORALLONFOR wParam:4] == 0, "clear the marks from the search dialog"))
		return 1;
	[markPanel close];
	if (!Check(controller.documents.count == 1, "leave the document count unchanged after closing Mark"))
		return 1;
	if ([editor message:SCI_GETLEXER] != SCLEX_PYTHON || [editor message:SCI_GETSTYLEAT wParam:0] != SCE_P_WORD)
		fprintf(stderr, "Lexer ID: %ld, style at offset zero: %ld\n",
			[editor message:SCI_GETLEXER], [editor message:SCI_GETSTYLEAT wParam:0]);
	if (!Check([[document dataOfType:controller.defaultType error:&error] isEqualToData:encoded], "round trip UTF-16 BOM and CRLF") ||
		!Check([editor message:SCI_GETEOLMODE] == SC_EOL_CRLF, "detect CRLF for new lines") ||
		!Check([editor message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT] == 0x563412, "apply imported XML theme") ||
		!Check([editor message:SCI_GETLEXER] == SCLEX_PYTHON && [editor message:SCI_GETSTYLEAT wParam:0] == SCE_P_WORD,
			"highlight a Python keyword with Lexilla"))
		return 1;
	[editor message:SCI_GOTOLINE wParam:1];
	[document toggleBookmark:nil];
	[editor message:SCI_GOTOLINE wParam:0];
	NSMenuItem *nextBookmark = [[NSMenuItem alloc] init];
	nextBookmark.tag = 1;
	[document navigateBookmark:nextBookmark];
	if (!Check([editor message:SCI_GETCURRENTPOS] == [editor message:SCI_POSITIONFROMLINE wParam:1],
		"jump to a bookmark in the document"))
		return 1;
	[document clearBookmarks:nil];

	NSURL *udl = [test URLByAppendingPathComponent:@"User Language.xml"];
	NSString *definition = @"<NotepadPlus><UserLang name='Smoke language' ext='smk' udlVersion='2.1'>"
		"<Settings><Global caseIgnored='yes'/><Prefix/></Settings>"
		"<KeywordLists><Keywords name='Keywords1'>def</Keywords></KeywordLists>"
		"<Styles><WordsStyle name='KEYWORDS1' fgColor='009944'/></Styles></UserLang></NotepadPlus>";
	if (!Check([definition writeToURL:udl atomically:YES encoding:NSUTF8StringEncoding error:&error] &&
		[resources importUserLanguages:udl error:&error], "import UDL 2.1 XML"))
		return 1;
	NSMenuItem *chooseLexer = [[NSMenuItem alloc] init];
	chooseLexer.representedObject = @"udl:Smoke language";
	[document selectLanguage:chooseLexer];
	if (!Check([editor message:SCI_GETLEXER] == SCLEX_USER && [editor message:SCI_GETSTYLEAT wParam:0] == SCE_USER_STYLE_KEYWORD1 &&
		[editor message:SCI_STYLEGETFORE wParam:SCE_USER_STYLE_KEYWORD1] == 0x449900, "apply imported UDL keywords and colors"))
		return 1;
	chooseLexer.representedObject = nil;
	[document selectLanguage:chooseLexer];

	NSMenuItem *unixEndings = [[NSMenuItem alloc] init];
	unixEndings.tag = SC_EOL_LF;
	[document convertLineEndings:unixEndings];
	if (!Check([editor message:SCI_GETEOLMODE] == SC_EOL_LF &&
		[editor.string isEqualToString:@"def пример():\n    pass\n"], "convert the document to Unix line endings"))
		return 1;
	[editor message:SCI_UNDO];
	if (!Check([editor.string isEqualToString:source] && !document.isDocumentEdited, "undo line ending conversion"))
		return 1;

	EditorPlugins *plugins = [[EditorPlugins alloc] initWithDirectory:[test URLByAppendingPathComponent:@"plugins"]];
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Plugins"];
	[plugins populateMenu:menu];
	NSMenuItem *item = [menu itemWithTitle:@"Smoke: Replace Selection"];
	if (!Check(item != nil, "load a macOS plugin command"))
		return 1;
	[editor message:SCI_SETSEL wParam:0 lParam:3];
	if (!Check([plugins performCommand:item inDocument:document], "invoke the command exposed in the Plugins menu") ||
		!Check([editor.string hasPrefix:@"class пример"], "apply a plugin edit to the active document") ||
		!Check(document.isDocumentEdited, "mark a plugin edit as unsaved"))
		return 1;

	[editor message:SCI_UNDO];
	if (!Check([editor.string isEqualToString:source] && !document.isDocumentEdited, "undo to the original save point"))
		return 1;
	[editor message:SCI_REDO];
	NSURL *output = [test URLByAppendingPathComponent:@"saved smoke.py"];
	__block BOOL completed = NO;
	__block NSError *saveError = nil;
	[document saveToURL:output ofType:controller.defaultType forSaveOperation:NSSaveAsOperation completionHandler:^(NSError *failure) {
		saveError = failure;
		completed = YES;
	}];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
	while (!completed && deadline.timeIntervalSinceNow > 0)
		[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
	if (saveError)
		fprintf(stderr, "%s\n", saveError.localizedDescription.UTF8String);
	NSMutableData *expected = [NSMutableData dataWithBytes:"\xff\xfe" length:2];
	[expected appendData:[@"class пример():\r\n    pass\r\n" dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
	if (!Check(completed && !saveError && [[NSData dataWithContentsOfURL:output] isEqualToData:expected],
		"save edited UTF-16 file with its original BOM and CRLF") ||
		!Check(!document.isDocumentEdited, "clear the edited state after saving"))
		return 1;
	[editor message:SCI_SETSEL wParam:0 lParam:5];
	[document startRecordingMacro:nil];
	[editor setStringProperty:SCI_REPLACESEL parameter:0 value:@"def"];
	[document stopRecordingMacro:nil];
	if (!Check([document saveRecordedMacroNamed:@"Smoke recording" replacing:NO error:&error], "save a named macro in the profile"))
		return 1;
	[editor message:SCI_UNDO];
	[editor message:SCI_SETSEL wParam:0 lParam:5];
	[document playRecordedMacro:nil];
	if (!Check([editor.string hasPrefix:@"def пример"], "replay a recorded text edit"))
		return 1;
	[editor message:SCI_UNDO];
	if (!Check(!document.isDocumentEdited && [editor.string hasPrefix:@"class пример"], "undo macro playback in one step"))
		return 1;
	EditorMacroLibrary *reloaded = [[EditorMacroLibrary alloc] initWithDirectory:test];
	EditorMacroLibrary *concurrent = [[EditorMacroLibrary alloc] initWithDirectory:test];
	NSURL *shortcuts = [test URLByAppendingPathComponent:@"shortcuts.xml"];
	NSString *libraryXML = @"<NotepadPlus><Macros>"
		"<Macro name='Insert from XML' FolderName='Smoke folder'><Action type='1' message='2170' wParam='0' lParam='0' sParam='café'/></Macro>"
		"<Macro name='Trim from XML' FolderName='Smoke folder'><Action type='2' message='0' wParam='42024' lParam='0'/></Macro>"
		"<Macro name='Unsupported'><Action type='0' message='2182' wParam='0' lParam='4294967295' sParam=''/></Macro>"
		"</Macros></NotepadPlus>";
	NSUInteger skipped = 0;
	if (!Check(reloaded.macros.count == 1 && [reloaded.macros.firstObject.name isEqualToString:@"Smoke recording"] &&
		[libraryXML writeToURL:shortcuts atomically:YES encoding:NSUTF8StringEncoding error:&error] &&
		[EditorMacroLibrary.shared importShortcuts:shortcuts skipped:&skipped error:&error] == 2 && skipped == 1 &&
		[EditorMacroLibrary.shared.macros.lastObject.folder isEqualToString:@"Smoke folder"],
		"reload named macros and import only compatible, validated shortcut actions"))
		return 1;
	NSError *conflict = nil;
	if (!Check(![concurrent removeMacro:concurrent.macros.firstObject error:&conflict] && conflict &&
		[[[EditorMacroLibrary alloc] initWithDirectory:test] macros].count == 3,
		"prevent a second instance from overwriting an updated macro library"))
		return 1;
	EditorDocument *macroDocument = [controller makeUntitledDocumentOfType:controller.defaultType error:&error];
	[controller addDocument:macroDocument];
	[macroDocument makeWindowControllers];
	[macroDocument showWindows];
	NSMenu *macroMenu = [NSApp.mainMenu itemWithTitle:@"Macro"].submenu;
	[macroMenu update];
	NSMenu *importedMenu = [macroMenu itemWithTitle:@"Smoke folder"].submenu;
	NSMenuItem *savedMacroItem = [importedMenu itemWithTitle:@"Insert from XML"];
	if (!Check(savedMacroItem != nil, "expose imported macro folders in the live menu") ||
		!Check([NSApp sendAction:savedMacroItem.action to:savedMacroItem.target from:savedMacroItem] &&
		[macroDocument.editor.string isEqualToString:@"café"] && [editor.string hasPrefix:@"class пример"],
		"run a shared imported macro from its menu in a different document"))
		return 1;
	[macroDocument.editor setStringProperty:SCI_SETTEXT parameter:0 value:@" \tfirst  \r\n second \t"];
	[macroDocument.editor message:SCI_SETSEL wParam:3 lParam:6];
	NSMenuItem *trim = [[NSMenuItem alloc] init];
	trim.tag = 42043;
	[macroDocument runWhitespaceCommand:trim];
	if (!Check([macroDocument.editor.string isEqualToString:@"first\r\n second \t"], "trim only the partially selected line"))
		return 1;
	[macroDocument.editor message:SCI_SETSEL wParam:0 lParam:0];
	NSMenuItem *importedTrim = [importedMenu itemWithTitle:@"Trim from XML"];
	if (!Check(importedTrim && [NSApp sendAction:importedTrim.action to:importedTrim.target from:importedTrim] &&
		[macroDocument.editor.string isEqualToString:@"first\r\n second"], "run an imported whitespace menu command"))
		return 1;
	[macroDocument close];

	[editor message:SCI_SETSEL wParam:1 lParam:4];
	[document toggleBookmark:nil];
	EditorDocument *sessionPeer = [controller makeDocumentWithContentsOfURL:rootText ofType:controller.defaultType error:&error];
	if (!Check(sessionPeer != nil, "open a second saved file for the XML session"))
		return 1;
	[controller addDocument:sessionPeer];
	[sessionPeer makeWindowControllers];
	[sessionPeer moveToOtherView:nil];
	NSURL *session = [test URLByAppendingPathComponent:@"session.xml"];
	if (!Check([controller saveSessionToURL:session error:&error], "write a compatible editor session"))
		return 1;
	[sessionPeer close];
	[document close];
	if (!Check([controller loadSessionFromURL:session error:&error], "reopen files from the saved session"))
		return 1;
	document = (EditorDocument *)[controller documentForURL:output];
	editor = document.editor;
	sessionPeer = (EditorDocument *)[controller documentForURL:rootText];
	if (!Check(document && [editor message:SCI_GETANCHOR] == 1 && [editor message:SCI_GETCURRENTPOS] == 4 &&
		[editor message:SCI_MARKERGET wParam:0] != 0 && editor.window == sessionPeer.editor.window &&
		controller.focusedDocument == sessionPeer, "restore two panes, focus, selection and bookmark from the XML session"))
		return 1;
	[sessionPeer close];

	NSMenuItem *utf8 = [[NSMenuItem alloc] init];
	utf8.tag = NSUTF8StringEncoding;
	[document convertEncoding:utf8];
	if (!Check(document.isDocumentEdited && [[document dataOfType:controller.defaultType error:&error]
		isEqualToData:[editor.string dataUsingEncoding:NSUTF8StringEncoding]], "convert to UTF-8 and mark the new encoding as unsaved"))
		return 1;
	EditorDocument *draft = [controller makeUntitledDocumentOfType:controller.defaultType error:&error];
	[controller addDocument:draft];
	[draft makeWindowControllers];
	[draft showWindows];
	[draft.editor setStringProperty:SCI_REPLACESEL parameter:0 value:@"Unsaved draft — черновик"];
	[draft.editor message:SCI_SETSEL wParam:0 lParam:7];
	[document moveToOtherView:nil];
	if (!Check(controller.documents.count == 2, "prepare two tabs for the workspace test"))
	{
		for (EditorDocument *item in controller.documents)
			fprintf(stderr, "  open %s, saved=%d, edited=%d\n", item.displayName.UTF8String, item.fileURL != nil, item.isDocumentEdited);
		return 1;
	}
	NSURL *checkpoint = [test URLByAppendingPathComponent:@"workspace.plist"];
	EditorWorkspace *workspace = [[EditorWorkspace alloc] initWithController:controller];
	if (!Check([workspace writeToURL:checkpoint error:&error], "checkpoint a modified file and an untitled draft"))
		return 1;
	[draft close];
	[document close];
	if (!Check([workspace restoreFromURL:checkpoint error:&error], "restore the workspace checkpoint"))
		return 1;
	document = (EditorDocument *)[controller documentForURL:output];
	draft = (EditorDocument *)controller.documents.lastObject;
	if (!Check(controller.documents.count == 2 && document.isDocumentEdited && draft.isDocumentEdited, "recover both unsaved tabs"))
	{
		fprintf(stderr, "Found saved file=%d, edited file=%d, edited draft=%d, tabs=%lu\n",
			document != nil, document.isDocumentEdited, draft.isDocumentEdited, controller.documents.count);
		for (EditorDocument *item in controller.documents)
			fprintf(stderr, "  reopened %s, saved=%d, edited=%d\n", item.displayName.UTF8String, item.fileURL != nil, item.isDocumentEdited);
		return 1;
	}
	if (!Check([draft.editor.string isEqualToString:@"Unsaved draft — черновик"] && [draft.editor message:SCI_GETSELECTIONEND] == 7,
			"recover the draft and its selection") ||
		!Check(draft.windowControllers.firstObject.window.visible && draft.editor.window == document.editor.window && controller.focusedDocument == document,
			"recover the split layout and focused pane") ||
		!Check([[document dataOfType:controller.defaultType error:&error] isEqualToData:[document.editor.string dataUsingEncoding:NSUTF8StringEncoding]] &&
		[[NSData dataWithContentsOfURL:output] isEqualToData:expected], "recover the changed encoding without modifying the disk copy"))
		return 1;
	[draft close];
	[document close];

	if (!Check([@"Changed outside the editor" writeToURL:output atomically:YES encoding:NSUTF8StringEncoding error:&error] &&
		[files setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:10]} ofItemAtPath:output.path error:&error],
		"change the disk copy between workspace launches"))
		return 1;
	if (!Check([workspace restoreFromURL:checkpoint error:&error], "restore after the original changed on disk"))
		return 1;
	EditorDocument *recovered = (EditorDocument *)controller.documents.firstObject;
	if (!Check(!recovered.fileURL && recovered.isDocumentEdited && [recovered.displayName hasPrefix:@"Recovered "] &&
		[recovered.editor.string hasPrefix:@"class пример"] &&
		[[NSString stringWithContentsOfURL:output encoding:NSUTF8StringEncoding error:&error] isEqualToString:@"Changed outside the editor"],
		"recover the older unsaved text as an untitled copy if the original changed on disk"))
		return 1;
	for (EditorDocument *openDocument in [controller.documents copy])
		[openDocument close];
	NSURL *recoveryDirectory = [test URLByAppendingPathComponent:@"workspace-lock" isDirectory:YES];
	EditorWorkspace *otherInstance = [[EditorWorkspace alloc] initWithController:controller];
	if (!Check([workspace startAtDirectory:recoveryDirectory] && ![otherInstance startAtDirectory:recoveryDirectory],
		"prevent another instance from overwriting the same recovery workspace"))
		return 1;
	puts("Passed: dockable panels, tab transfers and split rotation, monitoring, search and history, XML, native plugins, settings, editing commands, session recovery, terminal options, macros.");
	return 0;
}

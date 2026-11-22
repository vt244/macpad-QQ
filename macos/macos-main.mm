// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <cstring>

#import "EditorDocument.h"
#import "EditorChrome.h"
#import "EditorContextMenus.h"
#import "EditorPlugins.h"
#import "EditorResources.h"
#import "Scintilla.h"
#import "ScintillaView.h"

int RunSmokeTest(void);

@interface MacpadApplication : NSApplication
@end

@implementation MacpadApplication
- (void)sendEvent:(NSEvent *)event
{
	EditorDocumentController *documents = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	if (event.type == NSEventTypeKeyDown && event.keyCode == 48 &&
		(event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand | NSEventModifierFlagOption)) == NSEventModifierFlagControl &&
		!self.modalWindow && !event.window.attachedSheet &&
		[documents cycleRecentTabsBackwards:(event.modifierFlags & NSEventModifierFlagShift) != 0])
		return;
	if (event.type == NSEventTypeKeyDown && event.keyCode == 53 && [documents finishRecentTabSwitch:NO])
		return;
	if (event.type == NSEventTypeFlagsChanged && !(event.modifierFlags & NSEventModifierFlagControl))
		[documents finishRecentTabSwitch:YES];
	[super sendEvent:event];
}

- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender
{
	return [super sendAction:action to:target ?: [self targetForAction:action to:nil from:sender] from:sender];
}

- (id)targetForAction:(SEL)action to:(id)target from:(id)sender
{
	id resolved = [super targetForAction:action to:target from:sender];
	if (!target && (!resolved || [resolved isKindOfClass:EditorDocument.class]))
	{
		EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
		EditorDocument *focused = controller.focusedDocument;
		if ([focused respondsToSelector:action])
			return focused;
	}
	return resolved;
}
@end

@interface MacpadApp : NSObject <NSApplicationDelegate, NSMenuDelegate>
- (void)buildMenu;
@end

static NSString *Label(NSString *identifier, NSString *fallback)
{
	return [EditorResources.shared label:identifier fallback:fallback];
}

static NSMenu *AddMenu(NSMenu *parent, NSString *title)
{
	NSMenuItem *item = [parent addItemWithTitle:title action:nullptr keyEquivalent:@""];
	item.submenu = [[NSMenu alloc] initWithTitle:title];
	return item.submenu;
}

static NSMenuItem *AddItem(NSMenu *menu, NSString *title, SEL action, NSString *key, id target = nil)
{
	NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:key];
	item.target = target;
	return item;
}

static void AddEditorCommand(NSMenu *menu, NSString *title, unsigned int message, NSString *key = @"")
{
	AddItem(menu, title, @selector(runEditorCommand:), key).tag = message;
}

static void CopyText(NSString *text)
{
	NSPasteboard *clipboard = NSPasteboard.generalPasteboard;
	[clipboard clearContents];
	[clipboard setString:text forType:NSPasteboardTypeString];
}

static void AddCharacterSets(NSMenu *menu)
{
	NSMenu *sets = AddMenu(menu, Label(@"encoding-characterSets", @"Character Set"));
	struct Entry { unsigned int page; NSInteger idOffset; NSString *title; };
	const Entry arabic[] = {{1256, 6, @"Windows-1256"}, {28596, 14, @"ISO 8859-6"}, {720, 25, @"OEM 720"}};
	const Entry baltic[] = {{1257, 7, @"Windows-1257"}, {28594, 12, @"ISO 8859-4"}, {28603, 20, @"ISO 8859-13"}, {775, 27, @"OEM 775"}};
	const Entry celtic[] = {{28604, 21, @"ISO 8859-14"}};
	const Entry central[] = {{1250, 0, @"Windows-1250"}, {28592, 10, @"ISO 8859-2"}, {852, 29, @"OEM 852"}};
	const Entry chinese[] = {{950, 40, @"Big5"}, {936, 41, @"GB2312"}};
	const Entry cyrillic[] = {{1251, 1, @"Windows-1251"}, {28595, 13, @"ISO 8859-5"}, {855, 30, @"OEM 855"},
		{866, 38, @"OEM 866"}, {10007, 46, @"Mac Cyrillic"}, {21866, 47, @"KOI8-U"}, {20866, 48, @"KOI8-R"}};
	const Entry eastern[] = {{28593, 11, @"ISO 8859-3"}};
	const Entry greek[] = {{1253, 3, @"Windows-1253"}, {28597, 15, @"ISO 8859-7"}, {737, 26, @"OEM 737"}, {869, 39, @"OEM 869"}};
	const Entry hebrew[] = {{1255, 5, @"Windows-1255"}, {28598, 16, @"ISO 8859-8"}, {862, 35, @"OEM 862"}};
	const Entry japanese[] = {{932, 42, @"Shift JIS"}};
	const Entry korean[] = {{949, 43, @"Windows-949"}, {51949, 44, @"EUC-KR"}};
	const Entry northern[] = {{28594, 12, @"ISO 8859-4"}, {861, 34, @"OEM 861"}, {865, 37, @"OEM 865"}};
	const Entry thai[] = {{874, 45, @"TIS-620"}};
	const Entry turkish[] = {{1254, 4, @"Windows-1254"}, {28599, 17, @"ISO 8859-9"}, {857, 31, @"OEM 857"}};
	const Entry western[] = {{1252, 2, @"Windows-1252"}, {28591, 9, @"ISO 8859-1"}, {28605, 22, @"ISO 8859-15"},
		{437, 24, @"OEM 437"}, {850, 28, @"OEM 850"}, {858, 32, @"OEM 858"}, {860, 33, @"OEM 860"}, {863, 36, @"OEM 863"}};
	const Entry vietnamese[] = {{1258, 8, @"Windows-1258"}};
	auto add = [&](NSString *id, NSString *title, const auto &entries) {
		NSMenu *group = AddMenu(sets, Label(id, title));
		for (const auto &entry : entries)
		{
			CFStringEncoding cf = CFStringConvertWindowsCodepageToEncoding(entry.page);
			if (cf == kCFStringEncodingInvalidId || !CFStringIsEncodingAvailable(cf))
				continue;
			NSStringEncoding encoding = CFStringConvertEncodingToNSStringEncoding(cf);
			AddItem(group, Label([@(45020 + entry.idOffset) stringValue], entry.title), @selector(reinterpretEncoding:), @"").tag = encoding;
		}
		if (!group.numberOfItems)
			[sets removeItemAtIndex:sets.numberOfItems - 1];
	};
	add(@"encoding-arabic", @"Arabic", arabic);
	add(@"encoding-baltic", @"Baltic", baltic);
	add(@"encoding-celtic", @"Celtic", celtic);
	add(@"encoding-centralEuropean", @"Central European", central);
	add(@"encoding-chinese", @"Chinese", chinese);
	add(@"encoding-cyrillic", @"Cyrillic", cyrillic);
	add(@"encoding-easternEuropean", @"Eastern European", eastern);
	add(@"encoding-greek", @"Greek", greek);
	add(@"encoding-hebrew", @"Hebrew", hebrew);
	add(@"encoding-japanese", @"Japanese", japanese);
	add(@"encoding-korean", @"Korean", korean);
	add(@"encoding-northEuropean", @"North European", northern);
	add(@"encoding-thai", @"Thai", thai);
	add(@"encoding-turkish", @"Turkish", turkish);
	add(@"encoding-westernEuropean", @"Western European", western);
	add(@"encoding-vietnamese", @"Vietnamese", vietnamese);
}

@implementation MacpadApp
{
	EditorPlugins *_plugins;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
	_plugins = [[EditorPlugins alloc] initWithDirectory:[EditorResources.shared.profile URLByAppendingPathComponent:@"plugins"]];
	[self buildMenu];

}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)app
{
	return ![NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"] &&
		NSDocumentController.sharedDocumentController.documents.count == 0;
}

- (void)applicationDidResignActive:(NSNotification *)notification
{
	[(EditorDocumentController *)NSDocumentController.sharedDocumentController finishRecentTabSwitch:NO];
}

- (void)buildMenu
{
	NSMenu *main = [[NSMenu alloc] initWithTitle:@""];
	NSMenu *application = AddMenu(main, @"macpad++");
	AddItem(application, Label(@"app-about", @"About macpad++"), @selector(showAbout:), @"", self);
	AddItem(application, Label(@"app-license", @"License…"), @selector(showLicense:), @"", self);
	[application addItem:NSMenuItem.separatorItem];
	AddItem(application, Label(@"app-hide", @"Hide macpad++"), @selector(hide:), @"h", NSApp);
	AddItem(application, Label(@"app-quit", @"Quit macpad++"), @selector(terminate:), @"q", NSApp);

	NSDocumentController *documents = NSDocumentController.sharedDocumentController;
	NSMenu *file = AddMenu(main, Label(@"file", @"File"));
	AddItem(file, Label(@"41001", @"New"), @selector(newDocument:), @"n", documents);
	AddItem(file, Label(@"41002", @"Open…"), @selector(openFiles:), @"o", self);
	AddItem(file, Label(@"41022", @"Open Folder as Workspace…"), @selector(chooseWorkspaceFolders:), @"", documents);
	NSMenu *containingFolder = AddMenu(file, Label(@"file-openFolder", @"Open Containing Folder"));
	AddItem(containingFolder, Label(@"native-showSelectionInFinder", @"Show in Finder"), @selector(runTabFileCommand:), @"", self).tag = 41019;
	AddItem(containingFolder, Label(@"41025", @"Folder as Workspace"), @selector(runTabFileCommand:), @"", self).tag = 41025;
	AddItem(file, Label(@"41023", @"Open in Default Viewer"), @selector(runTabFileCommand:), @"", self).tag = 41023;
	AddItem(file, Label(@"41003", @"Close"), @selector(closeEditorTab:), @"w");
	AddItem(file, Label(@"41004", @"Close All"), @selector(closeAll:), @"", self);
	NSMenu *closeMultiple = AddMenu(file, Label(@"file-closeMore", @"Close Multiple Documents"));
	const NSInteger closeIDs[] = {41005, 41026, 41009, 41018, 41024};
	NSArray<NSString *> *closeNames = @[@"Close All but Active Document", @"Close All but Pinned Documents",
		@"Close All to the Left", @"Close All to the Right", @"Close All Unchanged"];
	for (NSUInteger i = 0; i < closeNames.count; ++i)
		AddItem(closeMultiple, Label([@(closeIDs[i]) stringValue], closeNames[i]), @selector(runTabFileCommand:), @"", self).tag = closeIDs[i];
	[file addItem:NSMenuItem.separatorItem];
	AddItem(file, Label(@"41006", @"Save"), @selector(saveDocument:), @"s");
	AddItem(file, Label(@"41007", @"Save All"), @selector(saveAllDocuments:), @"", documents);
	AddItem(file, Label(@"41008", @"Save As…"), @selector(saveDocumentAs:), @"S");
	AddItem(file, Label(@"41015", @"Save a Copy As…"), @selector(saveCopyAs:), @"");
	AddItem(file, Label(@"41017", @"Rename…"), @selector(runTabFileCommand:), @"", self).tag = 41017;
	AddItem(file, Label(@"41016", @"Move to Trash…"), @selector(moveFileToTrash:), @"");
	AddItem(file, Label(@"41014", @"Reload from Disk"), @selector(revertDocumentToSaved:), @"");
	[file addItem:NSMenuItem.separatorItem];
	AddItem(file, Label(@"41010", @"Print…"), @selector(printDocument:), @"p");
	[file addItem:NSMenuItem.separatorItem];

	NSMenu *edit = AddMenu(main, Label(@"edit", @"Edit"));
	AddItem(edit, Label(@"42003", @"Undo"), @selector(undo:), @"z");
	AddItem(edit, Label(@"42004", @"Redo"), @selector(redo:), @"Z");
	[edit addItem:NSMenuItem.separatorItem];
	AddItem(edit, Label(@"42001", @"Cut"), @selector(cut:), @"x");
	AddItem(edit, Label(@"42002", @"Copy"), @selector(copy:), @"c");
	AddItem(edit, Label(@"42005", @"Paste"), @selector(paste:), @"v");
	AddEditorCommand(edit, Label(@"42006", @"Delete"), SCI_CLEAR);
	AddItem(edit, Label(@"42007", @"Select All"), @selector(selectAll:), @"a");
	AddItem(edit, Label(@"42020", @"Begin/End Select"), @selector(beginOrEndSelection:), @"").tag = 42020;
	AddItem(edit, Label(@"42089", @"Begin/End Select in Column Mode"), @selector(beginOrEndSelection:), @"").tag = 42089;
	[edit addItem:NSMenuItem.separatorItem];
	NSMenu *lines = AddMenu(edit, Label(@"edit-lineOperations", @"Line Operations"));
	AddEditorCommand(lines, Label(@"42010", @"Duplicate Current Line"), SCI_LINEDUPLICATE, @"d");
	AddEditorCommand(lines, Label(@"42011", @"Transpose Current Line"), SCI_LINETRANSPOSE);
	AddEditorCommand(lines, Label(@"42014", @"Move Lines Up"), SCI_MOVESELECTEDLINESUP);
	AddEditorCommand(lines, Label(@"42015", @"Move Lines Down"), SCI_MOVESELECTEDLINESDOWN);
	const NSInteger lineIDs[] = {42012, 42013, 42055, 42056};
	NSArray<NSString *> *lineActions = @[@"Split Lines", @"Join Lines", @"Remove Empty Lines", @"Remove Empty Lines (Containing Blank Characters)"];
	for (NSUInteger i = 0; i < lineActions.count; ++i)
		AddItem(lines, Label([@(lineIDs[i]) stringValue], lineActions[i]), @selector(runWhitespaceCommand:), @"").tag = lineIDs[i];
	NSMenu *indent = AddMenu(edit, Label(@"edit-indent", @"Indent"));
	AddEditorCommand(indent, Label(@"42008", @"Increase Indent"), SCI_LINEINDENT);
	AddEditorCommand(indent, Label(@"42009", @"Decrease Indent"), SCI_LINEDEDENT);
	NSMenu *blanks = AddMenu(edit, Label(@"edit-blankOperations", @"Blank Operations"));
	const NSInteger blankIDs[] = {42024, 42042, 42043, 42044, 42045, 42046, 42054, 42053};
	NSArray<NSString *> *blankActions = @[@"Trim Trailing Space", @"Trim Leading Space", @"Trim Leading and Trailing Space",
		@"EOL to Space", @"Trim Both and EOL to Space", @"Tab to Space", @"Space to Tab (All)", @"Space to Tab (Leading)"];
	for (NSUInteger i = 0; i < blankActions.count; ++i)
		AddItem(blanks, Label([@(blankIDs[i]) stringValue], blankActions[i]), @selector(runWhitespaceCommand:), @"").tag = blankIDs[i];
	NSMenu *insert = AddMenu(edit, Label(@"edit-insert", @"Insert"));
	AddItem(insert, Label(@"42084", @"Date Time (Short)"), @selector(insertDateTime:), @"").tag = 42084;
	AddItem(insert, Label(@"42085", @"Date Time (Long)"), @selector(insertDateTime:), @"").tag = 42085;
	AddItem(insert, Label(@"42086", @"Date Time (Customized)"), @selector(insertDateTime:), @"").tag = 42086;
	NSMenu *specialPaste = AddMenu(edit, Label(@"edit-pasteSpecial", @"Paste Special"));
	NSArray<NSString *> *clipboardActions = @[@"Paste HTML Content", @"Paste RTF Content", @"Copy Binary Content",
		@"Cut Binary Content", @"Paste Binary Content"];
	const NSInteger clipboardIDs[] = {42038, 42039, 42048, 42049, 42050};
	for (NSUInteger i = 0; i < clipboardActions.count; ++i)
		AddItem(specialPaste, Label([@(clipboardIDs[i]) stringValue], clipboardActions[i]),
			@selector(specialClipboard:), @"").tag = clipboardIDs[i];
	NSMenu *selectionActions = AddMenu(edit, Label(@"edit-onSelection", @"On Selection"));
	const NSInteger selectionActionIDs[] = {42073, 42074, 42075, 42076, 42106};
	NSArray<NSString *> *selectionActionNames = @[@"Open File", @"Open Containing Folder in Finder",
		@"Search on Internet", @"Change Search Engine…", @"Redact Selection"];
	for (NSUInteger i = 0; i < selectionActionNames.count; ++i)
	{
		const NSInteger command = selectionActionIDs[i];
		NSString *title = command == 42074 ? Label(@"native-showSelectionInFinder", selectionActionNames[i]) :
			Label([@(command) stringValue], selectionActionNames[i]);
		AddItem(selectionActions, title, @selector(actOnSelection:), @"", self).tag = command;
	}
	NSMenu *copyPath = AddMenu(edit, Label(@"edit-copyToClipboard", @"Copy to Clipboard"));
	AddItem(copyPath, Label(@"42029", @"Copy Current File Path"), @selector(copyDocumentPath:), @"", self).tag = 42029;
	AddItem(copyPath, Label(@"42030", @"Copy Current Filename"), @selector(copyDocumentPath:), @"", self).tag = 42030;
	AddItem(copyPath, Label(@"42031", @"Copy Current Directory Path"), @selector(copyDocumentPath:), @"", self).tag = 42031;
	AddItem(copyPath, Label(@"42087", @"Copy All Filenames"), @selector(copyDocumentPath:), @"", self).tag = 42087;
	AddItem(copyPath, Label(@"42088", @"Copy All File Paths"), @selector(copyDocumentPath:), @"", self).tag = 42088;
	AddItem(edit, Label(@"42028", @"Read-Only on Current Document"), @selector(toggleDocumentReadOnly:), @"");
	NSMenu *letterCase = AddMenu(edit, Label(@"edit-convertCaseTo", @"Convert Case"));
	AddEditorCommand(letterCase, Label(@"42016", @"Uppercase"), SCI_UPPERCASE);
	AddEditorCommand(letterCase, Label(@"42017", @"Lowercase"), SCI_LOWERCASE);
	NSArray<NSString *> *caseNames = @[@"Proper Case", @"Proper Case (Blend)", @"Sentence Case",
		@"Sentence Case (Blend)", @"Invert Case", @"Random Case"];
	for (NSUInteger i = 0; i < caseNames.count; ++i)
		AddItem(letterCase, Label([@(42067 + i) stringValue], caseNames[i]), @selector(transformSelectionCase:), @"").tag = 42067 + i;
	NSMenu *lineEndings = AddMenu(edit, Label(@"edit-eolConversion", @"EOL Conversion"));
	AddItem(lineEndings, Label(@"45001", @"Windows (CR LF)"), @selector(convertLineEndings:), @"").tag = SC_EOL_CRLF;
	AddItem(lineEndings, Label(@"45002", @"Unix (LF)"), @selector(convertLineEndings:), @"").tag = SC_EOL_LF;
	AddItem(lineEndings, Label(@"45003", @"Macintosh (CR)"), @selector(convertLineEndings:), @"").tag = SC_EOL_CR;

	NSMenu *search = AddMenu(main, Label(@"search", @"Search"));
	AddItem(search, Label(@"43001", @"Find…"), @selector(findText:), @"f");
	AddItem(search, Label(@"43002", @"Find Next"), @selector(findNext:), @"g");
	AddItem(search, Label(@"43010", @"Find Previous"), @selector(findPrevious:), @"G");
	const NSInteger selectionSearchIDs[] = {43048, 43049, 43014, 43015};
	NSArray<NSString *> *selectionSearchNames = @[@"Select and Find Next", @"Select and Find Previous",
		@"Find (Volatile) Next", @"Find (Volatile) Previous"];
	for (NSUInteger i = 0; i < selectionSearchNames.count; ++i)
		AddItem(search, Label([@(selectionSearchIDs[i]) stringValue], selectionSearchNames[i]),
			@selector(findSelectedText:), @"").tag = selectionSearchIDs[i];
	AddItem(search, Label(@"43003", @"Replace…"), @selector(replaceText:), @"F");
	AddItem(search, Label(@"43011", @"Incremental Search"), @selector(incrementalSearch:), @"");
	NSMenuItem *findFiles = AddItem(search, Label(@"43013", @"Find in Files…"), @selector(findInFiles:), @"f");
	AddItem(search, Label(@"native-findInProjects", @"Find in Projects…"), @selector(findInProjects:), @"");
	findFiles.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption;
	AddItem(search, Label(@"43054", @"Mark…"), @selector(markText:), @"");
	AddItem(search, Label(@"43045", @"Search Results Window"), @selector(toggleSearchResults:), @"");
	NSMenuItem *nextResult = AddItem(search, Label(@"43046", @"Next Search Result"), @selector(stepSearchResult:),
		[NSString stringWithFormat:@"%C", (unichar)NSF4FunctionKey], documents);
	nextResult.tag = 1;
	nextResult.keyEquivalentModifierMask = 0;
	NSMenuItem *previousResult = AddItem(search, Label(@"43047", @"Previous Search Result"), @selector(stepSearchResult:),
		nextResult.keyEquivalent, documents);
	previousResult.tag = -1;
	previousResult.keyEquivalentModifierMask = NSEventModifierFlagShift;
	AddItem(search, Label(@"43004", @"Go to Line…"), @selector(goToLine:), @"l");
	AddItem(search, Label(@"43009", @"Go to Matching Brace"), @selector(findMatchingBrace:), @"").tag = 43009;
	AddItem(search, Label(@"43053", @"Select Between Matching Braces"), @selector(findMatchingBrace:), @"").tag = 43053;
	AddItem(search, Label(@"43052", @"Find Characters in Range…"), @selector(showCharacterRangeSearch:), @"");
	[search addItem:NSMenuItem.separatorItem];
	NSArray<NSString *> *styleMenus = @[@"Style All Occurrences of Token", @"Style One Token", @"Clear Style",
		@"Jump Up", @"Jump Down", @"Copy Styled Text"];
	NSArray<NSString *> *styleKeys = @[@"search-markAll", @"search-markOne", @"search-unmarkAll",
		@"search-jumpUp", @"search-jumpDown", @"search-copyStyledText"];
	const NSInteger styleStarts[] = {43022, 43062, 43023, 43033, 43039, 43055};
	for (NSUInteger group = 0; group < styleMenus.count; ++group)
	{
		NSMenu *styles = AddMenu(search, Label(styleKeys[group], styleMenus[group]));
		for (NSInteger style = 0; style < 5; ++style)
		{
			const NSInteger command = styleStarts[group] + style * (group == 0 || group == 2 ? 2 : 1);
			NSString *title = [NSString stringWithFormat:group == 2 ? @"Clear Style %ld" : @"Style %ld", style + 1];
			AddItem(styles, Label([@(command) stringValue], title), @selector(useMarkStyle:), @"").tag = command;
		}
		if (group == 2 || group == 5)
		{
			const NSInteger command = group == 2 ? 43032 : 43060;
			AddItem(styles, Label([@(command) stringValue], @"All Styles"), @selector(useMarkStyle:), @"").tag = command;
		}
		if (group >= 3)
		{
			const NSInteger command = group == 5 ? 43061 : styleStarts[group] + 5;
			AddItem(styles, Label([@(command) stringValue], @"Find Mark Style"), @selector(useMarkStyle:), @"").tag = command;
		}
	}
	[search addItem:NSMenuItem.separatorItem];
	NSMenu *bookmarks = AddMenu(search, Label(@"search-bookmark", @"Bookmark"));
	AddItem(bookmarks, Label(@"43005", @"Toggle Bookmark"), @selector(toggleBookmark:), @"");
	AddItem(bookmarks, Label(@"43006", @"Next Bookmark"), @selector(navigateBookmark:), @"").tag = 1;
	AddItem(bookmarks, Label(@"43007", @"Previous Bookmark"), @selector(navigateBookmark:), @"").tag = -1;
	AddItem(bookmarks, Label(@"43008", @"Clear All Bookmarks"), @selector(clearBookmarks:), @"");
	NSMenu *view = AddMenu(main, Label(@"view", @"View"));
	AddItem(view, Label(@"44034", @"Always on Top"), @selector(toggleAlwaysOnTop:), @"");
	AddItem(view, Label(@"44032", @"Toggle Full Screen"), @selector(toggleEditorFullScreen:), @"");
	AddItem(view, Label(@"44009", @"Post-It"), @selector(togglePresentationMode:), @"").tag = 1;
	AddItem(view, Label(@"44011", @"Distraction Free Mode"), @selector(togglePresentationMode:), @"").tag = 2;
	AddItem(view, Label(@"44022", @"Word Wrap"), @selector(toggleWrap:), @"");
	AddItem(view, Label(@"native-lineNumbers", @"Line Numbers"), @selector(toggleLineNumbers:), @"");
	NSMenu *symbols = AddMenu(view, Label(@"view-showSymbol", @"Show Symbol"));
	AddItem(symbols, Label(@"44025", @"Show Spaces and Tabs"), @selector(toggleSymbolDisplay:), @"").tag = 44025;
	AddItem(symbols, Label(@"44026", @"Show End of Line"), @selector(toggleSymbolDisplay:), @"").tag = 44026;
	AddItem(symbols, Label(@"44019", @"Show All Characters"), @selector(toggleInvisibles:), @"");
	AddItem(symbols, Label(@"44020", @"Show Indent Guide"), @selector(toggleIndentGuides:), @"");
	AddItem(symbols, Label(@"44041", @"Show Wrap Symbol"), @selector(toggleSymbolDisplay:), @"").tag = 44041;
	AddItem(view, Label(@"44070", @"Document List"), @selector(toggleDocumentList:), @"");
	AddItem(view, Label(@"44085", @"Folder as Workspace"), @selector(toggleFolderWorkspace:), @"", documents);
	NSMenu *projects = AddMenu(view, Label(@"view-project", @"Project Panels"));
	for (NSInteger index = 0; index < 3; ++index)
		AddItem(projects, Label([@(44081 + index) stringValue], [NSString stringWithFormat:@"Project Panel %ld", index + 1]),
			@selector(toggleProjectPanel:), @"", documents).tag = index;
	[view addItem:NSMenuItem.separatorItem];
	AddEditorCommand(view, Label(@"native-zoomIn", @"Zoom In"), SCI_ZOOMIN, @"=");
	AddEditorCommand(view, Label(@"native-zoomOut", @"Zoom Out"), SCI_ZOOMOUT, @"-");
	AddEditorCommand(view, Label(@"44033", @"Restore Default Zoom"), SCI_SETZOOM, @"0");
	AddItem(view, Label(@"44027", @"Synchronize Zoom Across Views"), @selector(toggleZoomSync:), @"");
	AddItem(view, Label(@"44010", @"Fold All"), @selector(setFoldState:), @"").tag = SC_FOLDACTION_CONTRACT;
	AddItem(view, Label(@"44029", @"Unfold All"), @selector(setFoldState:), @"").tag = SC_FOLDACTION_EXPAND;
	AddItem(view, Label(@"44030", @"Fold Current Level"), @selector(foldAtLevel:), @"").tag = 9;
	AddItem(view, Label(@"44031", @"Unfold Current Level"), @selector(foldAtLevel:), @"").tag = -9;
	for (NSInteger direction : {1, -1})
	{
		NSMenu *levels = AddMenu(view, direction > 0 ? Label(@"view-collapseLevel", @"Fold Level") :
			Label(@"view-uncollapseLevel", @"Unfold Level"));
		for (NSInteger level = 1; level <= 8; ++level)
			AddItem(levels, [@(level) stringValue], @selector(foldAtLevel:), @"").tag = direction * level;
	}
	AddItem(view, Label(@"44042", @"Hide Selected Lines"), @selector(hideSelectedLines:), @"");
	AddItem(view, Label(@"native-showHiddenLines", @"Show Hidden Lines"), @selector(showHiddenLines:), @"");
	AddItem(view, Label(@"44049", @"Summary…"), @selector(showDocumentSummary:), @"");
	AddItem(view, Label(@"44097", @"Monitoring (tail -f)"), @selector(monitorFile:), @"");
	[view addItem:NSMenuItem.separatorItem];
	NSMenu *moveDocument = AddMenu(view, Label(@"view-moveCloneDocument", @"Move/Clone Current Document"));
	AddItem(moveDocument, Label(@"10001", @"Move to Other View"), @selector(moveToOtherView:), @"");
	AddItem(moveDocument, Label(@"10002", @"Clone to Other View"), @selector(cloneToOtherView:), @"");
	NSMenu *tabs = AddMenu(view, Label(@"view-tab", @"Tab"));
	for (NSInteger number = 1; number <= 9; ++number)
		AddItem(tabs, Label([@(44085 + number) stringValue], [NSString stringWithFormat:@"Tab %ld", number]),
			@selector(navigateTab:), [@(number) stringValue], documents).tag = 44085 + number;
	[tabs addItem:NSMenuItem.separatorItem];
	const NSInteger tabCommands[] = {44116, 44117, 44095, 44096, 10005, 10006, 44098, 44099};
	NSArray<NSString *> *tabTitles = @[@"First Tab", @"Last Tab", @"Next Tab", @"Previous Tab", @"Move to Start",
		@"Move to End", @"Move Tab Forward", @"Move Tab Backward"];
	for (NSUInteger i = 0; i < tabTitles.count; ++i)
		AddItem(tabs, Label([@(tabCommands[i]) stringValue], tabTitles[i]), @selector(navigateTab:), @"", documents).tag = tabCommands[i];
	[tabs addItem:NSMenuItem.separatorItem];
	for (NSInteger color = 1; color <= 5; ++color)
		AddItem(tabs, Label([@(44110 + color) stringValue], [NSString stringWithFormat:@"Apply Color %ld", color]),
			@selector(navigateTab:), @"", documents).tag = 44110 + color;
	AddItem(tabs, Label(@"44110", @"Remove Color"), @selector(navigateTab:), @"", documents).tag = 44110;
	AddItem(view, Label(@"44035", @"Synchronize Vertical Scrolling"), @selector(toggleVerticalScrollSync:), @"");
	AddItem(view, Label(@"44036", @"Synchronize Horizontal Scrolling"), @selector(toggleHorizontalScrollSync:), @"");
	AddItem(view, Label(@"native-closeOtherView", @"Close Other View"), @selector(closeOtherView:), @"");
	AddItem(view, Label(@"44072", @"Focus on Another View"), @selector(focusAnotherView:), @"");
	AddItem(view, Label(@"42026", @"Right-to-Left Text"), @selector(setTextDirection:), @"").tag = SC_BIDIRECTIONAL_R2L;
	AddItem(view, Label(@"42027", @"Left-to-Right Text"), @selector(setTextDirection:), @"").tag = SC_BIDIRECTIONAL_L2R;
	NSMenu *themes = AddMenu(view, Label(@"native-theme", @"Theme"));
	NSMenuItem *standard = AddItem(themes, Label(@"native-default", @"Default"), @selector(selectTheme:), @"", self);
	standard.state = EditorResources.shared.selectedTheme ? NSControlStateValueOff : NSControlStateValueOn;
	[self fillCatalog:themes theme:YES];

	NSMenu *encoding = AddMenu(main, Label(@"encoding", @"Encoding"));
	AddCharacterSets(encoding);
	[encoding addItem:NSMenuItem.separatorItem];
	const struct { NSString *id; NSString *title; NSStringEncoding encoding; const char *bom; NSUInteger length; } encodings[] = {
		{@"45009", @"Convert to ANSI", NSWindowsCP1252StringEncoding, nullptr, 0},
		{@"45010", @"Convert to UTF-8", NSUTF8StringEncoding, nullptr, 0},
		{@"45011", @"Convert to UTF-8-BOM", NSUTF8StringEncoding, "\xef\xbb\xbf", 3},
		{@"45012", @"Convert to UTF-16 BE BOM", NSUTF16BigEndianStringEncoding, "\xfe\xff", 2},
		{@"45013", @"Convert to UTF-16 LE BOM", NSUTF16LittleEndianStringEncoding, "\xff\xfe", 2},
	};
	for (const auto &entry : encodings)
	{
		NSMenuItem *item = AddItem(encoding, Label(entry.id, entry.title), @selector(convertEncoding:), @"");
		item.tag = entry.encoding;
		item.representedObject = entry.length ? [NSData dataWithBytes:entry.bom length:entry.length] : nil;
	}

	EditorResources *resources = EditorResources.shared;
	NSMenu *language = AddMenu(main, Label(@"language", @"Language"));
	AddItem(language, Label(@"native-detectLanguage", @"Detect from File Extension"), @selector(selectLanguage:), @"");
	AddItem(language, Label(@"native-normalText", @"Normal Text"), @selector(selectLanguage:), @"").representedObject = @"normal";
	[language addItem:NSMenuItem.separatorItem];
	NSDictionary<NSString *, NSString *> *languages = resources.languages;
	NSArray<NSString *> *keys = [languages keysSortedByValueUsingSelector:@selector(localizedStandardCompare:)];
	NSMutableDictionary<NSString *, NSMenu *> *groups = [NSMutableDictionary dictionary];
	for (NSString *key in keys)
	{
		if ([key isEqualToString:@"normal"])
			continue;
		NSString *name = languages[key];
		NSString *initial = [name substringToIndex:1].uppercaseString;
		NSMenu *group = groups[initial];
		if (!group)
			groups[initial] = group = AddMenu(language, initial);
		AddItem(group, name, @selector(selectLanguage:), @"").representedObject = key;
	}
	NSMenu *settings = AddMenu(main, Label(@"settings", @"Settings"));
	AddItem(settings, Label(@"native-editEditorMenu", @"Edit Editor Context Menu…"), @selector(editContextMenu:), @"", self);
	AddItem(settings, Label(@"native-editTabMenu", @"Edit Tab Context Menu…"), @selector(editContextMenu:), @"", self).tag = 1;
	NSMenu *translations = AddMenu(settings, Label(@"native-interfaceLanguage", @"Interface Language"));
	NSMenuItem *standardLanguage = AddItem(translations, Label(@"native-defaultLanguage", @"Default / nativeLang.xml"), @selector(selectTranslation:), @"", self);
	standardLanguage.state = EditorResources.shared.selectedTranslation ? NSControlStateValueOff : NSControlStateValueOn;
	[self fillCatalog:translations theme:NO];

	NSMenu *plugins = AddMenu(main, Label(@"Plugins", @"Plugins"));
	[_plugins populateMenu:plugins];

	NSMenu *window = AddMenu(main, Label(@"native-window", @"Window"));
	AddItem(window, Label(@"native-minimize", @"Minimize"), @selector(performMiniaturize:), @"m");
	AddItem(window, Label(@"native-zoomWindow", @"Zoom"), @selector(performZoom:), @"");
	NSMenu *help = AddMenu(main, @"?");
	AddItem(help, Label(@"app-about", @"About macpad++"), @selector(showAbout:), @"", self);
	AddItem(help, Label(@"app-license", @"License…"), @selector(showLicense:), @"", self);
	// AppKit adds system editing services to the menu bar. Keep the in-window menu scoped to editor commands.
	[main itemWithTitle:edit.title].representedObject = [edit copy];
	NSApp.mainMenu = main;
	NSApp.windowsMenu = window;
	for (EditorDocument *document in documents.documents)
		[document refreshChromeMenus];
}

- (void)editContextMenu:(NSMenuItem *)sender
{
	BOOL tabs = sender.tag == 1;
	NSURL *folder = EditorResources.shared.profile;
	NSURL *url = [folder URLByAppendingPathComponent:tabs ? @"tabContextMenu.xml" : @"contextMenu.xml"];
	NSError *error = nil;
	NSFileManager *files = NSFileManager.defaultManager;
	if (![files createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&error])
	{
		[NSApp presentError:error];
		return;
	}
	if (![files fileExistsAtPath:url.path])
	{
		NSString *section = tabs ? @"TabContextMenu" : @"ScintillaContextMenu";
		NSString *commands = tabs ? @"\t\t<Item id=\"41003\" />\n\t\t<Item id=\"44048\" />\n\t\t<Item id=\"41006\" />\n" :
			@"\t\t<Item id=\"42001\" />\n\t\t<Item id=\"42002\" />\n\t\t<Item id=\"42005\" />\n\t\t<Item id=\"0\" />\n\t\t<Item id=\"43001\" />\n";
		NSString *xml = [NSString stringWithFormat:@"<NotepadPlus>\n\t<%@>\n%@\t</%@>\n</NotepadPlus>\n", section, commands, section];
		if (![[xml dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url options:NSDataWritingWithoutOverwriting error:&error])
		{
			[NSApp presentError:error];
			return;
		}
	}
	[self openDocuments:@[url]];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorDocument *document = controller.focusedDocument;
	if (item.action == @selector(runTabFileCommand:))
		return document && EditorCanRunTabCommand(document, item.tag);
	if (item.action == @selector(actOnSelection:))
		return item.tag == 42076 || (![[document editor] message:SCI_GETSELECTIONEMPTY] &&
			document && (item.tag != 42106 || ![document.editor message:SCI_GETREADONLY]));
	if (item.action == @selector(copyDocumentPath:))
		return item.tag >= 42087 ? controller.tabDocuments.count > 0 : document.fileURL != nil;
	return YES;
}

- (void)openRecentFile:(NSMenuItem *)item
{
	[NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:item.representedObject display:YES
		completionHandler:^(NSDocument *document, BOOL alreadyOpen, NSError *error) {
			if (error)
				[NSApp presentError:error];
		}];
}

- (void)runTabFileCommand:(NSMenuItem *)item
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorRunTabCommand(controller.focusedDocument, item.tag);
}

static NSArray<NSArray<NSString *> *> *SearchEngines()
{
	return @[@[@"DuckDuckGo", @"https://duckduckgo.com/", @"q"],
		@[@"Google", @"https://www.google.com/search", @"q"], @[@"Bing", @"https://www.bing.com/search", @"q"],
		@[@"Wikipedia", @"https://en.wikipedia.org/w/index.php", @"search"], @[@"Yahoo", @"https://search.yahoo.com/search", @"p"],
		@[@"Stack Overflow", @"https://stackoverflow.com/search", @"q"]];
}

static NSURL *CustomSearchURL(NSString *pattern, NSString *query)
{
	NSString *placeholder = @"$(CURRENT_WORD)";
	if (![pattern containsString:placeholder])
		return nil;
	NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
		@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
	NSString *escaped = [query stringByAddingPercentEncodingWithAllowedCharacters:allowed];
	NSURLComponents *url = [NSURLComponents componentsWithString:[pattern stringByReplacingOccurrencesOfString:placeholder
		withString:escaped ?: @""]];
	if ((![[url.scheme lowercaseString] isEqual:@"https"] && ![[url.scheme lowercaseString] isEqual:@"http"]) ||
		!url.host.length || url.user || url.password)
		return nil;
	return url.URL;
}

- (void)actOnSelection:(NSMenuItem *)item
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorDocument *document = controller.focusedDocument;
	ScintillaView *editor = document.editor;
	NSInteger engine = [[EditorResources.shared setting:@"searchEngine" fallback:@0] integerValue];
	NSArray<NSArray<NSString *> *> *engines = SearchEngines();
	if (engine < 0 || engine > engines.count)
		engine = 0;
	if (item.tag == 42076)
	{
		NSAlert *prompt = [NSAlert new];
		prompt.messageText = Label(@"42076", @"Change Search Engine");
		[prompt addButtonWithTitle:Label(@"native-apply", @"Apply")];
		[prompt addButtonWithTitle:Label(@"native-cancel", @"Cancel")];
		NSPopUpButton *choices = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 260, 26) pullsDown:NO];
		for (NSArray<NSString *> *entry in engines)
			[choices addItemWithTitle:entry.firstObject];
		[choices addItemWithTitle:Label(@"custom-search-engine", @"Custom")];
		[choices selectItemAtIndex:engine];
		NSTextField *custom = [NSTextField textFieldWithString:[EditorResources.shared setting:@"searchEngineCustom" fallback:@""]];
		custom.placeholderString = @"https://example.com/search?q=$(CURRENT_WORD)";
		[custom setAccessibilityLabel:Label(@"custom-search-url", @"Custom search URL")];
		NSStackView *form = [NSStackView stackViewWithViews:@[choices, custom]];
		form.orientation = NSUserInterfaceLayoutOrientationVertical;
		form.frame = NSMakeRect(0, 0, 450, 61);
		prompt.accessoryView = form;
		while ([prompt runModal] == NSAlertFirstButtonReturn)
		{
			if (choices.indexOfSelectedItem == engines.count && !CustomSearchURL(custom.stringValue, @"example"))
			{
				prompt.informativeText = Label(@"custom-search-invalid", @"Enter an HTTP or HTTPS URL containing $(CURRENT_WORD).");
				continue;
			}
			[EditorResources.shared setSettings:@{@"searchEngine": @(choices.indexOfSelectedItem), @"searchEngineCustom": custom.stringValue}];
			break;
		}
		return;
	}
	NSString *selection = editor.selectedString;
	if (!selection.length)
		return;
	if (item.tag == 42106)
	{
		if ([editor message:SCI_GETREADONLY])
			return;
		NSMutableString *redacted = [NSMutableString string];
		BOOL dots = (NSEvent.modifierFlags & NSEventModifierFlagShift) != 0;
		[selection enumerateSubstringsInRange:NSMakeRange(0, selection.length)
			options:NSStringEnumerationByComposedCharacterSequences
			usingBlock:^(NSString *substring, NSRange range, NSRange enclosing, BOOL *stop) {
				BOOL whitespace = [substring rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet.invertedSet].location == NSNotFound;
				[redacted appendString:whitespace ? substring : dots ? @"●" : @"█"];
			}];
		[editor message:SCI_REPLACESEL wParam:0 lParam:reinterpret_cast<sptr_t>(redacted.UTF8String)];
		return;
	}
	NSString *value = [selection stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if (!value.length)
		return;
	if (item.tag == 42075)
	{
		if (engine == engines.count)
		{
			NSURL *custom = CustomSearchURL([EditorResources.shared setting:@"searchEngineCustom" fallback:@""], value);
			if (custom)
				[NSWorkspace.sharedWorkspace openURL:custom];
			else
				NSBeep();
			return;
		}
		NSURLComponents *url = [NSURLComponents componentsWithString:engines[engine][1]];
		url.queryItems = @[[NSURLQueryItem queryItemWithName:engines[engine][2] value:value]];
		[NSWorkspace.sharedWorkspace openURL:url.URL];
		return;
	}
	NSString *path = value.stringByExpandingTildeInPath;
	if (!path.isAbsolutePath)
		path = [(document.fileURL.URLByDeletingLastPathComponent.path ?: NSHomeDirectory()) stringByAppendingPathComponent:path];
	NSURL *url = [NSURL fileURLWithPath:path.stringByStandardizingPath];
	if (item.tag == 42074)
		[NSWorkspace.sharedWorkspace openURL:url.URLByDeletingLastPathComponent];
	else
	{
		NSMenuItem *file = [NSMenuItem new];
		file.representedObject = url;
		[self openRecentFile:file];
	}
}

- (void)copyDocumentPath:(NSMenuItem *)item
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	if (item.tag >= 42087)
	{
		NSMutableArray<NSString *> *files = [NSMutableArray array];
		for (EditorDocument *document in controller.tabDocuments)
			if (item.tag == 42087 || document.fileURL)
				[files addObject:item.tag == 42087 ? document.displayName : document.fileURL.path];
		EditorCopyText([files componentsJoinedByString:@"\n"]);
		return;
	}
	NSURL *url = controller.focusedDocument.fileURL;
	if (!url)
		return;
	NSString *value = item.tag == 42030 ? url.lastPathComponent : item.tag == 42031 ? url.URLByDeletingLastPathComponent.path : url.path;
	CopyText(value);
}

- (void)closeAll:(id)sender
{
	[NSDocumentController.sharedDocumentController closeAllDocumentsWithDelegate:self
		didCloseAllSelector:@selector(documents:didCloseAll:contextInfo:) contextInfo:nullptr];
}

- (void)documents:(NSDocumentController *)controller didCloseAll:(BOOL)closed contextInfo:(void *)context
{
	if (closed)
		[controller newDocument:nil];
}

- (void)fillCatalog:(NSMenu *)menu theme:(BOOL)theme
{
	EditorResources *resources = EditorResources.shared;
	NSDictionary<NSString *, NSURL *> *entries = theme ? resources.themes : resources.translations;
	NSURL *selected = theme ? resources.selectedTheme : resources.selectedTranslation;
	for (NSString *name in [entries.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)])
	{
		NSURL *url = entries[name];
		NSString *title = theme ? name.stringByDeletingPathExtension : [resources translationName:url];
		NSMenuItem *item = AddItem(menu, title, theme ? @selector(selectTheme:) : @selector(selectTranslation:), @"", self);
		item.representedObject = url;
		item.state = [url isEqual:selected] ? NSControlStateValueOn : NSControlStateValueOff;
	}
	[menu addItem:NSMenuItem.separatorItem];
	NSMenuItem *item = AddItem(menu, Label(@"native-importXML", @"Import XML…"), @selector(importXML:), @"", self);
	item.tag = theme;
}

- (void)selectTheme:(NSMenuItem *)sender
{
	[EditorResources.shared chooseTheme:sender.representedObject];
	for (EditorDocument *document in NSDocumentController.sharedDocumentController.documents)
		[document applyTheme];
	[self buildMenu];
}

- (void)selectTranslation:(NSMenuItem *)sender
{
	[EditorResources.shared chooseTranslation:sender.representedObject];
	[self buildMenu];
}

- (void)importXML:(NSMenuItem *)sender
{
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowedContentTypes = @[UTTypeXML];
	if ([panel runModal] != NSModalResponseOK)
		return;
	NSError *error = nil;
	NSURL *result = [EditorResources.shared importXML:panel.URL theme:sender.tag error:&error];
	if (!result)
	{
		[NSApp presentError:error];
		return;
	}
	NSMenuItem *selection = [[NSMenuItem alloc] init];
	selection.representedObject = result;
	if (sender.tag)
		[self selectTheme:selection];
	else
		[self selectTranslation:selection];
}

- (void)openFiles:(id)sender
{
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowsMultipleSelection = YES;
	if ([panel runModal] != NSModalResponseOK)
		return;
	[self openDocuments:panel.URLs];
}

- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls
{
	[self openDocuments:urls];
}

- (void)openDocuments:(NSArray<NSURL *> *)urls
{
	NSDocumentController *documents = NSDocumentController.sharedDocumentController;
	for (NSURL *url in urls)
	{
		if (!url.isFileURL)
			continue;
		[documents openDocumentWithContentsOfURL:url display:YES completionHandler:^(NSDocument *document, BOOL alreadyOpen, NSError *error) {
			if (error)
				[NSApp presentError:error];
		}];
	}
}

- (void)showLicense:(id)sender
{
	NSURL *license = [NSBundle.mainBundle URLForResource:@"LICENSE" withExtension:nil];
	NSString *contents = license ? [NSString stringWithContentsOfURL:license encoding:NSUTF8StringEncoding error:nullptr] : nil;
	if (!contents)
		return;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"macpad++ License";
	NSScrollView *view = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 540, 360)];
	view.hasVerticalScroller = YES;
	NSTextView *text = [[NSTextView alloc] initWithFrame:view.contentView.bounds];
	text.string = contents;
	text.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
	text.autoresizingMask = NSViewWidthSizable;
	text.editable = NO;
	view.documentView = text;
	alert.accessoryView = view;
	[alert runModal];
}

- (void)showAbout:(id)sender
{
	[NSApp orderFrontStandardAboutPanelWithOptions:@{
		NSAboutPanelOptionCredits: [[NSAttributedString alloc] initWithString:
			@"Independent fork of Notepad++ by Don Ho and contributors.\n"
			@"Built with Scintilla and Lexilla. Distributed under GNU GPL version 3.\n"
			@"This software comes without warranty. See License in the macpad++ menu."]
	}];
}
@end

int main(int argc, const char *argv[])
{
	@autoreleasepool
	{
		NSApplication *app = MacpadApplication.sharedApplication;
		__attribute__((objc_precise_lifetime)) EditorDocumentController *documents = [[EditorDocumentController alloc] init];
		__attribute__((objc_precise_lifetime)) MacpadApp *delegate = [[MacpadApp alloc] init];
		app.delegate = delegate;
		[app setActivationPolicy:NSApplicationActivationPolicyRegular];
		if (argc == 2 && strcmp(argv[1], "--smoke-test") == 0)
		{
			[app finishLaunching];
			return RunSmokeTest();
		}
		[app run];
		(void)documents;
		(void)delegate;
	}
	return 0;
}

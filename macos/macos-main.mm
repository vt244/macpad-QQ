// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <cstring>

#import "EditorDocument.h"
#import "EditorChrome.h"
#import "EditorContextMenus.h"
#import "EditorHash.h"
#import "EditorLaunchOptions.h"
#import "EditorMacros.h"
#import "EditorPlugins.h"
#import "EditorPluginCatalog.h"
#import "EditorResources.h"
#import "EditorRun.h"
#import "EditorSettings.h"
#import "Scintilla.h"
#import "ScintillaView.h"

int RunSmokeTest(void);
void RunWorkspaceLifecycleTest(BOOL restore);

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

- (BOOL)restoreWindowWithIdentifier:(NSUserInterfaceItemIdentifier)identifier state:(NSCoder *)state
	completionHandler:(void (^)(NSWindow *, NSError *))completionHandler
{
	// The editor workspace restores document groups, splits, and unsaved content together.
	return NO;
}

- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender
{
	return [super sendAction:action to:target ?: [self targetForAction:action to:nil from:sender] from:sender];
}

- (id)targetForAction:(SEL)action to:(id)target from:(id)sender
{
	NSWindow *window = self.modalWindow ?: self.keyWindow;
	NSResponder *responder = window.firstResponder;
	if (!target && [responder isKindOfClass:NSTextView.class] &&
		(action == @selector(paste:) || action == @selector(copy:) || action == @selector(cut:) ||
		action == @selector(selectAll:) || action == @selector(undo:) || action == @selector(redo:)) &&
		[responder respondsToSelector:action])
		return responder;
	id resolved = [super targetForAction:action to:target from:sender];
	if (!target && !self.modalWindow && !window.attachedSheet && (!resolved || [resolved isKindOfClass:EditorDocument.class]))
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
@property(nonatomic, strong) EditorLaunchOptions *launchOptions;
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

static void AlignEditMenu(NSMenu *menu)
{
	NSDictionary<NSString *, NSString *> *symbols = @{@"undo:": @"arrow.uturn.backward", @"redo:": @"arrow.uturn.forward",
		@"cut:": @"scissors", @"copy:": @"document.on.document", @"paste:": @"clipboard", @"selectAll:": @"selection.pin.in.out"};
	NSImage *empty = [NSImage imageWithSize:NSMakeSize(15, 15) flipped:NO drawingHandler:^BOOL(NSRect rect) { return YES; }];
	[empty setTemplate:YES];
	for (NSMenuItem *item in menu.itemArray)
	{
		if (item.separatorItem)
			continue;
		NSString *symbol = item.action ? symbols[NSStringFromSelector(item.action)] : nil;
		NSImage *image = symbol ? [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] : nil;
		item.image = image ? [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13
			weight:NSFontWeightRegular]] : empty;
	}
}

static NSString *HashName(EditorHashAlgorithm algorithm)
{
	return @[@"MD5", @"SHA-1", @"SHA-256", @"SHA-512"][algorithm];
}

static NSScrollView *HashTextView(NSString *text, BOOL editable)
{
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 480, 180)];
	scroll.borderType = NSBezelBorder;
	scroll.hasVerticalScroller = YES;
	NSTextView *view = [[NSTextView alloc] initWithFrame:scroll.bounds];
	view.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
	view.richText = NO;
	view.editable = editable;
	view.string = text;
	view.autoresizingMask = NSViewWidthSizable;
	scroll.documentView = view;
	return scroll;
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
	NSMenu *_macroMenu;
	NSMenu *_recentMenu;
	NSInteger _macroMenuBaseItems;
	NSString *_lastRunCommand;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
	if (!self.launchOptions.noPlugins)
		_plugins = [[EditorPlugins alloc] initWithDirectory:[EditorResources.shared.profile URLByAppendingPathComponent:@"plugins"]];
	if (self.launchOptions.translation.length)
	{
		EditorResources *resources = EditorResources.shared;
		NSDictionary *languages = @{@"ru": @"russian", @"en": @"english", @"fr": @"french", @"de": @"german",
			@"it": @"italian", @"es": @"spanish", @"ja": @"japanese", @"ko": @"korean", @"zh": @"chineseSimplified"};
		NSString *requested = languages[self.launchOptions.translation] ?: self.launchOptions.translation;
		for (NSString *name in resources.translations)
			if ([name.stringByDeletingPathExtension caseInsensitiveCompare:requested] == NSOrderedSame)
			{
				[resources chooseTranslation:resources.translations[name]];
				break;
			}
	}
	[self buildMenu];
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(macroLibraryChanged:)
		name:EditorMacroLibraryDidChange object:EditorMacroLibrary.shared];
	if (!self.launchOptions.noSession && [[EditorResources.shared setting:@"rememberSession" fallback:@YES] boolValue] &&
		![NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"])
	{
		EditorDocumentController *documents = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
		[documents startWorkspaceRecoveryAtDirectory:[EditorResources.shared.profile URLByAppendingPathComponent:@"recovery" isDirectory:YES]];
	}
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)app
{
	return ![NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"] &&
		!self.launchOptions.paths.count &&
		NSDocumentController.sharedDocumentController.documents.count == 0;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
	BOOL write = [arguments containsObject:@"--smoke-workspace-write"];
	BOOL restore = [arguments containsObject:@"--smoke-workspace-restore"];
	if (write || restore)
		dispatch_async(dispatch_get_main_queue(), ^{ RunWorkspaceLifecycleTest(restore); });
	else if (self.launchOptions.paths.count)
		dispatch_async(dispatch_get_main_queue(), ^{ [self openLaunchPaths]; });
}

- (void)openLaunchPaths
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorLaunchOptions *options = self.launchOptions;
	for (NSURL *url in options.paths)
	{
		NSNumber *directory = nil;
		[url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nullptr];
		if (directory.boolValue && options.openFoldersAsWorkspace)
			[controller addWorkspaceFolders:@[url]];
		else if (options.openSession)
		{
			NSError *error = nil;
			if (![controller loadSessionFromURL:url error:&error] && error)
				[NSApp presentError:error];
		}
		else
			[controller openDocumentWithContentsOfURL:url display:YES completionHandler:^(NSDocument *opened, BOOL wasOpen, NSError *error) {
				if (error)
				{
					[NSApp presentError:error];
					return;
				}
				EditorDocument *document = (EditorDocument *)opened;
				if (options.language.length)
				{
					NSMenuItem *language = [NSMenuItem new];
					language.representedObject = options.language;
					[document selectLanguage:language];
				}
				if (options.readOnly)
					[document.editor message:SCI_SETREADONLY wParam:1];
				if (options.monitor)
					[document monitorFile:nil];
				if (options.hideTabs)
					[document.chrome setTabsHidden:YES];
				ScintillaView *editor = document.editor;
				if (options.position >= 0)
					[editor message:SCI_GOTOPOS wParam:MIN(options.position, [editor message:SCI_GETLENGTH])];
				else if (options.line || options.column)
				{
					auto line = MIN(MAX(0, options.line - 1), [editor message:SCI_GETLINECOUNT] - 1);
					auto position = [editor message:SCI_FINDCOLUMN wParam:line lParam:MAX(0, options.column - 1)];
					[editor message:SCI_GOTOPOS wParam:position];
				}
				[editor message:SCI_SCROLLCARET];
			}];
	}
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	[(EditorDocumentController *)NSDocumentController.sharedDocumentController finishWorkspaceRecovery];
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
	AddItem(application, Label(@"48011", @"Preferences…"), @selector(showPreferences:), @",", self);
	[application addItem:NSMenuItem.separatorItem];
	AddItem(application, Label(@"app-hide", @"Hide macpad++"), @selector(hide:), @"h", NSApp);
	AddItem(application, Label(@"app-quit", @"Quit macpad++"), @selector(terminate:), @"q", NSApp);

	NSDocumentController *documents = NSDocumentController.sharedDocumentController;
	NSMenu *file = AddMenu(main, Label(@"file", @"File"));
	AddItem(file, Label(@"41001", @"New"), @selector(newDocument:), @"n", documents);
	AddItem(file, Label(@"41002", @"Open…"), @selector(openFiles:), @"o", self);
	_recentMenu = AddMenu(file, Label(@"file-recentFiles", @"Recent Files"));
	_recentMenu.delegate = self;
	[self menuNeedsUpdate:_recentMenu];
	NSMenuItem *reopen = AddItem(file, Label(@"41021", @"Restore Last Closed File"), @selector(reopenClosedTab:), @"t", documents);
	reopen.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
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
	AddItem(file, Label(@"1001", @"Print Now"), @selector(printNow:), @"");
	[file addItem:NSMenuItem.separatorItem];
	AddItem(file, Label(@"41012", @"Load Session…"), @selector(loadSession:), @"", self);
	AddItem(file, Label(@"41013", @"Save Session…"), @selector(saveSession:), @"", self);

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
	AddItem(edit, Label(@"42034", @"Column Editor…"), @selector(showColumnEditor:), @"");
	for (NSInteger kind = 0; kind < 2; ++kind)
	{
		NSMenu *selection = AddMenu(edit, kind ? Label(@"edit-multiSelectNext", @"Multi-select Next") :
			Label(@"edit-multiSelectALL", @"Multi-select All"));
		NSArray *options = @[@"Ignore Case and Word Boundaries", @"Match Case Only", @"Match Whole Words Only", @"Match Case and Whole Words"];
		for (NSInteger option = 0; option < options.count; ++option)
		{
			const NSInteger command = 42090 + kind * 4 + option;
			AddItem(selection, Label([@(command) stringValue], options[option]), @selector(selectOccurrences:), @"").tag = command;
		}
	}
	AddItem(edit, Label(@"42098", @"Undo Latest Multi-Select"), @selector(adjustMatchingSelections:), @"").tag = 42098;
	AddItem(edit, Label(@"42099", @"Skip Current and Select Next"), @selector(adjustMatchingSelections:), @"").tag = 42099;
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
	[lines addItem:NSMenuItem.separatorItem];
	const NSInteger reorderIDs[] = {42079, 42077, 42083, 42078, 42059, 42060, 42080, 42081, 42100, 42101,
		42061, 42062, 42063, 42064, 42065, 42066, 42104, 42105};
	NSArray *reorderNames = @[@"Remove Duplicate Lines", @"Remove Consecutive Duplicate Lines", @"Reverse Line Order", @"Randomize Line Order",
		@"Sort Lexicographically Ascending", @"Sort Lexicographically Descending", @"Sort Ascending Ignoring Case", @"Sort Descending Ignoring Case",
		@"Sort in Locale Order Ascending", @"Sort in Locale Order Descending", @"Sort as Integers Ascending", @"Sort as Integers Descending",
		@"Sort as Decimals (Comma) Ascending", @"Sort as Decimals (Comma) Descending", @"Sort as Decimals (Dot) Ascending",
		@"Sort as Decimals (Dot) Descending", @"Sort by Length Ascending", @"Sort by Length Descending"];
	for (NSUInteger i = 0; i < reorderNames.count; ++i)
		AddItem(lines, Label([@(reorderIDs[i]) stringValue], reorderNames[i]), @selector(reorderLines:), @"").tag = reorderIDs[i];
	NSMenu *indent = AddMenu(edit, Label(@"edit-indent", @"Indent"));
	AddEditorCommand(indent, Label(@"42008", @"Increase Indent"), SCI_LINEINDENT);
	AddEditorCommand(indent, Label(@"42009", @"Decrease Indent"), SCI_LINEDEDENT);
	NSMenu *comments = AddMenu(edit, Label(@"edit-comment", @"Comment/Uncomment"));
	const NSInteger commentIDs[] = {42022, 42035, 42036, 42023, 42047};
	NSArray *commentNames = @[@"Toggle Single Line Comment", @"Single Line Comment", @"Single Line Uncomment", @"Block Comment", @"Block Uncomment"];
	for (NSUInteger i = 0; i < commentNames.count; ++i)
		AddItem(comments, Label([@(commentIDs[i]) stringValue], commentNames[i]), @selector(commentSelection:), i == 0 ? @"/" : @"").tag = commentIDs[i];
	NSMenu *completion = AddMenu(edit, Label(@"edit-autoCompletion", @"Auto-Completion"));
	const NSInteger completionIDs[] = {50000, 50001, 50002, 50010, 50011, 50006};
	NSArray *completionNames = @[@"Function Completion", @"Word Completion", @"Function Parameters Hint",
		@"Function Parameters Previous Hint", @"Function Parameters Next Hint", @"Path Completion"];
	for (NSUInteger i = 0; i < completionNames.count; ++i)
		AddItem(completion, Label([@(completionIDs[i]) stringValue], completionNames[i]), @selector(completeText:), @"").tag = completionIDs[i];
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
	AddItem(edit, Label(@"42052", @"Clipboard History"), @selector(toggleInsertPanel:), @"", documents).tag = 0;
	AddItem(edit, Label(@"42051", @"Character Panel"), @selector(toggleInsertPanel:), @"", documents).tag = 1;
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
	AlignEditMenu(edit);

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
	const NSInteger bookmarkIDs[] = {43018, 43019, 43020, 43021, 43051, 43050};
	NSArray *bookmarkNames = @[@"Cut Bookmarked Lines", @"Copy Bookmarked Lines", @"Paste to Bookmarked Lines", @"Remove Bookmarked Lines",
		@"Remove Non-Bookmarked Lines", @"Inverse Bookmarks"];
	for (NSUInteger i = 0; i < bookmarkNames.count; ++i)
		AddItem(bookmarks, Label([@(bookmarkIDs[i]) stringValue], bookmarkNames[i]),
			@selector(operateOnBookmarkedLines:), @"").tag = bookmarkIDs[i];
	NSMenu *changes = AddMenu(search, Label(@"search-changeHistory", @"Change History"));
	NSArray *changeNames = @[@"Go to Next Change", @"Go to Previous Change", @"Clear Change History"];
	for (NSUInteger i = 0; i < changeNames.count; ++i)
		AddItem(changes, Label([@(43067 + i) stringValue], changeNames[i]), @selector(navigateChanges:), @"").tag = 43067 + i;

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
	AddItem(view, Label(@"44084", @"Function List"), @selector(toggleFunctionList:), @"", documents);
	AddItem(view, Label(@"44080", @"Document Map"), @selector(toggleDocumentMap:), @"", documents);
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
	AddItem(moveDocument, Label(@"10003", @"Move to New Instance"), @selector(openDocumentInNewInstance:), @"", self).tag = 10003;
	AddItem(moveDocument, Label(@"10004", @"Open in New Instance"), @selector(openDocumentInNewInstance:), @"", self).tag = 10004;
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
	[language addItem:NSMenuItem.separatorItem];
	for (NSString *name in resources.userLanguages)
		AddItem(language, name, @selector(selectLanguage:), @"").representedObject = [@"udl:" stringByAppendingString:name];
	AddItem(language, Label(@"native-importUDL", @"Import User Defined Language…"), @selector(importUserLanguage:), @"", self);
	AddItem(language, Label(@"native-editUDL", @"Define or Edit User Language…"), @selector(editUserLanguage:), @"", self);
	AddItem(language, EditorUIString(@"Toggle User Language Panel"), @selector(toggleUDLPanel:), @"");
	AddItem(language, EditorUIString(@"Remove User Defined Language…"), @selector(removeUserLanguage:), @"", self);
	AddItem(language, Label(@"native-exportUDL", @"Export User Defined Language…"), @selector(exportUserLanguage:), @"", self);

	NSMenu *settings = AddMenu(main, Label(@"settings", @"Settings"));
	AddItem(settings, Label(@"48011", @"Preferences…"), @selector(showPreferences:), @"", self);
	AddItem(settings, Label(@"46001", @"Style Configurator…"), @selector(showStyleConfigurator:), @"", self);
	AddItem(settings, Label(@"48009", @"Shortcut Mapper…"), @selector(showShortcutMapper:), @"", self);
	AddItem(settings, Label(@"native-importConfig", @"Import Notepad++ Configuration…"), @selector(importWindowsConfiguration:), @"", self);
	AddItem(settings, Label(@"native-editEditorMenu", @"Edit Editor Context Menu…"), @selector(editContextMenu:), @"", self);
	AddItem(settings, Label(@"native-editTabMenu", @"Edit Tab Context Menu…"), @selector(editContextMenu:), @"", self).tag = 1;
	NSMenu *translations = AddMenu(settings, Label(@"native-interfaceLanguage", @"Interface Language"));
	NSMenuItem *standardLanguage = AddItem(translations, Label(@"native-defaultLanguage", @"Default / nativeLang.xml"), @selector(selectTranslation:), @"", self);
	standardLanguage.state = EditorResources.shared.selectedTranslation ? NSControlStateValueOff : NSControlStateValueOn;
	[self fillCatalog:translations theme:NO];

	NSMenu *tools = AddMenu(main, Label(@"tools", @"Tools"));
	NSArray<NSString *> *toolIDs = @[@"tools-md5", @"tools-sha1", @"tools-sha256", @"tools-sha512"];
	NSInteger firstIDs[] = {48501, 48507, 48504, 48510};
	for (NSInteger i = 0; i < toolIDs.count; ++i)
	{
		NSMenu *hash = AddMenu(tools, Label(toolIDs[i], HashName(static_cast<EditorHashAlgorithm>(i))));
		NSArray<NSString *> *actions = @[@"Generate…", @"Generate from files…", @"Generate from selection into clipboard"];
		for (NSInteger action = 0; action < actions.count; ++action)
		{
			NSString *key = [@(firstIDs[i] + action) stringValue];
			AddItem(hash, Label(key, actions[action]), @selector(generateHash:), @"", self).tag = i * actions.count + action;
		}
	}

	NSMenu *macro = AddMenu(main, Label(@"macro", @"Macro"));
	_macroMenu = macro;
	AddItem(macro, Label(@"42018", @"Start Recording"), @selector(startRecordingMacro:), @"");
	AddItem(macro, Label(@"42019", @"Stop Recording"), @selector(stopRecordingMacro:), @"");
	AddItem(macro, Label(@"42021", @"Playback"), @selector(playRecordedMacro:), @"");
	AddItem(macro, Label(@"42025", @"Save Current Recorded Macro…"), @selector(saveRecordedMacro:), @"");
	AddItem(macro, Label(@"42032", @"Run a Macro Multiple Times…"), @selector(repeatRecordedMacro:), @"");
	[macro addItem:NSMenuItem.separatorItem];
	AddItem(macro, Label(@"native-importMacros", @"Import Macros…"), @selector(importMacros:), @"", self);
	AddItem(macro, Label(@"native-deleteMacro", @"Delete Saved Macro…"), @selector(deleteSavedMacro:), @"", self);
	AddItem(macro, Label(@"native-modifyMacroShortcut", @"Modify Macro Shortcut…"), @selector(showShortcutMapper:), @"", self).tag = 1;
	_macroMenuBaseItems = macro.numberOfItems;
	macro.delegate = self;
	[self menuNeedsUpdate:macro];

	NSMenu *run = AddMenu(main, Label(@"run", @"Run"));
	NSMenuItem *runCommand = AddItem(run, Label(@"49000", @"Run…"), @selector(runExternalCommand:),
		[NSString stringWithFormat:@"%C", (unichar)NSF5FunctionKey], self);
	runCommand.keyEquivalentModifierMask = 0;
	NSDictionary<NSString *, NSString *> *runCommands = [EditorResources.shared setting:@"runCommands" fallback:@{}];
	if (runCommands.count)
	{
		AddItem(run, Label(@"48017", @"Manage Saved Commands…"), @selector(removeSavedRunCommand:), @"", self);
		[run addItem:NSMenuItem.separatorItem];
		for (NSString *name in [runCommands.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)])
			AddItem(run, name, @selector(executeSavedRunCommand:), @"", self).representedObject = name;
	}

	NSMenu *plugins = AddMenu(main, Label(@"Plugins", @"Plugins"));
	AddItem(plugins, Label(@"48014", @"Open Plugins Folder…"), @selector(openPluginsFolder:), @"", self);
	AddItem(plugins, Label(@"48015", @"Plugins Admin…"), @selector(managePlugins:), @"", self);
	AddItem(plugins, Label(@"native-pluginCatalogSource", @"Plugin Catalog Source…"), @selector(choosePluginCatalog:), @"", self);
	[plugins addItem:NSMenuItem.separatorItem];
	[_plugins populateMenu:plugins];

	NSMenu *window = AddMenu(main, Label(@"native-window", @"Window"));
	AddItem(window, Label(@"native-minimize", @"Minimize"), @selector(performMiniaturize:), @"m");
	AddItem(window, Label(@"native-zoomWindow", @"Zoom"), @selector(performZoom:), @"");
	AddItem(window, Label(@"native-openTabs", @"Manage Open Tabs…"), @selector(showTabManager:), @"", self);
	NSMenu *help = AddMenu(main, @"?");
	AddItem(help, Label(@"app-about", @"About macpad++"), @selector(showAbout:), @"", self);
	AddItem(help, Label(@"app-license", @"License…"), @selector(showLicense:), @"", self);
	EditorApplyShortcuts(main);
	// AppKit adds system editing services to the menu bar. Keep the in-window menu scoped to editor commands.
	[main itemWithTitle:edit.title].representedObject = [edit copy];
	NSApp.mainMenu = main;
	NSApp.windowsMenu = window;
	for (EditorDocument *document in documents.documents)
		[document refreshChromeMenus];
}

- (void)showTabManager:(id)sender { EditorShowTabManager(); }
- (void)showPreferences:(id)sender { EditorShowPreferences(); }
- (void)showStyleConfigurator:(id)sender { if (EditorShowStyleConfigurator()) [self buildMenu]; }
- (void)showShortcutMapper:(id)sender { if (EditorShowShortcutMapper(NSApp.mainMenu)) [self buildMenu]; }
- (void)editUserLanguage:(id)sender
{
	if (EditorShowUserLanguageEditor())
		[self updateUserLanguages:nil];
		return;
}
- (void)removeUserLanguage:(id)sender
{
	if (EditorRemoveUserLanguage())
		[self updateUserLanguages:nil];
}
- (void)updateUserLanguages:(id)sender
{
	for (EditorDocument *document in NSDocumentController.sharedDocumentController.documents)
		[document applyTheme];
	[self buildMenu];
}
- (void)exportUserLanguage:(id)sender { EditorExportUserLanguage(); }

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

- (void)openPluginsFolder:(id)sender
{
	NSError *error = nil;
	if (![NSFileManager.defaultManager createDirectoryAtURL:_plugins.directory withIntermediateDirectories:YES attributes:nil error:&error])
	{
		[NSApp presentError:error];
		return;
	}
	[NSWorkspace.sharedWorkspace openURL:_plugins.directory];
}

- (void)managePlugins:(id)sender
{
	for (;;)
	{
		NSArray<NSURL *> *plugins = _plugins.pluginFiles;
		NSAlert *panel = [[NSAlert alloc] init];
		panel.messageText = EditorUIString(@"Plugins Admin");
		panel.informativeText = EditorUIString(@"Install or disable native macOS plugins. Restart macpad++ to apply changes.");
		[panel addButtonWithTitle:EditorUIString(@"Close")];
		[panel addButtonWithTitle:EditorUIString(@"Install…")];
		NSButton *disable = [panel addButtonWithTitle:EditorUIString(@"Disable")];
		disable.enabled = plugins.count > 0;
		[panel addButtonWithTitle:EditorUIString(@"Catalog…")];
		if (!plugins.count)
			panel.accessoryView = [NSTextField labelWithString:EditorUIString(@"No native plugins installed.")];
		NSPopUpButton *files = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 365, 26) pullsDown:NO];
		for (NSURL *file in plugins)
		{
			NSString *title = [_plugins loadedTitleForFile:file];
			NSString *description = title ? [NSString stringWithFormat:@"%@ — %@", file.lastPathComponent, title] :
				[NSString stringWithFormat:@"%@ — Not loaded", file.lastPathComponent];
			NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:description action:nil keyEquivalent:@""];
			item.representedObject = file;
			[files.menu addItem:item];
		}
		if (plugins.count)
		{
			[files selectItemAtIndex:0];
			panel.accessoryView = files;
		}

		NSModalResponse response = [panel runModal];
		NSError *error = nil;
		if (response == NSAlertSecondButtonReturn)
		{
			NSOpenPanel *picker = NSOpenPanel.openPanel;
			picker.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"dylib"] ?: UTTypeData];
			picker.message = @"Choose a macOS plugin to install.";
			if ([picker runModal] == NSModalResponseOK && ![_plugins installPluginAtURL:picker.URL error:&error] && error)
				[NSApp presentError:error];
		}
		else if (response == NSAlertThirdButtonReturn && files.selectedItem)
		{
			if (![_plugins disablePluginAtURL:files.selectedItem.representedObject error:&error] && error)
				[NSApp presentError:error];
		}
		else if (response == NSAlertThirdButtonReturn + 1)
		{
			EditorShowPluginCatalog(_plugins);
			return;
		}
		else
			return;
	}
}

- (void)choosePluginCatalog:(id)sender { EditorChoosePluginCatalog(); }

- (void)runExternalCommand:(id)sender
{
	NSAlert *prompt = [[NSAlert alloc] init];
	prompt.messageText = Label(@"49000", @"Run");
	prompt.informativeText = EditorUIString(@"Program and arguments");
	[prompt addButtonWithTitle:EditorUIString(@"Run")];
	[prompt addButtonWithTitle:EditorUIString(@"Cancel")];
	[prompt addButtonWithTitle:EditorUIString(@"Save…")];
	NSTextField *input = [NSTextField textFieldWithString:_lastRunCommand ?: @""];
	input.frame = NSMakeRect(0, 0, 510, 26);
	prompt.accessoryView = input;
	prompt.window.initialFirstResponder = input;
	NSModalResponse response = [prompt runModal];
	if (response == NSAlertSecondButtonReturn)
		return;
	NSString *command = [input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if (!command.length)
		return;
	_lastRunCommand = command;
	if (response == NSAlertThirdButtonReturn)
		[self saveRunCommand:command];
	else
		[self executeRunCommand:command];
}

- (void)saveRunCommand:(NSString *)command
{
	NSAlert *dialog = [NSAlert new];
	dialog.messageText = EditorUIString(@"Save Run Command");
	[dialog addButtonWithTitle:EditorUIString(@"Save")];
	[dialog addButtonWithTitle:EditorUIString(@"Cancel")];
	NSTextField *name = [NSTextField textFieldWithString:@""];
	name.placeholderString = EditorUIString(@"Command name");
	name.frame = NSMakeRect(0, 0, 325, 24);
	dialog.accessoryView = name;
	dialog.window.initialFirstResponder = name;
	if ([dialog runModal] != NSAlertFirstButtonReturn)
		return;
	NSString *title = [name.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if (!title.length)
		return;
	EditorResources *resources = EditorResources.shared;
	NSMutableDictionary *commands = [[resources setting:@"runCommands" fallback:@{}] mutableCopy];
	if (commands[title])
	{
		NSAlert *confirm = [NSAlert new];
		confirm.messageText = [NSString stringWithFormat:@"Replace the saved command “%@”?", title];
		[confirm addButtonWithTitle:EditorUIString(@"Cancel")];
		[confirm addButtonWithTitle:EditorUIString(@"Replace")];
		if ([confirm runModal] != NSAlertSecondButtonReturn)
			return;
	}
	commands[title] = command;
	[resources setSetting:commands forName:@"runCommands"];
	[self buildMenu];
}

- (void)removeSavedRunCommand:(id)sender
{
	EditorResources *resources = EditorResources.shared;
	NSMutableDictionary *commands = [[resources setting:@"runCommands" fallback:@{}] mutableCopy];
	if (!commands.count)
		return;
	NSAlert *dialog = [NSAlert new];
	dialog.messageText = EditorUIString(@"Manage Saved Run Commands");
	[dialog addButtonWithTitle:EditorUIString(@"Remove")];
	[dialog addButtonWithTitle:EditorUIString(@"Cancel")];
	NSPopUpButton *choices = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 350, 28) pullsDown:NO];
	[choices addItemsWithTitles:[commands.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)]];
	dialog.accessoryView = choices;
	if ([dialog runModal] != NSAlertFirstButtonReturn)
		return;
	[commands removeObjectForKey:choices.titleOfSelectedItem];
	[resources setSetting:commands forName:@"runCommands"];
	[self buildMenu];
}

- (void)executeSavedRunCommand:(NSMenuItem *)sender
{
	NSDictionary *commands = [EditorResources.shared setting:@"runCommands" fallback:@{}];
	NSString *command = commands[sender.representedObject];
	if ([command isKindOfClass:NSString.class] && command.length)
		[self executeRunCommand:command];
}

- (void)executeRunCommand:(NSString *)command
{
	EditorDocumentController *documents = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorDocument *document = documents.focusedDocument;
	ScintillaView *editor = document.editor;
	NSURL *directory = document.fileURL.URLByDeletingLastPathComponent;
	NSString *filename = document.fileURL.lastPathComponent ?: @"";
	const auto position = [editor message:SCI_GETCURRENTPOS];
	const auto line = [editor message:SCI_LINEFROMPOSITION wParam:position];
	NSString *word = editor.selectedString;
	if (!word.length && editor)
	{
		auto start = [editor message:SCI_WORDSTARTPOSITION wParam:position lParam:1];
		auto end = [editor message:SCI_WORDENDPOSITION wParam:position lParam:1];
		const auto *bytes = reinterpret_cast<const char *>([editor message:SCI_GETCHARACTERPOINTER]);
		if (end > start)
			word = [[NSString alloc] initWithBytes:bytes + start length:end - start encoding:NSUTF8StringEncoding];
	}
	NSString *lineText = @"";
	if (editor)
	{
		auto start = [editor message:SCI_POSITIONFROMLINE wParam:line];
		auto end = [editor message:SCI_GETLINEENDPOSITION wParam:line];
		const auto *bytes = reinterpret_cast<const char *>([editor message:SCI_GETCHARACTERPOINTER]);
		if (end > start)
			lineText = [[NSString alloc] initWithBytes:bytes + start length:end - start encoding:NSUTF8StringEncoding] ?: @"";
	}
	NSDictionary *values = @{
		@"FULL_CURRENT_PATH": document.fileURL.path ?: @"",
		@"CURRENT_DIRECTORY": directory.path ?: @"",
		@"FILE_NAME": filename, @"NAME_PART": filename.stringByDeletingPathExtension, @"EXT_PART": filename.pathExtension,
		@"CURRENT_WORD": word ?: @"", @"CURRENT_LINESTR": lineText,
		@"CURRENT_LINE": [@(line + 1) stringValue], @"CURRENT_COLUMN": [@([editor message:SCI_GETCOLUMN wParam:position] + 1) stringValue],
		@"NPP_DIRECTORY": NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.path ?: @"",
		@"NPP_FULL_FILE_PATH": NSBundle.mainBundle.executableURL.path ?: @"",
	};
	NSTask *task = EditorRunTask(command, values, directory ?: [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES]);
	task.terminationHandler = ^(NSTask *completed) {
		if (completed.terminationStatus)
			dispatch_async(dispatch_get_main_queue(), ^{
				NSAlert *failure = [[NSAlert alloc] init];
				failure.messageText = [NSString stringWithFormat:@"Command exited with status %d", completed.terminationStatus];
				[failure runModal];
			});
	};
	NSError *error = nil;
	if (![task launchAndReturnError:&error])
		[NSApp presentError:error];
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
	if (menu == _recentMenu)
	{
		[menu removeAllItems];
		NSArray<NSURL *> *urls = NSDocumentController.sharedDocumentController.recentDocumentURLs;
		for (NSURL *url in urls)
		{
			NSMenuItem *entry = AddItem(menu, url.lastPathComponent, @selector(openRecentFile:), @"", self);
			entry.representedObject = url;
			entry.toolTip = url.path;
		}
		if (urls.count)
			[menu addItem:NSMenuItem.separatorItem];
		AddItem(menu, Label(@"42041", @"Clear Recent Files"), @selector(clearRecentDocuments:), @"",
			NSDocumentController.sharedDocumentController);
		return;
	}
	if (menu != _macroMenu)
		return;
	while (menu.numberOfItems > _macroMenuBaseItems)
		[menu removeItemAtIndex:menu.numberOfItems - 1];
	NSArray<EditorMacro *> *macros = EditorMacroLibrary.shared.macros;
	if (!macros.count)
		return;
	[menu addItem:NSMenuItem.separatorItem];
	NSMutableDictionary<NSString *, NSMenu *> *folders = [NSMutableDictionary dictionary];
	for (EditorMacro *macro in macros)
	{
		NSMenu *destination = menu;
		if (macro.folder.length)
		{
			destination = folders[macro.folder];
			if (!destination)
				folders[macro.folder] = destination = AddMenu(menu, macro.folder);
		}
		AddItem(destination, macro.name, @selector(playSavedMacro:), @"").representedObject = macro;
	}
	EditorApplyShortcuts(menu);
}

- (void)macroLibraryChanged:(NSNotification *)notification
{
	[self menuNeedsUpdate:_macroMenu];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorDocument *document = controller.focusedDocument;
	if (item.action == @selector(openDocumentInNewInstance:))
		return document && (item.tag == 10003 || document.fileURL);
	if (item.action == @selector(runTabFileCommand:))
		return document && EditorCanRunTabCommand(document, item.tag);
	if (item.action == @selector(actOnSelection:))
		return item.tag == 42076 || (![[document editor] message:SCI_GETSELECTIONEMPTY] &&
			document && (item.tag != 42106 || ![document.editor message:SCI_GETREADONLY]));
	if (item.action == @selector(copyDocumentPath:))
		return item.tag >= 42087 ? controller.tabDocuments.count > 0 : document.fileURL != nil;
	if (item.action == @selector(generateHash:) && item.tag % 3 == 2)
	{
		EditorDocumentController *documents = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
		return documents.focusedDocument.editor.selectedString.length > 0;
	}
	return item.action != @selector(deleteSavedMacro:) || EditorMacroLibrary.shared.macros.count > 0;
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

- (void)importWindowsConfiguration:(id)sender
{
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowedContentTypes = @[UTTypeXML];
	if ([panel runModal] != NSModalResponseOK)
		return;
	NSError *error = nil;
	if (![EditorResources.shared importWindowsConfiguration:panel.URL error:&error])
	{
		[NSApp presentError:error];
		return;
	}
	for (EditorDocument *document in NSDocumentController.sharedDocumentController.documents)
		[document applyPreferences];
	[(EditorDocumentController *)NSDocumentController.sharedDocumentController applyImportedDockLayout];
	NSAlert *report = [NSAlert new];
	report.messageText = Label(@"native-configImported", @"Configuration Imported");
	report.informativeText = Label(@"native-configImportedInfo",
		@"Supported preferences were applied. The original XML was copied to the profile as imported-config.xml.");
	[report addButtonWithTitle:Label(@"app-ok", @"OK")];
	[report runModal];
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
		custom.placeholderString = EditorUIString(@"https://example.com/search?q=$(CURRENT_WORD)");
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

- (void)launchAdditionalInstance:(NSArray<NSString *> *)arguments completion:(void (^)(void))completion
{
	NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
	configuration.createsNewApplicationInstance = YES;
	configuration.arguments = [@[@"-nosession",
		[@"-settingsDir=" stringByAppendingString:EditorResources.shared.profile.path]] arrayByAddingObjectsFromArray:arguments];
	[NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:configuration
		completionHandler:^(NSRunningApplication *instance, NSError *error) {
			dispatch_async(dispatch_get_main_queue(), ^{
				if (error)
					[NSApp presentError:error];
				else if (instance && completion)
					completion();
			});
		}];
}

- (void)launchNewInstanceForDocument:(EditorDocument *)document move:(BOOL)move
{
	NSURL *url = document.fileURL;
	if (!url)
		return;
	NSString *position = [NSString stringWithFormat:@"-p%ld", static_cast<long>([document.editor message:SCI_GETCURRENTPOS])];
	[self launchAdditionalInstance:@[position, @"--", url.path] completion:^{
		if (move && !document.isDocumentEdited && [document.fileURL isEqual:url])
			[document closeEditorTab:nil];
	}];
}

- (void)document:(EditorDocument *)document didSaveForNewInstance:(BOOL)saved contextInfo:(void *)context
{
	if (saved)
		[self launchNewInstanceForDocument:document move:YES];
}

- (void)openDocumentInNewInstance:(NSMenuItem *)sender
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorDocument *document = [sender.representedObject isKindOfClass:EditorDocument.class] ? sender.representedObject :
		controller.focusedDocument;
	const BOOL move = sender.tag == 10003;
	if (move && (!document.fileURL || document.isDocumentEdited))
		[document saveDocumentWithDelegate:self didSaveSelector:@selector(document:didSaveForNewInstance:contextInfo:) contextInfo:nullptr];
	else
		[self launchNewInstanceForDocument:document move:move];
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

- (void)showHashResults:(NSString *)contents algorithm:(EditorHashAlgorithm)algorithm
{
	NSAlert *result = [[NSAlert alloc] init];
	result.messageText = HashName(algorithm);
	[result addButtonWithTitle:EditorUIString(@"Copy")];
	[result addButtonWithTitle:EditorUIString(@"Close")];
	result.accessoryView = HashTextView(contents, NO);
	if ([result runModal] == NSAlertFirstButtonReturn)
		CopyText(contents);
}

- (void)generateHash:(NSMenuItem *)sender
{
	auto algorithm = static_cast<EditorHashAlgorithm>(sender.tag / 3);
	switch (sender.tag % 3)
	{
	case 0:
	{
		NSAlert *input = [[NSAlert alloc] init];
		input.messageText = HashName(algorithm);
		[input addButtonWithTitle:EditorUIString(@"Generate")];
		[input addButtonWithTitle:EditorUIString(@"Cancel")];
		NSScrollView *scroll = HashTextView(@"", YES);
		NSTextView *editor = (NSTextView *)scroll.documentView;
		NSButton *perLine = [NSButton checkboxWithTitle:EditorUIString(@"Treat each line as a separate string") target:nil action:nil];
		NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 210)];
		scroll.frame = NSMakeRect(0, 30, 480, 180);
		perLine.frame = NSMakeRect(0, 0, 480, 24);
		[form addSubview:scroll];
		[form addSubview:perLine];
		input.accessoryView = form;
		input.window.initialFirstResponder = editor;
		if ([input runModal] != NSAlertFirstButtonReturn)
			return;
		NSString *text = editor.string;
		if (perLine.state == NSControlStateValueOn)
		{
			NSMutableArray<NSString *> *lines = [NSMutableArray array];
			[text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
				[lines addObject:EditorHashData([line dataUsingEncoding:NSUTF8StringEncoding], algorithm)];
			}];
			[self showHashResults:[lines componentsJoinedByString:@"\n"] algorithm:algorithm];
		}
		else
			[self showHashResults:EditorHashData([text dataUsingEncoding:NSUTF8StringEncoding], algorithm) algorithm:algorithm];
		break;
	}
	case 1:
	{
		NSOpenPanel *panel = NSOpenPanel.openPanel;
		panel.allowsMultipleSelection = YES;
		if ([panel runModal] != NSModalResponseOK)
			return;
		NSArray<NSURL *> *urls = panel.URLs;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSMutableArray<NSString *> *lines = [NSMutableArray array];
			for (NSURL *url in urls)
			{
				NSError *error = nil;
				NSString *digest = EditorHashFile(url, algorithm, &error);
				[lines addObject:digest ? [NSString stringWithFormat:@"%@  %@", digest, url.lastPathComponent] :
					[NSString stringWithFormat:@"%@ — %@", url.lastPathComponent, error.localizedDescription]];
			}
			NSString *result = [lines componentsJoinedByString:@"\n"];
			dispatch_async(dispatch_get_main_queue(), ^{ [self showHashResults:result algorithm:algorithm]; });
		});
		break;
	}
	case 2:
	{
		EditorDocumentController *documents = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
		NSString *selection = documents.focusedDocument.editor.selectedString;
		if (selection.length)
			CopyText(EditorHashData([selection dataUsingEncoding:NSUTF8StringEncoding], algorithm));
		break;
	}
	}
}

- (void)importMacros:(id)sender
{
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowedContentTypes = @[UTTypeXML];
	if ([panel runModal] != NSModalResponseOK)
		return;
	NSError *error = nil;
	NSUInteger skipped = 0;
	NSInteger imported = [EditorMacroLibrary.shared importShortcuts:panel.URL skipped:&skipped error:&error];
	if (imported < 0)
	{
		[NSApp presentError:error];
		return;
	}
	NSAlert *report = [[NSAlert alloc] init];
	report.messageText = [NSString localizedStringWithFormat:@"%ld macros imported", imported];
	if (skipped)
		report.informativeText = [NSString localizedStringWithFormat:@"%lu duplicate or unsupported macros skipped.", skipped];
	[report runModal];
}

- (void)deleteSavedMacro:(id)sender
{
	NSArray<EditorMacro *> *macros = EditorMacroLibrary.shared.macros;
	if (!macros.count)
		return;
	NSPopUpButton *chooser = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 290, 26) pullsDown:NO];
	for (EditorMacro *macro in macros)
	{
		NSString *title = macro.folder.length ? [NSString stringWithFormat:@"%@ / %@", macro.folder, macro.name] : macro.name;
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
		item.representedObject = macro;
		[chooser.menu addItem:item];
	}
	[chooser selectItemAtIndex:0];
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = EditorUIString(@"Delete a saved macro");
	[alert addButtonWithTitle:EditorUIString(@"Cancel")];
	[alert addButtonWithTitle:EditorUIString(@"Delete")].hasDestructiveAction = YES;
	alert.accessoryView = chooser;
	if ([alert runModal] != NSAlertSecondButtonReturn)
		return;
	NSError *error = nil;
	if (![EditorMacroLibrary.shared removeMacro:chooser.selectedItem.representedObject error:&error])
		[NSApp presentError:error];
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

- (void)importUserLanguage:(id)sender
{
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowedContentTypes = @[UTTypeXML];
	if ([panel runModal] != NSModalResponseOK)
		return;
	NSError *error = nil;
	if (![EditorResources.shared importUserLanguages:panel.URL error:&error])
	{
		[NSApp presentError:error];
		return;
	}
	for (EditorDocument *document in NSDocumentController.sharedDocumentController.documents)
		[document applyTheme];
	[self buildMenu];
}

- (void)saveSession:(id)sender
{
	NSSavePanel *panel = NSSavePanel.savePanel;
	panel.nameFieldStringValue = @"session.xml";
	panel.allowedContentTypes = @[UTTypeXML];
	if ([panel runModal] != NSModalResponseOK)
		return;
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	NSError *error = nil;
	if (![controller saveSessionToURL:panel.URL error:&error])
		[NSApp presentError:error];
}

- (void)loadSession:(id)sender
{
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowedContentTypes = @[UTTypeXML];
	if ([panel runModal] != NSModalResponseOK)
		return;
	if ([[EditorResources.shared setting:@"instanceMode" fallback:@0] integerValue] == 1)
	{
		[self launchAdditionalInstance:@[@"-openSession", @"--", panel.URL.path] completion:nil];
		return;
	}
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	NSError *error = nil;
	if (![controller loadSessionFromURL:panel.URL error:&error])
		[NSApp presentError:error];
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
		if ([[EditorResources.shared setting:@"instanceMode" fallback:@0] integerValue] == 2)
		{
			[self launchAdditionalInstance:@[@"--", url.path] completion:nil];
			continue;
		}
		[documents openDocumentWithContentsOfURL:url display:YES completionHandler:^(NSDocument *document, BOOL alreadyOpen, NSError *error) {
			if (error)
				[NSApp presentError:error];
		}];
	}
}

static NSScrollView *LegalTextView(NSString *contents)
{
	NSScrollView *view = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 540, 360)];
	view.hasVerticalScroller = YES;
	view.borderType = NSBezelBorder;
	NSTextView *text = [[NSTextView alloc] initWithFrame:view.contentView.bounds];
	text.string = contents;
	text.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
	text.autoresizingMask = NSViewWidthSizable;
	text.verticallyResizable = YES;
	text.editable = NO;
	view.documentView = text;
	return view;
}

- (void)showLicense:(id)sender
{
	NSURL *license = [NSBundle.mainBundle URLForResource:@"LICENSE" withExtension:nil];
	NSString *contents = license ? [NSString stringWithContentsOfURL:license encoding:NSUTF8StringEncoding error:nullptr] : nil;
	NSAlert *alert = [NSAlert new];
	alert.icon = NSApp.applicationIconImage;
	alert.messageText = Label(@"app-license-title", @"macpad++ License");
	[alert addButtonWithTitle:Label(@"app-ok", @"OK")];
	if (!contents.length)
	{
		alert.informativeText = Label(@"app-license-unavailable", @"The license text could not be opened.");
		[alert runModal];
		return;
	}
	alert.informativeText = Label(@"app-license-description",
		@"macpad++ is distributed under version 3 of the GNU GPL. The original license text follows.");
	NSRange heading = [contents rangeOfString:@"GNU GENERAL PUBLIC LICENSE"];
	alert.accessoryView = LegalTextView(heading.location == NSNotFound ? contents : [contents substringFromIndex:heading.location]);
	[alert addButtonWithTitle:Label(@"app-notices", @"Copyright and Notices…")];
	if ([alert runModal] == NSAlertSecondButtonReturn)
	{
		NSURL *notices = [NSBundle.mainBundle URLForResource:@"THIRD_PARTY_NOTICES" withExtension:@"md"];
		NSString *attribution = notices ? [NSString stringWithContentsOfURL:notices encoding:NSUTF8StringEncoding error:nullptr] : nil;
		NSString *upstream = heading.location == NSNotFound ? contents : [contents substringToIndex:heading.location];
		NSString *combined = attribution.length ? [NSString stringWithFormat:@"%@\n\n%@", upstream, attribution] : upstream;
		NSAlert *credits = [NSAlert new];
		credits.icon = NSApp.applicationIconImage;
		credits.messageText = Label(@"app-notices-title", @"Copyright and Notices");
		credits.accessoryView = LegalTextView(combined);
		[credits addButtonWithTitle:Label(@"app-ok", @"OK")];
		[credits runModal];
	}
}

- (void)showAbout:(id)sender
{
	NSBundle *bundle = NSBundle.mainBundle;
	NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
	NSString *build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
	NSAlert *about = [NSAlert new];
	about.icon = NSApp.applicationIconImage;
	about.messageText = EditorUIString(@"macpad++");
	NSString *versionLine = [NSString stringWithFormat:Label(@"app-version", @"Version %@ (build %@)"), version, build];
	NSString *description = Label(@"app-about-description",
		@"Native text and code editor for macOS. Built with Scintilla and Lexilla and distributed under version 3 of the GNU GPL.");
	about.informativeText = [NSString stringWithFormat:@"%@\n\n%@", versionLine, description];
	[about addButtonWithTitle:Label(@"app-ok", @"OK")];
	[about addButtonWithTitle:Label(@"app-license", @"macpad++ License…")];
	if ([about runModal] == NSAlertSecondButtonReturn)
		[self showLicense:nil];
}
@end

int main(int argc, const char *argv[])
{
	@autoreleasepool
	{
		NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
		EditorLaunchOptions *options = [[EditorLaunchOptions alloc] initWithArguments:
			[arguments subarrayWithRange:NSMakeRange(1, arguments.count - 1)]];
		if (options.help)
		{
			puts("macpad++ [-nLINE] [-cCOLUMN] [-pBYTE] [-lLANGUAGE] [-udl=NAME] [-LCODE]\n"
				"         [-nosession] [-noPlugin] [-notabbar] [-ro] [-monitor]\n"
				"         [-settingsDir=PATH] [-openSession] [-openFoldersAsWorkspace] [--] [file ...]");
			return 0;
		}
		if (options.settingsPath.isAbsolutePath)
			setenv("MACPAD_DATA_DIR", options.settingsPath.fileSystemRepresentation, 1);
		NSApplication *app = MacpadApplication.sharedApplication;
		__attribute__((objc_precise_lifetime)) EditorDocumentController *documents = [[EditorDocumentController alloc] init];
		__attribute__((objc_precise_lifetime)) MacpadApp *delegate = [[MacpadApp alloc] init];
		delegate.launchOptions = options;
		app.delegate = delegate;
		[app setActivationPolicy:NSApplicationActivationPolicyRegular];
		if (argc == 2 && strcmp(argv[1], "--smoke-test") == 0)
		{
			[app finishLaunching];
			return RunSmokeTest();
		}
		if (argc == 2 && std::strncmp(argv[1], "--smoke-workspace-", 18) == 0 &&
			!NSProcessInfo.processInfo.environment[@"MACPAD_DATA_DIR"].isAbsolutePath)
			return 1;
		[app run];
		(void)documents;
		(void)delegate;
	}
	return 0;
}

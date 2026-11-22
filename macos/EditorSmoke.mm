// SPDX-License-Identifier: GPL-3.0-only
#import "EditorDocument.h"
#import "EditorPlugins.h"
#import "EditorResources.h"
#import "ScintillaView.h"

#include "SciLexer.h"

static bool Check(bool condition, const char *description)
{
	if (!condition)
		fprintf(stderr, "macpad++ smoke test failed: %s\n", description);
	return condition;
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

	NSURL *customTheme = [resources importXML:[test URLByAppendingPathComponent:@"Smoke.xml"] theme:YES error:&error];
	NSURL *translation = [resources importXML:[NSBundle.mainBundle URLForResource:@"russian" withExtension:@"xml"
		subdirectory:@"localization"] theme:NO error:&error];
	if (!Check(customTheme && translation, "import theme and translation XML"))
		return 1;
	[resources chooseTheme:customTheme];
	[resources chooseTranslation:translation];
	if (!Check([[resources label:@"file" fallback:@"File"] isEqualToString:@"Файл"], "apply Russian menu labels"))
		return 1;

	NSDocumentController *controller = NSDocumentController.sharedDocumentController;
	EditorDocument *document = (EditorDocument *)[controller makeDocumentWithContentsOfURL:fixture
		ofType:controller.defaultType error:&error];
	if (!Check([document isKindOfClass:EditorDocument.class], "open fixture with the macOS document controller"))
		return 1;
	[controller addDocument:document];
	[document makeWindowControllers];
	ScintillaView *editor = document.editor;
	if ([editor message:SCI_GETLEXER] != SCLEX_PYTHON || [editor message:SCI_GETSTYLEAT wParam:0] != SCE_P_WORD)
		fprintf(stderr, "Lexer ID: %ld, style at offset zero: %ld\n",
			[editor message:SCI_GETLEXER], [editor message:SCI_GETSTYLEAT wParam:0]);
	if (!Check([[document dataOfType:controller.defaultType error:&error] isEqualToData:encoded], "round trip UTF-16 BOM and CRLF") ||
		!Check([editor message:SCI_GETEOLMODE] == SC_EOL_CRLF, "detect CRLF for new lines") ||
		!Check([editor message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT] == 0x563412, "apply imported XML theme") ||
		!Check([editor message:SCI_GETLEXER] == SCLEX_PYTHON && [editor message:SCI_GETSTYLEAT wParam:0] == SCE_P_WORD,
			"highlight a Python keyword with Lexilla"))
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
	[document close];
	puts("Passed: AppKit document open and save, Scintilla editing, Lexilla, XML import, and native plugin command.");
	return 0;
}

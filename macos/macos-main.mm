// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <cstring>

#import "EditorDocument.h"
#import "EditorPlugins.h"
#import "EditorResources.h"

int RunSmokeTest(void);

@interface MacpadApp : NSObject <NSApplicationDelegate>
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

@implementation MacpadApp
{
	EditorPlugins *_plugins;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
	_plugins = [[EditorPlugins alloc] initWithDirectory:[EditorResources.shared.profile URLByAppendingPathComponent:@"plugins"]];
	[self buildMenu];
}

- (void)buildMenu
{
	NSMenu *main = [[NSMenu alloc] initWithTitle:@""];
	NSMenu *application = AddMenu(main, @"macpad++");
	AddItem(application, @"About macpad++", @selector(showAbout:), @"", self);
	AddItem(application, @"License…", @selector(showLicense:), @"", self);
	[application addItem:NSMenuItem.separatorItem];
	AddItem(application, @"Hide macpad++", @selector(hide:), @"h", NSApp);
	AddItem(application, @"Quit macpad++", @selector(terminate:), @"q", NSApp);

	NSDocumentController *documents = NSDocumentController.sharedDocumentController;
	NSMenu *file = AddMenu(main, Label(@"file", @"File"));
	AddItem(file, Label(@"41001", @"New"), @selector(newDocument:), @"n", documents);
	AddItem(file, Label(@"41002", @"Open…"), @selector(openFiles:), @"o", self);
	AddItem(file, Label(@"41003", @"Close"), @selector(performClose:), @"w");
	[file addItem:NSMenuItem.separatorItem];
	AddItem(file, Label(@"41006", @"Save"), @selector(saveDocument:), @"s");
	AddItem(file, Label(@"41008", @"Save As…"), @selector(saveDocumentAs:), @"S");

	NSMenu *edit = AddMenu(main, Label(@"edit", @"Edit"));
	AddItem(edit, Label(@"42003", @"Undo"), @selector(undo:), @"z");
	AddItem(edit, Label(@"42004", @"Redo"), @selector(redo:), @"Z");
	[edit addItem:NSMenuItem.separatorItem];
	AddItem(edit, Label(@"42001", @"Cut"), @selector(cut:), @"x");
	AddItem(edit, Label(@"42002", @"Copy"), @selector(copy:), @"c");
	AddItem(edit, Label(@"42005", @"Paste"), @selector(paste:), @"v");
	AddItem(edit, Label(@"42007", @"Select All"), @selector(selectAll:), @"a");

	NSMenu *search = AddMenu(main, Label(@"search", @"Search"));
	AddItem(search, Label(@"43001", @"Find…"), @selector(findText:), @"f");
	AddItem(search, Label(@"43002", @"Find Next"), @selector(findNext:), @"g");
	AddItem(search, Label(@"43003", @"Replace…"), @selector(replaceText:), @"F");

	NSMenu *view = AddMenu(main, Label(@"view", @"View"));
	AddItem(view, Label(@"44022", @"Word Wrap"), @selector(toggleWrap:), @"");
	AddItem(view, @"Line Numbers", @selector(toggleLineNumbers:), @"");
	NSMenu *themes = AddMenu(view, @"Theme");
	NSMenuItem *standard = AddItem(themes, @"Default", @selector(selectTheme:), @"", self);
	standard.state = EditorResources.shared.selectedTheme ? NSControlStateValueOff : NSControlStateValueOn;
	[self fillCatalog:themes theme:YES];

	NSMenu *settings = AddMenu(main, Label(@"settings", @"Settings"));
	NSMenu *translations = AddMenu(settings, @"Interface Language");
	NSMenuItem *standardLanguage = AddItem(translations, @"Default / nativeLang.xml", @selector(selectTranslation:), @"", self);
	standardLanguage.state = EditorResources.shared.selectedTranslation ? NSControlStateValueOff : NSControlStateValueOn;
	[self fillCatalog:translations theme:NO];

	NSMenu *plugins = AddMenu(main, Label(@"Plugins", @"Plugins"));
	[_plugins populateMenu:plugins];

	NSMenu *window = AddMenu(main, Label(@"Window", @"Window"));
	AddItem(window, @"Minimize", @selector(performMiniaturize:), @"m");
	AddItem(window, @"Zoom", @selector(performZoom:), @"");
	AddItem(window, @"Merge All Windows", @selector(mergeAllWindows:), @"");
	NSApp.mainMenu = main;
	NSApp.windowsMenu = window;
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
	NSMenuItem *item = AddItem(menu, @"Import XML…", @selector(importXML:), @"", self);
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
		NSApplication *app = NSApplication.sharedApplication;
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

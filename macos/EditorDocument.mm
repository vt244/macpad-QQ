// SPDX-License-Identifier: GPL-3.0-only
#import "EditorDocument.h"
#import "EditorChrome.h"
#import "EditorCompletion.h"
#import "EditorContextMenus.h"
#import "EditorDocumentList.h"
#import "EditorDocumentMap.h"
#import "EditorDock.h"
#import "EditorFileSearch.h"
#import "EditorFolderPanel.h"
#import "EditorEditActions.h"
#import "EditorFunctionList.h"
#import "EditorIncrementalSearch.h"
#import "EditorInsertPanels.h"
#import "EditorLaunchOptions.h"
#import "EditorMacros.h"
#import "EditorProjectPanel.h"
#import "EditorPlugins.h"
#import "EditorPrinting.h"
#import "EditorResources.h"
#import "EditorSettings.h"
#import "EditorText.h"
#import "EditorWorkspace.h"
#import "ScintillaView.h"
#include "MacpadPlugin.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "SciLexer.h"
#include "BoostRegexSearch.h"
#include "pugiconfig.hpp"
#undef PUGIXML_CHARCONV_FLOAT
#include "pugixml.hpp"
#include <algorithm>
#include <climits>
#include <cstring>
#include <optional>
#include <sstream>
#include <string_view>
#include <vector>

static constexpr int Bookmark = 20;
static constexpr int FindMark = 8;
static constexpr int FirstTokenMark = 10;
static constexpr int TokenMarkCount = 5;
static std::pair<sptr_t, sptr_t> TokenRange(ScintillaView *editor);
static NSData *DocumentBytes(ScintillaView *editor, sptr_t start, sptr_t end);
static NSUInteger NextUntitledNumber = 1;
static uint64_t NextRuntimeDocumentID = 1;

@interface EditorWindowController : NSWindowController
@property(nonatomic, copy) NSString *titleSuffix;
@end

@implementation EditorWindowController
- (NSString *)windowTitleForDocumentDisplayName:(NSString *)displayName
{
	NSString *title = [super windowTitleForDocumentDisplayName:displayName];
	return self.titleSuffix.length ? [NSString stringWithFormat:@"%@ — %@", title, self.titleSuffix] : title;
}
@end

static void NotifyPlugins(EditorDocument *document, MacpadDocumentEventV2 event)
{
	if (document)
		[NSNotificationCenter.defaultCenter postNotificationName:EditorPluginDocumentDidChange object:document
			userInfo:@{@"event": @(event)}];
}

struct RecordedSearch
{
	NSString *query = @"";
	NSString *replacement = @"";
	NSString *folder = @"";
	NSString *filters = @"*.*";
	NSInteger mode = 0;
	NSInteger options = 512;
};

@interface EditorTabPane : NSView
@property(nonatomic, weak) EditorTabStrip *tabs;
@property(nonatomic, strong) NSView *host;
@end

@implementation EditorTabPane
- (void)layout
{
	[super layout];
	NSRect content = self.bounds;
	if (!self.tabs.hidden)
	{
		EditorResources *resources = EditorResources.shared;
		const BOOL vertical = [[resources setting:@"verticalTabs" fallback:@NO] boolValue];
		const BOOL multiline = [[resources setting:@"multilineTabs" fallback:@NO] boolValue];
		const CGFloat width = vertical ? MIN(180, MAX(0, NSWidth(content) / 3)) : NSWidth(content);
		const CGFloat height = [self.tabs layoutTabsForWidth:width height:NSHeight(content) vertical:vertical multiline:multiline];
		NSRect tabFrame;
		NSDivideRect(content, &tabFrame, &content, vertical ? width : MIN(NSHeight(content), height),
			vertical ? NSMinXEdge : NSMaxYEdge);
		self.tabs.frame = tabFrame;
	}
	self.host.frame = content;
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	self.needsLayout = YES;
}
@end

static NSView *AddEditorHost(EditorTabPane *pane, NSView *tabs)
{
	NSView *host = [[NSView alloc] initWithFrame:NSZeroRect];
	pane.tabs = (EditorTabStrip *)tabs;
	pane.host = host;
	[pane addSubview:tabs];
	[pane addSubview:host];
	return host;
}

@interface EditorSplitView : NSSplitView
@property(nonatomic, copy) void (^rotate)(NSInteger);
@end

@implementation EditorSplitView
- (NSMenu *)menuForEvent:(NSEvent *)event
{
	if (self.arrangedSubviews.count != 2)
		return [super menuForEvent:event];
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	NSRect first = self.arrangedSubviews.firstObject.frame;
	NSRect second = self.arrangedSubviews.lastObject.frame;
	const CGFloat divider = self.isVertical ? (MIN(NSMaxX(first), NSMaxX(second)) + MAX(NSMinX(first), NSMinX(second))) / 2 :
		(MIN(NSMaxY(first), NSMaxY(second)) + MAX(NSMinY(first), NSMinY(second))) / 2;
	if (fabs((self.isVertical ? point.x : point.y) - divider) > 6)
		return [super menuForEvent:event];
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Split View"];
	NSMenuItem *right = [menu addItemWithTitle:@"Rotate Right" action:@selector(rotateFromMenu:) keyEquivalent:@""];
	right.target = self;
	right.tag = 1;
	NSMenuItem *left = [menu addItemWithTitle:@"Rotate Left" action:@selector(rotateFromMenu:) keyEquivalent:@""];
	left.target = self;
	left.tag = -1;
	return menu;
}

- (void)rotateFromMenu:(NSMenuItem *)item { self.rotate(item.tag); }
@end

@interface EditorDocument ()
- (void)displaySearchReports:(NSArray<EditorSearchReport *> *)reports purge:(BOOL)purge match:(EditorSearchMatch *)match visible:(BOOL)visible;
- (void)refineSearchReports:(NSArray<EditorSearchReport *> *)reports;
- (void)displayDocumentList:(NSArray<EditorDocument *> *)documents otherView:(NSArray<EditorDocument *> *)other
	focused:(EditorDocument *)focused focusOther:(BOOL)focusOther groupByView:(BOOL)groupByView visible:(BOOL)visible;
- (void)displayFolderWorkspace:(NSArray<NSURL *> *)folders visible:(BOOL)visible;
- (void)displayProjectPanels:(NSIndexSet *)visible;
- (void)displayFunctionsOf:(EditorDocument *)document visible:(BOOL)visible;
- (void)displayDocumentMap:(ScintillaView *)editor visible:(BOOL)visible;
- (void)displayInsertPanels:(NSIndexSet *)visible clipboard:(NSArray<NSString *> *)entries encoding:(NSStringEncoding)encoding;
- (NSStringEncoding)currentTextEncoding;
- (void)checkDiskChanges:(BOOL)checkNormal allowPrompt:(BOOL)allowPrompt;
- (NSData *)editorUTF8;
- (NSDictionary<NSString *, id> *)workspaceEntry;
- (void)restoreWorkspaceEntry:(NSDictionary<NSString *, id> *)entry;
- (void)displayOtherDocument:(EditorDocument *)document;
- (void)applySplitRotation:(NSInteger)rotation;
- (void)applyPresentationMode:(NSInteger)mode;
- (void)focusEditor;
- (void)updateStatus;
- (void)refreshDockPlacements;
- (BOOL)largeFileMode;
- (void)setReaderEncoding:(NSStringEncoding)encoding;
- (void)closeClonedView;
- (void)addClonedView;
- (void)focusPrimaryEditor;
- (void)focusClonedEditor;
- (ScintillaView *)companionClone;
- (ScintillaView *)primaryEditorView;
- (ScintillaView *)clonedEditorView;
- (void)clonedViewNotification:(SCNotification *)notification;
- (BOOL)userReadOnly;
- (void)setUserReadOnly:(BOOL)readOnly;
@end

@interface EditorCloneObserver : NSObject <ScintillaNotificationProtocol>
@property(nonatomic, weak) EditorDocument *document;
@end

@implementation EditorCloneObserver
- (void)notification:(SCNotification *)notification
{
	[self.document clonedViewNotification:notification];
}
@end

@interface EditorDocumentController ()
@property(nonatomic, copy) NSArray<EditorSearchReport *> *searchReports;
@property(nonatomic) BOOL purgeSearchReports;
@property(nonatomic) BOOL searchResultsVisible;
@property(nonatomic) BOOL documentListVisible;
@property(nonatomic) BOOL documentListUngrouped;
@property(nonatomic) BOOL syncVerticalScroll;
@property(nonatomic) BOOL syncHorizontalScroll;
@property(nonatomic) BOOL syncZoom;
@property(nonatomic) NSInteger splitRotation;
@property(nonatomic, readonly) EditorDockPlacement *documentListPlacement;
@property(nonatomic, readonly) EditorDockPlacement *searchResultsPlacement;
@property(nonatomic, readonly) EditorDockPlacement *folderWorkspacePlacement;
@property(nonatomic, readonly) NSArray<EditorProjectWorkspace *> *projectWorkspaces;
@property(nonatomic, readonly) NSArray<EditorDockPlacement *> *projectPlacements;
@property(nonatomic, readonly) EditorDockPlacement *functionListPlacement;
@property(nonatomic, readonly) EditorDockPlacement *documentMapPlacement;
@property(nonatomic, readonly) NSArray<EditorDockPlacement *> *insertPlacements;
- (void)setProjectPanel:(NSUInteger)index visible:(BOOL)visible;
- (void)refreshFunctionList;
- (void)refreshDocumentMap;
- (void)setInsertPanel:(NSUInteger)index visible:(BOOL)visible;
- (void)refreshInsertPanels;
- (void)insertPanelText:(NSString *)text;
- (void)showSearchReport:(EditorSearchReport *)report;
- (void)refreshSearchPanel;
- (void)openSearchMatch:(EditorSearchMatch *)match;
- (void)workspaceChanged;
- (void)refreshDocumentList;
- (EditorDocument *)windowOwnerForDocument:(EditorDocument *)document;
- (void)showInOtherView:(EditorDocument *)document;
- (void)hideOtherView;
- (BOOL)hasOtherView;
- (BOOL)focusOtherViewDocument:(EditorDocument *)document;
- (void)prepareToCloseDocument:(EditorDocument *)document;
- (void)syncScrollFromDocument:(EditorDocument *)document changes:(int)changes;
- (void)syncZoomFromDocument:(EditorDocument *)document;
- (void)restoreViewsWithPrimary:(EditorDocument *)primary other:(EditorDocument *)other focusOther:(BOOL)focusOther;
@end

static constexpr struct { const char *name; unsigned int read; unsigned int write; } SessionFields[] = {
	{"firstVisibleLine", SCI_GETFIRSTVISIBLELINE, SCI_SETFIRSTVISIBLELINE},
	{"xOffset", SCI_GETXOFFSET, SCI_SETXOFFSET},
	{"scrollWidth", SCI_GETSCROLLWIDTH, SCI_SETSCROLLWIDTH},
};

static id WorkspaceValue(NSDictionary *entry, NSString *key, Class type)
{
	id value = entry[key];
	return [value isKindOfClass:type] ? value : nil;
}

static BOOL IsAvailableEncoding(NSStringEncoding encoding)
{
	if (!encoding)
		return NO;
	const auto cf = CFStringConvertNSStringEncodingToEncoding(encoding);
	return cf != kCFStringEncodingInvalidId && CFStringIsEncodingAvailable(cf);
}

static void WriteSessionView(pugi::xml_node file, NSString *path, ScintillaView *editor)
{
	file.append_attribute("filename") = path.UTF8String;
	for (const auto &field : SessionFields)
		file.append_attribute(field.name) = static_cast<long long>([editor message:field.read]);
	file.append_attribute("startPos") = static_cast<long long>([editor message:SCI_GETANCHOR]);
	file.append_attribute("endPos") = static_cast<long long>([editor message:SCI_GETCURRENTPOS]);
	for (auto line = [editor message:SCI_MARKERNEXT wParam:0 lParam:1 << Bookmark]; line >= 0;
		line = [editor message:SCI_MARKERNEXT wParam:line + 1 lParam:1 << Bookmark])
		file.append_child("Mark").append_attribute("line") = static_cast<long long>(line);
	for (auto line = [editor message:SCI_CONTRACTEDFOLDNEXT wParam:0]; line >= 0;
		line = [editor message:SCI_CONTRACTEDFOLDNEXT wParam:line + 1])
		file.append_child("Fold").append_attribute("line") = static_cast<long long>(line);
}

static void ReadSessionView(pugi::xml_node file, ScintillaView *editor)
{
	auto length = [editor message:SCI_GETLENGTH];
	auto start = std::clamp(file.attribute("startPos").as_llong(), 0LL, static_cast<long long>(length));
	auto end = std::clamp(file.attribute("endPos").as_llong(), 0LL, static_cast<long long>(length));
	[editor message:SCI_SETSEL wParam:start lParam:end];
	auto lineCount = [editor message:SCI_GETLINECOUNT];
	for (auto mark : file.children("Mark"))
	{
		auto line = mark.attribute("line").as_llong(-1);
		if (line >= 0 && line < lineCount)
			[editor message:SCI_MARKERADD wParam:line lParam:Bookmark];
	}
	for (auto fold : file.children("Fold"))
	{
		auto line = fold.attribute("line").as_llong(-1);
		if (line >= 0 && line < lineCount)
			[editor message:SCI_FOLDLINE wParam:line lParam:SC_FOLDACTION_CONTRACT];
	}
	for (const auto &field : SessionFields)
		if (auto setting = file.attribute(field.name))
			[editor message:field.write wParam:std::clamp(setting.as_llong(), 0LL, static_cast<long long>(INT_MAX))];
}

@implementation EditorDocumentController
{
	__weak EditorDocument *_activeDocument;
	NSMutableArray<EditorDocument *> *_tabOrder;
	NSPointerArray *_recentTabs;
	NSArray<EditorDocument *> *_switchTabs;
	NSPanel *_tabSwitcher;
	NSTextField *_switchList;
	NSInteger _switchIndex;
	NSHashTable<EditorDocument *> *_secondaryTabs;
	__weak EditorDocument *_otherDocument;
	EditorWorkspace *_workspace;
	EditorDockPlacement *_documentListPlacement;
	EditorDockPlacement *_searchResultsPlacement;
	EditorDockPlacement *_folderWorkspacePlacement;
	NSArray<NSURL *> *_workspaceFolders;
	BOOL _folderWorkspaceVisible;
	NSArray<EditorProjectWorkspace *> *_projectWorkspaces;
	NSArray<EditorDockPlacement *> *_projectPlacements;
	NSMutableIndexSet *_visibleProjects;
	EditorDockPlacement *_functionListPlacement;
	BOOL _functionListVisible;
	EditorDockPlacement *_documentMapPlacement;
	BOOL _documentMapVisible;
	NSArray<EditorDockPlacement *> *_insertPlacements;
	NSMutableIndexSet *_visibleInsertPanels;
	NSMutableArray<NSString *> *_clipboardEntries;
	NSTimer *_clipboardTimer;
	NSInteger _clipboardChangeCount;
	NSTimer *_fileStatusTimer;
	__weak EditorSearchMatch *_currentSearchMatch;
	BOOL _workspaceSavedForQuit;
	NSMutableArray<NSURL *> *_closedTabURLs;
}

- (void)applyImportedDockLayout
{
	NSDictionary *layout = [EditorResources.shared setting:@"windowsDockLayout" fallback:@{}];
	NSArray<NSNumber *> *sizes = WorkspaceValue(layout, @"sizes", NSArray.class);
	if (sizes.count != 4)
		return;
	NSDictionary *panels = WorkspaceValue(layout, @"panes", NSDictionary.class);
	if (!_visibleProjects)
		_visibleProjects = [NSMutableIndexSet indexSet];
	if (!_visibleInsertPanels)
		_visibleInsertPanels = [NSMutableIndexSet indexSet];
	NSDictionary<NSString *, EditorDockPlacement *> *placements = @{
		@"44070": self.documentListPlacement, @"43045": self.searchResultsPlacement,
		@"44085": self.folderWorkspacePlacement, @"44084": self.functionListPlacement, @"44080": self.documentMapPlacement,
		@"44081": self.projectPlacements[0], @"44082": self.projectPlacements[1], @"44083": self.projectPlacements[2],
		@"42052": self.insertPlacements[0], @"42051": self.insertPlacements[1]};
	for (NSString *identifier in placements)
	{
		EditorDockPlacement *placement = placements[identifier];
		NSDictionary *record = WorkspaceValue(panels, identifier, NSDictionary.class);
		if (!record)
		{
			NSInteger edge = [placement.snapshot[@"edge"] integerValue];
			if (edge >= 0 && edge < sizes.count)
				[placement restore:edge < 2 ? @{@"width": sizes[edge]} : @{@"height": sizes[edge]}];
			continue;
		}
		[placement restore:record];
		const BOOL visible = [record[@"visible"] boolValue];
		switch (identifier.integerValue)
		{
			case 44070: self.documentListVisible = visible; break;
			case 43045: self.searchResultsVisible = visible; break;
			case 44085: _folderWorkspaceVisible = visible; break;
			case 44084: _functionListVisible = visible; break;
			case 44080: _documentMapVisible = visible; break;
			case 44081: case 44082: case 44083:
			{
				NSUInteger index = identifier.integerValue - 44081;
				if (visible)
					[_visibleProjects addIndex:index];
				else
					[_visibleProjects removeIndex:index];
				break;
			}
			default:
			{
				[self setInsertPanel:identifier.integerValue == 42052 ? 0 : 1 visible:visible];
				break;
			}
		}
	}
	for (EditorDocument *document in self.documents)
		[document refreshDockPlacements];
	[self refreshSearchPanel];
	[self refreshDocumentList];
	[self refreshFolderWorkspace];
	[_activeDocument displayProjectPanels:_visibleProjects];
	[self refreshFunctionList];
	[self refreshDocumentMap];
	[self refreshInsertPanels];
	[self workspaceChanged];
}

- (EditorDockPlacement *)documentListPlacement
{
	if (!_documentListPlacement)
		_documentListPlacement = [[EditorDockPlacement alloc] initWithEdge:EditorDockLeft];
	return _documentListPlacement;
}

- (EditorDockPlacement *)searchResultsPlacement
{
	if (!_searchResultsPlacement)
		_searchResultsPlacement = [[EditorDockPlacement alloc] initWithEdge:EditorDockBottom];
	return _searchResultsPlacement;
}

- (EditorDockPlacement *)folderWorkspacePlacement
{
	if (!_folderWorkspacePlacement)
		_folderWorkspacePlacement = [[EditorDockPlacement alloc] initWithEdge:EditorDockLeft];
	return _folderWorkspacePlacement;
}

- (IBAction)chooseWorkspaceFolders:(id)sender
{
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.canChooseFiles = NO;
	panel.canChooseDirectories = YES;
	panel.allowsMultipleSelection = YES;
	panel.prompt = EditorUIString(@"Add");
	panel.directoryURL = self.focusedDocument.fileURL.URLByDeletingLastPathComponent;
	[panel beginWithCompletionHandler:^(NSModalResponse response) {
		if (response == NSModalResponseOK)
			[self addWorkspaceFolders:panel.URLs];
	}];
}

- (IBAction)toggleFolderWorkspace:(id)sender
{
	if (!_activeDocument)
		[self newDocument:nil];
	_folderWorkspaceVisible = !_folderWorkspaceVisible;
	[self refreshFolderWorkspace];
	[self workspaceChanged];
}

- (void)addWorkspaceFolders:(NSArray<NSURL *> *)folders
{
	NSMutableOrderedSet<NSURL *> *combined = [NSMutableOrderedSet orderedSetWithArray:_workspaceFolders ?: @[]];
	for (NSURL *folder in folders)
		if (EditorIsWorkspaceDirectory(folder))
			[combined addObject:folder.URLByStandardizingPath];
	if (!_activeDocument)
		[self newDocument:nil];
	_folderWorkspaceVisible = YES;
	[self setWorkspaceFolders:combined.array];
}

- (void)setWorkspaceFolders:(NSArray<NSURL *> *)folders
{
	_workspaceFolders = [folders copy];
	[self refreshFolderWorkspace];
	[self workspaceChanged];
}

- (void)refreshFolderWorkspace
{
	[_activeDocument displayFolderWorkspace:_workspaceFolders visible:_folderWorkspaceVisible];
}

- (NSArray<EditorProjectWorkspace *> *)projectWorkspaces
{
	if (!_projectWorkspaces)
		_projectWorkspaces = @[[EditorProjectWorkspace new], [EditorProjectWorkspace new], [EditorProjectWorkspace new]];
	return _projectWorkspaces;
}

- (NSArray<EditorDockPlacement *> *)projectPlacements
{
	if (!_projectPlacements)
		_projectPlacements = @[[[EditorDockPlacement alloc] initWithEdge:EditorDockRight],
			[[EditorDockPlacement alloc] initWithEdge:EditorDockRight], [[EditorDockPlacement alloc] initWithEdge:EditorDockRight]];
	return _projectPlacements;
}

- (IBAction)toggleProjectPanel:(NSMenuItem *)sender
{
	[self setProjectPanel:sender.tag visible:![_visibleProjects containsIndex:sender.tag]];
}

- (void)setProjectPanel:(NSUInteger)index visible:(BOOL)visible
{
	if (index >= self.projectWorkspaces.count)
		return;
	if (!_activeDocument && visible)
		[self newDocument:nil];
	if (!_visibleProjects)
		_visibleProjects = [NSMutableIndexSet indexSet];
	if (visible)
		[_visibleProjects addIndex:index];
	else
		[_visibleProjects removeIndex:index];
	[_activeDocument displayProjectPanels:_visibleProjects];
	[self workspaceChanged];
}

- (EditorDockPlacement *)functionListPlacement
{
	if (!_functionListPlacement)
		_functionListPlacement = [[EditorDockPlacement alloc] initWithEdge:EditorDockRight];
	return _functionListPlacement;
}

- (void)refreshFunctionList
{
	[_activeDocument displayFunctionsOf:self.focusedDocument visible:_functionListVisible];
}

- (IBAction)toggleFunctionList:(id)sender
{
	if (!_activeDocument)
		[self newDocument:nil];
	_functionListVisible = !_functionListVisible;
	[self refreshFunctionList];
	[self workspaceChanged];
}

- (EditorDockPlacement *)documentMapPlacement
{
	if (!_documentMapPlacement)
		_documentMapPlacement = [[EditorDockPlacement alloc] initWithEdge:EditorDockRight];
	return _documentMapPlacement;
}

- (void)refreshDocumentMap
{
	[_activeDocument displayDocumentMap:self.focusedDocument.editor visible:_documentMapVisible];
}

- (IBAction)toggleDocumentMap:(id)sender
{
	if (!_activeDocument)
		[self newDocument:nil];
	_documentMapVisible = !_documentMapVisible;
	[self refreshDocumentMap];
	[self workspaceChanged];
}

- (NSArray<EditorDockPlacement *> *)insertPlacements
{
	if (!_insertPlacements)
		_insertPlacements = @[[[EditorDockPlacement alloc] initWithEdge:EditorDockRight],
			[[EditorDockPlacement alloc] initWithEdge:EditorDockBottom]];
	return _insertPlacements;
}

- (void)captureClipboardChange
{
	NSPasteboard *clipboard = NSPasteboard.generalPasteboard;
	const NSInteger count = clipboard.changeCount;
	if (_clipboardChangeCount == count)
		return;
	_clipboardChangeCount = count;
	NSString *entry = [clipboard stringForType:NSPasteboardTypeString];
	if (!entry.length || [entry lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024 * 1024)
		return;
	if (!_clipboardEntries)
		_clipboardEntries = [NSMutableArray array];
	[_clipboardEntries removeObject:entry];
	[_clipboardEntries insertObject:entry atIndex:0];
	if (_clipboardEntries.count > 32)
		[_clipboardEntries removeLastObject];
	[self refreshInsertPanels];
}

- (void)startClipboardHistory
{
	if (_clipboardTimer)
		return;
	_clipboardChangeCount = NSPasteboard.generalPasteboard.changeCount - 1;
	[self captureClipboardChange];
	__weak EditorDocumentController *weakSelf = self;
	_clipboardTimer = [NSTimer timerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *timer) {
		[weakSelf captureClipboardChange];
	}];
	[NSRunLoop.mainRunLoop addTimer:_clipboardTimer forMode:NSRunLoopCommonModes];
}

- (IBAction)toggleInsertPanel:(NSMenuItem *)sender
{
	[self setInsertPanel:sender.tag visible:![_visibleInsertPanels containsIndex:sender.tag]];
}

- (void)setInsertPanel:(NSUInteger)index visible:(BOOL)visible
{
	if (index >= self.insertPlacements.count)
		return;
	if (!_activeDocument && visible)
		[self newDocument:nil];
	if (!_visibleInsertPanels)
		_visibleInsertPanels = [NSMutableIndexSet indexSet];
	if (visible)
	{
		[_visibleInsertPanels addIndex:index];
		if (index == 0)
			[self startClipboardHistory];
	}
	else
	{
		[_visibleInsertPanels removeIndex:index];
		if (index == 0)
		{
			[_clipboardTimer invalidate];
			_clipboardTimer = nil;
		}
	}
	[self refreshInsertPanels];
	[self workspaceChanged];
}

- (void)refreshInsertPanels
{
	[_activeDocument displayInsertPanels:_visibleInsertPanels clipboard:_clipboardEntries encoding:[self.focusedDocument currentTextEncoding]];
}

- (void)insertPanelText:(NSString *)text
{
	EditorDocument *document = self.focusedDocument;
	ScintillaView *editor = document.editor;
	if (!editor || [editor message:SCI_GETREADONLY])
		return;
	NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
	const auto start = [editor message:SCI_GETSELECTIONSTART];
	const auto end = [editor message:SCI_GETSELECTIONEND];
	[editor message:SCI_SETTARGETRANGE wParam:start lParam:end];
	[editor message:SCI_REPLACETARGET wParam:bytes.length lParam:reinterpret_cast<sptr_t>(bytes.bytes)];
	[document focusEditor];
	[editor message:SCI_GOTOPOS wParam:start + bytes.length];
}

- (NSArray<EditorDocument *> *)tabDocuments
{
	NSArray<EditorDocument *> *documents = (NSArray<EditorDocument *> *)self.documents;
	if (!_tabOrder)
		_tabOrder = [NSMutableArray array];
	for (EditorDocument *document in documents)
		if (![_tabOrder containsObject:document])
			[_tabOrder addObject:document];
	NSMutableArray<EditorDocument *> *ordered = [NSMutableArray arrayWithCapacity:_tabOrder.count];
	for (BOOL pinned : {YES, NO})
		for (EditorDocument *document in _tabOrder)
			if (document.isTabPinned == pinned)
				[ordered addObject:document];
	return ordered;
}

- (NSArray<EditorDocument *> *)tabsInOtherView:(BOOL)other
{
	if (other && !_otherDocument && _activeDocument.clonedEditorView)
		return @[_activeDocument];
	NSMutableArray<EditorDocument *> *tabs = [NSMutableArray array];
	for (EditorDocument *document in self.tabDocuments)
		if ([_secondaryTabs containsObject:document] == other)
			[tabs addObject:document];
	return tabs;
}

- (EditorDocument *)selectedTabInOtherView:(BOOL)other
{
	return other ? (_otherDocument ?: (_activeDocument.clonedEditorView ? _activeDocument : nil)) : _activeDocument;
}

- (void)activateTab:(EditorDocument *)document otherView:(BOOL)other
{
	if (document == _activeDocument && document.clonedEditorView)
	{
		if (other)
			[document focusClonedEditor];
		else
			[document focusPrimaryEditor];
	}
	else
		[document showWindows];
}

- (void)dropTab:(EditorDocument *)document before:(EditorDocument *)anchor otherView:(BOOL)other
{
	if (![self.tabDocuments containsObject:document])
		return;
	BOOL wasOther = [_secondaryTabs containsObject:document];
	if (other != wasOther)
		[self showInOtherView:document];
	if (document != anchor)
	{
		[_tabOrder removeObjectIdenticalTo:document];
		NSUInteger index = anchor ? [_tabOrder indexOfObjectIdenticalTo:anchor] : NSNotFound;
		[_tabOrder insertObject:document atIndex:index == NSNotFound ? _tabOrder.count : index];
	}
	[self activateTab:document otherView:other];
	[self refreshDocumentTabs];
	[self workspaceChanged];
}

- (void)moveTab:(EditorDocument *)document toEnd:(BOOL)toEnd
{
	if (![self.tabDocuments containsObject:document])
		return;
	[_tabOrder removeObjectIdenticalTo:document];
	[_tabOrder insertObject:document atIndex:toEnd ? _tabOrder.count : 0];
	[self refreshDocumentTabs];
	[self workspaceChanged];
}

- (void)reorderTabs:(NSArray<EditorDocument *> *)documents
{
	(void)self.tabDocuments;
	NSArray *sorted = [[NSOrderedSet orderedSetWithArray:documents].array filteredArrayUsingPredicate:
		[NSPredicate predicateWithBlock:^BOOL(EditorDocument *document, NSDictionary *bindings) {
			return [_tabOrder containsObject:document];
		}]];
	NSSet *requested = [NSSet setWithArray:sorted];
	NSIndexSet *positions = [_tabOrder indexesOfObjectsPassingTest:^BOOL(EditorDocument *document, NSUInteger index, BOOL *stop) {
		return [requested containsObject:document];
	}];
	[_tabOrder replaceObjectsAtIndexes:positions withObjects:sorted];
	[self refreshDocumentTabs];
	[self workspaceChanged];
}

- (void)noteFocusedTab:(EditorDocument *)document
{
	if (!document || ![self.documents containsObject:document])
		return;
	NSArray *old = _recentTabs.allObjects;
	if (old.firstObject == document)
		return;
	_recentTabs = NSPointerArray.weakObjectsPointerArray;
	[_recentTabs addPointer:(__bridge void *)document];
	for (EditorDocument *candidate in old)
		if (candidate != document)
			[_recentTabs addPointer:(__bridge void *)candidate];
}

- (BOOL)cycleRecentTabsBackwards:(BOOL)backwards
{
	if (![[EditorResources.shared setting:@"mruTabSwitcher" fallback:@YES] boolValue])
		return NO;
	if (!_switchTabs)
	{
		NSArray *tabs = self.tabDocuments;
		if (tabs.count < 2)
			return NO;
		NSMutableOrderedSet *order = [NSMutableOrderedSet orderedSetWithArray:_recentTabs.allObjects ?: @[]];
		[order intersectOrderedSet:[NSOrderedSet orderedSetWithArray:tabs]];
		[order addObjectsFromArray:tabs];
		_switchTabs = order.array;
		NSUInteger index = [_switchTabs indexOfObjectIdenticalTo:self.focusedDocument];
		_switchIndex = index == NSNotFound ? 0 : index;
		_tabSwitcher = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 370, 175)
			styleMask:NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		_tabSwitcher.title = [EditorResources.shared label:@"view-tab-switcher" fallback:@"Open Documents"];
		_tabSwitcher.floatingPanel = YES;
		_tabSwitcher.hidesOnDeactivate = YES;
		_switchList = [NSTextField wrappingLabelWithString:@""];
		_switchList.frame = NSInsetRect(_tabSwitcher.contentView.bounds, 10, 8);
		[_tabSwitcher.contentView addSubview:_switchList];
		NSRect parent = NSApp.keyWindow.frame;
		[_tabSwitcher setFrameOrigin:NSMakePoint(NSMidX(parent) - 185, NSMidY(parent) - 88)];
		[_tabSwitcher orderFront:nil];
	}
	const NSInteger count = _switchTabs.count;
	_switchIndex = (_switchIndex + count + (backwards ? -1 : 1)) % count;
	NSMutableAttributedString *lines = [[NSMutableAttributedString alloc] initWithString:@""];
	const NSInteger first = std::clamp<NSInteger>(_switchIndex - 3, 0, std::max<NSInteger>(0, count - 8));
	for (NSInteger i = first; i < MIN(first + 8, count); ++i)
	{
		BOOL active = i == _switchIndex;
		NSFont *font = active ? [NSFont boldSystemFontOfSize:14] : [NSFont systemFontOfSize:13];
		NSString *line = [NSString stringWithFormat:@"%@ %@\n", active ? @"›" : @" ", _switchTabs[i].displayName];
		[lines appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:@{NSFontAttributeName: font}]];
	}
	_switchList.attributedStringValue = lines;
	return YES;
}

- (BOOL)finishRecentTabSwitch:(BOOL)accept
{
	if (!_switchTabs)
		return NO;
	EditorDocument *document = _switchTabs[_switchIndex];
	[_tabSwitcher orderOut:nil];
	_tabSwitcher = nil;
	_switchList = nil;
	_switchTabs = nil;
	if (accept && [self.documents containsObject:document])
		[document showWindows];
	return YES;
}

- (IBAction)navigateTab:(NSMenuItem *)item
{
	EditorDocument *document = self.focusedDocument;
	const BOOL other = [_secondaryTabs containsObject:document] ||
		(document.clonedEditorView && document.editor == document.clonedEditorView);
	NSArray<EditorDocument *> *tabs = [self tabsInOtherView:other];
	NSInteger count = tabs.count;
	NSUInteger current = [tabs indexOfObjectIdenticalTo:document];
	if (!count || current == NSNotFound)
		return;
	NSInteger command = item.tag;
	if (command >= 44110 && command <= 44115)
	{
		[document changeTabColor:command - 44110];
		return;
	}
	if (command == 10005 || command == 10006)
	{
		[self moveTab:document toEnd:command == 10006];
		return;
	}
	if (command == 44098 || command == 44099)
	{
		NSInteger target = static_cast<NSInteger>(current) + (command == 44098 ? 1 : -1);
		if (target >= 0 && target < count && document.isTabPinned == tabs[target].isTabPinned)
		{
			[_tabOrder exchangeObjectAtIndex:[_tabOrder indexOfObjectIdenticalTo:document]
				withObjectAtIndex:[_tabOrder indexOfObjectIdenticalTo:tabs[target]]];
			[self refreshDocumentTabs];
			[self workspaceChanged];
		}
		return;
	}
	NSInteger target = command >= 44086 && command <= 44094 ? command - 44086 :
		command == 44116 ? 0 : command == 44117 ? count - 1 :
		(static_cast<NSInteger>(current) + count + (command == 44095 ? 1 : -1)) % count;
	if (target < count)
		[self activateTab:tabs[target] otherView:other];
}

- (void)prepareToShowDocument:(EditorDocument *)document
{
	NSWindow *previous = _activeDocument.windowControllers.firstObject.window;
	NSWindow *next = document.windowControllers.firstObject.window;
	if (_activeDocument != document)
	{
		[_activeDocument displayOtherDocument:nil];
		[_activeDocument displaySearchReports:nil purge:NO match:nil visible:NO];
		[_activeDocument displayDocumentList:nil otherView:nil focused:nil focusOther:NO groupByView:NO visible:NO];
		[_activeDocument displayFolderWorkspace:nil visible:NO];
		[_activeDocument displayProjectPanels:nil];
		[_activeDocument displayFunctionsOf:nil visible:NO];
		[_activeDocument displayDocumentMap:nil visible:NO];
		[_activeDocument displayInsertPanels:nil clipboard:nil encoding:0];
		_activeDocument = document;
		if (previous.visible)
		{
			[next setFrame:previous.frame display:NO];
			[previous orderOut:nil];
		}
		[document displayOtherDocument:_otherDocument];
	}
	[self noteFocusedTab:document];
	[self refreshSearchPanel];
	[document applySplitRotation:self.splitRotation];
	[self refreshDocumentTabs];
	[self refreshFolderWorkspace];
	[document displayProjectPanels:_visibleProjects];
	[self refreshFunctionList];
	[self refreshDocumentMap];
	[self refreshInsertPanels];
	if (!_fileStatusTimer)
	{
		__weak EditorDocumentController *weakSelf = self;
		_fileStatusTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
			[weakSelf checkOpenFilesOnDisk];
		}];
	}
	[self workspaceChanged];
	NotifyPlugins(document, MACPAD_DOCUMENT_ACTIVATED);
}

- (void)checkOpenFilesOnDisk
{
	const NSInteger mode = [[EditorResources.shared setting:@"fileStatusMode" fallback:@1] integerValue];
	const BOOL appActive = NSApp.active;
	EditorDocument *focus = self.focusedDocument;
	for (EditorDocument *document in self.documents)
	{
		NSWindow *window = _activeDocument.windowControllers.firstObject.window;
		[document checkDiskChanges:appActive && (mode == 2 || (mode == 1 && document == focus))
			allowPrompt:appActive && window.visible && window.keyWindow && !window.attachedSheet];
	}
}

- (EditorDocument *)focusedDocument
{
	NSResponder *responder = _activeDocument.windowControllers.firstObject.window.firstResponder;
	if (_otherDocument && [responder isKindOfClass:NSView.class] &&
		[(NSView *)responder isDescendantOf:_otherDocument.editor])
		return _otherDocument;
	return _activeDocument;
}

- (EditorDocument *)windowOwnerForDocument:(EditorDocument *)document
{
	return document == _otherDocument ? _activeDocument : document;
}

- (BOOL)focusOtherViewDocument:(EditorDocument *)document
{
	if (!_activeDocument || ![_secondaryTabs containsObject:document])
		return NO;
	_otherDocument = document;
	[_activeDocument displayOtherDocument:document];
	[document focusEditor];
	[self noteFocusedTab:document];
	[self refreshDocumentTabs];
	[self workspaceChanged];
	return YES;
}

- (BOOL)hasOtherView
{
	return _otherDocument || _activeDocument.companionClone;
}

- (void)syncScrollFromDocument:(EditorDocument *)document changes:(int)changes
{
	if (document != self.focusedDocument)
		return;
	ScintillaView *source = document.editor;
	ScintillaView *other = _otherDocument ? (document == _otherDocument ? _activeDocument : _otherDocument).editor : document.companionClone;
	if (!other)
		return;
	if (self.syncVerticalScroll && (changes & SC_UPDATE_V_SCROLL))
	{
		auto firstLine = [source message:SCI_GETFIRSTVISIBLELINE];
		if (firstLine != [other message:SCI_GETFIRSTVISIBLELINE])
			[other message:SCI_SETFIRSTVISIBLELINE wParam:firstLine];
	}
	if (self.syncHorizontalScroll && (changes & SC_UPDATE_H_SCROLL))
	{
		auto offset = [source message:SCI_GETXOFFSET];
		if (offset != [other message:SCI_GETXOFFSET])
			[other message:SCI_SETXOFFSET wParam:offset];
	}
}

- (void)syncZoomFromDocument:(EditorDocument *)document
{
	if (!self.syncZoom || document != self.focusedDocument)
		return;
	ScintillaView *source = document.editor;
	ScintillaView *other = _otherDocument ? (document == _otherDocument ? _activeDocument : _otherDocument).editor : document.companionClone;
	const auto zoom = [source message:SCI_GETZOOM];
	if (other && [other message:SCI_GETZOOM] != zoom)
		[other message:SCI_SETZOOM wParam:zoom];
}

- (void)showInOtherView:(EditorDocument *)document
{
	if (!_activeDocument || !document)
		return;
	if ([_secondaryTabs containsObject:document])
	{
		[_secondaryTabs removeObject:document];
		if (_otherDocument == document)
		{
			[_activeDocument displayOtherDocument:nil];
			_otherDocument = [self tabsInOtherView:YES].firstObject;
		}
		[document showWindows];
		return;
	}
	EditorDocument *replacement = _activeDocument;
	if (_activeDocument == document)
	{
		replacement = nil;
		for (EditorDocument *candidate in [self tabsInOtherView:NO].reverseObjectEnumerator)
			if (candidate != document)
			{
				replacement = candidate;
				break;
			}
		if (!replacement)
		{
			NSError *error = nil;
			replacement = [self makeUntitledDocumentOfType:self.defaultType error:&error];
			if (!replacement)
			{
				if (error)
					[NSApp presentError:error];
				return;
			}
			[self addDocument:replacement];
			[replacement makeWindowControllers];
		}
	}
	if (!_secondaryTabs)
		_secondaryTabs = NSHashTable.weakObjectsHashTable;
	[_secondaryTabs addObject:document];
	if (replacement != _activeDocument)
		[replacement showWindows];
	[self focusOtherViewDocument:document];
}

- (void)hideOtherView
{
	[_activeDocument displayOtherDocument:nil];
	[_activeDocument closeClonedView];
	_otherDocument = nil;
	[_secondaryTabs removeAllObjects];
	[_activeDocument focusEditor];
	[self refreshDocumentTabs];
	[self workspaceChanged];
}

- (void)prepareToCloseDocument:(EditorDocument *)document
{
	[_secondaryTabs removeObject:document];
	if (document == _otherDocument)
	{
		_otherDocument = [self tabsInOtherView:YES].firstObject;
		[_activeDocument displayOtherDocument:_otherDocument];
		[(_otherDocument ?: _activeDocument) focusEditor];
	}
	else if (document == _activeDocument)
		[document displayOtherDocument:nil];
}

- (void)restoreViewsWithPrimary:(EditorDocument *)primary other:(EditorDocument *)other focusOther:(BOOL)focusOther
{
	if (!primary)
	{
		primary = other;
		other = nil;
	}
	if (!primary)
		return;
	[_activeDocument displayOtherDocument:nil];
	_otherDocument = other != primary ? other : nil;
	if (!_secondaryTabs)
		_secondaryTabs = NSHashTable.weakObjectsHashTable;
	[_secondaryTabs removeObject:primary];
	if (_otherDocument)
		[_secondaryTabs addObject:_otherDocument];
	[primary showWindows];
	[primary displayOtherDocument:_otherDocument];
	if (other == primary)
		[primary cloneToOtherView:nil];
	if (focusOther && _otherDocument)
		[_otherDocument focusEditor];
	else if (other == primary && !focusOther)
		[primary focusPrimaryEditor];
	[self refreshDocumentTabs];
}

- (void)removeDocument:(NSDocument *)document
{
	NSArray<EditorDocument *> *documents = self.tabDocuments;
	NSUInteger index = [documents indexOfObjectIdenticalTo:(EditorDocument *)document];
	NSURL *closedURL = document.fileURL;
	if (index != NSNotFound && closedURL.isFileURL && !_workspaceSavedForQuit)
	{
		if (!_closedTabURLs)
			_closedTabURLs = [NSMutableArray array];
		[_closedTabURLs removeObject:closedURL];
		[_closedTabURLs addObject:closedURL];
		if (_closedTabURLs.count > 30)
			[_closedTabURLs removeObjectAtIndex:0];
	}
	BOOL wasActive = document == _activeDocument;
	NSRect frame = document.windowControllers.firstObject.window.frame;
	[super removeDocument:document];
	NotifyPlugins((EditorDocument *)document, MACPAD_DOCUMENT_CLOSED);
	[_tabOrder removeObjectIdenticalTo:(EditorDocument *)document];
	if (wasActive)
	{
		_activeDocument = nil;
		NSArray<EditorDocument *> *remaining = [self tabsInOtherView:NO];
		if (!remaining.count)
			remaining = [self tabsInOtherView:YES];
		if (remaining.count)
		{
			NSDocument *replacement = remaining[MIN(index, remaining.count - 1)];
			[_secondaryTabs removeObject:(EditorDocument *)replacement];
			if (replacement == _otherDocument)
				_otherDocument = [self tabsInOtherView:YES].firstObject;
			if (!NSIsEmptyRect(frame))
				[replacement.windowControllers.firstObject.window setFrame:frame display:NO];
			[replacement showWindows];
		}
	}
	[self refreshDocumentTabs];
	[self workspaceChanged];
}

- (void)addDocument:(NSDocument *)document
{
	[super addDocument:document];
	NotifyPlugins((EditorDocument *)document, MACPAD_DOCUMENT_OPENED);
}

- (NSURL *)closedTabURL
{
	for (NSURL *url in _closedTabURLs.reverseObjectEnumerator)
		if (![self documentForURL:url] && [NSFileManager.defaultManager fileExistsAtPath:url.path])
			return url;
	for (NSURL *url in self.recentDocumentURLs)
		if (![self documentForURL:url] && [NSFileManager.defaultManager fileExistsAtPath:url.path])
			return url;
	return nil;
}

- (BOOL)canReopenClosedTab { return self.closedTabURL != nil; }

- (IBAction)reopenClosedTab:(id)sender
{
	NSURL *url = self.closedTabURL;
	if (!url)
		return;
	[self openDocumentWithContentsOfURL:url display:YES completionHandler:^(NSDocument *document, BOOL alreadyOpen, NSError *error) {
		if (document)
			[self->_closedTabURLs removeObject:url];
		else if (error)
			[NSApp presentError:error];
	}];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
	if (item.action == @selector(reopenClosedTab:))
		return self.canReopenClosedTab;
	if (item.action == @selector(saveAllDocuments:))
		return self.canSaveAllDocuments;
	if (item.action == @selector(setAllDocumentsReadOnly:))
		return [self canSetAllDocumentsReadOnly:item.tag == 42102];
	return [super validateUserInterfaceItem:item];
}

- (void)refreshDocumentTabs
{
	for (EditorDocument *document in self.documents)
		[document.chrome refreshTabs];
	[self refreshDocumentList];
}

- (BOOL)canSaveAllDocuments
{
	return !self.launchOptions.savingForbidden && self.hasEditedDocuments;
}

- (IBAction)saveAllDocuments:(id)sender
{
	if (!self.canSaveAllDocuments)
		return;
	EditorResources *resources = EditorResources.shared;
	if ([[resources setting:@"saveAllConfirm" fallback:@YES] boolValue])
	{
		NSAlert *alert = [NSAlert new];
		alert.messageText = [resources label:@"DoSaveAll:title" fallback:@"Save All Confirmation"];
		alert.informativeText = [resources label:@"DoSaveAll:1766" fallback:@"Are you sure you want to save all modified documents?"];
		[alert addButtonWithTitle:[resources label:@"DoSaveAll:6" fallback:@"Yes"]];
		NSButton *cancel = [alert addButtonWithTitle:[resources label:@"DoSaveAll:7" fallback:@"No"]];
		cancel.keyEquivalent = @"\033";
		[alert addButtonWithTitle:[resources label:@"DoSaveAll:4" fallback:@"Always yes"]];
		NSModalResponse response = [alert runModal];
		if (response == NSAlertThirdButtonReturn)
			[resources setSetting:@NO forName:@"saveAllConfirm"];
		else if (response != NSAlertFirstButtonReturn)
			return;
	}
	[super saveAllDocuments:sender];
}

- (BOOL)canSetAllDocumentsReadOnly:(BOOL)readOnly
{
	if (!readOnly && self.launchOptions.savingForbidden)
		return NO;
	for (EditorDocument *document in self.documents)
		if (document.editor && document.userReadOnly != readOnly)
			return YES;
	return NO;
}

- (IBAction)setAllDocumentsReadOnly:(NSMenuItem *)sender
{
	const BOOL readOnly = sender.tag == 42102;
	if (![self canSetAllDocumentsReadOnly:readOnly])
		return;
	for (EditorDocument *document in self.documents)
		[document setUserReadOnly:readOnly];
	[self refreshDocumentTabs];
}

- (void)refreshDocumentList
{
	NSArray<EditorDocument *> *primary = [self tabsInOtherView:NO];
	NSArray<EditorDocument *> *other = [self tabsInOtherView:YES];
	EditorDocument *focused = self.focusedDocument;
	BOOL focusOther = _otherDocument ? focused == _otherDocument :
		_activeDocument.clonedEditorView && _activeDocument.editor == _activeDocument.clonedEditorView;
	[_activeDocument displayDocumentList:primary otherView:other focused:focused focusOther:focusOther
		groupByView:!self.documentListUngrouped visible:self.documentListVisible];
}

- (void)startWorkspaceRecoveryAtDirectory:(NSURL *)directory
{
	_workspace = [[EditorWorkspace alloc] initWithController:self];
	if (![_workspace startAtDirectory:directory])
		_workspace = nil;
}

- (void)workspaceChanged
{
	if (!_workspaceSavedForQuit)
		[_workspace scheduleCheckpoint];
}

- (void)finishWorkspaceRecovery
{
	if (!_workspaceSavedForQuit)
		[_workspace checkpoint];
}

- (void)reviewUnsavedDocumentsWithAlertTitle:(NSString *)title cancellable:(BOOL)cancellable
	delegate:(id)delegate didReviewAllSelector:(SEL)selector contextInfo:(void *)context
{
	// AppKit calls this before quitting. Keep its save prompts if recovery cannot write the workspace.
	if (delegate && selector && [delegate respondsToSelector:selector] && [_workspace checkpoint])
	{
		_workspaceSavedForQuit = YES;
		using ReviewCallback = void (*)(id, SEL, NSDocumentController *, BOOL, void *);
		auto finished = reinterpret_cast<ReviewCallback>([delegate methodForSelector:selector]);
		finished(delegate, selector, self, YES, context);
		return;
	}
	[super reviewUnsavedDocumentsWithAlertTitle:title cancellable:cancellable delegate:delegate
		didReviewAllSelector:selector contextInfo:context];
}

- (NSDictionary<NSString *, id> *)captureWorkspace
{
	NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
	NSMutableArray<NSDictionary *> *projects = [NSMutableArray array];
	for (NSUInteger index = 0; index < self.projectWorkspaces.count; ++index)
		[projects addObject:@{@"workspace": self.projectWorkspaces[index].snapshot,
			@"placement": self.projectPlacements[index].snapshot, @"visible": @([_visibleProjects containsIndex:index])}];
	NSUInteger active = 0;
	NSInteger other = -1;
	for (EditorDocument *document in self.tabDocuments)
	{
		if (document == _activeDocument)
			active = entries.count;
		if (document == _otherDocument)
			other = entries.count;
		NSMutableDictionary *entry = [[document workspaceEntry] mutableCopy];
		entry[@"secondary"] = @([_secondaryTabs containsObject:document]);
		[entries addObject:entry];
	}
	return @{@"version": @1, @"documents": entries, @"active": @(active), @"other": @(other),
		@"focusOther": @(_otherDocument && self.focusedDocument == _otherDocument),
		@"syncVertical": @(self.syncVerticalScroll), @"syncHorizontal": @(self.syncHorizontalScroll), @"syncZoom": @(self.syncZoom),
		@"splitRotation": @(self.splitRotation),
		@"purgeSearchReports": @(self.purgeSearchReports),
		@"documentList": @(self.documentListVisible),
		@"documentListUngrouped": @(self.documentListUngrouped),
		@"documentListPlacement": self.documentListPlacement.snapshot,
		@"searchResultsPlacement": self.searchResultsPlacement.snapshot,
		@"folderWorkspaceVisible": @(_folderWorkspaceVisible),
		@"folderWorkspacePlacement": self.folderWorkspacePlacement.snapshot,
		@"functionListPlacement": self.functionListPlacement.snapshot, @"functionListVisible": @(_functionListVisible),
		@"documentMapPlacement": self.documentMapPlacement.snapshot, @"documentMapVisible": @(_documentMapVisible),
		@"insertPlacements": [self.insertPlacements valueForKey:@"snapshot"],
		@"clipboardVisible": @([_visibleInsertPanels containsIndex:0]), @"charactersVisible": @([_visibleInsertPanels containsIndex:1]),
		@"workspaceFolders": [_workspaceFolders valueForKey:@"path"] ?: @[], @"projects": projects};
}

- (void)restoreWorkspace:(NSDictionary<NSString *, id> *)snapshot
{
	NSArray *entries = WorkspaceValue(snapshot, @"documents", NSArray.class);
	self.syncVerticalScroll = [WorkspaceValue(snapshot, @"syncVertical", NSNumber.class) boolValue];
	self.syncHorizontalScroll = [WorkspaceValue(snapshot, @"syncHorizontal", NSNumber.class) boolValue];
	self.syncZoom = [WorkspaceValue(snapshot, @"syncZoom", NSNumber.class) boolValue];
	self.splitRotation = [WorkspaceValue(snapshot, @"splitRotation", NSNumber.class) unsignedIntegerValue] % 4;
	self.purgeSearchReports = [WorkspaceValue(snapshot, @"purgeSearchReports", NSNumber.class) boolValue];
	self.documentListVisible = [WorkspaceValue(snapshot, @"documentList", NSNumber.class) boolValue];
	self.documentListUngrouped = [WorkspaceValue(snapshot, @"documentListUngrouped", NSNumber.class) boolValue];
	[self.documentListPlacement restore:WorkspaceValue(snapshot, @"documentListPlacement", NSDictionary.class)];
	[self.searchResultsPlacement restore:WorkspaceValue(snapshot, @"searchResultsPlacement", NSDictionary.class)];
	[self.folderWorkspacePlacement restore:WorkspaceValue(snapshot, @"folderWorkspacePlacement", NSDictionary.class)];
	[self.functionListPlacement restore:WorkspaceValue(snapshot, @"functionListPlacement", NSDictionary.class)];
	_functionListVisible = [WorkspaceValue(snapshot, @"functionListVisible", NSNumber.class) boolValue];
	[self.documentMapPlacement restore:WorkspaceValue(snapshot, @"documentMapPlacement", NSDictionary.class)];
	_documentMapVisible = [WorkspaceValue(snapshot, @"documentMapVisible", NSNumber.class) boolValue];
	NSArray *insertPlacements = WorkspaceValue(snapshot, @"insertPlacements", NSArray.class);
	for (NSUInteger index = 0; index < MIN(self.insertPlacements.count, insertPlacements.count); ++index)
		[self.insertPlacements[index] restore:insertPlacements[index]];
	_visibleInsertPanels = [NSMutableIndexSet indexSet];
	if ([WorkspaceValue(snapshot, @"clipboardVisible", NSNumber.class) boolValue])
	{
		[_visibleInsertPanels addIndex:0];
		[self startClipboardHistory];
	}
	if ([WorkspaceValue(snapshot, @"charactersVisible", NSNumber.class) boolValue])
		[_visibleInsertPanels addIndex:1];
	_folderWorkspaceVisible = [WorkspaceValue(snapshot, @"folderWorkspaceVisible", NSNumber.class) boolValue];
	NSMutableArray<NSURL *> *folders = [NSMutableArray array];
	for (id path in WorkspaceValue(snapshot, @"workspaceFolders", NSArray.class))
		if ([path isKindOfClass:NSString.class] && [path isAbsolutePath])
			[folders addObject:[NSURL fileURLWithPath:path isDirectory:YES]];
	_workspaceFolders = [folders copy];
	_visibleProjects = [NSMutableIndexSet indexSet];
	NSArray *projects = WorkspaceValue(snapshot, @"projects", NSArray.class);
	for (NSUInteger index = 0; index < MIN(self.projectWorkspaces.count, projects.count); ++index)
	{
		NSDictionary *project = projects[index];
		if (![project isKindOfClass:NSDictionary.class])
			continue;
		[self.projectWorkspaces[index] restore:WorkspaceValue(project, @"workspace", NSDictionary.class)];
		[self.projectPlacements[index] restore:WorkspaceValue(project, @"placement", NSDictionary.class)];
		if ([WorkspaceValue(project, @"visible", NSNumber.class) boolValue])
			[_visibleProjects addIndex:index];
	}
	NSUInteger activeIndex = [WorkspaceValue(snapshot, @"active", NSNumber.class) unsignedIntegerValue];
	NSNumber *otherIndex = WorkspaceValue(snapshot, @"other", NSNumber.class);
	EditorDocument *first = nil;
	EditorDocument *active = nil;
	EditorDocument *other = nil;
	_secondaryTabs = NSHashTable.weakObjectsHashTable;
	for (NSUInteger i = 0; i < entries.count; ++i)
	{
		id entry = entries[i];
		if (![entry isKindOfClass:NSDictionary.class])
			continue;
		NSString *path = WorkspaceValue(entry, @"path", NSString.class);
		NSData *unsaved = WorkspaceValue(entry, @"unsavedUTF8", NSData.class);
		NSURL *url = path.isAbsolutePath ? [NSURL fileURLWithPath:path] : nil;
		EditorDocument *document = nil;
		if (url && ![self documentForURL:url])
		{
			NSString *type = [self typeForContentsOfURL:url error:nullptr];
			auto explicitEncoding = [WorkspaceValue(entry, @"readerEncoding", NSNumber.class) unsignedIntegerValue];
			if (type && IsAvailableEncoding(explicitEncoding))
			{
				document = [self makeUntitledDocumentOfType:type error:nullptr];
				[document setReaderEncoding:explicitEncoding];
				if ([document readFromURL:url ofType:type error:nullptr])
				{
					document.fileURL = url;
					NSDate *modification = nil;
					[url getResourceValue:&modification forKey:NSURLContentModificationDateKey error:nullptr];
					document.fileModificationDate = modification;
				}
				else
					document = nil;
			}
			else if (type)
				document = [self makeDocumentWithContentsOfURL:url ofType:type error:nullptr];
			if (unsaved && document)
			{
				NSDate *modified = WorkspaceValue(entry, @"fileModified", NSDate.class);
				if (modified && ![modified isEqual:document.fileModificationDate])
					document = nil;
			}
		}
		if (!document && (!path.length || unsaved))
			document = [self makeUntitledDocumentOfType:self.defaultType error:nullptr];
		if (!document)
			continue;
		[self addDocument:document];
		if ([WorkspaceValue(entry, @"secondary", NSNumber.class) boolValue])
			[_secondaryTabs addObject:document];
		[document restoreWorkspaceEntry:entry];
		if (!first)
			first = document;
		if (i == activeIndex)
			active = document;
		if (otherIndex && i == otherIndex.unsignedIntegerValue)
			other = document;
	}
	[self restoreViewsWithPrimary:active ?: first other:other ?: [self tabsInOtherView:YES].firstObject
		focusOther:[WorkspaceValue(snapshot, @"focusOther", NSNumber.class) boolValue]];
}

- (void)setSearchResultsVisible:(BOOL)visible
{
	_searchResultsVisible = visible;
	[self refreshSearchPanel];
}

- (void)refreshSearchPanel
{
	[_activeDocument displaySearchReports:self.searchReports purge:self.purgeSearchReports
		match:_currentSearchMatch visible:self.searchResultsVisible];
}

- (void)showSearchReport:(EditorSearchReport *)report
{
	_currentSearchMatch = nil;
	self.searchReports = self.purgeSearchReports ? @[report] : [@[report] arrayByAddingObjectsFromArray:self.searchReports ?: @[]];
	self.searchResultsVisible = YES;
}

- (IBAction)stepSearchResult:(NSMenuItem *)sender
{
	NSMutableArray<EditorSearchMatch *> *matches = [NSMutableArray array];
	for (EditorSearchReport *report in self.searchReports)
		for (EditorSearchFile *file in report.files)
			[matches addObjectsFromArray:file.matches];
	if (!matches.count)
		return;
	NSInteger index = [matches indexOfObjectIdenticalTo:_currentSearchMatch];
	if (index == NSNotFound)
		index = sender.tag < 0 ? 0 : -1;
	for (NSUInteger attempt = 0; attempt < matches.count; ++attempt)
	{
		index = (index + (NSInteger)matches.count + sender.tag) % (NSInteger)matches.count;
		EditorSearchMatch *match = matches[index];
		if (match.url || [self.documents containsObject:match.document])
		{
			self.searchResultsVisible = YES;
			[self openSearchMatch:match];
			return;
		}
	}
}

- (void)openSearchMatch:(EditorSearchMatch *)match
{
	_currentSearchMatch = match;
	[self refreshSearchPanel];
	void (^navigate)(EditorDocument *) = ^(EditorDocument *target) {
		ScintillaView *editor = target.editor;
		const auto length = [editor message:SCI_GETLENGTH];
		const NSRange range = match.byteRange;
		const auto *bytes = reinterpret_cast<const char *>([editor message:SCI_GETCHARACTERPOINTER]);
		auto line = MIN(match.line - 1, static_cast<NSUInteger>([editor message:SCI_GETLINECOUNT] - 1));
		if (range.location <= length && range.length <= length - range.location &&
			(!range.length || std::memcmp(bytes + range.location, match.matchedBytes.bytes, range.length) == 0))
		{
			line = [editor message:SCI_LINEFROMPOSITION wParam:range.location];
			[editor message:SCI_SETSEL wParam:range.location lParam:NSMaxRange(range)];
		}
		else
			[editor message:SCI_GOTOLINE wParam:line];
		[editor message:SCI_ENSUREVISIBLE wParam:line];
		[editor message:SCI_SCROLLCARET];
		[target focusEditor];
	};
	EditorDocument *document = match.document;
	if (document && [self.documents containsObject:document])
	{
		[document showWindows];
		navigate(document);
	}
	else if (match.url)
		[self openDocumentWithContentsOfURL:match.url display:YES completionHandler:^(NSDocument *opened, BOOL wasOpen, NSError *failure) {
			if (failure)
				[NSApp presentError:failure];
			else
				navigate((EditorDocument *)opened);
		}];
	else
		NSBeep();
}

- (BOOL)saveSessionToURL:(NSURL *)url error:(NSError **)error
{
	pugi::xml_document xml;
	auto session = xml.append_child("NotepadPlus").append_child("Session");
	ScintillaView *currentClone = _activeDocument.clonedEditorView;
	BOOL focusOther = _otherDocument.fileURL && self.focusedDocument == _otherDocument;
	if (currentClone && _activeDocument.fileURL && _activeDocument.editor == currentClone)
		focusOther = YES;
	session.append_attribute("activeView") = focusOther ? 1 : 0;
	auto list = session.append_child("mainView");
	auto secondaryList = session.append_child("subView");
	auto active = list.append_attribute("activeIndex");
	active = 0;
	auto secondaryActive = secondaryList.append_attribute("activeIndex");
	secondaryActive = 0;
	int index = 0;
	int secondaryIndex = 0;
	for (EditorDocument *document in self.tabDocuments)
	{
		NSString *path = document.fileURL.path;
		ScintillaView *editor = document.primaryEditorView;
		if (!path || !editor)
			continue;
		auto owner = [_secondaryTabs containsObject:document] ? secondaryList : list;
		if (owner == list)
		{
			if (document == _activeDocument)
				active = index;
			++index;
		}
		else
		{
			if (document == _otherDocument)
				secondaryActive = secondaryIndex;
			++secondaryIndex;
		}
		WriteSessionView(owner.append_child("File"), path, editor);
		if (document == _activeDocument && currentClone)
			WriteSessionView(secondaryList.append_child("File"), path, currentClone);
	}

	std::ostringstream stream;
	xml.save(stream, "  ", pugi::format_default, pugi::encoding_utf8);
	auto bytes = stream.str();
	return [[NSData dataWithBytes:bytes.data() length:bytes.size()] writeToURL:url options:NSDataWritingAtomic error:error];
}

- (BOOL)loadSessionFromURL:(NSURL *)url error:(NSError **)error
{
	NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
	if (!data)
		return NO;
	pugi::xml_document xml;
	auto parsed = xml.load_buffer(data.bytes, data.length);
	auto session = xml.child("NotepadPlus").child("Session");
	if (!parsed || !session)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError
				userInfo:@{NSURLErrorKey: url, NSLocalizedDescriptionKey: EditorUIString(@"This XML file does not contain an editor session.")}];
		return NO;
	}

	EditorDocument *active[2] = {nil, nil};
	EditorDocument *first[2] = {nil, nil};
	NSHashTable<EditorDocument *> *secondary = NSHashTable.weakObjectsHashTable;
	NSHashTable<EditorDocument *> *primaryFiles = NSHashTable.weakObjectsHashTable;
	pugi::xml_node cloneFile;
	NSMutableArray<NSString *> *missing = [NSMutableArray array];
	for (NSUInteger view = 0; view < 2; ++view)
	{
		auto list = session.child(view ? "subView" : "mainView");
		auto index = list.attribute("activeIndex").as_int();
		int current = -1;
		for (auto file : list.children("File"))
		{
			++current;
			NSString *path = [NSString stringWithUTF8String:file.attribute("filename").value()];
			if (!path.length)
				continue;
			NSURL *fileURL = [EditorResources.shared localURLForWindowsPath:path];
			if (!fileURL && path.isAbsolutePath && ![path hasPrefix:@"//"])
				fileURL = [NSURL fileURLWithPath:path];
			if (!fileURL)
			{
				[missing addObject:path];
				continue;
			}
			EditorDocument *document = (EditorDocument *)[self documentForURL:fileURL];
			if (!document)
			{
				NSString *type = [self typeForContentsOfURL:fileURL error:nullptr];
				document = type ? [self makeDocumentWithContentsOfURL:fileURL ofType:type error:nullptr] : nil;
				if (!document)
				{
					[missing addObject:path];
					continue;
				}
				[self addDocument:document];
				[document makeWindowControllers];
			}
			if (!first[view])
				first[view] = document;
			if (current == index)
				active[view] = document;
			if (view == 0)
				[primaryFiles addObject:document];
			else if (![primaryFiles containsObject:document])
				[secondary addObject:document];
			if (document.isDocumentEdited)
				continue;
			if (view == 1 && document == (active[0] ?: first[0]))
				cloneFile = file;
			else
				ReadSessionView(file, document.primaryEditorView);
		}
	}
	EditorDocument *primary = active[0] ?: first[0];
	EditorDocument *other = active[1] ?: first[1];
	_secondaryTabs = secondary;
	[self restoreViewsWithPrimary:primary other:other focusOther:session.attribute("activeView").as_int() == 1];
	if (cloneFile && primary == other)
		ReadSessionView(cloneFile, primary.clonedEditorView);
	if (missing.count)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:@{
				NSLocalizedDescriptionKey: EditorUIString(@"Some files in this session could not be opened."),
				NSLocalizedRecoverySuggestionErrorKey: [missing componentsJoinedByString:@"\n"]}];
		return NO;
	}
	return YES;
}
- (NSString *)defaultType
{
	return @"public.plain-text";
}

- (Class)documentClassForType:(NSString *)typeName
{
	return EditorDocument.class;
}

- (NSString *)typeForContentsOfURL:(NSURL *)url error:(NSError **)error
{
	NSNumber *regular = nil;
	if (![url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:error])
		return nil;
	if (!regular.boolValue)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnsupportedSchemeError
				userInfo:@{NSURLErrorKey: url}];
		return nil;
	}
	return self.defaultType;
}
@end

@implementation EditorDocument
{
	ScintillaView *_editor;
	ScintillaView *_clone;
	EditorCloneObserver *_cloneObserver;
	__weak ScintillaView *_macroSource;
	NSData *_loadedUTF8;
	NSStringEncoding _encoding;
	NSStringEncoding _readerEncoding;
	NSData *_bom;
	NSString *_statusLanguage;
	NSString *_languageOverride;
	NSString *_untitledName;
	NSString *_query;
	NSInteger _searchFlags;
	sptr_t _lastEmptyMatch;
	NSPanel *_searchPanel;
	NSComboBox *_searchInput;
	NSComboBox *_replaceInput;
	NSTextField *_searchStatus;
	NSButton *_matchCase;
	NSButton *_wholeWord;
	NSButton *_regularExpression;
	NSButton *_extendedSearch;
	NSButton *_inSelection;
	NSRange _searchSelection;
	NSButton *_wrapSearch;
	NSButton *_replaceButton;
	NSButton *_replaceAllButton;
	NSInteger _multiSelectFlags;
	std::optional<sptr_t> _selectionStart;
	NSSegmentedControl *_searchMode;
	NSTextField *_replaceLabel;
	NSTextField *_searchFolder;
	NSTextField *_searchFilters;
	NSButton *_recursive;
	NSButton *_includeHidden;
	NSButton *_matchNewline;
	NSButton *_findAll;
	NSButton *_replaceFiles;
	NSButton *_findForward;
	NSButton *_findBackward;
	NSButton *_countMatches;
	NSButton *_findInDocument;
	NSButton *_findInOpenDocuments;
	NSButton *_replaceInOpenDocuments;
	NSArray<NSButton *> *_projectSearchControls;
	NSArray<NSView *> *_directoryControls;
	NSArray<NSView *> *_markControls;
	NSButton *_bookmarkMatches;
	NSButton *_purgeMarks;
	NSArray<NSView *> *_fileSearchControls;
	NSProgress *_fileSearch;
	EditorSearchResultsView *_resultsView;
	EditorDocumentList *_documentList;
	EditorDockPane *_documentListPane;
	__weak EditorDockArea *_dockArea;
	EditorDockPane *_udlPane;
	EditorDockPane *_resultsPane;
	EditorDockPane *_folderPane;
	EditorFolderPanel *_folderWorkspace;
	NSArray<EditorDockPane *> *_projectPanes;
	NSArray<EditorProjectPanel *> *_projectPanels;
	EditorDockPane *_functionListPane;
	EditorFunctionList *_functionList;
	EditorDockPane *_documentMapPane;
	EditorDocumentMap *_documentMap;
	EditorClipboardHistory *_clipboardHistory;
	EditorCharacterPanel *_characterPanel;
	EditorDockPane *_clipboardPane;
	EditorDockPane *_characterPane;
	EditorIncrementalSearch *_incremental;
	NSLayoutConstraint *_incrementalHeight;
	NSLayoutConstraint *_dockUnderChrome;
	NSLayoutConstraint *_dockUnderTitle;
	NSLayoutConstraint *_incrementalOverStatus;
	NSLayoutConstraint *_incrementalAtBottom;
	NSInteger _presentationMode;
	BOOL _presentationFullScreen;
	id _presentationKeys;
	__weak EditorDocument *_incrementalDocument;
	NSString *_languageIdentifier;
	EditorCompletion *_completion;
	EditorSplitView *_editorSplit;
	EditorTabPane *_primaryPane;
	NSView *_primaryEditorHost;
	EditorTabPane *_otherPane;
	NSView *_otherEditorHost;
	NSArray<NSLayoutConstraint *> *_editorConstraints;
	__weak EditorDocument *_displayedOtherDocument;
	BOOL _loading;
	BOOL _encodingChanged;
	BOOL _recording;
	BOOL _playingMacro;
	BOOL _monitoring;
	BOOL _readOnlyBeforeMonitoring;
	BOOL _askingAboutDisk;
	NSDictionary *_diskState;
	NSDictionary *_pendingDiskState;
	std::vector<MacroStep> _macro;
}

- (void)dealloc
{
	if (_presentationKeys)
		[NSEvent removeMonitor:_presentationKeys];
	_editor.delegate = nil;
	_clone.delegate = nil;
}

- (ScintillaView *)editor
{
	NSResponder *responder = _clone.window.firstResponder;
	if (_clone && [responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:_clone])
		return _clone;
	return _editor;
}

- (ScintillaView *)companionClone
{
	return _clone && self.editor == _clone ? _editor : _clone;
}

- (ScintillaView *)primaryEditorView
{
	return _editor;
}

- (ScintillaView *)clonedEditorView
{
	return _clone;
}

- (instancetype)init
{
	self = [super init];
	if (self)
	{
		_runtimeIdentifier = NextRuntimeDocumentID++;
		static const NSStringEncoding encodings[] = {NSWindowsCP1252StringEncoding, NSUTF8StringEncoding,
			NSUTF16BigEndianStringEncoding, NSUTF16LittleEndianStringEncoding, NSUTF8StringEncoding,
			NSASCIIStringEncoding, NSUTF16BigEndianStringEncoding, NSUTF16LittleEndianStringEncoding};
		NSInteger encoding = [[EditorResources.shared setting:@"newDocumentEncoding" fallback:@4] integerValue];
		encoding = std::clamp<NSInteger>(encoding, 0, 7);
		_encoding = encodings[encoding];
		if (encoding == 1)
			_bom = [NSData dataWithBytes:"\xef\xbb\xbf" length:3];
		else if (encoding == 2 || encoding == 3)
			_bom = [NSData dataWithBytes:encoding == 2 ? "\xfe\xff" : "\xff\xfe" length:2];
		_lastEmptyMatch = -1;
		self.hasUndoManager = NO;
	}
	return self;
}

+ (NSArray<NSString *> *)readableTypes
{
	return @[@"public.plain-text"];
}

+ (NSArray<NSString *> *)writableTypes
{
	return self.readableTypes;
}

- (BOOL)prepareSavePanel:(NSSavePanel *)panel
{
	if (![super prepareSavePanel:panel])
		return NO;
	panel.allowsOtherFileTypes = YES;
	return YES;
}

static sptr_t GuideColor(NSColor *color, sptr_t fallback)
{
	NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	return rgb ? (lround(rgb.redComponent * 255) | (lround(rgb.greenComponent * 255) << 8) |
		(lround(rgb.blueComponent * 255) << 16)) : fallback;
}

static void ApplyEditorGuides(ScintillaView *view)
{
	EditorResources *resources = EditorResources.shared;
	NSInteger mode = [[resources setting:@"currentLineMode" fallback:@0] integerValue];
	[view message:SCI_SETCARETLINEBACK wParam:GuideColor([resources widgetColor:@"Current line background colour" background:YES], 0xFFF0E8)];
	[view message:SCI_SETCARETLINEVISIBLE wParam:mode != 0];
	[view message:SCI_SETCARETLINEFRAME wParam:mode == 2 ? std::clamp([[resources setting:@"currentLineFrameWidth" fallback:@1] integerValue], 1L, 6L) : 0];
	[view message:SCI_SETWRAPINDENTMODE wParam:std::clamp([[resources setting:@"wrapIndent" fallback:@0] integerValue], 0L, 2L)];
	NSString *columns = [resources setting:@"edgeColumns" fallback:@""];
	NSMutableIndexSet *rulers = [NSMutableIndexSet indexSet];
	for (NSString *value in [columns componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ,;\t\n"]])
	{
		NSScanner *scanner = [NSScanner scannerWithString:value];
		NSInteger index;
		if ([scanner scanInteger:&index] && scanner.isAtEnd && index > 0 && index <= 4096)
			[rulers addIndex:index];
	}
	sptr_t color = GuideColor([resources widgetColor:@"Edge colour" background:NO], 0xD0D0D0);
	[view message:SCI_MULTIEDGECLEARALL];
	[view message:SCI_SETEDGECOLOUR wParam:color];
	if (rulers.count == 1)
	{
		[view message:SCI_SETEDGECOLUMN wParam:rulers.firstIndex];
		[view message:SCI_SETEDGEMODE wParam:[[resources setting:@"edgeBackground" fallback:@NO] boolValue] ? EDGE_BACKGROUND : EDGE_LINE];
	}
	else
	{
		[rulers enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) { [view message:SCI_MULTIEDGEADDLINE wParam:index lParam:color]; }];
		[view message:SCI_SETEDGEMODE wParam:rulers.count ? EDGE_MULTILINE : EDGE_NONE];
	}
}

static void ApplyPreferencesToView(ScintillaView *view)
{
	EditorResources *resources = EditorResources.shared;
	auto enabled = ^BOOL(NSString *name, BOOL fallback) { return [[resources setting:name fallback:@(fallback)] boolValue]; };
	[view message:SCI_SETTABWIDTH wParam:MIN(32, MAX(1, [[resources setting:@"tabWidth" fallback:@4] integerValue]))];
	[view message:SCI_SETUSETABS wParam:!enabled(@"insertSpaces", NO)];
	[view message:SCI_SETWRAPMODE wParam:enabled(@"wordWrap", NO) ? SC_WRAP_WORD : SC_WRAP_NONE];
	[view message:SCI_SETMARGINWIDTHN wParam:0 lParam:enabled(@"lineNumbers", YES) ? 32 : 0];
	[view message:SCI_SETMARGINWIDTHN wParam:1 lParam:enabled(@"bookmarkMargin", YES) ? 16 : 0];
	[view message:SCI_SETWRAPVISUALFLAGS wParam:enabled(@"showWrapSymbol", NO) ? SC_WRAPVISUALFLAG_END : SC_WRAPVISUALFLAG_NONE];
	[view message:SCI_SETENDATLASTLINE wParam:!enabled(@"scrollBeyondLastLine", NO)];
	[view message:SCI_SETVIRTUALSPACEOPTIONS wParam:SCVS_RECTANGULARSELECTION |
		(enabled(@"virtualSpace", NO) ? SCVS_USERACCESSIBLE : 0)];
	[view message:SCI_SETMULTIPLESELECTION wParam:enabled(@"multipleSelections", YES)];
	[view message:SCI_SETBACKSPACEUNINDENTS wParam:enabled(@"backspaceUnindent", NO)];
	[view message:SCI_SETINDENTATIONGUIDES wParam:enabled(@"indentGuide", NO) ? SC_IV_REAL : SC_IV_NONE];
	[view message:SCI_SETVIEWWS wParam:enabled(@"whitespace", NO) ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE];
	[view message:SCI_SETVIEWEOL wParam:enabled(@"showEOL", NO)];
	[view message:SCI_SETCARETWIDTH wParam:std::clamp([[resources setting:@"caretWidth" fallback:@1] integerValue], 0L, 20L)];
	[view message:SCI_SETCARETPERIOD wParam:std::clamp([[resources setting:@"caretBlink" fallback:@500] integerValue], 0L, 5000L)];
	ApplyEditorGuides(view);
}

- (void)refreshDockPlacements
{
	[_dockArea refreshPanelPlacements];
}

- (BOOL)largeFileMode
{
	EditorResources *resources = EditorResources.shared;
	if (![[resources setting:@"limitLargeFiles" fallback:@NO] boolValue])
		return NO;
	const auto megabytes = std::clamp<NSInteger>([[resources setting:@"largeFileMegabytes" fallback:@200] integerValue], 1, 4096);
	const auto size = MAX(_loadedUTF8.length, static_cast<NSUInteger>([_editor message:SCI_GETLENGTH]));
	return size >= static_cast<NSUInteger>(megabytes) * 1024 * 1024;
}

- (void)applyPreferences
{
	ApplyPreferencesToView(_editor);
	ApplyPreferencesToView(_clone);
	[self applyTheme];
	[_chrome refreshAppearancePreferences];
	[_chrome refreshToolbar];
}

- (void)configureEditorView:(ScintillaView *)view
{
	[view message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
	[view message:SCI_SETMULTIPLESELECTION wParam:1];
	[view message:SCI_SETADDITIONALSELECTIONTYPING wParam:1];
	[view message:SCI_SETVIRTUALSPACEOPTIONS wParam:SCVS_RECTANGULARSELECTION];
	[view message:SCI_SETTABWIDTH wParam:4];
	[view message:SCI_SETMARGINTYPEN wParam:0 lParam:SC_MARGIN_NUMBER];
	[view message:SCI_SETMARGINWIDTHN wParam:0 lParam:32];
	[view message:SCI_SETMARGINTYPEN wParam:1 lParam:SC_MARGIN_SYMBOL];
	[view message:SCI_SETMARGINMASKN wParam:1 lParam:1 << Bookmark];
	[view message:SCI_SETMARGINWIDTHN wParam:1 lParam:16];
	[view message:SCI_SETMARGINSENSITIVEN wParam:1 lParam:1];
	[view message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];
	const unsigned historyMask = (1 << SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN) | (1 << SC_MARKNUM_HISTORY_SAVED) |
		(1 << SC_MARKNUM_HISTORY_MODIFIED) | (1 << SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED);
	[view message:SCI_SETMARGINTYPEN wParam:3 lParam:SC_MARGIN_SYMBOL];
	[view message:SCI_SETMARGINMASKN wParam:3 lParam:historyMask];
	[view message:SCI_SETMARGINWIDTHN wParam:3 lParam:4];
	const int changeColors[] = {0x70afaf, 0x44aa44, 0x22aaff, 0x70aadd};
	for (int i = 0; i < std::size(changeColors); ++i)
	{
		const int marker = SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN + i;
		[view message:SCI_MARKERDEFINE wParam:marker lParam:SC_MARK_FULLRECT];
		[view message:SCI_MARKERSETBACK wParam:marker lParam:changeColors[i]];
	}
	[view message:SCI_MARKERDEFINE wParam:Bookmark lParam:SC_MARK_CIRCLE];
	[view message:SCI_MARKERSETBACK wParam:Bookmark lParam:0xD48000];
	[view message:SCI_SETMARGINTYPEN wParam:2 lParam:SC_MARGIN_SYMBOL];
	[view message:SCI_SETMARGINMASKN wParam:2 lParam:SC_MASK_FOLDERS];
	[view message:SCI_SETMARGINSENSITIVEN wParam:2 lParam:1];
	const int foldMarkers[] = {SC_MARK_BOXPLUSCONNECTED, SC_MARK_BOXMINUSCONNECTED, SC_MARK_TCORNER,
		SC_MARK_LCORNER, SC_MARK_VLINE, SC_MARK_BOXPLUS, SC_MARK_BOXMINUS};
	for (NSUInteger i = 0; i < std::size(foldMarkers); ++i)
	{
		[view message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEREND + i lParam:foldMarkers[i]];
		[view message:SCI_MARKERSETFORE wParam:SC_MARKNUM_FOLDEREND + i lParam:0xffffff];
		[view message:SCI_MARKERSETBACK wParam:SC_MARKNUM_FOLDEREND + i lParam:0x808080];
	}
	[view message:SCI_SETAUTOMATICFOLD wParam:SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE];
	ApplyPreferencesToView(view);
}

- (void)makeWindowControllers
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 680)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
			NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
	window.minSize = NSMakeSize(680, 260);
	window.tabbingMode = NSWindowTabbingModeDisallowed;
	window.releasedWhenClosed = NO;
	window.restorable = NO;
	[window center];
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorLaunchOptions *launch = controller.launchOptions;
	if (launch.leftPosition || launch.topPosition)
	{
		NSRect frame = window.frame;
		if (launch.leftPosition)
			frame.origin.x = launch.leftPosition.doubleValue;
		if (launch.topPosition)
			frame.origin.y = NSMaxY(NSScreen.screens.firstObject.frame) - launch.topPosition.doubleValue - frame.size.height;
		[window setFrameOrigin:frame.origin];
	}
	if (launch.alwaysOnTop)
		window.level = NSFloatingWindowLevel;

	NSView *content = window.contentView;
	EditorContextView *primary = [[EditorContextView alloc] initWithFrame:content.bounds];
	primary.document = self;
	_editor = primary;
	_editor.translatesAutoresizingMaskIntoConstraints = NO;
	_editor.delegate = (id<ScintillaNotificationProtocol>)self;
	[self configureEditorView:_editor];
	_chrome = [[EditorChrome alloc] initWithDocument:self commands:[self toolbarCommands]];
	[_chrome refreshAppearancePreferences];
	NSView *statusBar = _chrome.statusBar;
	__weak EditorDocumentController *weakController = controller;
	void (^dismissResults)(void) = ^{ weakController.searchResultsVisible = NO; };
	void (^dismissDocuments)(void) = ^{
		EditorDocumentController *documents = weakController;
		documents.documentListVisible = NO;
		[documents refreshDocumentTabs];
		[documents workspaceChanged];
	};
	_resultsView = [[EditorSearchResultsView alloc] initWithOpenMatch:^(EditorSearchMatch *match) {
		[weakController openSearchMatch:match];
	} dismiss:dismissResults];
	_resultsView.reportsChanged = ^(NSArray<EditorSearchReport *> *reports) {
		EditorDocumentController *documents = weakController;
		documents.searchReports = reports;
		[documents refreshSearchPanel];
	};
	_resultsView.purgeChanged = ^(BOOL purge) {
		EditorDocumentController *documents = weakController;
		documents.purgeSearchReports = purge;
		[documents refreshSearchPanel];
		[documents workspaceChanged];
	};
	_resultsView.refine = ^(NSArray<EditorSearchReport *> *reports) { [weakController.focusedDocument refineSearchReports:reports]; };
	_documentList = [[EditorDocumentList alloc] initWithSelect:^(EditorDocument *document, BOOL otherView) {
		[document showWindows];
		if (document.clonedEditorView)
		{
			if (otherView)
				[document focusClonedEditor];
			else
				[document focusPrimaryEditor];
		}
	} dismiss:dismissDocuments groupingChanged:^(BOOL grouped) {
		weakController.documentListUngrouped = !grouped;
		[weakController refreshDocumentList];
		[weakController workspaceChanged];
	}];
	_editorSplit = [[EditorSplitView alloc] initWithFrame:content.bounds];
	_editorSplit.vertical = YES;
	_editorSplit.dividerStyle = NSSplitViewDividerStyleThin;
	__weak EditorDocument *weakDocument = self;
	_editorSplit.rotate = ^(NSInteger direction) {
		EditorDocumentController *documents = weakController;
		documents.splitRotation = (documents.splitRotation + direction + 4) % 4;
		[weakDocument applySplitRotation:documents.splitRotation];
		[documents workspaceChanged];
	};
	_primaryPane = [[EditorTabPane alloc] initWithFrame:content.bounds];
	_primaryEditorHost = AddEditorHost(_primaryPane, _chrome.primaryTabs);
	[_editorSplit addArrangedSubview:_primaryPane];
	[self attachEditorTo:_primaryEditorHost];
	EditorDockArea *dock = [[EditorDockArea alloc] initWithEditor:_editorSplit];
	_dockArea = dock;
	dock.translatesAutoresizingMaskIntoConstraints = NO;
	dock.placementChanged = ^{ [weakController workspaceChanged]; };
	EditorResources *resources = EditorResources.shared;
	_resultsPane = [dock addPanel:_resultsView title:[resources label:@"find-result-caption" fallback:@"Search results"]
		placement:controller.searchResultsPlacement dismiss:dismissResults];
	_documentListPane = [dock addPanel:_documentList title:[resources label:@"docList:PanelTitle" fallback:@"Document List"]
		placement:controller.documentListPlacement dismiss:dismissDocuments];
	void (^dismissFolder)(void) = ^{ [weakController toggleFolderWorkspace:nil]; };
	void (^openFromPanel)(NSURL *) = ^(NSURL *url) {
		[weakController openDocumentWithContentsOfURL:url display:YES completionHandler:
			^(NSDocument *document, BOOL wasOpen, NSError *error) { if (error) [NSApp presentError:error]; }];
	};
	_folderWorkspace = [[EditorFolderPanel alloc] initWithOpen:openFromPanel add:^{
		[weakController chooseWorkspaceFolders:nil];
	} changeRoots:^(NSArray<NSURL *> *folders) {
		[weakController setWorkspaceFolders:folders];
	} dismiss:dismissFolder];
	_folderPane = [dock addPanel:_folderWorkspace title:[resources label:@"44085" fallback:@"Folder as Workspace"]
		placement:controller.folderWorkspacePlacement dismiss:dismissFolder];
	NSMutableArray *panels = [NSMutableArray array], *panes = [NSMutableArray array];
	for (NSUInteger index = 0; index < controller.projectWorkspaces.count; ++index)
	{
		NSString *title = [resources label:[@(44081 + index) stringValue]
			fallback:[NSString stringWithFormat:@"Project Panel %lu", index + 1]];
		void (^dismiss)(void) = ^{ [weakController setProjectPanel:index visible:NO]; };
		EditorProjectPanel *panel = [[EditorProjectPanel alloc] initWithTitle:title workspace:controller.projectWorkspaces[index]
			open:openFromPanel changed:^{ [weakController workspaceChanged]; } dismiss:dismiss];
		[panels addObject:panel];
		[panes addObject:[dock addPanel:panel title:title placement:controller.projectPlacements[index] dismiss:dismiss]];
	}
	_projectPanes = [panes copy];
	_projectPanels = [panels copy];
	void (^dismissFunctions)(void) = ^{ [weakController toggleFunctionList:nil]; };
	_functionList = [[EditorFunctionList alloc] initWithNavigate:^(NSUInteger position) {
		EditorDocument *focused = weakController.focusedDocument;
		[focused focusEditor];
		[focused.editor message:SCI_GOTOPOS wParam:MIN(position, [focused.editor message:SCI_GETLENGTH])];
		[focused.editor message:SCI_SCROLLCARET];
	} dismiss:dismissFunctions];
	_functionListPane = [dock addPanel:_functionList title:[resources label:@"44084" fallback:@"Function List"]
		placement:controller.functionListPlacement dismiss:dismissFunctions];
	void (^dismissMap)(void) = ^{ [weakController toggleDocumentMap:nil]; };
	_documentMap = [[EditorDocumentMap alloc] initWithDismiss:dismissMap];
	_documentMapPane = [dock addPanel:_documentMap title:[resources label:@"44080" fallback:@"Document Map"]
		placement:controller.documentMapPlacement dismiss:dismissMap];
	void (^insert)(NSString *) = ^(NSString *text) { [weakController insertPanelText:text]; };
	void (^dismissClipboard)(void) = ^{ [weakController setInsertPanel:0 visible:NO]; };
	void (^dismissCharacters)(void) = ^{ [weakController setInsertPanel:1 visible:NO]; };
	_clipboardHistory = [[EditorClipboardHistory alloc] initWithInsert:insert dismiss:dismissClipboard];
	_characterPanel = [[EditorCharacterPanel alloc] initWithInsert:insert dismiss:dismissCharacters];
	_clipboardPane = [dock addPanel:_clipboardHistory title:[resources label:@"42052" fallback:@"Clipboard History"]
		placement:controller.insertPlacements[0] dismiss:dismissClipboard];
	_characterPane = [dock addPanel:_characterPanel title:[resources label:@"42051" fallback:@"Character Panel"]
		placement:controller.insertPlacements[1] dismiss:dismissCharacters];
	[content addSubview:_chrome];
	[content addSubview:dock];
	_incremental = [[EditorIncrementalSearch alloc] initWithDismiss:^{ [weakDocument dismissIncrementalSearch]; }];
	_incremental.hidden = YES;
	_incrementalHeight = [_incremental.heightAnchor constraintEqualToConstant:0];
	[content addSubview:_incremental];
	[content addSubview:statusBar];
	_dockUnderChrome = [dock.topAnchor constraintEqualToAnchor:_chrome.bottomAnchor];
	_dockUnderTitle = [dock.topAnchor constraintEqualToAnchor:content.topAnchor];
	_incrementalOverStatus = [_incremental.bottomAnchor constraintEqualToAnchor:statusBar.topAnchor];
	_incrementalAtBottom = [_incremental.bottomAnchor constraintEqualToAnchor:content.bottomAnchor];
	[NSLayoutConstraint activateConstraints:@[
		[_chrome.topAnchor constraintEqualToAnchor:content.topAnchor],
		[_chrome.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
		[_chrome.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
		_dockUnderChrome,
		[dock.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
		[dock.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
		[dock.bottomAnchor constraintEqualToAnchor:_incremental.topAnchor],
		[_incremental.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
		[_incremental.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
		_incrementalOverStatus,
		_incrementalHeight,
		[statusBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
		[statusBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
		[statusBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
	]];
	[self displaySearchReports:nil purge:NO match:nil visible:NO];
	window.initialFirstResponder = _editor.content;

	EditorWindowController *windowController = [[EditorWindowController alloc] initWithWindow:window];
	windowController.titleSuffix = launch.titleSuffix;
	[self addWindowController:windowController];
	[self applyTheme];
	[self loadEditor];
	if (launch.fullReadOnly)
		[_editor message:SCI_SETREADONLY wParam:1];
	if (launch.monitoringMode && self.fileURL && !_monitoring)
		[self monitorFile:nil];
}

- (void)applyPresentationMode:(NSInteger)mode
{
	_presentationMode = mode;
	BOOL minimal = mode != 0;
	_chrome.hidden = minimal;
	if (minimal)
	{
		_chrome.statusBar.hidden = YES;
		[_chrome setTabsHidden:YES];
	}
	else
		[_chrome refreshAppearancePreferences];
	(minimal ? _dockUnderChrome : _dockUnderTitle).active = NO;
	(minimal ? _incrementalOverStatus : _incrementalAtBottom).active = NO;
	(minimal ? _dockUnderTitle : _dockUnderChrome).active = YES;
	(minimal ? _incrementalAtBottom : _incrementalOverStatus).active = YES;
	NSWindow *window = self.windowControllers.firstObject.window;
	window.titleVisibility = minimal ? NSWindowTitleHidden : NSWindowTitleVisible;
	for (NSNumber *type in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)])
		[window standardWindowButton:(NSWindowButton)type.integerValue].hidden = minimal;
	for (ScintillaView *view in _clone ? @[_editor, _clone] : @[_editor])
	{
		const auto padding = mode == 2 ? 56 : 1;
		[view message:SCI_SETMARGINLEFT wParam:0 lParam:padding];
		[view message:SCI_SETMARGINRIGHT wParam:0 lParam:padding];
	}
	if (minimal && !_presentationKeys)
	{
		__weak EditorDocument *weakSelf = self;
		_presentationKeys = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
			EditorDocument *document = weakSelf;
			if (document && event.keyCode == 53 && event.window == document.windowControllers.firstObject.window)
			{
				[document leavePresentation];
				return nil;
			}
			return event;
		}];
	}
	else if (!minimal && _presentationKeys)
	{
		[NSEvent removeMonitor:_presentationKeys];
		_presentationKeys = nil;
	}
}

- (void)leavePresentation
{
	[self applyPresentationMode:0];
	NSWindow *window = self.windowControllers.firstObject.window;
	if (_presentationFullScreen && (window.styleMask & NSWindowStyleMaskFullScreen))
		[window toggleFullScreen:nil];
	_presentationFullScreen = NO;
}

- (IBAction)togglePresentationMode:(NSMenuItem *)sender
{
	EditorDocument *host = [(EditorDocumentController *)NSDocumentController.sharedDocumentController windowOwnerForDocument:self];
	if (host->_presentationMode == sender.tag)
		return [host leavePresentation];
	[host applyPresentationMode:sender.tag];
	NSWindow *window = host.windowControllers.firstObject.window;
	if (sender.tag == 2 && !(window.styleMask & NSWindowStyleMaskFullScreen))
	{
		host->_presentationFullScreen = YES;
		[window toggleFullScreen:nil];
	}
	else if (sender.tag == 1 && host->_presentationFullScreen && (window.styleMask & NSWindowStyleMaskFullScreen))
	{
		host->_presentationFullScreen = NO;
		[window toggleFullScreen:nil];
	}
}

- (void)attachEditorTo:(NSView *)host
{
	if (_editor.superview == host)
		return;
	[NSLayoutConstraint deactivateConstraints:_editorConstraints ?: @[]];
	[_editor removeFromSuperview];
	[host addSubview:_editor];
	_editorConstraints = @[
		[_editor.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
		[_editor.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
		[_editor.topAnchor constraintEqualToAnchor:host.topAnchor],
		[_editor.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
	];
	[NSLayoutConstraint activateConstraints:_editorConstraints];
}

- (void)makeOtherPane
{
	_otherPane = [[EditorTabPane alloc] initWithFrame:_primaryEditorHost.frame];
	_otherEditorHost = AddEditorHost(_otherPane, _chrome.secondaryTabs);
}

- (void)applySplitRotation:(NSInteger)rotation
{
	BOOL vertical = (rotation % 2) == 0;
	BOOL flipped = rotation >= 2;
	BOOL reordered = _editorSplit.arrangedSubviews.count == 2 &&
		_editorSplit.arrangedSubviews.firstObject != (flipped ? _otherPane : _primaryPane);
	if (_editorSplit.isVertical == vertical && !reordered)
		return;
	_editorSplit.vertical = vertical;
	if (reordered)
	{
		NSView *first = flipped ? _otherPane : _primaryPane;
		[_editorSplit removeArrangedSubview:first];
		[_editorSplit insertArrangedSubview:first atIndex:0];
	}
	[_editorSplit adjustSubviews];
	if (_editorSplit.arrangedSubviews.count == 2)
		[_editorSplit setPosition:(vertical ? NSWidth(_editorSplit.bounds) : NSHeight(_editorSplit.bounds)) / 2 ofDividerAtIndex:0];
}

- (void)displayOtherDocument:(EditorDocument *)document
{
	if (_displayedOtherDocument == document)
		return;
	if (_displayedOtherDocument)
	{
		NSPanel *search = _displayedOtherDocument->_searchPanel;
		[search orderOut:nil];
		[search.parentWindow removeChildWindow:search];
		[_displayedOtherDocument attachEditorTo:_displayedOtherDocument->_primaryEditorHost];
	}
	_displayedOtherDocument = document;
	if (!document)
	{
		[_editorSplit removeArrangedSubview:_otherPane];
		[_otherPane removeFromSuperview];
		[_editorSplit adjustSubviews];
		return;
	}
	[self closeClonedView];
	if (!_otherPane)
		[self makeOtherPane];
	BOOL newlySplit = _otherPane.superview != _editorSplit;
	if (newlySplit)
		[_editorSplit addArrangedSubview:_otherPane];
	[document attachEditorTo:_otherEditorHost];
	[_chrome refreshTabs];
	if (newlySplit)
	{
		[self applySplitRotation:((EditorDocumentController *)NSDocumentController.sharedDocumentController).splitRotation];
		[_editorSplit setPosition:(_editorSplit.isVertical ? NSWidth(_editorSplit.bounds) : NSHeight(_editorSplit.bounds)) / 2 ofDividerAtIndex:0];
	}
}

- (void)focusEditor
{
	ScintillaView *editor = self.editor;
	NSWindow *window = editor.window;
	[window makeKeyAndOrderFront:nil];
	[window makeFirstResponder:editor.content];
	[self updateStatus];
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	[[controller windowOwnerForDocument:self].chrome refreshToolbar];
}

- (NSWindow *)windowForSheet
{
	return _editor.window ?: [super windowForSheet];
}

- (void)focusPrimaryEditor
{
	[_editor.window makeFirstResponder:_editor.content];
	[self focusEditor];
}

- (void)focusClonedEditor
{
	[_clone.window makeFirstResponder:_clone.content];
	[self updateStatus];
	[_chrome refreshToolbar];
}

- (IBAction)moveToOtherView:(id)sender
{
	[(EditorDocumentController *)NSDocumentController.sharedDocumentController showInOtherView:self];
}

- (IBAction)cloneToOtherView:(id)sender
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	if ([controller windowOwnerForDocument:self] != self)
		[controller showInOtherView:self];
	if (!_clone)
	{
		[controller hideOtherView];
		[self addClonedView];
	}
	[self focusClonedEditor];
	[controller workspaceChanged];
}

- (void)addClonedView
{
	if (!_otherPane)
		[self makeOtherPane];
	EditorContextView *clone = [[EditorContextView alloc] initWithFrame:_primaryEditorHost.bounds];
	clone.document = self;
	_clone = clone;
	_clone.translatesAutoresizingMaskIntoConstraints = NO;
	[_clone message:SCI_SETDOCPOINTER wParam:0 lParam:[_editor message:SCI_GETDOCPOINTER]];
	[self configureEditorView:_clone];
	_cloneObserver = [[EditorCloneObserver alloc] init];
	_cloneObserver.document = self;
	_clone.delegate = _cloneObserver;
	[_otherEditorHost addSubview:_clone];
	[NSLayoutConstraint activateConstraints:@[
		[_clone.leadingAnchor constraintEqualToAnchor:_otherEditorHost.leadingAnchor],
		[_clone.trailingAnchor constraintEqualToAnchor:_otherEditorHost.trailingAnchor],
		[_clone.topAnchor constraintEqualToAnchor:_otherEditorHost.topAnchor],
		[_clone.bottomAnchor constraintEqualToAnchor:_otherEditorHost.bottomAnchor],
	]];
	[_editorSplit addArrangedSubview:_otherPane];
	[self applySplitRotation:((EditorDocumentController *)NSDocumentController.sharedDocumentController).splitRotation];
	[_editorSplit setPosition:(_editorSplit.isVertical ? NSWidth(_editorSplit.bounds) : NSHeight(_editorSplit.bounds)) / 2 ofDividerAtIndex:0];
	[_clone message:SCI_SETSEL wParam:[_editor message:SCI_GETANCHOR] lParam:[_editor message:SCI_GETCURRENTPOS]];
	[_clone message:SCI_SETFIRSTVISIBLELINE wParam:[_editor message:SCI_GETFIRSTVISIBLELINE]];
	[_chrome refreshTabs];
	[self applyTheme];
}

- (void)closeClonedView
{
	if (!_clone)
		return;
	if (_macroSource == _clone)
		[self stopRecordingMacro:nil];
	_clone.delegate = nil;
	[_clone removeFromSuperview];
	_clone = nil;
	_cloneObserver = nil;
	[_editorSplit removeArrangedSubview:_otherPane];
	[_otherPane removeFromSuperview];
	[_editorSplit adjustSubviews];
}

- (void)clonedViewNotification:(SCNotification *)notification
{
	switch (notification->nmhdr.code)
	{
		case SCN_FOCUSIN:
		case SCN_ZOOM:
		case SCN_UPDATEUI:
		case SCN_MACRORECORD:
		case SCN_MARGINCLICK:
		case SCN_CHARADDED:
			[self notification:notification];
			break;
	}
}

- (IBAction)closeOtherView:(id)sender
{
	[(EditorDocumentController *)NSDocumentController.sharedDocumentController hideOtherView];
}

- (IBAction)toggleZoomSync:(id)sender
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	controller.syncZoom = !controller.syncZoom;
	[controller syncZoomFromDocument:controller.focusedDocument];
	[controller workspaceChanged];
}

- (IBAction)toggleVerticalScrollSync:(id)sender
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	controller.syncVerticalScroll = !controller.syncVerticalScroll;
	[controller syncScrollFromDocument:controller.focusedDocument changes:SC_UPDATE_V_SCROLL];
	[controller workspaceChanged];
}

- (IBAction)toggleHorizontalScrollSync:(id)sender
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	controller.syncHorizontalScroll = !controller.syncHorizontalScroll;
	[controller syncScrollFromDocument:controller.focusedDocument changes:SC_UPDATE_H_SCROLL];
	[controller workspaceChanged];
}

- (void)displaySearchReports:(NSArray<EditorSearchReport *> *)reports purge:(BOOL)purge match:(EditorSearchMatch *)match visible:(BOOL)visible
{
	_resultsView.reports = visible ? reports : nil;
	_resultsView.purgeForEachSearch = purge;
	_resultsPane.shown = visible;
	if (visible)
		[_resultsView selectMatch:match];
}

- (void)displayDocumentList:(NSArray<EditorDocument *> *)documents otherView:(NSArray<EditorDocument *> *)other
	focused:(EditorDocument *)focused focusOther:(BOOL)focusOther groupByView:(BOOL)groupByView visible:(BOOL)visible
{
	_documentListPane.shown = visible;
	if (visible)
		[_documentList reloadDocuments:documents otherView:other selected:focused focusOther:focusOther groupByView:groupByView];
}

- (IBAction)toggleDocumentList:(id)sender
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	controller.documentListVisible = !controller.documentListVisible;
	[controller refreshDocumentTabs];
	[controller workspaceChanged];
}

- (void)displayFolderWorkspace:(NSArray<NSURL *> *)folders visible:(BOOL)visible
{
	_folderPane.shown = visible;
	if (visible)
		[_folderWorkspace setDirectories:folders ?: @[]];
}

- (void)displayProjectPanels:(NSIndexSet *)visible
{
	for (NSUInteger index = 0; index < _projectPanes.count; ++index)
	{
		BOOL shown = [visible containsIndex:index];
		_projectPanes[index].shown = shown;
		if (shown)
			[_projectPanels[index] reload];
	}
}

- (void)displayFunctionsOf:(EditorDocument *)document visible:(BOOL)visible
{
	_functionListPane.shown = visible;
	if (visible && document)
		[_functionList refresh:[document editorUTF8] language:document->_languageIdentifier];
	else
		[_functionList cancel];
}

- (void)displayDocumentMap:(ScintillaView *)editor visible:(BOOL)visible
{
	_documentMapPane.shown = visible;
	[_documentMap showEditor:visible ? editor : nil];
}

- (void)displayInsertPanels:(NSIndexSet *)visible clipboard:(NSArray<NSString *> *)entries encoding:(NSStringEncoding)encoding
{
	_clipboardPane.shown = [visible containsIndex:0];
	_characterPane.shown = [visible containsIndex:1];
	if (_clipboardPane.isShown)
		[_clipboardHistory setEntries:entries];
	if (_characterPane.isShown)
		[_characterPanel useEncoding:encoding];
}

- (NSStringEncoding)currentTextEncoding { return _encoding; }

- (IBAction)toggleSearchResults:(id)sender
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	controller.searchResultsVisible = !controller.searchResultsVisible;
}

- (NSArray<NSToolbarItem *> *)toolbarCommands
{
	struct Command
	{
		NSString *identifier;
		NSString *translation;
		NSString *label;
		NSString *symbol;
		SEL action;
		id target;
		NSInteger tag = 0;
	};
	const Command commands[] = {
		{@"new", @"41001", @"New", @"doc.badge.plus", @selector(newDocument:), NSDocumentController.sharedDocumentController},
		{@"open", @"41002", @"Open…", @"folder", @selector(openFiles:), NSApp.delegate},
		{@"save", @"41006", @"Save", @"square.and.arrow.down", @selector(saveDocument:), self},
		{@"saveall", @"41007", @"Save All", @"square.stack", @selector(saveAllDocuments:), NSDocumentController.sharedDocumentController},
		{@"close", @"41003", @"Close", @"xmark", @selector(closeEditorTab:), self},
		{@"closeall", @"41004", @"Close All", @"xmark.rectangle", @selector(closeAll:), NSApp.delegate},
		{@"print", @"41010", @"Print", @"printer", @selector(printDocument:), self},
		{NSToolbarSpaceItemIdentifier, nil, nil, nil, nullptr, nil},
		{@"cut", @"42001", @"Cut", @"scissors", @selector(cut:), _editor.content},
		{@"copy", @"42002", @"Copy", @"doc.on.doc", @selector(copy:), _editor.content},
		{@"paste", @"42005", @"Paste", @"clipboard", @selector(paste:), _editor.content},
		{NSToolbarSpaceItemIdentifier, nil, nil, nil, nullptr, nil},
		{@"undo", @"42003", @"Undo", @"arrow.uturn.backward", @selector(undo:), _editor.content},
		{@"redo", @"42004", @"Redo", @"arrow.uturn.forward", @selector(redo:), _editor.content},
		{NSToolbarSpaceItemIdentifier, nil, nil, nil, nullptr, nil},
		{@"find", @"43001", @"Find…", @"magnifyingglass", @selector(findText:), self},
		{@"findrep", @"43003", @"Replace…", @"arrow.left.arrow.right", @selector(replaceText:), self},
		{NSToolbarSpaceItemIdentifier, nil, nil, nil, nullptr, nil},
		{@"zoomIn", @"native-zoomIn", @"Zoom In", @"plus.magnifyingglass", @selector(runEditorCommand:), self, SCI_ZOOMIN},
		{@"zoomOut", @"native-zoomOut", @"Zoom Out", @"minus.magnifyingglass", @selector(runEditorCommand:), self, SCI_ZOOMOUT},
		{NSToolbarSpaceItemIdentifier, nil, nil, nil, nullptr, nil},
		{@"syncV", @"44035", @"Synchronize Vertical Scrolling", @"arrow.up.and.down", @selector(toggleVerticalScrollSync:), self},
		{@"syncH", @"44036", @"Synchronize Horizontal Scrolling", @"arrow.left.and.right", @selector(toggleHorizontalScrollSync:), self},
		{NSToolbarSpaceItemIdentifier, nil, nil, nil, nullptr, nil},
		{@"wrap", @"44022", @"Word Wrap", @"text.line.last.and.arrowtriangle.forward", @selector(toggleWrap:), self},
		{@"allChars", @"44019", @"Show All Characters", @"paragraphsign", @selector(toggleInvisibles:), self},
		{@"indentGuide", @"44020", @"Show Indent Guide", @"decrease.indent", @selector(toggleIndentGuides:), self},
		{NSToolbarSpaceItemIdentifier, nil, nil, nil, nullptr, nil},
		{@"udl", @"native-editUDL", @"Define User Language…", @"curlybraces", @selector(editUserLanguage:), NSApp.delegate},
		{@"docMap", @"44080", @"Document Map", @"map", @selector(toggleDocumentMap:), NSDocumentController.sharedDocumentController},
		{@"docList", @"44070", @"Document List", @"sidebar.left", @selector(toggleDocumentList:), self},
		{@"funcList", @"44084", @"Function List", @"list.bullet", @selector(toggleFunctionList:), NSDocumentController.sharedDocumentController},
		{@"fileBrowser", @"44085", @"Folder as Workspace", @"folder", @selector(toggleFolderWorkspace:), NSDocumentController.sharedDocumentController},
		{NSToolbarSpaceItemIdentifier, nil, nil, nil, nullptr, nil},
		{@"monitoring", @"44097", @"Monitoring (tail -f)", @"waveform.path", @selector(monitorFile:), self},
		{NSToolbarSpaceItemIdentifier, nil, nil, nil, nullptr, nil},
		{@"startrecord", @"42018", @"Start Recording", @"record.circle", @selector(startRecordingMacro:), self},
		{@"stoprecord", @"42019", @"Stop Recording", @"stop.circle", @selector(stopRecordingMacro:), self},
		{@"playrecord", @"42021", @"Playback", @"play.circle", @selector(playRecordedMacro:), self},
		{@"playrecord_m", @"42032", @"Run a Macro Multiple Times…", @"repeat.circle", @selector(repeatRecordedMacro:), self},
		{@"saverecord", @"42025", @"Save Current Recorded Macro…", @"square.and.arrow.down", @selector(saveRecordedMacro:), self},
	};
	NSMutableArray<NSToolbarItem *> *items = [NSMutableArray array];
	NSDictionary *alternateIDs = @{@"zoomIn": @"44023", @"zoomOut": @"44024", @"udl": @"46250"};
	for (NSUInteger index = 0; index < std::size(commands); ++index)
	{
		const auto &command = commands[index];
		NSString *identifier = alternateIDs[command.identifier] ?: command.translation ?: @"0";
		if ([EditorResources.shared toolbarHidesCommand:identifier atIndex:index])
			continue;
		if (!command.action && (!items.count || [items.lastObject.itemIdentifier isEqualToString:NSToolbarSpaceItemIdentifier]))
			continue;
		NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:command.identifier];
		[items addObject:item];
		if (!command.action)
			continue;
		item.label = [EditorResources.shared label:command.translation fallback:command.label];
		item.toolTip = item.label;
		item.image = [NSImage imageWithSystemSymbolName:command.symbol accessibilityDescription:item.label];
		item.tag = command.tag;
		item.target = command.target;
		item.action = command.action;
	}
	if ([items.lastObject.itemIdentifier isEqualToString:NSToolbarSpaceItemIdentifier])
		[items removeLastObject];
	return items;
}

- (BOOL)isToolbarCommandEnabled:(NSToolbarItem *)command
{
	EditorDocument *focused = [self focusedToolbarDocument];
	if (focused != self)
		return [focused isToolbarCommandEnabled:command];
	if (command.action == @selector(undo:))
		return [self.editor message:SCI_CANUNDO] != 0;
	if (command.action == @selector(redo:))
		return [self.editor message:SCI_CANREDO] != 0;
	if (command.action == @selector(cut:) || command.action == @selector(copy:))
		return [self.editor message:SCI_GETSELECTIONEMPTY] == 0;
	if (command.action == @selector(paste:))
		return [self.editor message:SCI_CANPASTE] != 0;
	if (command.action == @selector(saveDocument:))
		return self.isDocumentEdited;
	if (command.action == @selector(saveAllDocuments:))
		return [(EditorDocumentController *)NSDocumentController.sharedDocumentController canSaveAllDocuments];
	if (command.action == @selector(monitorFile:))
		return self.fileURL && !self.isDocumentEdited;
	if (command.action == @selector(startRecordingMacro:))
		return !_recording;
	if (command.action == @selector(stopRecordingMacro:))
		return _recording;
	if (command.action == @selector(playRecordedMacro:) || command.action == @selector(saveRecordedMacro:))
		return !_recording && !_macro.empty();
	if (command.action == @selector(repeatRecordedMacro:))
		return !_recording && (!_macro.empty() || EditorMacroLibrary.shared.macros.count);
	if (command.action == @selector(toggleVerticalScrollSync:) || command.action == @selector(toggleHorizontalScrollSync:))
		return [(EditorDocumentController *)NSDocumentController.sharedDocumentController hasOtherView];
	return YES;
}

- (EditorDocument *)focusedToolbarDocument
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorDocument *document = controller.focusedDocument;
	return [controller windowOwnerForDocument:document] == self ? document : self;
}

- (id)targetForToolbarCommand:(NSToolbarItem *)command
{
	EditorDocument *document = [self focusedToolbarDocument];
	if (command.target == self)
		return document;
	if (command.target == _editor.content)
		return document.editor.content;
	return command.target;
}

- (NSString *)displayName
{
	if (self.fileURL)
		return [super displayName];
	if (!_untitledName)
	{
		_untitledName = [NSString stringWithFormat:[EditorResources.shared label:@"native-untitled" fallback:@"new %lu"], NextUntitledNumber++];
	}
	return _untitledName;
}

- (void)showWindows
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	if ([controller focusOtherViewDocument:self])
		return;
	[controller prepareToShowDocument:self];
	[super showWindows];
	[self focusEditor];
}

- (IBAction)closeEditorTab:(id)sender
{
	NSWindow *window = self.windowControllers.firstObject.window;
	if (!window.visible && !self.isDocumentEdited)
	{
		[self close];
		return;
	}
	if (_editor.window && _editor.window != window)
	{
		[self canCloseDocumentWithDelegate:self shouldCloseSelector:@selector(document:shouldCloseOtherTab:contextInfo:) contextInfo:nullptr];
		return;
	}
	if (!window.visible)
		[self showWindows];
	[window performClose:sender];
}

- (void)changeTabPin
{
	_tabPinned = !_tabPinned;
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	[controller refreshDocumentTabs];
	[controller workspaceChanged];
}

- (void)changeTabColor:(NSInteger)index
{
	_tabColorIndex = std::clamp<NSInteger>(index, 0, 5);
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	[controller refreshDocumentTabs];
	[controller workspaceChanged];
}

- (void)document:(NSDocument *)document shouldCloseOtherTab:(BOOL)shouldClose contextInfo:(void *)context
{
	if (shouldClose)
		[self close];
}

- (void)refreshChromeMenus
{
	[self.chrome refreshMenus];
	[_searchPanel close];
	_searchPanel = nil;
}

- (void)setFileURL:(NSURL *)fileURL
{
	if (![self.fileURL isEqual:fileURL])
	{
		_diskState = nil;
		_pendingDiskState = nil;
		if (_monitoring)
		{
			_monitoring = NO;
			[_editor message:SCI_SETREADONLY wParam:_readOnlyBeforeMonitoring];
		}
	}
	[super setFileURL:fileURL];
	[self applyTheme];
	[(EditorDocumentController *)NSDocumentController.sharedDocumentController refreshDocumentTabs];
}

- (NSDictionary *)currentDiskState
{
	if (!self.fileURL.isFileURL)
		return nil;
	NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.fileURL.path error:nullptr];
	if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || !attributes[NSFileModificationDate])
		return nil;
	return @{@"date": attributes[NSFileModificationDate], @"size": attributes[NSFileSize] ?: @0,
		@"fileNumber": attributes[NSFileSystemFileNumber] ?: @0};
}

- (void)reloadExternalFileFollowingEnd:(BOOL)follow
{
	const auto readOnly = [_editor message:SCI_GETREADONLY];
	const auto line = [_editor message:SCI_LINEFROMPOSITION wParam:[_editor message:SCI_GETCURRENTPOS]];
	[_editor message:SCI_SETREADONLY wParam:0];
	NSError *error = nil;
	BOOL loaded = [self revertToContentsOfURL:self.fileURL ofType:self.fileType error:&error];
	[_editor message:SCI_SETREADONLY wParam:readOnly];
	if (!loaded)
	{
		if (!follow && error)
			[self presentError:error];
		return;
	}
	[_editor message:follow ? SCI_DOCUMENTEND : SCI_GOTOLINE wParam:line];
	[_editor message:SCI_SCROLLCARET];
	if (_clone && follow)
		[_clone message:SCI_DOCUMENTEND];
}

- (void)checkDiskChanges:(BOOL)checkNormal allowPrompt:(BOOL)allowPrompt
{
	if ((!checkNormal && !_monitoring) || !_editor || _loading || _askingAboutDisk)
		return;
	NSDictionary *current = self.currentDiskState;
	if (!current)
		return;
	if (!_pendingDiskState)
	{
		if ([current isEqual:_diskState])
			return;
		BOOL changed = _diskState != nil || (self.fileModificationDate && ![current[@"date"] isEqual:self.fileModificationDate]);
		BOOL wasSavedHere = _diskState && ![_diskState[@"date"] isEqual:self.fileModificationDate] &&
			[current[@"date"] isEqual:self.fileModificationDate];
		_diskState = current;
		if (!changed || wasSavedHere)
			return;
		_pendingDiskState = current;
	}
	if (_monitoring || ([[EditorResources.shared setting:@"autoReload" fallback:@NO] boolValue] && !self.isDocumentEdited))
	{
		_pendingDiskState = nil;
		[self reloadExternalFileFollowingEnd:_monitoring || [[EditorResources.shared setting:@"reloadToEnd" fallback:@NO] boolValue]];
		return;
	}
	if (!allowPrompt)
		return;
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	NSWindow *window = [controller selectedTabInOtherView:NO].windowControllers.firstObject.window;
	if (!window)
		return;
	_askingAboutDisk = YES;
	NSURL *url = self.fileURL;
	NSAlert *alert = [NSAlert new];
	alert.messageText = [NSString stringWithFormat:@"%@ changed on disk", self.displayName];
	alert.informativeText = self.isDocumentEdited ? @"Reloading will discard the unsaved edits in this document." :
		@"Reload the file to read the latest contents.";
	[alert addButtonWithTitle:EditorUIString(@"Keep Editor Contents")];
	[alert addButtonWithTitle:EditorUIString(@"Reload")];
	[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
		self->_askingAboutDisk = NO;
		self->_pendingDiskState = nil;
		if (response == NSAlertSecondButtonReturn && [self.fileURL isEqual:url])
			[self reloadExternalFileFollowingEnd:[[EditorResources.shared setting:@"reloadToEnd" fallback:@NO] boolValue]];
	}];
}

- (IBAction)monitorFile:(id)sender
{
	if (!self.fileURL || self.isDocumentEdited)
		return;
	if (!_monitoring)
	{
		_readOnlyBeforeMonitoring = [_editor message:SCI_GETREADONLY];
		_diskState = self.currentDiskState;
		[_editor message:SCI_DOCUMENTEND];
	}
	_monitoring = !_monitoring;
	[_editor message:SCI_SETREADONLY wParam:_monitoring || _readOnlyBeforeMonitoring];
	[(EditorDocumentController *)NSDocumentController.sharedDocumentController refreshDocumentTabs];
}

- (BOOL)isMonitoring { return _monitoring; }

- (BOOL)userReadOnly
{
	return _monitoring ? _readOnlyBeforeMonitoring : [self.editor message:SCI_GETREADONLY] != 0;
}

- (void)setUserReadOnly:(BOOL)readOnly
{
	if (_monitoring)
		_readOnlyBeforeMonitoring = readOnly;
	else
		[self.editor message:SCI_SETREADONLY wParam:readOnly];
}

- (IBAction)saveCopyAs:(id)sender
{
	if (((EditorDocumentController *)NSDocumentController.sharedDocumentController).launchOptions.savingForbidden)
	{
		NSBeep();
		return;
	}
	NSSavePanel *panel = NSSavePanel.savePanel;
	panel.nameFieldStringValue = self.displayName;
	panel.directoryURL = self.fileURL.URLByDeletingLastPathComponent;
	[panel beginSheetModalForWindow:self.windowForSheet completionHandler:^(NSModalResponse response) {
		if (response != NSModalResponseOK)
			return;
		if ([panel.URL.URLByStandardizingPath isEqual:self.fileURL.URLByStandardizingPath])
		{
			NSBeep();
			return;
		}
		NSError *error = nil;
		NSData *data = [self dataOfType:self.fileType error:&error];
		if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error] && error)
			[self presentError:error];
	}];
}

- (IBAction)moveFileToTrash:(id)sender
{
	NSURL *url = self.fileURL;
	if (!url)
		return;
	NSAlert *alert = [NSAlert new];
	alert.messageText = [NSString stringWithFormat:@"Move %@ to the Trash?", self.displayName];
	if (self.isDocumentEdited)
		alert.informativeText = EditorUIString(@"Moving this file to the Trash will also discard its unsaved edits.");
	[alert addButtonWithTitle:EditorUIString(@"Cancel")];
	[alert addButtonWithTitle:EditorUIString(@"Move to Trash")].hasDestructiveAction = YES;
	[alert beginSheetModalForWindow:self.windowForSheet completionHandler:^(NSModalResponse response) {
		if (response == NSAlertSecondButtonReturn && [self.fileURL isEqual:url])
			[NSWorkspace.sharedWorkspace recycleURLs:@[url] completionHandler:^(NSDictionary *results, NSError *error) {
				dispatch_async(dispatch_get_main_queue(), ^{
					if (error)
						[self presentError:error];
					else if ([self.fileURL isEqual:url])
						[self close];
				});
			}];
	}];
}

- (void)applyTheme
{
	if (!_editor)
		return;
	NSString *extension = self.fileURL.pathExtension.lowercaseString ?: @"";
	NSString *identifier = nil;
	const BOOL large = self.largeFileMode;
	_statusLanguage = [EditorResources.shared configure:_editor extension:extension language:_languageOverride
		syntaxHighlighting:!large identifier:&identifier];
	_languageIdentifier = identifier;
	[_editor message:SCI_SETMARGINWIDTHN wParam:2 lParam:[_editor message:SCI_GETLEXER] <= SCLEX_NULL ? 0 : 14];
	if (_clone)
	{
		[EditorResources.shared configure:_clone extension:extension language:_languageOverride
			syntaxHighlighting:!large identifier:nullptr];
		[_clone message:SCI_SETMARGINWIDTHN wParam:2 lParam:[_clone message:SCI_GETLEXER] <= SCLEX_NULL ? 0 : 14];
	}
	ApplyEditorGuides(_editor);
	if (_clone)
		ApplyEditorGuides(_clone);
	if (large && [[EditorResources.shared setting:@"largeFileDisableWrap" fallback:@NO] boolValue])
	{
		for (ScintillaView *view in _clone ? @[_editor, _clone] : @[_editor])
			[view message:SCI_SETWRAPMODE wParam:SC_WRAP_NONE];
	}
	for (int style = 0; style <= TokenMarkCount; ++style)
	{
		const int indicator = style ? FirstTokenMark + style - 1 : FindMark;
		NSString *name = style ? [NSString stringWithFormat:@"Mark Style %d", style] : @"Find Mark Style";
		NSArray<NSColor *> *defaults = @[NSColor.systemRedColor, NSColor.systemTealColor, NSColor.systemOrangeColor,
			NSColor.systemYellowColor, NSColor.systemPurpleColor, NSColor.systemGreenColor];
		NSColor *color = [EditorResources.shared widgetColor:name background:YES] ?: defaults[style];
		color = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
		const auto rgb = static_cast<unsigned>(color.redComponent * 255) |
			(static_cast<unsigned>(color.greenComponent * 255) << 8) | (static_cast<unsigned>(color.blueComponent * 255) << 16);
		for (ScintillaView *view in _clone ? @[_editor, _clone] : @[_editor])
		{
			[view message:SCI_INDICSETSTYLE wParam:indicator lParam:INDIC_STRAIGHTBOX];
			[view message:SCI_INDICSETFORE wParam:indicator lParam:rgb];
			[view message:SCI_INDICSETALPHA wParam:indicator lParam:75];
			[view message:SCI_INDICSETUNDER wParam:indicator lParam:1];
		}
	}
	[_chrome refreshColors];
	[_resultsView refreshTheme];
	self.windowControllers.firstObject.window.appearance = _chrome.appearance;
	_searchPanel.appearance = _chrome.appearance;
	[self updateStatus];
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	if (controller.focusedDocument == self)
	{
		[controller refreshFunctionList];
		[[controller windowOwnerForDocument:self]->_documentMap refreshStyle];
	}
}

- (IBAction)selectLanguage:(NSMenuItem *)sender
{
	_languageOverride = sender.representedObject;
	[self applyTheme];
}

- (IBAction)setFoldState:(id)sender
{
	[self.editor message:SCI_FOLDALL wParam:[sender tag]];
}

- (IBAction)foldAtLevel:(NSMenuItem *)sender
{
	ScintillaView *editor = self.editor;
	const BOOL expand = sender.tag < 0;
	const NSInteger level = labs(sender.tag);
	if (level == 9)
	{
		const auto line = [editor message:SCI_LINEFROMPOSITION wParam:[editor message:SCI_GETCURRENTPOS]];
		[editor message:SCI_FOLDLINE wParam:line lParam:expand ? SC_FOLDACTION_EXPAND : SC_FOLDACTION_CONTRACT];
		return;
	}
	for (sptr_t line = 0; line < [editor message:SCI_GETLINECOUNT]; ++line)
	{
		const auto current = [editor message:SCI_GETFOLDLEVEL wParam:line];
		if ((current & SC_FOLDLEVELHEADERFLAG) && (current & SC_FOLDLEVELNUMBERMASK) == SC_FOLDLEVELBASE + level - 1)
			[editor message:SCI_FOLDLINE wParam:line lParam:expand ? SC_FOLDACTION_EXPAND : SC_FOLDACTION_CONTRACT];
	}
}

- (IBAction)hideSelectedLines:(id)sender
{
	ScintillaView *editor = self.editor;
	const auto start = [editor message:SCI_GETSELECTIONSTART];
	const auto end = [editor message:SCI_GETSELECTIONEND];
	const auto first = MAX(1, [editor message:SCI_LINEFROMPOSITION wParam:start]);
	const auto last = [editor message:SCI_LINEFROMPOSITION wParam:end > start ? end - 1 : end];
	if (first <= last)
	{
		[editor message:SCI_HIDELINES wParam:first lParam:last];
		[editor message:SCI_GOTOLINE wParam:first - 1];
	}
}

- (IBAction)showHiddenLines:(id)sender
{
	ScintillaView *editor = self.editor;
	[editor message:SCI_FOLDALL wParam:SC_FOLDACTION_EXPAND];
	[editor message:SCI_SHOWLINES wParam:0 lParam:[editor message:SCI_GETLINECOUNT] - 1];
}

- (IBAction)showDocumentSummary:(id)sender
{
	NSString *text = self.editor.string ?: @"";
	__block NSUInteger words = 0;
	[text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
		usingBlock:^(NSString *substring, NSRange range, NSRange enclosing, BOOL *stop) { ++words; }];
	NSAlert *summary = [NSAlert new];
	summary.messageText = self.displayName;
	const auto characters = [self.editor message:SCI_COUNTCHARACTERS wParam:0 lParam:[self.editor message:SCI_GETLENGTH]];
	summary.informativeText = [NSString localizedStringWithFormat:@"Characters: %ld\nWords: %lu\nLines: %ld\nBytes (UTF-8): %ld",
		characters, words, [self.editor message:SCI_GETLINECOUNT], [self.editor message:SCI_GETLENGTH]];
	[summary beginSheetModalForWindow:self.windowForSheet completionHandler:nil];
}

- (NSPrintOperation *)printOperationWithSettings:(NSDictionary<NSPrintInfoAttributeKey, id> *)settings error:(NSError **)error
{
	return EditorPrintOperation(self, settings);
}

- (IBAction)printNow:(id)sender
{
	NSPrintOperation *operation = EditorPrintOperation(self, @{});
	operation.showsPrintPanel = NO;
	[operation runOperation];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	if (controller.launchOptions.savingForbidden &&
		(item.action == @selector(saveDocument:) || item.action == @selector(saveDocumentAs:) ||
		 item.action == @selector(saveDocumentTo:) || item.action == @selector(saveCopyAs:)))
		return NO;
	if (item.action == @selector(toggleZoomSync:))
	{
		item.state = controller.syncZoom ? NSControlStateValueOn : NSControlStateValueOff;
		return controller.hasOtherView;
	}
	if (item.action == @selector(toggleAlwaysOnTop:))
		item.state = self.windowForSheet.level == NSFloatingWindowLevel ? NSControlStateValueOn : NSControlStateValueOff;
	if (item.action == @selector(focusAnotherView:))
		return controller.hasOtherView;
	if (item.action == @selector(toggleSymbolDisplay:))
	{
		unsigned message = item.tag == 44025 ? SCI_GETVIEWWS : item.tag == 44026 ? SCI_GETVIEWEOL : SCI_GETWRAPVISUALFLAGS;
		item.state = [self.editor message:message] ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (item.action == @selector(setTextDirection:))
	{
		auto direction = [self.editor message:SCI_GETBIDIRECTIONAL];
		item.state = direction == item.tag || (item.tag == SC_BIDIRECTIONAL_L2R && direction == SC_BIDIRECTIONAL_DISABLED) ?
			NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (item.action == @selector(closeOtherView:))
		return controller.hasOtherView;
	if (item.action == @selector(toggleVerticalScrollSync:) || item.action == @selector(toggleHorizontalScrollSync:))
	{
		item.state = item.action == @selector(toggleVerticalScrollSync:) ? controller.syncVerticalScroll : controller.syncHorizontalScroll;
		return controller.hasOtherView;
	}
	if (item.action == @selector(toggleDocumentList:))
	{
		item.state = controller.documentListVisible ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (item.action == @selector(selectLanguage:))
	{
		item.state = (_languageOverride == item.representedObject || [_languageOverride isEqual:item.representedObject]) ?
			NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (item.action == @selector(startRecordingMacro:))
		return !_recording;
	if (item.action == @selector(stopRecordingMacro:))
		return _recording;
	if (item.action == @selector(playRecordedMacro:) || item.action == @selector(saveRecordedMacro:))
		return !_recording && !_macro.empty();
	if (item.action == @selector(repeatRecordedMacro:))
		return !_recording && (!_macro.empty() || EditorMacroLibrary.shared.macros.count);
	if (item.action == @selector(playSavedMacro:))
		return !_recording;
	if (item.action == @selector(toggleDocumentReadOnly:))
	{
		item.state = [self.editor message:SCI_GETREADONLY] ? NSControlStateValueOn : NSControlStateValueOff;
		return self.editor != nil && !_monitoring;
	}
	if (item.action == @selector(monitorFile:))
	{
		item.state = _monitoring;
		return self.fileURL != nil && !self.isDocumentEdited;
	}
	if (item.action == @selector(moveFileToTrash:))
		return self.fileURL != nil;
	if (item.action == @selector(reinterpretEncoding:))
	{
		item.state = _readerEncoding == item.tag ? NSControlStateValueOn : NSControlStateValueOff;
		return self.fileURL != nil && !self.isDocumentEdited;
	}
	return [super validateMenuItem:item];
}

- (IBAction)startRecordingMacro:(id)sender
{
	if (_recording)
		return;
	_macro.clear();
	_recording = YES;
	_macroSource = self.editor;
	[_macroSource message:SCI_STARTRECORD];
	[_chrome refreshToolbar];
}

- (IBAction)stopRecordingMacro:(id)sender
{
	[_macroSource message:SCI_STOPRECORD];
	_macroSource = nil;
	_recording = NO;
	[_chrome refreshToolbar];
}

- (void)recordStep:(const SCNotification *)notification
{
	MacroStep step = {static_cast<unsigned int>(notification->message), notification->wParam, notification->lParam, std::nullopt};
	const char *text = reinterpret_cast<const char *>(step.lParam);
	switch (step.message)
	{
	case SCI_REPLACESEL:
		if (text && (std::strcmp(text, "\n") == 0 || std::strcmp(text, "\r") == 0))
		{
			if (_editor && [_editor message:SCI_GETEOLMODE] == SC_EOL_CRLF && *text == '\n' &&
				!_macro.empty() && _macro.back().message == SCI_NEWLINE && _macro.back().lParam == '\r')
				_macro.pop_back();
			step = {SCI_NEWLINE, 0, *text, std::nullopt};
			break;
		}
		[[fallthrough]];
	case SCI_INSERTTEXT:
	case SCI_SEARCHNEXT:
	case SCI_SEARCHPREV:
		if (text)
			step.text = std::string(text);
		break;
	case SCI_ADDTEXT:
	case SCI_APPENDTEXT:
		if (text)
			step.text = std::string(text, step.wParam);
		break;
	}
	_macro.push_back(std::move(step));
}

- (void)playMacro:(const std::vector<MacroStep> &)steps count:(NSUInteger)count untilEOF:(BOOL)untilEOF
{
	if (_recording || _playingMacro || steps.empty())
		return;
	_playingMacro = YES;
	ScintillaView *editor = self.editor;
	[editor message:SCI_BEGINUNDOACTION];
	for (NSUInteger i = 0; untilEOF || i < count; ++i)
	{
		RecordedSearch search;
		const auto before = [editor message:SCI_GETCURRENTPOS];
		const auto lengthBefore = [editor message:SCI_GETLENGTH];
		if (untilEOF && before >= lengthBefore)
			break;
		for (const auto &step : steps)
		{
			if (IsMacroSearchStep(step.message))
			{
				[self playSearchStep:step state:search];
				continue;
			}
			if (!step.message && IsMacroMenuCommand(step.wParam))
			{
				if (step.wParam == 41006)
					[self saveDocument:nil];
				else
					[self applyWhitespaceCommand:step.wParam];
				continue;
			}
			const auto parameter = step.text ? reinterpret_cast<sptr_t>(step.text->c_str()) :
				step.message == SCI_NEWLINE ? 0 : step.lParam;
			if (step.message == SCI_SEARCHNEXT || step.message == SCI_SEARCHPREV)
				SearchEditorFromAnchor(editor, step.message, step.wParam, parameter);
			else
				[editor message:step.message wParam:step.wParam lParam:parameter];
		}
		if (untilEOF && [editor message:SCI_GETLENGTH] - [editor message:SCI_GETCURRENTPOS] >= lengthBefore - before)
			break;
	}
	[editor message:SCI_ENDUNDOACTION];
	[editor message:SCI_SCROLLCARET];
	_playingMacro = NO;
}

- (void)playSearchStep:(const MacroStep &)step state:(RecordedSearch &)search
{
	NSString *value = step.text ? [[NSString alloc] initWithBytes:step.text->data()
		length:step.text->size() encoding:NSUTF8StringEncoding] : nil;
	switch (step.message)
	{
		case 1700: search = RecordedSearch{}; return;
		case 1601: search.query = value ?: @""; return;
		case 1602: search.replacement = value ?: @""; return;
		case 1654: search.filters = value ?: @"*.*"; return;
		case 1655: search.folder = value ?: @""; return;
		case 1625: search.mode = step.lParam; return;
		case 1702: search.options = step.lParam; return;
	}
	if (!_searchPanel)
		[self makeSearchPanel];
	const NSInteger command = step.lParam;
	_searchMode.selectedSegment = command == 1665 || command == 1666 ? 4 : command == 1656 || command == 1660 ? 2 :
		command == 1615 || command == 1633 ? 3 : command == 1608 || command == 1609 || command == 1635 ? 1 : 0;
	_searchInput.stringValue = search.query;
	_replaceInput.stringValue = search.replacement;
	if (search.folder.length)
		_searchFolder.stringValue = search.folder;
	_searchFilters.stringValue = search.filters;
	_matchCase.state = (search.options & 1) != 0;
	_wholeWord.state = (search.options & 2) != 0;
	_purgeMarks.state = (search.options & 4) != 0;
	_bookmarkMatches.state = (search.options & 16) != 0;
	_recursive.state = (search.options & 32) != 0;
	_includeHidden.state = (search.options & 64) != 0;
	_wrapSearch.state = (search.options & 256) != 0;
	_regularExpression.state = search.mode == 2;
	_extendedSearch.state = search.mode == 1;
	_matchNewline.state = (search.options & 1024) != 0;
	[self updateSearchMode:nil];
	_inSelection.state = !_inSelection.hidden && (search.options & 128) != 0;
	[self captureSearchSelection:nil];
	for (NSUInteger index = 0; index < _projectSearchControls.count; ++index)
		_projectSearchControls[index].state = (search.options & (128 << index)) != 0;
	NSButton *action = [NSButton new];
	switch (command)
	{
		case 1: action.tag = search.options & 512 ? 0 : 1; break;
		case 43010: action.tag = 1; break;
		case 1608: action.tag = 2; break;
		case 1609: action.tag = 3; break;
		case 1656: case 1666: action.tag = 5; break;
		case 1660: case 1665: action.tag = 6; break;
		case 1615: action.tag = 7; break;
		case 1633: action.tag = 8; break;
		case 1614: action.tag = 10; break;
		case 1641: action.tag = 11; break;
		case 1636: action.tag = 12; break;
		case 1635: action.tag = 13; break;
		default: return;
	}
	[self performSearch:action];
}

- (IBAction)saveDocument:(id)sender
{
	if (_recording)
		_macro.push_back({0, 41006, 0, std::nullopt});
	[super saveDocument:sender];
}

- (IBAction)playRecordedMacro:(id)sender
{
	[self playMacro:_macro count:1 untilEOF:NO];
}

- (IBAction)playSavedMacro:(NSMenuItem *)sender
{
	EditorMacro *macro = sender.representedObject;
	if ([macro isKindOfClass:EditorMacro.class])
		[self playMacro:[macro steps] count:1 untilEOF:NO];
}

- (BOOL)saveRecordedMacroNamed:(NSString *)name replacing:(BOOL)replacing error:(NSError **)error
{
	return [EditorMacroLibrary.shared saveSteps:_macro name:name replacing:replacing error:error];
}

- (IBAction)saveRecordedMacro:(id)sender
{
	if (_recording || _macro.empty())
		return;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = [EditorResources.shared label:@"42025" fallback:@"Save Current Recorded Macro"];
	[alert addButtonWithTitle:EditorUIString(@"Save")];
	[alert addButtonWithTitle:EditorUIString(@"Cancel")];
	NSTextField *input = [NSTextField textFieldWithString:@""];
	input.frame = NSMakeRect(0, 0, 260, 24);
	input.placeholderString = EditorUIString(@"Macro name");
	alert.accessoryView = input;
	alert.window.initialFirstResponder = input;
	if ([alert runModal] != NSAlertFirstButtonReturn)
		return;
	NSString *name = [input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSError *error = nil;
	if ([self saveRecordedMacroNamed:name replacing:NO error:&error])
		return;
	if (error.code == NSFileWriteFileExistsError)
	{
		NSAlert *replace = [[NSAlert alloc] init];
		replace.messageText = [NSString stringWithFormat:@"Replace the macro “%@”?", name];
		[replace addButtonWithTitle:EditorUIString(@"Cancel")];
		[replace addButtonWithTitle:EditorUIString(@"Replace")];
		if ([replace runModal] != NSAlertSecondButtonReturn)
			return;
		error = nil;
		if ([self saveRecordedMacroNamed:name replacing:YES error:&error])
			return;
	}
	if (error)
		[self presentError:error];
}

- (IBAction)repeatRecordedMacro:(id)sender
{
	if (_recording)
		return;
	NSArray<EditorMacro *> *macros = EditorMacroLibrary.shared.macros;
	if (_macro.empty() && !macros.count)
		return;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = [EditorResources.shared label:@"42032" fallback:@"Run a Macro Multiple Times"];
	[alert addButtonWithTitle:EditorUIString(@"Run")];
	[alert addButtonWithTitle:EditorUIString(@"Cancel")];
	[alert addButtonWithTitle:EditorUIString(@"Run Until End of File")];
	NSPopUpButton *choices = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	if (!_macro.empty())
		[choices addItemWithTitle:@"Current recorded macro"];
	for (EditorMacro *macro in macros)
	{
		NSString *title = macro.folder.length ? [NSString stringWithFormat:@"%@ / %@", macro.folder, macro.name] : macro.name;
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
		item.representedObject = macro;
		[choices.menu addItem:item];
	}
	[choices selectItemAtIndex:0];
	NSTextField *count = [NSTextField textFieldWithString:@"1"];
	NSStackView *form = [NSStackView stackViewWithViews:@[choices, [NSTextField labelWithString:EditorUIString(@"Number of times")], count]];
	form.orientation = NSUserInterfaceLayoutOrientationVertical;
	form.alignment = NSLayoutAttributeLeading;
	form.frame = NSMakeRect(0, 0, 275, 90);
	[choices.widthAnchor constraintLessThanOrEqualToConstant:275].active = YES;
	[count.widthAnchor constraintEqualToConstant:100].active = YES;
	alert.accessoryView = form;
	alert.window.initialFirstResponder = count;
	const auto response = [alert runModal];
	if (response != NSAlertFirstButtonReturn && response != NSAlertThirdButtonReturn)
		return;
	EditorMacro *selected = choices.selectedItem.representedObject;
	const auto &steps = selected ? [selected steps] : _macro;
	if (response == NSAlertThirdButtonReturn)
	{
		[self playMacro:steps count:0 untilEOF:YES];
		return;
	}
	NSScanner *scanner = [NSScanner scannerWithString:count.stringValue];
	NSInteger times = 0;
	if (![scanner scanInteger:&times] || !scanner.isAtEnd || times < 1)
	{
		NSBeep();
		return;
	}
	[self playMacro:steps count:times untilEOF:NO];
}

- (IBAction)convertEncoding:(NSMenuItem *)sender
{
	NSData *bom = sender.representedObject;
	NSStringEncoding encoding = sender.tag;
	if (_encoding == encoding && (_bom == bom || [_bom isEqual:bom]))
		return;
	if (![_editor.string canBeConvertedToEncoding:encoding])
	{
		[self presentError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError
			userInfo:@{NSLocalizedDescriptionKey: EditorUIString(@"The document contains characters that this encoding cannot represent.")}]];
		return;
	}
	_encoding = encoding;
	_readerEncoding = 0;
	_bom = bom;
	_encodingChanged = YES;
	if (!self.isDocumentEdited)
		[self updateChangeCount:NSChangeDone];
	[self updateStatus];
	[(EditorDocumentController *)NSDocumentController.sharedDocumentController refreshDocumentTabs];
	[_chrome refreshToolbar];
}

- (void)setReaderEncoding:(NSStringEncoding)encoding
{
	_readerEncoding = encoding;
}

- (BOOL)reinterpretWithEncoding:(NSStringEncoding)encoding error:(NSError **)error
{
	if (!self.fileURL || self.isDocumentEdited || !IsAvailableEncoding(encoding))
		return NO;
	const auto oldEncoding = _readerEncoding;
	_readerEncoding = encoding;
	if ([self revertToContentsOfURL:self.fileURL ofType:self.fileType error:error])
		return YES;
	_readerEncoding = oldEncoding;
	return NO;
}

- (IBAction)reinterpretEncoding:(NSMenuItem *)sender
{
	if (_readerEncoding == sender.tag)
		return;
	if ([self.editor message:SCI_CANUNDO])
	{
		NSAlert *alert = [[NSAlert alloc] init];
		alert.messageText = EditorUIString(@"Reopen the file in the selected character set?");
		alert.informativeText = EditorUIString(@"Reopening clears the undo history.");
		[alert addButtonWithTitle:EditorUIString(@"Cancel")];
		[alert addButtonWithTitle:EditorUIString(@"Reopen")];
		if ([alert runModal] != NSAlertSecondButtonReturn)
			return;
	}
	NSError *error = nil;
	if (![self reinterpretWithEncoding:sender.tag error:&error] && error)
		[self presentError:error];
}

- (void)loadEditor
{
	if (!_editor)
		return;
	_selectionStart.reset();
	_loading = YES;
	[_editor message:SCI_SETUNDOCOLLECTION wParam:0];
	[_editor message:SCI_CLEARALL];
	if (_loadedUTF8.length)
		[_editor message:SCI_ADDTEXT wParam:_loadedUTF8.length lParam:reinterpret_cast<sptr_t>(_loadedUTF8.bytes)];
	[_editor message:SCI_SETUNDOCOLLECTION wParam:1];
	[_editor message:SCI_EMPTYUNDOBUFFER];
	const auto history = [_editor message:SCI_GETCHANGEHISTORY];
	[_editor message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_DISABLED];
	[_editor message:SCI_SETCHANGEHISTORY wParam:history];
	[_editor message:SCI_SETSAVEPOINT];
	[_editor message:SCI_GOTOPOS wParam:0];
	[_editor message:SCI_COLOURISE wParam:0 lParam:-1];
	std::string_view bytes(_loadedUTF8.length ? static_cast<const char *>(_loadedUTF8.bytes) : "", _loadedUTF8.length);
	size_t eol = bytes.find_first_of("\r\n");
	int eolMode = SC_EOL_CRLF;
	if (eol != bytes.npos)
		eolMode = bytes[eol] == '\n' ? SC_EOL_LF :
			eol + 1 < bytes.size() && bytes[eol + 1] == '\n' ? SC_EOL_CRLF : SC_EOL_CR;
	else if (!self.fileURL)
	{
		static const int endings[] = {SC_EOL_CRLF, SC_EOL_CR, SC_EOL_LF};
		NSInteger choice = [[EditorResources.shared setting:@"newDocumentEOL" fallback:@0] integerValue];
		eolMode = endings[std::clamp<NSInteger>(choice, 0, 2)];
	}
	[_editor message:SCI_SETEOLMODE wParam:eolMode];
	_loading = NO;
	_loadedUTF8 = nil;
	[self updateStatus];
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName error:(NSError **)error
{
	NSStringEncoding encoding = _readerEncoding;
	NSData *bom = nil;
	NSString *text = encoding ? DecodeEditorTextWithEncoding(data, encoding) : DecodeEditorText(data, &encoding, &bom);
	if (!text)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadInapplicableStringEncodingError
				userInfo:@{NSLocalizedDescriptionKey: encoding ? EditorUIString(@"The file cannot be decoded using the selected character set.") :
					EditorUIString(@"Open text encoded as UTF-8, UTF-16 with BOM, or Windows-1252.")}];
		return NO;
	}
	_encoding = encoding;
	_encodingChanged = NO;
	_bom = bom;
	_loadedUTF8 = [text dataUsingEncoding:NSUTF8StringEncoding];
	if (_editor)
		[self applyTheme];
	[self loadEditor];
	return YES;
}

- (NSData *)editorUTF8
{
	if (!_editor)
		return _loadedUTF8 ?: [NSData data];
	const auto length = [_editor message:SCI_GETLENGTH];
	const auto *bytes = reinterpret_cast<const void *>([_editor message:SCI_GETCHARACTERPOINTER]);
	return [NSData dataWithBytes:bytes length:length];
}

- (NSDictionary<NSString *, id> *)workspaceEntry
{
	NSMutableDictionary<NSString *, id> *entry = [NSMutableDictionary dictionary];
	entry[@"name"] = self.displayName;
	entry[@"path"] = self.fileURL.path;
	entry[@"fileModified"] = self.fileModificationDate;
	entry[@"language"] = _languageOverride;
	entry[@"tabPinned"] = @(_tabPinned);
	entry[@"tabColor"] = @(_tabColorIndex);
	if (_readerEncoding)
		entry[@"readerEncoding"] = @(_readerEncoding);
	if (self.isDocumentEdited && [[EditorResources.shared setting:@"checkpointDrafts" fallback:@YES] boolValue])
	{
		entry[@"unsavedUTF8"] = [self editorUTF8];
		entry[@"encoding"] = @(_encoding);
		entry[@"bom"] = _bom;
	}
	entry[@"eol"] = @([_editor message:SCI_GETEOLMODE]);
	entry[@"startPos"] = @([_editor message:SCI_GETANCHOR]);
	entry[@"endPos"] = @([_editor message:SCI_GETCURRENTPOS]);
	for (const auto &field : SessionFields)
		entry[@(field.name)] = @([_editor message:field.read]);
	NSMutableArray<NSNumber *> *marks = [NSMutableArray array];
	NSMutableArray<NSNumber *> *folds = [NSMutableArray array];
	if (_editor)
	{
		for (auto line = [_editor message:SCI_MARKERNEXT wParam:0 lParam:1 << Bookmark]; line >= 0;
			line = [_editor message:SCI_MARKERNEXT wParam:line + 1 lParam:1 << Bookmark])
			[marks addObject:@(line)];
		for (auto line = [_editor message:SCI_CONTRACTEDFOLDNEXT wParam:0]; line >= 0;
			line = [_editor message:SCI_CONTRACTEDFOLDNEXT wParam:line + 1])
			[folds addObject:@(line)];
	}
	entry[@"marks"] = marks;
	entry[@"folds"] = folds;
	if (_clone)
	{
		NSMutableDictionary<NSString *, id> *clone = [NSMutableDictionary dictionary];
		clone[@"startPos"] = @([_clone message:SCI_GETANCHOR]);
		clone[@"endPos"] = @([_clone message:SCI_GETCURRENTPOS]);
		clone[@"focused"] = @(self.editor == _clone);
		for (const auto &field : SessionFields)
			clone[@(field.name)] = @([_clone message:field.read]);
		entry[@"clone"] = clone;
	}
	return entry;
}

- (void)restoreWorkspaceEntry:(NSDictionary<NSString *, id> *)entry
{
	if (!self.fileURL)
	{
		NSString *name = WorkspaceValue(entry, @"name", NSString.class);
		if (name.length)
		{
			_untitledName = WorkspaceValue(entry, @"path", NSString.class) ? [@"Recovered " stringByAppendingString:name] : name;
			NSScanner *scanner = [NSScanner scannerWithString:name];
			NSInteger number = 0;
			if ([scanner scanString:@"new " intoString:nullptr] && [scanner scanInteger:&number] &&
				scanner.isAtEnd && number > 0 && number < NSIntegerMax)
				NextUntitledNumber = MAX(NextUntitledNumber, static_cast<NSUInteger>(number + 1));
		}
	}
	_languageOverride = WorkspaceValue(entry, @"language", NSString.class);
	_tabPinned = [WorkspaceValue(entry, @"tabPinned", NSNumber.class) boolValue];
	_tabColorIndex = std::clamp<NSInteger>([WorkspaceValue(entry, @"tabColor", NSNumber.class) integerValue], 0, 5);
	auto readerEncoding = [WorkspaceValue(entry, @"readerEncoding", NSNumber.class) unsignedIntegerValue];
	if (IsAvailableEncoding(readerEncoding))
		_readerEncoding = readerEncoding;
	NSData *unsaved = WorkspaceValue(entry, @"unsavedUTF8", NSData.class);
	if (unsaved)
	{
		_loadedUTF8 = unsaved;
		auto encoding = [WorkspaceValue(entry, @"encoding", NSNumber.class) unsignedIntegerValue];
		if (IsAvailableEncoding(encoding))
			_encoding = encoding;
		_bom = WorkspaceValue(entry, @"bom", NSData.class);
	}
	[self makeWindowControllers];
	NSNumber *eol = WorkspaceValue(entry, @"eol", NSNumber.class);
	if (eol && eol.integerValue >= SC_EOL_CRLF && eol.integerValue <= SC_EOL_LF)
		[_editor message:SCI_SETEOLMODE wParam:eol.integerValue];
	auto length = [_editor message:SCI_GETLENGTH];
	auto start = std::clamp([WorkspaceValue(entry, @"startPos", NSNumber.class) longLongValue], 0LL, static_cast<long long>(length));
	auto end = std::clamp([WorkspaceValue(entry, @"endPos", NSNumber.class) longLongValue], 0LL, static_cast<long long>(length));
	[_editor message:SCI_SETSEL wParam:start lParam:end];
	auto lineCount = [_editor message:SCI_GETLINECOUNT];
	for (id mark in WorkspaceValue(entry, @"marks", NSArray.class))
		if ([mark isKindOfClass:NSNumber.class] && [mark integerValue] >= 0 && [mark integerValue] < lineCount)
			[_editor message:SCI_MARKERADD wParam:[mark integerValue] lParam:Bookmark];
	for (id fold in WorkspaceValue(entry, @"folds", NSArray.class))
		if ([fold isKindOfClass:NSNumber.class] && [fold integerValue] >= 0 && [fold integerValue] < lineCount)
			[_editor message:SCI_FOLDLINE wParam:[fold integerValue] lParam:SC_FOLDACTION_CONTRACT];
	for (const auto &field : SessionFields)
		if (NSNumber *setting = WorkspaceValue(entry, @(field.name), NSNumber.class))
			[_editor message:field.write wParam:std::clamp(setting.longLongValue, 0LL, static_cast<long long>(INT_MAX))];
	if (NSDictionary *clone = WorkspaceValue(entry, @"clone", NSDictionary.class))
	{
		[self addClonedView];
		auto cloneStart = std::clamp([WorkspaceValue(clone, @"startPos", NSNumber.class) longLongValue], 0LL, static_cast<long long>(length));
		auto cloneEnd = std::clamp([WorkspaceValue(clone, @"endPos", NSNumber.class) longLongValue], 0LL, static_cast<long long>(length));
		[_clone message:SCI_SETSEL wParam:cloneStart lParam:cloneEnd];
		for (const auto &field : SessionFields)
			if (NSNumber *setting = WorkspaceValue(clone, @(field.name), NSNumber.class))
				[_clone message:field.write wParam:std::clamp(setting.longLongValue, 0LL, static_cast<long long>(INT_MAX))];
		if ([WorkspaceValue(clone, @"focused", NSNumber.class) boolValue])
			[self focusClonedEditor];
	}
	if (unsaved)
	{
		_encodingChanged = YES;
		[self updateChangeCount:NSChangeDone];
	}
	[self updateStatus];
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)error
{
	NSData *data = EncodeEditorText([self editorUTF8], _encoding, _bom);
	if (!data)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError userInfo:nil];
		return nil;
	}
	return data;
}

- (void)saveToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)operation
	completionHandler:(void (^)(NSError *))completionHandler
{
	[super saveToURL:url ofType:typeName forSaveOperation:operation completionHandler:^(NSError *error) {
		if (!error && operation != NSSaveToOperation)
		{
			self->_encodingChanged = NO;
			[self.editor message:SCI_SETSAVEPOINT];
			[(EditorDocumentController *)NSDocumentController.sharedDocumentController workspaceChanged];
		}
		completionHandler(error);
	}];
}

- (BOOL)writeSafelyToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)operation
	error:(NSError **)error
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	if (controller.launchOptions.savingForbidden)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError
				userInfo:@{NSURLErrorKey: url, NSLocalizedDescriptionKey: EditorUIString(@"Saving is disabled for this instance.")}];
		return NO;
	}
	EditorResources *resources = EditorResources.shared;
	const NSInteger backup = [[resources setting:@"backupMode" fallback:@0] integerValue];
	if (backup && (operation == NSSaveOperation || operation == NSSaveAsOperation) &&
		url.isFileURL && [NSFileManager.defaultManager fileExistsAtPath:url.path])
	{
		NSData *original = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
		if (!original)
			return NO;
		NSString *directoryPath = [[resources setting:@"backupDirectory" fallback:@""] stringByExpandingTildeInPath];
		NSURL *directory = directoryPath.isAbsolutePath ? [NSURL fileURLWithPath:directoryPath isDirectory:YES] :
			url.URLByDeletingLastPathComponent;
		NSString *suffix = backup == 1 ? @"bak" : [NSString stringWithFormat:@"%.0f-%@.bak",
			NSDate.date.timeIntervalSince1970, [NSUUID.UUID.UUIDString substringToIndex:8]];
		NSURL *destination = [directory URLByAppendingPathComponent:[url.lastPathComponent stringByAppendingPathExtension:suffix]];
		if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error] ||
			![original writeToURL:destination options:NSDataWritingAtomic error:error])
			return NO;
	}
	return [super writeSafelyToURL:url ofType:typeName forSaveOperation:operation error:error];
}

- (void)notification:(SCNotification *)notification
{
	if (_loading)
		return;
	switch (notification->nmhdr.code)
	{
		case SCN_FOCUSIN:
			[self updateStatus];
			[[(EditorDocumentController *)NSDocumentController.sharedDocumentController windowOwnerForDocument:self].chrome refreshToolbar];
			[[(EditorDocumentController *)NSDocumentController.sharedDocumentController windowOwnerForDocument:self].chrome refreshTabs];
			[(EditorDocumentController *)NSDocumentController.sharedDocumentController refreshDocumentList];
			[(EditorDocumentController *)NSDocumentController.sharedDocumentController refreshFunctionList];
			[(EditorDocumentController *)NSDocumentController.sharedDocumentController refreshDocumentMap];
			[(EditorDocumentController *)NSDocumentController.sharedDocumentController refreshInsertPanels];
			NotifyPlugins(self, MACPAD_DOCUMENT_ACTIVATED);
			break;
		case SCN_MODIFIED:
			if (_selectionStart && notification->position < *_selectionStart)
			{
				if (notification->modificationType & SC_MOD_INSERTTEXT)
					*_selectionStart += notification->length;
				else if (notification->modificationType & SC_MOD_DELETETEXT)
					*_selectionStart = std::max<sptr_t>(notification->position, *_selectionStart - notification->length);
			}
			if (notification->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT | SC_MOD_CHANGEMARKER | SC_MOD_CHANGEFOLD))
				[(EditorDocumentController *)NSDocumentController.sharedDocumentController workspaceChanged];
			if (notification->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))
			{
				EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
				if (controller.focusedDocument == self)
					[controller refreshFunctionList];
				NotifyPlugins(self, MACPAD_DOCUMENT_CHANGED);
			}
			break;
		case SCN_CHARADDED:
			if (notification->characterSource == SC_CHARACTERSOURCE_DIRECT_INPUT)
			{
				if (!_completion)
					_completion = [EditorCompletion new];
				const BOOL code = _languageIdentifier.length && ![_languageIdentifier isEqualToString:@"normal"];
				EditorResources *resources = EditorResources.shared;
				[_completion typed:notification->ch inEditor:self.editor language:_languageIdentifier
					complete:code && [[resources setting:@"autocomplete" fallback:@YES] boolValue] &&
						(!self.largeFileMode || [[resources setting:@"largeFileCompletion" fallback:@NO] boolValue])
					closePairs:code && [[resources setting:@"autoPairs" fallback:@YES] boolValue]];
			}
			break;
		case SCN_SAVEPOINTLEFT:
			[self updateChangeCount:NSChangeDone];
			[(EditorDocumentController *)NSDocumentController.sharedDocumentController refreshDocumentTabs];
			[_chrome refreshToolbar];
			break;
		case SCN_SAVEPOINTREACHED:
			if (!_encodingChanged)
				[self updateChangeCount:NSChangeCleared];
			[(EditorDocumentController *)NSDocumentController.sharedDocumentController refreshDocumentTabs];
			[_chrome refreshToolbar];
			break;
		case SCN_ZOOM:
			[(EditorDocumentController *)NSDocumentController.sharedDocumentController syncZoomFromDocument:self];
			break;
		case SCN_UPDATEUI:
			[self updateStatus];
			[_chrome refreshToolbar];
			if (notification->updated & (SC_UPDATE_SELECTION | SC_UPDATE_V_SCROLL | SC_UPDATE_H_SCROLL))
				[(EditorDocumentController *)NSDocumentController.sharedDocumentController workspaceChanged];
			if (notification->updated & (SC_UPDATE_V_SCROLL | SC_UPDATE_H_SCROLL))
				[(EditorDocumentController *)NSDocumentController.sharedDocumentController syncScrollFromDocument:self changes:notification->updated];
			if (notification->updated & (SC_UPDATE_V_SCROLL | SC_UPDATE_CONTENT))
				[(EditorDocumentController *)NSDocumentController.sharedDocumentController refreshDocumentMap];
			break;
		case SCN_MARGINCLICK:
			if (notification->margin == 1)
				[self toggleBookmarkAtLine:[self.editor message:SCI_LINEFROMPOSITION wParam:notification->position]];
			break;
		case SCN_MACRORECORD:
			if (_recording)
				[self recordStep:notification];
			break;
	}
}

- (void)updateStatus
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorDocument *focused = controller.focusedDocument;
	EditorDocument *owner = [controller windowOwnerForDocument:self];
	if (owner == self && focused != self && [controller windowOwnerForDocument:focused] == self)
		return;
	EditorChrome *chrome = focused == self ? owner.chrome : _chrome;
	auto position = [self.editor message:SCI_GETCURRENTPOS];
	auto line = [self.editor message:SCI_LINEFROMPOSITION wParam:position];
	auto column = [self.editor message:SCI_GETCOLUMN wParam:position];
	auto eol = [self.editor message:SCI_GETEOLMODE];
	NSString *ending = eol == SC_EOL_CRLF ? @"Windows (CR LF)" : eol == SC_EOL_CR ? @"Macintosh (CR)" : @"Unix (LF)";
	NSString *encoding = _encoding == NSUTF8StringEncoding ? (_bom ? @"UTF-8-BOM" : @"UTF-8") :
		_encoding == NSUTF16LittleEndianStringEncoding ? (_bom ? @"UTF-16 LE BOM" : @"UTF-16 LE") :
		_encoding == NSUTF16BigEndianStringEncoding ? (_bom ? @"UTF-16 BE BOM" : @"UTF-16 BE") :
		_encoding == NSASCIIStringEncoding ? @"ASCII" : @"ANSI";
	if (_readerEncoding)
	{
		auto encodingRef = CFStringConvertNSStringEncodingToEncoding(_readerEncoding);
		CFStringRef name = CFStringConvertEncodingToIANACharSetName(encodingRef);
		if (name)
			encoding = [(__bridge NSString *)name uppercaseString];
	}
	auto length = [self.editor message:SCI_GETLENGTH];
	auto lines = [self.editor message:SCI_GETLINECOUNT];
	auto start = [self.editor message:SCI_GETSELECTIONSTART];
	auto end = [self.editor message:SCI_GETSELECTIONEND];
	EditorResources *resources = EditorResources.shared;
	auto status = ^NSString *(NSString *key, NSString *fallback, long first, long second) {
		NSString *text = [resources label:key fallback:fallback];
		text = [text stringByReplacingOccurrencesOfString:@"$STR_REPLACE1$" withString:[@(first) stringValue]];
		return [text stringByReplacingOccurrencesOfString:@"$STR_REPLACE2$" withString:[@(second) stringValue]];
	};
	NSString *positionText = [[resources label:@"statusbar-Pos" fallback:@"Pos: "] stringByAppendingString:[@(position + 1) stringValue]];
	if (start != end)
	{
		auto selected = [self.editor message:SCI_COUNTCHARACTERS wParam:start lParam:end];
		auto selectedLines = [self.editor message:SCI_LINEFROMPOSITION wParam:end - 1] -
			[self.editor message:SCI_LINEFROMPOSITION wParam:start] + 1;
		positionText = [[resources label:@"statusbar-Sel" fallback:@"Sel: "] stringByAppendingFormat:@"%ld | %ld", selected, selectedLines];
	}
	[chrome setStatusFields:@[
		!_statusLanguage || [_statusLanguage isEqualToString:@"Normal text file"] ?
			[resources label:@"status-normalText" fallback:@"Normal text file"] : _statusLanguage,
		status(@"statusbar-length-lines", @"Length: $STR_REPLACE1$   Lines: $STR_REPLACE2$", length, lines),
		[status(@"statusbar-Ln-Col", @"Ln: $STR_REPLACE1$   Col: $STR_REPLACE2$", line + 1, column + 1)
			stringByAppendingFormat:@"   %@", positionText],
		ending,
		encoding,
		[self.editor message:SCI_GETOVERTYPE] ? @"OVR" : @"INS",
	]];
}

- (void)toggleBookmarkAtLine:(sptr_t)line
{
	const BOOL marked = ([self.editor message:SCI_MARKERGET wParam:line] & (1 << Bookmark)) != 0;
	[self.editor message:marked ? SCI_MARKERDELETE : SCI_MARKERADD wParam:line lParam:Bookmark];
}

- (IBAction)toggleBookmark:(id)sender
{
	[self toggleBookmarkAtLine:[self.editor message:SCI_LINEFROMPOSITION wParam:[self.editor message:SCI_GETCURRENTPOS]]];
}

- (IBAction)navigateBookmark:(id)sender
{
	const BOOL forward = [sender tag] > 0;
	const auto line = [self.editor message:SCI_LINEFROMPOSITION wParam:[self.editor message:SCI_GETCURRENTPOS]];
	const auto lineCount = [self.editor message:SCI_GETLINECOUNT];
	const auto message = forward ? SCI_MARKERNEXT : SCI_MARKERPREVIOUS;
	const auto start = line + (forward ? 1 : -1);
	auto target = start >= 0 && start < lineCount ? [self.editor message:message wParam:start lParam:1 << Bookmark] : -1;
	if (target < 0)
		target = [self.editor message:message wParam:forward ? 0 : lineCount - 1 lParam:1 << Bookmark];
	if (target >= 0)
	{
		[self.editor message:SCI_ENSUREVISIBLE wParam:target];
		[self.editor message:SCI_GOTOLINE wParam:target];
	}
}

- (IBAction)clearBookmarks:(id)sender
{
	[self.editor message:SCI_MARKERDELETEALL wParam:Bookmark];
}

- (IBAction)goToLine:(id)sender
{
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = [EditorResources.shared label:@"43004" fallback:@"Go to Line"];
	[alert addButtonWithTitle:EditorUIString(@"Go")];
	[alert addButtonWithTitle:EditorUIString(@"Cancel")];
	NSTextField *input = [NSTextField textFieldWithString:@""];
	input.frame = NSMakeRect(0, 0, 200, 24);
	input.placeholderString = EditorUIString(@"Line number");
	alert.accessoryView = input;
	alert.window.initialFirstResponder = input;
	if ([alert runModal] != NSAlertFirstButtonReturn)
		return;
	NSScanner *scanner = [NSScanner scannerWithString:input.stringValue];
	long long line;
	if (![scanner scanLongLong:&line] || !scanner.isAtEnd || line < 1 || line > [self.editor message:SCI_GETLINECOUNT])
	{
		NSBeep();
		return;
	}
	[self.editor message:SCI_GOTOLINE wParam:line - 1];
	[self.editor message:SCI_SCROLLCARET];
}

- (IBAction)runEditorCommand:(id)sender
{
	[self.editor message:static_cast<unsigned int>([sender tag])];
}

- (IBAction)showColumnEditor:(id)sender { EditorShowColumnDialog(self.editor); }

- (IBAction)selectOccurrences:(NSMenuItem *)sender
{
	const NSInteger options = (sender.tag - 42090) % 4;
	_multiSelectFlags = (options & 1 ? SCFIND_MATCHCASE : 0) | (options & 2 ? SCFIND_WHOLEWORD : 0);
	EditorAddMatchingSelections(self.editor, sender.tag);
}

- (IBAction)adjustMatchingSelections:(NSMenuItem *)sender
{
	ScintillaView *editor = self.editor;
	const auto selections = [editor message:SCI_GETSELECTIONS];
	if (sender.tag == 42098)
	{
		if (selections > 1)
			[editor message:SCI_DROPSELECTIONN wParam:selections - 1];
		return;
	}

	EditorAddMatchingSelections(editor, 42094 + (_multiSelectFlags & SCFIND_MATCHCASE ? 1 : 0) +
		(_multiSelectFlags & SCFIND_WHOLEWORD ? 2 : 0));
	if ([editor message:SCI_GETSELECTIONS] > selections)
		[editor message:SCI_DROPSELECTIONN wParam:selections - 1];
}

static NSData *DocumentBytes(ScintillaView *editor, sptr_t start, sptr_t end)
{
	const auto *bytes = reinterpret_cast<const char *>([editor message:SCI_GETCHARACTERPOINTER]);
	return [NSData dataWithBytes:bytes + start length:end - start];
}

- (IBAction)specialClipboard:(NSMenuItem *)sender
{
	static NSPasteboardType const binaryType = @"io.github.vt244.macpad-plus-plus.binary-text";
	ScintillaView *editor = self.editor;
	NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
	const BOOL readOnly = [editor message:SCI_GETREADONLY] != 0;
	if (sender.tag == 42048 || sender.tag == 42049)
	{
		if ([editor message:SCI_GETSELECTIONEMPTY] || (readOnly && sender.tag == 42049))
			return;
		const auto selections = [editor message:SCI_GETSELECTIONS];
		std::vector<std::pair<sptr_t, sptr_t>> ranges;
		for (sptr_t index = 0; index < selections; ++index)
			ranges.emplace_back([editor message:SCI_GETSELECTIONNSTART wParam:index],
				[editor message:SCI_GETSELECTIONNEND wParam:index]);
		if ([editor message:SCI_SELECTIONISRECTANGLE])
			std::sort(ranges.begin(), ranges.end());
		NSMutableData *bytes = [NSMutableData data];
		const auto ending = [editor message:SCI_GETEOLMODE];
		const char *separator = ending == SC_EOL_CRLF ? "\r\n" : ending == SC_EOL_CR ? "\r" : "\n";
		for (const auto &[start, end] : ranges)
		{
			[bytes appendData:DocumentBytes(editor, start, end)];
			if (selections > 1)
				[bytes appendBytes:separator length:strlen(separator)];
		}
		NSString *text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
		NSPasteboardItem *item = [NSPasteboardItem new];
		[item setData:bytes forType:binaryType];
		if (text && memchr(bytes.bytes, 0, bytes.length) == nullptr)
			[item setString:text forType:NSPasteboardTypeString];
		[pasteboard clearContents];
		if (![pasteboard writeObjects:@[item]])
			return;
		if (sender.tag == 42049)
			[editor setStringProperty:SCI_REPLACESEL parameter:0 value:@""];
		return;
	}
	if (readOnly)
		return;
	NSPasteboardType type = sender.tag == 42038 ? NSPasteboardTypeHTML :
		sender.tag == 42039 ? NSPasteboardTypeRTF : binaryType;
	NSData *bytes = [pasteboard dataForType:type];
	if (!bytes && type == binaryType)
		bytes = [[pasteboard stringForType:NSPasteboardTypeString] dataUsingEncoding:NSUTF8StringEncoding];
	if (!bytes)
	{
		NSBeep();
		return;
	}
	if (type != binaryType)
	{
		NSString *source = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] ?:
			[[NSString alloc] initWithData:bytes encoding:NSWindowsCP1252StringEncoding];
		bytes = [source dataUsingEncoding:NSUTF8StringEncoding];
		if (!bytes)
			return;
	}
	[editor message:SCI_BEGINUNDOACTION];
	[editor setStringProperty:SCI_REPLACESEL parameter:0 value:@""];
	[editor message:SCI_ADDTEXT wParam:bytes.length lParam:reinterpret_cast<sptr_t>(bytes.bytes ?: "")];
	[editor message:SCI_ENDUNDOACTION];
	[editor message:SCI_SCROLLCARET];
}

- (IBAction)commentSelection:(NSMenuItem *)sender
{
	NSArray<NSString *> *symbols = [EditorResources.shared commentSymbolsForLanguage:_languageIdentifier];
	EditorCommentSelection(self.editor, sender.tag, symbols[0], symbols[1], symbols[2]);
}

- (IBAction)completeText:(NSMenuItem *)sender
{
	if (!_completion)
		_completion = [EditorCompletion new];
	[_completion completeIn:self.editor language:_languageIdentifier directory:self.fileURL.URLByDeletingLastPathComponent command:sender.tag];
}

- (IBAction)reorderLines:(NSMenuItem *)sender { EditorReorderLines(self.editor, sender.tag); }
- (IBAction)operateOnBookmarkedLines:(NSMenuItem *)sender { EditorBookmarkLines(self.editor, sender.tag, Bookmark); }
- (IBAction)navigateChanges:(NSMenuItem *)sender { EditorNavigateChanges(self.editor, sender.tag); }

- (IBAction)toggleDocumentReadOnly:(id)sender
{
	if (_monitoring)
		return;
	[self setUserReadOnly:!self.userReadOnly];
	[(EditorDocumentController *)NSDocumentController.sharedDocumentController refreshDocumentTabs];
}

- (IBAction)toggleUDLPanel:(id)sender
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorDocument *owner = [controller windowOwnerForDocument:self];
	if (owner && owner != self)
	{
		[owner toggleUDLPanel:sender];
		return;
	}
	if (!_udlPane && _dockArea)
	{
		NSView *view = EditorCreateUDLPanel(^{
			[NSApp sendAction:@selector(updateUserLanguages:) to:NSApp.delegate from:nil];
		});
		EditorDockPlacement *placement = [[EditorDockPlacement alloc] initWithEdge:EditorDockRight];
		[placement restore:@{@"width": @500}];
		__weak EditorDocument *weakSelf = self;
		_udlPane = [_dockArea addPanel:view title:EditorUIString(@"User Defined Language") placement:placement dismiss:^{
			[weakSelf toggleUDLPanel:nil];
		}];
	}
	_udlPane.shown = !_udlPane.shown;
}

- (IBAction)beginOrEndSelection:(NSMenuItem *)sender
{
	ScintillaView *editor = self.editor;
	const auto caret = [editor message:SCI_GETCURRENTPOS];
	if (!_selectionStart)
	{
		_selectionStart = caret;
		return;
	}
	const auto anchor = std::min(*_selectionStart, [editor message:SCI_GETLENGTH]);
	_selectionStart.reset();
	if (sender.tag == 42089)
	{
		[editor message:SCI_CHANGESELECTIONMODE wParam:SC_SEL_RECTANGLE];
		[editor message:SCI_SETRECTANGULARSELECTIONANCHOR wParam:anchor];
		[editor message:SCI_SETRECTANGULARSELECTIONCARET wParam:caret];
	}
	else
	{
		[editor message:SCI_CHANGESELECTIONMODE wParam:SC_SEL_STREAM];
		[editor message:SCI_SETSEL wParam:anchor lParam:caret];
	}
}

- (IBAction)insertDateTime:(id)sender
{
	NSString *text;
	if ([sender tag] == 42086)
	{
		NSDateFormatter *format = [NSDateFormatter new];
		format.dateFormat = [EditorResources.shared setting:@"dateTimeFormat" fallback:@"yyyy-MM-dd HH:mm:ss"];
		text = [format stringFromDate:NSDate.date];
	}
	else
	{
		NSDateFormatterStyle style = [sender tag] == 42085 ? NSDateFormatterLongStyle : NSDateFormatterShortStyle;
		text = [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:style timeStyle:NSDateFormatterShortStyle];
	}
	[self.editor setStringProperty:SCI_REPLACESEL parameter:0 value:text ?: @""];
}

static void ReplaceBytes(ScintillaView *editor, sptr_t start, sptr_t end, NSData *data)
{
	[editor message:SCI_SETTARGETRANGE wParam:start lParam:end];
	[editor message:SCI_REPLACETARGET wParam:data.length lParam:reinterpret_cast<sptr_t>(data.bytes ?: "")];
}

static NSString *TransformCase(NSString *original, NSInteger mode)
{
	if (mode == 42071 || mode == 42072)
	{
		NSMutableString *result = [NSMutableString string];
		[original enumerateSubstringsInRange:NSMakeRange(0, original.length) options:NSStringEnumerationByComposedCharacterSequences
			usingBlock:^(NSString *part, NSRange range, NSRange enclosing, BOOL *stop) {
				BOOL upper = mode == 42072 ? arc4random_uniform(2) != 0 : [part isEqual:part.localizedLowercaseString];
				[result appendString:upper ? part.localizedUppercaseString : part.localizedLowercaseString];
			}];
		return result;
	}
	NSString *base = mode == 42067 || mode == 42069 ? original.localizedLowercaseString : original;
	NSMutableString *result = [base mutableCopy];
	const auto unit = mode <= 42068 ? NSStringEnumerationByWords : NSStringEnumerationBySentences;
	[base enumerateSubstringsInRange:NSMakeRange(0, base.length) options:unit | NSStringEnumerationReverse
		usingBlock:^(NSString *part, NSRange range, NSRange enclosing, BOOL *stop) {
			[part enumerateSubstringsInRange:NSMakeRange(0, part.length) options:NSStringEnumerationByComposedCharacterSequences
				usingBlock:^(NSString *letter, NSRange character, NSRange bounds, BOOL *done) {
					if ([letter.localizedLowercaseString isEqual:letter.localizedUppercaseString])
						return;
					[result replaceCharactersInRange:NSMakeRange(range.location + character.location, character.length)
						withString:letter.localizedUppercaseString];
					*done = YES;
				}];
		}];
	return result;
}

- (IBAction)transformSelectionCase:(NSMenuItem *)sender
{
	ScintillaView *editor = self.editor;
	if ([editor message:SCI_GETREADONLY] || [editor message:SCI_GETSELECTIONEMPTY])
		return;
	std::vector<std::pair<sptr_t, sptr_t>> ranges;
	for (sptr_t i = 0; i < [editor message:SCI_GETSELECTIONS]; ++i)
		ranges.emplace_back([editor message:SCI_GETSELECTIONNSTART wParam:i], [editor message:SCI_GETSELECTIONNEND wParam:i]);
	std::sort(ranges.begin(), ranges.end());
	[editor message:SCI_BEGINUNDOACTION];
	for (auto i = ranges.rbegin(); i != ranges.rend(); ++i)
	{
		const auto [start, end] = *i;
		NSString *before = [[NSString alloc] initWithData:DocumentBytes(editor, start, end) encoding:NSUTF8StringEncoding];
		if (before)
			ReplaceBytes(editor, start, end, [TransformCase(before, sender.tag) dataUsingEncoding:NSUTF8StringEncoding]);
	}
	[editor message:SCI_ENDUNDOACTION];
}

static void ConvertIndentation(ScintillaView *editor, NSInteger command)
{
	if ([editor message:SCI_GETREADONLY])
		return;
	const BOOL selected = ![editor message:SCI_GETSELECTIONEMPTY];
	const auto start = selected ? [editor message:SCI_GETSELECTIONSTART] : 0;
	const auto end = selected ? [editor message:SCI_GETSELECTIONEND] : [editor message:SCI_GETLENGTH];
	const auto width = std::max<sptr_t>(1, [editor message:SCI_GETTABWIDTH]);
	struct Edit { sptr_t start, end; std::string text; };
	std::vector<Edit> edits;
	for (auto cursor = start; cursor < end;)
	{
		const auto value = [editor message:SCI_GETCHARAT wParam:cursor];
		if (command == 42046 && value == '\t')
		{
			const auto column = [editor message:SCI_GETCOLUMN wParam:cursor];
			edits.push_back({cursor, cursor + 1, std::string(width - column % width, ' ')});
			++cursor;
		}
		else if (command != 42046 && value == ' ')
		{
			const auto first = cursor;
			while (cursor < end && [editor message:SCI_GETCHARAT wParam:cursor] == ' ')
				++cursor;
			const auto line = [editor message:SCI_LINEFROMPOSITION wParam:first];
			if (command == 42053 && first >= [editor message:SCI_GETLINEINDENTPOSITION wParam:line])
				continue;
			auto column = [editor message:SCI_GETCOLUMN wParam:first];
			auto count = cursor - first;
			std::string tabs;
			for (auto step = width - column % width; step <= count; step = width)
			{
				tabs += step == 1 ? ' ' : '\t';
				count -= step;
			}
			tabs.append(count, ' ');
			if (tabs.size() < cursor - first)
				edits.push_back({first, cursor, std::move(tabs)});
		}
		else
			++cursor;
	}
	[editor message:SCI_BEGINUNDOACTION];
	for (auto i = edits.rbegin(); i != edits.rend(); ++i)
		ReplaceBytes(editor, i->start, i->end, [NSData dataWithBytes:i->text.data() length:i->text.size()]);
	[editor message:SCI_ENDUNDOACTION];
}

static sptr_t DeleteWhitespace(ScintillaView *editor, NSString *pattern, sptr_t start, sptr_t end)
{
	sptr_t position = start;
	while (position < end)
	{
		[editor message:SCI_SETTARGETRANGE wParam:position lParam:end];
		position = SearchEditorTarget(editor, pattern, SCFIND_REGEXP);
		if (position < 0)
			break;
		const auto matchEnd = [editor message:SCI_GETTARGETEND];
		if (matchEnd <= position)
			break;
		if ([editor message:SCI_REPLACETARGET wParam:0 lParam:reinterpret_cast<sptr_t>("")] < 0)
			break;
		end -= matchEnd - position;
	}
	return end;
}

- (void)applyWhitespaceCommand:(NSInteger)command
{
	ScintillaView *editor = self.editor;
	const auto mode = [editor message:SCI_GETSELECTIONMODE];
	if ([editor message:SCI_GETREADONLY] || mode == SC_SEL_RECTANGLE || mode == SC_SEL_THIN)
		return;
	auto start = [editor message:SCI_GETSELECTIONSTART];
	auto end = [editor message:SCI_GETSELECTIONEND];
	const auto originalLength = [editor message:SCI_GETLENGTH];
	const auto firstVisible = [editor message:SCI_GETFIRSTVISIBLELINE];
	const BOOL selection = start != end;
	const BOOL reversed = [editor message:SCI_GETANCHOR] > [editor message:SCI_GETCURRENTPOS];
	if (!selection)
	{
		start = 0;
		end = originalLength;
	}
	if ((command == 42012 || command == 42013) && !selection)
		return;

	NSString *pattern = nil;
	switch (command)
	{
	case 42024: pattern = @"[\\t ]+$"; break;
	case 42042: pattern = @"^[\\t ]+"; break;
	case 42043: case 42045: pattern = @"^[\\t ]+|[\\t ]+$"; break;
	case 42055: pattern = @"^(?:\\r\\n|[\\r\\n])"; break;
	case 42056: pattern = @"^[\\t ]*(?:\\r\\n|[\\r\\n])"; break;
	}
	const BOOL trimming = command == 42024 || command == 42042 || command == 42043 || command == 42045;
	if (selection && (trimming || command == 42013))
	{
		auto first = [editor message:SCI_LINEFROMPOSITION wParam:start];
		auto last = [editor message:SCI_LINEFROMPOSITION wParam:end];
		if (command == 42013 && first == last)
			return;
		start = [editor message:SCI_POSITIONFROMLINE wParam:first];
		if (command == 42013 || end != [editor message:SCI_POSITIONFROMLINE wParam:last])
			end = MAX(end, [editor message:SCI_GETLINEENDPOSITION wParam:last]);
	}

	[editor message:SCI_BEGINUNDOACTION];
	if (pattern)
		end = DeleteWhitespace(editor, pattern, start, end);
	if ((command == 42055 || command == 42056) && end == [editor message:SCI_GETLENGTH] && end)
	{
		auto last = [editor message:SCI_GETLINECOUNT] - 1;
		const auto tailStart = [editor message:SCI_POSITIONFROMLINE wParam:MAX(0, last - 1)];
		NSString *tail = command == 42056 ? @"(?:\\r\\n|[\\r\\n])+[\\t ]*\\z|^[\\t ]+\\z" : @"(?:\\r\\n|[\\r\\n])+\\z";
		end = DeleteWhitespace(editor, tail, MAX(start, tailStart), end);
	}
	if (command == 42012 || command == 42013 || command == 42044 || command == 42045)
	{
		[editor message:SCI_SETTARGETRANGE wParam:start lParam:end];
		[editor message:command == 42012 ? SCI_LINESSPLIT : SCI_LINESJOIN];
		end = [editor message:SCI_GETTARGETEND];
	}
	[editor message:SCI_ENDUNDOACTION];
	if (selection && (originalLength != [editor message:SCI_GETLENGTH] || command == 42013))
		[editor message:SCI_SETSEL wParam:reversed ? end : start lParam:reversed ? start : end];
	[editor message:SCI_SETFIRSTVISIBLELINE wParam:firstVisible];
}

- (IBAction)runWhitespaceCommand:(id)sender
{
	const auto command = [sender tag];
	if (command == 42046 || command == 42053 || command == 42054)
	{
		ConvertIndentation(self.editor, command);
		return;
	}
	if (_recording && IsMacroMenuCommand(command))
		_macro.push_back({0, static_cast<uptr_t>(command), 0, std::nullopt});
	[self applyWhitespaceCommand:command];
}

- (IBAction)convertLineEndings:(id)sender
{
	const auto mode = [sender tag];
	[self.editor message:SCI_CONVERTEOLS wParam:mode];
	[self.editor message:SCI_SETEOLMODE wParam:mode];
	[self updateStatus];
}

- (IBAction)toggleInvisibles:(id)sender
{
	const bool show = [self.editor message:SCI_GETVIEWWS] == SCWS_INVISIBLE;
	[self.editor message:SCI_SETVIEWWS wParam:show ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE];
	[self.editor message:SCI_SETVIEWEOL wParam:show];
}

- (IBAction)toggleIndentGuides:(id)sender
{
	const bool show = [self.editor message:SCI_GETINDENTATIONGUIDES] == SC_IV_NONE;
	[self.editor message:SCI_SETINDENTATIONGUIDES wParam:show ? SC_IV_LOOKBOTH : SC_IV_NONE];
}

- (IBAction)toggleWrap:(id)sender
{
	[self.editor message:SCI_SETWRAPMODE wParam:[self.editor message:SCI_GETWRAPMODE] ? SC_WRAP_NONE : SC_WRAP_WORD];
}

- (IBAction)toggleLineNumbers:(id)sender
{
	[self.editor message:SCI_SETMARGINWIDTHN wParam:0 lParam:[self.editor message:SCI_GETMARGINWIDTHN wParam:0] ? 0 : 32];
}

- (IBAction)toggleAlwaysOnTop:(id)sender
{
	NSWindow *window = self.windowForSheet;
	window.level = window.level == NSFloatingWindowLevel ? NSNormalWindowLevel : NSFloatingWindowLevel;
}

- (IBAction)toggleEditorFullScreen:(id)sender
{
	[self.windowForSheet toggleFullScreen:sender];
}

- (IBAction)focusAnotherView:(id)sender
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorDocument *other = [controller selectedTabInOtherView:YES];
	EditorDocument *primary = [controller selectedTabInOtherView:NO];
	if (other)
		[(self == other ? primary : other) focusEditor];
	else if (_clone)
	{
		if (self.editor == _clone)
			[self focusPrimaryEditor];
		else
			[self focusClonedEditor];
	}
}

- (IBAction)toggleSymbolDisplay:(NSMenuItem *)sender
{
	ScintillaView *editor = self.editor;
	if (sender.tag == 44025)
		[editor message:SCI_SETVIEWWS wParam:[editor message:SCI_GETVIEWWS] ? SCWS_INVISIBLE : SCWS_VISIBLEALWAYS];
	else if (sender.tag == 44026)
		[editor message:SCI_SETVIEWEOL wParam:![editor message:SCI_GETVIEWEOL]];
	else
		[editor message:SCI_SETWRAPVISUALFLAGS wParam:[editor message:SCI_GETWRAPVISUALFLAGS] ? SC_WRAPVISUALFLAG_NONE : SC_WRAPVISUALFLAG_END];
}

- (IBAction)setTextDirection:(NSMenuItem *)sender
{
	[self.editor message:SCI_SETBIDIRECTIONAL wParam:sender.tag];
}

- (IBAction)findText:(id)sender
{
	[self showSearchMode:0];
}

- (IBAction)replaceText:(id)sender
{
	[self showSearchMode:1];
}

- (IBAction)findInFiles:(id)sender
{
	[self showSearchMode:2];
}

- (void)findInDirectory:(NSURL *)directory
{
	[self showSearchMode:2];
	_searchFolder.stringValue = directory.path;
}

- (IBAction)findInProjects:(id)sender
{
	[self showSearchMode:4];
}

- (IBAction)incrementalSearch:(id)sender
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	EditorDocument *owner = [controller windowOwnerForDocument:self];
	owner->_incrementalDocument = self;
	owner->_incremental.hidden = NO;
	owner->_incrementalHeight.constant = 29;
	[owner->_incremental beginInEditor:self.editor];
}

- (void)dismissIncrementalSearch
{
	[_incremental end];
	_incremental.hidden = YES;
	_incrementalHeight.constant = 0;
	[_incrementalDocument focusEditor];
	_incrementalDocument = nil;
}

- (IBAction)markText:(id)sender
{
	[self showSearchMode:3];
}

static void PlaceSearchControl(NSView *form, NSView *control, NSRect frame)
{
	control.frame = frame;
	[form addSubview:control];
}

static void LoadSearchHistory(NSComboBox *control, NSString *key)
{
	NSString *text = control.stringValue;
	[control removeAllItems];
	for (id entry in [EditorResources.shared setting:key fallback:@[]])
		if ([entry isKindOfClass:NSString.class])
			[control addItemWithObjectValue:entry];
	control.stringValue = text;
}

static void RememberSearchHistory(NSString *value, NSString *key)
{
	if (!value.length)
		return;
	EditorResources *resources = EditorResources.shared;
	NSArray *previous = [resources setting:key fallback:@[]];
	if ([previous.firstObject isEqual:value])
		return;
	NSMutableOrderedSet *history = [NSMutableOrderedSet orderedSetWithArray:previous];
	[history removeObject:value];
	[history insertObject:value atIndex:0];
	if (history.count > 24)
		[history removeObjectsInRange:NSMakeRange(24, history.count - 24)];
	[resources setSetting:history.array forName:key];
}

- (void)makeSearchPanel
{
	_searchPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 618, 304)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
		backing:NSBackingStoreBuffered defer:NO];
	_searchPanel.releasedWhenClosed = NO;
	_searchPanel.restorable = NO;
	_searchPanel.hidesOnDeactivate = YES;
	_searchPanel.appearance = self.chrome.appearance;
	NSView *form = _searchPanel.contentView;
	EditorResources *resources = EditorResources.shared;
	auto label = ^NSString *(NSString *key, NSString *fallback) { return [resources findLabel:key fallback:fallback]; };
	_searchMode = [NSSegmentedControl segmentedControlWithLabels:@[label(@"titleFind", @"Find"), label(@"titleReplace", @"Replace"),
		label(@"titleFindInFiles", @"Find in Files"), label(@"titleMark", @"Mark"), label(@"titleFindInProjects", @"Find in Projects")]
		trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(updateSearchMode:)];
	PlaceSearchControl(form, _searchMode, NSMakeRect(12, 269, 594, 26));

	_searchInput = [[NSComboBox alloc] initWithFrame:NSZeroRect];
	_searchInput.accessibilityIdentifier = @"find-text";
	_replaceInput = [[NSComboBox alloc] initWithFrame:NSZeroRect];
	_searchInput.numberOfVisibleItems = _replaceInput.numberOfVisibleItems = 8;
	LoadSearchHistory(_searchInput, @"findHistory");
	LoadSearchHistory(_replaceInput, @"replaceHistory");
	_searchInput.stringValue = _query ?: [[resources setting:@"findHistory" fallback:@[]] firstObject] ?: @"";
	_replaceInput.stringValue = [[resources setting:@"replaceHistory" fallback:@[]] firstObject] ?: @"";
	NSArray<NSString *> *titles = @[label(@"1620", @"Find what:"), label(@"1611", @"Replace with:")];
	for (NSUInteger i = 0; i < titles.count; ++i)
	{
		CGFloat y = 236 - 31 * i;
		NSTextField *fieldLabel = [NSTextField labelWithString:titles[i]];
		if (i == 1)
			_replaceLabel = fieldLabel;
		PlaceSearchControl(form, fieldLabel, NSMakeRect(14, y + 2, 126, 21));
		NSTextField *input = i == 0 ? _searchInput : _replaceInput;
		[input setAccessibilityLabel:titles[i]];
		PlaceSearchControl(form, input, NSMakeRect(143, y, 275, 24));
	}

	NSString *folder = self.fileURL.URLByDeletingLastPathComponent.path ?: NSHomeDirectory();
	_searchFolder = [NSTextField textFieldWithString:folder];
	_searchFilters = [NSTextField textFieldWithString:@"*.*"];
	NSTextField *directoryLabel = [NSTextField labelWithString:label(@"1655", @"Directory:")];
	NSTextField *filtersLabel = [NSTextField labelWithString:label(@"1654", @"Filters:")];
	[_searchFolder setAccessibilityLabel:directoryLabel.stringValue];
	[_searchFilters setAccessibilityLabel:filtersLabel.stringValue];
	NSButton *browse = [NSButton buttonWithTitle:@"…" target:self action:@selector(browseSearchDirectory:)];
	[browse setAccessibilityLabel:@"Select Search Directory"];
	PlaceSearchControl(form, filtersLabel, NSMakeRect(14, 173, 126, 21));
	PlaceSearchControl(form, _searchFilters, NSMakeRect(143, 171, 275, 24));
	PlaceSearchControl(form, directoryLabel, NSMakeRect(14, 142, 126, 21));
	PlaceSearchControl(form, _searchFolder, NSMakeRect(143, 140, 243, 24));
	PlaceSearchControl(form, browse, NSMakeRect(385, 137, 35, 28));
	_recursive = [NSButton checkboxWithTitle:label(@"1658", @"In all sub-folders") target:nil action:nil];
	_includeHidden = [NSButton checkboxWithTitle:label(@"1659", @"In hidden folders") target:nil action:nil];
	_recursive.state = [[EditorResources.shared setting:@"findRecursive" fallback:@YES] boolValue];
	PlaceSearchControl(form, _recursive, NSMakeRect(14, 62, 220, 21));
	PlaceSearchControl(form, _includeHidden, NSMakeRect(14, 38, 220, 21));
	_fileSearchControls = @[filtersLabel, _searchFilters];
	_directoryControls = @[directoryLabel, _searchFolder, browse, _recursive, _includeHidden];
	NSMutableArray *projectControls = [NSMutableArray array];
	for (NSUInteger index = 0; index < 3; ++index)
	{
		NSString *panelName = [NSString stringWithFormat:@"Project Panel %lu", index + 1];
		NSButton *checkbox = [NSButton checkboxWithTitle:label([@(1662 + index) stringValue], panelName) target:nil action:nil];
		checkbox.state = NSControlStateValueOn;
		PlaceSearchControl(form, checkbox, NSMakeRect(14 + index * 142, 138, 140, 21));
		[projectControls addObject:checkbox];
	}
	_projectSearchControls = [projectControls copy];
	_matchCase = [NSButton checkboxWithTitle:label(@"1604", @"Match case") target:nil action:nil];
	_wholeWord = [NSButton checkboxWithTitle:label(@"1603", @"Match whole word only") target:nil action:nil];
	_wrapSearch = [NSButton checkboxWithTitle:label(@"1606", @"Wrap around") target:nil action:nil];
	_regularExpression = [NSButton checkboxWithTitle:label(@"1605", @"Regular expression") target:self action:@selector(toggleRegex:)];
	_extendedSearch = [NSButton checkboxWithTitle:label(@"1626", @"Extended (\\n, \\t, …)") target:self action:@selector(toggleExtended:)];
	_inSelection = [NSButton checkboxWithTitle:label(@"1632", @"In selection") target:self action:@selector(captureSearchSelection:)];
	_matchNewline = [NSButton checkboxWithTitle:label(@"1703", @". matches newline") target:nil action:nil];
	_matchCase.state = _query.length ? (_searchFlags & SCFIND_MATCHCASE) != 0 :
		[[EditorResources.shared setting:@"findMatchCase" fallback:@NO] boolValue];
	_wholeWord.state = _query.length ? (_searchFlags & SCFIND_WHOLEWORD) != 0 :
		[[EditorResources.shared setting:@"findWholeWord" fallback:@NO] boolValue];
	_wrapSearch.state = [[EditorResources.shared setting:@"findWrap" fallback:@YES] boolValue];
	_regularExpression.state = (_searchFlags & SCFIND_REGEXP) != 0;
	_matchNewline.state = (_searchFlags & SCFIND_REGEXP_DOTMATCHESNL) != 0;
	NSArray<NSButton *> *options = @[_wholeWord, _matchCase, _wrapSearch];
	for (NSUInteger i = 0; i < options.count; ++i)
		PlaceSearchControl(form, options[i], NSMakeRect(14, 110 - 24 * i, 224, 21));
	PlaceSearchControl(form, _regularExpression, NSMakeRect(240, 110, 180, 21));
	PlaceSearchControl(form, _matchNewline, NSMakeRect(240, 86, 180, 21));
	PlaceSearchControl(form, _extendedSearch, NSMakeRect(240, 62, 185, 21));
	PlaceSearchControl(form, _inSelection, NSMakeRect(14, 143, 220, 21));
	_bookmarkMatches = [NSButton checkboxWithTitle:label(@"1616", @"Bookmark line") target:nil action:nil];
	_purgeMarks = [NSButton checkboxWithTitle:label(@"1618", @"Purge for each search") target:nil action:nil];
	_purgeMarks.state = NSControlStateValueOn;
	PlaceSearchControl(form, _bookmarkMatches, NSMakeRect(14, 62, 220, 21));
	PlaceSearchControl(form, _purgeMarks, NSMakeRect(14, 38, 220, 21));

	NSArray<NSString *> *actions = @[label(@"1", @"Find Next"), [resources label:@"43010" fallback:@"Find Previous"],
		label(@"1608", @"Replace"), label(@"1609", @"Replace All"), label(@"2", @"Close"), label(@"1656", @"Find All"),
		label(@"1660", @"Replace in Files"), label(@"1615", @"Mark All"), label(@"1633", @"Clear All Marks"),
		label(@"1725", @"Copy Marked Text"), label(@"1614", @"Count")];
	NSMutableArray *markControls = [NSMutableArray arrayWithArray:@[_bookmarkMatches, _purgeMarks]];
	for (NSUInteger i = 0; i < actions.count; ++i)
	{
		NSButton *button = [NSButton buttonWithTitle:actions[i] target:self action:@selector(performSearch:)];
		button.tag = i;
		if (i == 0)
			_findForward = button;
		if (i == 1)
			_findBackward = button;
		if (i == 2)
			_replaceButton = button;
		if (i == 3)
			_replaceAllButton = button;
		if (i == 4)
			button.keyEquivalent = @"\033";
		if (i == 5)
			_findAll = button;
		if (i == 6)
			_replaceFiles = button;
		if (i >= 7 && i <= 9)
			[markControls addObject:button];
		if (i == 10)
			_countMatches = button;
		NSInteger row = i <= 4 ? i : i <= 6 ? i - 5 : i <= 9 ? i - 7 : 2;
		PlaceSearchControl(form, button, NSMakeRect(432, 232 - 30 * row, 172, 29));
	}
	_markControls = [markControls copy];
	_findInDocument = [NSButton buttonWithTitle:label(@"1641", @"Find All in Current Document") target:self action:@selector(performSearch:)];
	_findInOpenDocuments = [NSButton buttonWithTitle:label(@"1636", @"Find All in All Opened Documents") target:self action:@selector(performSearch:)];
	_replaceInOpenDocuments = [NSButton buttonWithTitle:label(@"1635", @"Replace All in All Opened Documents") target:self action:@selector(performSearch:)];
	_findInDocument.tag = 11;
	_findInOpenDocuments.tag = 12;
	_replaceInOpenDocuments.tag = 13;
	PlaceSearchControl(form, _findInDocument, NSMakeRect(157, 42, 225, 28));
	PlaceSearchControl(form, _findInOpenDocuments, NSMakeRect(386, 42, 218, 28));
	PlaceSearchControl(form, _replaceInOpenDocuments, NSMakeRect(354, 42, 250, 28));
	_searchStatus = [NSTextField labelWithString:@""];
	PlaceSearchControl(form, _searchStatus, NSMakeRect(14, 12, 408, 22));
	[_searchPanel center];
}

- (void)showSearchMode:(NSInteger)mode
{
	if (!_searchPanel)
		[self makeSearchPanel];
	_searchMode.selectedSegment = mode;
	LoadSearchHistory(_searchInput, @"findHistory");
	LoadSearchHistory(_replaceInput, @"replaceHistory");
	EditorResources *resources = EditorResources.shared;
	NSFont *font = [[resources setting:@"monospacedFontFindDlg" fallback:@NO] boolValue] ?
		[NSFont monospacedSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular] :
		[NSFont systemFontOfSize:NSFont.systemFontSize];
	for (NSTextField *input in @[_searchInput, _replaceInput, _searchFilters, _searchFolder])
		input.font = font;
	ScintillaView *editor = self.editor;
	const auto start = [editor message:SCI_GETSELECTIONSTART];
	const auto end = [editor message:SCI_GETSELECTIONEND];
	const auto selectionLength = [editor message:SCI_COUNTCHARACTERS wParam:start lParam:end];
	const BOOL canSearchSelection = start < end && [editor message:SCI_GETSELECTIONS] == 1 &&
		[editor message:SCI_GETSELECTIONMODE] != SC_SEL_RECTANGLE && [editor message:SCI_GETSELECTIONMODE] != SC_SEL_THIN;
	const NSInteger threshold = [[resources setting:@"inSelectionAutocheckThreshold" fallback:@1024] integerValue];
	_inSelection.enabled = canSearchSelection;
	if (threshold > 0 || !canSearchSelection)
		_inSelection.state = canSearchSelection && selectionLength >= threshold;
	[self captureSearchSelection:nil];
	if ([[resources setting:@"fillFindSelection" fallback:@YES] boolValue])
	{
		const NSInteger limit = [[resources setting:@"fillFindWhatThreshold" fallback:@1024] integerValue];
		NSString *selection = canSearchSelection && selectionLength <= limit ? editor.selectedString : nil;
		if (selectionLength == 0 && [[resources setting:@"fillFindWord" fallback:@NO] boolValue])
		{
			const auto [tokenStart, tokenEnd] = TokenRange(editor);
			if (tokenEnd > tokenStart && [editor message:SCI_COUNTCHARACTERS wParam:tokenStart lParam:tokenEnd] <= limit)
				selection = [[NSString alloc] initWithData:DocumentBytes(editor, tokenStart, tokenEnd) encoding:NSUTF8StringEncoding];
		}
		if (selection.length && [selection rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound)
			_searchInput.stringValue = selection;
	}
	[self updateSearchMode:nil];
	NSWindow *documentWindow = self.windowForSheet;
	[documentWindow addChildWindow:_searchPanel ordered:NSWindowAbove];
	[_searchPanel makeKeyAndOrderFront:nil];
	[_searchInput selectText:nil];
}

- (void)close
{
	[(EditorDocumentController *)NSDocumentController.sharedDocumentController prepareToCloseDocument:self];
	_documentListPane.shown = _resultsPane.shown = NO;
	_folderPane.shown = NO;
	[self displayProjectPanels:nil];
	[self displayFunctionsOf:nil visible:NO];
	[self displayDocumentMap:nil visible:NO];
	[self displayInsertPanels:nil clipboard:nil encoding:0];
	[_incremental end];
	[self closeClonedView];
	[_fileSearch cancel];
	[_searchPanel close];
	_editor.delegate = nil;
	[super close];
}

- (void)updateSearchMode:(id)sender
{
	const BOOL replace = _searchMode.selectedSegment == 1;
	const BOOL fileSearch = _searchMode.selectedSegment == 2;
	const BOOL mark = _searchMode.selectedSegment == 3;
	const BOOL projectSearch = _searchMode.selectedSegment == 4;
	const BOOL multiFile = fileSearch || projectSearch;
	_searchPanel.title = [_searchMode labelForSegment:_searchMode.selectedSegment];
	_replaceLabel.hidden = _replaceInput.hidden = !replace && !multiFile;
	_replaceButton.hidden = _replaceAllButton.hidden = !replace;
	_wrapSearch.hidden = _findForward.hidden = _findBackward.hidden = multiFile || mark;
	_findAll.hidden = !multiFile;
	_replaceFiles.hidden = !multiFile;
	_replaceFiles.title = projectSearch ? [EditorResources.shared findLabel:@"1665" fallback:@"Replace in Projects"] :
		[EditorResources.shared findLabel:@"1660" fallback:@"Replace in Files"];
	_countMatches.hidden = _searchMode.selectedSegment != 0;
	_replaceFiles.enabled = _findInDocument.enabled = _findInOpenDocuments.enabled = _replaceInOpenDocuments.enabled = !_fileSearch;
	_findInDocument.hidden = _findInOpenDocuments.hidden = _searchMode.selectedSegment != 0;
	_replaceInOpenDocuments.hidden = !replace;
	_inSelection.hidden = multiFile;
	_findForward.keyEquivalent = (multiFile || mark) ? @"" : @"\r";
	_findAll.keyEquivalent = multiFile ? @"\r" : @"";
	for (NSView *control in _fileSearchControls)
		control.hidden = !multiFile;
	for (NSView *control in _directoryControls)
		control.hidden = !fileSearch;
	for (NSView *control in _projectSearchControls)
		control.hidden = !projectSearch;
	for (NSView *control in _markControls)
		control.hidden = !mark;
	((NSButton *)_markControls[2]).keyEquivalent = mark ? @"\r" : @"";
	_wholeWord.enabled = _regularExpression.state != NSControlStateValueOn;
	_matchNewline.enabled = !_wholeWord.enabled;
}

- (void)toggleRegex:(id)sender
{
	if (_regularExpression.state == NSControlStateValueOn)
		_extendedSearch.state = NSControlStateValueOff;
	[self updateSearchMode:nil];
}

- (void)toggleExtended:(id)sender
{
	if (_extendedSearch.state == NSControlStateValueOn)
		_regularExpression.state = NSControlStateValueOff;
	[self updateSearchMode:nil];
}

- (void)captureSearchSelection:(id)sender
{
	auto start = [self.editor message:SCI_GETSELECTIONSTART];
	auto end = [self.editor message:SCI_GETSELECTIONEND];
	if (end == start && _inSelection.state == NSControlStateValueOn)
	{
		_searchStatus.stringValue = [EditorResources.shared label:@"search-selectRange" fallback:@"Select a range of text first."];
		_inSelection.state = NSControlStateValueOff;
	}
	_searchSelection = NSMakeRange(start, end - start);
}

- (void)setSearchStatus:(NSString *)message style:(NSString *)style
{
	_searchStatus.textColor = [EditorResources.shared widgetColor:style background:NO] ?: NSColor.labelColor;
	_searchStatus.stringValue = message;
}

- (void)showReplacementCount:(NSUInteger)count
{
	NSString *message = [EditorResources.shared label:count == 1 ? @"find-status-replaceall-1-replaced" : @"find-status-replaceall-nb-replaced"
		fallback:@"$INT_REPLACE$ replacements"];
	[self setSearchStatus:[message stringByReplacingOccurrencesOfString:@"$INT_REPLACE$" withString:@(count).stringValue]
		style:@"Find status: Message"];
}

- (NSRange)searchScope
{
	const auto length = static_cast<NSUInteger>([self.editor message:SCI_GETLENGTH]);
	if (_inSelection.state != NSControlStateValueOn || _inSelection.hidden)
		return NSMakeRange(0, length);
	const auto start = MIN(length, _searchSelection.location);
	return NSMakeRange(start, MIN(length - start, _searchSelection.length));
}

- (void)browseSearchDirectory:(id)sender
{
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.canChooseDirectories = YES;
	panel.canChooseFiles = NO;
	panel.directoryURL = [NSURL fileURLWithPath:_searchFolder.stringValue.stringByExpandingTildeInPath isDirectory:YES];
	[panel beginSheetModalForWindow:_searchPanel completionHandler:^(NSModalResponse response) {
		if (response == NSModalResponseOK)
			self->_searchFolder.stringValue = panel.URL.path;
	}];
}

- (void)startFileSearchWithQuery:(NSString *)query flags:(NSUInteger)flags replacement:(NSString *)replacement
{
	NSString *path = _searchFolder.stringValue.stringByExpandingTildeInPath;
	if (!path.isAbsolutePath)
	{
		_searchStatus.stringValue = [EditorResources.shared label:@"search-absoluteDirectory" fallback:@"Choose an absolute directory path."];
		return;
	}
	NSURL *folder = [NSURL fileURLWithPath:path isDirectory:YES];
	NSString *filters = _searchFilters.stringValue;
	BOOL recursive = _recursive.state == NSControlStateValueOn;
	BOOL hidden = _includeHidden.state == NSControlStateValueOn;
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	NSMutableDictionary<NSURL *, NSData *> *snapshots = [NSMutableDictionary dictionary];
	for (EditorDocument *document in controller.documents)
		if (document.editor && document.fileURL &&
			(replacement || ![[EditorResources.shared setting:@"findFilesOnDisk" fallback:@NO] boolValue]))
			snapshots[document.fileURL.URLByStandardizingPath] = [document editorUTF8];

	[self startSearchReplacing:replacement != nil mayWriteToDisk:YES worker:^EditorSearchReport *(NSProgress *progress, NSError **error) {
		return SearchDirectory(folder, query, filters, flags, recursive, hidden, snapshots, replacement, progress, error);
	}];
}

- (void)startDocumentSearch:(NSString *)query flags:(NSUInteger)flags replacement:(NSString *)replacement
	all:(BOOL)all projects:(BOOL)projects
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	NSMutableArray<EditorSearchSource *> *sources = [NSMutableArray array];
	if (projects)
	{
		NSMutableOrderedSet<NSURL *> *paths = [NSMutableOrderedSet orderedSet];
		for (NSUInteger index = 0; index < controller.projectWorkspaces.count; ++index)
			if (_projectSearchControls[index].state == NSControlStateValueOn)
				[paths addObjectsFromArray:controller.projectWorkspaces[index].files];
		for (NSURL *url in paths)
		{
			EditorDocument *document = (EditorDocument *)[controller documentForURL:url];
			[sources addObject:[[EditorSearchSource alloc] initWithName:url.path url:url document:document utf8:[document editorUTF8]
				range:NSMakeRange(NSNotFound, 0)]];
		}
		if (!paths.count)
		{
			_searchStatus.stringValue = [EditorResources.shared label:@"search-noProjectFiles" fallback:@"The selected project panels contain no files."];
			return;
		}
	}
	else
		for (EditorDocument *document in all ? controller.tabDocuments : @[self])
			[sources addObject:[[EditorSearchSource alloc] initWithName:document.fileURL.path ?: document.displayName
				url:document.fileURL document:document utf8:[document editorUTF8]
				range:all ? NSMakeRange(NSNotFound, 0) : self.searchScope]];
	NSString *filters = projects ? _searchFilters.stringValue : nil;
	[self startSearchReplacing:replacement != nil mayWriteToDisk:projects worker:^EditorSearchReport *(NSProgress *progress, NSError **error) {
		return SearchSources(sources, query, filters, flags, replacement, progress, error);
	}];
}

- (void)refineSearchReports:(NSArray<EditorSearchReport *> *)reports
{
	if (_fileSearch)
		return;
	NSAlert *alert = [[NSAlert alloc] init];
	auto label = ^NSString *(NSString *key, NSString *fallback) {
		return [EditorResources.shared label:[@"FindInFinder:" stringByAppendingString:key] fallback:fallback];
	};
	alert.messageText = label(@"title", @"Find in these search results");
	[alert addButtonWithTitle:label(@"1", @"Find All")];
	[alert addButtonWithTitle:EditorUIString(@"Cancel")];
	NSTextField *queryField = [NSTextField textFieldWithString:@""];
	queryField.placeholderString = label(@"1711", @"Find what");
	NSButton *linesOnly = [NSButton checkboxWithTitle:label(@"1713", @"Search only in found lines") target:nil action:nil];
	NSButton *matchCase = [NSButton checkboxWithTitle:label(@"1715", @"Match case") target:nil action:nil];
	NSButton *regex = [NSButton checkboxWithTitle:label(@"1719", @"Regular expression") target:nil action:nil];
	NSView *controls = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 330, 92)];
	PlaceSearchControl(controls, queryField, NSMakeRect(0, 64, 330, 24));
	PlaceSearchControl(controls, linesOnly, NSMakeRect(0, 40, 330, 21));
	PlaceSearchControl(controls, matchCase, NSMakeRect(0, 18, 140, 21));
	PlaceSearchControl(controls, regex, NSMakeRect(142, 18, 185, 21));
	alert.accessoryView = controls;
	alert.window.initialFirstResponder = queryField;
	if ([alert runModal] != NSAlertFirstButtonReturn || !queryField.stringValue.length)
		return;

	NSMutableDictionary<id<NSCopying>, EditorSearchSource *> *byFile = [NSMutableDictionary dictionary];
	NSMutableDictionary<id<NSCopying>, NSMutableIndexSet *> *matchedLines = [NSMutableDictionary dictionary];
	NSMutableArray<EditorSearchSource *> *sources = [NSMutableArray array];
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	for (EditorSearchReport *report in reports)
		for (EditorSearchFile *file in report.files)
		{
			EditorDocument *document = file.document;
			if (document && ![controller.documents containsObject:document])
				document = nil;
			if (!document && file.url)
				document = (EditorDocument *)[controller documentForURL:file.url];
			if (!document && !file.url)
				continue;
			id<NSCopying> key = file.url.URLByStandardizingPath ?: [NSValue valueWithNonretainedObject:document];
			EditorSearchSource *source = byFile[key];
			if (!source)
			{
				source = [[EditorSearchSource alloc] initWithName:file.name url:file.url document:document
					utf8:[document editorUTF8] range:NSMakeRange(NSNotFound, 0)];
				byFile[key] = source;
				matchedLines[key] = [NSMutableIndexSet indexSet];
				[sources addObject:source];
			}
			if (linesOnly.state == NSControlStateValueOn)
				for (EditorSearchMatch *match in file.matches)
					[matchedLines[key] addIndex:match.line - 1];
		}
	if (linesOnly.state == NSControlStateValueOn)
		for (id<NSCopying> key in byFile)
			byFile[key].lines = matchedLines[key];
	NSString *query = queryField.stringValue;
	NSUInteger flags = matchCase.state == NSControlStateValueOn ? SCFIND_MATCHCASE : 0;
	if (regex.state == NSControlStateValueOn)
		flags |= SCFIND_REGEXP | SCFIND_REGEXP_EMPTYMATCH_ALL | SCFIND_REGEXP_SKIPCRLFASONE;
	[self startSearchReplacing:NO mayWriteToDisk:NO worker:^EditorSearchReport *(NSProgress *progress, NSError **error) {
		return SearchSources(sources, query, nil, flags, nil, progress, error);
	}];
}

- (void)startSearchReplacing:(BOOL)replacing mayWriteToDisk:(BOOL)mayWriteToDisk
	worker:(EditorSearchReport *(^)(NSProgress *, NSError **))worker
{
	if (_fileSearch)
		return;
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	NSProgress *progress = [NSProgress progressWithTotalUnitCount:-1];
	progress.cancellable = YES;
	_fileSearch = progress;
	_findAll.title = @"Cancel Search";
	[self updateSearchMode:nil];
	_searchStatus.stringValue = [EditorResources.shared label:@"search-searching" fallback:@"Searching…"];
	__weak EditorDocument *weakSelf = self;
	void (^finish)(EditorSearchReport *, NSError *) = ^(EditorSearchReport *report, NSError *error) {
		EditorDocument *document = weakSelf;
		if (!document || document->_fileSearch != progress)
			return;
		document->_fileSearch = nil;
		document->_findAll.title = [EditorResources.shared findLabel:@"1656" fallback:@"Find All"];
		[document updateSearchMode:nil];
		if (progress.cancelled)
			document->_searchStatus.stringValue = [EditorResources.shared label:@"search-cancelled" fallback:@"Search cancelled."];
		else if (!report)
		{
			NSString *message = error.localizedDescription ?: @"The search could not finish.";
			if (document->_searchPanel.visible)
				document->_searchStatus.stringValue = message;
			else if (error)
				[NSApp presentError:error];
		}
		else
		{
			NSString *message = [EditorResources.shared label:@"find-result-title-info"
				fallback:@"$INT_REPLACE1$ hits in $INT_REPLACE2$ files"];
			message = [message stringByReplacingOccurrencesOfString:@"$INT_REPLACE1$" withString:@(report.hits).stringValue];
			message = [message stringByReplacingOccurrencesOfString:@"$INT_REPLACE2$" withString:@(report.files.count).stringValue];
			message = [message stringByReplacingOccurrencesOfString:@"$INT_REPLACE3$" withString:@(report.searchedFiles).stringValue];
			[document setSearchStatus:message style:@"Find status: Message"];
			[controller showSearchReport:report];
			if (replacing && report.hits)
				[document confirmFileReplacement:report mayWriteToDisk:mayWriteToDisk];
			else if (!replacing)
				[document->_searchPanel orderOut:nil];
		}
	};
	if (_playingMacro)
	{
		NSError *error = nil;
		EditorSearchReport *report = worker(progress, &error);
		finish(report, error);
	}
	else
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSError *error = nil;
			EditorSearchReport *report = worker(progress, &error);
			dispatch_async(dispatch_get_main_queue(), ^{ finish(report, error); });
		});
}

- (void)confirmFileReplacement:(EditorSearchReport *)report mayWriteToDisk:(BOOL)mayWriteToDisk
{
	NSAlert *confirmation = [[NSAlert alloc] init];
	confirmation.messageText = [NSString localizedStringWithFormat:@"Replace %lu matches in %lu files?", report.hits, report.files.count];
	confirmation.informativeText = mayWriteToDisk ? @"Open tabs receive undoable edits. Closed files are updated on disk." :
		@"The replacement is undoable in each open document.";
	[confirmation addButtonWithTitle:EditorUIString(@"Cancel")];
	NSButton *replace = [confirmation addButtonWithTitle:EditorUIString(@"Replace All")];
	replace.hasDestructiveAction = YES;
	if ([confirmation runModal] == NSAlertSecondButtonReturn)
		[self applyFileReplacement:report];
	[report discardReplacementSnapshots];
}

- (void)applyFileReplacement:(EditorSearchReport *)report
{
	if (((EditorDocumentController *)NSDocumentController.sharedDocumentController).launchOptions.savingForbidden)
	{
		NSBeep();
		return;
	}
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	NSMutableArray<NSString *> *failures = [NSMutableArray array];
	NSUInteger replaced = 0;
	for (EditorSearchFile *file in report.files)
	{
		EditorDocument *document = file.document;
		if (document && ![controller.documents containsObject:document])
			document = nil;
		if (!document && file.url)
			document = (EditorDocument *)[controller documentForURL:file.url];
		if (document)
		{
			ScintillaView *editor = document.editor;
			if (!editor || [editor message:SCI_GETREADONLY] || ![[document editorUTF8] isEqualToData:file.originalUTF8])
			{
				[failures addObject:[NSString stringWithFormat:@"%@ — the open buffer changed or is read-only.", file.name]];
				continue;
			}
			[editor message:SCI_BEGINUNDOACTION];
			for (EditorSearchMatch *match in file.matches.reverseObjectEnumerator)
			{
				NSData *replacement = match.replacementBytes;
				[editor message:SCI_SETTARGETRANGE wParam:match.byteRange.location lParam:NSMaxRange(match.byteRange)];
				[editor message:SCI_REPLACETARGET wParam:replacement.length lParam:reinterpret_cast<sptr_t>(replacement.bytes ?: "")];
			}
			[editor message:SCI_ENDUNDOACTION];
		}
		else
		{
			NSError *error = nil;
			if (![file replaceOnDisk:&error])
			{
				[failures addObject:[NSString stringWithFormat:@"%@ — %@", file.name, error.localizedDescription ?: @"Could not write the file."]];
				continue;
			}
		}
		replaced += file.matches.count;
	}
	[self showReplacementCount:replaced];
	if (failures.count)
	{
		NSAlert *alert = [[NSAlert alloc] init];
		alert.messageText = [NSString localizedStringWithFormat:@"Could not update %lu files", failures.count];
		alert.informativeText = [failures componentsJoinedByString:@"\n"];
		[alert beginSheetModalForWindow:self.windowForSheet completionHandler:nil];
	}
}

- (void)recordSearchAction:(NSInteger)tag
{
	if (!_recording || tag < 0 || tag > 13 || tag == 4 || tag == 9)
		return;
	const NSInteger actions[] = {1, 1, 1608, 1609, 0, 1656, 1660, 1615, 1633, 0, 1614, 1641, 1636, 1635};
	const BOOL project = _searchMode.selectedSegment == 4;
	sptr_t action = project && tag == 5 ? 1666 : project && tag == 6 ? 1665 : actions[tag];
	auto appendText = [&](unsigned int message, NSString *value) {
		_macro.push_back({message, 0, 0, std::string(value.UTF8String ?: "", [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding])});
	};
	sptr_t options = (_matchCase.state ? 1 : 0) | (_wholeWord.state ? 2 : 0) | (_purgeMarks.state ? 4 : 0) |
		(_bookmarkMatches.state ? 16 : 0) | (_recursive.state ? 32 : 0) | (_includeHidden.state ? 64 : 0) |
		(!_inSelection.hidden && _inSelection.state ? 128 : 0) | (_wrapSearch.state ? 256 : 0) |
		(tag == 1 ? 0 : 512) | (_matchNewline.state ? 1024 : 0);
	if (project)
		for (NSUInteger index = 0; index < _projectSearchControls.count; ++index)
			if (_projectSearchControls[index].state)
				options |= 128 << index;
	_macro.push_back({1700, 0, 0, std::nullopt});
	appendText(1601, _searchInput.stringValue);
	appendText(1602, _replaceInput.stringValue);
	if (tag == 5 || tag == 6)
	{
		appendText(1654, _searchFilters.stringValue);
		if (!project)
			appendText(1655, _searchFolder.stringValue);
	}
	_macro.push_back({1625, 0, _regularExpression.state ? 2 : _extendedSearch.state ? 1 : 0, std::nullopt});
	_macro.push_back({1702, 0, options, std::nullopt});
	_macro.push_back({1701, 0, action, std::nullopt});
}

- (void)performSearch:(NSButton *)sender
{
	if (sender.tag == 4)
	{
		[_searchPanel close];
		return;
	}
	if (sender.tag == 5 && _fileSearch)
	{
		[_fileSearch cancel];
		_searchStatus.stringValue = [EditorResources.shared label:@"search-cancelling" fallback:@"Cancelling…"];
		return;
	}
	if (sender.tag == 8 || sender.tag == 9)
	{
		if (sender.tag == 8)
		{
			[self recordSearchAction:8];
			[self clearSearchMarks];
		}
		else
			[self copySearchMarks];
		return;
	}
	NSString *query = _searchInput.stringValue;
	NSString *replacement = _replaceInput.stringValue;
	if (_extendedSearch.state == NSControlStateValueOn)
	{
		query = DecodeExtendedSearchText(query);
		replacement = DecodeExtendedSearchText(replacement);
	}
	if (!query.length)
	{
		_searchStatus.stringValue = [EditorResources.shared label:@"search-emptyQuery" fallback:@"Enter text to find."];
		return;
	}
	RememberSearchHistory(_searchInput.stringValue, @"findHistory");
	if (sender.tag == 2 || sender.tag == 3 || sender.tag == 6 || sender.tag == 13)
		RememberSearchHistory(_replaceInput.stringValue, @"replaceHistory");
	NSInteger flags = (_matchCase.state == NSControlStateValueOn ? SCFIND_MATCHCASE : 0) |
		(_wholeWord.enabled && _wholeWord.state == NSControlStateValueOn ? SCFIND_WHOLEWORD : 0);
	if (_regularExpression.state == NSControlStateValueOn)
	{
		flags |= SCFIND_REGEXP | SCFIND_REGEXP_EMPTYMATCH_ALL | SCFIND_REGEXP_SKIPCRLFASONE;
		if (_matchNewline.state == NSControlStateValueOn)
			flags |= SCFIND_REGEXP_DOTMATCHESNL;
	}
	if (![_query isEqualToString:query] || _searchFlags != flags)
		_lastEmptyMatch = -1;
	_query = query;
	_searchFlags = flags;
	[self setSearchStatus:@"" style:@"Find status: Message"];
	[self.editor message:SCI_SETSTATUS wParam:SC_STATUS_OK];
	[self recordSearchAction:sender.tag];
	struct PauseRecording {
		ScintillaView *source;
		~PauseRecording() { [source message:SCI_STARTRECORD]; }
	} pause{_recording ? _macroSource : nil};
	[pause.source message:SCI_STOPRECORD];
	switch (sender.tag)
	{
		case 0: [self findNext:nil]; break;
		case 1: [self findPrevious:nil]; break;
		case 2: [self replaceNextWith:replacement]; break;
		case 3: [self replaceAll:replacement]; break;
		case 5:
		case 6:
			if (_searchMode.selectedSegment == 4)
				[self startDocumentSearch:_query flags:_searchFlags replacement:sender.tag == 6 ? replacement : nil all:NO projects:YES];
			else
				[self startFileSearchWithQuery:_query flags:_searchFlags replacement:sender.tag == 6 ? replacement : nil];
			return;
		case 7: [self countMatchesAndMark:YES]; break;
		case 10: [self countMatchesAndMark:NO]; break;
		case 11: case 12: case 13:
			[self startDocumentSearch:_query flags:_searchFlags replacement:sender.tag == 13 ? replacement : nil
				all:sender.tag != 11 projects:NO];
			return;
	}
	if ([self.editor message:SCI_GETSTATUS] == SC_STATUS_WARN_REGEX)
		[self setSearchStatus:[EditorResources.shared label:@"search-invalidRegex"
			fallback:[EditorResources.shared label:@"find-status-invalid-re" fallback:@"Invalid regular expression."]]
			style:@"Find status: Not found"];
}

static void ClearMark(ScintillaView *editor, int indicator)
{
	[editor message:SCI_SETINDICATORCURRENT wParam:indicator];
	[editor message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[editor message:SCI_GETLENGTH]];
}

static std::vector<std::pair<sptr_t, sptr_t>> MarkRanges(ScintillaView *editor, int indicator)
{
	std::vector<std::pair<sptr_t, sptr_t>> ranges;
	const auto length = [editor message:SCI_GETLENGTH];
	for (sptr_t start = 0; start < length;)
	{
		const auto end = [editor message:SCI_INDICATOREND wParam:indicator lParam:start];
		if (end <= start || end > length)
			break;
		if ([editor message:SCI_INDICATORVALUEAT wParam:indicator lParam:start])
			ranges.emplace_back(start, end);
		start = end;
	}
	return ranges;
}

static void CopyMarks(ScintillaView *editor, int first, int count)
{
	std::vector<std::pair<sptr_t, sptr_t>> ranges;
	for (int indicator = first; indicator < first + count; ++indicator)
	{
		auto marks = MarkRanges(editor, indicator);
		ranges.insert(ranges.end(), marks.begin(), marks.end());
	}
	std::sort(ranges.begin(), ranges.end());
	ranges.erase(std::unique(ranges.begin(), ranges.end()), ranges.end());
	NSMutableArray<NSString *> *parts = [NSMutableArray array];
	for (const auto &[start, end] : ranges)
	{
		NSString *part = [[NSString alloc] initWithData:DocumentBytes(editor, start, end) encoding:NSUTF8StringEncoding];
		if (part)
			[parts addObject:part];
	}
	if (parts.count)
	{
		NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
		[pasteboard clearContents];
		[pasteboard setString:[parts componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
	}
}

static std::pair<sptr_t, sptr_t> TokenRange(ScintillaView *editor)
{
	auto start = [editor message:SCI_GETSELECTIONSTART];
	auto end = [editor message:SCI_GETSELECTIONEND];
	if (start == end)
	{
		start = [editor message:SCI_WORDSTARTPOSITION wParam:start lParam:1];
		end = [editor message:SCI_WORDENDPOSITION wParam:end lParam:1];
	}
	return {start, end};
}

- (IBAction)showCharacterRangeSearch:(id)sender
{
	EditorResources *resources = EditorResources.shared;
	NSAlert *dialog = [NSAlert new];
	dialog.messageText = [resources label:@"43052" fallback:@"Find Characters in Range"];
	[dialog addButtonWithTitle:[resources label:@"character-range-find" fallback:@"Find"]];
	[dialog addButtonWithTitle:[resources label:@"app-ok" fallback:@"Close"]];
	NSTextField *first = [NSTextField textFieldWithString:@"0"];
	NSTextField *last = [NSTextField textFieldWithString:@"127"];
	NSButton *backward = [NSButton checkboxWithTitle:[resources label:@"character-range-backward" fallback:@"Search backwards"] target:nil action:nil];
	NSButton *wrap = [NSButton checkboxWithTitle:[resources label:@"character-range-wrap" fallback:@"Wrap around"] target:nil action:nil];
	wrap.state = NSControlStateValueOn;
	NSStackView *form = [NSStackView stackViewWithViews:@[
		[NSTextField labelWithString:[resources label:@"character-range-first" fallback:@"First Unicode code point"]],
		first, [NSTextField labelWithString:[resources label:@"character-range-last" fallback:@"Last Unicode code point"]],
		last, backward, wrap]];
	form.orientation = NSUserInterfaceLayoutOrientationVertical;
	form.alignment = NSLayoutAttributeLeading;
	form.frame = NSMakeRect(0, 0, 270, 160);
	dialog.accessoryView = form;
	dialog.window.initialFirstResponder = first;
	while ([dialog runModal] == NSAlertFirstButtonReturn)
	{
		NSInteger lower = 0, upper = 0;
		NSScanner *from = [NSScanner scannerWithString:first.stringValue];
		NSScanner *to = [NSScanner scannerWithString:last.stringValue];
		if (![from scanInteger:&lower] || !from.isAtEnd || ![to scanInteger:&upper] || !to.isAtEnd ||
			lower < 0 || upper < lower || upper > 0x10FFFF)
		{
			dialog.informativeText = [resources label:@"character-range-invalid" fallback:@"Enter an ordered range from 0 to 1114111."];
			continue;
		}
		ScintillaView *editor = self.editor;
		const auto length = [editor message:SCI_GETLENGTH];
		const BOOL reverse = backward.state == NSControlStateValueOn;
		const auto anchor = [editor message:reverse ? SCI_GETSELECTIONSTART : SCI_GETSELECTIONEND];
		auto match = [&](sptr_t start, sptr_t end) -> bool {
			for (auto boundary = start; reverse ? boundary > end : boundary < end;)
			{
				const auto position = reverse ? [editor message:SCI_POSITIONBEFORE wParam:boundary] : boundary;
				const auto next = reverse ? boundary : [editor message:SCI_POSITIONAFTER wParam:position];
				if (next <= position)
					break;
				auto lead = [editor message:SCI_GETCHARAT wParam:position];
				auto code = lead;
				if (next - position > 1)
				{
					code &= (1 << (7 - (next - position))) - 1;
					for (auto byte = position + 1; byte < next; ++byte)
						code = (code << 6) | ([editor message:SCI_GETCHARAT wParam:byte] & 0x3f);
				}
				if (code >= lower && code <= upper)
				{
					[editor message:SCI_SETSEL wParam:position lParam:next];
					[editor message:SCI_SCROLLCARET];
					return true;
				}
				boundary = reverse ? position : next;
			}
			return false;
		};
		const BOOL found = match(anchor, reverse ? 0 : length) ||
			(wrap.state == NSControlStateValueOn && match(reverse ? length : 0, anchor));
		dialog.informativeText = found ? @"" : [resources label:@"search-noMatches" fallback:@"No matches found."];
	}
}

- (IBAction)findMatchingBrace:(NSMenuItem *)sender
{
	if (self.largeFileMode && ![[EditorResources.shared setting:@"largeFileBraceMatch" fallback:@NO] boolValue])
		return;
	ScintillaView *editor = self.editor;
	const auto caret = [editor message:SCI_GETCURRENTPOS];
	const auto previous = [editor message:SCI_POSITIONBEFORE wParam:caret];
	for (const auto position : {caret, previous})
	{
		const auto other = [editor message:SCI_BRACEMATCH wParam:position lParam:0];
		if (other < 0)
			continue;
		if (sender.tag == 43053)
			[editor message:SCI_SETSEL wParam:std::min(position, other) lParam:std::max(position, other) + 1];
		else
			[editor message:SCI_GOTOPOS wParam:other];
		[editor message:SCI_CHOOSECARETX];
		[editor message:SCI_SCROLLCARET];
		return;
	}
}

- (IBAction)findSelectedText:(NSMenuItem *)sender
{
	ScintillaView *editor = self.editor;
	const auto [start, end] = TokenRange(editor);
	if (start == end)
		return;
	NSString *query = [[NSString alloc] initWithData:DocumentBytes(editor, start, end) encoding:NSUTF8StringEncoding];
	if (!query.length)
		return;
	const BOOL forward = sender.tag == 43014 || sender.tag == 43048;
	const BOOL remember = sender.tag == 43048 || sender.tag == 43049;
	const NSInteger flags = remember ? _searchFlags & (SCFIND_MATCHCASE | SCFIND_WHOLEWORD) : 0;
	const BOOL wrap = !remember || !_wrapSearch || _wrapSearch.state == NSControlStateValueOn;
	if (remember)
	{
		RememberSearchHistory(query, @"findHistory");
		_query = query;
		_searchFlags = flags;
		_lastEmptyMatch = -1;
		_searchInput.stringValue = query;
		_matchCase.state = (flags & SCFIND_MATCHCASE) != 0;
		_wholeWord.state = (flags & SCFIND_WHOLEWORD) != 0;
		_regularExpression.state = _extendedSearch.state = NSControlStateValueOff;
	}
	const auto bound = [editor message:SCI_GETLENGTH];
	[editor message:SCI_SETTARGETRANGE wParam:forward ? end : start lParam:forward ? bound : 0];
	auto match = SearchEditorTarget(editor, query, flags);
	if (match < 0 && wrap)
	{
		[editor message:SCI_SETTARGETRANGE wParam:forward ? 0 : bound lParam:forward ? end : start];
		match = SearchEditorTarget(editor, query, flags);
	}
	if (match >= 0)
	{
		[editor message:SCI_SETSEL wParam:match lParam:[editor message:SCI_GETTARGETEND]];
		[editor message:SCI_SCROLLCARET];
	}
	else
		NSBeep();
}

- (IBAction)useMarkStyle:(NSMenuItem *)sender
{
	ScintillaView *editor = self.editor;
	const NSInteger command = sender.tag;
	if (command >= 43022 && command <= 43031 && command % 2)
	{
		ClearMark(editor, FirstTokenMark + (command - 43023) / 2);
		return;
	}
	if (command == 43032)
	{
		for (int i = 0; i < TokenMarkCount; ++i)
			ClearMark(editor, FirstTokenMark + i);
		return;
	}
	if (command >= 43055 && command <= 43061)
	{
		CopyMarks(editor, command == 43061 ? FindMark : command == 43060 ? FirstTokenMark : FirstTokenMark + command - 43055,
			command == 43060 ? TokenMarkCount : 1);
		return;
	}
	if (command >= 43033 && command <= 43044)
	{
		const BOOL forward = command >= 43039;
		const NSInteger style = command - (forward ? 43039 : 43033);
		auto ranges = MarkRanges(editor, style == TokenMarkCount ? FindMark : FirstTokenMark + style);
		if (ranges.empty())
			return;
		const auto caret = [editor message:SCI_GETSELECTIONSTART];
		auto next = forward ? std::find_if(ranges.begin(), ranges.end(), [caret](auto range) { return range.first > caret; }) :
			std::find_if(ranges.rbegin(), ranges.rend(), [caret](auto range) { return range.first < caret; }).base();
		const auto [start, end] = forward ? (next == ranges.end() ? ranges.front() : *next) :
			(next == ranges.begin() ? ranges.back() : *std::prev(next));
		[editor message:SCI_SETSEL wParam:start lParam:end];
		[editor message:SCI_SCROLLCARET];
		return;
	}
	const auto [start, end] = TokenRange(editor);
	if (start == end)
		return;
	const BOOL single = command >= 43062;
	[editor message:SCI_SETINDICATORCURRENT wParam:FirstTokenMark + (single ? command - 43062 : (command - 43022) / 2)];
	if (single)
	{
		[editor message:SCI_INDICATORFILLRANGE wParam:start lParam:end - start];
		return;
	}
	NSString *query = [[NSString alloc] initWithData:DocumentBytes(editor, start, end) encoding:NSUTF8StringEncoding];
	if (!query.length)
		return;
	const auto limit = [editor message:SCI_GETLENGTH];
	const NSInteger flags = SCFIND_MATCHCASE | ([editor message:SCI_GETSELECTIONEMPTY] ? SCFIND_WHOLEWORD : 0);
	for (auto position = static_cast<sptr_t>(0); position < limit;)
	{
		[editor message:SCI_SETTARGETRANGE wParam:position lParam:limit];
		const auto match = SearchEditorTarget(editor, query, flags);
		if (match < 0)
			break;
		position = [editor message:SCI_GETTARGETEND];
		if (position <= match)
			break;
		[editor message:SCI_INDICATORFILLRANGE wParam:match lParam:position - match];
	}
}

- (void)clearSearchMarks
{
	ClearMark(self.editor, FindMark);
	_searchStatus.stringValue = @"";
}

- (void)copySearchMarks
{
	CopyMarks(self.editor, FindMark, 1);
}

- (NSUInteger)countMatchesAndMark:(BOOL)mark
{
	if (!_query.length)
		return 0;
	ScintillaView *editor = self.editor;
	if (mark && _purgeMarks.state == NSControlStateValueOn)
		[self clearSearchMarks];
	const NSRange scope = self.searchScope;
	const auto length = static_cast<sptr_t>(NSMaxRange(scope));
	NSUInteger matches = 0;
	for (sptr_t position = scope.location; position <= length;)
	{
		auto start = [self searchFrom:position to:length];
		if (start < 0)
			break;
		const auto end = [editor message:SCI_GETTARGETEND];
		++matches;
		if (mark && end > start)
		{
			[editor message:SCI_SETINDICATORCURRENT wParam:FindMark];
			[editor message:SCI_INDICATORFILLRANGE wParam:start lParam:end - start];
		}
		if (mark && _bookmarkMatches.state == NSControlStateValueOn)
		{
			auto line = [editor message:SCI_LINEFROMPOSITION wParam:start];
			if (!([editor message:SCI_MARKERGET wParam:line] & (1 << Bookmark)))
				[editor message:SCI_MARKERADD wParam:line lParam:Bookmark];
		}
		if (end == start && end == length)
			break;
		position = end > start ? end : [editor message:SCI_POSITIONAFTER wParam:start];
	}
	EditorResources *resources = EditorResources.shared;
	NSString *statusKey = mark ? (matches == 1 ? @"find-status-mark-1-match" : @"find-status-mark-nb-matches") :
		(matches == 1 ? @"find-status-count-1-match" : @"find-status-count-nb-matches");
	NSString *message = [resources label:statusKey fallback:[NSString localizedStringWithFormat:[resources
		label:@"search-count" fallback:matches == 1 ? @"%lu match" : @"%lu matches"], matches]];
	[self setSearchStatus:[message stringByReplacingOccurrencesOfString:@"$INT_REPLACE$" withString:@(matches).stringValue]
		style:@"Find status: Message"];
	return matches;
}

- (sptr_t)searchFrom:(sptr_t)start to:(sptr_t)end
{
	[self.editor message:SCI_SETTARGETRANGE wParam:start lParam:end];
	return SearchEditorTarget(self.editor, _query, _searchFlags);
}

- (IBAction)findNext:(id)sender
{
	[self findInDirection:YES];
}

- (IBAction)findPrevious:(id)sender
{
	[self findInDirection:NO];
}

- (void)findInDirection:(BOOL)forward
{
	if (!_query.length)
	{
		[self showSearchMode:0];
		return;
	}
	const NSRange scope = self.searchScope;
	const auto lower = static_cast<sptr_t>(scope.location), upper = static_cast<sptr_t>(NSMaxRange(scope));
	auto end = forward ? upper : lower;
	auto start = std::clamp([self.editor message:forward ? SCI_GETSELECTIONEND : SCI_GETSELECTIONSTART], lower, upper);
	BOOL skipEmpty = start == _lastEmptyMatch && [self.editor message:SCI_GETSELECTIONEMPTY];
	auto next = skipEmpty && start != end ? [self.editor message:forward ? SCI_POSITIONAFTER : SCI_POSITIONBEFORE wParam:start] : start;
	auto result = skipEmpty && start == end ? -1 : [self searchFrom:next to:end];
	const BOOL wrapped = result < 0 && (!_searchPanel || _wrapSearch.state == NSControlStateValueOn) && start != (forward ? lower : upper);
	if (wrapped)
		result = [self searchFrom:forward ? lower : upper to:start];
	if (result < 0)
	{
		[self setSearchStatus:[EditorResources.shared label:@"search-noMatches" fallback:@"No matches found."]
			style:@"Find status: Not found"];
		NSBeep();
		return;
	}
	if (wrapped)
	{
		NSString *message = [EditorResources.shared label:forward ? @"find-status-end-reached" : @"find-status-top-reached"
			fallback:forward ? @"Reached the end and continued from the beginning." : @"Reached the beginning and continued from the end."];
		[self setSearchStatus:message style:@"Find status: Search end reached"];
	}
	auto matchEnd = [self.editor message:SCI_GETTARGETEND];
	_lastEmptyMatch = matchEnd == result ? result : -1;
	[self.editor message:SCI_SETSEL wParam:result lParam:matchEnd];
	[self.editor message:SCI_SCROLLCARET];
}

- (void)replaceNextWith:(NSString *)replacement
{
	const NSRange scope = self.searchScope;
	const auto lower = static_cast<sptr_t>(scope.location), upper = static_cast<sptr_t>(NSMaxRange(scope));
	auto selection = std::clamp([self.editor message:SCI_GETSELECTIONSTART], lower, upper);
	auto start = [self searchFrom:selection to:upper];
	if (start < 0 && selection > lower && (!_searchPanel || _wrapSearch.state == NSControlStateValueOn))
		start = [self searchFrom:lower to:selection];
	if (start < 0)
	{
		NSBeep();
		return;
	}
	const auto previousEnd = [self.editor message:SCI_GETTARGETEND];
	auto replaced = [self.editor message:_searchFlags & SCFIND_REGEXP ? SCI_REPLACETARGETRE : SCI_REPLACETARGET
		wParam:[replacement lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
		lParam:reinterpret_cast<sptr_t>(replacement.UTF8String)];
	if (replaced >= 0)
	{
		if (_inSelection.state == NSControlStateValueOn && !_inSelection.hidden)
			_searchSelection.length = scope.length + replaced - (previousEnd - start);
		[self.editor message:SCI_SETSEL wParam:start lParam:start + replaced];
		[self.editor message:SCI_SCROLLCARET];
	}
}

- (void)replaceAll:(NSString *)replacement
{
	[self.editor message:SCI_BEGINUNDOACTION];
	const auto length = [replacement lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	const auto *bytes = replacement.UTF8String;
	const NSRange scope = self.searchScope;
	sptr_t position = scope.location;
	sptr_t boundary = NSMaxRange(scope);
	NSUInteger replacedCount = 0;
	while (position <= boundary)
	{
		auto start = [self searchFrom:position to:boundary];
		if (start < 0)
			break;
		const auto previousEnd = [self.editor message:SCI_GETTARGETEND];
		BOOL emptyMatch = start == previousEnd;
		auto replaced = [self.editor message:_searchFlags & SCFIND_REGEXP ? SCI_REPLACETARGETRE : SCI_REPLACETARGET
			wParam:length lParam:reinterpret_cast<sptr_t>(bytes)];
		if (replaced < 0)
			break;
		++replacedCount;
		boundary += replaced - (previousEnd - start);
		position = start + replaced;
		if (emptyMatch)
		{
			if (position >= boundary)
				break;
			position = [self.editor message:SCI_POSITIONAFTER wParam:position];
		}
	}
	[self.editor message:SCI_ENDUNDOACTION];
	if (_inSelection.state == NSControlStateValueOn && !_inSelection.hidden)
		_searchSelection.length = boundary - scope.location;
	[self showReplacementCount:replacedCount];
}
@end

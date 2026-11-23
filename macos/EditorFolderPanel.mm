// SPDX-License-Identifier: GPL-3.0-only
#import "EditorFolderPanel.h"
#import "EditorContextMenus.h"
#import "EditorDocument.h"
#import "EditorPanelChrome.h"
#import "EditorResources.h"

static BOOL URLFlag(NSURL *url, NSURLResourceKey key)
{
	NSNumber *value = nil;
	return [url getResourceValue:&value forKey:key error:nullptr] && value.boolValue;
}

BOOL EditorIsWorkspaceDirectory(NSURL *url)
{
	return url.isFileURL && URLFlag(url, NSURLIsDirectoryKey) && !URLFlag(url, NSURLIsSymbolicLinkKey) &&
		!URLFlag(url, NSURLIsPackageKey);
}

@interface WorkspaceFile : NSObject
@property(nonatomic, strong) NSURL *url;
@property(nonatomic) BOOL directory;
@property(nonatomic, strong) NSArray<WorkspaceFile *> *children;
- (instancetype)initWithURL:(NSURL *)url;
@end

@implementation WorkspaceFile
- (instancetype)initWithURL:(NSURL *)url
{
	if ((self = [super init]))
	{
		_url = url;
		_directory = EditorIsWorkspaceDirectory(url);
	}
	return self;
}

- (NSArray<WorkspaceFile *> *)children
{
	if (!_directory)
		return @[];
	if (!_children)
	{
		NSArray<NSURL *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:_url
			includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLIsPackageKey]
			options:NSDirectoryEnumerationSkipsHiddenFiles error:nullptr];
		NSMutableArray<WorkspaceFile *> *files = [NSMutableArray arrayWithCapacity:entries.count];
		for (NSURL *entry in entries)
			[files addObject:[[WorkspaceFile alloc] initWithURL:entry]];
		[files sortUsingComparator:^NSComparisonResult(WorkspaceFile *a, WorkspaceFile *b) {
			if (a.directory != b.directory)
				return a.directory ? NSOrderedAscending : NSOrderedDescending;
			return [a.url.lastPathComponent localizedStandardCompare:b.url.lastPathComponent];
		}];
		_children = [files copy];
	}
	return _children;
}
@synthesize children = _children;
@end

@interface WorkspaceOutline : NSOutlineView
@property(nonatomic, copy) NSMenu *(^contextMenu)(id);
@end

@implementation WorkspaceOutline
- (NSMenu *)menuForEvent:(NSEvent *)event
{
	NSInteger row = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
	return self.contextMenu([self itemAtRow:row]);
}

- (void)keyDown:(NSEvent *)event
{
	if (event.keyCode == 36 || event.keyCode == 76)
		[NSApp sendAction:self.doubleAction to:self.target from:self];
	else
		[super keyDown:event];
}
@end

@interface EditorFolderPanel () <NSOutlineViewDataSource, NSOutlineViewDelegate>
@end

@implementation EditorFolderPanel
{
	NSArray<WorkspaceFile *> *_roots;
	WorkspaceOutline *_outline;
	NSArray<NSButton *> *_toolButtons;
	void (^_open)(NSURL *);
	void (^_add)(void);
	void (^_changeRoots)(NSArray<NSURL *> *);
	void (^_dismiss)(void);
}

- (instancetype)initWithOpen:(void (^)(NSURL *))open add:(void (^)(void))add
	changeRoots:(void (^)(NSArray<NSURL *> *))changeRoots dismiss:(void (^)(void))dismiss
{
	if (!(self = [super initWithFrame:NSZeroRect]))
		return nil;
	_open = [open copy];
	_add = [add copy];
	_changeRoots = [changeRoots copy];
	_dismiss = [dismiss copy];

	NSView *caption = EditorPanelCaption([EditorResources.shared label:@"FolderAsWorkspace:PanelTitle" fallback:@"Folder as Workspace"],
		self, @selector(dismiss:));
	_outline = [[WorkspaceOutline alloc] initWithFrame:NSZeroRect];
	_outline.headerView = nil;
	_outline.rowHeight = 18;
	_outline.indentationPerLevel = 16;
	_outline.style = NSTableViewStylePlain;
	_outline.target = self;
	_outline.doubleAction = @selector(openSelected:);
	_outline.dataSource = self;
	_outline.delegate = self;
	[_outline setAccessibilityIdentifier:@"folder-workspace"];
	[_outline setAccessibilityLabel:[EditorResources.shared label:@"FolderAsWorkspace:PanelTitle" fallback:@"Folder as Workspace"]];
	[_outline registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
	__weak EditorFolderPanel *weakSelf = self;
	_outline.contextMenu = ^NSMenu *(WorkspaceFile *file) { return [weakSelf menuForFile:file]; };
	NSTableColumn *files = [[NSTableColumn alloc] initWithIdentifier:@"file"];
	[_outline addTableColumn:files];
	_outline.outlineTableColumn = files;
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	scroll.documentView = _outline;
	scroll.hasVerticalScroller = YES;
	scroll.scrollerStyle = NSScrollerStyleLegacy;
	scroll.autohidesScrollers = YES;

	NSStackView *tools = [NSStackView new];
	tools.translatesAutoresizingMaskIntoConstraints = NO;
	tools.edgeInsets = NSEdgeInsetsMake(1, 3, 1, 3);
	tools.spacing = 2;
	[tools addArrangedSubview:[NSView new]];
	NSString *scheme = EditorResources.shared.usesDarkColors ? @"panels/dark" : @"panels/standard";
	NSMutableArray<NSButton *> *toolButtons = [NSMutableArray array];
	for (NSArray<NSString *> *entry in @[@[@"fb_expand_all", @"expandAll:"],
		@[@"fb_fold_all", @"collapseAll:"], @[@"fb_select_current_file", @"locateCurrentFile:"]])
	{
		NSButton *button = [NSButton buttonWithTitle:@"" target:self action:NSSelectorFromString(entry[1])];
		NSURL *icon = [NSBundle.mainBundle URLForResource:entry[0] withExtension:@"ico" subdirectory:scheme];
		if (icon)
		{
			button.image = [[NSImage alloc] initWithContentsOfURL:icon];
			button.image.size = NSMakeSize(16, 16);
			button.imagePosition = NSImageOnly;
			button.bordered = NO;
		}
		[button.widthAnchor constraintEqualToConstant:24].active = YES;
		[tools addArrangedSubview:button];
		[toolButtons addObject:button];
	}
	_toolButtons = [toolButtons copy];
	[self refreshDockLabels:[EditorResources.shared label:@"FolderAsWorkspace:PanelTitle" fallback:@"Folder as Workspace"]];
	[self addSubview:caption];
	[self addSubview:tools];
	[self addSubview:scroll];
	[NSLayoutConstraint activateConstraints:@[
		[caption.topAnchor constraintEqualToAnchor:self.topAnchor],
		[caption.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[caption.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[tools.topAnchor constraintEqualToAnchor:caption.bottomAnchor],
		[tools.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[tools.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[tools.heightAnchor constraintEqualToConstant:23],
		[scroll.topAnchor constraintEqualToAnchor:tools.bottomAnchor],
		[scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
	]];
	return self;
}

- (void)refreshDockLabels:(NSString *)title
{
	[_outline setAccessibilityLabel:title];
	EditorResources *resources = EditorResources.shared;
	NSArray<NSString *> *labels = @[[resources label:@"panel-expandAll" fallback:@"Unfold All"],
		[resources label:@"panel-foldAll" fallback:@"Fold All"], [resources label:@"panel-locateFile" fallback:@"Locate Current File"]];
	for (NSUInteger i = 0; i < _toolButtons.count; ++i)
	{
		NSButton *button = _toolButtons[i];
		button.title = button.toolTip = labels[i];
		[button setAccessibilityLabel:labels[i]];
	}
}

- (void)setDirectories:(NSArray<NSURL *> *)directories
{
	if ([[_roots valueForKey:@"url"] isEqualToArray:directories])
		return;
	NSMutableArray<WorkspaceFile *> *roots = [NSMutableArray arrayWithCapacity:directories.count];
	for (NSURL *directory in directories)
	{
		auto previous = [_roots indexOfObjectPassingTest:^BOOL(WorkspaceFile *entry, NSUInteger index, BOOL *stop) {
			return [entry.url isEqual:directory];
		}];
		[roots addObject:_roots && previous != NSNotFound ? _roots[previous] : [[WorkspaceFile alloc] initWithURL:directory]];
	}
	_roots = roots;
	[_outline reloadData];
	for (WorkspaceFile *root in _roots)
		[_outline expandItem:root];
}

- (void)dismiss:(id)sender { _dismiss(); }
- (void)add:(id)sender { _add(); }
- (void)expandAll:(id)sender { [_outline expandItem:nil expandChildren:YES]; }
- (void)collapseAll:(id)sender { [_outline collapseItem:nil collapseChildren:YES]; }

- (void)locateCurrentFile:(id)sender
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	NSArray<NSString *> *components = controller.focusedDocument.fileURL.URLByStandardizingPath.pathComponents;
	for (WorkspaceFile *root in _roots)
	{
		NSArray<NSString *> *base = root.url.URLByStandardizingPath.pathComponents;
		if (components.count < base.count || ![[components subarrayWithRange:NSMakeRange(0, base.count)] isEqualToArray:base])
			continue;
		WorkspaceFile *node = root;
		for (NSUInteger depth = base.count; depth < components.count && node; ++depth)
		{
			[_outline expandItem:node];
			NSString *name = components[depth];
			NSUInteger index = [node.children indexOfObjectPassingTest:^BOOL(WorkspaceFile *child, NSUInteger i, BOOL *stop) {
				return [child.url.lastPathComponent isEqualToString:name];
			}];
			node = index == NSNotFound ? nil : node.children[index];
		}
		NSInteger row = node ? [_outline rowForItem:node] : -1;
		if (row >= 0)
		{
			[_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
			[_outline scrollRowToVisible:row];
			return;
		}
	}
	NSBeep();
}

- (void)openSelected:(id)sender
{
	NSInteger row = _outline.clickedRow >= 0 ? _outline.clickedRow : _outline.selectedRow;
	WorkspaceFile *file = [_outline itemAtRow:row];
	if (file.directory)
	{
		if ([_outline isItemExpanded:file])
			[_outline collapseItem:file];
		else
			[_outline expandItem:file];
	}
	else if (file)
		_open(file.url);
}

- (NSMenu *)menuForFile:(WorkspaceFile *)file
{
	EditorResources *resources = EditorResources.shared;
	NSMenu *menu = [[NSMenu alloc] initWithTitle:[resources label:@"FolderAsWorkspace:PanelTitle" fallback:@"Folder as Workspace"]];
	NSArray *entries = !file ? @[@[@"panel-addFolder", @"Add Folder…", @"add:"], @[@"panel-removeAll", @"Remove All", @"removeAll:"]] :
		file.directory ? @[@[@"panel-copyPath", @"Copy Path", @"copyPath:"], @[@"43013", @"Find in Files…", @"search:"],
			@[@"native-showSelectionInFinder", @"Show in Finder", @"reveal:"], @[@"panel-refresh", @"Refresh Folder", @"refresh:"],
			@[@"panel-remove", @"Remove from Workspace", @"remove:"]] :
		@[@[@"41002", @"Open…", @"openFile:"], @[@"panel-copyPath", @"Copy Path", @"copyPath:"],
			@[@"42030", @"Copy Filename", @"copyFilename:"], @[@"41023", @"Open in Default Viewer", @"openInViewer:"],
			@[@"native-showSelectionInFinder", @"Show in Finder", @"reveal:"]];
	for (NSArray<NSString *> *entry in entries)
	{
		SEL action = NSSelectorFromString(entry[2]);
		if (action == @selector(remove:) && ![_roots containsObject:file])
			continue;
		NSMenuItem *item = [menu addItemWithTitle:[resources label:entry[0] fallback:entry[1]] action:action keyEquivalent:@""];
		item.representedObject = file;
		item.target = self;
	}
	return menu;
}

- (void)removeAll:(id)sender { _changeRoots(@[]); }
- (void)openFile:(NSMenuItem *)item { _open([item.representedObject url]); }
- (void)openInViewer:(NSMenuItem *)item { [NSWorkspace.sharedWorkspace openURL:[item.representedObject url]]; }
- (void)copyPath:(NSMenuItem *)item { EditorCopyText([[item.representedObject url] path]); }
- (void)copyFilename:(NSMenuItem *)item { EditorCopyText([[item.representedObject url] lastPathComponent]); }
- (void)search:(NSMenuItem *)item
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	[controller.focusedDocument findInDirectory:[item.representedObject url]];
}

- (void)reveal:(NSMenuItem *)item
{
	[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[item.representedObject url]]];
}

- (void)refresh:(NSMenuItem *)item
{
	WorkspaceFile *file = item.representedObject;
	file.children = nil;
	[_outline reloadItem:file reloadChildren:YES];
}

- (void)remove:(NSMenuItem *)item
{
	NSMutableArray *urls = [[_roots valueForKey:@"url"] mutableCopy];
	[urls removeObject:[item.representedObject url]];
	_changeRoots(urls);
}

- (NSInteger)outlineView:(NSOutlineView *)outline numberOfChildrenOfItem:(WorkspaceFile *)item
{
	return (item ? item.children : _roots).count;
}

- (id)outlineView:(NSOutlineView *)outline child:(NSInteger)index ofItem:(WorkspaceFile *)item
{
	return (item ? item.children : _roots)[index];
}

- (BOOL)outlineView:(NSOutlineView *)outline isItemExpandable:(WorkspaceFile *)item { return item.directory; }

- (NSView *)outlineView:(NSOutlineView *)outline viewForTableColumn:(NSTableColumn *)column item:(WorkspaceFile *)item
{
	NSTableCellView *cell = [outline makeViewWithIdentifier:@"Name" owner:self];
	if (!cell)
	{
		cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
		cell.identifier = @"Name";
		NSImageView *image = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 1, 16, 16)];
		NSTextField *label = [NSTextField labelWithString:@""];
		label.font = [NSFont systemFontOfSize:11];
		label.lineBreakMode = NSLineBreakByTruncatingMiddle;
		label.translatesAutoresizingMaskIntoConstraints = NO;
		[cell addSubview:image];
		[cell addSubview:label];
		cell.imageView = image;
		cell.textField = label;
		[NSLayoutConstraint activateConstraints:@[
			[label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:19],
			[label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-3],
			[label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
		]];
	}
	cell.textField.stringValue = item.url.lastPathComponent.length ? item.url.lastPathComponent : item.url.path;
	cell.imageView.image = [NSWorkspace.sharedWorkspace iconForFile:item.url.path];
	cell.toolTip = item.url.path;
	return cell;
}

- (NSArray<NSURL *> *)directoriesOnPasteboard:(NSPasteboard *)pasteboard
{
	NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
	return [urls filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
		return EditorIsWorkspaceDirectory(url);
	}]];
}

- (NSDragOperation)outlineView:(NSOutlineView *)outline validateDrop:(id<NSDraggingInfo>)info
	proposedItem:(id)item proposedChildIndex:(NSInteger)index
{
	[outline setDropItem:nil dropChildIndex:NSOutlineViewDropOnItemIndex];
	return [self directoriesOnPasteboard:info.draggingPasteboard].count ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)outlineView:(NSOutlineView *)outline acceptDrop:(id<NSDraggingInfo>)info
	item:(id)item childIndex:(NSInteger)index
{
	NSArray<NSURL *> *dropped = [self directoriesOnPasteboard:info.draggingPasteboard];
	if (!dropped.count)
		return NO;
	NSMutableOrderedSet<NSURL *> *urls = [NSMutableOrderedSet orderedSetWithArray:[_roots valueForKey:@"url"] ?: @[]];
	[urls addObjectsFromArray:dropped];
	_changeRoots(urls.array);
	return YES;
}
@end

// SPDX-License-Identifier: GPL-3.0-only
#import "EditorProjectPanel.h"
#import "EditorResources.h"
#import "EditorPanelChrome.h"

#include "pugiconfig.hpp"
#undef PUGIXML_CHARCONV_FLOAT
#include "pugixml.hpp"
#include <string_view>

@interface ProjectEntry : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *externalPath;
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, strong) NSMutableArray<ProjectEntry *> *children;
@property(nonatomic, weak) ProjectEntry *parent;
@end
@implementation ProjectEntry
@end

@interface EditorProjectWorkspace ()
@property(nonatomic, strong) ProjectEntry *root;
@property(nonatomic, strong) NSURL *url;
@property(nonatomic) BOOL dirty;
@end

static ProjectEntry *Container(NSString *name)
{
	ProjectEntry *entry = [ProjectEntry new];
	entry.name = name;
	entry.children = [NSMutableArray array];
	return entry;
}

static void Append(ProjectEntry *parent, ProjectEntry *entry)
{
	entry.parent = parent;
	[parent.children addObject:entry];
}

static BOOL ReadChildren(pugi::xml_node xml, ProjectEntry *parent, NSURL *base, NSUInteger depth)
{
	if (depth > 128)
		return NO;
	for (pugi::xml_node child : xml.children())
	{
		const std::string_view kind(child.name());
		NSString *name = [NSString stringWithUTF8String:child.attribute("name").value()];
		if (!name.length)
			continue;
		if ((!depth && kind == "Project") || (depth && kind == "Folder"))
		{
			ProjectEntry *entry = Container(name);
			if (!ReadChildren(child, entry, base, depth + 1))
				return NO;
			Append(parent, entry);
		}
		else if (depth && kind == "File")
		{
			NSString *path = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
			ProjectEntry *entry = [ProjectEntry new];
			entry.name = path.lastPathComponent;
			if ([path hasPrefix:@"//"] || (path.length >= 2 && [path characterAtIndex:1] == ':'))
			{
				entry.externalPath = name;
				entry.url = [EditorResources.shared localURLForWindowsPath:name];
			}
			else if (path.isAbsolutePath)
				entry.url = [NSURL fileURLWithPath:path];
			else if (base)
				entry.url = [base URLByAppendingPathComponent:path isDirectory:NO].URLByStandardizingPath;
			else
				entry.externalPath = name;
			Append(parent, entry);
		}
	}
	return YES;
}

static NSString *RelativePath(NSURL *url, NSURL *base)
{
	NSArray<NSString *> *path = url.URLByStandardizingPath.pathComponents;
	NSArray<NSString *> *directory = base.URLByStandardizingPath.pathComponents;
	if (!directory.count || !path.count)
		return url.path;
	NSUInteger common = 0;
	while (common < MIN(path.count, directory.count) && [path[common] isEqual:directory[common]])
		++common;
	NSMutableArray<NSString *> *pieces = [NSMutableArray array];
	for (NSUInteger i = common; i < directory.count; ++i)
		[pieces addObject:@".."];
	[pieces addObjectsFromArray:[path subarrayWithRange:NSMakeRange(common, path.count - common)]];
	return [pieces componentsJoinedByString:@"\\"];
}

static void WriteChildren(pugi::xml_node xml, ProjectEntry *parent, NSURL *base, BOOL root)
{
	for (ProjectEntry *entry in parent.children)
	{
		if (entry.children)
		{
			auto child = xml.append_child(root ? "Project" : "Folder");
			child.append_attribute("name") = entry.name.UTF8String;
			WriteChildren(child, entry, base, NO);
		}
		else
		{
			NSString *path = entry.externalPath ?: RelativePath(entry.url, base);
			xml.append_child("File").append_attribute("name") = path.UTF8String;
		}
	}
}

struct ProjectXMLWriter final : pugi::xml_writer
{
	NSMutableData *bytes = [NSMutableData data];
	void write(const void *data, size_t size) override { [bytes appendBytes:data length:size]; }
};

@implementation EditorProjectWorkspace
- (instancetype)init
{
	if ((self = [super init]))
		_root = Container(@"Workspace");
	return self;
}

- (NSData *)dataRelativeTo:(NSURL *)base
{
	pugi::xml_document doc;
	WriteChildren(doc.append_child("NotepadPlus"), _root, base, YES);
	ProjectXMLWriter writer;
	doc.save(writer, "\t");
	return writer.bytes;
}

- (BOOL)loadData:(NSData *)data base:(NSURL *)base
{
	pugi::xml_document doc;
	if (!data.length || !doc.load_buffer(data.bytes, data.length) || !doc.child("NotepadPlus"))
		return NO;
	ProjectEntry *root = Container(@"Workspace");
	if (!ReadChildren(doc.child("NotepadPlus"), root, base, 0))
		return NO;
	self.root = root;
	return YES;
}

- (BOOL)readFromURL:(NSURL *)url error:(NSError **)error
{
	NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
	if (!data)
		return NO;
	if (![self loadData:data base:url.URLByDeletingLastPathComponent])
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{NSURLErrorKey: url}];
		return NO;
	}
	self.url = url;
	self.dirty = NO;
	return YES;
}

- (BOOL)writeToURL:(NSURL *)url error:(NSError **)error
{
	if (![[self dataRelativeTo:url.URLByDeletingLastPathComponent] writeToURL:url options:NSDataWritingAtomic error:error])
		return NO;
	self.url = url;
	self.dirty = NO;
	return YES;
}

- (NSDictionary *)snapshot
{
	return @{@"xml": [self dataRelativeTo:nil], @"path": self.url.path ?: @"", @"dirty": @(self.dirty)};
}

- (void)restore:(NSDictionary *)snapshot
{
	if (![snapshot isKindOfClass:NSDictionary.class] || ![snapshot[@"xml"] isKindOfClass:NSData.class] ||
		![self loadData:snapshot[@"xml"] base:nil])
		return;
	NSString *path = snapshot[@"path"];
	self.url = [path isKindOfClass:NSString.class] && path.isAbsolutePath ? [NSURL fileURLWithPath:path] : nil;
	self.dirty = [snapshot[@"dirty"] isKindOfClass:NSNumber.class] && [snapshot[@"dirty"] boolValue];
}

- (NSArray<NSURL *> *)files
{
	NSMutableOrderedSet<NSURL *> *files = [NSMutableOrderedSet orderedSet];
	NSMutableArray<ProjectEntry *> *entries = [_root.children mutableCopy];
	for (NSUInteger i = 0; i < entries.count; ++i)
	{
		ProjectEntry *entry = entries[i];
		if (entry.url)
			[files addObject:entry.url];
		else if (entry.children.count)
			[entries addObjectsFromArray:entry.children];
	}
	return files.array;
}
@end

@interface ProjectOutline : NSOutlineView
@property(nonatomic, copy) NSMenu *(^menuForEntry)(ProjectEntry *);
@end

@implementation ProjectOutline
- (NSMenu *)menuForEvent:(NSEvent *)event
{
	return self.menuForEntry([self itemAtRow:[self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]]);
}
@end

@interface EditorProjectPanel () <NSOutlineViewDataSource, NSOutlineViewDelegate>
@end

@implementation EditorProjectPanel
{
	EditorProjectWorkspace *_workspace;
	ProjectOutline *_outline;
	void (^_open)(NSURL *);
	void (^_changed)(void);
	void (^_dismiss)(void);
	__weak ProjectEntry *_loadedRoot;
}

- (instancetype)initWithTitle:(NSString *)title workspace:(EditorProjectWorkspace *)workspace
	open:(void (^)(NSURL *))open changed:(void (^)(void))changed dismiss:(void (^)(void))dismiss
{
	if (!(self = [super initWithFrame:NSZeroRect]))
		return nil;
	_workspace = workspace;
	_open = [open copy];
	_changed = [changed copy];
	_dismiss = [dismiss copy];
	_outline = [[ProjectOutline alloc] initWithFrame:NSZeroRect];
	_outline.target = self;
	_outline.doubleAction = @selector(openEntry:);
	_outline.headerView = nil;
	_outline.style = NSTableViewStylePlain;
	_outline.rowHeight = 18;
	_outline.dataSource = self;
	_outline.delegate = self;
	[_outline setAccessibilityLabel:title];
	__weak EditorProjectPanel *weakSelf = self;
	_outline.menuForEntry = ^NSMenu *(ProjectEntry *entry) { return [weakSelf menuFor:entry]; };
	NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"Project"];
	[_outline addTableColumn:column];
	_outline.outlineTableColumn = column;
	NSView *caption = EditorPanelCaption(title, self, @selector(dismiss:));
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	scroll.hasVerticalScroller = YES;
	scroll.autohidesScrollers = YES;
	scroll.documentView = _outline;
	[self addSubview:caption];
	[self addSubview:scroll];
	[NSLayoutConstraint activateConstraints:@[
		[caption.topAnchor constraintEqualToAnchor:self.topAnchor],
		[caption.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[caption.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[scroll.topAnchor constraintEqualToAnchor:caption.bottomAnchor],
		[scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
	]];
	return self;
}

- (void)reload
{
	BOOL reset = _loadedRoot != _workspace.root;
	_loadedRoot = _workspace.root;
	[_outline reloadData];
	if (reset)
		[_outline expandItem:_workspace.root];
}

- (void)change
{
	_workspace.dirty = YES;
	[self reload];
	_changed();
}

- (void)dismiss:(id)sender { _dismiss(); }

- (NSInteger)outlineView:(NSOutlineView *)outline numberOfChildrenOfItem:(ProjectEntry *)entry
{
	return entry ? entry.children.count : 1;
}

- (id)outlineView:(NSOutlineView *)outline child:(NSInteger)index ofItem:(ProjectEntry *)entry
{
	return entry ? entry.children[index] : _workspace.root;
}

- (BOOL)outlineView:(NSOutlineView *)outline isItemExpandable:(ProjectEntry *)entry
{
	return entry.children != nil;
}

- (NSView *)outlineView:(NSOutlineView *)outline viewForTableColumn:(NSTableColumn *)column item:(ProjectEntry *)entry
{
	NSString *title = entry == _workspace.root ? (_workspace.url.lastPathComponent ?: entry.name) : entry.name;
	if (entry == _workspace.root && _workspace.dirty)
		title = [title stringByAppendingString:@" *"];
	NSTextField *label = [NSTextField labelWithString:title];
	label.font = [NSFont systemFontOfSize:11];
	label.lineBreakMode = NSLineBreakByTruncatingMiddle;
	label.toolTip = entry.url.path ?: entry.externalPath;
	if (entry.externalPath && !entry.url)
		label.textColor = NSColor.secondaryLabelColor;
	return label;
}

static NSString *ProjectLabel(NSString *title)
{
	return [EditorResources.shared label:[@"project-" stringByAppendingString:title] fallback:title];
}

- (NSMenu *)menuFor:(ProjectEntry *)entry
{
	entry = entry ?: _workspace.root;
	NSMenu *menu = [[NSMenu alloc] initWithTitle:ProjectLabel(@"Project")];
	auto add = [&](NSString *title, SEL action, NSInteger tag = 0) {
		NSMenuItem *item = [menu addItemWithTitle:ProjectLabel(title) action:action keyEquivalent:@""];
		item.target = self;
		item.representedObject = entry;
		item.tag = tag;
		return item;
	};
	if (entry == _workspace.root)
	{
		add(@"New Workspace", @selector(newWorkspace:));
		add(@"Open Workspace…", @selector(openWorkspace:));
		add(@"Save Workspace", @selector(saveWorkspace:));
		add(@"Save Workspace As…", @selector(saveWorkspace:), 1);
		[menu addItem:NSMenuItem.separatorItem];
		add(@"Add Project…", @selector(addContainer:));
	}
	else
	{
		if (entry.children)
		{
			add(@"Add Folder…", @selector(addContainer:));
			add(@"Add Files…", @selector(addFiles:));
			add(@"Rename…", @selector(renameEntry:));
		}
		else if (entry.url)
		{
			add(@"Open", @selector(openFile:));
			add(@"Show in Finder", @selector(revealFile:));
		}
		add(@"Remove from Workspace", @selector(remove:));
		NSUInteger index = [entry.parent.children indexOfObjectIdenticalTo:entry];
		if (index > 0)
			add(@"Move Up", @selector(move:), -1);
		if (index + 1 < entry.parent.children.count)
			add(@"Move Down", @selector(move:), 1);
	}
	return menu;
}

- (void)openEntry:(id)sender
{
	ProjectEntry *entry = [_outline itemAtRow:_outline.clickedRow];
	if (entry.url)
		_open(entry.url);
}
- (void)openFile:(NSMenuItem *)item { _open([item.representedObject url]); }
- (void)revealFile:(NSMenuItem *)item
{
	[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[item.representedObject url]]];
}

- (BOOL)canReplaceWorkspace
{
	if (!_workspace.dirty)
		return YES;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = ProjectLabel(@"Discard unsaved changes to this project workspace?");
	[alert addButtonWithTitle:[EditorResources.shared label:@"native-cancel" fallback:@"Cancel"]];
	[alert addButtonWithTitle:ProjectLabel(@"Discard Changes")];
	return [alert runModal] == NSAlertSecondButtonReturn;
}

- (void)newWorkspace:(id)sender
{
	if (![self canReplaceWorkspace])
		return;
	_workspace.root = Container(@"Workspace");
	_workspace.url = nil;
	_workspace.dirty = NO;
	[self reload];
	_changed();
}

- (void)openWorkspace:(id)sender
{
	if (![self canReplaceWorkspace])
		return;
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	if ([panel runModal] != NSModalResponseOK)
		return;
	NSError *error = nil;
	if (![_workspace readFromURL:panel.URL error:&error])
		[NSApp presentError:error];
	else
	{
		[self reload];
		_changed();
	}
}

- (void)saveWorkspace:(NSMenuItem *)item
{
	NSURL *url = item.tag ? nil : _workspace.url;
	if (!url)
	{
		NSSavePanel *panel = NSSavePanel.savePanel;
		panel.nameFieldStringValue = _workspace.url.lastPathComponent ?: @"workspace.xml";
		if ([panel runModal] != NSModalResponseOK)
			return;
		url = panel.URL;
	}
	NSError *error = nil;
	if (![_workspace writeToURL:url error:&error])
		[NSApp presentError:error];
	else
	{
		[self reload];
		_changed();
	}
}

- (NSString *)nameWithTitle:(NSString *)title initial:(NSString *)initial
{
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = ProjectLabel(title);
	NSTextField *field = [NSTextField textFieldWithString:initial ?: @""];
	field.frame = NSMakeRect(0, 0, 280, 24);
	alert.accessoryView = field;
	alert.window.initialFirstResponder = field;
	[alert addButtonWithTitle:[EditorResources.shared label:@"app-ok" fallback:@"OK"]];
	[alert addButtonWithTitle:[EditorResources.shared label:@"native-cancel" fallback:@"Cancel"]];
	return [alert runModal] == NSAlertFirstButtonReturn ?
		[field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
}

- (void)addContainer:(NSMenuItem *)item
{
	ProjectEntry *parent = item.representedObject;
	NSString *name = [self nameWithTitle:parent == _workspace.root ? @"Project name" : @"Folder name" initial:nil];
	if (name.length)
	{
		Append(parent, Container(name));
		[self change];
		[_outline expandItem:parent];
	}
}

- (void)addFiles:(NSMenuItem *)item
{
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowsMultipleSelection = YES;
	if ([panel runModal] != NSModalResponseOK)
		return;
	ProjectEntry *parent = item.representedObject;
	for (NSURL *url in panel.URLs)
	{
		ProjectEntry *file = [ProjectEntry new];
		file.name = url.lastPathComponent;
		file.url = url;
		Append(parent, file);
	}
	[self change];
	[_outline expandItem:parent];
}

- (void)renameEntry:(NSMenuItem *)item
{
	ProjectEntry *entry = item.representedObject;
	NSString *name = [self nameWithTitle:@"Rename" initial:entry.name];
	if (name.length)
	{
		entry.name = name;
		[self change];
	}
}

- (void)remove:(NSMenuItem *)item
{
	ProjectEntry *entry = item.representedObject;
	[entry.parent.children removeObjectIdenticalTo:entry];
	[self change];
}

- (void)move:(NSMenuItem *)item
{
	ProjectEntry *entry = item.representedObject;
	NSMutableArray<ProjectEntry *> *siblings = entry.parent.children;
	NSInteger first = [siblings indexOfObjectIdenticalTo:entry], second = first + item.tag;
	if (first >= 0 && first < siblings.count && second >= 0 && second < siblings.count)
	{
		[siblings exchangeObjectAtIndex:first withObjectAtIndex:second];
		[self change];
	}
}
@end

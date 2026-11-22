// SPDX-License-Identifier: GPL-3.0-only
#import "EditorDocumentList.h"
#import "EditorContextMenus.h"
#import "EditorDocument.h"
#import "EditorPanelChrome.h"
#import "EditorResources.h"

@interface DocumentListTable : NSTableView
@property(nonatomic, copy) EditorDocument *(^documentAtRow)(NSInteger);
@property(nonatomic, copy) void (^activateRow)(NSInteger);
@end

@implementation DocumentListTable
- (NSMenu *)menuForEvent:(NSEvent *)event
{
	NSInteger row = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
	return EditorTabMenu(self.documentAtRow(row));
}

- (void)otherMouseDown:(NSEvent *)event
{
	if (event.buttonNumber == 2)
	{
		NSInteger row = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
		[self.documentAtRow(row) closeEditorTab:nil];
	}
	else
		[super otherMouseDown:event];
}

- (void)keyDown:(NSEvent *)event
{
	if (event.keyCode == 36 || event.keyCode == 76)
		self.activateRow(self.selectedRow);
	else
		[super keyDown:event];
}
@end

@interface DocumentListHeader : NSTableHeaderView
@property(nonatomic, copy) NSMenu *(^columnMenu)(void);
@end

@implementation DocumentListHeader
- (NSMenu *)menuForEvent:(NSEvent *)event { return self.columnMenu(); }
@end

@interface EditorDocumentList () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation EditorDocumentList
{
	NSPointerArray *_documents;
	NSPointerArray *_other;
	NSPointerArray *_rows;
	NSInteger _secondaryHeaderRow;
	BOOL _hasGroups;
	BOOL _groupByView;
	BOOL _focusOther;
	NSUInteger _collapsedViews;
	NSTableView *_table;
	__weak EditorDocument *_selectedDocument;
	NSTableColumn *_extensionColumn;
	NSTableColumn *_pathColumn;
	void (^_select)(EditorDocument *, BOOL);
	void (^_dismiss)(void);
	void (^_groupingChanged)(BOOL);
}

- (instancetype)initWithSelect:(void (^)(EditorDocument *, BOOL))select
	dismiss:(void (^)(void))dismiss groupingChanged:(void (^)(BOOL))groupingChanged
{
	self = [super initWithFrame:NSZeroRect];
	if (!self)
		return nil;
	_select = [select copy];
	_dismiss = [dismiss copy];
	_groupingChanged = [groupingChanged copy];
	self.translatesAutoresizingMaskIntoConstraints = NO;

	EditorResources *resources = EditorResources.shared;
	NSView *header = EditorPanelCaption([resources label:@"docList:PanelTitle" fallback:@"Document List"], self, @selector(dismiss:));
	__weak EditorDocumentList *weakSelf = self;
	DocumentListTable *table = [[DocumentListTable alloc] initWithFrame:NSZeroRect];
	table.documentAtRow = ^EditorDocument *(NSInteger row) { return [weakSelf documentAtRow:row]; };
	table.activateRow = ^(NSInteger row) { [weakSelf activateRow:row]; };
	_table = table;
	_table.dataSource = self;
	_table.delegate = self;
	_table.target = self;
	_table.action = @selector(selectRow:);
	DocumentListHeader *columnHeader = [[DocumentListHeader alloc] initWithFrame:NSMakeRect(0, 0, 200, 19)];
	columnHeader.columnMenu = ^NSMenu * { return [weakSelf documentColumnMenu]; };
	_table.headerView = columnHeader;
	_table.rowHeight = 17;
	_table.intercellSpacing = NSMakeSize(1, 0);
	_table.style = NSTableViewStylePlain;
	_table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
	[_table setAccessibilityIdentifier:@"open-documents"];
	[_table setAccessibilityLabel:[resources label:@"panel-openDocuments" fallback:@"Open Documents"]];
	NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"document"];
	column.title = [resources label:@"docList:ColumnName" fallback:@"Name"];
	column.resizingMask = NSTableColumnAutoresizingMask;
	column.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"displayName" ascending:YES selector:@selector(localizedStandardCompare:)];
	[_table addTableColumn:column];
	_extensionColumn = [[NSTableColumn alloc] initWithIdentifier:@"extension"];
	_extensionColumn.title = [resources label:@"docList:ColumnExt" fallback:@"Ext."];
	_extensionColumn.width = 48;
	_extensionColumn.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"fileURL.pathExtension" ascending:YES selector:@selector(localizedStandardCompare:)];
	[_table addTableColumn:_extensionColumn];
	_pathColumn = [[NSTableColumn alloc] initWithIdentifier:@"path"];
	_pathColumn.title = [resources label:@"docList:ColumnPath" fallback:@"Path"];
	_pathColumn.width = 80;
	_pathColumn.hidden = YES;
	_pathColumn.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"fileURL.path" ascending:YES selector:@selector(localizedStandardCompare:)];
	[_table addTableColumn:_pathColumn];
	for (NSTableColumn *entry in _table.tableColumns)
		entry.headerCell.font = [NSFont systemFontOfSize:11];
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	scroll.documentView = _table;
	scroll.hasVerticalScroller = YES;
	scroll.scrollerStyle = NSScrollerStyleLegacy;
	scroll.autohidesScrollers = YES;
	scroll.borderType = NSLineBorder;

	[self addSubview:header];
	[self addSubview:scroll];
	[NSLayoutConstraint activateConstraints:@[
		[header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[header.topAnchor constraintEqualToAnchor:self.topAnchor],
		[scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
	]];
	return self;
}

static NSPointerArray *WeakList(NSArray<EditorDocument *> *documents)
{
	NSPointerArray *list = NSPointerArray.weakObjectsPointerArray;
	for (EditorDocument *document in documents)
		[list addPointer:(__bridge void *)document];
	return list;
}

- (void)reloadDocuments:(NSArray<EditorDocument *> *)documents otherView:(NSArray<EditorDocument *> *)other
	selected:(EditorDocument *)selected focusOther:(BOOL)focusOther groupByView:(BOOL)groupByView
{
	_documents = WeakList(documents);
	_other = WeakList(other);
	_selectedDocument = selected;
	_focusOther = focusOther;
	_groupByView = groupByView;
	_hasGroups = groupByView && (documents.count || other.count);
	_secondaryHeaderRow = -1;
	if (!_hasGroups)
	{
		NSMutableOrderedSet *combined = [NSMutableOrderedSet orderedSetWithArray:documents];
		[combined addObjectsFromArray:other];
		documents = combined.array;
	}
	if (_table.sortDescriptors.count)
	{
		documents = [documents sortedArrayUsingDescriptors:_table.sortDescriptors];
		other = [other sortedArrayUsingDescriptors:_table.sortDescriptors];
	}
	_rows = NSPointerArray.weakObjectsPointerArray;
	if (_hasGroups)
		[_rows addPointer:nullptr];
	NSInteger selectedRow = -1;
	for (EditorDocument *document in documents)
	{
		if (_hasGroups && (_collapsedViews & 1))
			break;
		if (document == selected && (!_hasGroups || !focusOther))
			selectedRow = _rows.count;
		[_rows addPointer:(__bridge void *)document];
	}
	if (_hasGroups && other.count)
	{
		_secondaryHeaderRow = _rows.count;
		[_rows addPointer:nullptr];
		for (EditorDocument *document in other)
		{
			if (_collapsedViews & 2)
				break;
			if (document == selected && focusOther)
				selectedRow = _rows.count;
			[_rows addPointer:(__bridge void *)document];
		}
	}
	[_table reloadData];
	if (selectedRow >= 0)
	{
		[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:selectedRow] byExtendingSelection:NO];
		[_table scrollRowToVisible:selectedRow];
	}
}

- (EditorDocument *)documentAtRow:(NSInteger)row
{
	return row >= 0 && static_cast<NSUInteger>(row) < _rows.count ? (__bridge EditorDocument *)[_rows pointerAtIndex:row] : nil;
}

- (NSMenu *)documentColumnMenu
{
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Columns"];
	for (NSTableColumn *column in @[_extensionColumn, _pathColumn])
	{
		NSMenuItem *item = [menu addItemWithTitle:column.title action:@selector(toggleColumn:) keyEquivalent:@""];
		item.target = self;
		item.representedObject = column;
		item.state = column.hidden ? NSControlStateValueOff : NSControlStateValueOn;
	}
	[menu addItem:NSMenuItem.separatorItem];
	NSString *title = [EditorResources.shared label:@"docList:ListGroups" fallback:@"Group by View"];
	NSMenuItem *group = [menu addItemWithTitle:title action:@selector(toggleGrouping:) keyEquivalent:@""];
	group.target = self;
	group.state = _groupByView ? NSControlStateValueOn : NSControlStateValueOff;
	return menu;
}

- (void)toggleGrouping:(id)sender { _groupingChanged(!_groupByView); }

- (void)toggleColumn:(NSMenuItem *)item
{
	NSTableColumn *column = item.representedObject;
	column.hidden = !column.hidden;
	[_table reloadData];
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors
{
	[self reloadDocuments:_documents.allObjects otherView:_other.allObjects selected:_selectedDocument
		focusOther:_focusOther groupByView:_groupByView];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return _rows.count;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row
{
	return _hasGroups && (row == 0 || row == _secondaryHeaderRow);
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
	return [self documentAtRow:row] != nil;
}

- (void)toggleGroup:(NSButton *)button
{
	_collapsedViews ^= 1U << button.tag;
	[self reloadDocuments:_documents.allObjects otherView:_other.allObjects selected:_selectedDocument
		focusOther:_focusOther groupByView:_groupByView];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
	if ([self tableView:tableView isGroupRow:row])
	{
		const NSInteger group = row == 0 ? 0 : 1;
		EditorResources *resources = EditorResources.shared;
		NSString *title = [resources label:group ? @"panel-view2" : @"panel-view1" fallback:group ? @"View 2" : @"View 1"];
		BOOL collapsed = (_collapsedViews & (1U << group)) != 0;
		NSButton *button = [NSButton buttonWithTitle:title image:[NSImage imageWithSystemSymbolName:collapsed ?
			@"chevron.right" : @"chevron.down" accessibilityDescription:nil] target:self action:@selector(toggleGroup:)];
		button.imagePosition = NSImageLeft;
		button.alignment = NSTextAlignmentLeft;
		button.bordered = NO;
		button.tag = group;
		button.font = [NSFont boldSystemFontOfSize:11];
		return button;
	}
	NSTableCellView *cell = [tableView makeViewWithIdentifier:column.identifier owner:self];
	const BOOL name = [column.identifier isEqualToString:@"document"];
	if (!cell)
	{
		cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
		cell.identifier = column.identifier;
		NSTextField *label = [NSTextField labelWithString:@""];
		label.font = [NSFont systemFontOfSize:11];
		label.lineBreakMode = NSLineBreakByTruncatingMiddle;
		label.translatesAutoresizingMaskIntoConstraints = NO;
		cell.textField = label;
		[cell addSubview:label];
		[NSLayoutConstraint activateConstraints:@[
			[label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:name ? 20 : 3],
			[label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
			[label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
		]];
		if (name)
		{
			NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
			icon.translatesAutoresizingMaskIntoConstraints = NO;
			cell.imageView = icon;
			[cell addSubview:icon];
			[NSLayoutConstraint activateConstraints:@[
				[icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:3],
				[icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
				[icon.widthAnchor constraintEqualToConstant:14],
				[icon.heightAnchor constraintEqualToConstant:14],
			]];
		}
	}
	EditorDocument *document = [self documentAtRow:row];
	if (name)
	{
		NSString *filename = document.displayName ?: @"";
		cell.textField.stringValue = _extensionColumn.hidden ? filename : filename.stringByDeletingPathExtension;
		cell.imageView.image = EditorTabStateIcon(document.isDocumentEdited, [document.editor message:SCI_GETREADONLY] != 0,
			document.isMonitoring, EditorResources.shared.usesDarkColors);
		cell.wantsLayer = YES;
		cell.layer.backgroundColor = (EditorTabColor(document.tabColorIndex) ?: NSColor.clearColor).CGColor;
	}
	else
		cell.textField.stringValue = (column == _extensionColumn ? document.fileURL.pathExtension : document.fileURL.URLByDeletingLastPathComponent.path) ?: @"";
	cell.toolTip = document.fileURL.path;
	return cell;
}

- (void)selectRow:(id)sender
{
	[self activateRow:_table.clickedRow];
}

- (void)activateRow:(NSInteger)row
{
	if (EditorDocument *document = [self documentAtRow:row])
		_select(document, _hasGroups && row > _secondaryHeaderRow);
}

- (void)dismiss:(id)sender
{
	_dismiss();
}
@end

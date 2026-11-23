// SPDX-License-Identifier: GPL-3.0-only
#import "EditorDocument.h"
#import "EditorResources.h"
#import "EditorSettings.h"

static NSString *TabsLabel(NSString *key, NSString *fallback)
{
	return [EditorResources.shared label:key fallback:fallback];
}

@interface EditorTabManager : NSObject <NSTableViewDataSource, NSTableViewDelegate>
- (void)show;
@end

@implementation EditorTabManager
{
	NSArray<EditorDocument *> *_rows;
	NSTableView *_table;
	NSArray<EditorDocument *> *_pending;
	BOOL _saving;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return _rows.count; }

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
	EditorDocument *document = _rows[row];
	if ([column.identifier isEqualToString:@"fileURL.path"])
		return document.fileURL.path ?: @"";
	if ([column.identifier isEqualToString:@"fileModificationDate"])
		return document.fileModificationDate ? [NSDateFormatter localizedStringFromDate:document.fileModificationDate
			dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle] : @"";
	return document.isDocumentEdited ? [document.displayName stringByAppendingString:@" *"] : document.displayName;
}

- (void)tableView:(NSTableView *)table sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old
{
	NSSortDescriptor *sorting = table.sortDescriptors.firstObject;
	if (!sorting)
		return;
	_rows = [_rows sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(EditorDocument *left, EditorDocument *right) {
		id a = [left valueForKeyPath:sorting.key];
		id b = [right valueForKeyPath:sorting.key];
		NSComparisonResult result = NSOrderedSame;
		if (a && b)
			result = [a isKindOfClass:NSString.class] ? [a localizedStandardCompare:b] : [a compare:b];
		else if (a != b)
			result = a ? NSOrderedDescending : NSOrderedAscending;
		return sorting.ascending ? result : static_cast<NSComparisonResult>(-result);
	}];
	[table deselectAll:nil];
	[table reloadData];
}

- (void)finishNext
{
	if (!_pending.count)
		return;
	EditorDocument *document = _pending.firstObject;
	_pending = [_pending subarrayWithRange:NSMakeRange(1, _pending.count - 1)];
	void *context = (__bridge_retained void *)self;
	if (_saving)
		[document saveDocumentWithDelegate:self didSaveSelector:@selector(document:finished:context:) contextInfo:context];
	else
		[document canCloseDocumentWithDelegate:self shouldCloseSelector:@selector(document:finished:context:) contextInfo:context];
}

- (void)document:(EditorDocument *)document finished:(BOOL)approved context:(void *)context
{
	EditorTabManager *operation = (__bridge_transfer EditorTabManager *)context;
	if (!approved)
		return;
	if (!_saving)
		[document close];
	dispatch_async(dispatch_get_main_queue(), ^{ [operation finishNext]; });
}

- (void)show
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	_rows = controller.tabDocuments;
	if (!_rows.count)
		return;
	_table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 660, 280)];
	_table.usesAlternatingRowBackgroundColors = YES;
	_table.allowsMultipleSelection = YES;
	NSArray *columns = @[
		@[@"displayName", TabsLabel(@"native-openTabs-file", @"File"), @190],
		@[@"fileURL.path", TabsLabel(@"native-openTabs-path", @"Path"), @315],
		@[@"fileModificationDate", TabsLabel(@"native-openTabs-modified", @"Modified"), @140],
	];
	for (NSArray *definition in columns)
	{
		NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:definition[0]];
		column.title = definition[1];
		column.width = [definition[2] doubleValue];
		column.editable = NO;
		column.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:column.identifier ascending:YES];
		[_table addTableColumn:column];
	}
	_table.dataSource = self;
	_table.delegate = self;
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:_table.frame];
	scroll.hasVerticalScroller = YES;
	scroll.documentView = _table;
	NSAlert *panel = [NSAlert new];
	panel.messageText = TabsLabel(@"native-openTabs", @"Manage Open Tabs…");
	[panel addButtonWithTitle:TabsLabel(@"native-openTabs-activate", @"Activate")];
	[panel addButtonWithTitle:TabsLabel(@"app-ok", @"OK")].keyEquivalent = @"\e";
	[panel addButtonWithTitle:TabsLabel(@"native-openTabs-save", @"Save Selected")];
	[panel addButtonWithTitle:TabsLabel(@"native-openTabs-close", @"Close Selected")];
	[panel addButtonWithTitle:TabsLabel(@"native-openTabs-sort", @"Apply Tab Order")];
	panel.accessoryView = scroll;
	NSUInteger selected = [_rows indexOfObjectIdenticalTo:controller.focusedDocument];
	if (selected != NSNotFound)
		[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];

	NSModalResponse response = [panel runModal];
	NSArray<EditorDocument *> *documents = [_rows objectsAtIndexes:_table.selectedRowIndexes];
	if (response == NSAlertFirstButtonReturn && documents.count)
		[documents.firstObject showWindows];
	else if (response == NSAlertThirdButtonReturn || response == NSAlertThirdButtonReturn + 1)
	{
		_pending = documents;
		_saving = response == NSAlertThirdButtonReturn;
		dispatch_async(dispatch_get_main_queue(), ^{ [self finishNext]; });
	}
	else if (response == NSAlertThirdButtonReturn + 2)
		[controller reorderTabs:_rows];
}
@end

void EditorShowTabManager(void) { [[EditorTabManager new] show]; }

// SPDX-License-Identifier: GPL-3.0-only
#import "EditorInsertPanels.h"
#import "EditorPanelChrome.h"
#import "EditorResources.h"

@interface InsertTable : NSTableView
@property(nonatomic, copy) void (^activate)(NSInteger, NSInteger);
@end

@implementation InsertTable
- (void)keyDown:(NSEvent *)event
{
	if (event.keyCode == 36 || event.keyCode == 76)
		self.activate(self.selectedRow, -1);
	else
		[super keyDown:event];
}
@end

static InsertTable *InstallTable(NSView *view, NSString *title, NSArray<NSString *> *columns,
	id<NSTableViewDataSource, NSTableViewDelegate> target)
{
	NSView *caption = EditorPanelCaption(title, target, @selector(dismiss:));
	InsertTable *table = [[InsertTable alloc] initWithFrame:NSZeroRect];
	table.dataSource = target;
	table.delegate = target;
	table.target = target;
	table.doubleAction = @selector(activateCell:);
	table.style = NSTableViewStylePlain;
	table.rowHeight = 17;
	[table setAccessibilityLabel:title];
	if (columns.count == 1)
		table.headerView = nil;
	for (NSUInteger i = 0; i < columns.count; ++i)
	{
		NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:[@(i) stringValue]];
		column.title = columns[i];
		column.width = i < 3 ? 64 : 96;
		[table addTableColumn:column];
	}
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	scroll.hasVerticalScroller = YES;
	scroll.hasHorizontalScroller = columns.count > 1;
	scroll.autohidesScrollers = YES;
	scroll.documentView = table;
	[view addSubview:caption];
	[view addSubview:scroll];
	[NSLayoutConstraint activateConstraints:@[
		[caption.topAnchor constraintEqualToAnchor:view.topAnchor],
		[caption.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
		[caption.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
		[scroll.topAnchor constraintEqualToAnchor:caption.bottomAnchor],
		[scroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
	]];
	return table;
}

static NSTextField *Cell(NSString *value)
{
	NSTextField *label = [NSTextField labelWithString:value];
	label.font = [NSFont systemFontOfSize:11];
	label.lineBreakMode = NSLineBreakByTruncatingTail;
	return label;
}

@interface EditorClipboardHistory () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation EditorClipboardHistory
{
	InsertTable *_table;
	NSArray<NSString *> *_entries;
	void (^_insert)(NSString *);
	void (^_dismiss)(void);
}

- (instancetype)initWithInsert:(void (^)(NSString *))insert dismiss:(void (^)(void))dismiss
{
	if (!(self = [super initWithFrame:NSZeroRect]))
		return nil;
	_insert = [insert copy];
	_dismiss = [dismiss copy];
	NSString *title = [EditorResources.shared label:@"ClipboardHistory:PanelTitle" fallback:@"Clipboard History"];
	_table = InstallTable(self, title, @[title], self);
	__weak EditorClipboardHistory *weakSelf = self;
	_table.activate = ^(NSInteger row, NSInteger column) { [weakSelf insertRow:row]; };
	return self;
}

- (void)setEntries:(NSArray<NSString *> *)entries
{
	_entries = [entries copy];
	[_table reloadData];
}

- (void)activateCell:(id)sender { [self insertRow:_table.clickedRow]; }
- (void)dismiss:(id)sender { _dismiss(); }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return _entries.count; }

- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
	NSString *entry = _entries[row];
	NSString *preview = [[entry componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] firstObject];
	return Cell(preview.length ? preview : @"↵");
}

- (void)insertRow:(NSInteger)row
{
	if (row >= 0 && row < _entries.count)
		_insert(_entries[row]);
}
@end

@interface EditorCharacterPanel () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation EditorCharacterPanel
{
	InsertTable *_table;
	NSStringEncoding _encoding;
	void (^_insert)(NSString *);
	void (^_dismiss)(void);
}

- (instancetype)initWithInsert:(void (^)(NSString *))insert dismiss:(void (^)(void))dismiss
{
	if (!(self = [super initWithFrame:NSZeroRect]))
		return nil;
	_insert = [insert copy];
	_dismiss = [dismiss copy];
	_encoding = NSWindowsCP1252StringEncoding;
	EditorResources *resources = EditorResources.shared;
	NSArray *keys = @[@"ColumnVal", @"ColumnHex", @"ColumnChar", @"ColumnHtmlName", @"ColumnHtmlNumber", @"ColumnHtmlHexNb"];
	NSArray *defaults = @[@"Value", @"Hex", @"Character", @"HTML Name", @"HTML Decimal", @"HTML Hexadecimal"];
	NSMutableArray *columns = [NSMutableArray array];
	for (NSUInteger index = 0; index < keys.count; ++index)
		[columns addObject:[resources label:[@"AsciiInsertion:" stringByAppendingString:keys[index]] fallback:defaults[index]]];
	_table = InstallTable(self, [resources label:@"AsciiInsertion:PanelTitle" fallback:@"ASCII Codes Insertion Panel"], columns, self);
	__weak EditorCharacterPanel *weakSelf = self;
	_table.activate = ^(NSInteger row, NSInteger column) { [weakSelf insertRow:row column:column]; };
	return self;
}

- (void)useEncoding:(NSStringEncoding)encoding
{
	if (encoding == NSUTF8StringEncoding || encoding == NSUTF16LittleEndianStringEncoding ||
		encoding == NSUTF16BigEndianStringEncoding || !encoding)
		encoding = NSWindowsCP1252StringEncoding;
	if (_encoding != encoding)
	{
		_encoding = encoding;
		[_table reloadData];
	}
}

- (NSString *)character:(NSInteger)row
{
	if (row < 128)
	{
		unichar character = row;
		return [NSString stringWithCharacters:&character length:1];
	}
	const unsigned char byte = row;
	return [[NSString alloc] initWithBytes:&byte length:1 encoding:_encoding];
}

- (NSString *)valueForRow:(NSInteger)row column:(NSInteger)column
{
	NSString *character = [self character:row];
	const unichar codepoint = character.length ? [character characterAtIndex:0] : row;
	switch (column)
	{
		case 0: return [@(row) stringValue];
		case 1: return [NSString stringWithFormat:@"%02lX", row];
		case 2: return character ?: @"";
		case 3:
			switch (codepoint)
			{
				case 34: return @"&quot;";
				case 38: return @"&amp;";
				case 39: return @"&apos;";
				case 60: return @"&lt;";
				case 62: return @"&gt;";
				case 160: return @"&nbsp;";
				case 169: return @"&copy;";
				case 174: return @"&reg;";
				case 8364: return @"&euro;";
			}
			return @"";
		case 4: return [NSString stringWithFormat:@"&#%u;", codepoint];
		case 5: return [NSString stringWithFormat:@"&#x%X;", codepoint];
	}
	return @"";
}

- (void)activateCell:(id)sender { [self insertRow:_table.clickedRow column:_table.clickedColumn]; }
- (void)dismiss:(id)sender { _dismiss(); }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return 256; }

- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
	NSInteger index = column.identifier.integerValue;
	if (index == 2 && (row < 32 || row == 127))
	{
		unichar control = row == 127 ? 0x2421 : 0x2400 + row;
		return Cell([NSString stringWithCharacters:&control length:1]);
	}
	return Cell([self valueForRow:row column:index]);
}

- (void)insertRow:(NSInteger)row column:(NSInteger)column
{
	if (row >= 0 && row < 256)
	{
		NSString *value = [self valueForRow:row column:column < 0 ? 2 : column];
		if (value.length)
			_insert(value);
	}
}
@end

// SPDX-License-Identifier: GPL-3.0-only
#import "EditorFileSearch.h"
#import "EditorContextMenus.h"
#import "EditorPanelChrome.h"
#import "EditorResources.h"
#import "ScintillaView.h"

#include <vector>

@interface ResultEditor : ScintillaView
@property(nonatomic, copy) NSMenu *(^resultMenu)(NSEvent *);
@end

@implementation ResultEditor
- (NSMenu *)menuForEvent:(NSEvent *)event { return self.resultMenu(event); }
@end

static NSString *Inline(NSString *value)
{
	return [[value stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"]
		stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
}

@interface EditorSearchResultsView () <ScintillaNotificationProtocol>
@end

@implementation EditorSearchResultsView
{
	ResultEditor *_results;
	NSArray *_rows;
	id _keyMonitor;
	void (^_openMatch)(EditorSearchMatch *);
	void (^_dismiss)(void);
}

- (instancetype)initWithOpenMatch:(void (^)(EditorSearchMatch *))openMatch dismiss:(void (^)(void))dismiss
{
	self = [super initWithFrame:NSZeroRect];
	if (!self)
		return nil;
	_openMatch = [openMatch copy];
	_dismiss = [dismiss copy];
	self.translatesAutoresizingMaskIntoConstraints = NO;
	NSString *title = [EditorResources.shared label:@"find-result-caption" fallback:@"Search results"];
	NSView *caption = EditorPanelCaption(title, self, @selector(dismiss:));
	_results = [[ResultEditor alloc] initWithFrame:NSZeroRect];
	_results.translatesAutoresizingMaskIntoConstraints = NO;
	_results.delegate = self;
	[_results.content setAccessibilityLabel:title];
	__weak EditorSearchResultsView *weakSelf = self;
	_results.resultMenu = ^NSMenu *(NSEvent *event) { return [weakSelf menuForResultEvent:event]; };
	[_results message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
	[_results message:SCI_SETMARGINWIDTHN wParam:0 lParam:0];
	[_results message:SCI_SETMARGINWIDTHN wParam:1 lParam:0];
	[_results message:SCI_SETMARGINTYPEN wParam:2 lParam:SC_MARGIN_SYMBOL];
	[_results message:SCI_SETMARGINMASKN wParam:2 lParam:SC_MASK_FOLDERS];
	[_results message:SCI_SETMARGINWIDTHN wParam:2 lParam:14];
	[_results message:SCI_SETMARGINSENSITIVEN wParam:2 lParam:1];
	[_results message:SCI_SETAUTOMATICFOLD wParam:SC_AUTOMATICFOLD_CLICK];
	const int markers[] = {SC_MARK_BOXPLUSCONNECTED, SC_MARK_BOXMINUSCONNECTED, SC_MARK_TCORNER,
		SC_MARK_LCORNER, SC_MARK_VLINE, SC_MARK_BOXPLUS, SC_MARK_BOXMINUS};
	for (NSUInteger i = 0; i < std::size(markers); ++i)
		[_results message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEREND + i lParam:markers[i]];
	[_results message:SCI_SETUNDOCOLLECTION wParam:0];
	[_results message:SCI_SETREADONLY wParam:1];
	[self refreshTheme];
	[self addSubview:caption];
	[self addSubview:_results];
	[NSLayoutConstraint activateConstraints:@[
		[caption.topAnchor constraintEqualToAnchor:self.topAnchor],
		[caption.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[caption.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[_results.topAnchor constraintEqualToAnchor:caption.bottomAnchor],
		[_results.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
		[_results.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[_results.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
	]];
	_keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
		EditorSearchResultsView *view = weakSelf;
		if (view && view.window == event.window &&
			[view.window.firstResponder isKindOfClass:NSView.class] &&
			[(NSView *)view.window.firstResponder isDescendantOf:view->_results])
		{
			if (event.keyCode == 36 || event.keyCode == 76)
			{
				[view openResultAtLine:[view currentLine]];
				return nil;
			}
			if (event.keyCode == 51 || event.keyCode == 117)
			{
				[view removeSelected:nil];
				return nil;
			}
		}
		return event;
	}];
	return self;
}

- (void)dealloc
{
	if (_keyMonitor)
		[NSEvent removeMonitor:_keyMonitor];
	_results.delegate = nil;
}

- (void)refreshTheme
{
	[EditorResources.shared styleSearchResults:_results];
	[_results message:SCI_SETCARETLINEBACK wParam:[_results message:SCI_STYLEGETBACK wParam:6]];
	[_results message:SCI_SETCARETLINEVISIBLE wParam:1];
	for (int marker = SC_MARKNUM_FOLDEREND; marker <= SC_MARKNUM_FOLDEROPEN; ++marker)
	{
		[_results message:SCI_MARKERSETFORE wParam:marker lParam:EditorResources.shared.usesDarkColors ? 0x282828 : 0xffffff];
		[_results message:SCI_MARKERSETBACK wParam:marker lParam:EditorResources.shared.usesDarkColors ? 0xa0a0a0 : 0x727272];
	}
}

- (void)setReports:(NSArray<EditorSearchReport *> *)reports
{
	if (_reports == reports || [_reports isEqualToArray:reports])
		return;
	_reports = [reports copy];
	[_results message:SCI_SETREADONLY wParam:0];
	[_results message:SCI_CLEARALL];
	[_results message:SCI_SHOWLINES wParam:0 lParam:[_results message:SCI_GETLINECOUNT] - 1];
	NSMutableArray *rows = [NSMutableArray array];
	NSMutableData *text = [NSMutableData data];
	struct Span { NSUInteger size; int style; };
	std::vector<Span> styles;
	std::vector<int> levels;
	std::vector<NSUInteger> headingLines;
	auto append = [&](NSString *part, int style) {
		NSData *utf8 = [part dataUsingEncoding:NSUTF8StringEncoding];
		if (utf8.length)
		{
			[text appendData:utf8];
			styles.push_back({utf8.length, style});
		}
	};
	EditorResources *resources = EditorResources.shared;
	for (EditorSearchReport *report in reports)
	{
		headingLines.push_back(rows.count);
		NSString *summary = [NSString localizedStringWithFormat:[resources label:@"results-summary" fallback:@"Search \"%@\" (%lu hits in %lu files of %lu searched)"],
			Inline(report.query), report.hits, report.files.count, report.searchedFiles];
		if (report.skippedFiles)
			summary = [summary stringByAppendingFormat:[resources label:@"results-skipped" fallback:@" · %lu skipped"], report.skippedFiles];
		append([summary stringByAppendingString:@"\n"], 1);
		[rows addObject:report];
		levels.push_back(SC_FOLDLEVELBASE | (report.files.count ? SC_FOLDLEVELHEADERFLAG : 0));
		for (EditorSearchFile *file in report.files)
		{
			NSString *title = [NSString localizedStringWithFormat:[resources label:file.matches.count == 1 ? @"results-file-one" : @"results-file-many"
				fallback:file.matches.count == 1 ? @"  %@ (%lu hit)\n" : @"  %@ (%lu hits)\n"], Inline(file.name), file.matches.count];
			append(title, 2);
			[rows addObject:file];
			levels.push_back((SC_FOLDLEVELBASE + 1) | SC_FOLDLEVELHEADERFLAG);
			for (EditorSearchMatch *match in file.matches)
			{
				append([NSString localizedStringWithFormat:[resources label:@"results-line" fallback:@"\tLine %lu: "], match.line], 3);
				NSRange highlight = match.highlight;
				if (highlight.location <= match.lineText.length && highlight.length <= match.lineText.length - highlight.location)
				{
					append([match.lineText substringToIndex:highlight.location], 0);
					append([match.lineText substringWithRange:highlight], 4);
					append([match.lineText substringFromIndex:NSMaxRange(highlight)], 0);
				}
				else
					append(match.lineText, 0);
				append(@"\n", 0);
				[rows addObject:match];
				levels.push_back(SC_FOLDLEVELBASE + 2);
			}
		}
	}
	_rows = [rows copy];
	if (text.length)
		[_results message:SCI_ADDTEXT wParam:text.length lParam:reinterpret_cast<sptr_t>(text.bytes)];
	[_results message:SCI_STARTSTYLING wParam:0];
	for (const auto &style : styles)
		[_results message:SCI_SETSTYLING wParam:style.size lParam:style.style];
	for (NSUInteger i = 0; i < levels.size(); ++i)
		[_results message:SCI_SETFOLDLEVEL wParam:i lParam:levels[i]];
	[_results message:SCI_GOTOPOS wParam:0];
	for (NSUInteger i = 1; i < headingLines.size(); ++i)
		[_results message:SCI_FOLDLINE wParam:headingLines[i] lParam:SC_FOLDACTION_CONTRACT];
	[_results message:SCI_SETREADONLY wParam:1];
}

- (void)selectMatch:(EditorSearchMatch *)match
{
	NSUInteger line = match ? [_rows indexOfObjectIdenticalTo:match] : NSNotFound;
	if (line == NSNotFound)
		return;
	[_results message:SCI_ENSUREVISIBLE wParam:line];
	[_results message:SCI_GOTOLINE wParam:line];
}

- (NSInteger)currentLine
{
	return [_results message:SCI_LINEFROMPOSITION wParam:[_results message:SCI_GETCURRENTPOS]];
}

- (id)resultAtLine:(NSInteger)line
{
	return line >= 0 && static_cast<NSUInteger>(line) < _rows.count ? _rows[line] : nil;
}

- (void)openResultAtLine:(NSInteger)line
{
	id result = [self resultAtLine:line];
	if ([result isKindOfClass:EditorSearchMatch.class])
		_openMatch(result);
	else if (result)
		[_results message:SCI_TOGGLEFOLD wParam:line];
}

- (void)notification:(SCNotification *)notification
{
	if (notification->nmhdr.code == SCN_DOUBLECLICK && notification->position >= 0)
		[self openResultAtLine:[_results message:SCI_LINEFROMPOSITION wParam:notification->position]];
}

- (NSMenu *)menuForResultEvent:(NSEvent *)event
{
	NSPoint point = [_results.content convertPoint:event.locationInWindow fromView:nil];
	auto position = [_results message:SCI_POSITIONFROMPOINT wParam:point.x lParam:point.y];
	if (position >= 0 && [_results message:SCI_GETSELECTIONEMPTY])
		[_results message:SCI_GOTOPOS wParam:position];
	[self.window makeFirstResponder:_results.content];
	EditorResources *resources = EditorResources.shared;
	NSMenu *menu = [[NSMenu alloc] initWithTitle:[resources label:@"find-result-caption" fallback:@"Search results"]];
	menu.autoenablesItems = NO;
	id result = [self resultAtLine:[self currentLine]];
	auto add = [&](NSString *name, SEL action, BOOL enabled) {
		NSMenuItem *item = [menu addItemWithTitle:name action:action keyEquivalent:@""];
		item.target = self;
		item.enabled = enabled;
		return item;
	};
	add(@"Open Selected Result", @selector(openCurrentResult:), [result isKindOfClass:EditorSearchMatch.class]);
	add([resources label:@"finder-find-in-finder" fallback:@"Find in these search results…"], @selector(refineResults:), _reports.count > 0);
	add([resources label:@"finder-collapse-all" fallback:@"Fold All"], @selector(foldAll:), _rows.count != 0).tag = SC_FOLDACTION_CONTRACT;
	add([resources label:@"finder-uncollapse-all" fallback:@"Unfold All"], @selector(foldAll:), _rows.count != 0).tag = SC_FOLDACTION_EXPAND;
	[menu addItem:NSMenuItem.separatorItem];
	add([resources label:@"finder-copy" fallback:@"Copy Selected Line(s)"], @selector(copyResultLines:), result != nil);
	add([resources label:@"finder-copy-selected-paths" fallback:@"Copy Selected Pathname(s)"], @selector(copyResultPaths:), [self selectedPaths].count != 0);
	add(@"Remove Selected Results", @selector(removeSelected:), result != nil);
	add([resources label:@"finder-clear-all" fallback:@"Clear All"], @selector(clear:), _reports.count > 0);
	[menu addItem:NSMenuItem.separatorItem];
	add([resources label:@"finder-wrap-long-lines" fallback:@"Word Wrap Long Lines"], @selector(toggleWrap:), YES).state = [_results message:SCI_GETWRAPMODE] ?
		NSControlStateValueOn : NSControlStateValueOff;
	add([resources label:@"finder-purge-for-every-search" fallback:@"Purge for every search"], @selector(togglePurge:), YES).state =
		self.purgeForEachSearch ? NSControlStateValueOn : NSControlStateValueOff;
	return menu;
}

- (NSRange)selectedLines
{
	auto start = [_results message:SCI_GETSELECTIONSTART];
	auto end = [_results message:SCI_GETSELECTIONEND];
	auto first = [_results message:SCI_LINEFROMPOSITION wParam:start];
	auto last = [_results message:SCI_LINEFROMPOSITION wParam:end > start ? end - 1 : end];
	return NSMakeRange(first, last - first + 1);
}

- (NSArray<NSString *> *)selectedPaths
{
	NSRange range = [self selectedLines];
	NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
	for (NSUInteger i = range.location; i < MIN(NSMaxRange(range), _rows.count); ++i)
	{
		id object = _rows[i];
		NSString *path = nil;
		if ([object isKindOfClass:EditorSearchFile.class])
			path = ((EditorSearchFile *)object).url.path;
		else if ([object isKindOfClass:EditorSearchMatch.class])
			path = ((EditorSearchMatch *)object).url.path;
		if (path)
			[paths addObject:path];
	}
	return paths.array;
}

- (void)openCurrentResult:(id)sender { [self openResultAtLine:[self currentLine]]; }
- (void)foldAll:(NSMenuItem *)sender { [_results message:SCI_FOLDALL wParam:sender.tag]; }
- (void)clear:(id)sender { if (self.reportsChanged) self.reportsChanged(@[]); }
- (void)dismiss:(id)sender { _dismiss(); }
- (void)refineResults:(id)sender { if (self.refine) self.refine(_reports); }
- (void)togglePurge:(id)sender { if (self.purgeChanged) self.purgeChanged(!self.purgeForEachSearch); }

- (void)removeSelected:(id)sender
{
	NSRange lines = NSIntersectionRange([self selectedLines], NSMakeRange(0, _rows.count));
	if (lines.length && self.reportsChanged)
	{
		self.reportsChanged(SearchReportsRemovingRows(_reports, [NSSet setWithArray:[_rows subarrayWithRange:lines]]));
		if (_rows.count)
			[_results message:SCI_GOTOLINE wParam:MIN(lines.location, _rows.count - 1)];
	}
}

- (void)copyResultLines:(id)sender
{
	NSRange range = [self selectedLines];
	auto start = [_results message:SCI_POSITIONFROMLINE wParam:range.location];
	auto end = [_results message:SCI_GETLINEENDPOSITION wParam:NSMaxRange(range) - 1];
	const auto *bytes = reinterpret_cast<const char *>([_results message:SCI_GETCHARACTERPOINTER]);
	if (bytes && end > start)
		EditorCopyText([[NSString alloc] initWithBytes:bytes + start length:end - start encoding:NSUTF8StringEncoding]);
}

- (void)copyResultPaths:(id)sender { EditorCopyText([[self selectedPaths] componentsJoinedByString:@"\n"]); }

- (void)toggleWrap:(id)sender
{
	[_results message:SCI_SETWRAPMODE wParam:[_results message:SCI_GETWRAPMODE] ? SC_WRAP_NONE : SC_WRAP_WORD];
}
@end

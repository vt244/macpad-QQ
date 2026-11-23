// SPDX-License-Identifier: GPL-3.0-only
#import "EditorEditActions.h"
#import "EditorResources.h"
#import "EditorContextMenus.h"
#import "ScintillaView.h"

#include <algorithm>
#include <charconv>
#include <random>
#include <vector>

static void Replace(ScintillaView *editor, sptr_t start, sptr_t end, NSString *text)
{
	NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
	[editor message:SCI_SETTARGETRANGE wParam:start lParam:end];
	[editor message:SCI_REPLACETARGET wParam:bytes.length lParam:reinterpret_cast<sptr_t>(bytes.bytes ?: "")];
}

struct ColumnRange { sptr_t start, end, spaces; };

static std::vector<ColumnRange> ColumnRanges(ScintillaView *editor)
{
	std::vector<ColumnRange> columns;
	const auto count = [editor message:SCI_GETSELECTIONS];
	if (count > 1 || [editor message:SCI_SELECTIONISRECTANGLE])
	{
		for (sptr_t i = 0; i < count; ++i)
			columns.push_back({[editor message:SCI_GETSELECTIONNSTART wParam:i],
				[editor message:SCI_GETSELECTIONNEND wParam:i], [editor message:SCI_GETSELECTIONNSTARTVIRTUALSPACE wParam:i]});
		std::sort(columns.begin(), columns.end(), [](ColumnRange a, ColumnRange b) { return a.start < b.start; });
	}
	else
	{
		const auto caret = [editor message:SCI_GETCURRENTPOS];
		const auto column = [editor message:SCI_GETCOLUMN wParam:caret];
		const auto first = [editor message:SCI_LINEFROMPOSITION wParam:caret];
		const auto end = [editor message:SCI_GETLINECOUNT];
		for (sptr_t line = first; line < end; ++line)
		{
			const auto point = [editor message:SCI_FINDCOLUMN wParam:line lParam:column];
			columns.push_back({point, point, MAX(0, column - [editor message:SCI_GETCOLUMN wParam:point])});
		}
	}
	return columns;
}

static void ApplyColumn(ScintillaView *editor, const std::vector<ColumnRange> &columns, NSArray<NSString *> *values)
{
	[editor message:SCI_BEGINUNDOACTION];
	for (NSUInteger i = columns.size(); i > 0; --i)
	{
		const auto column = columns[i - 1];
		NSString *padding = [@"" stringByPaddingToLength:column.spaces withString:@" " startingAtIndex:0];
		Replace(editor, column.start, column.end, [padding stringByAppendingString:values[i - 1]]);
	}
	[editor message:SCI_ENDUNDOACTION];
}

void EditorInsertColumnText(ScintillaView *editor, NSString *text)
{
	const auto columns = ColumnRanges(editor);
	NSMutableArray<NSString *> *values = [NSMutableArray arrayWithCapacity:columns.size()];
	for (size_t i = 0; i < columns.size(); ++i)
		[values addObject:text];
	ApplyColumn(editor, columns, values);
}

static NSTextField *ColumnField(NSView *controls, NSString *name, NSString *value, CGFloat y, CGFloat labelWidth)
{
	NSTextField *label = [NSTextField labelWithString:name];
	label.frame = NSMakeRect(0, y + 2, labelWidth, 21);
	[controls addSubview:label];
	NSTextField *field = [NSTextField textFieldWithString:value];
	[field setAccessibilityLabel:name];
	field.frame = NSMakeRect(labelWidth + 10, y, NSWidth(controls.bounds) - labelWidth - 10, 24);
	[controls addSubview:field];
	return field;
}

static bool ParseNumber(NSString *value, int base, int64_t &result)
{
	const char *input = value.UTF8String;
	const char *end = input + strlen(input);
	auto parsed = std::from_chars(input, end, result, base);
	return parsed.ec == std::errc{} && parsed.ptr == end;
}

void EditorShowColumnDialog(ScintillaView *editor)
{
	if (!editor || [editor message:SCI_GETREADONLY])
		return;
	NSAlert *alert = [NSAlert new];
	auto label = ^NSString *(NSString *key, NSString *fallback) {
		return [EditorResources.shared label:[@"ColumnEditor:" stringByAppendingString:key] fallback:fallback];
	};
	alert.messageText = label(@"title", @"Column Editor");
	[alert addButtonWithTitle:EditorUIString(@"Insert")];
	[alert addButtonWithTitle:EditorUIString(@"Cancel")];
	NSArray<NSString *> *labels = @[label(@"2023", @"Text to insert"), label(@"2030", @"Initial number"),
		label(@"2031", @"Increase by"), label(@"2036", @"Repeat each")];
	CGFloat labelWidth = 140;
	for (NSString *title in labels)
		labelWidth = MAX(labelWidth, ceil([NSTextField labelWithString:title].fittingSize.width));
	NSButton *zeros = [NSButton checkboxWithTitle:EditorUIString(@"Leading zeros") target:nil action:nullptr];
	CGFloat width = MAX(labelWidth + 200, ceil(zeros.fittingSize.width) + 182);
	NSView *controls = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 194)];
	NSSegmentedControl *mode = [NSSegmentedControl segmentedControlWithLabels:@[label(@"2023", @"Text"), label(@"2033", @"Numbers")]
		trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nullptr];
	mode.selectedSegment = 0;
	mode.frame = NSMakeRect(0, 166, width, 24);
	[controls addSubview:mode];
	NSTextField *text = ColumnField(controls, labels[0], @"", 134, labelWidth);
	NSTextField *initial = ColumnField(controls, labels[1], @"1", 102, labelWidth);
	NSTextField *step = ColumnField(controls, labels[2], @"1", 72, labelWidth);
	NSTextField *repeat = ColumnField(controls, labels[3], @"1", 42, labelWidth);
	NSPopUpButton *format = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 8, 160, 25) pullsDown:NO];
	[format addItemsWithTitles:@[label(@"2024", @"Decimal"), label(@"2026", @"Hexadecimal"),
		label(@"2025", @"Octal"), label(@"2027", @"Binary")]];
	[controls addSubview:format];
	zeros.frame = NSMakeRect(172, 8, width - 172, 25);
	[controls addSubview:zeros];
	alert.accessoryView = controls;
	alert.window.initialFirstResponder = text;
	auto columns = ColumnRanges(editor);
	NSMutableArray<NSString *> *values = [NSMutableArray arrayWithCapacity:columns.size()];
	while ([alert runModal] == NSAlertFirstButtonReturn)
	{
		if (!mode.selectedSegment)
		{
			EditorInsertColumnText(editor, text.stringValue);
			return;
		}
		const int bases[] = {10, 16, 8, 2};
		const int base = bases[format.indexOfSelectedItem];
		int64_t first = 0, increment = 0, repetitions = 0;
		BOOL valid = ParseNumber(initial.stringValue, base, first) && ParseNumber(step.stringValue, base, increment) &&
			ParseNumber(repeat.stringValue, 10, repetitions) && repetitions > 0;
		NSUInteger width = 0;
		if (valid)
			for (size_t i = 0; i < columns.size(); ++i)
			{
				int64_t offset, value;
				if (__builtin_mul_overflow(static_cast<int64_t>(i / repetitions), increment, &offset) ||
					__builtin_add_overflow(first, offset, &value))
				{
					valid = NO;
					break;
				}
				char digits[70];
				auto end = std::to_chars(digits, digits + sizeof digits, value, base).ptr;
				NSString *entry = [[[NSString alloc] initWithBytes:digits length:end - digits encoding:NSASCIIStringEncoding] uppercaseString];
				width = MAX(width, entry.length);
				[values addObject:entry];
			}
		if (valid)
		{
			if (zeros.state == NSControlStateValueOn)
				for (NSUInteger i = 0; i < values.count; ++i)
				{
					NSString *value = values[i];
					NSString *padding = [@"" stringByPaddingToLength:width - value.length withString:@"0" startingAtIndex:0];
					values[i] = [value hasPrefix:@"-"] ? [NSString stringWithFormat:@"-%@%@", padding, [value substringFromIndex:1]] :
						[padding stringByAppendingString:value];
				}
			break;
		}
		[values removeAllObjects];
		alert.informativeText = EditorUIString(@"Enter valid numbers in the chosen base and a positive decimal repeat count.");
	}
	if (values.count != columns.size() || !values.count)
		return;
	ApplyColumn(editor, columns, values);
}

void EditorAddMatchingSelections(ScintillaView *editor, NSInteger command)
{
	const BOOL each = command < 42094;
	NSInteger options = (command - 42090) % 4;
	NSInteger flags = (options & 1 ? SCFIND_MATCHCASE : 0) | (options & 2 ? SCFIND_WHOLEWORD : 0);
	[editor message:SCI_SETSEARCHFLAGS wParam:flags];
	[editor message:SCI_TARGETWHOLEDOCUMENT];
	const unsigned action = each ? SCI_MULTIPLESELECTADDEACH : SCI_MULTIPLESELECTADDNEXT;
	if ([editor message:SCI_GETSELECTIONEMPTY])
		[editor message:action];
	if (![editor message:SCI_GETSELECTIONEMPTY])
		[editor message:action];
}

static bool HasPrefix(ScintillaView *editor, sptr_t position, NSString *prefix)
{
	const auto length = [prefix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	const auto *bytes = reinterpret_cast<const char *>([editor message:SCI_GETCHARACTERPOINTER]);
	return length && position >= 0 && position + length <= [editor message:SCI_GETLENGTH] &&
		!memcmp(bytes + position, prefix.UTF8String, length);
}

void EditorCommentSelection(ScintillaView *editor, NSInteger command, NSString *linePrefix, NSString *blockStart, NSString *blockEnd)
{
	if ([editor message:SCI_GETREADONLY])
		return;
	const auto start = [editor message:SCI_GETSELECTIONSTART];
	const auto end = [editor message:SCI_GETSELECTIONEND];
	if (command == 42023 || command == 42047)
	{
		if (!blockStart.length || !blockEnd.length)
			return;
		const auto left = [blockStart lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
		const auto right = [blockEnd lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
		[editor message:SCI_BEGINUNDOACTION];
		if (command == 42023)
		{
			Replace(editor, end, end, blockEnd);
			Replace(editor, start, start, blockStart);
			[editor message:SCI_SETSEL wParam:start + left lParam:end + left];
		}
		else if (end - start >= left + right && HasPrefix(editor, start, blockStart) && HasPrefix(editor, end - right, blockEnd))
		{
			Replace(editor, end - right, end, @"");
			Replace(editor, start, start + left, @"");
			[editor message:SCI_SETSEL wParam:start lParam:end - left - right];
		}
		else if (start >= left && HasPrefix(editor, start - left, blockStart) && HasPrefix(editor, end, blockEnd))
		{
			Replace(editor, end, end + right, @"");
			Replace(editor, start - left, start, @"");
			[editor message:SCI_SETSEL wParam:start - left lParam:end - left];
		}
		[editor message:SCI_ENDUNDOACTION];
		return;
	}
	if (!linePrefix.length)
		return;
	const auto first = [editor message:SCI_LINEFROMPOSITION wParam:start];
	const auto last = [editor message:SCI_LINEFROMPOSITION wParam:end > start ? end - 1 : end];
	BOOL remove = command == 42036;
	if (command == 42022)
	{
		remove = YES;
		for (auto line = first; line <= last; ++line)
			if (!HasPrefix(editor, [editor message:SCI_GETLINEINDENTPOSITION wParam:line], linePrefix))
				remove = NO;
	}
	const auto prefixLength = [linePrefix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	[editor message:SCI_BEGINUNDOACTION];
	for (auto line = last; line >= first; --line)
	{
		auto position = [editor message:SCI_GETLINEINDENTPOSITION wParam:line];
		BOOL hasPrefix = HasPrefix(editor, position, linePrefix);
		if (!remove && !hasPrefix)
			Replace(editor, position, position, [linePrefix stringByAppendingString:@" "]);
		else if (remove && hasPrefix)
		{
			auto suffix = position + prefixLength;
			if ([editor message:SCI_GETCHARAT wParam:suffix] == ' ')
				++suffix;
			Replace(editor, position, suffix, @"");
		}
	}
	[editor message:SCI_ENDUNDOACTION];
}

static NSString *StringAt(ScintillaView *editor, sptr_t start, sptr_t end)
{
	const char *bytes = reinterpret_cast<const char *>([editor message:SCI_GETCHARACTERPOINTER]);
	return end > start ? ([[NSString alloc] initWithBytes:bytes + start length:end - start encoding:NSUTF8StringEncoding] ?: @"") : @"";
}

void EditorReorderLines(ScintillaView *editor, NSInteger command)
{
	if ([editor message:SCI_GETREADONLY])
		return;
	const auto start = [editor message:SCI_GETSELECTIONSTART];
	const auto end = [editor message:SCI_GETSELECTIONEND];
	const bool selection = start != end;
	const auto first = selection ? [editor message:SCI_LINEFROMPOSITION wParam:start] : 0;
	auto last = selection ? [editor message:SCI_LINEFROMPOSITION wParam:end - 1] : [editor message:SCI_GETLINECOUNT] - 1;
	const auto length = [editor message:SCI_GETLENGTH];
	if (last > first && [editor message:SCI_POSITIONFROMLINE wParam:last] == length)
		--last;
	if (last <= first)
		return;

	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	NSMutableArray<NSString *> *separators = [NSMutableArray array];
	for (auto line = first; line <= last; ++line)
	{
		const auto position = [editor message:SCI_POSITIONFROMLINE wParam:line];
		const auto lineEnd = [editor message:SCI_GETLINEENDPOSITION wParam:line];
		[lines addObject:StringAt(editor, position, lineEnd)];
		if (line < last)
			[separators addObject:StringAt(editor, lineEnd, [editor message:SCI_POSITIONFROMLINE wParam:line + 1])];
	}
	if (command == 42077 || command == 42079)
	{
		NSMutableSet<NSString *> *seen = [NSMutableSet set];
		NSMutableArray<NSString *> *unique = [NSMutableArray array];
		for (NSString *line in lines)
		{
			BOOL duplicate = command == 42077 ? [line isEqualToString:unique.lastObject] : [seen containsObject:line];
			if (!duplicate)
				[unique addObject:line];
			[seen addObject:line];
		}
		lines = unique;
	}
	else if (command == 42083)
		lines = [[lines.reverseObjectEnumerator allObjects] mutableCopy];
	else if (command == 42078)
	{
		std::mt19937 random(std::random_device{}());
		for (NSUInteger i = lines.count - 1; i > 0; --i)
			[lines exchangeObjectAtIndex:i withObjectAtIndex:std::uniform_int_distribution<NSUInteger>(0, i)(random)];
	}
	else
	{
		const BOOL descending = command == 42060 || command == 42062 || command == 42064 || command == 42066 ||
			command == 42081 || command == 42101 || command == 42105;
		NSMutableDictionary<NSString *, NSDecimalNumber *> *numbers = nil;
		if (command >= 42061 && command <= 42066)
		{
			numbers = [NSMutableDictionary dictionary];
			NSString *decimal = (command == 42063 || command == 42064) ? @"," : @".";
			for (NSString *line in lines)
			{
				NSScanner *scanner = [NSScanner scannerWithString:line];
				scanner.locale = @{NSLocaleDecimalSeparator: decimal};
				NSDecimal number;
				if ([scanner scanDecimal:&number] && scanner.isAtEnd &&
					(command >= 42063 || [line rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@".,"]].location == NSNotFound))
					numbers[line] = [NSDecimalNumber decimalNumberWithDecimal:number];
			}
		}
		[lines sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSString *a, NSString *b) {
			NSComparisonResult result;
			if (numbers)
			{
				NSDecimalNumber *left = numbers[a], *right = numbers[b];
				result = left && right ? [left compare:right] : left ? NSOrderedDescending : right ? NSOrderedAscending : NSOrderedSame;
			}
			else if (command == 42104 || command == 42105)
				result = a.length == b.length ? NSOrderedSame : a.length < b.length ? NSOrderedAscending : NSOrderedDescending;
			else if (command == 42100 || command == 42101)
				result = [a localizedCompare:b];
			else
				result = [a compare:b options:command == 42080 || command == 42081 ? NSCaseInsensitiveSearch : NSLiteralSearch];
			return descending ? static_cast<NSComparisonResult>(-result) : result;
		}];
	}
	NSMutableString *output = [NSMutableString string];
	for (NSUInteger i = 0; i < lines.count; ++i)
	{
		if (i)
			[output appendString:separators[i - 1]];
		[output appendString:lines[i]];
	}
	const auto rangeStart = [editor message:SCI_POSITIONFROMLINE wParam:first];
	const auto rangeEnd = [editor message:SCI_GETLINEENDPOSITION wParam:last];
	if ([output isEqualToString:StringAt(editor, rangeStart, rangeEnd)])
		return;
	[editor message:SCI_BEGINUNDOACTION];
	Replace(editor, rangeStart, rangeEnd, output);
	[editor message:SCI_ENDUNDOACTION];
	if (selection)
		[editor message:SCI_SETSEL wParam:rangeStart lParam:rangeStart + [output lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
}

void EditorBookmarkLines(ScintillaView *editor, NSInteger command, int marker)
{
	const auto count = [editor message:SCI_GETLINECOUNT];
	auto bookmarked = [&](sptr_t line) { return ([editor message:SCI_MARKERGET wParam:line] & (1 << marker)) != 0; };
	if (command == 43050)
	{
		for (sptr_t line = 0; line < count; ++line)
			[editor message:bookmarked(line) ? SCI_MARKERDELETE : SCI_MARKERADD wParam:line lParam:marker];
		return;
	}
	if (command == 43018 || command == 43019)
	{
		NSMutableString *text = [NSMutableString string];
		for (sptr_t line = 0; line < count; ++line)
			if (bookmarked(line))
			{
				auto start = [editor message:SCI_POSITIONFROMLINE wParam:line];
				[text appendString:StringAt(editor, start, start + [editor message:SCI_LINELENGTH wParam:line])];
			}
		EditorCopyText(text);
		if (command == 43019)
			return;
	}
	if ([editor message:SCI_GETREADONLY])
		return;
	NSString *clipboard = command == 43020 ? [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] : nil;
	if (command == 43020 && !clipboard)
		return;
	[editor message:SCI_BEGINUNDOACTION];
	for (sptr_t line = count - 1; line >= 0; --line)
	{
		const BOOL marked = bookmarked(line);
		if (marked == (command == 43051))
			continue;
		const auto start = [editor message:SCI_POSITIONFROMLINE wParam:line];
		if (clipboard)
			Replace(editor, start, [editor message:SCI_GETLINEENDPOSITION wParam:line], clipboard);
		else
		{
			[editor message:SCI_MARKERDELETE wParam:line lParam:marker];
			Replace(editor, start, start + [editor message:SCI_LINELENGTH wParam:line], @"");
		}
	}
	[editor message:SCI_ENDUNDOACTION];
}

void EditorNavigateChanges(ScintillaView *editor, NSInteger command)
{
	if (command == 43069)
	{
		const auto flags = [editor message:SCI_GETCHANGEHISTORY];
		[editor message:SCI_EMPTYUNDOBUFFER];
		[editor message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_DISABLED];
		[editor message:SCI_SETCHANGEHISTORY wParam:flags];
		return;
	}
	constexpr int mask = (1 << SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN) | (1 << SC_MARKNUM_HISTORY_SAVED) |
		(1 << SC_MARKNUM_HISTORY_MODIFIED) | (1 << SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED);
	const BOOL forward = command == 43067;
	const auto count = [editor message:SCI_GETLINECOUNT];
	const auto line = [editor message:SCI_LINEFROMPOSITION wParam:[editor message:SCI_GETCURRENTPOS]];
	auto boundary = line;
	while (boundary >= 0 && boundary < count && ([editor message:SCI_MARKERGET wParam:boundary] & mask))
		boundary += forward ? 1 : -1;
	const unsigned search = forward ? SCI_MARKERNEXT : SCI_MARKERPREVIOUS;
	auto next = boundary >= 0 && boundary < count ? [editor message:search wParam:boundary lParam:mask] : -1;
	if (next < 0)
		next = [editor message:search wParam:forward ? 0 : count - 1 lParam:mask];
	if (next >= 0)
	{
		[editor message:SCI_ENSUREVISIBLE wParam:next];
		[editor message:SCI_GOTOLINE wParam:next];
		[editor message:SCI_SCROLLCARET];
	}
}

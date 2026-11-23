// SPDX-License-Identifier: GPL-3.0-only
#import "EditorPrinting.h"
#import "EditorDocument.h"
#import "EditorResources.h"
#import "ScintillaView.h"

@interface EditorPrintView : NSTextView
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *variables;
@property(nonatomic) CGFloat printWidth;
@property(nonatomic, copy) NSIndexSet *pageBreaks;
@end

@implementation EditorPrintView
{
	NSArray<NSValue *> *_pages;
}

- (NSAttributedString *)pageText:(NSString *)kind
{
	NSMutableArray *parts = [NSMutableArray array];
	for (NSString *side in @[@"Left", @"Middle", @"Right"])
	{
		NSString *key = [NSString stringWithFormat:@"print%@%@", kind, side];
		NSString *text = [EditorResources.shared setting:key fallback:@""];
		for (NSString *name in self.variables)
			text = [text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"$(%@)", name]
				withString:self.variables[name]];
		text = [text stringByReplacingOccurrencesOfString:@"$(CURRENT_PRINTING_PAGE)"
			withString:[@(NSPrintOperation.currentOperation.currentPage) stringValue]];
		[parts addObject:text];
	}
	if (![[parts componentsJoinedByString:@""] length])
		return nil;
	NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
	paragraph.tabStops = @[
		[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentCenter location:self.printWidth / 2 options:@{}],
		[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:self.printWidth options:@{}],
	];
	EditorResources *resources = EditorResources.shared;
	NSString *family = [resources setting:[NSString stringWithFormat:@"print%@FontName", kind] fallback:@""];
	CGFloat pointSize = [[resources setting:[NSString stringWithFormat:@"print%@FontSize", kind] fallback:@9] doubleValue];
	CGFloat size = MAX(1, MIN(72, pointSize));
	NSFont *font = family.length ? [NSFont fontWithName:family size:size] : nil;
	font = font ?: [NSFont systemFontOfSize:size];
	NSInteger style = [[resources setting:[NSString stringWithFormat:@"print%@FontStyle", kind] fallback:@0] integerValue];
	NSFontTraitMask traits = (style & 1 ? NSBoldFontMask : 0) | (style & 2 ? NSItalicFontMask : 0);
	if (traits)
		font = [NSFontManager.sharedFontManager convertFont:font toHaveTrait:traits] ?: font;
	return [[NSAttributedString alloc] initWithString:[parts componentsJoinedByString:@"\t"]
		attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.blackColor,
			NSParagraphStyleAttributeName: paragraph}];
}

- (NSAttributedString *)pageHeader { return [self pageText:@"Header"]; }
- (NSAttributedString *)pageFooter { return [self pageText:@"Footer"]; }

- (BOOL)knowsPageRange:(NSRangePointer)range
{
	if (!self.pageBreaks.count)
		return [super knowsPageRange:range];
	NSPrintInfo *info = NSPrintOperation.currentOperation.printInfo;
	CGFloat height = MAX(24, info.paperSize.height - info.topMargin - info.bottomMargin);
	NSLayoutManager *layout = self.layoutManager;
	[layout ensureLayoutForTextContainer:self.textContainer];
	const NSUInteger count = layout.numberOfGlyphs;
	NSRange glyphs = NSMakeRange(0, count);
	NSMutableArray<NSNumber *> *lineStarts = [NSMutableArray arrayWithObject:@0];
	[layout enumerateLineFragmentsForGlyphRange:glyphs usingBlock:^(NSRect rect, NSRect used, NSTextContainer *container, NSRange line, BOOL *stop) {
		if (rect.origin.y > lineStarts.lastObject.doubleValue)
			[lineStarts addObject:@(rect.origin.y)];
	}];
	NSMutableIndexSet *forced = [NSMutableIndexSet indexSet];
	[self.pageBreaks enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
		if (index < self.string.length)
			[forced addIndex:[layout glyphIndexForCharacterAtIndex:index]];
	}];
	NSMutableSet<NSNumber *> *boundaries = [NSMutableSet set];
	[forced enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
		if (index < count)
			[boundaries addObject:@([layout lineFragmentRectForGlyphAtIndex:index effectiveRange:nullptr].origin.y)];
	}];
	NSMutableArray *pages = [NSMutableArray array];
	CGFloat start = 0;
	CGFloat previous = 0;
	auto addPage = ^(CGFloat from, CGFloat to) {
		[pages addObject:[NSValue valueWithRect:NSMakeRect(0, from, self.printWidth, MAX(1, to - from))]];
	};
	for (NSNumber *entry in lineStarts)
	{
		CGFloat y = entry.doubleValue;
		if (y > start && [boundaries containsObject:entry])
		{
			addPage(start, y);
			start = y;
		}
		else if (y - start > height)
		{
			CGFloat edge = previous > start ? previous : y;
			addPage(start, edge);
			start = edge;
		}
		previous = y;
	}
	addPage(start, MAX(start + 1, NSMaxY([layout usedRectForTextContainer:self.textContainer])));
	_pages = [pages copy];
	*range = NSMakeRange(1, _pages.count);
	return YES;
}

- (NSRect)rectForPage:(NSInteger)page
{
	if (_pages && page > 0 && page <= (NSInteger)_pages.count)
		return _pages[page - 1].rectValue;
	return [super rectForPage:page];
}

@end

static NSColor *PrintColor(sptr_t color, BOOL invert)
{
	const auto rgb = static_cast<unsigned>(color) ^ (invert ? 0xffffff : 0);
	return [NSColor colorWithSRGBRed:(rgb & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0
		blue:((rgb >> 16) & 255) / 255.0 alpha:1];
}

static NSAttributedString *PrintText(ScintillaView *editor, NSInteger mode, BOOL numbers)
{
	const auto length = [editor message:SCI_GETLENGTH];
	[editor message:SCI_COLOURISE wParam:0 lParam:-1];
	const auto *bytes = reinterpret_cast<const char *>([editor message:SCI_GETCHARACTERPOINTER]);
	NSMutableAttributedString *result = [NSMutableAttributedString new];
	NSFont *font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
	NSDictionary *plain = @{NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.blackColor};
	NSMutableDictionary<NSNumber *, NSDictionary *> *styles = [NSMutableDictionary dictionary];
	const auto lines = [editor message:SCI_GETLINECOUNT];
	const NSUInteger digits = [@(lines) stringValue].length;
	for (sptr_t line = 0; line < lines; ++line)
	{
		const auto start = [editor message:SCI_POSITIONFROMLINE wParam:line];
		const auto end = line + 1 < lines ? [editor message:SCI_POSITIONFROMLINE wParam:line + 1] : length;
		if (numbers)
			[result appendAttributedString:[[NSAttributedString alloc]
				initWithString:[NSString stringWithFormat:@"%*ld  ", (int)digits, (long)line + 1] attributes:plain]];
		for (sptr_t position = start; position < end;)
		{
			const auto style = mode == SC_PRINT_BLACKONWHITE ? STYLE_DEFAULT : [editor message:SCI_GETSTYLEAT wParam:position];
			auto next = end;
			NSDictionary *attributes = plain;
			if (mode != SC_PRINT_BLACKONWHITE)
			{
				next = [editor message:SCI_POSITIONAFTER wParam:position];
				while (next < end && [editor message:SCI_GETSTYLEAT wParam:next] == style)
					next = [editor message:SCI_POSITIONAFTER wParam:next];
				attributes = styles[@(style)];
				if (!attributes)
				{
					const BOOL invert = mode == SC_PRINT_INVERTLIGHT;
					NSFont *styleFont = [NSFont monospacedSystemFontOfSize:10
						weight:[editor message:SCI_STYLEGETBOLD wParam:style] ? NSFontWeightBold : NSFontWeightRegular];
					if ([editor message:SCI_STYLEGETITALIC wParam:style])
						styleFont = [NSFontManager.sharedFontManager convertFont:styleFont toHaveTrait:NSItalicFontMask] ?: styleFont;
					NSMutableDictionary *format = [@{NSFontAttributeName: styleFont,
						NSForegroundColorAttributeName: PrintColor([editor message:SCI_STYLEGETFORE wParam:style], invert)} mutableCopy];
					if (mode != SC_PRINT_COLOURONWHITE)
						format[NSBackgroundColorAttributeName] = PrintColor([editor message:SCI_STYLEGETBACK wParam:style], invert);
					if ([editor message:SCI_STYLEGETUNDERLINE wParam:style])
						format[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
					attributes = styles[@(style)] = [format copy];
				}
			}
			NSString *text = [[NSString alloc] initWithBytes:bytes + position length:next - position encoding:NSUTF8StringEncoding];
			if (text)
				[result appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
			position = next;
		}
	}
	return result;
}

NSPrintOperation *EditorPrintOperation(EditorDocument *document, NSDictionary *settings)
{
	EditorResources *resources = EditorResources.shared;
	NSPrintInfo *info = [document.printInfo copy];
	[info.dictionary addEntriesFromDictionary:settings ?: @{}];
	info.dictionary[NSPrintHeaderAndFooter] = @YES;
	auto margin = ^CGFloat(NSString *key, CGFloat fallback, CGFloat maximum) {
		NSNumber *value = [resources setting:key fallback:nil];
		return value ? MIN(maximum / 3, MAX(0, value.doubleValue) * 72 / 25.4) : fallback;
	};
	info.leftMargin = margin(@"printMarginLeft", info.leftMargin, info.paperSize.width);
	info.rightMargin = margin(@"printMarginRight", info.rightMargin, info.paperSize.width);
	info.topMargin = margin(@"printMarginTop", info.topMargin, info.paperSize.height);
	info.bottomMargin = margin(@"printMarginBottom", info.bottomMargin, info.paperSize.height);
	CGFloat width = MAX(72, info.paperSize.width - info.leftMargin - info.rightMargin);
	EditorPrintView *view = [[EditorPrintView alloc] initWithFrame:NSMakeRect(0, 0, width, 100)];
	view.printWidth = width;
	view.verticallyResizable = YES;
	view.textContainer.widthTracksTextView = YES;
	view.textContainer.lineFragmentPadding = 0;
	view.variables = @{
		@"FULL_CURRENT_PATH": document.fileURL.path ?: @"", @"FILE_NAME": document.displayName ?: @"",
		@"CURRENT_DIRECTORY": document.fileURL.URLByDeletingLastPathComponent.path ?: @"",
		@"SHORT_DATE": [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterNoStyle],
		@"LONG_DATE": [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterLongStyle timeStyle:NSDateFormatterNoStyle],
		@"TIME": [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle],
	};
	NSInteger mode = [[resources setting:@"printColorMode" fallback:@(SC_PRINT_BLACKONWHITE)] integerValue];
	NSAttributedString *printed = PrintText(document.editor, mode, [[resources setting:@"printLineNumbers" fallback:@NO] boolValue]);
	if ([[resources setting:@"printFormFeedBreak" fallback:@NO] boolValue])
	{
		NSMutableAttributedString *body = [printed mutableCopy];
		NSString *source = printed.string;
		NSMutableIndexSet *breaks = [NSMutableIndexSet indexSet];
		for (NSUInteger index = 0; index < source.length; ++index)
			if ([source characterAtIndex:index] == '\f')
			{
				const BOOL followsBreak = index && [[NSCharacterSet newlineCharacterSet] characterIsMember:[source characterAtIndex:index - 1]];
				const BOOL beforeBreak = index + 1 < source.length &&
					[[NSCharacterSet newlineCharacterSet] characterIsMember:[source characterAtIndex:index + 1]];
				[body replaceCharactersInRange:NSMakeRange(index, 1) withString:followsBreak || beforeBreak ? @"\u200b" : @"\n"];
				NSUInteger next = index + (followsBreak ? 0 : 1);
				while (next < source.length && ([source characterAtIndex:next] == '\r' || [source characterAtIndex:next] == '\n'))
					++next;
				if (next < source.length)
					[breaks addIndex:next];
			}
		view.pageBreaks = breaks;
		printed = body;
	}
	[view.textStorage setAttributedString:printed];
	[view.layoutManager ensureLayoutForTextContainer:view.textContainer];
	[view sizeToFit];
	return [NSPrintOperation printOperationWithView:view printInfo:info];
}

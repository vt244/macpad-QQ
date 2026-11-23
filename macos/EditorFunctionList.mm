// SPDX-License-Identifier: GPL-3.0-only
#import "EditorFunctionList.h"
#import "EditorPanelChrome.h"
#import "EditorResources.h"
#import "EditorSearchBuffer.h"

#include "pugiconfig.hpp"
#undef PUGIXML_CHARCONV_FLOAT
#include "pugixml.hpp"
#include <algorithm>
#include <string>
#include <vector>

@interface EditorFunction ()
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *group;
@property(nonatomic) NSUInteger bytePosition;
@end
@implementation EditorFunction
@end

namespace
{
class FunctionReader
{
	NSData *source;
	NSProgress *progress;
	std::shared_ptr<Scintilla::Internal::Document> buffer;
	std::vector<NSRange> comments;
	NSMutableArray<EditorFunction *> *functions = [NSMutableArray array];

	NSRange find(const char *expr, NSRange scope) const
	{
		if (progress.cancelled)
			return NSMakeRange(NSNotFound, 0);
		return EditorFindPattern(*buffer, expr, scope);
	}

	// Advance even when a customized XML rule matches an empty string.
	template<class Visit> void each(const char *expr, NSRange scope, Visit visit)
	{
		const NSUInteger end = NSMaxRange(scope);
		while (scope.length)
		{
			NSRange match = find(expr, scope);
			if (match.location == NSNotFound)
				break;
			NSUInteger next = visit(match);
			next = MAX(next, match.location + 1);
			if (next >= end)
				break;
			scope = NSMakeRange(next, end - next);
		}
	}

	bool inComment(NSUInteger position) const
	{
		auto next = std::upper_bound(comments.begin(), comments.end(), position,
			[](NSUInteger point, NSRange zone) { return point < zone.location; });
		return next != comments.begin() && NSLocationInRange(position, *std::prev(next));
	}

	NSRange extract(NSRange range, pugi::xml_node steps) const
	{
		for (auto part : steps.children())
		{
			if (!part.attribute("expr"))
				continue;
			range = find(part.attribute("expr").value(), range);
			if (range.location == NSNotFound)
				break;
		}
		return range;
	}

	NSString *text(NSRange range) const
	{
		if (range.location == NSNotFound || !range.length)
			return @"";
		const char *start = static_cast<const char *>(source.bytes) + range.location;
		NSString *value = [[NSString alloc] initWithBytes:start length:range.length encoding:NSUTF8StringEncoding];
		return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
	}

	void readFunctions(pugi::xml_node rule, NSRange scope, NSString *className)
	{
		each(rule.attribute("mainExpr").value(), scope, [&](NSRange match) {
			NSRange name = extract(match, rule.child("functionName"));
			NSRange group = extract(match, rule.child("className"));
			NSString *title = text(name);
			if (title.length && !inComment(name.location) && !inComment(match.location))
			{
				EditorFunction *function = [EditorFunction new];
				function.name = title;
				function.group = className.length ? className : (rule.child("className") ? text(group) : @"");
				function.bytePosition = name.location;
				[functions addObject:function];
			}
			return NSMaxRange(match);
		});
	}

	NSUInteger bodyEnd(pugi::xml_node rule, NSUInteger start, NSUInteger end)
	{
		const char *open = rule.attribute("openSymbole").value();
		const char *close = rule.attribute("closeSymbole").value();
		if (!*open || !*close || start >= end)
			return start;
		std::string both = std::string("(?:") + open + ")|(?:" + close + ")";
		NSUInteger nesting = 1;
		for (NSUInteger cursor = start; cursor < end;)
		{
			NSRange match = find(both.c_str(), NSMakeRange(cursor, end - cursor));
			if (match.location == NSNotFound)
				break;
			cursor = MAX(NSMaxRange(match), match.location + 1);
			if (inComment(match.location))
				continue;
			if (find(open, match).location != NSNotFound)
				++nesting;
			else if (--nesting == 0)
				return cursor;
		}
		return start;
	}

	std::vector<NSRange> readClasses(pugi::xml_node rule, NSRange scope, NSUInteger depth)
	{
		std::vector<NSRange> classes;
		each(rule.attribute("mainExpr").value(), scope, [&](NSRange match) {
			if (inComment(match.location))
				return NSMaxRange(match);
			const NSUInteger end = bodyEnd(rule, NSMaxRange(match), NSMaxRange(scope));
			NSRange body = NSMakeRange(match.location, end - match.location);
			classes.push_back(body);
			NSString *name = text(extract(match, rule.child("className")));
			if (depth < 8 && end > NSMaxRange(match))
			{
				auto nested = readClasses(rule, NSMakeRange(NSMaxRange(match), end - NSMaxRange(match)), depth + 1);
				NSUInteger start = body.location;
				for (NSRange child : nested)
				{
					readFunctions(rule.child("function"), NSMakeRange(start, child.location - start), name);
					start = NSMaxRange(child);
				}
				readFunctions(rule.child("function"), NSMakeRange(start, end - start), name);
			}
			else
				readFunctions(rule.child("function"), body, name);
			return end;
		});
		return classes;
	}

public:
	FunctionReader(NSData *data, NSProgress *task) : source(data), progress(task), buffer(EditorSearchBuffer(data)) {}

	NSArray<EditorFunction *> *read(pugi::xml_node rule)
	{
		const NSRange all = NSMakeRange(0, source.length);
		each(rule.attribute("commentExpr").value(), all, [&](NSRange range) {
			comments.push_back(range);
			return NSMaxRange(range);
		});
		auto classes = readClasses(rule.child("classRange"), all, 0);
		NSUInteger start = 0;
		for (NSRange range : classes)
		{
			readFunctions(rule.child("function"), NSMakeRange(start, range.location - start), nil);
			start = NSMaxRange(range);
		}
		readFunctions(rule.child("function"), NSMakeRange(start, source.length - start), nil);
		[functions sortUsingComparator:^NSComparisonResult(EditorFunction *a, EditorFunction *b) {
			if (a.bytePosition == b.bytePosition)
				return NSOrderedSame;
			return a.bytePosition < b.bytePosition ? NSOrderedAscending : NSOrderedDescending;
		}];
		return functions;
	}
};
}

static BOOL LoadRules(pugi::xml_document &xml, NSURL *url)
{
	NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
	return data.length && xml.load_buffer(data.bytes, data.length);
}

NSArray<EditorFunction *> *EditorReadFunctions(NSData *utf8, NSURL *rules, NSProgress *progress)
{
	pugi::xml_document xml;
	if (!utf8.length || !LoadRules(xml, rules))
		return @[];
	return FunctionReader(utf8, progress).read(xml.child("NotepadPlus").child("functionList").child("parser"));
}

static NSString *AssociatedRule(NSURL *folder, NSString *language)
{
	// This order is the original public LangType enumeration, used by overrideMap.xml.
	static NSArray<NSString *> *languages = [@"normal php c cpp cs objc java rc html xml makefile pascal batch ini nfo udf "
		"asp sql vb javascript css perl python lua tex fortran bash actionscript nsis tcl lisp scheme asm diff props "
		"postscript ruby smalltalk vhdl kix autoit caml ada verilog matlab haskell inno searchResult cmake yaml cobol "
		"gui4cli d powershell r jsp coffeescript json javascript.js fortran77 baanc srec ihex tehex swift asn1 avs blitzbasic "
		"purebasic freebasic csound erlang escript forth latex mmixal nim nncrontab oscript rebol registry rust spice "
		"txt2tags visualprolog typescript json5 mssql gdscript hollywood go raku toml sas errorlist escseq fcST"
		componentsSeparatedByString:@" "];
	const BOOL udl = [language hasPrefix:@"udl:"];
	const NSUInteger langID = udl ? NSNotFound : [languages indexOfObject:language];
	pugi::xml_document xml;
	if (LoadRules(xml, [folder URLByAppendingPathComponent:@"overrideMap.xml"]))
		for (auto node : xml.child("NotepadPlus").child("functionList").child("associationMap").children("association"))
		{
			NSString *udlName = [NSString stringWithUTF8String:node.attribute("userDefinedLangName").value()];
			if ((udl && [udlName isEqualToString:[language substringFromIndex:4]]) ||
				(!udl && langID != NSNotFound && node.attribute("langID").as_uint(-1) == langID))
			{
				NSString *name = [NSString stringWithUTF8String:node.attribute("id").value()];
				if ([name.pathExtension isEqualToString:@"xml"] && [name isEqualToString:name.lastPathComponent])
					return name;
			}
		}
	return nil;
}

static NSURL *RuleFile(NSURL *profile, NSURL *installed, NSString *language)
{
	NSString *name = AssociatedRule(profile, language) ?: AssociatedRule(installed, language);
	if (!name && ![language hasPrefix:@"udl:"])
		name = [([language isEqualToString:@"javascript"] ? @"javascript.js" : language) stringByAppendingPathExtension:@"xml"];
	if (!name.length)
		return nil;
	NSURL *custom = [profile URLByAppendingPathComponent:name];
	return [NSFileManager.defaultManager fileExistsAtPath:custom.path] ? custom : [installed URLByAppendingPathComponent:name];
}

@interface FunctionGroup : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) NSMutableArray<EditorFunction *> *functions;
@end
@implementation FunctionGroup
@end

@interface EditorFunctionList () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate>
@end

@implementation EditorFunctionList
{
	NSOutlineView *_table;
	NSSearchField *_filter;
	NSArray<EditorFunction *> *_matches;
	NSArray *_visible;
	NSProgress *_task;
	void (^_navigate)(NSUInteger);
	void (^_dismiss)(void);
}

- (instancetype)initWithNavigate:(void (^)(NSUInteger))navigate dismiss:(void (^)(void))dismiss
{
	if (!(self = [super initWithFrame:NSZeroRect]))
		return nil;
	_navigate = [navigate copy];
	_dismiss = [dismiss copy];
	NSView *caption = EditorPanelCaption([EditorResources.shared label:@"FunctionList:PanelTitle" fallback:@"Function List"],
		self, @selector(dismiss:));
	_filter = [[NSSearchField alloc] initWithFrame:NSZeroRect];
	_filter.translatesAutoresizingMaskIntoConstraints = NO;
	_filter.placeholderString = [EditorResources.shared label:@"function-filter" fallback:@"Filter functions"];
	_filter.controlSize = NSControlSizeSmall;
	_filter.delegate = self;
	_table = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
	_table.style = NSTableViewStylePlain;
	_table.headerView = nil;
	_table.rowHeight = 18;
	_table.dataSource = self;
	_table.delegate = self;
	_table.target = self;
	_table.doubleAction = @selector(navigate:);
	[_table setAccessibilityLabel:[EditorResources.shared label:@"FunctionList:PanelTitle" fallback:@"Functions"]];
	NSTableColumn *symbols = [[NSTableColumn alloc] initWithIdentifier:@"Symbol"];
	[_table addTableColumn:symbols];
	_table.outlineTableColumn = symbols;
	_table.indentationPerLevel = 14;
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	scroll.hasVerticalScroller = YES;
	scroll.scrollerStyle = NSScrollerStyleLegacy;
	scroll.autohidesScrollers = YES;
	scroll.documentView = _table;
	[self addSubview:caption];
	[self addSubview:_filter];
	[self addSubview:scroll];
	[NSLayoutConstraint activateConstraints:@[
		[caption.topAnchor constraintEqualToAnchor:self.topAnchor],
		[caption.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[caption.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[_filter.topAnchor constraintEqualToAnchor:caption.bottomAnchor constant:3],
		[_filter.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:3],
		[_filter.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-3],
		[scroll.topAnchor constraintEqualToAnchor:_filter.bottomAnchor constant:3],
		[scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
	]];
	return self;
}

- (void)refreshDockLabels:(NSString *)title
{
	_filter.placeholderString = [EditorResources.shared label:@"function-filter" fallback:@"Filter functions"];
	[_table setAccessibilityLabel:title];
}

- (void)cancel { [_task cancel]; _task = nil; }
- (void)dealloc { [_task cancel]; }

- (void)refresh:(NSData *)utf8 language:(NSString *)language
{
	[self cancel];
	NSProgress *task = [NSProgress progressWithTotalUnitCount:1];
	_task = task;
	NSString *mode = language.length ? language : @"normal";
	NSURL *installed = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"functionList" isDirectory:YES];
	NSURL *profile = [EditorResources.shared.profile URLByAppendingPathComponent:@"functionList" isDirectory:YES];
	__weak EditorFunctionList *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		if (task.cancelled)
			return;
		NSArray *matches = EditorReadFunctions(utf8, RuleFile(profile, installed, mode), task);
		dispatch_async(dispatch_get_main_queue(), ^{
			EditorFunctionList *panel = weakSelf;
			if (panel && panel->_task == task && !task.cancelled)
			{
				panel->_matches = matches;
				[panel applyFilter];
			}
		});
	});
}

- (NSString *)labelFor:(EditorFunction *)function
{
	return function.group.length ? [NSString stringWithFormat:@"%@  ›  %@", function.group, function.name] : function.name;
}

- (void)applyFilter
{
	NSString *filter = _filter.stringValue;
	NSMutableDictionary<NSString *, FunctionGroup *> *groups = [NSMutableDictionary dictionary];
	NSMutableArray *visible = [NSMutableArray array];
	NSMutableSet<NSString *> *collapsed = [NSMutableSet set];
	for (id old in _visible)
		if ([old isKindOfClass:FunctionGroup.class] && ![_table isItemExpanded:old])
			[collapsed addObject:[old name]];
	for (EditorFunction *function in _matches)
	{
		if (filter.length && ![[self labelFor:function] localizedCaseInsensitiveContainsString:filter])
			continue;
		if (!function.group.length)
		{
			[visible addObject:function];
			continue;
		}
		FunctionGroup *group = groups[function.group];
		if (!group)
		{
			group = [FunctionGroup new];
			group.name = function.group;
			group.functions = [NSMutableArray array];
			groups[group.name] = group;
			[visible addObject:group];
		}
		[group.functions addObject:function];
	}
	_visible = visible;
	[_table reloadData];
	for (FunctionGroup *group in groups.allValues)
		if (filter.length || ![collapsed containsObject:group.name])
			[_table expandItem:group];
}

- (void)controlTextDidChange:(NSNotification *)notification { [self applyFilter]; }
- (void)dismiss:(id)sender { _dismiss(); }

- (NSInteger)outlineView:(NSOutlineView *)outline numberOfChildrenOfItem:(FunctionGroup *)item
{
	return !item ? _visible.count : [item isKindOfClass:FunctionGroup.class] ? item.functions.count : 0;
}

- (id)outlineView:(NSOutlineView *)outline child:(NSInteger)index ofItem:(FunctionGroup *)item
{
	return item ? item.functions[index] : _visible[index];
}

- (BOOL)outlineView:(NSOutlineView *)outline isItemExpandable:(id)item
{
	return [item isKindOfClass:FunctionGroup.class];
}

- (NSView *)outlineView:(NSOutlineView *)outline viewForTableColumn:(NSTableColumn *)column item:(id)item
{
	NSTextField *label = [NSTextField labelWithString:[item name]];
	label.font = [item isKindOfClass:FunctionGroup.class] ? [NSFont boldSystemFontOfSize:11] : [NSFont systemFontOfSize:11];
	label.lineBreakMode = NSLineBreakByTruncatingTail;
	return label;
}

- (void)navigate:(id)sender
{
	NSInteger row = _table.clickedRow;
	if (row < 0)
		return;
	id item = [_table itemAtRow:row];
	if ([item isKindOfClass:FunctionGroup.class])
	{
		if ([_table isItemExpanded:item])
			[_table collapseItem:item];
		else
			[_table expandItem:item];
	}
	else if ([item isKindOfClass:EditorFunction.class])
		_navigate([(EditorFunction *)item bytePosition]);
}
@end

// SPDX-License-Identifier: GPL-3.0-only
#import "EditorCompletion.h"
#import "EditorResources.h"
#import "ScintillaView.h"

#include "pugiconfig.hpp"
#undef PUGIXML_CHARCONV_FLOAT
#include "pugixml.hpp"

static NSString *Text(ScintillaView *editor, sptr_t start, sptr_t end)
{
	const char *text = reinterpret_cast<const char *>([editor message:SCI_GETCHARACTERPOINTER]);
	return end > start ? [[NSString alloc] initWithBytes:text + start length:end - start encoding:NSUTF8StringEncoding] : @"";
}

static void ShowChoices(ScintillaView *editor, NSArray<NSString *> *list, NSString *prefix)
{
	NSMutableOrderedSet *choices = [NSMutableOrderedSet orderedSet];
	for (NSString *item in list)
		if (item.length > prefix.length && [item hasPrefix:prefix] &&
			[item rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound)
			[choices addObject:item];
	if (!choices.count)
		return;
	NSString *items = [[choices.array sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"\n"];
	[editor message:SCI_AUTOCSETSEPARATOR wParam:'\n'];
	[editor message:SCI_AUTOCSETTYPESEPARATOR wParam:0];
	[editor message:SCI_AUTOCSETORDER wParam:SC_ORDER_CUSTOM];
	[editor message:SCI_AUTOCSETMAXHEIGHT wParam:10];
	[editor setStringProperty:SCI_AUTOCSHOW parameter:[prefix lengthOfBytesUsingEncoding:NSUTF8StringEncoding] value:items];
}

@implementation EditorCompletion
{
	NSString *_loadedLanguage;
	NSDictionary<NSString *, NSArray<NSString *> *> *_keywords;
	NSArray<NSString *> *_tips;
	NSInteger _tipIndex;
	sptr_t _tipPosition;
}

- (void)loadLanguage:(NSString *)language
{
	if ([_loadedLanguage isEqualToString:language])
		return;
	_loadedLanguage = [language copy];
	language = [language isEqualToString:@"javascript.js"] ? @"javascript" : language;
	if ([language hasPrefix:@"udl:"])
		language = [language substringFromIndex:4];
	_keywords = @{};
	if (!language.length || ![language.lastPathComponent isEqualToString:language])
		return;
	NSURL *path = [[EditorResources.shared.profile URLByAppendingPathComponent:@"autoCompletion"]
		URLByAppendingPathComponent:[language stringByAppendingPathExtension:@"xml"]];
	NSData *data = [NSData dataWithContentsOfURL:path];
	if (!data)
	{
		NSURL *bundled = [NSBundle.mainBundle URLForResource:language withExtension:@"xml" subdirectory:@"autoCompletion"];
		if (bundled)
			data = [NSData dataWithContentsOfURL:bundled];
	}
	pugi::xml_document xml;
	if (!data.length || !xml.load_buffer(data.bytes, data.length))
		return;
	NSMutableDictionary *keywords = [NSMutableDictionary dictionary];
	for (auto keyword : xml.child("NotepadPlus").child("AutoComplete").children("KeyWord"))
	{
		NSString *name = [NSString stringWithUTF8String:keyword.attribute("name").value()];
		if (!name.length)
			continue;
		NSMutableArray *tips = [NSMutableArray array];
		for (auto overload : keyword.children("Overload"))
		{
			NSMutableArray *arguments = [NSMutableArray array];
			for (auto parameter : overload.children("Param"))
			{
				NSString *argument = [NSString stringWithUTF8String:parameter.attribute("name").value()];
				if (argument.length)
					[arguments addObject:argument];
			}
			NSString *returns = [NSString stringWithUTF8String:overload.attribute("retVal").value()];
			NSString *description = [NSString stringWithUTF8String:overload.attribute("descr").value()];
			NSString *signature = [NSString stringWithFormat:@"%@%@%@(%@)", returns ?: @"", returns.length ? @" " : @"",
				name, [arguments componentsJoinedByString:@", "]];
			[tips addObject:description.length ? [NSString stringWithFormat:@"%@\n%@", signature, description] : signature];
		}
		keywords[name] = tips;
	}
	_keywords = keywords;
}

- (NSArray<NSString *> *)words:(ScintillaView *)editor prefix:(NSString *)prefix position:(sptr_t)position
{
	static NSRegularExpression *scanner = [NSRegularExpression
		regularExpressionWithPattern:@"[\\p{L}_][\\p{L}\\p{N}_]*" options:0 error:nullptr];
	const auto start = [editor message:SCI_POSITIONAFTER wParam:MAX(0, position - 100000)];
	const auto end = [editor message:SCI_POSITIONBEFORE wParam:MIN(position + 100000, [editor message:SCI_GETLENGTH])];
	NSString *context = Text(editor, start, end) ?: @"";
	NSMutableOrderedSet *list = [NSMutableOrderedSet orderedSet];
	[scanner enumerateMatchesInString:context options:0 range:NSMakeRange(0, context.length)
		usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
			NSString *word = [context substringWithRange:result.range];
			if (word.length > prefix.length && [word hasPrefix:prefix])
				[list addObject:word];
			*stop = list.count > 500;
		}];
	return list.array;
}

- (void)completePath:(ScintillaView *)editor directory:(NSURL *)directory
{
	const auto caret = [editor message:SCI_GETCURRENTPOS];
	const auto line = [editor message:SCI_LINEFROMPOSITION wParam:caret];
	NSString *text = Text(editor, [editor message:SCI_POSITIONFROMLINE wParam:line], caret);
	NSString *path = [text componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\t\"'<>|"]].lastObject;
	path = [path stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	NSString *prefix = [path hasSuffix:@"/"] ? @"" : path.lastPathComponent ?: @"";
	NSString *parent = [path hasSuffix:@"/"] ? path : path.stringByDeletingLastPathComponent;
	parent = parent.stringByExpandingTildeInPath;
	NSURL *folder = parent.isAbsolutePath ? [NSURL fileURLWithPath:parent isDirectory:YES] :
		[(directory ?: [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES]) URLByAppendingPathComponent:parent ?: @"" isDirectory:YES];
	NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder
		includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:nullptr];
	NSMutableArray *choices = [NSMutableArray array];
	for (NSURL *file in files)
		if ([file.lastPathComponent hasPrefix:prefix])
		{
			NSNumber *isDir = nil;
			[file getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nullptr];
			[choices addObject:isDir.boolValue ? [file.lastPathComponent stringByAppendingString:@"/"] : file.lastPathComponent];
		}
	ShowChoices(editor, choices, prefix);
}

- (void)showTip:(ScintillaView *)editor
{
	if (_tips.count)
		[editor setStringProperty:SCI_CALLTIPSHOW parameter:_tipPosition value:_tips[_tipIndex]];
}

- (void)functionTip:(ScintillaView *)editor
{
	const auto caret = [editor message:SCI_GETCURRENTPOS];
	auto position = caret;
	while (position > 0 && [editor message:SCI_GETCHARAT wParam:position - 1] != '(' &&
		[editor message:SCI_GETCHARAT wParam:position - 1] != '\n')
		--position;
	if (position > 0 && [editor message:SCI_GETCHARAT wParam:position - 1] == '(')
		--position;
	else
		position = caret;
	while (position > 0 && [editor message:SCI_GETCHARAT wParam:position - 1] == ' ')
		--position;
	auto start = [editor message:SCI_WORDSTARTPOSITION wParam:position lParam:1];
	NSString *word = Text(editor, start, position);
	_tips = word.length ? _keywords[word] : nil;
	_tipPosition = position;
	_tipIndex = 0;
	[self showTip:editor];
}

- (void)completeIn:(ScintillaView *)editor language:(NSString *)language directory:(NSURL *)directory command:(NSInteger)command
{
	[self loadLanguage:language];
	if (command == 50006)
		return [self completePath:editor directory:directory];
	if (command == 50002)
		return [self functionTip:editor];
	if (command == 50010 || command == 50011)
	{
		if (_tips.count && [editor message:SCI_CALLTIPACTIVE])
		{
			_tipIndex = (_tipIndex + (NSInteger)_tips.count + (command == 50010 ? -1 : 1)) % _tips.count;
			[self showTip:editor];
		}
		return;
	}
	auto caret = [editor message:SCI_GETCURRENTPOS];
	auto start = [editor message:SCI_WORDSTARTPOSITION wParam:caret lParam:1];
	NSString *prefix = Text(editor, start, caret) ?: @"";
	NSArray *choices = command == 50001 ? [self words:editor prefix:prefix position:caret] : _keywords.allKeys;
	if (command < 0)
		choices = [choices arrayByAddingObjectsFromArray:[self words:editor prefix:prefix position:caret]];
	ShowChoices(editor, choices, prefix);
}

- (void)typed:(int)character inEditor:(ScintillaView *)editor language:(NSString *)language
	complete:(BOOL)complete closePairs:(BOOL)closePairs
{
	const auto caret = [editor message:SCI_GETCURRENTPOS];
	[self loadLanguage:language];
	if (closePairs)
	{
		const int pair = character == '(' ? ')' : character == '[' ? ']' : character == '{' ? '}' :
			character == '"' || character == '\'' ? character : 0;
		const int next = (int)[editor message:SCI_GETCHARAT wParam:caret];
		const int previous = caret > 1 ? (int)[editor message:SCI_GETCHARAT wParam:caret - 2] : 0;
		if (pair && next != pair && previous != '\\' && (!next || isspace((unsigned char)next) ||
			next == ',' || next == ';' || next == ')' || next == ']' || next == '}') &&
			((character != '"' && character != '\'') || !isalnum((unsigned char)previous)))
		{
			char closing[] = {static_cast<char>(pair), 0};
			[editor message:SCI_INSERTTEXT wParam:caret lParam:reinterpret_cast<sptr_t>(closing)];
			[editor message:SCI_GOTOPOS wParam:caret];
		}
		if (character == '>' && [@[@"html", @"xml", @"php"] containsObject:language ?: @""])
			[self closeTag:editor at:caret language:language];
	}
	if (complete && character == '(')
		[self functionTip:editor];
	else if (complete && (character >= 128 || isalnum((unsigned char)character) || character == '_') &&
		![editor message:SCI_AUTOCACTIVE] && [editor message:SCI_COUNTCHARACTERS
			wParam:[editor message:SCI_WORDSTARTPOSITION wParam:caret lParam:1] lParam:caret] >=
			[[EditorResources.shared setting:@"autocompleteMinimum" fallback:@2] integerValue])
		[self completeIn:editor language:language directory:nil command:-1];
	if (character == ')')
		[editor message:SCI_CALLTIPCANCEL];
}

- (void)closeTag:(ScintillaView *)editor at:(sptr_t)caret language:(NSString *)language
{
	static NSRegularExpression *opening = [NSRegularExpression regularExpressionWithPattern:
		@"<([A-Za-z_][A-Za-z0-9_.:-]*)(?:\\s+[^<>]*[^/\\s])?\\s*>$" options:0 error:nullptr];
	const auto line = [editor message:SCI_LINEFROMPOSITION wParam:caret];
	NSString *prefix = Text(editor, [editor message:SCI_POSITIONFROMLINE wParam:line], caret);
	if (!prefix.length)
		return;
	NSTextCheckingResult *match = [opening firstMatchInString:prefix options:0 range:NSMakeRange(0, prefix.length)];
	if (!match)
		return;
	NSString *name = [prefix substringWithRange:[match rangeAtIndex:1]];
	static NSSet *voidTags = [NSSet setWithArray:@[@"area", @"base", @"br", @"col", @"embed", @"hr", @"img",
		@"input", @"link", @"meta", @"param", @"source", @"track", @"wbr"]];
	if (![language isEqualToString:@"xml"] && [voidTags containsObject:name.lowercaseString])
		return;
	NSString *end = [NSString stringWithFormat:@"</%@>", name];
	const char *ending = end.UTF8String;
	const auto size = [end lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	if (caret + size <= [editor message:SCI_GETLENGTH] && [Text(editor, caret, caret + size) isEqualToString:end])
		return;
	[editor message:SCI_INSERTTEXT wParam:caret lParam:reinterpret_cast<sptr_t>(ending)];
	[editor message:SCI_GOTOPOS wParam:caret];
}
@end

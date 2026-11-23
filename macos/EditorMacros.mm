// SPDX-License-Identifier: GPL-3.0-only
#import "EditorMacros.h"
#import "EditorResources.h"

#include <climits>
#include "pugiconfig.hpp"
#undef PUGIXML_CHARCONV_FLOAT
#include "pugixml.hpp"

enum class Parameter { Unsupported, Scalar, String, Bytes };
NSNotificationName const EditorMacroLibraryDidChange = @"EditorMacroLibraryDidChange";

MacroMenuAction MacroMenuActionForCommand(uptr_t command)
{
	switch (command)
	{
	case 41006: return MacroMenuAction::Save;
	case 42012: case 42013: case 42024: case 42042: case 42043: case 42044:
	case 42045: case 42046: case 42053: case 42054: case 42055: case 42056:
		return MacroMenuAction::Whitespace;
	case 42022: case 42023: case 42035: case 42036: case 42047:
		return MacroMenuAction::Comment;
	case 42059: case 42060: case 42061: case 42062: case 42063: case 42064: case 42065: case 42066:
	case 42077: case 42078: case 42079: case 42080: case 42081: case 42083: case 42100: case 42101: case 42104: case 42105:
		return MacroMenuAction::Reorder;
	case 42067: case 42068: case 42069: case 42070: case 42071: case 42072:
		return MacroMenuAction::Case;
	case 43018: case 43019: case 43020: case 43021: case 43050: case 43051:
		return MacroMenuAction::Bookmarks;
	default: return MacroMenuAction::Unsupported;
	}
}

bool IsMacroMenuCommand(uptr_t command) { return MacroMenuActionForCommand(command) != MacroMenuAction::Unsupported; }

bool IsMacroSearchStep(unsigned int message)
{
	switch (message)
	{
		case 1601: case 1602: case 1625: case 1654: case 1655: case 1700: case 1701: case 1702: return true;
		default: return false;
	}
}

static Parameter MacroParameter(unsigned int message)
{
	switch (message)
	{
	case SCI_REPLACESEL: case SCI_INSERTTEXT: case SCI_SEARCHNEXT: case SCI_SEARCHPREV:
		return Parameter::String;
	case SCI_ADDTEXT: case SCI_APPENDTEXT:
		return Parameter::Bytes;
	case SCI_CUT: case SCI_COPY: case SCI_PASTE: case SCI_CLEAR: case SCI_CLEARALL: case SCI_SELECTALL:
	case SCI_GOTOLINE: case SCI_GOTOPOS: case SCI_SEARCHANCHOR: case SCI_NEWLINE:
	case SCI_LINEDOWN: case SCI_LINEDOWNEXTEND: case SCI_PARADOWN: case SCI_PARADOWNEXTEND:
	case SCI_LINEUP: case SCI_LINEUPEXTEND: case SCI_PARAUP: case SCI_PARAUPEXTEND:
	case SCI_CHARLEFT: case SCI_CHARLEFTEXTEND: case SCI_CHARRIGHT: case SCI_CHARRIGHTEXTEND:
	case SCI_WORDLEFT: case SCI_WORDLEFTEXTEND: case SCI_WORDRIGHT: case SCI_WORDRIGHTEXTEND:
	case SCI_WORDPARTLEFT: case SCI_WORDPARTLEFTEXTEND: case SCI_WORDPARTRIGHT: case SCI_WORDPARTRIGHTEXTEND:
	case SCI_WORDLEFTEND: case SCI_WORDLEFTENDEXTEND: case SCI_WORDRIGHTEND: case SCI_WORDRIGHTENDEXTEND:
	case SCI_HOME: case SCI_HOMEEXTEND: case SCI_LINEEND: case SCI_LINEENDEXTEND:
	case SCI_HOMEWRAP: case SCI_HOMEWRAPEXTEND: case SCI_LINEENDWRAP: case SCI_LINEENDWRAPEXTEND:
	case SCI_DOCUMENTSTART: case SCI_DOCUMENTSTARTEXTEND: case SCI_DOCUMENTEND: case SCI_DOCUMENTENDEXTEND:
	case SCI_STUTTEREDPAGEUP: case SCI_STUTTEREDPAGEUPEXTEND: case SCI_STUTTEREDPAGEDOWN: case SCI_STUTTEREDPAGEDOWNEXTEND:
	case SCI_PAGEUP: case SCI_PAGEUPEXTEND: case SCI_PAGEDOWN: case SCI_PAGEDOWNEXTEND:
	case SCI_EDITTOGGLEOVERTYPE: case SCI_CANCEL: case SCI_DELETEBACK: case SCI_TAB: case SCI_BACKTAB: case SCI_FORMFEED:
	case SCI_LINEINDENT: case SCI_LINEDEDENT: case SCI_VCHOME: case SCI_VCHOMEEXTEND: case SCI_VCHOMEWRAP: case SCI_VCHOMEWRAPEXTEND:
	case SCI_VCHOMEDISPLAY: case SCI_VCHOMEDISPLAYEXTEND: case SCI_DELWORDLEFT: case SCI_DELWORDRIGHT:
	case SCI_DELWORDRIGHTEND: case SCI_DELLINELEFT: case SCI_DELLINERIGHT: case SCI_LINECOPY: case SCI_LINECUT:
	case SCI_LINEDELETE: case SCI_LINETRANSPOSE: case SCI_LINEREVERSE: case SCI_LINEDUPLICATE: case SCI_LOWERCASE: case SCI_UPPERCASE:
	case SCI_LINESCROLLDOWN: case SCI_LINESCROLLUP: case SCI_DELETEBACKNOTLINE: case SCI_HOMEDISPLAY: case SCI_HOMEDISPLAYEXTEND:
	case SCI_LINEENDDISPLAY: case SCI_LINEENDDISPLAYEXTEND: case SCI_SETSELECTIONMODE: case SCI_LINEDOWNRECTEXTEND:
	case SCI_LINEUPRECTEXTEND: case SCI_CHARLEFTRECTEXTEND: case SCI_CHARRIGHTRECTEXTEND: case SCI_HOMERECTEXTEND:
	case SCI_VCHOMERECTEXTEND: case SCI_LINEENDRECTEXTEND: case SCI_PAGEUPRECTEXTEND: case SCI_PAGEDOWNRECTEXTEND:
	case SCI_SELECTIONDUPLICATE: case SCI_COPYALLOWLINE: case SCI_CUTALLOWLINE: case SCI_VERTICALCENTRECARET:
	case SCI_MOVESELECTEDLINESUP: case SCI_MOVESELECTEDLINESDOWN: case SCI_SCROLLTOSTART: case SCI_SCROLLTOEND:
		return Parameter::Scalar;
	default:
		return Parameter::Unsupported;
	}
}

static bool NormalizeMacroStep(MacroStep &step)
{
	if (IsMacroSearchStep(step.message))
	{
		step.wParam = 0;
		switch (step.message)
		{
			case 1601: case 1602: case 1654: case 1655: return step.text.has_value();
			case 1625: return !step.text && step.lParam >= 0 && step.lParam <= 2;
			case 1700: return !step.text;
			case 1702: return !step.text && step.lParam >= 0 && step.lParam < 8192;
			case 1701:
				switch (step.lParam)
				{
					case 1: case 1608: case 1609: case 1614: case 1615: case 1633: case 1635: case 1636:
					case 1641: case 1656: case 1660: case 1665: case 1666: case 43010:
						return !step.text;
				}
				return false;
		}
	}
	step.lParam = 0;
	if (!step.message)
		return !step.text && IsMacroMenuCommand(step.wParam);
	switch (MacroParameter(step.message))
	{
	case Parameter::Scalar:
		if (step.text)
			return false;
		if (step.message == SCI_SETSELECTIONMODE && step.wParam > SC_SEL_THIN)
			return false;
		return step.wParam <= static_cast<uptr_t>(PTRDIFF_MAX);
	case Parameter::String:
		if (!step.text || step.text->find('\0') != std::string::npos)
			return false;
		return step.wParam <= static_cast<uptr_t>(PTRDIFF_MAX);
	case Parameter::Bytes:
		if (!step.text)
			return false;
		step.wParam = step.text->size();
		return true;
	default:
		return false;
	}
}

@interface EditorMacro ()
- (instancetype)initWithName:(NSString *)name folder:(NSString *)folder steps:(std::vector<MacroStep>)steps;
@end

@implementation EditorMacro
{
	std::vector<MacroStep> _steps;
}

- (instancetype)initWithName:(NSString *)name folder:(NSString *)folder steps:(std::vector<MacroStep>)steps
{
	self = [super init];
	if (self)
	{
		_name = [name copy];
		_folder = [folder copy];
		_steps = std::move(steps);
	}
	return self;
}

- (const std::vector<MacroStep> &)steps
{
	return _steps;
}
@end

static NSError *MacroError(NSString *description, NSInteger code)
{
	return [NSError errorWithDomain:NSCocoaErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSString *XMLString(pugi::xml_attribute value)
{
	return [NSString stringWithUTF8String:value.value()];
}

@implementation EditorMacroLibrary
{
	NSURL *_directory;
	NSURL *_file;
	NSData *_diskData;
	BOOL _readable;
}

+ (instancetype)shared
{
	static EditorMacroLibrary *library = [[self alloc] initWithDirectory:EditorResources.shared.profile];
	return library;
}

- (instancetype)initWithDirectory:(NSURL *)directory
{
	self = [super init];
	if (!self)
		return nil;
	_directory = directory;
	_file = [directory URLByAppendingPathComponent:@"macros.plist"];
	_macros = @[];
	if (![NSFileManager.defaultManager fileExistsAtPath:_file.path])
	{
		_readable = YES;
		return self;
	}
	_diskData = [NSData dataWithContentsOfURL:_file];
	id records = _diskData ? [NSPropertyListSerialization propertyListWithData:_diskData options:NSPropertyListImmutable
		format:nullptr error:nullptr] : nil;
	_readable = [records isKindOfClass:NSArray.class];
	if (!_readable)
		return self;
	NSMutableArray<EditorMacro *> *macros = [NSMutableArray array];
	for (id entry in records)
	{
		if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"name"] isKindOfClass:NSString.class] ||
			![entry[@"folder"] isKindOfClass:NSString.class] || ![entry[@"actions"] isKindOfClass:NSArray.class])
		{
			_readable = NO;
			continue;
		}
		std::vector<MacroStep> steps;
		BOOL valid = YES;
		for (id action in entry[@"actions"])
		{
			if (![action isKindOfClass:NSDictionary.class] || ![action[@"message"] isKindOfClass:NSNumber.class] ||
				![action[@"wParam"] isKindOfClass:NSNumber.class])
			{
				valid = NO;
				break;
			}
			NSData *bytes = action[@"text"];
			MacroStep step{[action[@"message"] unsignedIntValue], [action[@"wParam"] unsignedLongLongValue],
				[action[@"lParam"] isKindOfClass:NSNumber.class] ? [action[@"lParam"] longLongValue] : 0, std::nullopt};
			if ([bytes isKindOfClass:NSData.class])
				step.text.emplace(static_cast<const char *>(bytes.bytes) ?: "", bytes.length);
			if (!NormalizeMacroStep(step))
			{
				valid = NO;
				break;
			}
			steps.push_back(std::move(step));
		}
		if (valid && !steps.empty())
			[macros addObject:[[EditorMacro alloc] initWithName:entry[@"name"] folder:entry[@"folder"] steps:std::move(steps)]];
		else
			_readable = NO;
	}
	_macros = [macros copy];
	return self;
}

- (BOOL)writeMacros:(NSArray<EditorMacro *> *)macros error:(NSError **)error
{
	if (!_readable)
	{
		if (error)
			*error = MacroError(@"The existing macro library contains unreadable entries.", NSFileWriteUnknownError);
		return NO;
	}
	NSMutableArray *records = [NSMutableArray array];
	for (EditorMacro *macro in macros)
	{
		NSMutableArray *actions = [NSMutableArray array];
		for (const auto &step : [macro steps])
		{
			NSMutableDictionary *action = [@{@"message": @(step.message), @"wParam": @(step.wParam)} mutableCopy];
			if (IsMacroSearchStep(step.message))
				action[@"lParam"] = @(step.lParam);
			if (step.text)
				action[@"text"] = [NSData dataWithBytes:step.text->data() length:step.text->size()];
			[actions addObject:action];
		}
		[records addObject:@{@"name": macro.name, @"folder": macro.folder, @"actions": actions}];
	}
	if (![NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES
		attributes:nil error:error])
		return NO;
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:records format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
	if (!data)
		return NO;
	NSError *coordinationError = nil;
	__block NSError *failure = nil;
	__block BOOL written = NO;
	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coordinator coordinateWritingItemAtURL:_file options:NSFileCoordinatorWritingForReplacing error:&coordinationError byAccessor:^(NSURL *url) {
		NSData *current = [NSData dataWithContentsOfURL:url];
		if (!(_diskData == current || [_diskData isEqualToData:current]))
		{
			failure = MacroError(@"Another editor instance changed the macro library. Reopen macpad++ to load those changes.", NSFileWriteUnknownError);
			return;
		}
		NSError *writeError = nil;
		written = [data writeToURL:url options:NSDataWritingAtomic error:&writeError];
		failure = writeError;
	}];
	if (!written)
	{
		if (error)
			*error = failure ?: coordinationError;
		return NO;
	}
	_diskData = data;
	_macros = [macros copy];
	[NSNotificationCenter.defaultCenter postNotificationName:EditorMacroLibraryDidChange object:self];
	return YES;
}

- (BOOL)saveSteps:(const std::vector<MacroStep> &)steps name:(NSString *)name replacing:(BOOL)replacing error:(NSError **)error
{
	auto validated = steps;
	bool valid = name.length && !validated.empty();
	for (auto &step : validated)
		if (!NormalizeMacroStep(step))
		{
			valid = false;
			break;
		}
	if (!valid)
	{
		if (error)
			*error = MacroError(@"Enter a name and record a supported editor operation.", NSFileWriteUnknownError);
		return NO;
	}
	NSMutableArray<EditorMacro *> *macros = [self.macros mutableCopy];
	NSUInteger existing = [macros indexOfObjectPassingTest:^BOOL(EditorMacro *macro, NSUInteger index, BOOL *stop) {
		return !macro.folder.length && [macro.name isEqualToString:name];
	}];
	EditorMacro *macro = [[EditorMacro alloc] initWithName:name folder:@"" steps:std::move(validated)];
	if (existing == NSNotFound)
		[macros addObject:macro];
	else if (replacing)
		macros[existing] = macro;
	else
	{
		if (error)
			*error = MacroError(@"A macro with this name already exists.", NSFileWriteFileExistsError);
		return NO;
	}
	return [self writeMacros:macros error:error];
}

- (BOOL)removeMacro:(EditorMacro *)macro error:(NSError **)error
{
	NSMutableArray *macros = [self.macros mutableCopy];
	[macros removeObjectIdenticalTo:macro];
	return [self writeMacros:macros error:error];
}

- (NSInteger)importShortcuts:(NSURL *)url skipped:(NSUInteger *)skipped error:(NSError **)error
{
	NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
	if (!data)
		return -1;
	pugi::xml_document xml;
	auto parsed = xml.load_buffer(data.bytes, data.length);
	auto macrosNode = xml.child("NotepadPlus").child("Macros");
	if (!parsed || !macrosNode)
	{
		if (error)
			*error = MacroError(@"Choose a shortcuts XML file containing a Macros section.", NSFileReadCorruptFileError);
		return -1;
	}
	NSMutableArray<EditorMacro *> *macros = [self.macros mutableCopy];
	NSUInteger ignored = 0;
	for (auto node : macrosNode.children("Macro"))
	{
		NSString *name = XMLString(node.attribute("name"));
		NSString *folder = XMLString(node.attribute("FolderName")) ?: @"";
		std::vector<MacroStep> steps;
		BOOL valid = name.length > 0;
		for (auto action : node.children("Action"))
		{
			auto type = action.attribute("type").as_int(-1);
			MacroStep step{action.attribute("message").as_uint(), action.attribute("wParam").as_ullong(),
				action.attribute("lParam").as_llong(), std::nullopt};
			if ((type == 1 || (type == 3 && (step.message == 1601 || step.message == 1602 || step.message == 1654 || step.message == 1655))) &&
				action.attribute("sParam"))
				step.text.emplace(action.attribute("sParam").value());
			const bool menuCommand = type == 2 && !step.message;
			const bool scintillaCommand = (type == 0 || type == 1) && step.message;
			const bool searchCommand = type == 3 && IsMacroSearchStep(step.message);
			if ((!menuCommand && !scintillaCommand && !searchCommand) || !NormalizeMacroStep(step))
			{
				valid = NO;
				break;
			}
			steps.push_back(std::move(step));
		}
		BOOL exists = [macros indexOfObjectPassingTest:^BOOL(EditorMacro *macro, NSUInteger index, BOOL *stop) {
			return [macro.name isEqualToString:name] && [macro.folder isEqualToString:folder];
		}] != NSNotFound;
		if (valid && !steps.empty() && !exists)
			[macros addObject:[[EditorMacro alloc] initWithName:name folder:folder steps:std::move(steps)]];
		else
			++ignored;
	}
	NSInteger added = macros.count - self.macros.count;
	if (added && ![self writeMacros:macros error:error])
		return -1;
	if (skipped)
		*skipped = ignored;
	return added;
}
@end

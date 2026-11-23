// SPDX-License-Identifier: GPL-3.0-only
#import "EditorSettings.h"
#import "EditorContextMenus.h"
#import "EditorMacros.h"
#import "EditorPlugins.h"
#import "EditorResources.h"

#include "Scintilla.h"
#include "pugiconfig.hpp"
#undef PUGIXML_CHARCONV_FLOAT
#include "pugixml.hpp"
#include <cstring>

NSDictionary<NSNumber *, NSString *> *EditorScintillaCommandNames(void)
{
	return @{
		@(SCI_LINEDOWN): @"Line Down", @(SCI_LINEUP): @"Line Up", @(SCI_CHARLEFT): @"Character Left",
		@(SCI_CHARRIGHT): @"Character Right", @(SCI_WORDLEFT): @"Word Left", @(SCI_WORDRIGHT): @"Word Right",
		@(SCI_HOME): @"Start of Line", @(SCI_LINEEND): @"End of Line", @(SCI_DOCUMENTSTART): @"Start of Document",
		@(SCI_DOCUMENTEND): @"End of Document", @(SCI_PAGEUP): @"Page Up", @(SCI_PAGEDOWN): @"Page Down",
		@(SCI_LINEDOWNEXTEND): @"Select Down", @(SCI_LINEUPEXTEND): @"Select Up",
		@(SCI_CHARLEFTEXTEND): @"Select Character Left", @(SCI_CHARRIGHTEXTEND): @"Select Character Right",
		@(SCI_WORDLEFTEXTEND): @"Select Word Left", @(SCI_WORDRIGHTEXTEND): @"Select Word Right",
		@(SCI_HOMEEXTEND): @"Select to Start of Line", @(SCI_LINEENDEXTEND): @"Select to End of Line",
		@(SCI_DOCUMENTSTARTEXTEND): @"Select to Start of Document", @(SCI_DOCUMENTENDEXTEND): @"Select to End of Document",
		@(SCI_PAGEUPEXTEND): @"Select Page Up", @(SCI_PAGEDOWNEXTEND): @"Select Page Down",
		@(SCI_DELETEBACK): @"Delete Backward", @(SCI_CLEAR): @"Delete Forward", @(SCI_DELWORDLEFT): @"Delete Word Left",
		@(SCI_DELWORDRIGHT): @"Delete Word Right", @(SCI_DELLINELEFT): @"Delete to Start of Line",
		@(SCI_DELLINERIGHT): @"Delete to End of Line", @(SCI_NEWLINE): @"Insert Newline",
		@(SCI_TAB): @"Indent", @(SCI_BACKTAB): @"Unindent", @(SCI_VCHOME): @"Toggle Start of Indentation",
		@(SCI_VCHOMEEXTEND): @"Select to Start of Indentation", @(SCI_WORDPARTLEFT): @"Word Part Left",
		@(SCI_WORDPARTRIGHT): @"Word Part Right", @(SCI_EDITTOGGLEOVERTYPE): @"Toggle Insert / Overwrite",
		@(SCI_LINEDUPLICATE): @"Duplicate Line", @(SCI_LINEDELETE): @"Delete Line", @(SCI_LINECOPY): @"Copy Line",
		@(SCI_LINECUT): @"Cut Line", @(SCI_LINETRANSPOSE): @"Transpose Lines",
		@(SCI_SCROLLTOSTART): @"Scroll to Start", @(SCI_SCROLLTOEND): @"Scroll to End",
		@(SCI_VERTICALCENTRECARET): @"Center Line at Caret",
		@(SCI_PARADOWN): @"Next Paragraph", @(SCI_PARAUP): @"Previous Paragraph",
		@(SCI_PARADOWNEXTEND): @"Select Next Paragraph", @(SCI_PARAUPEXTEND): @"Select Previous Paragraph",
		@(SCI_HOMEDISPLAY): @"Start of Display Line", @(SCI_LINEENDDISPLAY): @"End of Display Line",
		@(SCI_HOMEDISPLAYEXTEND): @"Select to Start of Display Line", @(SCI_LINEENDDISPLAYEXTEND): @"Select to End of Display Line",
		@(SCI_HOMEWRAP): @"Start of Wrapped Line", @(SCI_LINEENDWRAP): @"End of Wrapped Line",
		@(SCI_HOMEWRAPEXTEND): @"Select to Start of Wrapped Line", @(SCI_LINEENDWRAPEXTEND): @"Select to End of Wrapped Line",
		@(SCI_WORDPARTLEFTEXTEND): @"Select Word Part Left", @(SCI_WORDPARTRIGHTEXTEND): @"Select Word Part Right",
		@(SCI_WORDLEFTEND): @"Previous Word End", @(SCI_WORDRIGHTEND): @"Next Word End",
		@(SCI_WORDLEFTENDEXTEND): @"Select to Previous Word End", @(SCI_WORDRIGHTENDEXTEND): @"Select to Next Word End",
		@(SCI_LINEDOWNRECTEXTEND): @"Extend Rectangle Down", @(SCI_LINEUPRECTEXTEND): @"Extend Rectangle Up",
		@(SCI_CHARLEFTRECTEXTEND): @"Extend Rectangle Left", @(SCI_CHARRIGHTRECTEXTEND): @"Extend Rectangle Right",
		@(SCI_HOMERECTEXTEND): @"Extend Rectangle to Start of Line", @(SCI_LINEENDRECTEXTEND): @"Extend Rectangle to End of Line",
		@(SCI_PAGEUPRECTEXTEND): @"Extend Rectangle Page Up", @(SCI_PAGEDOWNRECTEXTEND): @"Extend Rectangle Page Down",
		@(SCI_LINESCROLLDOWN): @"Scroll Down One Line", @(SCI_LINESCROLLUP): @"Scroll Up One Line",
		@(SCI_DELETEBACKNOTLINE): @"Delete Backward Within Line", @(SCI_DELWORDRIGHTEND): @"Delete to Next Word End",
		@(SCI_LINEREVERSE): @"Reverse Lines", @(SCI_MOVESELECTEDLINESUP): @"Move Selected Lines Up",
		@(SCI_MOVESELECTEDLINESDOWN): @"Move Selected Lines Down", @(SCI_SELECTIONDUPLICATE): @"Duplicate Selection",
		@(SCI_LINEINDENT): @"Indent Line", @(SCI_LINEDEDENT): @"Unindent Line",
		@(SCI_LOWERCASE): @"Lowercase", @(SCI_UPPERCASE): @"Uppercase",
		@(SCI_COPY): @"Copy", @(SCI_PASTE): @"Paste", @(SCI_CUT): @"Cut", @(SCI_SELECTALL): @"Select All",
		@(SCI_UNDO): @"Undo", @(SCI_REDO): @"Redo", @(SCI_CANCEL): @"Cancel",
		@(SCI_ZOOMIN): @"Zoom In", @(SCI_ZOOMOUT): @"Zoom Out"
	};
}

static NSString *PluginShortcut(NSMenu *menu, NSString *module, NSInteger identifier)
{
	for (NSMenuItem *item in menu.itemArray)
	{
		if ([item.target isKindOfClass:EditorPlugins.class])
			if (NSString *key = [(EditorPlugins *)item.target shortcutForWindowsModule:module internalID:identifier])
				return key;
		if (item.submenu)
			if (NSString *key = PluginShortcut(item.submenu, module, identifier))
				return key;
	}
	return nil;
}

void EditorResolvePendingPluginShortcuts(NSMenu *menu)
{
	EditorResources *resources = EditorResources.shared;
	NSDictionary *stored = [resources setting:@"pendingWindowsPluginShortcuts" fallback:@{}];
	if (!stored.count)
		return;
	NSMutableDictionary *remaining = [stored mutableCopy];
	NSMutableDictionary *shortcuts = [[resources setting:@"shortcuts" fallback:@{}] mutableCopy];
	for (NSString *record in stored)
	{
		NSDictionary *entry = stored[record];
		NSString *key = PluginShortcut(menu, entry[@"module"], [entry[@"id"] integerValue]);
		if (key)
		{
			if (!shortcuts[key])
				shortcuts[key] = entry[@"binding"];
			[remaining removeObjectForKey:record];
		}
	}
	if (remaining.count != stored.count)
		[resources setSettings:@{@"shortcuts": shortcuts, @"pendingWindowsPluginShortcuts": remaining}];
}

static NSString *XMLString(const char *text) { return [NSString stringWithUTF8String:text] ?: @""; }

static NSDictionary *WindowsBinding(pugi::xml_node node)
{
	int key = node.attribute("Key").as_int(-1);
	unichar scalar = 0;
	if ((key >= '0' && key <= '9') || (key >= 'A' && key <= 'Z'))
		scalar = key;
	else if (key >= 0x70 && key <= 0x83)
		scalar = NSF1FunctionKey + key - 0x70;
	else
	{
		const NSDictionary<NSNumber *, NSNumber *> *special = @{
			@8: @127, @9: @9, @13: @13, @27: @27, @32: @32, @33: @(NSPageUpFunctionKey),
			@34: @(NSPageDownFunctionKey), @35: @(NSEndFunctionKey), @36: @(NSHomeFunctionKey),
			@37: @(NSLeftArrowFunctionKey), @38: @(NSUpArrowFunctionKey), @39: @(NSRightArrowFunctionKey),
			@40: @(NSDownArrowFunctionKey), @45: @(NSInsertFunctionKey), @46: @(NSDeleteFunctionKey),
			@186: @';', @187: @'=', @188: @',', @189: @'-', @190: @'.', @191: @'/',
			@192: @'`', @219: @'[', @220: @'\\', @221: @']', @222: @'\''
		};
		scalar = [special[@(key)] unsignedShortValue];
	}
	if (!scalar && key != 0)
		return nil;
	NSUInteger modifiers = 0;
	if (strcmp(node.attribute("Ctrl").value(), "yes") == 0) modifiers |= NSEventModifierFlagCommand;
	if (strcmp(node.attribute("Alt").value(), "yes") == 0) modifiers |= NSEventModifierFlagOption;
	if (strcmp(node.attribute("Shift").value(), "yes") == 0) modifiers |= NSEventModifierFlagShift;
	NSString *character = scalar ? [[NSString stringWithCharacters:&scalar length:1] lowercaseString] : @"";
	return @{@"key": character, @"modifiers": @(modifiers)};
}

BOOL EditorImportShortcutConfiguration(NSURL *url, NSMenu *menu, NSUInteger *skipped, NSError **error)
{
	NSData *file = [NSData dataWithContentsOfURL:url options:0 error:error];
	pugi::xml_document xml;
	auto parsed = file.length && xml.load_buffer(file.bytes, file.length);
	auto root = xml.child("NotepadPlus");
	if (!parsed || !root || !(root.child("InternalCommands") || root.child("Macros") ||
		root.child("UserDefinedCommands") || root.child("ScintillaKeys") || root.child("PluginCommands")))
	{
		if (file && error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError
				userInfo:@{NSLocalizedDescriptionKey: [EditorResources.shared label:@"native-invalidShortcuts" fallback:@"Choose a valid shortcuts.xml file."]}];
		return NO;
	}
	EditorResources *resources = EditorResources.shared;
	NSMutableDictionary *shortcuts = [[resources setting:@"shortcuts" fallback:@{}] mutableCopy];
	NSMutableDictionary *run = [[resources setting:@"runCommands" fallback:@{}] mutableCopy];
	NSMutableDictionary *pending = [[resources setting:@"pendingWindowsPluginShortcuts" fallback:@{}] mutableCopy];
	NSUInteger ignored = 0;
	if (root.child("Macros") && [EditorMacroLibrary.shared importShortcuts:url skipped:&ignored error:error] < 0)
		return NO;
	for (auto shortcut : root.child("InternalCommands").children("Shortcut"))
	{
		NSMenuItem *item = EditorFindMenuCommandByID(menu, XMLString(shortcut.attribute("id").value()));
		NSDictionary *binding = WindowsBinding(shortcut);
		if (item && binding)
			shortcuts[EditorShortcutIdentifier(item)] = binding;
		else
			++ignored;
	}
	for (auto shortcut : root.child("UserDefinedCommands").children("Command"))
	{
		NSString *name = XMLString(shortcut.attribute("name").value());
		NSString *command = XMLString(shortcut.child_value());
		if (!name.length || !command.length || (run[name] && ![run[name] isEqualToString:command]))
		{
			++ignored;
			continue;
		}
		run[name] = command;
		if (NSDictionary *binding = WindowsBinding(shortcut))
			shortcuts[[@"executeSavedRunCommand:" stringByAppendingString:name]] = binding;
	}
	for (auto shortcut : root.child("Macros").children("Macro"))
	{
		NSString *name = XMLString(shortcut.attribute("name").value());
		NSString *folder = XMLString(shortcut.attribute("FolderName").value());
		NSDictionary *binding = WindowsBinding(shortcut);
		if (name.length && binding)
			shortcuts[[NSString stringWithFormat:@"playSavedMacro:/%@/%@", folder, name]] = binding;
	}
	NSDictionary *supported = EditorScintillaCommandNames();
	for (auto shortcut : root.child("ScintillaKeys").children("ScintKey"))
	{
		NSInteger command = shortcut.attribute("ScintID").as_int();
		NSDictionary *binding = WindowsBinding(shortcut);
		if (!supported[@(command)] || !binding)
		{
			++ignored;
			continue;
		}
		NSMutableArray *alternatives = [NSMutableArray array];
		for (auto next : shortcut.children("NextKey"))
			if (NSDictionary *key = WindowsBinding(next))
				if ([key[@"key"] length])
					[alternatives addObject:key];
		NSMutableDictionary *record = [binding mutableCopy];
		if (alternatives.count)
			record[@"alternatives"] = alternatives;
		shortcuts[[NSString stringWithFormat:@"scintilla/%ld", command]] = record;
	}
	for (auto plugin : root.child("PluginCommands").children("PluginCommand"))
	{
		NSString *module = XMLString(plugin.attribute("moduleName").value());
		NSInteger identifier = plugin.attribute("internalID").as_int(-1);
		NSDictionary *binding = WindowsBinding(plugin);
		if (!module.length || identifier < 0 || !binding)
		{
			++ignored;
			continue;
		}
		NSString *record = [NSString stringWithFormat:@"%@/%ld", module.lowercaseString, identifier];
		if (NSString *key = PluginShortcut(menu, module, identifier))
		{
			shortcuts[key] = binding;
			[pending removeObjectForKey:record];
		}
		else
			pending[record] = @{@"module": module, @"id": @(identifier), @"binding": binding};
	}
	[resources setSettings:@{@"shortcuts": shortcuts, @"runCommands": run, @"pendingWindowsPluginShortcuts": pending}];
	if (skipped)
		*skipped = ignored;
	return YES;
}

unsigned int EditorScintillaCommandForEvent(NSEvent *event)
{
	if (event.type != NSEventTypeKeyDown)
		return 0;
	NSString *key = event.charactersIgnoringModifiers.lowercaseString;
	if (key.length != 1)
		return 0;
	const auto modifiers = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
		NSEventModifierFlagOption | NSEventModifierFlagShift);
	NSDictionary *shortcuts = [EditorResources.shared setting:@"shortcuts" fallback:@{}];
	for (NSString *identifier in shortcuts)
	{
		if (![identifier hasPrefix:@"scintilla/"])
			continue;
		NSDictionary *binding = shortcuts[identifier];
		if (![binding isKindOfClass:NSDictionary.class])
			continue;
		NSArray *alternatives = binding[@"alternatives"];
		NSArray *bindings = [alternatives isKindOfClass:NSArray.class] ? [@[binding] arrayByAddingObjectsFromArray:alternatives] : @[binding];
		for (NSDictionary *choice in bindings)
			if ([choice isKindOfClass:NSDictionary.class] && [choice[@"key"] isEqual:key] &&
				[choice[@"modifiers"] unsignedIntegerValue] == modifiers)
			{
				unsigned int command = static_cast<unsigned int>([identifier substringFromIndex:10].integerValue);
				return EditorScintillaCommandNames()[@(command)] ? command : 0;
			}
	}
	return 0;
}

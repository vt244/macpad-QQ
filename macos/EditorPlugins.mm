// SPDX-License-Identifier: GPL-3.0-only
#import "EditorPlugins.h"
#import "EditorDocument.h"
#import "ScintillaView.h"

#include "MacpadPlugin.h"

#include <algorithm>
#include <cstring>
#include <dlfcn.h>
#include <vector>

static size_t CopySelection(void *context, char *buffer, size_t capacity)
{
	ScintillaView *view = (__bridge ScintillaView *)context;
	auto start = [view message:SCI_GETSELECTIONSTART];
	auto end = [view message:SCI_GETSELECTIONEND];
	auto selected = static_cast<size_t>(end - start);
	if (buffer && capacity && selected)
	{
		const auto *data = reinterpret_cast<const char *>([view message:SCI_GETCHARACTERPOINTER]);
		std::memcpy(buffer, data + start, std::min(capacity, selected));
	}
	return selected;
}

static int ReplaceSelection(void *context, const char *bytes, size_t length)
{
	ScintillaView *view = (__bridge ScintillaView *)context;
	if ((!bytes && length) || [view message:SCI_GETREADONLY] ||
		(length && (std::memchr(bytes, 0, length) || ![[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding])))
		return 0;
	auto start = [view message:SCI_GETSELECTIONSTART];
	auto end = [view message:SCI_GETSELECTIONEND];
	[view message:SCI_SETTARGETRANGE wParam:start lParam:end];
	auto replaced = [view message:SCI_REPLACETARGET wParam:length lParam:reinterpret_cast<sptr_t>(bytes ?: "")];
	if (replaced < 0)
		return 0;
	[view message:SCI_SETSEL wParam:start lParam:start + replaced];
	return 1;
}

static EditorDocument *ActiveDocument()
{
	NSDocument *document = NSApp.keyWindow.windowController.document ?:
		NSApp.mainWindow.windowController.document ?: NSDocumentController.sharedDocumentController.currentDocument;
	return [document isKindOfClass:EditorDocument.class] ? (EditorDocument *)document : nil;
}

@implementation EditorPlugins
{
	std::vector<void *> _libraries;
	std::vector<const MacpadPluginV1 *> _commands;
}

- (instancetype)initWithDirectory:(NSURL *)directory
{
	self = [super init];
	if (self)
	{
		NSArray<NSURL *> *urls = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
			includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nullptr];
		for (NSURL *url in urls)
		{
			NSNumber *regular = nil;
			[url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nullptr];
			if (!regular.boolValue || ![url.pathExtension.lowercaseString isEqualToString:@"dylib"])
				continue;
			void *library = dlopen(url.fileSystemRepresentation, RTLD_LOCAL | RTLD_NOW);
			if (!library)
			{
				NSLog(@"macpad++ plugin %@: %s", url.lastPathComponent, dlerror());
				continue;
			}
			auto entry = reinterpret_cast<MacpadPluginEntry>(dlsym(library, "macpad_plugin"));
			const MacpadPluginV1 *command = entry ? entry() : nullptr;
			if (!command || command->version != MACPAD_PLUGIN_ABI_VERSION || !command->title || !command->run ||
				![NSString stringWithUTF8String:command->title].length)
			{
				NSLog(@"macpad++ plugin %@: incompatible plugin API", url.lastPathComponent);
				dlclose(library);
				continue;
			}
			_libraries.push_back(library);
			_commands.push_back(command);
		}
	}
	return self;
}

- (void)dealloc
{
	for (void *library : _libraries)
		dlclose(library);
}

- (void)populateMenu:(NSMenu *)menu
{
	for (size_t i = 0; i < _commands.size(); ++i)
	{
		NSMenuItem *item = [menu addItemWithTitle:[NSString stringWithUTF8String:_commands[i]->title]
			action:@selector(runPlugin:) keyEquivalent:@""];
		item.target = self;
		item.tag = i;
	}
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	return ActiveDocument().editor != nil;
}

- (void)runPlugin:(NSMenuItem *)item
{
	[self performCommand:item inDocument:ActiveDocument()];
}

- (BOOL)performCommand:(NSMenuItem *)item inDocument:(EditorDocument *)document
{
	if (!document.editor || !item || item.tag < 0 || static_cast<size_t>(item.tag) >= _commands.size())
		return NO;
	const MacpadEditorV1 editor = {(__bridge void *)document.editor, CopySelection, ReplaceSelection};
	_commands[item.tag]->run(&editor);
	return YES;
}
@end

// SPDX-License-Identifier: GPL-3.0-only
#import "EditorPlugins.h"
#import "EditorDocument.h"
#import "ScintillaView.h"

#include "MacpadPlugin.h"

#include <algorithm>
#include <cstring>
#include <dlfcn.h>
#include <vector>

NSNotificationName const EditorPluginDocumentDidChange = @"EditorPluginDocumentDidChange";

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
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	NSDocument *document = controller.focusedDocument ?: NSApp.keyWindow.windowController.document ?:
		NSApp.mainWindow.windowController.document ?: NSDocumentController.sharedDocumentController.currentDocument;
	return [document isKindOfClass:EditorDocument.class] ? (EditorDocument *)document : nil;
}

static EditorDocument *DocumentWithID(MacpadDocumentID identifier)
{
	if (!NSThread.isMainThread || !identifier)
		return nil;
	for (EditorDocument *document in NSDocumentController.sharedDocumentController.documents)
		if (document.runtimeIdentifier == identifier)
			return document;
	return nil;
}

static size_t CopyDocumentBytes(const void *source, size_t length, char *buffer, size_t capacity)
{
	if (source && buffer && capacity && length)
		std::memcpy(buffer, source, std::min(capacity, length));
	return length;
}

static MacpadDocumentID PluginActiveDocument(void *context)
{
	return NSThread.isMainThread ? ActiveDocument().runtimeIdentifier : 0;
}

static size_t PluginDocumentCount(void *context)
{
	return NSThread.isMainThread ? NSDocumentController.sharedDocumentController.documents.count : 0;
}

static MacpadDocumentID PluginDocumentAtIndex(void *context, size_t index)
{
	if (!NSThread.isMainThread)
		return 0;
	NSArray<EditorDocument *> *documents = (NSArray *)NSDocumentController.sharedDocumentController.documents;
	return index < documents.count ? documents[index].runtimeIdentifier : 0;
}

static size_t PluginCopyPath(void *context, MacpadDocumentID identifier, char *buffer, size_t capacity)
{
	NSData *path = [DocumentWithID(identifier).fileURL.path dataUsingEncoding:NSUTF8StringEncoding];
	return CopyDocumentBytes(path.bytes, path.length, buffer, capacity);
}

static size_t PluginCopyText(void *context, MacpadDocumentID identifier, char *buffer, size_t capacity)
{
	ScintillaView *view = DocumentWithID(identifier).editor;
	const auto count = [view message:SCI_GETLENGTH];
	const auto *bytes = reinterpret_cast<const char *>([view message:SCI_GETCHARACTERPOINTER]);
	return CopyDocumentBytes(bytes, count, buffer, capacity);
}

static int PluginReplaceRange(void *context, MacpadDocumentID identifier, size_t start, size_t end, const char *text, size_t length)
{
	ScintillaView *view = DocumentWithID(identifier).editor;
	const auto count = static_cast<size_t>([view message:SCI_GETLENGTH]);
	if (!view || [view message:SCI_GETREADONLY] || start > end || end > count || (!text && length) ||
		(length && ![[NSString alloc] initWithBytes:text length:length encoding:NSUTF8StringEncoding]))
		return 0;
	auto continuation = [&](size_t offset) {
		return offset < count && ([view message:SCI_GETCHARAT wParam:offset] & 0xc0) == 0x80;
	};
	if (continuation(start) || continuation(end))
		return 0;
	[view message:SCI_SETTARGETRANGE wParam:start lParam:end];
	return [view message:SCI_REPLACETARGET wParam:length lParam:reinterpret_cast<sptr_t>(text ?: "")] >= 0;
}

@interface EditorPlugins () <NSWindowDelegate>
- (BOOL)showPanel:(NSString *)identifier title:(NSString *)title view:(NSView *)view;
- (void)closePanel:(NSString *)identifier;
@end

struct PluginInvocation
{
	__unsafe_unretained EditorPlugins *plugins;
	const MacpadPluginV2 *descriptor;
};

static NSString *PluginPanelIdentifier(const PluginInvocation &invocation, const char *identifier)
{
	NSString *name = identifier ? [NSString stringWithUTF8String:identifier] : nil;
	return name.length ? [NSString stringWithFormat:@"%p/%@", invocation.descriptor, name] : nil;
}

static int PluginShowPanel(void *context, const char *identifier, const char *title, void *view)
{
	if (!NSThread.isMainThread || !context || !view || !title)
		return 0;
	const auto &invocation = *static_cast<const PluginInvocation *>(context);
	return [invocation.plugins showPanel:PluginPanelIdentifier(invocation, identifier)
		title:[NSString stringWithUTF8String:title] view:(__bridge NSView *)view];
}

static void PluginClosePanel(void *context, const char *identifier)
{
	if (NSThread.isMainThread && context)
	{
		const auto &invocation = *static_cast<const PluginInvocation *>(context);
		[invocation.plugins closePanel:PluginPanelIdentifier(invocation, identifier)];
	}
}

static MacpadEditorV2 PluginEditor(PluginInvocation *invocation)
{
	return {invocation, PluginActiveDocument, PluginDocumentCount, PluginDocumentAtIndex,
		PluginCopyPath, PluginCopyText, PluginReplaceRange, PluginShowPanel, PluginClosePanel};
}

struct PluginCommand
{
	const MacpadPluginV1 *v1;
	const MacpadPluginV2 *v2;
	size_t index;
};

@implementation EditorPlugins
{
	std::vector<void *> _libraries;
	std::vector<PluginCommand> _commands;
	std::vector<const MacpadPluginV2 *> _eventHandlers;
	NSMutableDictionary<NSString *, NSString *> *_loadedTitles;
	NSMutableDictionary<NSString *, NSPanel *> *_panels;
	BOOL _dispatchingEvent;
	MacpadDocumentID _lastActive;
}

- (NSArray<NSURL *> *)pluginFiles
{
	NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directory
		includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nullptr];
	NSMutableArray<NSURL *> *files = [NSMutableArray array];
	for (NSURL *item in items)
	{
		NSNumber *regular = nil;
		[item getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nullptr];
		if (regular.boolValue && [item.pathExtension.lowercaseString isEqualToString:@"dylib"])
			[files addObject:item];
	}
	return [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
		return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
	}];
}

- (instancetype)initWithDirectory:(NSURL *)directory
{
	self = [super init];
	if (self)
	{
		_directory = [directory copy];
		_loadedTitles = [NSMutableDictionary dictionary];
		_panels = [NSMutableDictionary dictionary];
		for (NSURL *url in self.pluginFiles)
		{
			void *library = dlopen(url.fileSystemRepresentation, RTLD_LOCAL | RTLD_NOW);
			if (!library)
			{
				NSLog(@"macpad++ plugin %@: %s", url.lastPathComponent, dlerror());
				continue;
			}
			auto modernEntry = reinterpret_cast<MacpadPluginEntryV2>(dlsym(library, "macpad_plugin_v2"));
			if (modernEntry)
			{
				const MacpadPluginV2 *plugin = modernEntry();
				if (!plugin || plugin->version != MACPAD_PLUGIN_ABI_V2 || plugin->structSize < sizeof(MacpadPluginV2) ||
					!plugin->title || ![NSString stringWithUTF8String:plugin->title].length || plugin->commandCount > 256 ||
					(plugin->commandCount && !plugin->commands))
				{
					NSLog(@"macpad++ plugin %@: incompatible version 2 API", url.lastPathComponent);
					dlclose(library);
					continue;
				}
				_libraries.push_back(library);
				_loadedTitles[url.lastPathComponent] = [NSString stringWithUTF8String:plugin->title];
				if (plugin->onDocumentEvent)
					_eventHandlers.push_back(plugin);
				for (size_t index = 0; index < plugin->commandCount; ++index)
					if (plugin->commands[index].run && plugin->commands[index].title &&
						[NSString stringWithUTF8String:plugin->commands[index].title].length)
						_commands.push_back({nullptr, plugin, index});
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
			_commands.push_back({command, nullptr, 0});
			_loadedTitles[url.lastPathComponent] = [NSString stringWithUTF8String:command->title];
		}
		if (!_eventHandlers.empty())
			[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentEvent:)
				name:EditorPluginDocumentDidChange object:nil];
	}
	return self;
}

- (NSString *)loadedTitleForFile:(NSURL *)file
{
	return _loadedTitles[file.lastPathComponent];
}

- (BOOL)installPluginAtURL:(NSURL *)source error:(NSError **)error
{
	NSNumber *regular = nil;
	NSNumber *link = nil;
	if (![source getResourceValue:&regular forKey:NSURLIsRegularFileKey error:error] ||
		![source getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:error])
		return NO;
	if (!regular.boolValue || link.boolValue || ![source.pathExtension.lowercaseString isEqualToString:@"dylib"])
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnsupportedSchemeError userInfo:@{
				NSURLErrorKey: source, NSLocalizedDescriptionKey: @"Choose a regular macOS .dylib plugin file."}];
		return NO;
	}
	NSFileManager *files = NSFileManager.defaultManager;
	if (![files createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:error])
		return NO;
	NSURL *target = [self.directory URLByAppendingPathComponent:source.lastPathComponent isDirectory:NO];
	NSURL *staging = [self.directory URLByAppendingPathComponent:[@"." stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:NO];
	if (![files copyItemAtURL:source toURL:staging error:error])
		return NO;
	if ([files moveItemAtURL:staging toURL:target error:error])
		return YES;
	[files removeItemAtURL:staging error:nullptr];
	return NO;
}

- (BOOL)disablePluginAtURL:(NSURL *)file error:(NSError **)error
{
	if (![self.pluginFiles containsObject:file])
		return NO;
	NSFileManager *files = NSFileManager.defaultManager;
	NSURL *disabled = [self.directory URLByAppendingPathComponent:@"Disabled" isDirectory:YES];
	if (![files createDirectoryAtURL:disabled withIntermediateDirectories:YES attributes:nil error:error])
		return NO;
	NSURL *target = [disabled URLByAppendingPathComponent:file.lastPathComponent isDirectory:NO];
	return [files moveItemAtURL:file toURL:target error:error];
}

- (BOOL)installCatalogPlugin:(NSData *)data filename:(NSString *)filename updating:(BOOL)updating error:(NSError **)error
{
	if (!data.length || ![filename isEqualToString:filename.lastPathComponent] || [filename hasPrefix:@"."] ||
		![filename.pathExtension.lowercaseString isEqualToString:@"dylib"])
		return NO;
	NSFileManager *files = NSFileManager.defaultManager;
	if (![files createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:error])
		return NO;
	NSURL *target = [self.directory URLByAppendingPathComponent:filename];
	if (updating)
	{
		NSNumber *regular = nil, *link = nil;
		if (![target getResourceValue:&regular forKey:NSURLIsRegularFileKey error:error] ||
			![target getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:error] || !regular.boolValue || link.boolValue)
			return NO;
		return [data writeToURL:target options:NSDataWritingAtomic error:error];
	}
	NSURL *stage = [self.directory URLByAppendingPathComponent:[@"." stringByAppendingString:NSUUID.UUID.UUIDString]];
	if (![data writeToURL:stage options:NSDataWritingWithoutOverwriting error:error])
		return NO;
	if ([files moveItemAtURL:stage toURL:target error:error])
		return YES;
	[files removeItemAtURL:stage error:nullptr];
	return NO;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
	for (NSPanel *panel in _panels.allValues)
	{
		panel.delegate = nil;
		panel.contentView = nil;
		[panel close];
	}
	for (void *library : _libraries)
		dlclose(library);
}

- (void)populateMenu:(NSMenu *)menu
{
	NSMutableDictionary<NSValue *, NSMenu *> *groups = [NSMutableDictionary dictionary];
	for (size_t i = 0; i < _commands.size(); ++i)
	{
		const PluginCommand &command = _commands[i];
		NSMenu *target = menu;
		if (command.v2)
		{
			NSValue *identifier = [NSValue valueWithPointer:command.v2];
			target = groups[identifier];
			if (!target)
			{
				NSString *title = [NSString stringWithUTF8String:command.v2->title];
				NSMenuItem *parent = [menu addItemWithTitle:title action:nullptr keyEquivalent:@""];
				target = [[NSMenu alloc] initWithTitle:title];
				parent.submenu = target;
				groups[identifier] = target;
			}
		}
		const auto *title = command.v2 ? command.v2->commands[command.index].title : command.v1->title;
		NSMenuItem *item = [target addItemWithTitle:[NSString stringWithUTF8String:title]
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
	const PluginCommand &command = _commands[item.tag];
	if (command.v2)
	{
		PluginInvocation invocation{self, command.v2};
		auto editor = PluginEditor(&invocation);
		command.v2->commands[command.index].run(&editor);
	}
	else
	{
		const MacpadEditorV1 editor = {(__bridge void *)document.editor, CopySelection, ReplaceSelection};
		command.v1->run(&editor);
	}
	return YES;
}

- (void)documentEvent:(NSNotification *)notification
{
	if (_dispatchingEvent || ![notification.object isKindOfClass:EditorDocument.class])
		return;
	EditorDocument *document = notification.object;
	auto event = static_cast<MacpadDocumentEventV2>([notification.userInfo[@"event"] intValue]);
	if (event == MACPAD_DOCUMENT_ACTIVATED)
	{
		if (_lastActive == document.runtimeIdentifier)
			return;
		_lastActive = document.runtimeIdentifier;
	}
	else if (event == MACPAD_DOCUMENT_CLOSED && _lastActive == document.runtimeIdentifier)
		_lastActive = 0;
	_dispatchingEvent = YES;
	for (const auto *plugin : _eventHandlers)
	{
		PluginInvocation invocation{self, plugin};
		auto editor = PluginEditor(&invocation);
		plugin->onDocumentEvent(&editor, event, document.runtimeIdentifier);
	}
	_dispatchingEvent = NO;
}

- (BOOL)showPanel:(NSString *)identifier title:(NSString *)title view:(NSView *)view
{
	if (!identifier.length || !title.length || ![view isKindOfClass:NSView.class])
		return NO;
	NSPanel *panel = _panels[identifier];
	if (!panel)
	{
		panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 240)
			styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
				NSWindowStyleMaskUtilityWindow backing:NSBackingStoreBuffered defer:NO];
		panel.releasedWhenClosed = NO;
		panel.hidesOnDeactivate = YES;
		panel.delegate = self;
		[panel center];
		_panels[identifier] = panel;
	}
	panel.title = title;
	panel.contentView = view;
	[panel makeKeyAndOrderFront:nil];
	return YES;
}

- (void)closePanel:(NSString *)identifier
{
	if (identifier.length)
		[_panels[identifier] close];
}

- (void)windowWillClose:(NSNotification *)notification
{
	NSPanel *panel = notification.object;
	NSString *identifier = [_panels allKeysForObject:panel].firstObject;
	if (identifier)
	{
		panel.contentView = nil;
		[_panels removeObjectForKey:identifier];
	}
}
@end

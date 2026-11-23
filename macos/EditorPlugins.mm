// SPDX-License-Identifier: GPL-3.0-only
#import "EditorPlugins.h"
#import "EditorDocument.h"
#import "EditorResources.h"
#import "ScintillaView.h"

#include "MacpadPlugin.h"

#include <algorithm>
#include <cstring>
#include <dlfcn.h>
#include <vector>

NSNotificationName const EditorPluginDocumentDidChange = @"EditorPluginDocumentDidChange";
static NSNotificationName const EditorPluginScintillaEvent = @"EditorPluginScintillaEvent";
static NSUInteger EditorEventHosts = 0;

void EditorPublishPluginNotification(EditorDocument *document, const SCNotification *notification)
{
	if (EditorEventHosts && NSThread.isMainThread)
		[NSNotificationCenter.defaultCenter postNotificationName:EditorPluginScintillaEvent object:document
			userInfo:@{@"notification": [NSValue valueWithPointer:notification]}];
}

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

static BOOL UTF8Boundary(ScintillaView *view, size_t position, size_t length)
{
	return position == length || (position < length && ([view message:SCI_GETCHARAT wParam:position] & 0xc0) != 0x80);
}

static int PluginReplaceRange(void *context, MacpadDocumentID identifier, size_t start, size_t end, const char *text, size_t length)
{
	ScintillaView *view = DocumentWithID(identifier).editor;
	const auto count = static_cast<size_t>([view message:SCI_GETLENGTH]);
	if (!view || [view message:SCI_GETREADONLY] || start > end || end > count || (!text && length) ||
		(length && ![[NSString alloc] initWithBytes:text length:length encoding:NSUTF8StringEncoding]))
		return 0;
	if (!UTF8Boundary(view, start, count) || !UTF8Boundary(view, end, count))
		return 0;
	[view message:SCI_SETTARGETRANGE wParam:start lParam:end];
	return [view message:SCI_REPLACETARGET wParam:length lParam:reinterpret_cast<sptr_t>(text ?: "")] >= 0;
}

@interface EditorPlugins () <NSWindowDelegate>
- (BOOL)showPanel:(NSString *)identifier title:(NSString *)title view:(NSView *)view;
- (void)closePanel:(NSString *)identifier;
- (NSInteger)commandIndex:(NSString *)identifier descriptor:(const void *)descriptor;
- (int)registerToolbarCommand:(NSString *)command symbol:(NSString *)symbol descriptor:(const void *)descriptor;
- (int)reserveDecorations:(size_t)count markers:(BOOL)markers descriptor:(const void *)descriptor;
- (BOOL)ownsDecoration:(int)number markers:(BOOL)markers descriptor:(const void *)descriptor;
- (int)subscribe:(uint32_t)kinds descriptor:(const void *)descriptor;
- (int)mapWindowsModule:(NSString *)module internalID:(int)identifier command:(NSString *)command descriptor:(const void *)descriptor;
@end

struct PluginInvocation
{
	__unsafe_unretained EditorPlugins *plugins;
	const void *descriptor;
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

static int PluginDocumentFlags(void *context, MacpadDocumentID identifier, uint32_t *flags)
{
	EditorDocument *document = DocumentWithID(identifier);
	if (!flags || !document)
		return 0;
	*flags = (document.isDocumentEdited ? MACPAD_DOCUMENT_EDITED : 0) |
		([document.editor message:SCI_GETREADONLY] ? MACPAD_DOCUMENT_READ_ONLY : 0) |
		(document.isMonitoring ? MACPAD_DOCUMENT_MONITORED : 0) | (document.isTabPinned ? MACPAD_DOCUMENT_PINNED : 0);
	return 1;
}

static size_t PluginCopyLanguage(void *context, MacpadDocumentID identifier, char *buffer, size_t capacity)
{
	NSData *language = [DocumentWithID(identifier).languageIdentifier dataUsingEncoding:NSUTF8StringEncoding];
	return CopyDocumentBytes(language.bytes, language.length, buffer, capacity);
}

static size_t PluginCopyRange(void *context, MacpadDocumentID identifier, size_t start, size_t end, char *buffer, size_t capacity)
{
	ScintillaView *view = DocumentWithID(identifier).editor;
	const auto length = static_cast<size_t>([view message:SCI_GETLENGTH]);
	if (!view || start >= end || !UTF8Boundary(view, start, length) || !UTF8Boundary(view, end, length))
		return 0;
	const auto *text = reinterpret_cast<const char *>([view message:SCI_GETCHARACTERPOINTER]);
	return CopyDocumentBytes(text + start, end - start, buffer, capacity);
}

static size_t PluginSelectionCount(void *context, MacpadDocumentID identifier)
{
	return [DocumentWithID(identifier).editor message:SCI_GETSELECTIONS];
}

static int PluginSelectionAt(void *context, MacpadDocumentID identifier, size_t index, MacpadSelectionV3 *selection)
{
	ScintillaView *view = DocumentWithID(identifier).editor;
	if (!view || !selection || index >= static_cast<size_t>([view message:SCI_GETSELECTIONS]))
		return 0;
	selection->anchor = [view message:SCI_GETSELECTIONNANCHOR wParam:index];
	selection->caret = [view message:SCI_GETSELECTIONNCARET wParam:index];
	return 1;
}

static int PluginSetSelection(void *context, MacpadDocumentID identifier, MacpadSelectionV3 selection)
{
	ScintillaView *view = DocumentWithID(identifier).editor;
	const auto length = static_cast<size_t>([view message:SCI_GETLENGTH]);
	if (!view || !UTF8Boundary(view, selection.anchor, length) || !UTF8Boundary(view, selection.caret, length))
		return 0;
	[view message:SCI_SETSEL wParam:selection.anchor lParam:selection.caret];
	return 1;
}

static int PluginActivateDocument(void *context, MacpadDocumentID identifier)
{
	EditorDocument *document = DocumentWithID(identifier);
	if (!document)
		return 0;
	[document showWindows];
	return 1;
}

static int PluginAddToolbarButton(void *context, const char *command, const char *symbol)
{
	if (!NSThread.isMainThread || !context || !command || !symbol)
		return 0;
	const auto &invocation = *static_cast<const PluginInvocation *>(context);
	return [invocation.plugins registerToolbarCommand:[NSString stringWithUTF8String:command]
		symbol:[NSString stringWithUTF8String:symbol] descriptor:invocation.descriptor];
}

static int PluginReserveMarkers(void *context, size_t count)
{
	if (!NSThread.isMainThread || !context)
		return -1;
	const auto &invocation = *static_cast<const PluginInvocation *>(context);
	return [invocation.plugins reserveDecorations:count markers:YES descriptor:invocation.descriptor];
}

static int PluginReserveIndicators(void *context, size_t count)
{
	if (!NSThread.isMainThread || !context)
		return -1;
	const auto &invocation = *static_cast<const PluginInvocation *>(context);
	return [invocation.plugins reserveDecorations:count markers:NO descriptor:invocation.descriptor];
}

static int PluginSetMarker(void *context, MacpadDocumentID document, int number, size_t line, int present)
{
	ScintillaView *view = DocumentWithID(document).editor;
	if (!context || !view || line >= static_cast<size_t>([view message:SCI_GETLINECOUNT]))
		return 0;
	const auto &invocation = *static_cast<const PluginInvocation *>(context);
	if (![invocation.plugins ownsDecoration:number markers:YES descriptor:invocation.descriptor])
		return 0;
	if (present)
	{
		[view message:SCI_MARKERDEFINE wParam:number lParam:SC_MARK_SMALLRECT];
		[view message:SCI_MARKERSETBACK wParam:number lParam:0xFF8800];
		[view message:SCI_MARKERADD wParam:line lParam:number];
	}
	else
		[view message:SCI_MARKERDELETE wParam:line lParam:number];
	return 1;
}

static int PluginMarkRange(void *context, MacpadDocumentID document, int number, size_t start, size_t end, int present)
{
	ScintillaView *view = DocumentWithID(document).editor;
	auto length = static_cast<size_t>([view message:SCI_GETLENGTH]);
	if (!context || !view || start >= end || !UTF8Boundary(view, start, length) || !UTF8Boundary(view, end, length))
		return 0;
	const auto &invocation = *static_cast<const PluginInvocation *>(context);
	if (![invocation.plugins ownsDecoration:number markers:NO descriptor:invocation.descriptor])
		return 0;
	[view message:SCI_INDICSETSTYLE wParam:number lParam:INDIC_ROUNDBOX];
	[view message:SCI_INDICSETFORE wParam:number lParam:0xFF8800];
	const auto previous = [view message:SCI_GETINDICATORCURRENT];
	[view message:SCI_SETINDICATORCURRENT wParam:number];
	[view message:present ? SCI_INDICATORFILLRANGE : SCI_INDICATORCLEARRANGE wParam:start lParam:end - start];
	[view message:SCI_SETINDICATORCURRENT wParam:previous];
	return 1;
}

static int PluginSubscribe(void *context, uint32_t kinds)
{
	if (!NSThread.isMainThread || !context)
		return 0;
	const auto &invocation = *static_cast<const PluginInvocation *>(context);
	return [invocation.plugins subscribe:kinds descriptor:invocation.descriptor];
}

static int PluginMapWindowsShortcut(void *context, const char *command, const char *module, int identifier)
{
	if (!NSThread.isMainThread || !context || !command || !module)
		return 0;
	const auto &invocation = *static_cast<const PluginInvocation *>(context);
	return [invocation.plugins mapWindowsModule:[NSString stringWithUTF8String:module] internalID:identifier
		command:[NSString stringWithUTF8String:command] descriptor:invocation.descriptor];
}

static MacpadEditorV3 PluginEditorV3(PluginInvocation *invocation)
{
	return {sizeof(MacpadEditorV3), PluginEditor(invocation), PluginDocumentFlags, PluginCopyLanguage, PluginCopyRange,
		PluginSelectionCount, PluginSelectionAt, PluginSetSelection, PluginActivateDocument, PluginAddToolbarButton,
		PluginReserveMarkers, PluginReserveIndicators, PluginSubscribe, PluginSetMarker, PluginMarkRange, PluginMapWindowsShortcut};
}

static NSString *StableIdentifier(const char *identifier)
{
	NSString *value = identifier ? [NSString stringWithUTF8String:identifier] : nil;
	return value.length && ![value containsString:@"/"] ? value : nil;
}

struct PluginCommand
{
	const MacpadPluginV1 *v1;
	const MacpadPluginV2 *v2;
	const MacpadPluginV3 *v3;
	size_t index;
};

@implementation EditorPlugins
{
	std::vector<void *> _libraries;
	std::vector<PluginCommand> _commands;
	std::vector<const MacpadPluginV2 *> _eventHandlers;
	std::vector<const MacpadPluginV3 *> _eventHandlersV3;
	NSMutableDictionary<NSString *, NSString *> *_loadedTitles;
	NSMutableDictionary<NSString *, NSPanel *> *_panels;
	NSMutableDictionary<NSNumber *, NSImage *> *_toolbar;
	NSMutableDictionary<NSValue *, NSMutableIndexSet *> *_markers;
	NSMutableDictionary<NSValue *, NSMutableIndexSet *> *_indicators;
	NSMutableDictionary<NSValue *, NSNumber *> *_subscriptions;
	NSMutableDictionary<NSString *, NSString *> *_legacyShortcuts;
	const MacpadPluginV3 *_registeringPlugin;
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
		_toolbar = [NSMutableDictionary dictionary];
		_markers = [NSMutableDictionary dictionary];
		_indicators = [NSMutableDictionary dictionary];
		_subscriptions = [NSMutableDictionary dictionary];
		_legacyShortcuts = [NSMutableDictionary dictionary];
		NSMutableSet<NSString *> *pluginIDs = [NSMutableSet set];
		for (NSURL *url in self.pluginFiles)
		{
			void *library = dlopen(url.fileSystemRepresentation, RTLD_LOCAL | RTLD_NOW);
			if (!library)
			{
				NSLog(@"macpad++ plugin %@: %s", url.lastPathComponent, dlerror());
				continue;
			}
			auto entryV3 = reinterpret_cast<MacpadPluginEntryV3>(dlsym(library, "macpad_plugin_v3"));
			if (entryV3)
			{
				const MacpadPluginV3 *plugin = entryV3();
				NSString *identifier = plugin && plugin->version == MACPAD_PLUGIN_ABI_V3 &&
					plugin->structSize >= offsetof(MacpadPluginV3, onReady) ? StableIdentifier(plugin->identifier) : nil;
				NSString *title = identifier && plugin->title ? [NSString stringWithUTF8String:plugin->title] : nil;
				if (!title.length || [pluginIDs containsObject:identifier] || plugin->commandCount > 256 ||
					(plugin->commandCount && !plugin->commands))
				{
					NSLog(@"macpad++ plugin %@: incompatible version 3 API", url.lastPathComponent);
					dlclose(library);
					continue;
				}
				[pluginIDs addObject:identifier];
				_libraries.push_back(library);
				_loadedTitles[url.lastPathComponent] = title;
				if (plugin->onDocumentEvent)
					_eventHandlersV3.push_back(plugin);
				NSMutableSet<NSString *> *commandIDs = [NSMutableSet set];
				for (size_t index = 0; index < plugin->commandCount; ++index)
				{
					const auto &command = plugin->commands[index];
					NSString *commandID = StableIdentifier(command.identifier);
					if (commandID && command.run && command.title && [NSString stringWithUTF8String:command.title].length &&
						![commandIDs containsObject:commandID])
					{
						[commandIDs addObject:commandID];
						_commands.push_back({nullptr, nullptr, plugin, index});
					}
				}
				if (plugin->structSize >= offsetof(MacpadPluginV3, onReady) + sizeof(plugin->onReady) && plugin->onReady)
				{
					PluginInvocation invocation{self, plugin};
					auto editor = PluginEditorV3(&invocation);
					_registeringPlugin = plugin;
					plugin->onReady(&editor);
					_registeringPlugin = nullptr;
				}
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
						_commands.push_back({nullptr, plugin, nullptr, index});
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
			_commands.push_back({command, nullptr, nullptr, 0});
			_loadedTitles[url.lastPathComponent] = [NSString stringWithUTF8String:command->title];
		}
		if (!_eventHandlers.empty() || !_eventHandlersV3.empty())
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
				NSURLErrorKey: source, NSLocalizedDescriptionKey: EditorUIString(@"Choose a regular macOS .dylib plugin file.")}];
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
	if (_subscriptions.count)
		--EditorEventHosts;
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

- (NSInteger)commandIndex:(NSString *)identifier descriptor:(const void *)descriptor
{
	for (size_t i = 0; i < _commands.size(); ++i)
	{
		const auto &command = _commands[i];
		if (command.v3 && command.v3 == descriptor &&
			[identifier isEqualToString:@(command.v3->commands[command.index].identifier)])
			return i;
	}
	return NSNotFound;
}

- (int)registerToolbarCommand:(NSString *)command symbol:(NSString *)symbol descriptor:(const void *)descriptor
{
	if (!_registeringPlugin || descriptor != _registeringPlugin)
		return 0;
	NSInteger index = [self commandIndex:command descriptor:descriptor];
	NSImage *image = symbol.length ? [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] : nil;
	if (index == NSNotFound || !image)
		return 0;
	_toolbar[@(index)] = image;
	return 1;
}

- (NSArray<NSToolbarItem *> *)toolbarItems
{
	NSMutableArray *items = [NSMutableArray array];
	NSUInteger position = 1;
	for (NSNumber *index in [_toolbar.allKeys sortedArrayUsingSelector:@selector(compare:)])
	{
		if ([EditorResources.shared toolbarHidesPluginAtIndex:position++])
			continue;
		const auto &command = _commands[index.unsignedIntegerValue];
		const auto &metadata = command.v3->commands[command.index];
		NSString *key = [NSString stringWithFormat:@"plugin/%s/%s", command.v3->identifier, metadata.identifier];
		NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:key];
		item.label = @(metadata.title);
		item.toolTip = item.label;
		item.image = _toolbar[index];
		item.tag = index.integerValue;
		item.target = self;
		item.action = @selector(runPlugin:);
		[items addObject:item];
	}
	return items;
}

- (int)reserveDecorations:(size_t)count markers:(BOOL)markers descriptor:(const void *)descriptor
{
	static int nextMarker = 0;
	static int nextIndicator = 16;
	int &next = markers ? nextMarker : nextIndicator;
	const int limit = markers ? 20 : INDICATOR_IME;
	if (!count || count > static_cast<size_t>(limit - next))
		return -1;
	auto storage = markers ? _markers : _indicators;
	NSValue *key = [NSValue valueWithPointer:descriptor];
	NSMutableIndexSet *set = storage[key] ?: (storage[key] = [NSMutableIndexSet indexSet]);
	const int first = next;
	[set addIndexesInRange:NSMakeRange(first, count)];
	next += static_cast<int>(count);
	return first;
}

- (BOOL)ownsDecoration:(int)number markers:(BOOL)markers descriptor:(const void *)descriptor
{
	return number >= 0 && [(markers ? _markers : _indicators)[[NSValue valueWithPointer:descriptor]] containsIndex:number];
}

- (int)subscribe:(uint32_t)kinds descriptor:(const void *)descriptor
{
	const auto *plugin = static_cast<const MacpadPluginV3 *>(descriptor);
	const uint32_t supported = MACPAD_NOTIFY_MODIFIED | MACPAD_NOTIFY_UPDATE | MACPAD_NOTIFY_CHARACTER |
		MACPAD_NOTIFY_MARGIN | MACPAD_NOTIFY_ZOOM | MACPAD_NOTIFY_SAVEPOINT;
	if (!plugin || (kinds & ~supported) || plugin->structSize < offsetof(MacpadPluginV3, onEditorNotification) +
		sizeof(plugin->onEditorNotification) || !plugin->onEditorNotification)
		return 0;
	NSValue *key = [NSValue valueWithPointer:descriptor];
	const BOOL previous = _subscriptions.count > 0;
	if (kinds)
		_subscriptions[key] = @(kinds);
	else
		[_subscriptions removeObjectForKey:key];
	if (!previous && _subscriptions.count)
	{
		++EditorEventHosts;
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scintillaEvent:) name:EditorPluginScintillaEvent object:nil];
	}
	else if (previous && !_subscriptions.count)
	{
		--EditorEventHosts;
		[NSNotificationCenter.defaultCenter removeObserver:self name:EditorPluginScintillaEvent object:nil];
	}
	return 1;
}

- (void)scintillaEvent:(NSNotification *)message
{
	if (_dispatchingEvent)
		return;
	const auto *source = static_cast<const SCNotification *>([message.userInfo[@"notification"] pointerValue]);
	uint32_t kind;
	switch (source->nmhdr.code)
	{
		case SCN_MODIFIED: kind = MACPAD_NOTIFY_MODIFIED; break;
		case SCN_UPDATEUI: kind = MACPAD_NOTIFY_UPDATE; break;
		case SCN_CHARADDED: kind = MACPAD_NOTIFY_CHARACTER; break;
		case SCN_MARGINCLICK: case SCN_MARGINRIGHTCLICK: kind = MACPAD_NOTIFY_MARGIN; break;
		case SCN_ZOOM: kind = MACPAD_NOTIFY_ZOOM; break;
		case SCN_SAVEPOINTLEFT: case SCN_SAVEPOINTREACHED: kind = MACPAD_NOTIFY_SAVEPOINT; break;
		default: return;
	}
	const MacpadEditorNotificationV3 event{kind, source->nmhdr.code, source->position, source->length,
		static_cast<uint32_t>(source->modificationType), static_cast<uint32_t>(source->updated), source->ch, source->margin};
	EditorDocument *document = message.object;
	_dispatchingEvent = YES;
	NSDictionary *subscriptions = [_subscriptions copy];
	for (NSValue *key in subscriptions)
		if ([subscriptions[key] unsignedIntValue] & kind)
		{
			const auto *plugin = static_cast<const MacpadPluginV3 *>(key.pointerValue);
			PluginInvocation invocation{self, plugin};
			auto editor = PluginEditorV3(&invocation);
			plugin->onEditorNotification(&editor, document.runtimeIdentifier, &event);
		}
	_dispatchingEvent = NO;
}

static NSString *WindowsShortcutKey(NSString *module, NSInteger identifier)
{
	return [NSString stringWithFormat:@"%@/%ld", module.lastPathComponent.stringByDeletingPathExtension.lowercaseString, identifier];
}

- (int)mapWindowsModule:(NSString *)module internalID:(int)identifier command:(NSString *)command descriptor:(const void *)descriptor
{
	if (!_registeringPlugin || descriptor != _registeringPlugin)
		return 0;
	NSInteger index = [self commandIndex:command descriptor:descriptor];
	if (index == NSNotFound || !module.length || identifier < 0)
		return 0;
	NSString *key = WindowsShortcutKey(module, identifier);
	const auto *plugin = _commands[index].v3;
	NSString *value = [NSString stringWithFormat:@"plugin/%s/%@", plugin->identifier, command];
	if (_legacyShortcuts[key] && ![_legacyShortcuts[key] isEqualToString:value])
		return 0;
	_legacyShortcuts[key] = value;
	return 1;
}

- (NSString *)shortcutForWindowsModule:(NSString *)module internalID:(NSInteger)identifier
{
	return _legacyShortcuts[WindowsShortcutKey(module, identifier)];
}

- (void)populateMenu:(NSMenu *)menu
{
	NSMutableDictionary<NSValue *, NSMenu *> *groups = [NSMutableDictionary dictionary];
	for (size_t i = 0; i < _commands.size(); ++i)
	{
		const PluginCommand &command = _commands[i];
		NSMenu *target = menu;
		if (command.v2 || command.v3)
		{
			const void *descriptor = command.v3 ? static_cast<const void *>(command.v3) : static_cast<const void *>(command.v2);
			NSValue *identifier = [NSValue valueWithPointer:descriptor];
			target = groups[identifier];
			if (!target)
			{
				NSString *title = [NSString stringWithUTF8String:command.v3 ? command.v3->title : command.v2->title];
				NSMenuItem *parent = [menu addItemWithTitle:title action:nullptr keyEquivalent:@""];
				target = [[NSMenu alloc] initWithTitle:title];
				parent.submenu = target;
				groups[identifier] = target;
			}
		}
		const auto *title = command.v3 ? command.v3->commands[command.index].title :
			command.v2 ? command.v2->commands[command.index].title : command.v1->title;
		NSMenuItem *item = [target addItemWithTitle:[NSString stringWithUTF8String:title]
			action:@selector(runPlugin:) keyEquivalent:@""];
		item.target = self;
		item.tag = i;
		if (command.v3)
			item.representedObject = [NSString stringWithFormat:@"plugin/%s/%s", command.v3->identifier,
				command.v3->commands[command.index].identifier];
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
	if (command.v3)
	{
		PluginInvocation invocation{self, command.v3};
		auto editor = PluginEditorV3(&invocation);
		command.v3->commands[command.index].run(&editor);
	}
	else if (command.v2)
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
	auto event = static_cast<MacpadDocumentEventV3>([notification.userInfo[@"event"] intValue]);
	if (event == MACPAD_EVENT_ACTIVATED)
	{
		if (_lastActive == document.runtimeIdentifier)
			return;
		_lastActive = document.runtimeIdentifier;
	}
	else if (event == MACPAD_EVENT_CLOSED && _lastActive == document.runtimeIdentifier)
		_lastActive = 0;
	_dispatchingEvent = YES;
	if (event <= MACPAD_EVENT_CLOSED)
		for (const auto *plugin : _eventHandlers)
		{
			PluginInvocation invocation{self, plugin};
			auto editor = PluginEditor(&invocation);
			plugin->onDocumentEvent(&editor, static_cast<MacpadDocumentEventV2>(event), document.runtimeIdentifier);
		}
	for (const auto *plugin : _eventHandlersV3)
	{
		PluginInvocation invocation{self, plugin};
		auto editor = PluginEditorV3(&invocation);
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

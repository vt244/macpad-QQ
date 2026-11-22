// SPDX-License-Identifier: GPL-3.0-only
#import "EditorResources.h"
#import "ScintillaView.h"

#include <algorithm>
#include <charconv>
#include <optional>
#include <sstream>
#include <string_view>

#include "ILexer.h"
#include "Lexilla.h"
#include "SciLexer.h"
#include "pugiconfig.hpp"
// The Windows fork enables floating-point charconv, which needs newer macOS libraries.
#undef PUGIXML_CHARCONV_FLOAT
#include "pugixml.hpp"

static NSString *String(const char *text)
{
	return [NSString stringWithUTF8String:text] ?: @"";
}

static bool LoadXML(pugi::xml_document &document, NSURL *url)
{
	NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
	return data && document.load_buffer(data.bytes, data.length);
}

static pugi::xml_node TranslationRoot(pugi::xml_document &document)
{
	return document.child("NotepadPlus").child("Native-Langue");
}

static NSString *MenuLabel(NSString *label)
{
	// A single ampersand marks a Win32 keyboard mnemonic. A double one is literal.
	NSMutableString *result = [NSMutableString string];
	for (NSUInteger i = 0; i < label.length; ++i)
	{
		const unichar character = [label characterAtIndex:i];
		if (character == '&')
		{
			if (i + 1 == label.length || [label characterAtIndex:i + 1] != '&')
				continue;
			++i;
		}
		[result appendFormat:@"%C", character];
	}
	return result;
}

static void CollectLabels(pugi::xml_node node, NSMutableDictionary<NSString *, NSString *> *labels)
{
	if (auto name = node.attribute("name"))
	{
		auto key = node.attribute("menuId");
		if (!key)
			key = node.attribute("subMenuId");
		if (!key)
			key = node.attribute("id");
		if (key && !name.empty())
			labels[String(key.value())] = MenuLabel(String(name.value()));
	}
	for (auto child : node.children())
		CollectLabels(child, labels);
}

static std::optional<int> Color(pugi::xml_attribute attribute)
{
	std::string_view value = attribute.value();
	if (value.size() != 6)
		return std::nullopt;
	unsigned int rgb = 0;
	auto parsed = std::from_chars(value.data(), value.data() + value.size(), rgb, 16);
	if (parsed.ec != std::errc() || parsed.ptr != value.data() + value.size())
		return std::nullopt;
	return ((rgb & 0xff) << 16) | (rgb & 0xff00) | (rgb >> 16);
}

static void ApplyStyle(ScintillaView *view, int index, pugi::xml_node attributes)
{
	const int colorStyle = attributes.attribute("colorStyle").as_int(3);
	if (auto color = Color(attributes.attribute("fgColor")); color && (colorStyle & 1))
		[view message:SCI_STYLESETFORE wParam:index lParam:*color];
	if (auto color = Color(attributes.attribute("bgColor")); color && (colorStyle & 2))
		[view message:SCI_STYLESETBACK wParam:index lParam:*color];
	NSString *font = String(attributes.attribute("fontName").value());
	if (font.length && [NSFont fontWithName:font size:12])
		[view setStringProperty:SCI_STYLESETFONT parameter:index value:font];
	if (int size = attributes.attribute("fontSize").as_int(); size > 0 && size <= 144)
		[view message:SCI_STYLESETSIZE wParam:index lParam:size];
	auto flags = attributes.attribute("fontStyle");
	if (!String(flags.value()).length)
		return;
	[view message:SCI_STYLESETBOLD wParam:index lParam:(flags.as_int() & 1) != 0];
	[view message:SCI_STYLESETITALIC wParam:index lParam:(flags.as_int() & 2) != 0];
	[view message:SCI_STYLESETUNDERLINE wParam:index lParam:(flags.as_int() & 4) != 0];
}

static void SetProperty(ScintillaView *view, const char *key, NSString *value)
{
	[view message:SCI_SETPROPERTY wParam:reinterpret_cast<uptr_t>(key)
		lParam:reinterpret_cast<sptr_t>(value.UTF8String)];
}

@implementation EditorResources
{
	NSDictionary<NSString *, NSString *> *_labels;
	NSDictionary<NSString *, NSString *> *_englishLabels;
	NSDictionary<NSString *, NSString *> *_findLabels;
	NSMutableDictionary<NSString *, id> *_settings;
	pugi::xml_document _languages;
	pugi::xml_document _theme;
}

+ (instancetype)shared
{
	static EditorResources *resources = [[self alloc] init];
	return resources;
}

- (instancetype)init
{
	self = [super init];
	if (self)
	{
		NSFileManager *fm = NSFileManager.defaultManager;
		NSString *override = NSProcessInfo.processInfo.environment[@"MACPAD_DATA_DIR"];
		NSURL *support = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
		_profile = override.isAbsolutePath ? [NSURL fileURLWithPath:override isDirectory:YES] :
			[support URLByAppendingPathComponent:@"macpad++/profile" isDirectory:YES];
		LoadXML(_languages, [NSBundle.mainBundle URLForResource:@"langs.model" withExtension:@"xml"]);
		pugi::xml_document english;
		NSMutableDictionary *englishLabels = [NSMutableDictionary dictionary];
		if (LoadXML(english, [NSBundle.mainBundle URLForResource:@"english" withExtension:@"xml" subdirectory:@"localization"]))
			CollectLabels(TranslationRoot(english).child("Menu").child("Main"), englishLabels);
		_englishLabels = [englishLabels copy];
		NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfURL:[_profile URLByAppendingPathComponent:@"native-settings.plist"]];
		_settings = [preferences mutableCopy] ?: [NSMutableDictionary dictionary];
		NSURL *theme = [preferences[@"theme"] isKindOfClass:NSString.class] ? self.themes[preferences[@"theme"]] : nil;
		NSURL *translation = [preferences[@"translation"] isKindOfClass:NSString.class] ? self.translations[preferences[@"translation"]] : nil;
		[self loadTheme:theme];
		[self loadTranslation:translation];
	}
	return self;
}

- (NSDictionary<NSString *, NSURL *> *)catalog:(NSString *)folder
{
	NSMutableDictionary<NSString *, NSURL *> *files = [NSMutableDictionary dictionary];
	for (NSURL *base in @[NSBundle.mainBundle.resourceURL, _profile])
	{
		NSURL *directory = [base URLByAppendingPathComponent:folder isDirectory:YES];
		NSArray<NSURL *> *urls = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
			includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nullptr];
		for (NSURL *url in urls)
		{
			NSNumber *regular = nil;
			[url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nullptr];
			if (regular.boolValue && [url.pathExtension.lowercaseString isEqualToString:@"xml"])
				files[url.lastPathComponent] = url;
		}
	}
	return files;
}

- (NSDictionary<NSString *, NSURL *> *)themes
{
	return [self catalog:@"themes"];
}

- (NSDictionary<NSString *, NSURL *> *)translations
{
	return [self catalog:@"localization"];
}

- (NSDictionary<NSString *, NSString *> *)languages
{
	NSMutableDictionary *languages = [NSMutableDictionary dictionary];
	for (auto entry : _theme.child("NotepadPlus").child("LexerStyles").children("LexerType"))
	{
		NSString *name = String(entry.attribute("name").value());
		NSString *description = String(entry.attribute("desc").value());
		if (name.length && description.length)
			languages[name] = description;
	}
	languages[@"normal"] = @"Normal Text";
	return languages;
}

- (NSArray<NSString *> *)commentSymbolsForLanguage:(NSString *)identifier
{
	auto language = _languages.child("NotepadPlus").child("Languages").find_child_by_attribute("Language", "name",
		(identifier ?: @"normal").UTF8String);
	return @[String(language.attribute("commentLine").value()), String(language.attribute("commentStart").value()),
		String(language.attribute("commentEnd").value())];
}

- (void)loadTheme:(NSURL *)url
{
	_selectedTheme = url;
	if (!LoadXML(_theme, url) || !_theme.child("NotepadPlus").child("GlobalStyles"))
	{
		_selectedTheme = nil;
		LoadXML(_theme, [NSBundle.mainBundle URLForResource:@"stylers.model" withExtension:@"xml"]);
	}
}

- (void)loadTranslation:(NSURL *)url
{
	_selectedTranslation = url;
	pugi::xml_document document;
	NSMutableDictionary *labels = [NSMutableDictionary dictionary];
	NSMutableDictionary *findLabels = [NSMutableDictionary dictionary];
	NSURL *existing = [_profile URLByAppendingPathComponent:@"nativeLang.xml"];
	if (LoadXML(document, url ?: existing))
	{
		auto root = TranslationRoot(document);
		auto menu = root.child("Menu");
		CollectLabels(menu.child("Main"), labels);
		for (auto item : menu.child("TabBar").children("Item"))
		{
			if (auto id = item.attribute("CMDID"))
			{
				NSString *key = [@"tab:" stringByAppendingString:String(id.value())];
				labels[key] = MenuLabel(String(item.attribute("name").value()));
				if (auto alternative = item.attribute("alternativeName"))
					labels[[@"alt:" stringByAppendingString:key]] = MenuLabel(String(alternative.value()));
			}
		}
		for (auto item : root.child("DocList").children())
			labels[[@"docList:" stringByAppendingString:String(item.name())]] = String(item.attribute("name").value());
		for (const char *section : {"ClipboardHistory", "AsciiInsertion", "DocumentMap", "FunctionList", "FolderAsWorkspace", "ProjectManager"})
			for (auto item : root.child(section).children())
				if (auto name = item.attribute("name"))
					labels[[NSString stringWithFormat:@"%s:%s", section, item.name()]] = String(name.value());
		for (const char *section : {"StyleConfig", "ShortcutMapper", "Preference", "UserDefine", "ColumnEditor", "FindInFinder"})
		{
			auto dialog = root.child("Dialog").child(section);
			labels[[NSString stringWithFormat:@"%s:title", section]] = String(dialog.attribute("title").value());
			NSMutableDictionary *controls = [NSMutableDictionary dictionary];
			CollectLabels(dialog, controls);
			for (NSString *identifier in controls)
				labels[[NSString stringWithFormat:@"%s:%@", section, identifier]] = controls[identifier];
		}
		auto misc = root.child("MiscStrings");
		labels[@"find-result-caption"] = String(misc.child("find-result-caption").attribute("value").value());
		for (auto item : misc.children())
			if (std::string_view(item.name()).starts_with("finder-") || std::string_view(item.name()).starts_with("statusbar-"))
				labels[String(item.name())] = String(item.attribute("value").value());
		auto find = root.child("Dialog").child("Find");
		CollectLabels(find, findLabels);
		for (const char *title : {"titleFind", "titleReplace", "titleFindInFiles", "titleFindInProjects", "titleMark"})
			if (auto value = find.attribute(title); value && *value.value())
				findLabels[String(title)] = String(value.value());
	}
	_findLabels = [findLabels copy];
	_labels = [labels copy];
}

- (void)savePreferences
{
	[NSFileManager.defaultManager createDirectoryAtURL:_profile withIntermediateDirectories:YES attributes:nil error:nullptr];
	_settings[@"theme"] = _selectedTheme.lastPathComponent ?: @"";
	_settings[@"translation"] = _selectedTranslation.lastPathComponent ?: @"";
	[_settings writeToURL:[_profile URLByAppendingPathComponent:@"native-settings.plist"] error:nullptr];
}

- (id)setting:(NSString *)name fallback:(id)fallback
{
	id value = _settings[name];
	for (Class type in @[NSString.class, NSNumber.class, NSArray.class, NSDictionary.class, NSData.class])
		if ([fallback isKindOfClass:type])
			return [value isKindOfClass:type] ? value : fallback;
	return fallback;
}

- (void)setSetting:(id)value forName:(NSString *)name
{
	_settings[name] = value;
	[self savePreferences];
}

- (void)setSettings:(NSDictionary<NSString *, id> *)settings
{
	[_settings addEntriesFromDictionary:settings];
	[self savePreferences];
}

- (BOOL)importWindowsConfiguration:(NSURL *)url error:(NSError **)error
{
	NSData *source = [NSData dataWithContentsOfURL:url options:0 error:error];
	if (!source)
		return NO;
	pugi::xml_document document;
	auto parsed = document.load_buffer(source.bytes, source.length);
	auto gui = document.child("NotepadPlus").child("GUIConfigs");
	if (!parsed || !gui)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{
				NSURLErrorKey: url, NSLocalizedDescriptionKey: [self label:@"native-invalidConfig" fallback:@"Choose a valid Notepad++ config.xml."]}];
		return NO;
	}
	NSMutableDictionary<NSString *, id> *settings = [NSMutableDictionary dictionary];
	auto config = [&](const char *name) { return gui.find_child_by_attribute("GUIConfig", "name", name); };
	const struct { const char *section, *attribute; NSString *setting; } booleanSettings[] = {
		{"ScintillaPrimaryView", "Wrap", @"wordWrap"}, {"ScintillaPrimaryView", "lineNumberMargin", @"lineNumbers"},
		{"ScintillaPrimaryView", "bookMarkMargin", @"bookmarkMargin"}, {"ScintillaPrimaryView", "indentGuideLine", @"indentGuide"},
		{"ScintillaPrimaryView", "whiteSpaceShow", @"whitespace"}, {"ScintillaPrimaryView", "eolShow", @"showEOL"},
		{"ScintillaPrimaryView", "wrapSymbolShow", @"showWrapSymbol"},
		{"ScintillaPrimaryView", "scrollBeyondLastLine", @"scrollBeyondLastLine"},
		{"ScintillaPrimaryView", "virtualSpace", @"virtualSpace"},
		{"ScintillaPrimaryView", "multiSelection", @"multipleSelections"},
		{"TabSetting", "replaceBySpace", @"insertSpaces"}, {"TabSetting", "backspaceUnindent", @"backspaceUnindent"},
		{"TabBar", "hide", @"hideTabBar"}, {"TabBar", "closeButton", @"tabCloseButtons"},
		{"TabBar", "doubleClick2Close", @"doubleClickClosesTab"},
		{"TabBar", "vertical", @"verticalTabs"}, {"TabBar", "multiLine", @"multilineTabs"},
		{"MISC", "docPeekOnTab", @"tabPreview"},
		{"largeFileRestriction", "isEnabled", @"limitLargeFiles"},
		{"largeFileRestriction", "allowAutoCompletion", @"largeFileCompletion"},
		{"largeFileRestriction", "allowBraceMatch", @"largeFileBraceMatch"},
		{"largeFileRestriction", "deactivateWordWrap", @"largeFileDisableWrap"},
		{"Searching", "fillFindFieldWithSelected", @"fillFindSelection"},
		{"Searching", "fillFindFieldSelectCaret", @"fillFindWord"},
		{"Searching", "FiF_ignoreunsavedChangesInOpenedFiles", @"findFilesOnDisk"},
	};
	for (const auto &entry : booleanSettings)
		if (auto attribute = config(entry.section).attribute(entry.attribute))
		{
			std::string_view value = attribute.value();
			if (value == "yes" || value == "show" || value == "no" || value == "hide")
				settings[entry.setting] = @(value == "yes" || value == "show");
		}
	const struct { const char *section, *attribute; NSString *setting; int minimum, maximum; } integers[] = {
		{"TabSetting", "size", @"tabWidth", 1, 32}, {"Backup", "action", @"backupMode", 0, 2},
		{"Backup", "snapshotBackupTiming", @"checkpointMilliseconds", 250, 600000},
		{"NewDocDefaultSettings", "format", @"newDocumentEOL", 0, 2}, {"NewDocDefaultSettings", "encoding", @"newDocumentEncoding", 0, 7},
		{"auto-completion", "triggerFromNbChar", @"autocompleteMinimum", 1, 9},
		{"largeFileRestriction", "fileSizeMB", @"largeFileMegabytes", 1, 4096},
		{"multiInst", "setting", @"instanceMode", 0, 2}
	};
	for (const auto &entry : integers)
		if (auto attribute = config(entry.section).attribute(entry.attribute))
			settings[entry.setting] = @(std::clamp(attribute.as_int(entry.minimum), entry.minimum, entry.maximum));
	if (auto action = config("auto-completion").attribute("autoCAction"))
		settings[@"autocomplete"] = @(action.as_int() != 0);
	if (auto snapshotMode = config("Backup").attribute("isSnapshotMode"))
		settings[@"checkpointDrafts"] = @(std::string_view(snapshotMode.value()) == "yes");
	if (auto format = config("insertDateTime").attribute("customizedFormat"))
		settings[@"dateTimeFormat"] = String(format.value());
	if (auto engine = config("searchEngine"))
	{
		if (auto choice = engine.attribute("searchEngineChoice"))
		{
			static const NSInteger native[] = {6, 0, 1, 2, 4, 5};
			settings[@"searchEngine"] = @(native[std::clamp(choice.as_int(1), 0, 5)]);
		}
		if (auto format = engine.attribute("searchEngineCustom"))
			settings[@"searchEngineCustom"] = String(format.value());
	}
	settings[@"windowsDockLayout"] = @{};
	if (auto docking = config("DockingManager"))
	{
		const char *sizeNames[] = {"leftWidth", "rightWidth", "topHeight", "bottomHeight"};
		NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
		for (const char *size : sizeNames)
			[sizes addObject:@(std::clamp(docking.attribute(size).as_int(200), 56, 1600))];
		NSMutableDictionary *nativePanels = [NSMutableDictionary dictionary];
		NSMutableDictionary *activeTabs = [NSMutableDictionary dictionary];
		for (auto tab : docking.children("ActiveTabs"))
			activeTabs[@(tab.attribute("cont").as_int(-1))] = @(tab.attribute("activeTab").as_int(-1));
		NSMutableDictionary *containerCounts = [NSMutableDictionary dictionary];
		for (auto pane : docking.children("PluginDlg"))
		{
			NSInteger container = pane.attribute("curr").as_int(-1);
			BOOL visible = pane.attribute("isVisible").as_bool(false);
			NSInteger index = [containerCounts[@(container)] integerValue];
			if (visible)
				containerCounts[@(container)] = @(index + 1);
			std::string_view owner = pane.attribute("pluginName").value();
			if (!owner.ends_with("::InternalFunction"))
				continue;
			NSInteger oldEdge = std::clamp(pane.attribute("prev").as_int(0), 0, 3);
			NSInteger edge = container < 0 ? oldEdge : MIN(container, 4);
			NSInteger dock = edge == 4 ? oldEdge : edge;
			NSMutableDictionary *record = [@{@"edge": @(edge), @"lastDock": @(dock), @"visible": @(visible),
				@"width": dock < 2 ? sizes[dock] : @200, @"height": dock >= 2 ? sizes[dock] : @185,
				@"order": @(index + 1), @"selectedAt": @(index == [activeTabs[@(container)] integerValue] ? 1 : 0)} mutableCopy];
			if (container >= 4)
			{
				record[@"floatingGroup"] = [NSString stringWithFormat:@"windows-dock-%ld", container];
				auto frame = docking.find_child_by_attribute("FloatingWindow", "cont", std::to_string(container).c_str());
				if (frame)
				{
					NSRect screen = NSScreen.mainScreen.visibleFrame;
					CGFloat width = std::clamp(frame.attribute("width").as_int(390), 150, 1600);
					CGFloat height = std::clamp(frame.attribute("height").as_int(240), 85, 1200);
					record[@"floatingFrame"] = NSStringFromRect(NSMakeRect(frame.attribute("x").as_int(0),
						NSMaxY(screen) - frame.attribute("y").as_int(0) - height, width, height));
				}
			}
			nativePanels[[@(pane.attribute("id").as_int(-1)) stringValue]] = record;
		}
		settings[@"windowsDockLayout"] = @{@"sizes": sizes, @"panes": nativePanels};
	}
	if (auto session = config("RememberLastSession"))
		settings[@"rememberSession"] = @(std::string_view(session.child_value()) == "yes");
	if (auto mru = config("MRU"))
		settings[@"mruTabSwitcher"] = @(std::string_view(mru.child_value()) == "yes");
	if (auto toolbar = config("ToolBar"))
	{
		std::string_view size = toolbar.child_value();
		if (!size.empty())
			settings[@"toolbarStyle"] = @(size == "small" ? 0 : size == "large" ? 1 : size == "small2" ? 2 : size == "large2" ? 3 : 4);
		if (auto visible = toolbar.attribute("visible"))
			settings[@"hideToolbar"] = @(std::string_view(visible.value()) == "no");
	}
	if (auto status = config("StatusBar"))
		settings[@"hideStatusBar"] = @(std::string_view(status.child_value()) == "hide");
	if (auto change = config("Auto-detection"))
	{
		std::string_view mode = change.child_value();
		settings[@"fileStatusMode"] = @(mode == "no" ? 0 : mode.ends_with("Old") ? 2 : 1);
		settings[@"autoReload"] = @(mode.starts_with("auto"));
		settings[@"reloadToEnd"] = @(mode.find("2End") != std::string_view::npos);
	}
	NSString *backupDirectory = String(config("Backup").attribute("dir").value()).stringByExpandingTildeInPath;
	if (std::string_view(config("Backup").attribute("useCustumDir").value()) == "yes" && backupDirectory.isAbsolutePath)
		settings[@"backupDirectory"] = backupDirectory;
	auto history = document.child("NotepadPlus").child("FindHistory");
	if (history)
	{
		const struct { const char *attribute; NSString *setting; } attributes[] = {
			{"matchCase", @"findMatchCase"}, {"matchWord", @"findWholeWord"}, {"wrap", @"findWrap"}, {"fifRecuisive", @"findRecursive"}
		};
		for (const auto &entry : attributes)
			if (auto value = history.attribute(entry.attribute))
				settings[entry.setting] = @(value.as_bool());
		for (const char *type : {"Find", "Replace"})
		{
			NSMutableArray<NSString *> *values = [NSMutableArray array];
			for (auto entry : history.children(type))
			{
				NSString *value = String(entry.attribute("name").value());
				if (value.length && ![values containsObject:value])
					[values addObject:value];
				if (values.count == 24)
					break;
			}
			if (values.count)
				settings[std::string_view(type) == "Find" ? @"findHistory" : @"replaceHistory"] = values;
		}
	}
	if (![NSFileManager.defaultManager createDirectoryAtURL:_profile withIntermediateDirectories:YES attributes:nil error:error] ||
		![source writeToURL:[_profile URLByAppendingPathComponent:@"imported-config.xml"] options:NSDataWritingAtomic error:error])
		return NO;
	[self setSettings:settings];
	return YES;
}

- (NSString *)label:(NSString *)identifier fallback:(NSString *)fallback
{
	NSString *label = _labels[identifier];
	return label.length ? label : fallback;
}

- (NSString *)englishMenuLabel:(NSString *)identifier { return _englishLabels[identifier]; }

- (NSArray<NSString *> *)commandIDsWithEnglishTitle:(NSString *)title
{
	NSString *(^normalized)(NSString *) = ^NSString *(NSString *value) {
		return [[MenuLabel(value) stringByReplacingOccurrencesOfString:@"..." withString:@"…"]
			stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
	};
	NSString *wanted = normalized(title);
	NSMutableArray *identifiers = [NSMutableArray array];
	for (NSString *key in _englishLabels)
		if (key.integerValue > 0 && [normalized(_englishLabels[key]) isEqualToString:wanted])
			[identifiers addObject:key];
	return [identifiers sortedArrayUsingSelector:@selector(compare:)];
}

- (NSString *)findLabel:(NSString *)identifier fallback:(NSString *)fallback
{
	NSString *label = _findLabels[identifier];
	return label.length ? label : fallback;
}

- (NSString *)translationName:(NSURL *)url
{
	pugi::xml_document document;
	if (LoadXML(document, url))
	{
		NSString *name = String(TranslationRoot(document).attribute("name").value());
		if (name.length)
			return name;
	}
	return url.URLByDeletingPathExtension.lastPathComponent;
}

- (void)chooseTheme:(NSURL *)url
{
	[self loadTheme:url];
	[self savePreferences];
}

- (void)chooseTranslation:(NSURL *)url
{
	[self loadTranslation:url];
	[self savePreferences];
}

- (NSURL *)importXML:(NSURL *)url theme:(BOOL)theme error:(NSError **)error
{
	pugi::xml_document document;
	if (![url.pathExtension.lowercaseString isEqualToString:@"xml"] || !LoadXML(document, url) ||
		!(theme ? document.child("NotepadPlus").child("GlobalStyles") : TranslationRoot(document)))
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError
				userInfo:@{NSURLErrorKey: url, NSLocalizedDescriptionKey: theme ?
					@"This file does not contain a macpad++ theme." : @"This file does not contain a macpad++ translation."}];
		return nil;
	}
	NSURL *directory = [_profile URLByAppendingPathComponent:theme ? @"themes" : @"localization" isDirectory:YES];
	NSFileManager *fm = NSFileManager.defaultManager;
	if (![fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error])
		return nil;
	NSURL *destination = [directory URLByAppendingPathComponent:url.lastPathComponent];
	if (![url.URLByStandardizingPath isEqual:destination.URLByStandardizingPath] &&
		![fm copyItemAtURL:url toURL:destination error:error])
		return nil;
	return destination;
}

- (NSColor *)widgetColor:(NSString *)name background:(BOOL)background
{
	auto widgets = _theme.child("NotepadPlus").child("GlobalStyles");
	auto widget = widgets.find_child_by_attribute("WidgetStyle", "name", name.UTF8String);
	auto color = Color(widget.attribute(background ? "bgColor" : "fgColor"));
	if (!color)
		return nil;
	return [NSColor colorWithSRGBRed:(*color & 255) / 255.0
		green:((*color >> 8) & 255) / 255.0 blue:((*color >> 16) & 255) / 255.0 alpha:1];
}

- (BOOL)usesDarkColors
{
	NSColor *color = [[self widgetColor:@"Default Style" background:YES] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	return color && (0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent) < 0.4;
}

- (void)styleSearchResults:(ScintillaView *)view
{
	auto root = _theme.child("NotepadPlus");
	auto widgets = root.child("GlobalStyles");
	[view message:SCI_STYLERESETDEFAULT];
	[view setStringProperty:SCI_STYLESETFONT parameter:STYLE_DEFAULT value:@"Menlo"];
	[view message:SCI_STYLESETSIZE wParam:STYLE_DEFAULT lParam:11];
	ApplyStyle(view, STYLE_DEFAULT, widgets.find_child_by_attribute("WidgetStyle", "styleID", "32"));
	[view message:SCI_STYLECLEARALL];
	auto type = root.child("LexerStyles").find_child_by_attribute("LexerType", "name", "searchResult");
	if (!type)
	{
		[view message:SCI_STYLESETFORE wParam:1 lParam:0x800000];
		[view message:SCI_STYLESETBACK wParam:1 lParam:0xFFBBBB];
		[view message:SCI_STYLESETFORE wParam:2 lParam:0x008000];
		[view message:SCI_STYLESETBACK wParam:2 lParam:0xD5FFD5];
		[view message:SCI_STYLESETFORE wParam:3 lParam:0x4080FF];
		[view message:SCI_STYLESETFORE wParam:4 lParam:0x0000FF];
		[view message:SCI_STYLESETBACK wParam:4 lParam:0xBFFFFF];
	}
	for (auto style : type.children("WordsStyle"))
	{
		const int id = style.attribute("styleID").as_int();
		if (id >= 1 && id <= 6)
			ApplyStyle(view, id, style);
	}
	[view message:SCI_STYLESETEOLFILLED wParam:1 lParam:1];
	[view message:SCI_STYLESETEOLFILLED wParam:2 lParam:1];
	ApplyStyle(view, STYLE_LINENUMBER, widgets.find_child_by_attribute("WidgetStyle", "styleID", "33"));
}

- (pugi::xml_node)lexerStylesForExtension:(NSString *)extension
{
	if (!extension.length)
		return {};
	auto styles = _theme.child("NotepadPlus").child("LexerStyles");
	for (auto entry : styles.children("LexerType"))
	{
		auto extensions = [String(entry.attribute("ext").value()) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		if ([extensions containsObject:extension])
			return entry;
	}
	return {};
}

- (pugi::xml_node)languageForExtension:(NSString *)extension
{
	auto languages = _languages.child("NotepadPlus").child("Languages");
	if (!extension.length)
		return {};
	if (auto styles = [self lexerStylesForExtension:extension])
		return languages.find_child_by_attribute("Language", "name", styles.attribute("name").value());
	for (auto entry : languages.children("Language"))
	{
		auto extensions = [String(entry.attribute("ext").value()) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		if ([extensions containsObject:extension])
			return entry;
	}
	return {};
}

- (NSString *)configure:(ScintillaView *)view extension:(NSString *)extension language:(NSString *)mode
	syntaxHighlighting:(BOOL)highlight identifier:(NSString **)identifier
{
	auto root = _theme.child("NotepadPlus");
	auto widgets = root.child("GlobalStyles");
	[view message:SCI_STYLERESETDEFAULT];
	[view setStringProperty:SCI_STYLESETFONT parameter:STYLE_DEFAULT value:@"Menlo"];
	[view message:SCI_STYLESETSIZE wParam:STYLE_DEFAULT lParam:12];
	ApplyStyle(view, STYLE_DEFAULT, widgets.find_child_by_attribute("WidgetStyle", "styleID", "32"));
	[view message:SCI_STYLECLEARALL];
	for (auto style : widgets.children("WidgetStyle"))
	{
		const int index = style.attribute("styleID").as_int(-1);
		if (index > STYLE_DEFAULT && index <= STYLE_LASTPREDEFINED)
			ApplyStyle(view, index, style);
	}
	auto selected = widgets.find_child_by_attribute("WidgetStyle", "name", "Selected text colour");
	if (auto color = Color(selected.attribute("bgColor")))
		[view message:SCI_SETSELBACK wParam:1 lParam:*color];
	else
		[view message:SCI_SETSELBACK wParam:0 lParam:0];
	auto currentLine = widgets.find_child_by_attribute("WidgetStyle", "name", "Current line background colour");
	if (auto color = Color(currentLine.attribute("bgColor")))
	{
		[view message:SCI_SETCARETLINEBACK wParam:*color];
		[view message:SCI_SETCARETLINEVISIBLE wParam:1];
	}
	else
		[view message:SCI_SETCARETLINEVISIBLE wParam:0];
	[view message:SCI_SETCARETFORE wParam:[view message:SCI_STYLEGETFORE wParam:STYLE_DEFAULT]];
	auto foldMargin = widgets.find_child_by_attribute("WidgetStyle", "name", "Fold margin");
	if (auto color = Color(foldMargin.attribute("bgColor")))
		[view message:SCI_SETFOLDMARGINCOLOUR wParam:1 lParam:*color];
	else
		[view message:SCI_SETFOLDMARGINCOLOUR wParam:0 lParam:0];
	if (auto color = Color(foldMargin.attribute("fgColor")))
		[view message:SCI_SETFOLDMARGINHICOLOUR wParam:1 lParam:*color];
	else
		[view message:SCI_SETFOLDMARGINHICOLOUR wParam:0 lParam:0];
	auto whitespace = widgets.find_child_by_attribute("WidgetStyle", "name", "White space symbol");
	if (auto color = Color(whitespace.attribute("fgColor")))
		[view message:SCI_SETWHITESPACEFORE wParam:1 lParam:*color];
	else
		[view message:SCI_SETWHITESPACEFORE wParam:0 lParam:0];
	const char *changes[] = {"Change History revert origin", "Change History saved", "Change History modified",
		"Change History revert modified"};
	for (int i = 0; i < std::size(changes); ++i)
		if (auto color = Color(widgets.find_child_by_attribute("WidgetStyle", "name", changes[i]).attribute("bgColor")))
			[view message:SCI_MARKERSETBACK wParam:SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN + i lParam:*color];

	auto language = mode ? _languages.child("NotepadPlus").child("Languages").find_child_by_attribute("Language", "name", mode.UTF8String) :
		[self languageForExtension:extension];
	auto lexerStyles = mode ? root.child("LexerStyles").find_child_by_attribute("LexerType", "name", mode.UTF8String) :
		[self lexerStylesForExtension:extension];
	NSString *name = String(language ? language.attribute("name").value() : lexerStyles.attribute("name").value());
	if (identifier)
		*identifier = name.length ? name : @"normal";
	if (!lexerStyles && name.length)
		lexerStyles = root.child("LexerStyles").find_child_by_attribute("LexerType", "name", name.UTF8String);
	NSDictionary *aliases = @{@"c": @"cpp", @"cs": @"cpp", @"java": @"cpp", @"javascript": @"cpp", @"javascript.js": @"cpp",
		@"rc": @"cpp", @"objc": @"cpp", @"go": @"cpp", @"php": @"hypertext", @"html": @"hypertext", @"sh": @"bash",
		@"batch": @"batch", @"tex": @"latex", @"js": @"cpp", @"typescript": @"cpp", @"shell": @"bash"};
	NSString *lexerName = aliases[name] ?: name;
	Scintilla::ILexer5 *lexer = highlight && lexerName.length ? CreateLexer(lexerName.UTF8String) : nullptr;
	[view message:SCI_SETILEXER wParam:0 lParam:reinterpret_cast<sptr_t>(lexer)];
	SetProperty(view, "fold", @"1");
	NSArray<NSString *> *keywords = @[@"instre1", @"instre2", @"type1", @"type2", @"type3", @"type4", @"type5", @"type6", @"type7", @"type8"];
	for (NSUInteger i = 0; i < keywords.count; ++i)
	{
		auto list = language.find_child_by_attribute("Keywords", "name", keywords[i].UTF8String);
		[view setStringProperty:SCI_SETKEYWORDS parameter:i value:String(list.child_value())];
	}
	for (auto style : lexerStyles.children("WordsStyle"))
	{
		const int index = style.attribute("styleID").as_int(-1);
		if (index >= 0 && index <= STYLE_MAX)
			ApplyStyle(view, index, style);
	}
	if (highlight)
		[view message:SCI_COLOURISE wParam:0 lParam:-1];
	else
		[view message:SCI_CLEARDOCUMENTSTYLE];
	NSString *description = String(lexerStyles.attribute("desc").value());
	return description.length ? description : @"Normal text file";
}
@end

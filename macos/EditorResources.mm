// SPDX-License-Identifier: GPL-3.0-only
#import "EditorResources.h"
#import "ScintillaView.h"

#include <algorithm>
#include <charconv>
#include <climits>
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

static NSString *NormalizedUIString(NSString *text)
{
	return [text stringByReplacingOccurrencesOfString:@"..." withString:@"…"];
}

static void CollectSharedStrings(pugi::xml_node english, pugi::xml_node localized, NSMutableDictionary *strings)
{
	if (!english || !localized)
		return;
	for (const char *key : {"name", "title", "value"})
	{
		NSString *original = NormalizedUIString(MenuLabel(String(english.attribute(key).value())));
		NSString *translation = MenuLabel(String(localized.attribute(key).value()));
		if (original.length && translation.length && !strings[original])
			strings[original] = translation;
	}
	for (auto node : english.children())
	{
		if (node.type() != pugi::node_element)
			continue;
		pugi::xml_node counterpart;
		bool keyed = false;
		for (const char *key : {"id", "menuId", "subMenuId", "CMDID"})
			if (auto id = node.attribute(key))
			{
				keyed = true;
				counterpart = localized.find_child_by_attribute(node.name(), key, id.value());
				break;
			}
		if (!keyed && !node.next_sibling(node.name()) && !node.previous_sibling(node.name()))
			counterpart = localized.child(node.name());
		CollectSharedStrings(node, counterpart, strings);
	}
}

NSString *EditorUIString(NSString *english) { return [EditorResources.shared text:english]; }

NSString *EditorSyntaxExtension(NSURL *fileURL)
{
	NSString *name = fileURL.lastPathComponent.lowercaseString;
	static NSDictionary<NSString *, NSString *> *const namedFiles = @{
		@"makefile": @"mak", @"gnumakefile": @"mak", @"cmakelists.txt": @"cmake",
		@"sconstruct": @"py", @"sconscript": @"py", @"wscript": @"py",
		@"rakefile": @"rb", @"vagrantfile": @"rb",
		@"crontab": @"sh", @"pkgbuild": @"sh", @"apkbuild": @"sh"
	};
	NSString *namedExtension = name.length ? namedFiles[name] : nil;
	if (namedExtension)
		return namedExtension;
	NSString *extension = fileURL.pathExtension.lowercaseString;
	if (!extension.length && [name hasPrefix:@"."])
		return [name substringFromIndex:1];
	return extension ?: @"";
}

NSInteger EditorLineNumberMarginWidth(ScintillaView *view)
{
	NSString *lastLine = [NSString stringWithFormat:@"%ld", [view message:SCI_GETLINECOUNT]];
	const auto width = [view message:SCI_TEXTWIDTH wParam:STYLE_LINENUMBER lParam:reinterpret_cast<sptr_t>(lastLine.UTF8String)];
	return MAX(32, width + 10);
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

// The order matches the globalOverride flags in config.xml and Preferences.
static NSString *const GlobalOverrideSettings[] = {
	@"styleOverrideForeground", @"styleOverrideBackground", @"styleOverrideFont", @"styleOverrideSize",
	@"styleOverrideBold", @"styleOverrideItalic", @"styleOverrideUnderline",
};

static std::optional<int> WidgetThemeColor(pugi::xml_node widgets, const char *name, bool background)
{
	auto style = widgets.find_child_by_attribute("WidgetStyle", "name", name);
	if (!(style.attribute("colorStyle").as_int(3) & (background ? 2 : 1)))
		return std::nullopt;
	return Color(style.attribute(background ? "bgColor" : "fgColor"));
}

static void ApplyFoldTheme(ScintillaView *view, pugi::xml_node widgets, BOOL dark)
{
	const auto foreground = WidgetThemeColor(widgets, "Fold", true).value_or(dark ? 0x282828 : 0xffffff);
	const auto background = WidgetThemeColor(widgets, "Fold", false).value_or(dark ? 0xa0a0a0 : 0x808080);
	const auto active = WidgetThemeColor(widgets, "Fold active", false).value_or(background);
	for (int marker = SC_MARKNUM_FOLDEREND; marker <= SC_MARKNUM_FOLDEROPEN; ++marker)
	{
		[view message:SCI_MARKERSETFORE wParam:marker lParam:foreground];
		[view message:SCI_MARKERSETBACK wParam:marker lParam:background];
		[view message:SCI_MARKERSETBACKSELECTED wParam:marker lParam:active];
	}
	const auto margin = WidgetThemeColor(widgets, "Fold margin", true);
	const auto highlight = WidgetThemeColor(widgets, "Fold margin", false);
	[view message:SCI_SETFOLDMARGINCOLOUR wParam:margin.has_value() lParam:margin.value_or(0)];
	[view message:SCI_SETFOLDMARGINHICOLOUR wParam:highlight.has_value() lParam:highlight.value_or(0)];
}

static void ApplyStyle(ScintillaView *view, int index, pugi::xml_node attributes,
	pugi::xml_node overrideStyle = {}, unsigned overrides = 0)
{
	for (unsigned i = 0; i < 2; ++i)
	{
		const char *name = i ? "bgColor" : "fgColor";
		const auto mask = 1U << i;
		auto color = Color(attributes.attribute(name));
		if (!(attributes.attribute("colorStyle").as_uint(3) & mask))
			color.reset();
		if ((overrides & mask) && (overrideStyle.attribute("colorStyle").as_uint(3) & mask))
			if (auto value = Color(overrideStyle.attribute(name)))
				color = value;
		if (color)
			[view message:i ? SCI_STYLESETBACK : SCI_STYLESETFORE wParam:index lParam:*color];
	}
	NSString *font = String(overrideStyle.attribute("fontName").value());
	if (!(overrides & 4) || !font.length || ![NSFont fontWithName:font size:12])
		font = String(attributes.attribute("fontName").value());
	if (font.length && [NSFont fontWithName:font size:12])
		[view setStringProperty:SCI_STYLESETFONT parameter:index value:font];
	int size = (overrides & 8) ? overrideStyle.attribute("fontSize").as_int() : 0;
	if (size <= 0 || size > 144)
		size = attributes.attribute("fontSize").as_int();
	if (size > 0 && size <= 144)
		[view message:SCI_STYLESETSIZE wParam:index lParam:size];
	auto flags = attributes.attribute("fontStyle");
	auto overrideFlags = overrideStyle.attribute("fontStyle");
	const unsigned messages[] = {SCI_STYLESETBOLD, SCI_STYLESETITALIC, SCI_STYLESETUNDERLINE};
	for (unsigned i = 0; i < std::size(messages); ++i)
	{
		const auto value = (overrides & (16U << i)) && *overrideFlags.value() ? overrideFlags : flags;
		if (*value.value())
			[view message:messages[i] wParam:index lParam:(value.as_int() & (1 << i)) != 0];
	}
}

static NSString *UDLKeywords(const char *source)
{
	std::string result;
	char quote = 0;
	for (size_t i = 0; source[i]; ++i)
	{
		char c = source[i];
		char next = source[i + 1];
		if (c == '\\' && (next == '"' || next == '\'' || next == '\\'))
		{
			result += next;
			++i;
		}
		else if ((c == '"' || c == '\'') && (!quote || quote == c))
			quote = quote ? 0 : c;
		else if (!quote || static_cast<unsigned char>(c) > ' ')
			result += c;
		else if (!result.empty() && source[i - 1] != quote && next != quote && static_cast<unsigned char>(next) > ' ')
			result += quote == '"' ? '\v' : '\b';
	}
	return String(result.c_str());
}

static void SetProperty(ScintillaView *view, const char *key, NSString *value)
{
	[view message:SCI_SETPROPERTY wParam:reinterpret_cast<uptr_t>(key)
		lParam:reinterpret_cast<sptr_t>(value.UTF8String)];
}

static void ConfigureUDL(ScintillaView *view, pugi::xml_node language, pugi::xml_node overrideStyle, unsigned overrides)
{
	auto global = language.child("Settings").child("Global");
	auto prefix = language.child("Settings").child("Prefix");
	auto keywords = language.child("KeywordLists");
	auto list = [&](const char *key) {
		auto entry = keywords.find_child_by_attribute("Keywords", "name", key);
		if (!entry && std::string_view(language.attribute("udlVersion").value()) == "2.0")
		{
			const char *legacy[][2] = {
				{"Numbers, range", "Numbers, additional"}, {"Numbers, prefix2", "Numbers, prefixes"},
				{"Numbers, extras2", "Numbers, extras with prefixes"}, {"Numbers, suffix2", "Numbers, suffixes"},
			};
			for (const auto &names : legacy)
				if (std::string_view(key) == names[0])
					return keywords.find_child_by_attribute("Keywords", "name", names[1]).child_value();
		}
		return entry.child_value();
	};
	[view message:SCI_SETILEXER wParam:0 lParam:reinterpret_cast<sptr_t>(CreateLexer("user"))];
	SetProperty(view, "fold", @"1");
	for (const char *key : {"caseIgnored", "allowFoldOfComments", "foldCompact"})
	{
		std::string property = std::string("userDefine.") + (std::string_view(key) == "caseIgnored" ? "isCaseIgnored" : key);
		SetProperty(view, property.c_str(), std::string_view(global.attribute(key).value()) == "yes" ? @"1" : @"0");
	}
	SetProperty(view, "userDefine.forcePureLC", @(global.attribute("forcePureLC").as_int()).stringValue);
	SetProperty(view, "userDefine.decimalSeparator", @(global.attribute("decimalSeparator").as_int()).stringValue);
	for (int i = 1; i <= 8; ++i)
	{
		auto number = std::to_string(i);
		auto key = "Keywords" + number;
		SetProperty(view, ("userDefine.prefixKeywords" + number).c_str(),
			std::string_view(prefix.attribute(key.c_str()).value()) == "yes" ? @"1" : @"0");
	}
	const char *properties[][2] = {
		{"Comments", "comments"}, {"Delimiters", "delimiters"}, {"Operators1", "operators1"},
		{"Numbers, prefix1", "numberPrefix1"}, {"Numbers, prefix2", "numberPrefix2"},
		{"Numbers, extras1", "numberExtras1"}, {"Numbers, extras2", "numberExtras2"},
		{"Numbers, suffix1", "numberSuffix1"}, {"Numbers, suffix2", "numberSuffix2"}, {"Numbers, range", "numberRange"},
		{"Folders in code1, open", "foldersInCode1Open"}, {"Folders in code1, middle", "foldersInCode1Middle"},
		{"Folders in code1, close", "foldersInCode1Close"},
	};
	for (const auto &entry : properties)
		SetProperty(view, (std::string("userDefine.") + entry[1]).c_str(), String(list(entry[0])));
	const char *wordLists[] = {"Operators2", "Folders in code2, open", "Folders in code2, middle", "Folders in code2, close",
		"Folders in comment, open", "Folders in comment, middle", "Folders in comment, close",
		"Keywords1", "Keywords2", "Keywords3", "Keywords4", "Keywords5", "Keywords6", "Keywords7", "Keywords8"};
	for (NSUInteger i = 0; i < std::size(wordLists); ++i)
		[view setStringProperty:SCI_SETKEYWORDS parameter:i value:UDLKeywords(list(wordLists[i]))];

	const char *styleNames[] = {"DEFAULT", "COMMENTS", "LINE COMMENTS", "NUMBERS",
		"KEYWORDS1", "KEYWORDS2", "KEYWORDS3", "KEYWORDS4", "KEYWORDS5", "KEYWORDS6", "KEYWORDS7", "KEYWORDS8",
		"OPERATORS", "FOLDER IN CODE1", "FOLDER IN CODE2", "FOLDER IN COMMENT",
		"DELIMITERS1", "DELIMITERS2", "DELIMITERS3", "DELIMITERS4", "DELIMITERS5", "DELIMITERS6", "DELIMITERS7", "DELIMITERS8"};
	auto styles = language.child("Styles");
	for (NSUInteger i = 0; i < std::size(styleNames); ++i)
	{
		auto style = styles.find_child_by_attribute("WordsStyle", "name", styleNames[i]);
		ApplyStyle(view, i, style, overrideStyle, overrides);
		char property[32];
		snprintf(property, sizeof(property), "userDefine.nesting.%02u", static_cast<unsigned>(i));
		SetProperty(view, property, @(style.attribute("nesting").as_int()).stringValue);
	}
	// Scintilla uses a numeric ID for each open buffer's nesting cache.
	static int nextBufferID = 0;
	static NSMapTable<ScintillaView *, NSNumber *> *bufferIDs = [NSMapTable weakToStrongObjectsMapTable];
	NSNumber *bufferID = [bufferIDs objectForKey:view];
	if (!bufferID)
	{
		bufferID = @(++nextBufferID);
		[bufferIDs setObject:bufferID forKey:view];
	}
	SetProperty(view, "userDefine.currentBufferID", bufferID.stringValue);
	SetProperty(view, "userDefine.udlName", bufferID.stringValue);
}

@implementation EditorResources
{
	NSBundle *_bundle;
	NSDictionary<NSString *, NSString *> *_labels;
	NSDictionary<NSString *, NSString *> *_englishLabels;
	NSDictionary<NSString *, NSString *> *_findLabels;
	NSDictionary<NSString *, NSString *> *_translatedText;
	pugi::xml_document _english;
	NSMutableDictionary<NSString *, id> *_settings;
	pugi::xml_document _languages;
	pugi::xml_document _theme;
	pugi::xml_document _userLanguages;
	pugi::xml_document _toolbar;
	NSMutableDictionary<NSString *, NSURL *> *_userLanguageFiles;
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
		_bundle = NSBundle.mainBundle;
		NSFileManager *fm = NSFileManager.defaultManager;
		NSString *override = NSProcessInfo.processInfo.environment[@"MACPAD_DATA_DIR"];
		NSURL *support = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
		_profile = override.isAbsolutePath ? [NSURL fileURLWithPath:override isDirectory:YES] :
			[support URLByAppendingPathComponent:@"macpadqq/profile" isDirectory:YES];
		if (!override.isAbsolutePath && ![fm fileExistsAtPath:_profile.path])
		{
			// Keep existing sessions, plugins, and settings when upgrading.
			NSURL *legacyProfile = [support URLByAppendingPathComponent:@"macpad++/profile" isDirectory:YES];
			BOOL isDirectory = NO;
			if ([fm fileExistsAtPath:legacyProfile.path isDirectory:&isDirectory] && isDirectory)
				_profile = legacyProfile;
		}
		LoadXML(_toolbar, [_profile URLByAppendingPathComponent:@"toolbarButtonsConf.xml"]);
		LoadXML(_languages, [_bundle URLForResource:@"langs.model" withExtension:@"xml"]);
		NSMutableDictionary *englishLabels = [NSMutableDictionary dictionary];
		if (LoadXML(_english, [NSBundle.mainBundle URLForResource:@"english" withExtension:@"xml" subdirectory:@"localization"]))
			CollectLabels(TranslationRoot(_english).child("Menu").child("Main"), englishLabels);
		_englishLabels = [englishLabels copy];
		NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfURL:[_profile URLByAppendingPathComponent:@"native-settings.plist"]];
		_settings = [preferences mutableCopy] ?: [NSMutableDictionary dictionary];
		[self loadUserLanguages];
		NSURL *theme = [preferences[@"theme"] isKindOfClass:NSString.class] ? self.themes[preferences[@"theme"]] : nil;
		NSURL *translation = [preferences[@"translation"] isKindOfClass:NSString.class] ? self.translations[preferences[@"translation"]] : nil;
		[self loadTheme:theme];
		[self loadTranslation:translation];
	}
	return self;
}

- (instancetype)initForPreviewWithBundle:(NSBundle *)bundle
{
	self = [super init];
	if (self)
	{
		_bundle = bundle;
		_settings = [NSMutableDictionary dictionary];
		LoadXML(_languages, [_bundle URLForResource:@"langs.model" withExtension:@"xml"]);
		[self loadTheme:nil];
		[self loadUserLanguages];
	}
	return self;
}

- (NSDictionary<NSString *, NSURL *> *)catalog:(NSString *)folder
{
	NSMutableDictionary<NSString *, NSURL *> *files = [NSMutableDictionary dictionary];
	NSURL *resources = _bundle.resourceURL;
	for (NSURL *base in _profile ? @[resources, _profile] : (resources ? @[resources] : @[]))
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

- (void)loadUserLanguages
{
	_userLanguages.reset();
	_userLanguageFiles = [NSMutableDictionary dictionary];
	auto root = _userLanguages.append_child("NotepadPlus");
	NSMutableArray<NSURL *> *files = [NSMutableArray array];
	if (_profile)
		[files addObject:[_profile URLByAppendingPathComponent:@"userDefineLang.xml"]];
	NSDictionary *catalog = [self catalog:@"userDefineLangs"];
	NSArray *filenames = [catalog.allKeys sortedArrayUsingSelector:@selector(compare:)];
	for (NSString *file in filenames)
		if ([catalog[file] isKindOfClass:NSURL.class] && [self isProfileLanguageFile:catalog[file]])
			[files addObject:catalog[file]];
	for (NSString *file in filenames)
		if (![self isProfileLanguageFile:catalog[file]])
			[files addObject:catalog[file]];
	NSArray *hidden = [self setting:@"hiddenUserLanguages" fallback:@[]];
	for (NSURL *url in files)
	{
		pugi::xml_document definitions;
		if (!LoadXML(definitions, url))
			continue;
		for (auto entry : definitions.child("NotepadPlus").children("UserLang"))
		{
			auto name = entry.attribute("name");
			std::string_view version = entry.attribute("udlVersion").value();
			if (name && *name.value() && (version == "2.1" || version == "2.0") && ![hidden containsObject:String(name.value())] &&
				!root.find_child_by_attribute("UserLang", "name", name.value()))
			{
				root.append_copy(entry);
				_userLanguageFiles[String(name.value())] = url;
			}
		}
	}
}

- (BOOL)isProfileLanguageFile:(NSURL *)url
{
	if (!_profile || !url.isFileURL)
		return NO;
	NSString *profile = _profile.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
	NSString *file = url.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
	return [file hasPrefix:[profile stringByAppendingString:@"/"]];
}

- (NSString *)userLanguageXML:(NSString *)name
{
	if (!name.length)
		return nil;
	auto language = _userLanguages.child("NotepadPlus").find_child_by_attribute("UserLang", "name", name.UTF8String);
	if (!language)
		return nil;
	pugi::xml_document copy;
	copy.append_child("NotepadPlus").append_copy(language);
	std::ostringstream stream;
	copy.save(stream);
	return String(stream.str().c_str());
}

- (BOOL)saveUserLanguageXML:(NSString *)xml replacing:(NSString *)previousName error:(NSError **)error
{
	pugi::xml_document source;
	NSData *bytes = [xml dataUsingEncoding:NSUTF8StringEncoding];
	auto parsed = bytes.length && source.load_buffer(bytes.bytes, bytes.length);
	auto definition = source.child("NotepadPlus").child("UserLang");
	NSString *name = String(definition.attribute("name").value());
	std::string_view version = definition.attribute("udlVersion").value();
	if (!parsed || !name.length || (version != "2.0" && version != "2.1") || definition.next_sibling("UserLang") ||
		(![name isEqualToString:previousName] && _userLanguageFiles[name]))
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError
				userInfo:@{NSLocalizedDescriptionKey: EditorUIString(@"Enter one valid UDL 2.0 or 2.1 XML definition with a unique language name.")}];
		return NO;
	}
	NSURL *destination = previousName ? _userLanguageFiles[previousName] : nil;
	const BOOL overridesBundled = destination && ![self isProfileLanguageFile:destination];
	if (overridesBundled)
		destination = nil;
	pugi::xml_document output;
	if (destination)
	{
		if (!LoadXML(output, destination))
		{
			if (error)
				*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{NSURLErrorKey: destination}];
			return NO;
		}
		auto root = output.child("NotepadPlus");
		auto entry = root.find_child_by_attribute("UserLang", "name", previousName.UTF8String);
		if (!entry)
			return NO;
		root.insert_copy_before(definition, entry);
		root.remove_child(entry);
	}
	else
	{
		NSURL *folder = [_profile URLByAppendingPathComponent:@"userDefineLangs" isDirectory:YES];
		if (![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:error])
			return NO;
		destination = [folder URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"xml"]];
		output.append_child("NotepadPlus").append_copy(definition);
	}
	std::ostringstream stream;
	output.save(stream);
	const auto result = stream.str();
	if (![[NSData dataWithBytes:result.data() length:result.size()] writeToURL:destination options:NSDataWritingAtomic error:error])
		return NO;
	NSMutableArray *hidden = [[self setting:@"hiddenUserLanguages" fallback:@[]] mutableCopy];
	[hidden removeObject:name];
	if (overridesBundled && ![previousName isEqualToString:name])
		[hidden addObject:previousName];
	[self setSetting:hidden forName:@"hiddenUserLanguages"];
	[self loadUserLanguages];
	return YES;
}

- (BOOL)removeUserLanguage:(NSString *)name error:(NSError **)error
{
	NSURL *file = name.length ? _userLanguageFiles[name] : nil;
	if (!file)
		return NO;
	if ([self isProfileLanguageFile:file])
	{
		pugi::xml_document document;
		if (!LoadXML(document, file))
		{
			if (error)
				*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{NSURLErrorKey: file}];
			return NO;
		}
		auto root = document.child("NotepadPlus");
		if (!root.remove_child(root.find_child_by_attribute("UserLang", "name", name.UTF8String)))
			return NO;
		std::ostringstream stream;
		document.save(stream);
		const auto bytes = stream.str();
		if (![[NSData dataWithBytes:bytes.data() length:bytes.size()] writeToURL:file options:NSDataWritingAtomic error:error])
			return NO;
	}
	NSMutableArray *hidden = [[self setting:@"hiddenUserLanguages" fallback:@[]] mutableCopy];
	[hidden addObject:name];
	[self setSetting:hidden forName:@"hiddenUserLanguages"];
	[self loadUserLanguages];
	return YES;
}

- (NSArray<NSString *> *)userLanguages
{
	NSMutableArray<NSString *> *names = [NSMutableArray array];
	for (auto language : _userLanguages.child("NotepadPlus").children("UserLang"))
		[names addObject:String(language.attribute("name").value())];
	return [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (BOOL)importUserLanguages:(NSURL *)url error:(NSError **)error
{
	pugi::xml_document definitions;
	bool supported = false;
	if ([url.pathExtension.lowercaseString isEqualToString:@"xml"] && LoadXML(definitions, url))
		for (auto language : definitions.child("NotepadPlus").children("UserLang"))
		{
			std::string_view version = language.attribute("udlVersion").value();
			supported |= *language.attribute("name").value() && (version == "2.0" || version == "2.1");
		}
	if (!supported)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{
				NSURLErrorKey: url, NSLocalizedDescriptionKey: EditorUIString(@"Choose an XML file with a named UDL 2.0 or 2.1 definition.")}];
		return NO;
	}
	NSURL *directory = [_profile URLByAppendingPathComponent:@"userDefineLangs" isDirectory:YES];
	NSFileManager *fm = NSFileManager.defaultManager;
	if (![fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error])
		return NO;
	NSURL *destination = [directory URLByAppendingPathComponent:url.lastPathComponent];
	if (![url.URLByStandardizingPath isEqual:destination.URLByStandardizingPath] && [fm fileExistsAtPath:destination.path])
		destination = [directory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"xml"]];
	if (![url.URLByStandardizingPath isEqual:destination.URLByStandardizingPath] &&
		![fm copyItemAtURL:url toURL:destination error:error])
		return NO;
	NSMutableArray *hidden = [[self setting:@"hiddenUserLanguages" fallback:@[]] mutableCopy];
	for (auto language : definitions.child("NotepadPlus").children("UserLang"))
		[hidden removeObject:String(language.attribute("name").value())];
	[self setSetting:hidden forName:@"hiddenUserLanguages"];
	[self loadUserLanguages];
	return YES;
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
	if ([identifier hasPrefix:@"udl:"])
	{
		auto definition = _userLanguages.child("NotepadPlus").find_child_by_attribute("UserLang", "name",
			[identifier substringFromIndex:4].UTF8String);
		auto keywords = definition.child("KeywordLists").find_child_by_attribute("Keywords", "name", "Comments");
		NSString *entry = String(keywords.child_value());
		NSMutableArray<NSString *> *symbols = [NSMutableArray arrayWithArray:@[@"", @"", @""]];
		for (NSString *item in [entry componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
		{
			if (item.length <= 2)
				continue;
			NSString *code = [item substringToIndex:2];
			NSInteger index = [code isEqualToString:@"00"] ? 0 : [code isEqualToString:@"03"] ? 1 : [code isEqualToString:@"04"] ? 2 : -1;
			if (index >= 0 && !symbols[index].length)
				symbols[index] = [item substringFromIndex:2];
		}
		return symbols;
	}
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
		LoadXML(_theme, [_bundle URLForResource:@"stylers.model" withExtension:@"xml"]);
	}
	NSURL *bundledThemes = [_bundle.resourceURL URLByAppendingPathComponent:@"themes" isDirectory:YES];
	if (!_selectedTheme || [bundledThemes.URLByStandardizingPath.path
		isEqualToString:_selectedTheme.URLByDeletingLastPathComponent.URLByStandardizingPath.path])
	{
		auto size = _theme.child("NotepadPlus").child("GlobalStyles")
			.find_child_by_attribute("WidgetStyle", "styleID", "32").attribute("fontSize");
		const int points = size.as_int();
		if (points > 0 && points <= 96)
			size.set_value((points * 3 + 1) / 2);
	}
}

- (void)loadTranslation:(NSURL *)url
{
	_selectedTranslation = url;
	pugi::xml_document document;
	NSMutableDictionary *labels = [NSMutableDictionary dictionary];
	NSMutableDictionary *findLabels = [NSMutableDictionary dictionary];
	NSMutableDictionary *translatedText = [NSMutableDictionary dictionary];
	NSURL *existing = [_profile URLByAppendingPathComponent:@"nativeLang.xml"];
	if (LoadXML(document, url ?: existing))
	{
		auto root = TranslationRoot(document);
		CollectSharedStrings(TranslationRoot(_english), root, translatedText);
		NSString *filename = String(root.attribute("filename").value());
		NSString *language = (filename.length ? filename : (url ?: existing).lastPathComponent)
			.lastPathComponent.stringByDeletingPathExtension;
		NSURL *native = language.length ? [NSBundle.mainBundle URLForResource:language withExtension:@"plist" subdirectory:@"native-labels"] : nil;
		NSDictionary *nativeLabels = native ? [NSDictionary dictionaryWithContentsOfURL:native] : nil;
		NSMutableDictionary *overlays = [NSMutableDictionary dictionary];
		if (nativeLabels)
			[overlays addEntriesFromDictionary:nativeLabels];
		// An exported profile can add platform-specific translations without editing the bundle.
		if (language.length && [language isEqualToString:language.lastPathComponent])
		{
			NSURL *folder = [_profile URLByAppendingPathComponent:@"native-labels" isDirectory:YES];
			NSDictionary *overrides = [NSDictionary dictionaryWithContentsOfURL:
				[folder URLByAppendingPathComponent:[language stringByAppendingPathExtension:@"plist"]]];
			for (NSString *key in overrides)
				if ([overrides[key] isKindOfClass:NSString.class])
					overlays[key] = overrides[key];
		}
		for (auto item : root.child("MacpadStrings").children("String"))
		{
			NSString *key = String(item.attribute("key").value());
			NSString *value = String(item.attribute("value").value());
			if (key.length && value.length)
				overlays[key] = value;
		}
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
		for (const char *section : {"StyleConfig", "ShortcutMapper", "ShortcutMapperSubDialg", "Preference", "UserDefine",
			"ColumnEditor", "FindInFinder", "IncrementalFind", "DoSaveAll", "Window"})
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
			if (std::string_view(item.name()).starts_with("finder-") || std::string_view(item.name()).starts_with("statusbar-") ||
				std::string_view(item.name()).starts_with("IncrementalFind-") ||
				std::string_view(item.name()).starts_with("find-status-") || std::string_view(item.name()).starts_with("find-result-"))
				labels[String(item.name())] = String(item.attribute("value").value());
		auto find = root.child("Dialog").child("Find");
		CollectLabels(find, findLabels);
		for (const char *title : {"titleFind", "titleReplace", "titleFindInFiles", "titleFindInProjects", "titleMark"})
			if (auto value = find.attribute(title); value && *value.value())
				findLabels[String(title)] = String(value.value());
		NSDictionary *preferences = @{
			@"pref-saveAllConfirm": @"6361", @"pref-fillFindSelection": @"6908",
			@"pref-fillFindWord": @"6909", @"pref-findFilesOnDisk": @"6917",
			@"pref-inSelectionAutocheckThreshold": @"6910", @"pref-fillFindWhatThreshold": @"6916",
			@"pref-tabCloseButtons": @"6112", @"pref-doubleClickClosesTab": @"6113", @"pref-lockTabs": @"6108",
			@"pref-currentLineMode": @"6651", @"pref-currentLineMode-0": @"6652", @"pref-currentLineMode-1": @"6653",
			@"pref-currentLineMode-2": @"6654", @"pref-wrapIndent-0": @"6228", @"pref-wrapIndent-1": @"6229",
			@"pref-wrapIndent-2": @"6230", @"pref-scrollBeyondLastLine": @"6236", @"pref-virtualSpace": @"6245",
			@"pref-selectedTextForeground": @"6225", @"pref-bookmarkMargin": @"6207",
			@"pref-rememberSession": @"6309", @"pref-checkpointDrafts": @"6818",
			@"pref-backupMode-0": @"6315", @"pref-backupMode-1": @"6316", @"pref-backupMode-2": @"6317",
			@"pref-limitLargeFiles": @"7143", @"pref-largeFileCompletion": @"7148",
			@"pref-largeFileBraceMatch": @"7147", @"pref-largeFileDisableWrap": @"7150",
			@"pref-printLineNumbers": @"6601", @"pref-printColorMode-1": @"6604",
			@"pref-printColorMode-2": @"6605", @"pref-printColorMode-3": @"6606", @"pref-printFormFeedBreak": @"6616",
			@"pref-toolbarStyle-0": @"6103", @"pref-toolbarStyle-1": @"6104", @"pref-toolbarStyle-2": @"6129",
			@"pref-toolbarStyle-3": @"6130", @"pref-toolbarStyle-4": @"6105",
		};
		for (NSString *key in preferences)
			if (NSString *translation = labels[[@"Preference:" stringByAppendingString:preferences[key]]])
				labels[key] = [translation stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" :"]];
		const char *sections[][2] = {
			{"pref-search", "Searching"}, {"pref-backup", "Backup"}, {"pref-print", "Print"},
			{"pref-tabs", "Tabbar"}, {"pref-largeFiles", "Performance"},
		};
		for (const auto &section : sections)
			if (auto title = root.child("Dialog").child("Preference").child(section[1]).attribute("title"); *title.value())
				labels[String(section[0])] = MenuLabel(String(title.value()));
		for (unsigned i = 0; i < std::size(GlobalOverrideSettings); ++i)
			if (NSString *translation = labels[[NSString stringWithFormat:@"StyleConfig:%u", 2226 + i]])
				labels[[@"pref-" stringByAppendingString:GlobalOverrideSettings[i]]] = translation;
		NSDictionary *windows = @{@"native-openTabs-save": @"Window:7002", @"native-openTabs-close": @"Window:7003",
			@"native-openTabs-sort": @"Window:7004"};
		for (NSString *key in windows)
			if (NSString *translation = labels[windows[key]])
				labels[key] = translation;
		[labels addEntriesFromDictionary:overlays];
	}
	_findLabels = [findLabels copy];
	_labels = [labels copy];
	_translatedText = [translatedText copy];
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
		{"ScintillaPrimaryView", "selectedTextForegroundSingleColor", @"selectedTextForeground"},
		{"TabSetting", "replaceBySpace", @"insertSpaces"}, {"TabSetting", "backspaceUnindent", @"backspaceUnindent"},
		{"TabBar", "hide", @"hideTabBar"}, {"TabBar", "closeButton", @"tabCloseButtons"},
		{"TabBar", "doubleClick2Close", @"doubleClickClosesTab"},
		{"TabBar", "dragAndDrop", @"dragTabs"},
		{"Print", "lineNumber", @"printLineNumbers"},
		{"Print", "formFeedPageBreak", @"printFormFeedBreak"},
		{"TabBar", "vertical", @"verticalTabs"}, {"TabBar", "multiLine", @"multilineTabs"},
		{"MISC", "docPeekOnTab", @"tabPreview"},
		{"largeFileRestriction", "isEnabled", @"limitLargeFiles"},
		{"largeFileRestriction", "allowAutoCompletion", @"largeFileCompletion"},
		{"largeFileRestriction", "allowBraceMatch", @"largeFileBraceMatch"},
		{"largeFileRestriction", "deactivateWordWrap", @"largeFileDisableWrap"},
		{"Searching", "fillFindFieldWithSelected", @"fillFindSelection"},
		{"Searching", "fillFindFieldSelectCaret", @"fillFindWord"},
		{"Searching", "FiF_ignoreunsavedChangesInOpenedFiles", @"findFilesOnDisk"},
		{"Searching", "monospacedFontFindDlg", @"monospacedFontFindDlg"},
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
		{"Searching", "inSelectionAutocheckThreshold", @"inSelectionAutocheckThreshold", 0, 1024},
		{"Searching", "fillFindWhatThreshold", @"fillFindWhatThreshold", 1, 16383},
		{"multiInst", "setting", @"instanceMode", 0, 2}
	};
	for (const auto &entry : integers)
		if (auto attribute = config(entry.section).attribute(entry.attribute))
			settings[entry.setting] = @(std::clamp(attribute.as_int(entry.minimum), entry.minimum, entry.maximum));
	if (auto value = std::string_view(config("SaveAllConfirm").child_value()); value == "yes" || value == "no")
		settings[@"saveAllConfirm"] = @(value == "yes");
	if (auto overrideStyle = config("globalOverride"))
	{
		const char *attributes[] = {"fg", "bg", "font", "fontSize", "bold", "italic", "underline"};
		for (unsigned i = 0; i < std::size(attributes); ++i)
			if (auto value = overrideStyle.attribute(attributes[i]))
				settings[GlobalOverrideSettings[i]] = @(std::string_view(value.value()) == "yes");
	}
	if (settings[@"dragTabs"])
	{
		settings[@"lockTabs"] = @(![settings[@"dragTabs"] boolValue]);
		[settings removeObjectForKey:@"dragTabs"];
	}
	if (auto caret = config("Caret"))
	{
		if (auto width = caret.attribute("width"))
			settings[@"caretWidth"] = @(std::clamp(width.as_int(1), 0, 20));
		if (auto rate = caret.attribute("blinkRate"))
			settings[@"caretBlink"] = @(std::clamp(rate.as_int(500), 0, 5000));
	}
	if (auto view = config("ScintillaPrimaryView"))
	{
		if (auto value = view.attribute("currentLineIndicator"))
			settings[@"currentLineMode"] = @(std::clamp(value.as_int(), 0, 2));
		else if (auto value = view.attribute("currentLineHilitingShow"))
			settings[@"currentLineMode"] = @(std::string_view(value.value()) == "show" ? 1 : 0);
		if (auto value = view.attribute("currentLineFrameWidth"))
			settings[@"currentLineFrameWidth"] = @(std::clamp(value.as_int(1), 1, 6));
		if (auto value = view.attribute("eolMode"))
			settings[@"eolRepresentation"] = @(std::clamp(value.as_int(1), 0, 3));
		if (auto value = view.attribute("edgeMultiColumnPos"))
			settings[@"edgeColumns"] = String(value.value());
		if (auto value = view.attribute("isEdgeBgMode"))
			settings[@"edgeBackground"] = @(std::string_view(value.value()) == "yes");
		if (auto value = view.attribute("lineWrapMethod"))
		{
			const std::string_view method = value.value();
			settings[@"wrapIndent"] = @(method == "aligned" ? 1 : method == "indent" ? 2 : 0);
		}
	}
	if (auto printing = config("Print"))
	{
		if (auto mode = printing.attribute("printOption"))
			settings[@"printColorMode"] = @(std::clamp(mode.as_int(2), 0, 3));
		const struct { const char *attribute; NSString *setting; } strings[] = {
			{"headerLeft", @"printHeaderLeft"}, {"headerMiddle", @"printHeaderMiddle"}, {"headerRight", @"printHeaderRight"},
			{"footerLeft", @"printFooterLeft"}, {"footerMiddle", @"printFooterMiddle"}, {"footerRight", @"printFooterRight"},
			{"headerFontName", @"printHeaderFontName"}, {"footerFontName", @"printFooterFontName"},
		};
		for (const auto &entry : strings)
			if (auto field = printing.attribute(entry.attribute))
				settings[entry.setting] = String(field.value());
		const struct { const char *attribute; NSString *setting; } margins[] = {
			{"margeLeft", @"printMarginLeft"}, {"margeTop", @"printMarginTop"},
			{"margeRight", @"printMarginRight"}, {"margeBottom", @"printMarginBottom"},
		};
		for (const auto &entry : margins)
			if (auto field = printing.attribute(entry.attribute))
				settings[entry.setting] = @(std::clamp(field.as_int(), 0, 100));
		const struct { const char *attribute; NSString *setting; int limit; } fonts[] = {
			{"headerFontSize", @"printHeaderFontSize", 72}, {"footerFontSize", @"printFooterFontSize", 72},
			{"headerFontStyle", @"printHeaderFontStyle", 3}, {"footerFontStyle", @"printFooterFontStyle", 3},
		};
		for (const auto &entry : fonts)
			if (auto field = printing.attribute(entry.attribute); field && (entry.limit == 3 || field.as_int() > 0))
				settings[entry.setting] = @(std::clamp(field.as_int(), 0, entry.limit));
	}
	if (auto action = config("auto-completion").attribute("autoCAction"))
		settings[@"autocomplete"] = @(action.as_int() != 0);
	if (auto detector = config("DetectEncoding"))
	{
		const std::string_view value = detector.child_value();
		if (value == "yes" || value == "no")
			settings[@"detectEncoding"] = @(value == "yes");
	}
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

- (NSDictionary<NSString *, NSArray<NSDictionary *> *> *)styleDefinitions
{
	NSMutableDictionary *definitions = [NSMutableDictionary dictionary];
	auto collect = [](pugi::xml_node node, const char *type) {
		NSMutableArray *styles = [NSMutableArray array];
		for (auto style : node.children(type))
		{
			NSMutableDictionary *descriptor = [NSMutableDictionary dictionary];
			for (auto attribute : style.attributes())
				descriptor[String(attribute.name())] = String(attribute.value());
			[styles addObject:descriptor];
		}
		return styles;
	};
	auto root = _theme.child("NotepadPlus");
	definitions[@""] = collect(root.child("GlobalStyles"), "WidgetStyle");
	for (auto lexer : root.child("LexerStyles").children("LexerType"))
	{
		NSString *name = String(lexer.attribute("name").value());
		if (name.length)
			definitions[name] = collect(lexer, "WordsStyle");
	}
	return definitions;
}

- (BOOL)saveStyles:(NSDictionary<NSString *, NSArray<NSDictionary *> *> *)styles error:(NSError **)error
{
	pugi::xml_document copy;
	copy.reset(_theme);
	auto root = copy.child("NotepadPlus");
	for (NSString *language in styles)
	{
		auto group = language.length ? root.child("LexerStyles").find_child_by_attribute("LexerType", "name", language.UTF8String) :
			root.child("GlobalStyles");
		const char *type = language.length ? "WordsStyle" : "WidgetStyle";
		for (NSDictionary *values in styles[language])
		{
			NSString *name = values[@"name"];
			auto style = group.find_child_by_attribute(type, "name", name.UTF8String);
			if (!style)
				continue;
			for (NSString *key in @[@"fgColor", @"bgColor", @"fontName", @"fontSize", @"fontStyle", @"colorStyle"])
			{
				NSString *value = values[key];
				if (!value)
					continue;
				auto attribute = style.attribute(key.UTF8String);
				if (!attribute)
					attribute = style.append_attribute(key.UTF8String);
				attribute = value.UTF8String;
			}
		}
	}
	NSURL *folder = [_profile URLByAppendingPathComponent:@"themes" isDirectory:YES];
	if (![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:error])
		return NO;
	NSString *name = _selectedTheme.lastPathComponent ?: @"Custom.xml";
	NSURL *url = [folder URLByAppendingPathComponent:name];
	if (!_selectedTheme)
		for (NSUInteger number = 2; [NSFileManager.defaultManager fileExistsAtPath:url.path]; ++number)
			url = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"Custom %lu.xml", number]];
	std::ostringstream stream;
	copy.save(stream);
	const std::string xml = stream.str();
	if (![[NSData dataWithBytes:xml.data() length:xml.size()] writeToURL:url options:NSDataWritingAtomic error:error])
		return NO;
	[self chooseTheme:url];
	return YES;
}
- (NSString *)label:(NSString *)identifier fallback:(NSString *)fallback
{
	NSString *label = _labels[identifier];
	return label.length ? label : [self text:fallback];
}

- (NSString *)text:(NSString *)english
{
	if (!english.length)
		return english;
	NSString *key = [@"native-text:" stringByAppendingString:english];
	return _labels[key] ?: _translatedText[NormalizedUIString(english)] ?: english;
}

- (NSString *)englishMenuLabel:(NSString *)identifier { return _englishLabels[identifier]; }

- (BOOL)toolbarHidesCommand:(NSString *)identifier atIndex:(NSUInteger)index
{
	auto section = _toolbar.child("NotepadPlus").child("ToolbarButtons").child("Standard");
	if (std::string_view(section.attribute("hideAll").value()) == "yes")
		return YES;
	for (auto button : section.children("Button"))
		if (button.attribute("index").as_ullong(ULLONG_MAX) == index &&
			std::string_view(button.attribute("id").value()) == identifier.UTF8String)
			return std::string_view(button.attribute("hide").value()) == "yes";
	return NO;
}

- (BOOL)toolbarHidesPluginAtIndex:(NSUInteger)index
{
	auto section = _toolbar.child("NotepadPlus").child("ToolbarButtons").child("Plugin");
	if (std::string_view(section.attribute("hideAll").value()) == "yes")
		return YES;
	for (auto button : section.children("Button"))
		if (!index--)
			return std::string_view(button.attribute("hide").value()) == "yes";
	return NO;
}

- (NSURL *)toolbarIconNamed:(NSString *)name disabled:(BOOL)disabled
{
	auto icons = _toolbar.child("NotepadPlus").child("ToolBarIcons");
	if (!icons || !name.length)
		return nil;
	NSString *folder = String(icons.attribute("icoFolderName").value());
	if (!folder.length)
		folder = @"default";
	if (![folder isEqualToString:folder.lastPathComponent] || [folder isEqualToString:@"."] || [folder isEqualToString:@".."] ||
		[folder containsString:@"\\"])
		return nil;
	NSURL *directory = [[_profile URLByAppendingPathComponent:@"toolbarIcons" isDirectory:YES]
		URLByAppendingPathComponent:folder isDirectory:YES];
	if (disabled)
	{
		NSURL *icon = [directory URLByAppendingPathComponent:[name stringByAppendingString:@"_disabled.ico"]];
		if ([icon checkResourceIsReachableAndReturnError:nullptr])
			return icon;
	}
	NSURL *icon = [directory URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"ico"]];
	return [icon checkResourceIsReachableAndReturnError:nullptr] ? icon : nil;
}

- (NSURL *)localURLForWindowsPath:(NSString *)path
{
	NSString *normalized = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
	if (![normalized hasPrefix:@"//"] && !(normalized.length > 2 && [normalized characterAtIndex:1] == ':' &&
		[normalized characterAtIndex:2] == '/'))
		return nil;
	NSURL *file = [_profile URLByAppendingPathComponent:@"windowsPathMappings.plist"];
	NSDictionary *mapping = [NSDictionary dictionaryWithContentsOfURL:file];
	NSString *longest = nil;
	NSString *destination = nil;
	for (NSString *key in mapping)
	{
		NSString *root = mapping[key];
		if (![key isKindOfClass:NSString.class] || ![root isKindOfClass:NSString.class])
			continue;
		NSString *prefix = [key stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
		while (prefix.length && [prefix hasSuffix:@"/"])
			prefix = [prefix substringToIndex:prefix.length - 1];
		if (prefix.length <= longest.length || !root.stringByExpandingTildeInPath.isAbsolutePath)
			continue;
		NSString *lowercase = normalized.lowercaseString;
		if ([lowercase isEqualToString:prefix.lowercaseString] ||
			[lowercase hasPrefix:[prefix.lowercaseString stringByAppendingString:@"/"]])
		{
			longest = prefix;
			destination = root.stringByExpandingTildeInPath;
		}
	}
	if (!destination)
		return nil;
	NSURL *root = [NSURL fileURLWithPath:destination isDirectory:YES].URLByStandardizingPath;
	NSString *suffix = [normalized substringFromIndex:longest.length];
	if ([suffix hasPrefix:@"/"])
		suffix = [suffix substringFromIndex:1];
	if ([[suffix componentsSeparatedByString:@"/"] containsObject:@".."])
		return nil;
	return suffix.length ? [root URLByAppendingPathComponent:suffix].URLByStandardizingPath : root;
}

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
	NSString *label = _labels[[@"Find:" stringByAppendingString:identifier]] ?: _findLabels[identifier];
	return label.length ? label : [self text:fallback];
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
					EditorUIString(@"This file does not contain a macpadqq theme.") : EditorUIString(@"This file does not contain a macpadqq translation.")}];
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
	auto color = WidgetThemeColor(widgets, name.UTF8String, background);
	if (!color)
		return nil;
	return [NSColor colorWithSRGBRed:(*color & 255) / 255.0
		green:((*color >> 8) & 255) / 255.0 blue:((*color >> 16) & 255) / 255.0 alpha:1];
}

- (BOOL)usesDarkColors
{
	NSColor *color = [[self setting:@"styleOverrideBackground" fallback:@NO] boolValue] ?
		[self widgetColor:@"Global override" background:YES] : nil;
	color = [(color ?: [self widgetColor:@"Default Style" background:YES]) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
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
	ApplyFoldTheme(view, widgets, self.usesDarkColors);
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
	auto overrideStyle = widgets.find_child_by_attribute("WidgetStyle", "name", "Global override");
	unsigned overrides = 0;
	if (overrideStyle)
		for (unsigned i = 0; i < std::size(GlobalOverrideSettings); ++i)
			if ([[self setting:GlobalOverrideSettings[i] fallback:@NO] boolValue])
				overrides |= 1U << i;
	[view message:SCI_STYLERESETDEFAULT];
	[view setStringProperty:SCI_STYLESETFONT parameter:STYLE_DEFAULT value:@"Menlo"];
	[view message:SCI_STYLESETSIZE wParam:STYLE_DEFAULT lParam:18];
	ApplyStyle(view, STYLE_DEFAULT, widgets.find_child_by_attribute("WidgetStyle", "styleID", "32"), overrideStyle, overrides);
	[view message:SCI_STYLECLEARALL];
	for (auto style : widgets.children("WidgetStyle"))
	{
		const int index = style.attribute("styleID").as_int(-1);
		if (index > STYLE_DEFAULT && index <= STYLE_LASTPREDEFINED)
			ApplyStyle(view, index, style);
	}
	auto widgetColor = [&](const char *name, bool background) -> std::optional<int> {
		return WidgetThemeColor(widgets, name, background);
	};
	auto element = [&](int id, std::optional<int> color) {
		if (color)
			[view message:SCI_SETELEMENTCOLOUR wParam:id lParam:0xff000000U | *color];
		else
			[view message:SCI_RESETELEMENTCOLOUR wParam:id];
	};
	const auto selection = widgetColor("Selected text colour", true);
	element(SC_ELEMENT_SELECTION_BACK, selection);
	element(SC_ELEMENT_SELECTION_INACTIVE_BACK, selection);
	const auto multiSelection = widgetColor("Multi-selected text color", true);
	element(SC_ELEMENT_SELECTION_ADDITIONAL_BACK, multiSelection ? multiSelection : selection);
	element(SC_ELEMENT_SELECTION_INACTIVE_ADDITIONAL_BACK, multiSelection ? multiSelection : selection);
	const auto selectionText = [[self setting:@"selectedTextForeground" fallback:@NO] boolValue] ?
		widgetColor("Selected text colour", false) : std::nullopt;
	for (int id : {SC_ELEMENT_SELECTION_TEXT, SC_ELEMENT_SELECTION_INACTIVE_TEXT,
		SC_ELEMENT_SELECTION_ADDITIONAL_TEXT, SC_ELEMENT_SELECTION_INACTIVE_ADDITIONAL_TEXT})
		element(id, selectionText);
	auto currentLine = widgets.find_child_by_attribute("WidgetStyle", "name", "Current line background colour");
	if (auto color = Color(currentLine.attribute("bgColor")))
	{
		[view message:SCI_SETCARETLINEBACK wParam:*color];
		[view message:SCI_SETCARETLINEVISIBLE wParam:1];
	}
	else
		[view message:SCI_SETCARETLINEVISIBLE wParam:0];
	const auto defaultCaret = static_cast<int>([view message:SCI_STYLEGETFORE wParam:STYLE_DEFAULT]);
	element(SC_ELEMENT_CARET, widgetColor("Caret colour", false).value_or(defaultCaret));
	element(SC_ELEMENT_CARET_ADDITIONAL, widgetColor("Multi-edit carets color", false).value_or(defaultCaret));
	const auto margin = widgetColor("Line number margin", true).value_or(
		static_cast<int>([view message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT]));
	[view message:SCI_SETMARGINTYPEN wParam:1 lParam:SC_MARGIN_COLOUR];
	[view message:SCI_SETMARGINBACKN wParam:1 lParam:widgetColor("Bookmark margin", true).value_or(margin)];
	[view message:SCI_SETMARGINTYPEN wParam:3 lParam:SC_MARGIN_COLOUR];
	[view message:SCI_SETMARGINBACKN wParam:3 lParam:widgetColor("Change History margin", true).value_or(margin)];
	ApplyFoldTheme(view, widgets, self.usesDarkColors);
	const auto whitespace = widgetColor("White space symbol", false);
	[view message:SCI_SETWHITESPACEFORE wParam:whitespace.has_value() lParam:whitespace.value_or(0)];
	const auto eolColor = widgetColor("EOL custom color", false);
	const auto eolMode = [[self setting:@"eolRepresentation" fallback:@1] integerValue];
	const auto appearance = (eolMode & 1 ? SC_REPRESENTATION_BLOB : SC_REPRESENTATION_PLAIN) |
		((eolMode & 2) && eolColor ? SC_REPRESENTATION_COLOUR : 0);
	for (const char *sequence : {"\r", "\n"})
	{
		const auto key = reinterpret_cast<uptr_t>(sequence);
		if (eolColor)
			[view message:SCI_SETREPRESENTATIONCOLOUR wParam:key lParam:0xff000000U | *eolColor];
		[view message:SCI_SETREPRESENTATIONAPPEARANCE wParam:key lParam:appearance];
	}
	const char *changes[] = {"Change History revert origin", "Change History saved", "Change History modified",
		"Change History revert modified"};
	const int changeColors[] = {0x70afaf, 0x44aa44, 0x22aaff, 0x70aadd};
	for (int i = 0; i < std::size(changes); ++i)
		[view message:SCI_MARKERSETBACK wParam:SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN + i
			lParam:widgetColor(changes[i], true).value_or(changeColors[i])];

	auto definitions = _userLanguages.child("NotepadPlus");
	pugi::xml_node userLanguage;
	if ([mode hasPrefix:@"udl:"])
		userLanguage = definitions.find_child_by_attribute("UserLang", "name", [mode substringFromIndex:4].UTF8String);
	else if (!mode && extension.length)
	{
		const BOOL dark = self.usesDarkColors;
		for (auto entry : definitions.children("UserLang"))
		{
			auto extensions = [String(entry.attribute("ext").value()) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
			if (![extensions containsObject:extension])
				continue;
			const bool darkDefinition = std::string_view(entry.attribute("darkModeTheme").value()) == "yes";
			if (!userLanguage || darkDefinition == dark)
				userLanguage = entry;
			if (darkDefinition == dark)
				break;
		}
	}
	if (userLanguage)
	{
		if (highlight)
		{
			ConfigureUDL(view, userLanguage, overrideStyle, overrides);
			[view message:SCI_COLOURISE wParam:0 lParam:-1];
		}
		else
		{
			[view message:SCI_SETILEXER wParam:0 lParam:0];
			[view message:SCI_CLEARDOCUMENTSTYLE];
		}
		NSString *name = String(userLanguage.attribute("name").value());
		if (identifier)
			*identifier = [@"udl:" stringByAppendingString:name];
		return name;
	}

	auto language = mode ? _languages.child("NotepadPlus").child("Languages").find_child_by_attribute("Language", "name", mode.UTF8String) :
		[self languageForExtension:extension];
	auto lexerStyles = mode ? root.child("LexerStyles").find_child_by_attribute("LexerType", "name", mode.UTF8String) :
		[self lexerStylesForExtension:extension];
	NSString *name = String(language ? language.attribute("name").value() : lexerStyles.attribute("name").value());
	if (identifier)
		*identifier = name.length ? name : @"normal";
	if (!lexerStyles && name.length)
	{
		NSString *styleName = [name isEqualToString:@"json5"] ? @"json" : ([name isEqualToString:@"jsp"] ? @"html" : name);
		lexerStyles = root.child("LexerStyles").find_child_by_attribute("LexerType", "name", styleName.UTF8String);
	}
	NSDictionary *aliases = @{@"c": @"cpp", @"cs": @"cpp", @"java": @"cpp", @"javascript": @"cpp", @"javascript.js": @"cpp",
		@"rc": @"cpp", @"objc": @"cpp", @"go": @"cpp", @"php": @"hypertext", @"html": @"hypertext", @"sh": @"bash",
		@"tex": @"latex", @"js": @"cpp", @"typescript": @"cpp", @"shell": @"bash",
		@"actionscript": @"cpp", @"asp": @"hypertext", @"autoit": @"au3", @"baanc": @"baan", @"cobol": @"COBOL",
		@"fortran77": @"f77", @"ini": @"props", @"json5": @"json", @"jsp": @"hypertext", @"postscript": @"ps",
		@"scheme": @"lisp", @"swift": @"cpp"};
	NSString *lexerName = aliases[name] ?: name;
	Scintilla::ILexer5 *lexer = highlight && lexerName.length ? CreateLexer(lexerName.UTF8String) : nullptr;
	[view message:SCI_SETILEXER wParam:0 lParam:reinterpret_cast<sptr_t>(lexer)];
	SetProperty(view, "fold", @"1");
	if ([lexerName isEqualToString:@"json"])
	{
		SetProperty(view, "lexer.json.escape.sequence", @"1");
		SetProperty(view, "lexer.json.allow.comments", [name isEqualToString:@"json5"] ? @"1" : @"0");
		if ([name isEqualToString:@"json5"])
			language = _languages.child("NotepadPlus").child("Languages").find_child_by_attribute("Language", "name", "json");
	}
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
			ApplyStyle(view, index, style, overrideStyle, overrides);
	}
	if (highlight)
		[view message:SCI_COLOURISE wParam:0 lParam:-1];
	else
		[view message:SCI_CLEARDOCUMENTSTYLE];
	NSString *description = String(lexerStyles.attribute("desc").value());
	return description.length ? description : @"Normal text file";
}
@end

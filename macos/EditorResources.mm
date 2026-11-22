// SPDX-License-Identifier: GPL-3.0-only
#import "EditorResources.h"
#import "ScintillaView.h"

#include <charconv>
#include <optional>
#include <string_view>

#include "ILexer.h"
#include "Lexilla.h"
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

@implementation EditorResources
{
	NSDictionary<NSString *, NSString *> *_labels;
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
		NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfURL:[_profile URLByAppendingPathComponent:@"native-settings.plist"]];
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
	NSURL *existing = [_profile URLByAppendingPathComponent:@"nativeLang.xml"];
	if (LoadXML(document, url ?: existing))
		CollectLabels(TranslationRoot(document).child("Menu").child("Main"), labels);
	_labels = [labels copy];
}

- (void)savePreferences
{
	[NSFileManager.defaultManager createDirectoryAtURL:_profile withIntermediateDirectories:YES attributes:nil error:nullptr];
	NSDictionary *preferences = @{@"theme": _selectedTheme.lastPathComponent ?: @"",
		@"translation": _selectedTranslation.lastPathComponent ?: @""};
	[preferences writeToURL:[_profile URLByAppendingPathComponent:@"native-settings.plist"] error:nullptr];
}

- (NSString *)label:(NSString *)identifier fallback:(NSString *)fallback
{
	NSString *label = _labels[identifier];
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

- (void)configure:(ScintillaView *)view extension:(NSString *)extension
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

	pugi::xml_node language;
	pugi::xml_node lexerStyles;
	if (extension.length)
	{
		for (auto entry : root.child("LexerStyles").children("LexerType"))
		{
			auto extensions = [String(entry.attribute("ext").value()) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
			if ([extensions containsObject:extension])
			{
				lexerStyles = entry;
				language = _languages.child("NotepadPlus").child("Languages").find_child_by_attribute("Language", "name", entry.attribute("name").value());
				break;
			}
		}
		for (auto entry : _languages.child("NotepadPlus").child("Languages").children("Language"))
		{
			if (language || lexerStyles)
				break;
			auto extensions = [String(entry.attribute("ext").value()) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
			if ([extensions containsObject:extension])
				language = entry;
		}
	}
	NSString *name = String(language ? language.attribute("name").value() : lexerStyles.attribute("name").value());
	if (!lexerStyles && name.length)
		lexerStyles = root.child("LexerStyles").find_child_by_attribute("LexerType", "name", name.UTF8String);
	NSDictionary *aliases = @{@"c": @"cpp", @"cs": @"cpp", @"java": @"cpp", @"javascript": @"cpp", @"javascript.js": @"cpp",
		@"rc": @"cpp", @"objc": @"cpp", @"go": @"cpp", @"php": @"hypertext", @"html": @"hypertext", @"sh": @"bash",
		@"batch": @"batch", @"tex": @"latex", @"js": @"cpp", @"typescript": @"cpp", @"shell": @"bash"};
	NSString *lexerName = aliases[name] ?: name;
	Scintilla::ILexer5 *lexer = lexerName.length ? CreateLexer(lexerName.UTF8String) : nullptr;
	[view message:SCI_SETILEXER wParam:0 lParam:reinterpret_cast<sptr_t>(lexer)];
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
	auto selected = widgets.find_child_by_attribute("WidgetStyle", "name", "Selected text colour");
	if (auto color = Color(selected.attribute("bgColor")))
		[view message:SCI_SETSELBACK wParam:1 lParam:*color];
	else
		[view message:SCI_SETSELBACK wParam:0 lParam:0];
	[view message:SCI_SETCARETFORE wParam:[view message:SCI_STYLEGETFORE wParam:STYLE_DEFAULT]];
	[view message:SCI_COLOURISE wParam:0 lParam:-1];
}
@end

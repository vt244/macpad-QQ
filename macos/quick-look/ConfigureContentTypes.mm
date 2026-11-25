// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

static NSArray<NSString *> *Strings(id value)
{
	if ([value isKindOfClass:NSString.class])
		return @[value];
	return [value isKindOfClass:NSArray.class] ? value : @[];
}

static BOOL IsTextType(NSString *identifier, NSDictionary *declarations)
{
	if ([identifier isEqualToString:@"public.text"])
		return YES;
	for (NSString *parent in Strings(declarations[identifier][@"UTTypeConformsTo"]))
		if (IsTextType(parent, declarations))
			return YES;
	return NO;
}

int main(int argc, const char *argv[])
{
	@autoreleasepool
	{
		if (argc < 5)
			return 1;
		NSString *appPath = @(argv[1]);
		NSString *extensionPath = @(argv[2]);
		NSMutableDictionary *app = [NSMutableDictionary dictionaryWithContentsOfFile:appPath];
		NSMutableDictionary *extension = [NSMutableDictionary dictionaryWithContentsOfFile:extensionPath];
		if (!app || !extension)
			return 1;

		NSDictionary *coreTypes = [NSDictionary dictionaryWithContentsOfFile:
			@"/System/Library/CoreServices/CoreTypes.bundle/Contents/Info.plist"];
		NSArray<NSDictionary *> *exported = coreTypes[@"UTExportedTypeDeclarations"];
		if (!exported.count)
		{
			NSLog(@"Could not read macOS file type declarations.");
			return 1;
		}
		NSMutableDictionary *declarations = [NSMutableDictionary dictionary];
		for (NSDictionary *type in coreTypes[@"UTImportedTypeDeclarations"])
			declarations[type[@"UTTypeIdentifier"]] = type;
		for (NSDictionary *type in exported)
			declarations[type[@"UTTypeIdentifier"]] = type;

		// CSV opens as plain text in the editor and has no lexer of its own.
		NSMutableSet<NSString *> *suffixes = [NSMutableSet setWithObject:@"csv"];
		for (int index = 3; index < argc; ++index)
		{
			NSError *error = nil;
			NSURL *path = [NSURL fileURLWithPath:@(argv[index])];
			NSXMLDocument *xml = [[NSXMLDocument alloc] initWithContentsOfURL:path options:NSXMLNodeLoadExternalEntitiesNever error:&error];
			NSArray<NSXMLNode *> *attributes = [xml nodesForXPath:@"//Language/@ext | //LexerType/@ext | //UserLang/@ext" error:&error];
			if (!attributes)
			{
				NSLog(@"%@.", error);
				return 1;
			}
			for (NSXMLNode *attribute in attributes)
				for (NSString *suffix in [attribute.stringValue.lowercaseString componentsSeparatedByCharactersInSet:
					NSCharacterSet.whitespaceAndNewlineCharacterSet])
					if (suffix.length)
						[suffixes addObject:suffix];
		}

		NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *systemTypes = [NSMutableDictionary dictionary];
		for (NSDictionary *type in declarations.allValues)
		{
			NSString *identifier = type[@"UTTypeIdentifier"];
			for (NSString *suffix in Strings(type[@"UTTypeTagSpecification"][@"public.filename-extension"]))
			{
				NSString *normalized = suffix.lowercaseString;
				if (![suffixes containsObject:normalized] || !IsTextType(identifier, declarations))
					continue;
				if (!systemTypes[normalized])
					systemTypes[normalized] = [NSMutableSet set];
				[systemTypes[normalized] addObject:identifier];
			}
		}

		NSMutableSet<NSString *> *types = [NSMutableSet setWithObject:@"public.source-code"];
		NSMutableArray *imported = [NSMutableArray array];
		NSMutableArray *markdown = [NSMutableArray array];
		for (NSString *suffix in [suffixes.allObjects sortedArrayUsingSelector:@selector(compare:)])
		{
			if (NSSet *known = systemTypes[suffix])
			{
				[types unionSet:known];
				continue;
			}
			if ([suffix isEqualToString:@"md"] || [suffix isEqualToString:@"markdown"])
			{
				[markdown addObject:suffix];
				continue;
			}

			// Use a text fallback without registering the extension for unrelated binary types.
			NSString *identifier = [NSString stringWithFormat:@"%@.file.%@", app[@"CFBundleIdentifier"], suffix];
			[types addObject:identifier];
			[imported addObject:@{
				@"UTTypeIdentifier": identifier,
				@"UTTypeDescription": [NSString stringWithFormat:@"%@ text file", suffix.uppercaseString],
				@"UTTypeConformsTo": @[@"public.plain-text"],
				@"UTTypeTagSpecification": @{@"public.filename-extension": @[suffix]}
			}];
		}
		if (markdown.count)
		{
			NSString *identifier = @"net.daringfireball.markdown";
			[types addObject:identifier];
			[imported addObject:@{
				@"UTTypeIdentifier": identifier,
				@"UTTypeDescription": @"Markdown text file",
				@"UTTypeConformsTo": @[@"public.plain-text"],
				@"UTTypeTagSpecification": @{@"public.filename-extension": markdown}
			}];
		}

		app[@"UTImportedTypeDeclarations"] = imported;
		NSMutableDictionary *extensionInfo = [extension[@"NSExtension"] mutableCopy];
		NSMutableDictionary *attributes = [extensionInfo[@"NSExtensionAttributes"] mutableCopy];
		attributes[@"QLSupportedContentTypes"] = [types.allObjects sortedArrayUsingSelector:@selector(compare:)];
		extensionInfo[@"NSExtensionAttributes"] = attributes;
		extension[@"NSExtension"] = extensionInfo;
		for (NSString *key in @[@"CFBundleVersion", @"CFBundleShortVersionString"])
			extension[key] = app[key];
		return [app writeToFile:appPath atomically:YES] && [extension writeToFile:extensionPath atomically:YES] ? 0 : 1;
	}
}

// SPDX-License-Identifier: GPL-3.0-only
#import "EditorPluginCatalog.h"
#import "EditorHash.h"
#import "EditorPlugins.h"
#import "EditorResources.h"

@interface EditorPluginPackage ()
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *filename;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) NSString *sha256;
@property(nonatomic, strong) NSURL *url;
@end
@implementation EditorPluginPackage
@end

static NSError *CatalogError(NSString *message)
{
	return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError
		userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL AllowedURL(NSURL *url, BOOL local)
{
	return (local && url.isFileURL) || ([url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length);
}

NSArray<EditorPluginPackage *> *EditorPluginPackages(NSData *data, NSURL *source, NSError **error)
{
	id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
	id entries = [json isKindOfClass:NSDictionary.class] ? json[@"plugins"] : nil;
	if (![entries isKindOfClass:NSArray.class] || [entries count] > 1000)
	{
		if (error && !*error)
			*error = CatalogError(@"The catalog must contain a plugins array.");
		return nil;
	}
	NSMutableArray<EditorPluginPackage *> *packages = [NSMutableArray array];
	NSMutableSet<NSString *> *filenames = [NSMutableSet set];
	NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
	for (id item in entries)
	{
		if (![item isKindOfClass:NSDictionary.class])
			continue;
		BOOL strings = YES;
		for (NSString *key in @[@"name", @"file", @"version", @"sha256", @"url"])
			if (![item[key] isKindOfClass:NSString.class] || ![item[key] length])
				strings = NO;
		if (!strings)
			continue;
		NSString *filename = item[@"file"];
		NSString *hash = item[@"sha256"];
		NSURL *url = [NSURL URLWithString:item[@"url"] relativeToURL:source].absoluteURL;
		if (![filename isEqualToString:filename.lastPathComponent] || [filename hasPrefix:@"."] ||
			![filename.pathExtension.lowercaseString isEqualToString:@"dylib"] || [filenames containsObject:filename.lowercaseString] ||
			hash.length != 64 || [hash rangeOfCharacterFromSet:nonHex].location != NSNotFound || !AllowedURL(url, source.isFileURL))
			continue;
		[filenames addObject:filename.lowercaseString];
		EditorPluginPackage *package = [EditorPluginPackage new];
		package.name = item[@"name"];
		package.filename = filename;
		package.version = item[@"version"];
		package.sha256 = hash.lowercaseString;
		package.url = url;
		[packages addObject:package];
	}
	return packages;
}

static void ReadURL(NSURL *url, NSUInteger limit, void (^completion)(NSData *, NSError *))
{
	if (url.isFileURL)
	{
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
			NSError *error = nil;
			NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&error];
			if (data.length > limit)
			{
				data = nil;
				error = CatalogError(@"The catalog file exceeds the maximum supported size.");
			}
			dispatch_async(dispatch_get_main_queue(), ^{ completion(data, error); });
		});
		return;
	}
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
	[request setValue:@"macpad++" forHTTPHeaderField:@"User-Agent"];
	NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:
		^(NSData *data, NSURLResponse *response, NSError *error) {
			BOOL success = !error && AllowedURL(response.URL, NO) &&
				[response isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse *)response).statusCode == 200 && data.length <= limit;
			dispatch_async(dispatch_get_main_queue(), ^{
				completion(success ? data : nil, success ? nil : error ?: CatalogError(@"The catalog download failed."));
			});
		}];
	[task resume];
}

static NSURL *CatalogSource()
{
	NSString *setting = [EditorResources.shared setting:@"pluginCatalogURL" fallback:@""];
	NSURL *url = setting.length ? [NSURL URLWithString:setting] : nil;
	return AllowedURL(url, YES) ? url : [NSBundle.mainBundle URLForResource:@"plugins-catalog" withExtension:@"json"];
}

void EditorChoosePluginCatalog(void)
{
	NSAlert *choice = [NSAlert new];
	choice.messageText = @"Plugin Catalog Source";
	choice.informativeText = @"Use the bundled catalog, choose a local JSON file, or enter an HTTPS catalog URL.";
	[choice addButtonWithTitle:@"Use URL"];
	[choice addButtonWithTitle:@"Choose File…"];
	[choice addButtonWithTitle:@"Use Bundled Catalog"];
	[choice addButtonWithTitle:@"Cancel"];
	NSTextField *url = [NSTextField textFieldWithString:[EditorResources.shared setting:@"pluginCatalogURL" fallback:@""]];
	url.placeholderString = @"https://example.org/plugins.json";
	url.frame = NSMakeRect(0, 0, 420, 25);
	choice.accessoryView = url;
	NSModalResponse response = [choice runModal];
	NSString *value = nil;
	if (response == NSAlertFirstButtonReturn)
	{
		NSURL *source = [NSURL URLWithString:[url.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
		if (AllowedURL(source, NO))
			value = source.absoluteString;
		else
			[NSApp presentError:CatalogError(@"Enter a valid HTTPS catalog URL.")];
	}
	else if (response == NSAlertSecondButtonReturn)
	{
		NSOpenPanel *panel = NSOpenPanel.openPanel;
		if ([panel runModal] == NSModalResponseOK)
			value = panel.URL.absoluteString;
	}
	else if (response == NSAlertThirdButtonReturn)
		value = @"";
	if (value)
		[EditorResources.shared setSetting:value forName:@"pluginCatalogURL"];
}

static void Install(EditorPlugins *plugins, EditorPluginPackage *package, BOOL updating)
{
	ReadURL(package.url, 32 * 1024 * 1024, ^(NSData *data, NSError *error) {
		if (error)
			return (void)[NSApp presentError:error];
		if (!data.length || ![EditorHashData(data, EditorHashSHA256) isEqualToString:package.sha256])
			return (void)[NSApp presentError:CatalogError(@"The plugin does not match the catalog's SHA-256 checksum.")];
		NSError *failure = nil;
		if (![plugins installCatalogPlugin:data filename:package.filename updating:updating error:&failure])
		{
			[NSApp presentError:failure ?: CatalogError(@"The plugin could not be installed.")];
			return;
		}
		EditorResources *resources = EditorResources.shared;
		NSMutableDictionary *versions = [[resources setting:@"catalogPluginVersions" fallback:@{}] mutableCopy];
		versions[package.filename] = package.version;
		[resources setSetting:versions forName:@"catalogPluginVersions"];
		NSAlert *complete = [NSAlert new];
		complete.messageText = [NSString stringWithFormat:@"%@ %@ installed", package.name, package.version];
		complete.informativeText = @"Restart macpad++ to load this version.";
		[complete runModal];
	});
}

void EditorShowPluginCatalog(EditorPlugins *plugins)
{
	if (!plugins)
		return;
	NSURL *source = CatalogSource();
	ReadURL(source, 1024 * 1024, ^(NSData *data, NSError *error) {
		NSError *failure = error;
		NSArray<EditorPluginPackage *> *packages = failure ? nil : EditorPluginPackages(data, source, &failure);
		if (failure)
		{
			[NSApp presentError:failure];
			return;
		}
		NSDictionary *versions = [EditorResources.shared setting:@"catalogPluginVersions" fallback:@{}];
		NSAlert *catalog = [NSAlert new];
		catalog.messageText = @"Plugin Catalog";
		catalog.informativeText = packages.count ? @"Select a native plugin to install or update." : @"This catalog contains no compatible entries.";
		[catalog addButtonWithTitle:@"Install or Update"];
		[catalog addButtonWithTitle:@"Close"];
		NSPopUpButton *choices = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 436, 28) pullsDown:NO];
		for (EditorPluginPackage *package in packages)
		{
			NSURL *installed = [plugins.directory URLByAppendingPathComponent:package.filename];
			BOOL present = [NSFileManager.defaultManager fileExistsAtPath:installed.path];
			NSString *version = [versions[package.filename] isKindOfClass:NSString.class] ? versions[package.filename] : nil;
			NSString *status = !present ? @"Available" : !version ? @"Installed from file" :
				[version compare:package.version options:NSNumericSearch] == NSOrderedAscending ? @"Update available" : @"Installed";
			[choices addItemWithTitle:[NSString stringWithFormat:@"%@ %@ — %@", package.name, package.version, status]];
			choices.lastItem.representedObject = package;
		}
		if (packages.count)
			catalog.accessoryView = choices;
		else
			[catalog.buttons firstObject].enabled = NO;
		if ([catalog runModal] != NSAlertFirstButtonReturn)
			return;
		EditorPluginPackage *package = choices.selectedItem.representedObject;
		if (!package)
			return;
		NSURL *target = [plugins.directory URLByAppendingPathComponent:package.filename];
		BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:target.path];
		NSString *version = [versions[package.filename] isKindOfClass:NSString.class] ? versions[package.filename] : nil;
		if (exists && version && [version compare:package.version options:NSNumericSearch] != NSOrderedAscending)
			return;
		NSAlert *confirm = [NSAlert new];
		confirm.messageText = [NSString stringWithFormat:@"%@ %@ %@?", exists ? @"Update" : @"Install", package.name, package.version];
		confirm.informativeText = package.url.isFileURL ? package.url.lastPathComponent : package.url.host;
		[confirm addButtonWithTitle:exists ? @"Update" : @"Install"];
		[confirm addButtonWithTitle:@"Cancel"];
		if ([confirm runModal] == NSAlertFirstButtonReturn)
			Install(plugins, package, exists);
	});
}

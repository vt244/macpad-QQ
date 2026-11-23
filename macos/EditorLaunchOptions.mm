// SPDX-License-Identifier: GPL-3.0-only
#import "EditorLaunchOptions.h"
#include <fnmatch.h>

@implementation EditorLaunchOptions
- (instancetype)initWithArguments:(NSArray<NSString *> *)arguments
{
	if (!(self = [super init]))
		return nil;
	_position = -1;
	NSMutableArray<NSURL *> *paths = [NSMutableArray array];
	BOOL positional = NO;
	for (NSUInteger i = 0; i < arguments.count; ++i)
	{
		NSString *argument = arguments[i];
		if (!positional && [argument isEqualToString:@"--"])
		{
			positional = YES;
			continue;
		}
		if (positional || ![argument hasPrefix:@"-"])
		{
			[paths addObject:[NSURL fileURLWithPath:argument.stringByExpandingTildeInPath].URLByStandardizingPath];
			continue;
		}
		if ([argument isEqualToString:@"--help"]) _help = YES;
		else if ([argument isEqualToString:@"-multiInst"]) _multiInstance = YES;
		else if ([argument isEqualToString:@"-r"]) _recursive = YES;
		else if ([argument isEqualToString:@"-quickPrint"]) _quickPrint = YES;
		else if ([argument isEqualToString:@"-alwaysOnTop"]) _alwaysOnTop = YES;
		else if ([argument isEqualToString:@"-nosession"]) _noSession = YES;
		else if ([argument isEqualToString:@"-noPlugin"]) _noPlugins = YES;
		else if ([argument isEqualToString:@"-notabbar"]) _hideTabs = YES;
		else if ([argument isEqualToString:@"-ro"]) _readOnly = YES;
		else if ([argument isEqualToString:@"-fullReadOnly"]) _fullReadOnly = YES;
		else if ([argument isEqualToString:@"-fullReadOnlySavingForbidden"]) _fullReadOnly = _savingForbidden = YES;
		else if ([argument isEqualToString:@"-monitor"]) _monitor = YES;
		else if ([argument isEqualToString:@"-monitoringMode"]) _monitoringMode = YES;
		else if ([argument hasPrefix:@"-titleAdd="]) _titleSuffix = [argument substringFromIndex:10];
		else if ([argument isEqualToString:@"-openSession"]) _openSession = YES;
		else if ([argument isEqualToString:@"-openFoldersAsWorkspace"]) _openFoldersAsWorkspace = YES;
		else if ([argument hasPrefix:@"-settingsDir="]) _settingsPath = [argument substringFromIndex:13].stringByExpandingTildeInPath;
		else if ([argument hasPrefix:@"-udl="]) _language = [@"udl:" stringByAppendingString:[argument substringFromIndex:5]];
		else if ([argument hasPrefix:@"-l"] || [argument hasPrefix:@"-L"] || [argument hasPrefix:@"-n"] ||
			[argument hasPrefix:@"-c"] || [argument hasPrefix:@"-p"] || [argument hasPrefix:@"-x"] || [argument hasPrefix:@"-y"])
		{
			if ([argument hasPrefix:@"--"] || [argument hasPrefix:@"-psn_"])
				continue;
			const auto option = [argument characterAtIndex:1];
			NSString *value = argument.length > 2 ? [argument substringFromIndex:2] : @"";
			if (!value.length && i + 1 < arguments.count)
			{
				NSString *next = arguments[i + 1];
				NSScanner *coordinate = [NSScanner scannerWithString:next];
				NSInteger parsed;
				if (![next hasPrefix:@"-"] ||
					((option == 'x' || option == 'y') && [coordinate scanInteger:&parsed] && coordinate.isAtEnd))
					value = arguments[++i];
			}
			if ([value hasPrefix:@"="])
				value = [value substringFromIndex:1];
			if (!value.length)
				continue;
			if ([argument characterAtIndex:1] == 'l')
				_language = value.lowercaseString;
			else if ([argument characterAtIndex:1] == 'L')
				_translation = value.lowercaseString;
			else
			{
				NSScanner *number = [NSScanner scannerWithString:value];
				NSInteger result = 0;
				if (![number scanInteger:&result] || !number.isAtEnd || (result < 0 && option != 'x' && option != 'y'))
					continue;
				switch ([argument characterAtIndex:1])
				{
					case 'n': _line = result; break;
					case 'c': _column = result; break;
					case 'p': _position = result; break;
					case 'x': _leftPosition = @(result); break;
					case 'y': _topPosition = @(result); break;
				}
			}
		}
	}
	_paths = [paths copy];
	return self;
}

- (NSArray<NSURL *> *)expandedPaths
{
	NSMutableOrderedSet<NSURL *> *expanded = [NSMutableOrderedSet orderedSet];
	NSCharacterSet *wildcards = [NSCharacterSet characterSetWithCharactersInString:@"*?["];
	for (NSURL *url in _paths)
	{
		NSString *path = url.path;
		NSRange first = [path rangeOfCharacterFromSet:wildcards];
		if (first.location == NSNotFound || [NSFileManager.defaultManager fileExistsAtPath:path])
		{
			[expanded addObject:url];
			continue;
		}
		NSUInteger divider = [path rangeOfString:@"/" options:NSBackwardsSearch
			range:NSMakeRange(0, first.location)].location;
		NSString *prefix = [path substringToIndex:divider + 1];
		NSString *pattern = [path substringFromIndex:divider + 1];
		BOOL matchPath = [pattern containsString:@"/"];
		NSURL *root = [NSURL fileURLWithPath:prefix isDirectory:YES];
		NSDirectoryEnumerationOptions options = NSDirectoryEnumerationSkipsPackageDescendants;
		if (!_recursive && !matchPath)
			options |= NSDirectoryEnumerationSkipsSubdirectoryDescendants;
		NSDirectoryEnumerator<NSURL *> *iterator = [NSFileManager.defaultManager enumeratorAtURL:root
			includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:options errorHandler:nil];
		NSMutableArray<NSURL *> *matches = [NSMutableArray array];
		for (NSURL *candidate in iterator)
		{
			NSNumber *file;
			if (![candidate getResourceValue:&file forKey:NSURLIsRegularFileKey error:nil] || !file.boolValue)
				continue;
			NSString *value = matchPath ? [candidate.path substringFromIndex:prefix.length] : candidate.lastPathComponent;
			if (fnmatch(pattern.fileSystemRepresentation, value.fileSystemRepresentation, FNM_PATHNAME) == 0)
				[matches addObject:candidate.URLByStandardizingPath];
		}
		[matches sortUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
			return [left.path localizedStandardCompare:right.path];
		}];
		[expanded addObjectsFromArray:matches];
	}
	return expanded.array;
}
@end

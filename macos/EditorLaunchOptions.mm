// SPDX-License-Identifier: GPL-3.0-only
#import "EditorLaunchOptions.h"

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
		else if ([argument isEqualToString:@"-nosession"]) _noSession = YES;
		else if ([argument isEqualToString:@"-noPlugin"]) _noPlugins = YES;
		else if ([argument isEqualToString:@"-notabbar"]) _hideTabs = YES;
		else if ([argument isEqualToString:@"-ro"] || [argument isEqualToString:@"-fullReadOnly"]) _readOnly = YES;
		else if ([argument isEqualToString:@"-monitor"] || [argument isEqualToString:@"-monitoringMode"]) _monitor = YES;
		else if ([argument isEqualToString:@"-openSession"]) _openSession = YES;
		else if ([argument isEqualToString:@"-openFoldersAsWorkspace"]) _openFoldersAsWorkspace = YES;
		else if ([argument hasPrefix:@"-settingsDir="]) _settingsPath = [argument substringFromIndex:13].stringByExpandingTildeInPath;
		else if ([argument hasPrefix:@"-udl="]) _language = [@"udl:" stringByAppendingString:[argument substringFromIndex:5]];
		else if ([argument hasPrefix:@"-l"] || [argument hasPrefix:@"-L"] || [argument hasPrefix:@"-n"] ||
			[argument hasPrefix:@"-c"] || [argument hasPrefix:@"-p"])
		{
			if ([argument hasPrefix:@"--"] || [argument hasPrefix:@"-psn_"])
				continue;
			NSString *value = argument.length > 2 ? [argument substringFromIndex:2] :
				(i + 1 < arguments.count && ![arguments[i + 1] hasPrefix:@"-"] ? arguments[++i] : @"");
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
				if (![number scanInteger:&result] || !number.isAtEnd || result < 0)
					continue;
				switch ([argument characterAtIndex:1])
				{
					case 'n': _line = result; break;
					case 'c': _column = result; break;
					case 'p': _position = result; break;
				}
			}
		}
	}
	_paths = [paths copy];
	return self;
}
@end

// SPDX-License-Identifier: GPL-3.0-only
#import "EditorRun.h"

NSString *ExpandEditorRunCommand(NSString *command, NSDictionary<NSString *, NSString *> *values)
{
	NSMutableString *result = [NSMutableString string];
	unichar quote = 0;
	for (NSUInteger i = 0; i < command.length; ++i)
	{
		unichar character = [command characterAtIndex:i];
		if (character == '\\' && quote != '\'' && i + 1 < command.length)
		{
			[result appendString:[command substringWithRange:NSMakeRange(i, 2)]];
			++i;
			continue;
		}
		if ((character == '"' || character == '\'') && (!quote || quote == character))
			quote = quote ? 0 : character;
		if (character == '$' && i + 2 < command.length && [command characterAtIndex:i + 1] == '(')
		{
			NSRange tail = NSMakeRange(i + 2, command.length - i - 2);
			NSRange end = [command rangeOfString:@")" options:0 range:tail];
			if (end.location != NSNotFound)
			{
				NSString *key = [command substringWithRange:NSMakeRange(tail.location, end.location - tail.location)];
				if (values[key])
				{
					// Expand document values as single shell arguments, even when they contain quotes or metacharacters.
					[result appendFormat:quote == '\'' ? @"'\"${%@}\"'" : quote == '"' ? @"${%@}" : @"\"${%@}\"", key];
					i = end.location;
					continue;
				}
			}
		}
		NSUInteger length = 1;
		if (CFStringIsSurrogateHighCharacter(character) && i + 1 < command.length &&
			CFStringIsSurrogateLowCharacter([command characterAtIndex:i + 1]))
			length = 2;
		[result appendString:[command substringWithRange:NSMakeRange(i, length)]];
		i += length - 1;
	}
	return result;
}

NSTask *EditorRunTask(NSString *command, NSDictionary<NSString *, NSString *> *values, NSURL *workingDirectory)
{
	NSTask *task = [[NSTask alloc] init];
	task.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"];
	task.arguments = @[@"-c", ExpandEditorRunCommand(command, values)];
	task.currentDirectoryURL = workingDirectory;
	NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
	[environment addEntriesFromDictionary:values];
	task.environment = environment;
	return task;
}

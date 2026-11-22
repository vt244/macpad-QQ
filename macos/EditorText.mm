// SPDX-License-Identifier: GPL-3.0-only
#import "EditorText.h"

#include <vector>

NSString *DecodeExtendedSearchText(NSString *input)
{
	std::vector<unichar> output;
	output.reserve(input.length);
	for (NSUInteger index = 0; index < input.length; ++index)
	{
		unichar value = [input characterAtIndex:index];
		if (value != '\\' || index + 1 == input.length)
		{
			output.push_back(value);
			continue;
		}
		value = [input characterAtIndex:++index];
		switch (value)
		{
			case '0': output.push_back(0); continue;
			case 'r': output.push_back('\r'); continue;
			case 'n': output.push_back('\n'); continue;
			case 't': output.push_back('\t'); continue;
			case '\\': output.push_back('\\'); continue;
		}
		const unsigned digits = value == 'b' ? 8 : value == 'u' ? 4 : value == 'x' ? 2 : 3;
		const unsigned base = value == 'b' ? 2 : value == 'o' ? 8 : value == 'd' ? 10 :
			(value == 'x' || value == 'u') ? 16 : 0;
		unsigned number = 0;
		unsigned position = 0;
		if (base && index + digits < input.length)
			for (; position < digits; ++position)
			{
				const unichar digit = [input characterAtIndex:index + position + 1];
				const unsigned numeric = digit >= '0' && digit <= '9' ? digit - '0' : digit >= 'a' && digit <= 'f' ? digit - 'a' + 10 :
					digit >= 'A' && digit <= 'F' ? digit - 'A' + 10 : 16;
				if (numeric >= base)
					break;
				number = number * base + numeric;
			}
		if (position == digits)
		{
			output.push_back(static_cast<unichar>(number));
			index += digits;
		}
		else
		{
			output.push_back('\\');
			output.push_back(value);
		}
	}
	return output.empty() ? @"" : [NSString stringWithCharacters:output.data() length:output.size()];
}

NSString *DecodeEditorTextWithEncoding(NSData *data, NSStringEncoding encoding)
{
	NSString *text = data ? [[NSString alloc] initWithData:data encoding:encoding] : nil;
	const unichar zero = 0;
	return text && [text rangeOfString:[NSString stringWithCharacters:&zero length:1]].location == NSNotFound ? text : nil;
}

NSString *DecodeEditorText(NSData *data, NSStringEncoding *encoding, NSData **bom)
{
	if (!data)
		return nil;
	const auto *bytes = static_cast<const unsigned char *>(data.bytes);
	NSStringEncoding detected = NSUTF8StringEncoding;
	NSUInteger offset = 0;
	if (data.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf)
		offset = 3;
	else if (data.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe)
	{
		detected = NSUTF16LittleEndianStringEncoding;
		offset = 2;
	}
	else if (data.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff)
	{
		detected = NSUTF16BigEndianStringEncoding;
		offset = 2;
	}
	NSData *payload = offset ? [data subdataWithRange:NSMakeRange(offset, data.length - offset)] : data;
	NSString *text = DecodeEditorTextWithEncoding(payload, detected);
	if (!text && !offset)
	{
		detected = NSWindowsCP1252StringEncoding;
		text = DecodeEditorTextWithEncoding(payload, detected);
	}
	if (!text)
		return nil;
	if (encoding)
		*encoding = detected;
	if (bom)
		*bom = offset ? [data subdataWithRange:NSMakeRange(0, offset)] : nil;
	return text;
}

NSData *EncodeEditorText(NSData *utf8, NSStringEncoding encoding, NSData *bom)
{
	NSData *data = utf8;
	if (encoding != NSUTF8StringEncoding)
		data = [[[NSString alloc] initWithData:utf8 encoding:NSUTF8StringEncoding] dataUsingEncoding:encoding];
	if (!data || !bom.length)
		return data;
	NSMutableData *result = [bom mutableCopy];
	[result appendData:data];
	return result;
}

// SPDX-License-Identifier: GPL-3.0-only
#import "EditorPreview.h"
#import "EditorResources.h"
#import "EditorText.h"
#import "ScintillaView.h"

BOOL IsEditorPreviewKey(NSEvent *event)
{
	return [event.charactersIgnoringModifiers isEqualToString:@" "] &&
		!(event.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagControl |
			NSEventModifierFlagOption | NSEventModifierFlagCommand));
}

BOOL LoadEditorPreview(ScintillaView *view, NSURL *fileURL, EditorResources *resources, NSError **error)
{
	NSNumber *regular = nil;
	if (![fileURL.URLByResolvingSymlinksInPath getResourceValue:&regular forKey:NSURLIsRegularFileKey error:error])
		return NO;
	if (!regular.boolValue)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnsupportedSchemeError
				userInfo:@{NSURLErrorKey: fileURL}];
		return NO;
	}
	NSData *bytes = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:error];
	if (!bytes)
		return NO;
	NSString *text = DecodeEditorText(bytes, nullptr, nullptr);
	if (!text)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadInapplicableStringEncodingError
				userInfo:@{NSURLErrorKey: fileURL}];
		return NO;
	}

	[view message:SCI_SETREADONLY wParam:0];
	[view message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
	[view message:SCI_SETUNDOCOLLECTION wParam:0];
	[view setString:text];
	[view message:SCI_GOTOPOS wParam:0];
	[view message:SCI_SETTABWIDTH wParam:MIN(32, MAX(1, [[resources setting:@"tabWidth" fallback:@4] integerValue]))];
	[view message:SCI_SETSCROLLWIDTHTRACKING wParam:1];
	[view message:SCI_SETSCROLLWIDTH wParam:1];
	[view message:SCI_SETMARGINTYPEN wParam:0 lParam:SC_MARGIN_NUMBER];
	for (int margin = 1; margin <= 4; ++margin)
		[view message:SCI_SETMARGINWIDTHN wParam:margin lParam:0];
	[resources configure:view extension:EditorSyntaxExtension(fileURL) language:nil syntaxHighlighting:YES identifier:nullptr];
	NSString *lastLine = [NSString stringWithFormat:@"%ld", [view message:SCI_GETLINECOUNT]];
	const auto width = [view message:SCI_TEXTWIDTH wParam:STYLE_LINENUMBER lParam:reinterpret_cast<sptr_t>(lastLine.UTF8String)];
	[view message:SCI_SETMARGINWIDTHN wParam:0 lParam:MAX(32, width + 10)];
	[view message:SCI_SETCARETLINEVISIBLE wParam:0];
	[view message:SCI_SETREADONLY wParam:1];
	return YES;
}

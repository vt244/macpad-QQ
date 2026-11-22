// SPDX-License-Identifier: GPL-3.0-only
#import "EditorDocument.h"
#import "EditorResources.h"
#import "ScintillaView.h"

#include <cstring>
#include <string_view>

@implementation EditorDocumentController
- (NSString *)defaultType
{
	return @"public.plain-text";
}

- (Class)documentClassForType:(NSString *)typeName
{
	return EditorDocument.class;
}

- (NSString *)typeForContentsOfURL:(NSURL *)url error:(NSError **)error
{
	NSNumber *regular = nil;
	if (![url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:error])
		return nil;
	if (!regular.boolValue)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnsupportedSchemeError
				userInfo:@{NSURLErrorKey: url}];
		return nil;
	}
	return self.defaultType;
}
@end

@implementation EditorDocument
{
	NSData *_loadedUTF8;
	NSStringEncoding _encoding;
	NSData *_bom;
	NSTextField *_status;
	NSString *_query;
	NSInteger _searchFlags;
	sptr_t _lastEmptyMatch;
	BOOL _loading;
}

- (instancetype)init
{
	self = [super init];
	if (self)
	{
		_encoding = NSUTF8StringEncoding;
		_lastEmptyMatch = -1;
		self.hasUndoManager = NO;
	}
	return self;
}

+ (NSArray<NSString *> *)readableTypes
{
	return @[@"public.plain-text"];
}

+ (NSArray<NSString *> *)writableTypes
{
	return self.readableTypes;
}

- (BOOL)prepareSavePanel:(NSSavePanel *)panel
{
	if (![super prepareSavePanel:panel])
		return NO;
	panel.allowsOtherFileTypes = YES;
	return YES;
}

- (void)makeWindowControllers
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 680)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
			NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
	window.minSize = NSMakeSize(420, 260);
	window.tabbingIdentifier = @"macpad.editor";
	window.tabbingMode = NSWindowTabbingModePreferred;
	window.releasedWhenClosed = NO;
	[window center];

	NSView *content = window.contentView;
	_editor = [[ScintillaView alloc] initWithFrame:content.bounds];
	_editor.translatesAutoresizingMaskIntoConstraints = NO;
	_editor.delegate = (id<ScintillaNotificationProtocol>)self;
	[_editor message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
	[_editor message:SCI_SETTABWIDTH wParam:4];
	[_editor message:SCI_SETMARGINTYPEN wParam:0 lParam:SC_MARGIN_NUMBER];
	[_editor message:SCI_SETMARGINWIDTHN wParam:0 lParam:46];
	[_editor message:SCI_SETMARGINWIDTHN wParam:1 lParam:0];
	_status = [NSTextField labelWithString:@""];
	_status.translatesAutoresizingMaskIntoConstraints = NO;
	_status.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
	_status.textColor = NSColor.secondaryLabelColor;
	NSBox *line = [[NSBox alloc] initWithFrame:NSZeroRect];
	line.boxType = NSBoxSeparator;
	line.translatesAutoresizingMaskIntoConstraints = NO;
	[content addSubview:_editor];
	[content addSubview:line];
	[content addSubview:_status];
	[NSLayoutConstraint activateConstraints:@[
		[_editor.topAnchor constraintEqualToAnchor:content.topAnchor],
		[_editor.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
		[_editor.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
		[_editor.bottomAnchor constraintEqualToAnchor:line.topAnchor],
		[line.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
		[line.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
		[line.heightAnchor constraintEqualToConstant:1],
		[line.bottomAnchor constraintEqualToAnchor:_status.topAnchor constant:-5],
		[_status.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
		[_status.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-12],
		[_status.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-5],
	]];
	window.initialFirstResponder = _editor.content;
	[self addWindowController:[[NSWindowController alloc] initWithWindow:window]];
	[self applyTheme];
	[self loadEditor];
}

- (void)setFileURL:(NSURL *)fileURL
{
	[super setFileURL:fileURL];
	[self applyTheme];
}

- (void)applyTheme
{
	if (_editor)
		[EditorResources.shared configure:_editor extension:self.fileURL.pathExtension.lowercaseString ?: @""];
}

- (void)loadEditor
{
	if (!_editor)
		return;
	_loading = YES;
	[_editor message:SCI_SETUNDOCOLLECTION wParam:0];
	[_editor message:SCI_CLEARALL];
	if (_loadedUTF8.length)
		[_editor message:SCI_ADDTEXT wParam:_loadedUTF8.length lParam:reinterpret_cast<sptr_t>(_loadedUTF8.bytes)];
	[_editor message:SCI_SETUNDOCOLLECTION wParam:1];
	[_editor message:SCI_EMPTYUNDOBUFFER];
	[_editor message:SCI_SETSAVEPOINT];
	[_editor message:SCI_GOTOPOS wParam:0];
	[_editor message:SCI_COLOURISE wParam:0 lParam:-1];
	std::string_view bytes(_loadedUTF8.length ? static_cast<const char *>(_loadedUTF8.bytes) : "", _loadedUTF8.length);
	size_t eol = bytes.find_first_of("\r\n");
	int eolMode = SC_EOL_LF;
	if (eol != bytes.npos && bytes[eol] == '\r')
		eolMode = eol + 1 < bytes.size() && bytes[eol + 1] == '\n' ? SC_EOL_CRLF : SC_EOL_CR;
	[_editor message:SCI_SETEOLMODE wParam:eolMode];
	_loading = NO;
	_loadedUTF8 = nil;
	[self updateStatus];
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName error:(NSError **)error
{
	const auto *bytes = static_cast<const unsigned char *>(data.bytes);
	NSStringEncoding encoding = NSUTF8StringEncoding;
	NSUInteger offset = 0;
	if (data.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf)
		offset = 3;
	else if (data.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe)
	{
		encoding = NSUTF16LittleEndianStringEncoding;
		offset = 2;
	}
	else if (data.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff)
	{
		encoding = NSUTF16BigEndianStringEncoding;
		offset = 2;
	}
	NSData *payload = [data subdataWithRange:NSMakeRange(offset, data.length - offset)];
	NSString *text = [[NSString alloc] initWithData:payload encoding:encoding];
	if (!text || [text rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadInapplicableStringEncodingError
				userInfo:@{NSLocalizedDescriptionKey: @"Open a UTF-8 or UTF-16 text file. Binary files are unsupported."}];
		return NO;
	}
	_encoding = encoding;
	_bom = offset ? [data subdataWithRange:NSMakeRange(0, offset)] : nil;
	_loadedUTF8 = [text dataUsingEncoding:NSUTF8StringEncoding];
	[self loadEditor];
	return YES;
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)error
{
	NSData *utf8 = _loadedUTF8 ?: [NSData data];
	if (_editor)
	{
		const auto length = [_editor message:SCI_GETLENGTH];
		const auto *bytes = reinterpret_cast<const void *>([_editor message:SCI_GETCHARACTERPOINTER]);
		utf8 = [NSData dataWithBytes:bytes length:length];
	}
	NSData *data = utf8;
	if (_encoding != NSUTF8StringEncoding)
		data = [[[NSString alloc] initWithData:utf8 encoding:NSUTF8StringEncoding] dataUsingEncoding:_encoding];
	if (!data)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError userInfo:nil];
		return nil;
	}
	if (!_bom)
		return data;
	NSMutableData *result = [_bom mutableCopy];
	[result appendData:data];
	return result;
}

- (void)saveToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)operation
	completionHandler:(void (^)(NSError *))completionHandler
{
	[super saveToURL:url ofType:typeName forSaveOperation:operation completionHandler:^(NSError *error) {
		if (!error && operation != NSSaveToOperation)
			[self.editor message:SCI_SETSAVEPOINT];
		completionHandler(error);
	}];
}

- (void)notification:(SCNotification *)notification
{
	if (_loading)
		return;
	switch (notification->nmhdr.code)
	{
		case SCN_SAVEPOINTLEFT:
			[self updateChangeCount:NSChangeDone];
			break;
		case SCN_SAVEPOINTREACHED:
			[self updateChangeCount:NSChangeCleared];
			break;
		case SCN_UPDATEUI:
			[self updateStatus];
			break;
	}
}

- (void)updateStatus
{
	auto position = [_editor message:SCI_GETCURRENTPOS];
	auto line = [_editor message:SCI_LINEFROMPOSITION wParam:position];
	auto column = [_editor message:SCI_GETCOLUMN wParam:position];
	auto eol = [_editor message:SCI_GETEOLMODE];
	NSString *ending = eol == SC_EOL_CRLF ? @"CRLF" : eol == SC_EOL_CR ? @"CR" : @"LF";
	NSString *encoding = _encoding == NSUTF8StringEncoding ? (_bom ? @"UTF-8 BOM" : @"UTF-8") :
		_encoding == NSUTF16LittleEndianStringEncoding ? @"UTF-16 LE" : @"UTF-16 BE";
	_status.stringValue = [NSString stringWithFormat:@"%ld:%ld    %@    %@", line + 1, column + 1, encoding, ending];
}

- (IBAction)toggleWrap:(id)sender
{
	[_editor message:SCI_SETWRAPMODE wParam:[_editor message:SCI_GETWRAPMODE] ? SC_WRAP_NONE : SC_WRAP_WORD];
}

- (IBAction)toggleLineNumbers:(id)sender
{
	[_editor message:SCI_SETMARGINWIDTHN wParam:0 lParam:[_editor message:SCI_GETMARGINWIDTHN wParam:0] ? 0 : 46];
}

- (IBAction)findText:(id)sender
{
	[self showSearch:NO];
}

- (IBAction)replaceText:(id)sender
{
	[self showSearch:YES];
}

- (void)showSearch:(BOOL)replace
{
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = replace ? @"Replace" : @"Find";
	[alert addButtonWithTitle:replace ? @"Replace All" : @"Find Next"];
	[alert addButtonWithTitle:@"Cancel"];
	NSTextField *query = [NSTextField textFieldWithString:_query ?: _editor.selectedString ?: @""];
	query.placeholderString = @"Search for";
	NSTextField *replacement = [NSTextField textFieldWithString:@""];
	replacement.placeholderString = @"Replace with";
	NSButton *match = [NSButton checkboxWithTitle:@"Match case" target:nil action:nil];
	NSButton *regex = [NSButton checkboxWithTitle:@"Regular expression" target:nil action:nil];
	match.state = _searchFlags & SCFIND_MATCHCASE ? NSControlStateValueOn : NSControlStateValueOff;
	regex.state = _searchFlags & SCFIND_REGEXP ? NSControlStateValueOn : NSControlStateValueOff;
	NSArray *fields = replace ? @[query, replacement, match, regex] : @[query, match, regex];
	NSStackView *form = [NSStackView stackViewWithViews:fields];
	form.orientation = NSUserInterfaceLayoutOrientationVertical;
	form.alignment = NSLayoutAttributeLeading;
	form.frame = NSMakeRect(0, 0, 320, replace ? 112 : 84);
	[query.widthAnchor constraintEqualToConstant:320].active = YES;
	if (replace)
		[replacement.widthAnchor constraintEqualToAnchor:query.widthAnchor].active = YES;
	alert.accessoryView = form;
	alert.window.initialFirstResponder = query;
	if ([alert runModal] != NSAlertFirstButtonReturn || !query.stringValue.length)
		return;
	_query = query.stringValue;
	_lastEmptyMatch = -1;
	_searchFlags = (match.state == NSControlStateValueOn ? SCFIND_MATCHCASE : 0) |
		(regex.state == NSControlStateValueOn ? SCFIND_REGEXP | SCFIND_CXX11REGEX : 0);
	if (replace)
		[self replaceAll:replacement.stringValue];
	else
		[self findNext:nil];
}

- (sptr_t)searchFrom:(sptr_t)start to:(sptr_t)end
{
	[_editor message:SCI_SETSEARCHFLAGS wParam:_searchFlags];
	[_editor message:SCI_SETTARGETRANGE wParam:start lParam:end];
	return [_editor message:SCI_SEARCHINTARGET wParam:[_query lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
		lParam:reinterpret_cast<sptr_t>(_query.UTF8String)];
}

- (IBAction)findNext:(id)sender
{
	if (!_query.length)
	{
		[self showSearch:NO];
		return;
	}
	auto end = [_editor message:SCI_GETLENGTH];
	auto start = [_editor message:SCI_GETSELECTIONEND];
	BOOL skipEmpty = start == _lastEmptyMatch && [_editor message:SCI_GETSELECTIONEMPTY];
	auto next = skipEmpty && start < end ? [_editor message:SCI_POSITIONAFTER wParam:start] : start;
	auto result = skipEmpty && start == end ? -1 : [self searchFrom:next to:end];
	if (result < 0 && start > 0)
		result = [self searchFrom:0 to:start];
	if (result < 0)
	{
		NSBeep();
		return;
	}
	auto matchEnd = [_editor message:SCI_GETTARGETEND];
	_lastEmptyMatch = matchEnd == result ? result : -1;
	[_editor message:SCI_SETSEL wParam:result lParam:matchEnd];
	[_editor message:SCI_SCROLLCARET];
}

- (void)replaceAll:(NSString *)replacement
{
	[_editor message:SCI_BEGINUNDOACTION];
	const auto length = [replacement lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	const auto *bytes = replacement.UTF8String;
	sptr_t position = 0;
	while (position <= [_editor message:SCI_GETLENGTH])
	{
		auto start = [self searchFrom:position to:[_editor message:SCI_GETLENGTH]];
		if (start < 0)
			break;
		BOOL emptyMatch = start == [_editor message:SCI_GETTARGETEND];
		auto replaced = [_editor message:_searchFlags & SCFIND_REGEXP ? SCI_REPLACETARGETRE : SCI_REPLACETARGET
			wParam:length lParam:reinterpret_cast<sptr_t>(bytes)];
		if (replaced < 0)
			break;
		position = start + replaced;
		if (emptyMatch)
		{
			if (position >= [_editor message:SCI_GETLENGTH])
				break;
			position = [_editor message:SCI_POSITIONAFTER wParam:position];
		}
	}
	[_editor message:SCI_ENDUNDOACTION];
}
@end

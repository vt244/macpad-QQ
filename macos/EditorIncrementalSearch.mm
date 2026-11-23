// SPDX-License-Identifier: GPL-3.0-only
#import "EditorIncrementalSearch.h"
#import "EditorFileSearch.h"
#import "EditorPanelChrome.h"
#import "EditorResources.h"
#import "ScintillaView.h"

@interface EditorIncrementalSearch () <NSSearchFieldDelegate>
@end

static constexpr int IncrementalMark = 9;

@implementation EditorIncrementalSearch
{
	NSSearchField *_search;
	NSButton *_matchCase;
	NSButton *_highlight;
	NSButton *_previous;
	NSButton *_next;
	EditorCrossButton *_close;
	NSTextField *_status;
	__weak ScintillaView *_editor;
	NSInteger _origin;
	void (^_dismiss)(void);
}

- (instancetype)initWithDismiss:(void (^)(void))dismiss
{
	if (!(self = [super initWithFrame:NSZeroRect]))
		return nil;
	_dismiss = [dismiss copy];
	self.translatesAutoresizingMaskIntoConstraints = NO;
	_search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
	_search.controlSize = NSControlSizeSmall;
	_search.accessibilityIdentifier = @"incremental-search";
	_search.delegate = self;
	[_search.widthAnchor constraintEqualToConstant:200].active = YES;
	_previous = [NSButton buttonWithTitle:@"" target:self action:@selector(step:)];
	_next = [NSButton buttonWithTitle:@"" target:self action:@selector(step:)];
	_previous.tag = -1;
	_next.tag = 1;
	_previous.controlSize = _next.controlSize = NSControlSizeSmall;
	_matchCase = [NSButton checkboxWithTitle:@"" target:self action:@selector(queryChanged:)];
	_highlight = [NSButton checkboxWithTitle:@"" target:self action:@selector(queryChanged:)];
	_status = [NSTextField labelWithString:@""];
	_status.font = [NSFont systemFontOfSize:11];
	_close = [[EditorCrossButton alloc] initWithFrame:NSZeroRect];
	_close.translatesAutoresizingMaskIntoConstraints = NO;
	_close.bordered = NO;
	_close.target = self;
	_close.action = @selector(close:);
	[_close.widthAnchor constraintEqualToConstant:16].active = YES;
	[_close.heightAnchor constraintEqualToConstant:16].active = YES;
	[self refreshLocalization];
	NSStackView *row = [NSStackView stackViewWithViews:@[_close, _search, _previous, _next, _matchCase, _highlight, _status]];
	row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	row.alignment = NSLayoutAttributeCenterY;
	row.spacing = 5;
	row.translatesAutoresizingMaskIntoConstraints = NO;
	[self addSubview:row];
	[NSLayoutConstraint activateConstraints:@[
		[row.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
		[row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
		[row.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-4],
	]];
	return self;
}

- (void)refreshLocalization
{
	EditorResources *resources = EditorResources.shared;
	NSString *title = [resources label:@"43011" fallback:@"Incremental Search"];
	_search.placeholderString = title;
	[_search setAccessibilityLabel:title];
	[_close setAccessibilityLabel:[NSString stringWithFormat:[resources label:@"panel-close" fallback:@"Close %@"], title]];
	_previous.title = [resources label:@"43010" fallback:@"Previous"];
	_next.title = [resources label:@"43002" fallback:@"Next"];
	_matchCase.title = [resources label:@"IncrementalFind:1685" fallback:@"Match case"];
	_highlight.title = [resources label:@"IncrementalFind:1690" fallback:@"Highlight all"];
	if (_status.stringValue.length)
		_status.stringValue = [resources label:@"IncrementalFind-FSNotFound" fallback:@"No matches found"];
}

- (void)beginInEditor:(ScintillaView *)editor
{
	if (_editor != editor)
		[self end];
	_editor = editor;
	_origin = [editor message:SCI_GETSELECTIONSTART];
	[editor message:SCI_INDICSETSTYLE wParam:IncrementalMark lParam:INDIC_ROUNDBOX];
	[editor message:SCI_INDICSETFORE wParam:IncrementalMark lParam:0x3366AA];
	[editor message:SCI_INDICSETALPHA wParam:IncrementalMark lParam:55];
	_search.stringValue = editor.selectedString ?: @"";
	[_search.window makeFirstResponder:_search];
	[_search selectText:nil];
	[self queryChanged:nil];
}

- (void)clearHighlights
{
	[_editor message:SCI_SETINDICATORCURRENT wParam:IncrementalMark];
	[_editor message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[_editor message:SCI_GETLENGTH]];
}

- (void)end
{
	[self clearHighlights];
	_editor = nil;
	_status.stringValue = @"";
}

- (NSInteger)findFrom:(NSInteger)start to:(NSInteger)end
{
	[_editor message:SCI_SETTARGETRANGE wParam:start lParam:end];
	return SearchEditorTarget(_editor, _search.stringValue,
		_matchCase.state == NSControlStateValueOn ? SCFIND_MATCHCASE : 0);
}

- (void)findFrom:(NSInteger)start forward:(BOOL)forward
{
	NSString *query = _search.stringValue;
	NSInteger length = [_editor message:SCI_GETLENGTH];
	start = MIN(start, length);
	if (!query.length)
	{
		[_editor message:SCI_SETSEL wParam:start lParam:start];
		_status.stringValue = @"";
		return;
	}
	NSInteger match = [self findFrom:start to:forward ? length : 0];
	if (match < 0)
		match = [self findFrom:forward ? 0 : length to:start];
	if (match >= 0)
	{
		[_editor message:SCI_SETSEL wParam:match lParam:[_editor message:SCI_GETTARGETEND]];
		[_editor message:SCI_SCROLLCARET];
		_status.stringValue = @"";
	}
	else
		_status.stringValue = [EditorResources.shared label:@"IncrementalFind-FSNotFound" fallback:@"No matches found"];
}

- (void)queryChanged:(id)sender
{
	[self findFrom:_origin forward:YES];
	[self clearHighlights];
	if (_highlight.state != NSControlStateValueOn || !_search.stringValue.length)
		return;
	const NSInteger length = [_editor message:SCI_GETLENGTH];
	for (NSInteger start = 0; start < length;)
	{
		NSInteger match = [self findFrom:start to:length];
		if (match < 0)
			break;
		start = [_editor message:SCI_GETTARGETEND];
		[_editor message:SCI_INDICATORFILLRANGE wParam:match lParam:start - match];
		if (start == match)
			break;
	}
}

- (void)controlTextDidChange:(NSNotification *)notification { [self queryChanged:nil]; }

- (void)step:(NSButton *)button
{
	BOOL forward = button.tag > 0;
	[self findFrom:[_editor message:forward ? SCI_GETSELECTIONEND : SCI_GETSELECTIONSTART] forward:forward];
}

- (void)close:(id)sender { _dismiss(); }

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
	if (command == @selector(cancelOperation:))
	{
		_dismiss();
		return YES;
	}
	if (command == @selector(insertNewline:))
	{
		[self findFrom:[_editor message:SCI_GETSELECTIONEND] forward:YES];
		return YES;
	}
	return NO;
}
@end

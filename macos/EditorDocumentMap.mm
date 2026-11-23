// SPDX-License-Identifier: GPL-3.0-only
#import "EditorDocumentMap.h"
#import "EditorPanelChrome.h"
#import "EditorResources.h"
#import "ScintillaView.h"

@interface MapViewport : NSView
@property(nonatomic) NSRect visibleRange;
@property(nonatomic, copy) void (^navigate)(CGFloat);
@end

@implementation MapViewport
- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirty
{
	EditorResources *resources = EditorResources.shared;
	NSColor *border = [resources widgetColor:@"Document map" background:NO] ?: NSColor.controlAccentColor;
	NSColor *fill = [resources widgetColor:@"Document map" background:YES] ?: border;
	[[fill colorWithAlphaComponent:0.30] setFill];
	NSRectFillUsingOperation(_visibleRange, NSCompositingOperationSourceOver);
	[[border colorWithAlphaComponent:0.75] setStroke];
	[NSBezierPath strokeRect:_visibleRange];
}

- (void)mouseDown:(NSEvent *)event { [self mouseDragged:event]; }
- (void)mouseDragged:(NSEvent *)event
{
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	self.navigate(point.y);
}
@end

@implementation EditorDocumentMap
{
	ScintillaView *_map;
	MapViewport *_viewport;
	__weak ScintillaView *_source;
	void (^_dismiss)(void);
}

- (void)refreshDockLabels:(NSString *)title
{
	[_viewport setAccessibilityLabel:EditorUIString(@"Document map preview")];
}

- (instancetype)initWithDismiss:(void (^)(void))dismiss
{
	if (!(self = [super initWithFrame:NSZeroRect]))
		return nil;
	_dismiss = [dismiss copy];
	NSView *caption = EditorPanelCaption([EditorResources.shared label:@"DocumentMap:PanelTitle" fallback:@"Document Map"],
		self, @selector(dismiss:));
	_map = [[ScintillaView alloc] initWithFrame:NSZeroRect];
	_map.translatesAutoresizingMaskIntoConstraints = NO;
	[_map message:SCI_SETVSCROLLBAR wParam:0];
	[_map message:SCI_SETHSCROLLBAR wParam:0];
	[_map message:SCI_SETCARETSTYLE wParam:CARETSTYLE_INVISIBLE];
	[_map message:SCI_SETCARETLINEVISIBLE wParam:0];
	[_map message:SCI_SETWRAPMODE wParam:SC_WRAP_NONE];
	[_map message:SCI_SETENDATLASTLINE wParam:0];
	for (int margin = 0; margin < 5; ++margin)
		[_map message:SCI_SETMARGINWIDTHN wParam:margin lParam:0];
	_viewport = [[MapViewport alloc] initWithFrame:NSZeroRect];
	_viewport.translatesAutoresizingMaskIntoConstraints = NO;
	[_map setAccessibilityElement:NO];
	_map.accessibilityChildren = @[];
	[_viewport setAccessibilityElement:YES];
	[_viewport setAccessibilityRole:NSAccessibilityImageRole];
	[self refreshDockLabels:nil];
	__weak EditorDocumentMap *weakSelf = self;
	_viewport.navigate = ^(CGFloat y) { [weakSelf navigateToY:y]; };
	[self addSubview:caption];
	[self addSubview:_map];
	[self addSubview:_viewport];
	[NSLayoutConstraint activateConstraints:@[
		[caption.topAnchor constraintEqualToAnchor:self.topAnchor],
		[caption.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[caption.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[_map.topAnchor constraintEqualToAnchor:caption.bottomAnchor],
		[_map.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[_map.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[_map.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
		[_viewport.topAnchor constraintEqualToAnchor:_map.topAnchor],
		[_viewport.leadingAnchor constraintEqualToAnchor:_map.leadingAnchor],
		[_viewport.trailingAnchor constraintEqualToAnchor:_map.trailingAnchor],
		[_viewport.bottomAnchor constraintEqualToAnchor:_map.bottomAnchor],
	]];
	return self;
}

- (void)dismiss:(id)sender { _dismiss(); }

- (void)showEditor:(ScintillaView *)editor
{
	const auto pointer = [editor message:SCI_GETDOCPOINTER];
	if (_source != editor || (editor && [_map message:SCI_GETDOCPOINTER] != pointer))
	{
		_source = editor;
		[_map message:SCI_SETDOCPOINTER wParam:0 lParam:pointer];
		[self refreshStyle];
	}
	[self updateViewport];
}

- (void)refreshStyle
{
	if (!_source)
		return;
	for (int style = 0; style <= STYLE_MAX; ++style)
	{
		[_map message:SCI_STYLESETFORE wParam:style lParam:[_source message:SCI_STYLEGETFORE wParam:style]];
		[_map message:SCI_STYLESETBACK wParam:style lParam:[_source message:SCI_STYLEGETBACK wParam:style]];
		[_map message:SCI_STYLESETSIZE wParam:style lParam:3];
	}
	[_map setStringProperty:SCI_STYLESETFONT parameter:STYLE_DEFAULT value:@"Menlo"];
}

- (void)layout
{
	[super layout];
	[self updateViewport];
}

- (void)updateViewport
{
	ScintillaView *source = _source;
	if (!source)
	{
		_viewport.visibleRange = NSZeroRect;
		_viewport.needsDisplay = YES;
		return;
	}
	const auto line = [source message:SCI_GETFIRSTVISIBLELINE];
	const auto lastLine = [source message:SCI_GETLINECOUNT] - 1;
	const auto first = MIN(lastLine, [source message:SCI_DOCLINEFROMVISIBLE wParam:line]);
	const auto end = MIN(lastLine, [source message:SCI_DOCLINEFROMVISIBLE wParam:line + MAX(1, [source message:SCI_LINESONSCREEN])]);
	const auto page = MAX(1, [_map message:SCI_LINESONSCREEN]);
	const auto start = MAX(0, MIN(first - page / 3, lastLine + 1 - page));
	[_map message:SCI_SETFIRSTVISIBLELINE wParam:start];
	const auto actual = [_map message:SCI_GETFIRSTVISIBLELINE];
	const auto height = MAX(1, [_map message:SCI_TEXTHEIGHT]);
	_viewport.visibleRange = NSMakeRect(0, (first - actual) * height, NSWidth(_viewport.bounds), MAX(1, end - first + 1) * height);
	_viewport.needsDisplay = YES;
}

- (void)navigateToY:(CGFloat)y
{
	ScintillaView *source = _source;
	if (!source)
		return;
	const auto line = [_map message:SCI_GETFIRSTVISIBLELINE] + static_cast<NSInteger>(MAX(0, y) / MAX(1, [_map message:SCI_TEXTHEIGHT]));
	const auto visible = [source message:SCI_VISIBLEFROMDOCLINE wParam:MIN(line, [source message:SCI_GETLINECOUNT] - 1)];
	[source message:SCI_SETFIRSTVISIBLELINE wParam:MAX(0, visible - [source message:SCI_LINESONSCREEN] / 2)];
	[self updateViewport];
}
@end

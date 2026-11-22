// SPDX-License-Identifier: GPL-3.0-only
#import "EditorPanelChrome.h"
#import "EditorDock.h"
#import "EditorResources.h"

@implementation EditorCrossButton
{
	NSTrackingArea *_tracking;
	BOOL _hovered;
}

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if (_tracking)
		[self removeTrackingArea:_tracking];
	_tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:
		NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect | NSTrackingActiveInKeyWindow
		owner:self userInfo:nil];
	[self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event
{
	_hovered = YES;
	self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent *)event
{
	_hovered = NO;
	self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirty
{
	NSRect bounds = self.bounds;
	if (_hovered)
	{
		[[NSColor colorWithSRGBRed:0.79 green:0.18 blue:0.16 alpha:1] setFill];
		NSRectFill(NSInsetRect(bounds, 1, 1));
	}
	NSColor *color = _hovered ? NSColor.whiteColor : self.contentTintColor ?: NSColor.labelColor;
	[color setStroke];
	const CGFloat x = NSMidX(bounds);
	const CGFloat y = NSMidY(bounds);
	NSBezierPath *cross = [NSBezierPath bezierPath];
	[cross moveToPoint:NSMakePoint(x - 3.3, y - 3.3)];
	[cross lineToPoint:NSMakePoint(x + 3.3, y + 3.3)];
	[cross moveToPoint:NSMakePoint(x - 3.3, y + 3.3)];
	[cross lineToPoint:NSMakePoint(x + 3.3, y - 3.3)];
	cross.lineWidth = 1.3;
	[cross stroke];
}
@end

@interface EditorDockCaption : NSView
@end

@implementation EditorDockCaption
{
	NSPoint _dragStart;
	BOOL _dragged;
}

- (EditorDockPane *)dockPane
{
	for (NSView *view = self.superview; view; view = view.superview)
		if ([view isKindOfClass:EditorDockPane.class])
			return (EditorDockPane *)view;
	return nil;
}

- (NSView *)hitTest:(NSPoint)point
{
	NSView *hit = [super hitTest:point];
	return [hit isKindOfClass:NSTextField.class] ? self : hit;
}

- (NSMenu *)menuForEvent:(NSEvent *)event { return [self.dockPane placementMenu]; }

- (void)mouseDown:(NSEvent *)event
{
	_dragStart = event.locationInWindow;
	_dragged = NO;
}

- (void)mouseDragged:(NSEvent *)event
{
	NSPoint point = event.locationInWindow;
	_dragged |= hypot(point.x - _dragStart.x, point.y - _dragStart.y) > 5;
}

- (void)mouseUp:(NSEvent *)event
{
	if (_dragged)
		[self.dockPane dropAtScreenPoint:[self.window convertPointToScreen:event.locationInWindow]];
	else if (event.clickCount == 2)
		[self.dockPane toggleFloating];
	_dragged = NO;
}

- (void)drawRect:(NSRect)dirty
{
	BOOL dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
		isEqualToString:NSAppearanceNameDarkAqua];
	[[NSColor colorWithWhite:dark ? 0.17 : 0.91 alpha:1] setFill];
	NSRectFill(self.bounds);
	[[NSColor colorWithWhite:dark ? 0.34 : 0.68 alpha:1] setFill];
	NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), 1));
	NSRectFill(NSMakeRect(0, NSHeight(self.bounds) - 1, NSWidth(self.bounds), 1));
}
@end

NSView *EditorPanelCaption(NSString *title, id target, SEL closeAction)
{
	EditorDockCaption *caption = [[EditorDockCaption alloc] initWithFrame:NSZeroRect];
	caption.translatesAutoresizingMaskIntoConstraints = NO;
	NSTextField *label = [NSTextField labelWithString:title];
	label.translatesAutoresizingMaskIntoConstraints = NO;
	label.font = [NSFont systemFontOfSize:11];
	label.lineBreakMode = NSLineBreakByTruncatingTail;
	EditorCrossButton *close = [[EditorCrossButton alloc] initWithFrame:NSZeroRect];
	close.translatesAutoresizingMaskIntoConstraints = NO;
	close.bordered = NO;
	close.target = target;
	close.action = closeAction;
	[close setAccessibilityLabel:[NSString stringWithFormat:[EditorResources.shared label:@"panel-close" fallback:@"Close %@"], title]];
	[caption addSubview:label];
	[caption addSubview:close];
	[NSLayoutConstraint activateConstraints:@[
		[caption.heightAnchor constraintEqualToConstant:20],
		[label.leadingAnchor constraintEqualToAnchor:caption.leadingAnchor constant:5],
		[label.centerYAnchor constraintEqualToAnchor:caption.centerYAnchor],
		[label.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-4],
		[close.trailingAnchor constraintEqualToAnchor:caption.trailingAnchor constant:-2],
		[close.centerYAnchor constraintEqualToAnchor:caption.centerYAnchor],
		[close.widthAnchor constraintEqualToConstant:16],
		[close.heightAnchor constraintEqualToConstant:16],
	]];
	return caption;
}

NSImage *EditorTabStateIcon(BOOL edited, BOOL readOnly, BOOL monitoring, BOOL dark)
{
	NSString *name = monitoring ? @"monitoring" : readOnly ? @"readonly" : edited ? @"unsaved" : @"saved";
	NSURL *url = dark ? [NSBundle.mainBundle URLForResource:name withExtension:@"ico" subdirectory:@"tabbar/dark"] : nil;
	url = url ?: [NSBundle.mainBundle URLForResource:name withExtension:@"ico" subdirectory:@"tabbar"];
	NSImage *image = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
	image.size = NSMakeSize(14, 14);
	return image;
}

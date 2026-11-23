// SPDX-License-Identifier: GPL-3.0-only
#import "EditorDock.h"
#import "EditorResources.h"
#import "EditorPanelChrome.h"

static BOOL IsSide(EditorDockEdge edge) { return edge == EditorDockLeft || edge == EditorDockRight; }

@interface EditorDockPlacement ()
@property(nonatomic) EditorDockEdge edge;
@property(nonatomic) EditorDockEdge lastDock;
@property(nonatomic) CGFloat width;
@property(nonatomic) CGFloat height;
@property(nonatomic) NSRect floatingFrame;
@property(nonatomic) NSTimeInterval selectedAt;
@property(nonatomic) NSInteger order;
@property(nonatomic, copy) NSString *floatingGroup;
@end

@implementation EditorDockPlacement
- (instancetype)initWithEdge:(EditorDockEdge)edge
{
	if ((self = [super init]))
	{
		_edge = _lastDock = edge;
		_width = 200;
		_height = 185;
	}
	return self;
}

- (NSDictionary *)snapshot
{
	return @{@"edge": @(_edge), @"lastDock": @(_lastDock), @"width": @(_width), @"height": @(_height),
		@"floatingFrame": NSStringFromRect(_floatingFrame), @"selectedAt": @(_selectedAt),
		@"order": @(_order), @"floatingGroup": _floatingGroup ?: @""};
}

- (void)restore:(NSDictionary *)snapshot
{
	if (![snapshot isKindOfClass:NSDictionary.class])
		return;
	NSNumber *edge = snapshot[@"edge"];
	NSNumber *lastDock = snapshot[@"lastDock"];
	if ([edge isKindOfClass:NSNumber.class] && edge.integerValue >= EditorDockLeft && edge.integerValue <= EditorDockFloating)
		_edge = (EditorDockEdge)edge.integerValue;
	if ([lastDock isKindOfClass:NSNumber.class] && lastDock.integerValue >= EditorDockLeft && lastDock.integerValue <= EditorDockBottom)
		_lastDock = (EditorDockEdge)lastDock.integerValue;
	NSNumber *width = snapshot[@"width"];
	NSNumber *height = snapshot[@"height"];
	if ([width isKindOfClass:NSNumber.class] && isfinite(width.doubleValue))
		_width = MAX(96, width.doubleValue);
	if ([height isKindOfClass:NSNumber.class] && isfinite(height.doubleValue))
		_height = MAX(56, height.doubleValue);
	NSString *frame = snapshot[@"floatingFrame"];
	if ([frame isKindOfClass:NSString.class])
		_floatingFrame = NSRectFromString(frame);
	if ([snapshot[@"selectedAt"] isKindOfClass:NSNumber.class])
		_selectedAt = [snapshot[@"selectedAt"] doubleValue];
	if ([snapshot[@"order"] isKindOfClass:NSNumber.class])
		_order = [snapshot[@"order"] integerValue];
	if ([snapshot[@"floatingGroup"] isKindOfClass:NSString.class])
		_floatingGroup = [snapshot[@"floatingGroup"] copy];
}
@end

@interface EditorDockGrip : NSView
@property(nonatomic) BOOL side;
@property(nonatomic, copy) void (^resize)(CGFloat);
@end

@implementation EditorDockGrip
{
	NSPoint _previous;
}
- (void)setSide:(BOOL)side
{
	_side = side;
	[self.window invalidateCursorRectsForView:self];
}
- (void)resetCursorRects
{
	[self addCursorRect:self.bounds cursor:_side ? NSCursor.resizeLeftRightCursor : NSCursor.resizeUpDownCursor];
}
- (void)drawRect:(NSRect)dirty
{
	[NSColor.separatorColor setFill];
	NSRectFill(_side ? NSMakeRect(2, 0, 1, NSHeight(self.bounds)) : NSMakeRect(0, 2, NSWidth(self.bounds), 1));
}
- (void)mouseDown:(NSEvent *)event { _previous = event.locationInWindow; }
- (void)mouseDragged:(NSEvent *)event
{
	NSPoint point = event.locationInWindow;
	self.resize(_side ? point.x - _previous.x : point.y - _previous.y);
	_previous = point;
}
@end

@class EditorDockPane;
@interface EditorDockArea ()
- (NSArray<EditorDockPane *> *)panesAtEdge:(EditorDockEdge)edge;
- (void)toggleGroupFromPane:(EditorDockPane *)pane;
@end

@interface EditorDockPane () <NSWindowDelegate>
@property(nonatomic, weak) EditorDockArea *area;
@property(nonatomic, strong) EditorDockPlacement *placement;
@property(nonatomic, copy) void (^dismiss)(void);
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *titleKey;
@property(nonatomic, copy) NSString *titleFallback;
@property(nonatomic, strong) NSView *panel;
@property(nonatomic, strong) EditorDockGrip *grip;
- (void)updatePresentation;
- (void)placeAtEdge:(EditorDockEdge)edge;
- (void)refreshLocalization;
@end

@implementation EditorDockPane
{
	NSPanel *_floating;
	BOOL _shown;
}

- (void)dealloc
{
	_floating.delegate = nil;
	[_floating close];
}

- (BOOL)isShown { return _shown; }
- (void)refreshLocalization
{
	self.title = [EditorResources.shared label:self.titleKey fallback:self.titleFallback];
	_floating.title = self.title;
	EditorSetPanelCaption(self.panel, self.title);
	if ([self.panel respondsToSelector:@selector(refreshDockLabels:)])
		[(id<EditorDockLabels>)self.panel refreshDockLabels:self.title];
}

- (void)setShown:(BOOL)shown
{
	if (_shown == shown)
		return;
	_shown = shown;
	if (shown && !_placement.selectedAt)
		_placement.selectedAt = NSDate.timeIntervalSinceReferenceDate;
	[self updatePresentation];
	[self.area setNeedsLayout:YES];
}

- (void)updatePresentation
{
	if (_placement.edge == EditorDockFloating && _placement.floatingGroup.length)
	{
		self.grip.hidden = YES;
		self.hidden = !_shown;
		return;
	}
	NSWindow *parent = self.area.window;
	const BOOL floats = _shown && parent && _placement.edge == EditorDockFloating;
	self.grip.hidden = floats;
	if (floats)
	{
		if (!_floating)
		{
			_floating = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 390, 220)
				styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
					NSWindowStyleMaskUtilityWindow backing:NSBackingStoreBuffered defer:NO];
			_floating.title = self.title;
			_floating.releasedWhenClosed = NO;
			_floating.delegate = self;
			_floating.contentMinSize = NSMakeSize(150, 85);
		}
		if (_floating.contentView != self)
		{
			[self removeFromSuperview];
			_floating.contentView = self;
			NSRect screen = (parent.screen ?: NSScreen.mainScreen).visibleFrame;
			NSRect frame = _placement.floatingFrame;
			if (NSIsEmptyRect(frame))
				frame = NSOffsetRect(_floating.frame, NSMidX(parent.frame) - 195, NSMidY(parent.frame) - 110);
			if (!NSIsEmptyRect(screen))
			{
				frame.size.width = MIN(frame.size.width, NSWidth(screen));
				frame.size.height = MIN(frame.size.height, NSHeight(screen));
				frame.origin.x = MAX(NSMinX(screen), MIN(frame.origin.x, NSMaxX(screen) - NSWidth(frame)));
				frame.origin.y = MAX(NSMinY(screen), MIN(frame.origin.y, NSMaxY(screen) - NSHeight(frame)));
			}
			[_floating setFrame:frame display:NO];
			[parent addChildWindow:_floating ordered:NSWindowAbove];
		}
		_floating.appearance = parent.appearance;
		if (parent.visible)
			[_floating orderFront:nil];
	}
	else
	{
		if (_floating.contentView == self)
		{
			_placement.floatingFrame = _floating.frame;
			[_floating.parentWindow removeChildWindow:_floating];
			[_floating orderOut:nil];
			_floating.contentView = nil;
		}
		if (self.superview != self.area)
			[self.area addSubview:self];
	}
	self.hidden = !_shown;
	[self setNeedsLayout:YES];
}

- (void)layout
{
	[super layout];
	NSRect body = self.bounds;
	NSRect grip = NSZeroRect;
	switch (_placement.edge)
	{
		case EditorDockLeft: NSDivideRect(body, &grip, &body, 5, NSMaxXEdge); break;
		case EditorDockRight: NSDivideRect(body, &grip, &body, 5, NSMinXEdge); break;
		case EditorDockTop: NSDivideRect(body, &grip, &body, 5, NSMinYEdge); break;
		case EditorDockBottom: NSDivideRect(body, &grip, &body, 5, NSMaxYEdge); break;
		case EditorDockFloating: break;
	}
	self.panel.frame = body;
	self.grip.frame = grip;
	self.grip.side = IsSide(_placement.edge);
	self.grip.needsDisplay = YES;
}

- (void)placeAtEdge:(EditorDockEdge)edge
{
	if (edge != EditorDockFloating)
	{
		_placement.lastDock = edge;
		_placement.selectedAt = NSDate.timeIntervalSinceReferenceDate;
	}
	_placement.edge = edge;
	_placement.floatingGroup = nil;
	[self updatePresentation];
	[self.area setNeedsLayout:YES];
	if (self.area.placementChanged)
		self.area.placementChanged();
}

- (void)toggleFloating
{
	[self.area toggleGroupFromPane:self];
}

- (void)chooseEdge:(NSMenuItem *)item { [self placeAtEdge:(EditorDockEdge)item.tag]; }

- (NSMenu *)placementMenu
{
	NSMenu *menu = [[NSMenu alloc] initWithTitle:self.title];
	NSArray<NSString *> *labels = @[@"Dock Left", @"Dock Right", @"Dock Top", @"Dock Bottom", @"Float Panel"];
	for (NSInteger index = 0; index < labels.count; ++index)
	{
		NSString *label = [EditorResources.shared label:[NSString stringWithFormat:@"dock-edge-%ld", index] fallback:labels[index]];
		NSMenuItem *item = [menu addItemWithTitle:label action:@selector(chooseEdge:) keyEquivalent:@""];
		item.target = self;
		item.tag = index;
		item.state = index == _placement.edge ? NSControlStateValueOn : NSControlStateValueOff;
	}
	if (_placement.edge == EditorDockFloating)
	{
		NSMenuItem *item = [menu addItemWithTitle:[EditorResources.shared label:@"dock-redock" fallback:@"Dock Panel"]
			action:@selector(chooseEdge:) keyEquivalent:@""];
		item.target = self;
		item.tag = _placement.lastDock;
	}
	return menu;
}

- (void)dropAtScreenPoint:(NSPoint)point
{
	NSWindow *window = self.area.window;
	if (!window)
		return;
	NSPoint local = [self.area convertPoint:[window convertPointFromScreen:point] fromView:nil];
	NSRect bounds = self.area.bounds;
	if (NSPointInRect(local, NSInsetRect(bounds, -20, -20)))
	{
		const CGFloat distances[] = {fabs(local.x), fabs(NSMaxX(bounds) - local.x), fabs(NSMaxY(bounds) - local.y), fabs(local.y)};
		NSInteger edge = EditorDockLeft;
		for (NSInteger next = EditorDockRight; next <= EditorDockBottom; ++next)
			if (distances[next] < distances[edge])
				edge = next;
		if (distances[edge] <= 50)
			return [self placeAtEdge:(EditorDockEdge)edge];
		if (_placement.edge != EditorDockFloating)
			return;
	}
	NSRect frame = _floating ? _floating.frame : NSMakeRect(0, 0, 390, 245);
	frame.origin = NSMakePoint(point.x - 45, point.y - NSHeight(frame) + 36);
	_placement.floatingFrame = frame;
	if (_floating.contentView == self)
		[_floating setFrame:frame display:YES];
	[self placeAtEdge:EditorDockFloating];
}

- (BOOL)windowShouldClose:(NSWindow *)window
{
	self.dismiss();
	return NO;
}

- (void)windowDidMove:(NSNotification *)notification { [self storeFloatingFrame]; }
- (void)windowDidResize:(NSNotification *)notification { [self storeFloatingFrame]; }
- (void)storeFloatingFrame
{
	if (_placement.edge == EditorDockFloating && _shown)
	{
		_placement.floatingFrame = _floating.frame;
		if (self.area.placementChanged)
			self.area.placementChanged();
	}
}
@end

@interface DockTabs : NSSegmentedControl
@property(nonatomic, copy) void (^dragTab)(NSInteger, NSInteger);
@property(nonatomic, copy) void (^detachTab)(NSInteger);
@end

@implementation DockTabs
- (NSInteger)segmentAtPoint:(NSPoint)point
{
	if (!self.segmentCount || NSWidth(self.bounds) <= 0)
		return -1;
	return MAX(0, MIN(self.segmentCount - 1, (NSInteger)(point.x * self.segmentCount / NSWidth(self.bounds))));
}

- (void)mouseDown:(NSEvent *)event
{
	NSPoint initial = [self convertPoint:event.locationInWindow fromView:nil];
	NSInteger index = [self segmentAtPoint:initial];
	if (index < 0)
		return;
	if (event.clickCount == 2)
	{
		if (self.detachTab)
			self.detachTab(index);
		return;
	}
	NSEvent *next;
	BOOL dragged = NO;
	do
	{
		next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
		NSPoint point = [self convertPoint:next.locationInWindow fromView:nil];
		dragged |= hypot(point.x - initial.x, point.y - initial.y) > 5;
		if (next.type == NSEventTypeLeftMouseUp)
		{
			NSInteger target = [self segmentAtPoint:point];
			if (dragged && self.dragTab)
				self.dragTab(index, target);
			else if (NSPointInRect(point, self.bounds))
			{
				self.selectedSegment = index;
				[NSApp sendAction:self.action to:self.target from:self];
			}
			break;
		}
	} while (next);
}
@end

@interface DockGroupWindow : NSPanel
@property(nonatomic, strong) DockTabs *tabs;
@property(nonatomic, copy) NSArray<EditorDockPane *> *panes;
@end
@implementation DockGroupWindow
@end

@interface EditorDockArea () <NSWindowDelegate>
@end

@implementation EditorDockArea
{
	NSView *_editor;
	NSMutableArray<EditorDockPane *> *_panes;
	NSArray<DockTabs *> *_switchers;
	NSMutableDictionary<NSString *, DockGroupWindow *> *_floatingGroups;
}

- (instancetype)initWithEditor:(NSView *)editor
{
	if ((self = [super initWithFrame:NSZeroRect]))
	{
		_panes = [NSMutableArray array];
		_floatingGroups = [NSMutableDictionary dictionary];
		_editor = editor;
		[self addSubview:editor];
		NSMutableArray<DockTabs *> *switchers = [NSMutableArray array];
		__weak EditorDockArea *weakSelf = self;
		for (NSInteger edge = EditorDockLeft; edge <= EditorDockBottom; ++edge)
		{
			DockTabs *control = [[DockTabs alloc] initWithFrame:NSZeroRect];
			control.trackingMode = NSSegmentSwitchTrackingSelectOne;
			control.target = self;
			control.action = @selector(switchPanel:);
			const auto dock = static_cast<EditorDockEdge>(edge);
			control.dragTab = ^(NSInteger from, NSInteger to) { [weakSelf reorderGroup:[weakSelf panesAtEdge:dock] from:from to:to]; };
			control.detachTab = ^(NSInteger index) { [weakSelf detachTab:index from:[weakSelf panesAtEdge:dock]]; };
			control.segmentStyle = NSSegmentStyleSmallSquare;
			control.controlSize = NSControlSizeSmall;
			control.tag = edge;
			control.hidden = YES;
			[control setAccessibilityLabel:[EditorResources.shared label:@"dock-panelTabs" fallback:@"Docked panels"]];
			[switchers addObject:control];
			[self addSubview:control];
		}
		_switchers = [switchers copy];
	}
	return self;
}

- (EditorDockPane *)addPanel:(NSView *)panel titleKey:(NSString *)key fallback:(NSString *)fallback
	placement:(EditorDockPlacement *)placement dismiss:(void (^)(void))dismiss
{
	EditorDockPane *pane = [[EditorDockPane alloc] initWithFrame:NSZeroRect];
	pane.area = self;
	pane.placement = placement;
	pane.dismiss = dismiss;
	pane.titleKey = key;
	pane.titleFallback = fallback;
	pane.panel = panel;
	[pane refreshLocalization];
	panel.translatesAutoresizingMaskIntoConstraints = YES;
	pane.grip = [[EditorDockGrip alloc] initWithFrame:NSZeroRect];
	[pane addSubview:panel];
	[pane addSubview:pane.grip];
	__weak EditorDockPane *weakPane = pane;
	pane.grip.resize = ^(CGFloat delta) {
		EditorDockPane *panel = weakPane;
		EditorDockPlacement *position = panel.placement;
		const EditorDockEdge edge = position.edge;
		if (edge == EditorDockRight || edge == EditorDockTop)
			delta = -delta;
		NSArray<EditorDockPane *> *group = [panel.area panesAtEdge:edge];
		for (EditorDockPane *member in group)
			if (IsSide(edge))
				member.placement.width = MAX(96, NSWidth(panel.frame) + delta);
			else
				member.placement.height = MAX(56, NSHeight(panel.frame) + (group.count > 1 ? 22 : 0) + delta);
		panel.area.needsLayout = YES;
		[panel.area layoutSubtreeIfNeeded];
		if (panel.area.placementChanged)
			panel.area.placementChanged();
	};
	[_panes addObject:pane];
	[self addSubview:pane];
	pane.hidden = YES;
	return pane;
}

- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	[self refreshPanelPlacements];
}

- (void)refreshLocalization
{
	for (EditorDockPane *pane in _panes)
		[pane refreshLocalization];
	[self setNeedsLayout:YES];
}

- (void)refreshPanelPlacements
{
	for (EditorDockPane *pane in _panes)
		[pane updatePresentation];
	self.needsLayout = YES;
}

- (void)setFrameSize:(NSSize)size
{
	if (!NSEqualSizes(size, self.frame.size))
		self.needsLayout = YES;
	[super setFrameSize:size];
}

- (NSArray<EditorDockPane *> *)panesAtEdge:(EditorDockEdge)edge
{
	NSMutableArray<EditorDockPane *> *panes = [NSMutableArray array];
	for (EditorDockPane *pane in _panes)
		if (pane.isShown && pane.placement.edge == edge)
			[panes addObject:pane];
	return [panes sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(EditorDockPane *a, EditorDockPane *b) {
		return a.placement.order < b.placement.order ? NSOrderedAscending :
			a.placement.order > b.placement.order ? NSOrderedDescending : NSOrderedSame;
	}];
}

- (void)reorderGroup:(NSArray<EditorDockPane *> *)group from:(NSInteger)from to:(NSInteger)to
{
	if (from < 0 || to < 0 || from >= group.count || to >= group.count || from == to)
		return;
	NSMutableArray<EditorDockPane *> *order = [group mutableCopy];
	EditorDockPane *pane = order[from];
	[order removeObjectAtIndex:from];
	[order insertObject:pane atIndex:to];
	for (NSUInteger i = 0; i < order.count; ++i)
		order[i].placement.order = i + 1;
	[self changeGroupLayout];
}

- (void)detachTab:(NSInteger)index from:(NSArray<EditorDockPane *> *)group
{
	if (index >= 0 && index < group.count)
	{
		EditorDockPane *pane = group[index];
		[pane placeAtEdge:pane.placement.floatingGroup.length ? pane.placement.lastDock : EditorDockFloating];
		[self changeGroupLayout];
	}
}

- (void)changeGroupLayout
{
	self.needsLayout = YES;
	if (self.placementChanged)
		self.placementChanged();
}

- (void)toggleGroupFromPane:(EditorDockPane *)pane
{
	EditorDockPlacement *placement = pane.placement;
	if (placement.floatingGroup.length)
	{
		NSString *identifier = placement.floatingGroup;
		for (EditorDockPane *candidate in _panes)
			if ([candidate.placement.floatingGroup isEqualToString:identifier])
			{
				NSTimeInterval selection = candidate.placement.selectedAt;
				[candidate placeAtEdge:candidate.placement.lastDock];
				candidate.placement.selectedAt = selection;
			}
	}
	else if (placement.edge != EditorDockFloating)
	{
		NSArray *group = [self panesAtEdge:placement.edge];
		if (group.count <= 1)
			[pane placeAtEdge:EditorDockFloating];
		else
		{
			NSString *identifier = NSUUID.UUID.UUIDString;
			for (EditorDockPane *candidate in group)
			{
				candidate.placement.lastDock = placement.edge;
				candidate.placement.floatingGroup = identifier;
			}
			for (EditorDockPane *candidate in group)
			{
				candidate.placement.edge = EditorDockFloating;
				[candidate updatePresentation];
			}
		}
	}
	else
		[pane placeAtEdge:placement.lastDock];
	[self changeGroupLayout];
}

- (void)switchPanel:(NSSegmentedControl *)control
{
	NSArray<EditorDockPane *> *panes = [self panesAtEdge:static_cast<EditorDockEdge>(control.tag)];
	NSInteger selection = control.selectedSegment;
	if (selection < 0 || selection >= panes.count)
		return;
	panes[selection].placement.selectedAt = NSDate.timeIntervalSinceReferenceDate;
	self.needsLayout = YES;
	if (self.placementChanged)
		self.placementChanged();
}

static EditorDockPane *SelectedPanel(NSArray<EditorDockPane *> *group)
{
	EditorDockPane *selected = group.firstObject;
	for (EditorDockPane *candidate in group)
		if (candidate.placement.selectedAt > selected.placement.selectedAt)
			selected = candidate;
	return selected;
}

static void LayoutDockTabs(DockTabs *tabs, NSArray<EditorDockPane *> *group, EditorDockPane *selected, NSRect frame)
{
	tabs.segmentCount = group.count;
	for (NSUInteger i = 0; i < group.count; ++i)
	{
		[tabs setLabel:group[i].title forSegment:i];
		[tabs setWidth:MAX(1, NSWidth(frame) / group.count) forSegment:i];
	}
	tabs.selectedSegment = [group indexOfObjectIdenticalTo:selected];
	tabs.frame = frame;
}

- (void)switchFloatingTab:(DockTabs *)tabs
{
	DockGroupWindow *window = (DockGroupWindow *)tabs.window;
	if (tabs.selectedSegment >= 0 && tabs.selectedSegment < window.panes.count)
	{
		window.panes[tabs.selectedSegment].placement.selectedAt = NSDate.timeIntervalSinceReferenceDate;
		[self changeGroupLayout];
	}
}

- (BOOL)windowShouldClose:(DockGroupWindow *)window
{
	for (EditorDockPane *pane in window.panes)
		pane.dismiss();
	return NO;
}

- (void)windowDidResize:(NSNotification *)event { self.needsLayout = YES; }
- (void)windowDidMove:(NSNotification *)event
{
	DockGroupWindow *window = event.object;
	for (EditorDockPane *pane in window.panes)
		pane.placement.floatingFrame = window.frame;
	if (self.placementChanged)
		self.placementChanged();
}

- (void)layoutFloatingGroups
{
	NSMutableDictionary<NSString *, NSMutableArray<EditorDockPane *> *> *groups = [NSMutableDictionary dictionary];
	for (EditorDockPane *pane in _panes)
	{
		NSString *identifier = pane.placement.floatingGroup;
		if (pane.isShown && pane.placement.edge == EditorDockFloating && identifier.length)
		{
			if (!groups[identifier])
				groups[identifier] = [NSMutableArray array];
			[groups[identifier] addObject:pane];
		}
	}
	for (NSString *identifier in _floatingGroups.allKeys)
		if (!groups[identifier] || !self.window.visible)
		{
			DockGroupWindow *window = _floatingGroups[identifier];
			[window.parentWindow removeChildWindow:window];
			[window orderOut:nil];
			window.delegate = nil;
			[_floatingGroups removeObjectForKey:identifier];
		}
	if (!self.window.visible)
		return;
	for (NSString *identifier in groups)
	{
		NSArray<EditorDockPane *> *group = [groups[identifier] sortedArrayWithOptions:NSSortStable
			usingComparator:^NSComparisonResult(EditorDockPane *a, EditorDockPane *b) {
				return [@(a.placement.order) compare:@(b.placement.order)];
			}];
		EditorDockPane *selected = SelectedPanel(group);
		DockGroupWindow *window = _floatingGroups[identifier];
		if (!window)
		{
			window = [[DockGroupWindow alloc] initWithContentRect:NSMakeRect(0, 0, 390, 240)
				styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
					NSWindowStyleMaskUtilityWindow backing:NSBackingStoreBuffered defer:NO];
			window.releasedWhenClosed = NO;
			window.delegate = self;
			window.contentMinSize = NSMakeSize(150, 85);
			window.tabs = [[DockTabs alloc] initWithFrame:NSZeroRect];
			window.tabs.trackingMode = NSSegmentSwitchTrackingSelectOne;
			window.tabs.segmentStyle = NSSegmentStyleSmallSquare;
			window.tabs.target = self;
			window.tabs.action = @selector(switchFloatingTab:);
			__weak EditorDockArea *area = self;
			__weak DockGroupWindow *weakWindow = window;
			window.tabs.dragTab = ^(NSInteger from, NSInteger to) { [area reorderGroup:weakWindow.panes from:from to:to]; };
			window.tabs.detachTab = ^(NSInteger index) { [area detachTab:index from:weakWindow.panes]; };
			[window.contentView addSubview:window.tabs];
			NSRect frame = selected.placement.floatingFrame;
			if (NSIsEmptyRect(frame) || !NSIntersectsRect(frame, self.window.screen.visibleFrame))
				frame = NSMakeRect(NSMidX(self.window.frame) - 195, NSMidY(self.window.frame) - 120, 390, 240);
			[window setFrame:frame display:NO];
			[self.window addChildWindow:window ordered:NSWindowAbove];
			_floatingGroups[identifier] = window;
			[window orderFront:nil];
		}
		for (EditorDockPane *pane in window.panes)
			if (![group containsObject:pane] && pane.superview == window.contentView)
				[pane removeFromSuperview];
		window.panes = group;
		window.appearance = self.window.appearance;
		window.title = selected.title;
		NSRect body = window.contentView.bounds, strip;
		NSDivideRect(body, &strip, &body, group.count > 1 ? 22 : 0, NSMinYEdge);
		LayoutDockTabs(window.tabs, group, selected, strip);
		window.tabs.hidden = group.count < 2;
		for (EditorDockPane *pane in group)
		{
			if (pane.superview != window.contentView)
				[window.contentView addSubview:pane positioned:NSWindowBelow relativeTo:window.tabs];
			pane.frame = body;
			pane.hidden = pane != selected;
			pane.placement.floatingFrame = window.frame;
		}
	}
}

- (void)layout
{
	[super layout];
	NSRect remaining = self.bounds;
	NSInteger remainingSide = 0;
	NSInteger remainingHorizontal = 0;
	NSMutableDictionary<NSNumber *, NSArray<EditorDockPane *> *> *groups = [NSMutableDictionary dictionary];
	for (NSInteger index = EditorDockLeft; index <= EditorDockBottom; ++index)
	{
		auto edge = static_cast<EditorDockEdge>(index);
		NSArray<EditorDockPane *> *group = [self panesAtEdge:edge];
		if (group.count)
			(IsSide(edge) ? remainingSide : remainingHorizontal)++;
		groups[@(edge)] = group;
		_switchers[index].hidden = YES;
	}
	for (EditorDockPane *pane in _panes)
	{
		EditorDockPlacement *placement = pane.placement;
		EditorDockEdge edge = placement.edge;
		if (!pane.isShown || edge == EditorDockFloating)
			continue;
		NSArray<EditorDockPane *> *group = groups[@(edge)];
		if (pane != group.firstObject)
			continue;
		EditorDockPane *selected = SelectedPanel(group);
		const BOOL side = IsSide(edge);
		const NSInteger slots = side ? remainingSide-- : remainingHorizontal--;
		const CGFloat space = MAX(0, side ? NSWidth(remaining) - 240 : NSHeight(remaining) - 78);
		const CGFloat minimum = MIN(side ? 96 : 56, floor(space / slots));
		const CGFloat available = space - minimum * (slots - 1);
		const CGFloat length = MIN(available, side ? selected.placement.width : selected.placement.height);
		const NSRectEdge edges[] = {NSMinXEdge, NSMaxXEdge, NSMaxYEdge, NSMinYEdge};
		NSRect frame;
		NSDivideRect(remaining, &frame, &remaining, length, edges[edge]);
		DockTabs *switcher = _switchers[edge];
		if (group.count > 1)
		{
			NSRect tabs;
			NSDivideRect(frame, &tabs, &frame, MIN(22, NSHeight(frame)), NSMinYEdge);
			LayoutDockTabs(switcher, group, selected, tabs);
			switcher.hidden = NO;
		}
		for (EditorDockPane *candidate in group)
		{
			candidate.hidden = candidate != selected;
			if (candidate == selected)
				candidate.frame = frame;
		}
	}
	_editor.frame = remaining;
	[self layoutFloatingGroups];
}
@end

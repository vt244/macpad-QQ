// SPDX-License-Identifier: GPL-3.0-only
#import "EditorChrome.h"
#import "EditorContextMenus.h"
#import "EditorDocument.h"
#import "EditorPanelChrome.h"
#import "EditorResources.h"

static NSPasteboardType const TabPasteboardType = @"io.github.vt244.macpadqq.tab";

static CGFloat RelativeLuminance(NSColor *color)
{
	color = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	auto linear = [](CGFloat component) {
		return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4);
	};
	return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent);
}

static NSColor *ReadableTabText(NSColor *foreground, NSColor *background)
{
	const CGFloat text = RelativeLuminance(foreground) + 0.05;
	const CGFloat fill = RelativeLuminance(background) + 0.05;
	if (MAX(text, fill) / MIN(text, fill) >= 4.5)
		return foreground;
	return 1.05 / fill >= fill / 0.05 ? NSColor.whiteColor : NSColor.blackColor;
}

@interface DocumentTabView : NSView <NSDraggingSource>
@property(nonatomic, weak) EditorDocument *document;
@property(nonatomic) BOOL otherView;
- (void)trackTab:(NSEvent *)event click:(void (^)(void))click;
@end

@interface ChromeButton : NSButton
@property(nonatomic, strong) NSToolbarItem *command;
@property(nonatomic, strong) NSMenu *popup;
@property(nonatomic, weak) EditorDocument *document;
@property(nonatomic) NSInteger iconState;
@end
@implementation ChromeButton
- (void)mouseDown:(NSEvent *)event
{
	if (self.document)
		for (NSView *parent = self.superview; parent; parent = parent.superview)
			if ([parent isKindOfClass:DocumentTabView.class])
			{
				[(DocumentTabView *)parent trackTab:event click:^{ [self performClick:nil]; }];
				return;
			}
	[super mouseDown:event];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
	return self.document ? EditorTabMenu(self.document) : [super menuForEvent:event];
}

- (void)otherMouseDown:(NSEvent *)event
{
	if (self.document && event.buttonNumber == 2)
		[self.document closeEditorTab:nil];
	else
		[super otherMouseDown:event];
}
@end

@implementation DocumentTabView
{
	NSTrackingArea *_tracking;
	NSPopover *_preview;
}

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if (_tracking)
		[self removeTrackingArea:_tracking];
	_tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited |
		NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil];
	[self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event
{
	if (![[EditorResources.shared setting:@"tabPreview" fallback:@NO] boolValue] || !_document.editor)
		return;
	__weak DocumentTabView *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
		DocumentTabView *tab = weakSelf;
		if (!tab.window.isKeyWindow || tab->_preview ||
			!NSPointInRect([tab convertPoint:tab.window.mouseLocationOutsideOfEventStream fromView:nil], tab.bounds))
			return;
		EditorDocumentController *documents = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
		if ([documents selectedTabInOtherView:tab.otherView] == tab.document)
			return;
		ScintillaView *editor = tab.document.editor;
		const auto end = [editor message:SCI_GETLENGTH];
		auto limit = std::min<sptr_t>(end, 6000);
		const auto line = [editor message:SCI_POSITIONFROMLINE wParam:35];
		if (line > 0)
			limit = std::min<sptr_t>(limit, line);
		while (limit > 0 && limit < end && ([editor message:SCI_GETCHARAT wParam:limit] & 0xc0) == 0x80)
			--limit;
		const auto *bytes = reinterpret_cast<const char *>([editor message:SCI_GETCHARACTERPOINTER]);
		NSString *text = [[NSString alloc] initWithBytes:bytes length:limit encoding:NSUTF8StringEncoding];
		if (!text.length)
			text = tab.document.displayName;
		NSViewController *controller = [NSViewController new];
		NSTextView *view = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 280, 170)];
		view.editable = view.selectable = NO;
		view.string = text ?: @"";
		view.font = [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
		controller.view = view;
		tab->_preview = [NSPopover new];
		tab->_preview.behavior = NSPopoverBehaviorTransient;
		tab->_preview.contentSize = NSMakeSize(280, 170);
		tab->_preview.contentViewController = controller;
		[tab->_preview showRelativeToRect:tab.bounds ofView:tab preferredEdge:NSRectEdgeMaxY];
	});
}

- (void)mouseExited:(NSEvent *)event
{
	[_preview close];
	_preview = nil;
}

- (void)viewWillMoveToWindow:(NSWindow *)window
{
	if (!window)
	{
		[_preview close];
		_preview = nil;
	}
	[super viewWillMoveToWindow:window];
}
- (NSMenu *)menuForEvent:(NSEvent *)event { return EditorTabMenu(self.document); }
- (NSView *)hitTest:(NSPoint)point
{
	NSView *hit = [super hitTest:point];
	return !hit || [hit isKindOfClass:NSButton.class] ? hit : self;
}
- (void)mouseDown:(NSEvent *)event
{
	[self trackTab:event click:^{
		EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
		[controller activateTab:self.document otherView:self.otherView];
	}];
}

- (void)trackTab:(NSEvent *)event click:(void (^)(void))click
{
	NSWindow *window = self.window;
	const NSPoint start = event.locationInWindow;
	for (;;)
	{
		NSEvent *next = [window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
		if (!next)
			return;
		if (next.type == NSEventTypeLeftMouseUp)
		{
			if (NSPointInRect([self convertPoint:next.locationInWindow fromView:nil], self.bounds))
			{
				BOOL close = event.clickCount == 2 && [[EditorResources.shared setting:@"doubleClickClosesTab" fallback:@NO] boolValue];
				if (close)
					[self.document closeEditorTab:nil];
				else
					click();
			}
			return;
		}
		if (hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) < 4)
			continue;
		if ([[EditorResources.shared setting:@"lockTabs" fallback:@NO] boolValue])
			continue;
		NSPasteboardItem *reference = [NSPasteboardItem new];
		[reference setString:@"document" forType:TabPasteboardType];
		NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:reference];
		NSBitmapImageRep *bitmap = [self bitmapImageRepForCachingDisplayInRect:self.bounds];
		[self cacheDisplayInRect:self.bounds toBitmapImageRep:bitmap];
		NSImage *image = [[NSImage alloc] initWithSize:self.bounds.size];
		[image addRepresentation:bitmap];
		[item setDraggingFrame:self.bounds contents:image];
		[self beginDraggingSessionWithItems:@[item] event:next source:self];
		return;
	}
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
	return context == NSDraggingContextWithinApplication ? NSDragOperationMove : NSDragOperationNone;
}
- (void)otherMouseDown:(NSEvent *)event
{
	if (event.buttonNumber == 2)
		[self.document closeEditorTab:nil];
	else
		[super otherMouseDown:event];
}
@end

@interface TabContent : NSView
@end
@implementation TabContent
- (BOOL)isFlipped { return YES; }

- (void)mouseDown:(NSEvent *)event
{
	if (event.clickCount == 2)
		[NSDocumentController.sharedDocumentController newDocument:nil];
	else
		[super mouseDown:event];
}
@end

@interface EditorTabStrip ()
@property(nonatomic) BOOL otherView;
@property(nonatomic) BOOL verticalTabs;
@property(nonatomic) BOOL multilineTabs;
@property(nonatomic, weak) DocumentTabView *activeTab;
@end

@implementation EditorTabStrip
- (CGFloat)layoutTabsForWidth:(CGFloat)width height:(CGFloat)height vertical:(BOOL)vertical multiline:(BOOL)multiline
{
	self.verticalTabs = vertical;
	self.multilineTabs = multiline;
	self.hasVerticalScroller = vertical;
	self.autohidesScrollers = YES;
	NSView *content = self.documentView;
	CGFloat x = 0, y = 0, used = 0;
	CGFloat rowWidth = vertical ? MAX(1, width - 2) : MAX(1, width);
	for (DocumentTabView *tab in content.subviews)
	{
		NSView *controls = tab.subviews.lastObject;
		CGFloat tabWidth = MIN(vertical || multiline ? rowWidth : 260, MAX(45, controls.fittingSize.width));
		if (multiline && !vertical && x > 0 && x + tabWidth > rowWidth)
		{
			y += 25;
			x = 0;
		}
		tab.frame = NSMakeRect(x, y, vertical ? rowWidth : tabWidth, 24);
		if (vertical)
			y += 25;
		else
			x += tabWidth;
		used = MAX(used, x);
	}
	const CGFloat contentHeight = vertical ? MAX(25, y) : y + 25;
	[content setFrameSize:NSMakeSize(vertical ? rowWidth : MAX(rowWidth, used), contentHeight)];
	if (self.activeTab)
		[content scrollRectToVisible:self.activeTab.frame];
	return vertical ? height : multiline ? MIN(100, contentHeight) : 25;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)drag
{
	return [drag.draggingSource isKindOfClass:DocumentTabView.class] ? NSDragOperationMove : NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)drag
{
	if (![drag.draggingSource isKindOfClass:DocumentTabView.class])
		return NO;
	DocumentTabView *source = drag.draggingSource;
	NSView *content = self.documentView;
	NSPoint point = [content convertPoint:drag.draggingLocation fromView:nil];
	EditorDocument *anchor = nil;
	for (DocumentTabView *tab in content.subviews)
	{
		NSRect frame = tab.frame;
		BOOL before = self.verticalTabs ? point.y < NSMidY(frame) :
			point.y < NSMinY(frame) || (point.y <= NSMaxY(frame) && point.x < NSMidX(frame));
		if (before)
		{
			anchor = tab.document;
			break;
		}
	}
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	[controller dropTab:source.document before:anchor otherView:self.otherView];
	return YES;
}
@end

@interface TabCloseButton : EditorCrossButton
@property(nonatomic, weak) EditorDocument *document;
@end

@implementation TabCloseButton
- (NSMenu *)menuForEvent:(NSEvent *)event { return EditorTabMenu(self.document); }
@end

enum StatusFieldIndex
{
	StatusSyntax, StatusLength, StatusLines, StatusLine, StatusColumn, StatusPosition,
	StatusLineEnding, StatusEncoding, StatusMode, StatusFieldCount
};

@interface StatusField : NSTextField
@property(nonatomic) NSUInteger fieldIndex;
@end

@implementation StatusField
- (NSMenu *)menuForEvent:(NSEvent *)event
{
	EditorResources *resources = EditorResources.shared;
	if (self.fieldIndex == StatusEncoding)
		return [[NSApp.mainMenu itemWithTitle:[resources label:@"encoding" fallback:@"Encoding"]].submenu copy];
	if (self.fieldIndex == StatusLineEnding)
	{
		NSMenu *edit = [NSApp.mainMenu itemWithTitle:[resources label:@"edit" fallback:@"Edit"]].submenu;
		NSString *title = [resources label:@"edit-eolConversion" fallback:@"EOL Conversion"];
		return [[edit itemWithTitle:title].submenu copy];
	}
	return [super menuForEvent:event];
}
@end

static ChromeButton *Button(NSString *label, id target, SEL action)
{
	ChromeButton *button = [[ChromeButton alloc] initWithFrame:NSZeroRect];
	button.bordered = NO;
	button.focusRingType = NSFocusRingTypeNone;
	button.font = [NSFont systemFontOfSize:12];
	button.title = label;
	button.target = target;
	button.action = action;
	button.translatesAutoresizingMaskIntoConstraints = NO;
	return button;
}

static NSStackView *HorizontalStack()
{
	NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
	stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	stack.alignment = NSLayoutAttributeCenterY;
	stack.spacing = 0;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	return stack;
}

static NSView *ColoredView()
{
	NSView *view = [[NSView alloc] initWithFrame:NSZeroRect];
	view.wantsLayer = YES;
	view.translatesAutoresizingMaskIntoConstraints = NO;
	return view;
}

static void RemoveItems(NSStackView *stack)
{
	for (NSView *view in stack.arrangedSubviews)
	{
		[stack removeArrangedSubview:view];
		[view removeFromSuperview];
	}
}

static EditorTabStrip *TabStrip(BOOL other)
{
	EditorTabStrip *scroll = [[EditorTabStrip alloc] initWithFrame:NSZeroRect];
	scroll.otherView = other;
	[scroll registerForDraggedTypes:@[TabPasteboardType]];
	scroll.drawsBackground = NO;
	scroll.wantsLayer = YES;
	scroll.horizontalScrollElasticity = NSScrollElasticityNone;
	scroll.documentView = [[TabContent alloc] initWithFrame:NSMakeRect(0, 0, 0, 25)];
	return scroll;
}

@implementation EditorChrome
{
	__weak EditorDocument *_document;
	NSStackView *_rows;
	NSStackView *_menus;
	NSStackView *_buttons;
	NSView *_toolbarDivider;
	NSLayoutConstraint *_toolbarHeight;
	NSLayoutConstraint *_statusHeight;
	EditorTabStrip *_tabScroll;
	EditorTabStrip *_otherTabScroll;
	NSArray<NSTextField *> *_statusLabels;
	NSMutableArray<NSView *> *_separators;
	NSColor *_edgeColor;
	NSColor *_activeTabColor;
	NSColor *_inactiveTabColor;
	NSColor *_activeTabText;
	NSColor *_inactiveTabText;
	NSColor *_activeIndicatorColor;
	NSColor *_unfocusedIndicatorColor;
}

- (instancetype)initWithDocument:(EditorDocument *)document commands:(NSArray<NSToolbarItem *> *)commands
{
	self = [super initWithFrame:NSZeroRect];
	if (!self)
		return nil;
	_document = document;
	self.translatesAutoresizingMaskIntoConstraints = NO;
	self.wantsLayer = YES;
	_separators = [NSMutableArray array];
	_rows = [[NSStackView alloc] initWithFrame:NSZeroRect];
	_rows.orientation = NSUserInterfaceLayoutOrientationVertical;
	_rows.distribution = NSStackViewDistributionFill;
	_rows.alignment = NSLayoutAttributeLeading;
	_rows.spacing = 0;
	_rows.translatesAutoresizingMaskIntoConstraints = NO;
	[self addSubview:_rows];
	[NSLayoutConstraint activateConstraints:@[
		[_rows.topAnchor constraintEqualToAnchor:self.topAnchor],
		[_rows.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
		[_rows.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[_rows.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
	]];

	_menus = HorizontalStack();
	_menus.edgeInsets = NSEdgeInsetsMake(0, 2, 0, 2);
	[self addHeaderRow:_menus height:23];
	[self refreshMenus];

	_buttons = HorizontalStack();
	_buttons.edgeInsets = NSEdgeInsetsMake(0, 3, 0, 3);
	[_buttons setAccessibilityElement:YES];
	[_buttons setAccessibilityRole:NSAccessibilityToolbarRole];
	NSMutableArray<NSButton *> *toolbarButtons = [NSMutableArray array];
	for (NSToolbarItem *item in commands)
	{
		if ([item.itemIdentifier isEqualToString:NSToolbarSpaceItemIdentifier])
		{
			NSView *separator = ColoredView();
			[separator.heightAnchor constraintEqualToConstant:16].active = YES;
			[separator.widthAnchor constraintEqualToConstant:1].active = YES;
			if (_buttons.arrangedSubviews.count)
				[_buttons setCustomSpacing:3 afterView:_buttons.arrangedSubviews.lastObject];
			[_buttons addArrangedSubview:separator];
			[_buttons setCustomSpacing:3 afterView:separator];
			[_separators addObject:separator];
			continue;
		}
		ChromeButton *button = Button(@"", self, @selector(runCommand:));
		button.iconState = -1;
		button.command = item;
		button.image = item.image;
		button.imagePosition = NSImageOnly;
		button.toolTip = item.label;
		[button setAccessibilityLabel:item.label];
		[button.widthAnchor constraintEqualToConstant:23].active = YES;
		[button.heightAnchor constraintEqualToConstant:23].active = YES;
		[_buttons addArrangedSubview:button];
		[toolbarButtons addObject:button];
	}
	_toolbarButtons = [toolbarButtons copy];
	[_buttons addArrangedSubview:ColoredView()];
	[self addHeaderRow:_buttons height:25];
	_toolbarDivider = _separators.lastObject;
	for (NSLayoutConstraint *constraint in _buttons.constraints)
		if (constraint.firstAttribute == NSLayoutAttributeHeight && !constraint.secondItem)
			_toolbarHeight = constraint;
	// Keep the editor's existing minimum width. Extra toolbar actions remain in the menus.
	_buttons.clipsToBounds = YES;

	_tabScroll = TabStrip(NO);
	_otherTabScroll = TabStrip(YES);

	NSStackView *status = HorizontalStack();
	status.distribution = NSStackViewDistributionFill;
	status.wantsLayer = YES;
	status.edgeInsets = NSEdgeInsetsMake(0, 3, 0, 3);
	_statusHeight = [status.heightAnchor constraintEqualToConstant:21];
	_statusHeight.active = YES;
	NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
	const NSLayoutPriority compression[] = {
		NSLayoutPriorityDefaultLow, 755, 999, 758, 757, 751, 753, 754, 756
	};
	for (NSUInteger i = 0; i < StatusFieldCount; ++i)
	{
		StatusField *field = [[StatusField alloc] initWithFrame:NSZeroRect];
		field.fieldIndex = i;
		field.editable = NO;
		field.selectable = NO;
		field.bezeled = NO;
		field.bordered = NO;
		field.drawsBackground = NO;
		field.font = [NSFont systemFontOfSize:12];
		field.lineBreakMode = NSLineBreakByTruncatingTail;
		field.translatesAutoresizingMaskIntoConstraints = NO;
		[field setContentCompressionResistancePriority:compression[i] forOrientation:NSLayoutConstraintOrientationHorizontal];
		[field setContentHuggingPriority:i == StatusSyntax ? NSLayoutPriorityDefaultLow : NSLayoutPriorityDefaultHigh
			forOrientation:NSLayoutConstraintOrientationHorizontal];
		[field.widthAnchor constraintGreaterThanOrEqualToConstant:24].active = YES;
		[fields addObject:field];
		[status addArrangedSubview:field];
		[status setCustomSpacing:5 afterView:field];
		if (i == StatusSyntax || i == StatusLines || i == StatusPosition || i == StatusLineEnding || i == StatusEncoding)
		{
			NSView *separator = ColoredView();
			[separator.heightAnchor constraintEqualToConstant:15].active = YES;
			[separator.widthAnchor constraintEqualToConstant:1].active = YES;
			[status addArrangedSubview:separator];
			[status setCustomSpacing:5 afterView:separator];
			[_separators addObject:separator];
		}
	}
	_statusBar = status;
	_statusLabels = [fields copy];
	[self refreshColors];
	return self;
}

- (void)addHeaderRow:(NSView *)row height:(CGFloat)height
{
	[_rows addArrangedSubview:row];
	NSView *line = ColoredView();
	[_rows addArrangedSubview:line];
	[NSLayoutConstraint activateConstraints:@[
		[row.heightAnchor constraintEqualToConstant:height],
		[row.trailingAnchor constraintEqualToAnchor:_rows.trailingAnchor],
		[line.heightAnchor constraintEqualToConstant:1],
		[line.trailingAnchor constraintEqualToAnchor:_rows.trailingAnchor],
	]];
	[_separators addObject:line];
}

- (void)refreshMenus
{
	RemoveItems(_menus);
	for (NSMenuItem *item in NSApp.mainMenu.itemArray)
	{
		if (!item.submenu || [item.title isEqualToString:@"macpadqq"])
			continue;
		ChromeButton *button = Button(item.title, self, @selector(showMenu:));
		button.popup = [item.representedObject isKindOfClass:NSMenu.class] ? item.representedObject : item.submenu;
		[button.widthAnchor constraintEqualToConstant:ceil(button.intrinsicContentSize.width + 10)].active = YES;
		[_menus addArrangedSubview:button];
	}
	[_menus addArrangedSubview:ColoredView()];
	ChromeButton *newFile = Button(@"+", NSDocumentController.sharedDocumentController, @selector(newDocument:));
	[newFile setAccessibilityLabel:[EditorResources.shared label:@"chrome-new" fallback:@"New"]];
	ChromeButton *choose = Button(@"▾", self, @selector(showDocuments:));
	[choose setAccessibilityLabel:[EditorResources.shared label:@"chrome-openDocuments" fallback:@"Open documents"]];
	ChromeButton *close = Button(@"×", _document, @selector(closeEditorTab:));
	[close setAccessibilityLabel:[EditorResources.shared label:@"chrome-closeTab" fallback:@"Close current tab"]];
	for (NSButton *button in @[newFile, choose, close])
	{
		[_menus addArrangedSubview:button];
		[button.widthAnchor constraintEqualToConstant:20].active = YES;
	}
}

- (void)showMenu:(ChromeButton *)sender
{
	[sender.popup popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)) inView:sender];
}

- (void)showDocuments:(NSButton *)sender
{
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Open documents"];
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	for (EditorDocument *document in controller.tabDocuments)
	{
		NSMenuItem *item = [menu addItemWithTitle:document.displayName action:@selector(showDocument:) keyEquivalent:@""];
		item.target = self;
		item.representedObject = document;
		item.state = document == _document ? NSControlStateValueOn : NSControlStateValueOff;
	}
	[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)) inView:sender];
}

- (void)showDocument:(NSMenuItem *)item
{
	[item.representedObject showWindows];
}

- (void)runCommand:(ChromeButton *)sender
{
	NSToolbarItem *command = sender.command;
	[NSApp sendAction:command.action to:[_document targetForToolbarCommand:command] from:command];
	[self refreshToolbar];
}

- (void)refreshToolbar
{
	for (ChromeButton *button in self.toolbarButtons)
	{
		const BOOL enabled = [_document isToolbarCommandEnabled:button.command];
		button.enabled = enabled;
		[self updateIconForButton:button];
	}
}

- (void)refreshToolbarLabels:(NSArray<NSToolbarItem *> *)commands
{
	NSMutableDictionary<NSString *, NSString *> *labels = [NSMutableDictionary dictionary];
	for (NSToolbarItem *command in commands)
		if (command.action)
			labels[command.itemIdentifier] = command.label;
	for (ChromeButton *button in self.toolbarButtons)
	{
		NSString *label = labels[button.command.itemIdentifier];
		if (label)
		{
			button.command.label = button.command.toolTip = button.toolTip = label;
			[button setAccessibilityLabel:label];
		}
	}
}

- (void)refreshTabs
{
	[self refreshStrip:_tabScroll];
	[self refreshStrip:_otherTabScroll];
}

- (NSView *)primaryTabs { return _tabScroll; }
- (NSView *)secondaryTabs { return _otherTabScroll; }

- (void)setTabsHidden:(BOOL)hidden
{
	for (EditorTabStrip *strip in @[_tabScroll, _otherTabScroll])
	{
		strip.hidden = hidden;
		strip.superview.needsLayout = YES;
	}
}

- (void)refreshAppearancePreferences
{
	EditorResources *resources = EditorResources.shared;
	[self setTabsHidden:[[resources setting:@"hideTabBar" fallback:@NO] boolValue]];
	_buttons.hidden = _toolbarDivider.hidden = !self.toolbarButtons.count || [[resources setting:@"hideToolbar" fallback:@NO] boolValue];
	BOOL hideStatus = [[resources setting:@"hideStatusBar" fallback:@NO] boolValue];
	_statusBar.hidden = hideStatus;
	_statusHeight.constant = hideStatus ? 0 : 21;
	[self refreshColors];
}

- (void)refreshStrip:(EditorTabStrip *)strip
{
	const BOOL other = strip.otherView;
	NSView *content = strip.documentView;
	for (NSView *tab in content.subviews)
		[tab removeFromSuperview];
	DocumentTabView *activeTab = nil;
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	const BOOL dark = EditorResources.shared.usesDarkColors;
	EditorDocument *selected = self.window.visible || other ? [controller selectedTabInOtherView:other] : _document;
	for (EditorDocument *document in [controller tabsInOtherView:other])
	{
		const BOOL active = document == selected;
		DocumentTabView *tab = [[DocumentTabView alloc] initWithFrame:NSZeroRect];
		tab.document = document;
		tab.otherView = other;
		tab.wantsLayer = YES;
		tab.translatesAutoresizingMaskIntoConstraints = YES;
		tab.layer.borderWidth = 1;
		tab.layer.borderColor = _edgeColor.CGColor;
		NSColor *background = EditorTabColor(document.tabColorIndex) ?: (active ? _activeTabColor : _inactiveTabColor);
		NSColor *foreground = ReadableTabText(active ? _activeTabText : _inactiveTabText, background);
		tab.layer.backgroundColor = background.CGColor;
		NSStackView *contents = HorizontalStack();
		contents.edgeInsets = NSEdgeInsetsMake(0, 6, 0, 4);
		contents.spacing = 4;
		ChromeButton *select = Button(document.displayName, self, @selector(activateTab:));
		select.document = document;
		select.tag = other;
		select.toolTip = document.fileURL.path ?: document.displayName;
		select.attributedTitle = [[NSAttributedString alloc] initWithString:select.title
			attributes:@{NSForegroundColorAttributeName: foreground, NSFontAttributeName: select.font}];
		select.contentTintColor = foreground;
		select.lineBreakMode = NSLineBreakByTruncatingMiddle;
		select.image = EditorTabStateIcon(document.isDocumentEdited, [document.editor message:SCI_GETREADONLY] != 0,
			document.isMonitoring, dark);
		select.imagePosition = NSImageLeft;
		[select.widthAnchor constraintLessThanOrEqualToConstant:210].active = YES;
		[contents addArrangedSubview:select];
		if (active)
		{
			activeTab = tab;
			NSView *indicator = ColoredView();
			indicator.layer.backgroundColor = (controller.focusedDocument == document ? _activeIndicatorColor :
				_unfocusedIndicatorColor).CGColor;
			[tab addSubview:indicator];
			[NSLayoutConstraint activateConstraints:@[
				[indicator.topAnchor constraintEqualToAnchor:tab.topAnchor],
				[indicator.leadingAnchor constraintEqualToAnchor:tab.leadingAnchor],
				[indicator.trailingAnchor constraintEqualToAnchor:tab.trailingAnchor],
				[indicator.heightAnchor constraintEqualToConstant:3],
			]];
		}
		if (document.isTabPinned)
		{
			NSString *directory = dark ? @"tabbar/dark" : @"tabbar";
			NSURL *url = [NSBundle.mainBundle URLForResource:@"pinTabButton_pinned" withExtension:@"ico" subdirectory:directory];
			NSImage *image = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
			image.size = NSMakeSize(11, 11);
			if (image)
				[contents addArrangedSubview:[NSImageView imageViewWithImage:image]];
		}
		if ([[EditorResources.shared setting:@"tabCloseButtons" fallback:@YES] boolValue])
		{
			TabCloseButton *close = [[TabCloseButton alloc] initWithFrame:NSZeroRect];
			close.document = document;
			close.tag = other;
			close.target = self;
			close.action = @selector(closeTab:);
			close.bordered = NO;
			close.translatesAutoresizingMaskIntoConstraints = NO;
			close.contentTintColor = foreground;
			close.toolTip = [NSString stringWithFormat:[EditorResources.shared label:@"native-closeNamedTab" fallback:@"Close %@"],
				document.displayName];
			[close setAccessibilityLabel:close.toolTip];
			[close.widthAnchor constraintEqualToConstant:16].active = YES;
			[close.heightAnchor constraintEqualToConstant:16].active = YES;
			[contents addArrangedSubview:close];
		}
		[tab addSubview:contents];
		[NSLayoutConstraint activateConstraints:@[
			[contents.leadingAnchor constraintEqualToAnchor:tab.leadingAnchor],
			[contents.trailingAnchor constraintEqualToAnchor:tab.trailingAnchor],
			[contents.centerYAnchor constraintEqualToAnchor:tab.centerYAnchor constant:-1],
		]];
		[content addSubview:tab];
	}
	strip.activeTab = activeTab;
	strip.superview.needsLayout = YES;
}

- (void)activateTab:(ChromeButton *)button
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	[controller activateTab:button.document otherView:button.tag != 0];
}

- (void)closeTab:(TabCloseButton *)button
{
	EditorDocumentController *controller = (EditorDocumentController *)NSDocumentController.sharedDocumentController;
	if (button.tag && button.document == [controller selectedTabInOtherView:NO])
		[button.document closeOtherView:nil];
	else
		[button.document closeEditorTab:nil];
}

- (void)setStatusFields:(NSArray<NSString *> *)fields toolTips:(NSArray<NSString *> *)toolTips
{
	for (NSUInteger i = 0; i < _statusLabels.count; ++i)
	{
		NSTextField *label = _statusLabels[i];
		if (![label.stringValue isEqualToString:fields[i]])
			label.stringValue = fields[i];
		if (![label.toolTip isEqualToString:toolTips[i]])
			label.toolTip = toolTips[i];
	}
}

- (void)viewDidChangeEffectiveAppearance
{
	[super viewDidChangeEffectiveAppearance];
	[self refreshColors];
}

- (void)updateIconForButton:(ChromeButton *)button
{
	EditorResources *resources = EditorResources.shared;
	const BOOL dark = resources.usesDarkColors;
	NSInteger style = [[resources setting:@"toolbarStyle" fallback:@0] integerValue];
	style = MAX(0, MIN(4, style));
	NSInteger state = (style << 2) | (dark ? 2 : 0) | (button.enabled ? 1 : 0);
	if (button.iconState == state)
		return;
	button.iconState = state;
	NSString *directory = [NSString stringWithFormat:@"toolbar/%@/%@", dark ? @"dark" : @"light", style >= 2 ? @"filled" : @"regular"];
	NSString *base = button.command.itemIdentifier;
	NSDictionary *customNames = @{@"saveall": @"save-all", @"closeall": @"close-all", @"findrep": @"replace",
		@"zoomIn": @"zoom-in", @"zoomOut": @"zoom-out", @"syncV": @"sync-vertical", @"syncH": @"sync-horizontal",
		@"wrap": @"word-wrap", @"allChars": @"all-chars", @"indentGuide": @"indent-guide", @"udl": @"udl-dlg",
		@"docMap": @"doc-map", @"docList": @"doc-list", @"funcList": @"function-list", @"fileBrowser": @"folder-as-workspace",
		@"startrecord": @"record", @"stoprecord": @"stop-record", @"playrecord": @"playback", @"saverecord": @"save-macro",
		@"playrecord_m": @"playback-multiple"};
	NSURL *url = [resources toolbarIconNamed:customNames[base] ?: base disabled:!button.enabled];
	if (!url && style == 4)
	{
		NSDictionary *classicNames = @{@"new": @"newFile", @"open": @"openFile", @"save": @"saveFile", @"saveall": @"saveAll",
			@"close": @"closeFile", @"closeall": @"closeAll", @"findrep": @"findReplace", @"startrecord": @"startRecord",
			@"stoprecord": @"stopRecord", @"playrecord": @"playRecord", @"saverecord": @"saveRecord", @"playrecord_m": @"playRecord_m"};
		url = [NSBundle.mainBundle URLForResource:classicNames[base] ?: base withExtension:@"bmp" subdirectory:@"toolbar/classic"];
	}
	if (!url && !button.enabled)
		url = [NSBundle.mainBundle URLForResource:[base stringByAppendingString:@"_dis"]
		withExtension:@"ico" subdirectory:directory];
	url = url ?: [NSBundle.mainBundle URLForResource:[base stringByAppendingString:@"_off"]
		withExtension:@"ico" subdirectory:directory];
	NSImage *image = url ? [[NSImage alloc] initWithContentsOfURL:url] : [button.command.image copy];
	const CGFloat size = style % 2 ? 24 : 16;
	image.size = NSMakeSize(size, size);
	button.image = image;
}

- (void)refreshColors
{
	EditorResources *resources = EditorResources.shared;
	const BOOL dark = resources.usesDarkColors;
	NSAppearance *appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
	self.appearance = appearance;
	self.statusBar.appearance = appearance;
	NSColor *background = [NSColor colorWithWhite:dark ? 0.13 : 0.94 alpha:1];
	self.layer.backgroundColor = background.CGColor;
	self.statusBar.layer.backgroundColor = background.CGColor;
	_tabScroll.layer.backgroundColor = _otherTabScroll.layer.backgroundColor = background.CGColor;
	_edgeColor = [NSColor colorWithWhite:dark ? 0.30 : 0.76 alpha:1];
	_activeTabColor = [NSColor colorWithWhite:dark ? 0.22 : 1 alpha:1];
	_inactiveTabColor = [resources widgetColor:@"Inactive tabs" background:YES] ?:
		[NSColor colorWithWhite:dark ? 0.19 : 0.83 alpha:1];
	_activeTabText = [resources widgetColor:@"Active tab text" background:NO] ?: (dark ? NSColor.whiteColor : NSColor.blackColor);
	_inactiveTabText = [resources widgetColor:@"Inactive tabs" background:NO] ?:
		(dark ? [NSColor colorWithWhite:0.75 alpha:1] : NSColor.darkGrayColor);
	_activeIndicatorColor = [resources widgetColor:@"Active tab focused indicator" background:NO] ?: NSColor.systemOrangeColor;
	_unfocusedIndicatorColor = [resources widgetColor:@"Active tab unfocused indicator" background:NO] ?: _edgeColor;
	for (NSView *separator in _separators)
		separator.layer.backgroundColor = _edgeColor.CGColor;
	for (NSTextField *label in _statusLabels)
		label.textColor = dark ? NSColor.whiteColor : NSColor.blackColor;
	const BOOL large = [[resources setting:@"toolbarStyle" fallback:@0] integerValue] % 2;
	_toolbarHeight.constant = large ? 33 : 25;
	for (ChromeButton *button in self.toolbarButtons)
	{
		for (NSLayoutConstraint *constraint in button.constraints)
			if (constraint.firstItem == button && !constraint.secondItem)
				constraint.constant = large ? 31 : 23;
		[self updateIconForButton:button];
	}
	[self refreshTabs];
}
@end

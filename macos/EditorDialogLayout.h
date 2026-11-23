// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

// AppKit sizes an alert from its accessory's frame, including for stack views.
static inline NSStackView *EditorDialogForm(NSArray<NSView *> *rows, CGFloat minimumWidth)
{
	NSStackView *form = [NSStackView stackViewWithViews:rows];
	form.orientation = NSUserInterfaceLayoutOrientationVertical;
	form.alignment = NSLayoutAttributeLeading;
	form.spacing = 9;
	form.edgeInsets = NSEdgeInsetsMake(2, 3, 2, 3);
	CGFloat width = minimumWidth;
	for (NSView *row in rows)
		if (![row isKindOfClass:NSTextField.class] || ![(NSTextField *)row isEditable])
			width = MAX(width, ceil(row.fittingSize.width));
	if (NSScreen *screen = (NSApp.keyWindow.screen ?: NSScreen.mainScreen))
		width = MIN(width, MAX(minimumWidth, NSWidth(screen.visibleFrame) - 120));
	for (NSView *row in rows)
		if ([row isKindOfClass:NSPopUpButton.class] ||
			([row isKindOfClass:NSTextField.class] && [(NSTextField *)row isEditable]))
			[row.widthAnchor constraintEqualToConstant:width].active = YES;
	form.frame = NSMakeRect(0, 0, width + 6, ceil(form.fittingSize.height));
	return form;
}

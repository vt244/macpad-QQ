// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>
#import <QuickLookUI/QLPreviewingController.h>

#import "../EditorPreview.h"
#import "../EditorResources.h"
#import "ScintillaView.h"

@interface MacpadTextPreviewController : NSViewController <QLPreviewingController>
@end

@implementation MacpadTextPreviewController
{
	EditorResources *_resources;
}

- (void)loadView
{
	self.view = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 760, 520)];
	self.preferredContentSize = self.view.frame.size;
	// The extension is nested in the containing app's Contents/PlugIns directory.
	NSURL *appURL = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent
		.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
	_resources = [[EditorResources alloc] initForPreviewWithBundle:[NSBundle bundleWithURL:appURL]];
}

- (void)preparePreviewOfFileAtURL:(NSURL *)fileURL completionHandler:(void (^)(NSError *))handler
{
	NSError *error = nil;
	ScintillaView *view = (ScintillaView *)self.view;
	handler(LoadEditorPreview(view, fileURL, _resources, &error) ? nil : error);
}

@end

// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>
@class EditorDocument;
NSPrintOperation *EditorPrintOperation(EditorDocument *document, NSDictionary *settings);

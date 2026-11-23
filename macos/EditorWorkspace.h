// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

@class EditorDocumentController;

@interface EditorWorkspace : NSObject
- (instancetype)initWithController:(EditorDocumentController *)controller;
- (BOOL)startAtDirectory:(NSURL *)directory;
- (void)scheduleCheckpoint;
- (BOOL)checkpoint;
- (BOOL)restoreFromURL:(NSURL *)url error:(NSError **)error;
- (BOOL)writeToURL:(NSURL *)url error:(NSError **)error;
@end

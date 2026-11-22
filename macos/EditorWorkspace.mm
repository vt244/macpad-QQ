// SPDX-License-Identifier: GPL-3.0-only
#import "EditorWorkspace.h"
#import "EditorDocument.h"
#import "EditorResources.h"

#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

@implementation EditorWorkspace
{
	__weak EditorDocumentController *_controller;
	NSURL *_snapshotURL;
	NSTimer *_timer;
	int _lock;
}

- (instancetype)initWithController:(EditorDocumentController *)controller
{
	self = [super init];
	if (self)
	{
		_controller = controller;
		_lock = -1;
	}
	return self;
}

- (void)dealloc
{
	[_timer invalidate];
	if (_lock >= 0)
		close(_lock);
}

- (BOOL)startAtDirectory:(NSURL *)directory
{
	NSFileManager *files = NSFileManager.defaultManager;
	NSError *error = nil;
	if (![files createDirectoryAtURL:directory withIntermediateDirectories:YES
		attributes:@{NSFilePosixPermissions: @0700} error:&error])
		return NO;
	NSURL *lockURL = [directory URLByAppendingPathComponent:@"workspace.lock"];
	_lock = open(lockURL.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (_lock < 0)
		return NO;
	if (flock(_lock, LOCK_EX | LOCK_NB) != 0)
	{
		close(_lock);
		_lock = -1;
		return NO;
	}
	NSURL *snapshot = [directory URLByAppendingPathComponent:@"workspace.plist"];
	if ([files fileExistsAtPath:snapshot.path] && ![self restoreFromURL:snapshot error:&error])
	{
		close(_lock);
		_lock = -1;
		NSLog(@"macpad++ workspace: %@", error.localizedDescription);
		return NO;
	}
	_snapshotURL = snapshot;
	return YES;
}

- (void)scheduleCheckpoint
{
	if (!_snapshotURL || _timer)
		return;
	__weak EditorWorkspace *weakSelf = self;
	NSTimeInterval interval = [[EditorResources.shared setting:@"checkpointMilliseconds" fallback:@1000] doubleValue] / 1000;
	_timer = [NSTimer timerWithTimeInterval:MAX(0.25, interval) repeats:NO block:^(NSTimer *timer) {
		[weakSelf checkpoint];
	}];
	[NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (BOOL)checkpoint
{
	[_timer invalidate];
	_timer = nil;
	if (!_snapshotURL)
		return NO;
	NSError *error = nil;
	if ([self writeToURL:_snapshotURL error:&error])
		return YES;
	NSLog(@"macpad++ workspace: %@", error.localizedDescription);
	return NO;
}

- (BOOL)restoreFromURL:(NSURL *)url error:(NSError **)error
{
	NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
	if (!data)
		return NO;
	id snapshot = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nullptr error:error];
	if ([snapshot isKindOfClass:NSDictionary.class] && [snapshot[@"version"] isEqual:@1] &&
		[snapshot[@"documents"] isKindOfClass:NSArray.class])
	{
		[_controller restoreWorkspace:snapshot];
		return YES;
	}
	if (error && !*error)
		*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{
			NSLocalizedDescriptionKey: @"The recovery file is not a supported workspace.", NSURLErrorKey: url}];
	return NO;
}

- (BOOL)writeToURL:(NSURL *)url error:(NSError **)error
{
	NSData *snapshot = [NSPropertyListSerialization dataWithPropertyList:[_controller captureWorkspace]
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
	return snapshot && [snapshot writeToURL:url options:NSDataWritingAtomic error:error];
}
@end

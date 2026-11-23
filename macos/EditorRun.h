// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

NSString *ExpandEditorRunCommand(NSString *command, NSDictionary<NSString *, NSString *> *values);
NSTask *EditorRunTask(NSString *command, NSDictionary<NSString *, NSString *> *values, NSURL *workingDirectory);

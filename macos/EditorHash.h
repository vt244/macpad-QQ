// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, EditorHashAlgorithm)
{
	EditorHashMD5,
	EditorHashSHA1,
	EditorHashSHA256,
	EditorHashSHA512,
};

NSString *EditorHashData(NSData *data, EditorHashAlgorithm algorithm);
NSString *EditorHashFile(NSURL *url, EditorHashAlgorithm algorithm, NSError **error);

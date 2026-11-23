// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

NSString *DecodeExtendedSearchText(NSString *input);

NSString *DecodeEditorText(NSData *data, NSStringEncoding *encoding, NSData **bom);
NSData *EncodeEditorText(NSData *utf8, NSStringEncoding encoding, NSData *bom);
NSString *DecodeEditorTextWithEncoding(NSData *data, NSStringEncoding encoding);

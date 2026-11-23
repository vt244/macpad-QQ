// SPDX-License-Identifier: GPL-3.0-only
#import "EditorHash.h"

#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <climits>

struct Digest
{
	EditorHashAlgorithm algorithm;
	CC_MD5_CTX md5;
	CC_SHA1_CTX sha1;
	CC_SHA256_CTX sha256;
	CC_SHA512_CTX sha512;

	// MD5 and SHA-1 are available for compatibility with existing text and file checksums.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	explicit Digest(EditorHashAlgorithm choice) : algorithm(choice)
	{
		switch (algorithm)
		{
		case EditorHashMD5: CC_MD5_Init(&md5); break;
		case EditorHashSHA1: CC_SHA1_Init(&sha1); break;
		case EditorHashSHA256: CC_SHA256_Init(&sha256); break;
		case EditorHashSHA512: CC_SHA512_Init(&sha512); break;
		}
	}

	void update(NSData *data)
	{
		const auto *bytes = static_cast<const unsigned char *>(data.bytes);
		for (NSUInteger offset = 0; offset < data.length;)
		{
			const auto count = static_cast<CC_LONG>(std::min<NSUInteger>(UINT_MAX, data.length - offset));
			switch (algorithm)
			{
			case EditorHashMD5: CC_MD5_Update(&md5, bytes + offset, count); break;
			case EditorHashSHA1: CC_SHA1_Update(&sha1, bytes + offset, count); break;
			case EditorHashSHA256: CC_SHA256_Update(&sha256, bytes + offset, count); break;
			case EditorHashSHA512: CC_SHA512_Update(&sha512, bytes + offset, count); break;
			}
			offset += count;
		}
	}

	NSString *finish()
	{
		unsigned char bytes[CC_SHA512_DIGEST_LENGTH];
		size_t length = 0;
		switch (algorithm)
		{
		case EditorHashMD5: CC_MD5_Final(bytes, &md5); length = CC_MD5_DIGEST_LENGTH; break;
		case EditorHashSHA1: CC_SHA1_Final(bytes, &sha1); length = CC_SHA1_DIGEST_LENGTH; break;
		case EditorHashSHA256: CC_SHA256_Final(bytes, &sha256); length = CC_SHA256_DIGEST_LENGTH; break;
		case EditorHashSHA512: CC_SHA512_Final(bytes, &sha512); length = CC_SHA512_DIGEST_LENGTH; break;
		}
		constexpr char hex[] = "0123456789abcdef";
		char output[CC_SHA512_DIGEST_LENGTH * 2];
		for (size_t i = 0; i < length; ++i)
		{
			output[i * 2] = hex[bytes[i] >> 4];
			output[i * 2 + 1] = hex[bytes[i] & 15];
		}
		return [[NSString alloc] initWithBytes:output length:length * 2 encoding:NSASCIIStringEncoding];
	}
#pragma clang diagnostic pop
};

NSString *EditorHashData(NSData *data, EditorHashAlgorithm algorithm)
{
	Digest digest(algorithm);
	digest.update(data);
	return digest.finish();
}

NSString *EditorHashFile(NSURL *url, EditorHashAlgorithm algorithm, NSError **error)
{
	NSNumber *regular = nil;
	if (![url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:error])
		return nil;
	if (!regular.boolValue)
	{
		if (error)
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnsupportedSchemeError userInfo:@{NSURLErrorKey: url}];
		return nil;
	}
	NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:error];
	if (!file)
		return nil;
	Digest digest(algorithm);
	NSError *failure = nil;
	for (;;)
	{
		@autoreleasepool
		{
			NSData *chunk = [file readDataUpToLength:64 * 1024 error:&failure];
			if (!chunk.length)
				break;
			digest.update(chunk);
		}
	}
	[file closeAndReturnError:nullptr];
	if (failure && error)
		*error = failure;
	return failure ? nil : digest.finish();
}

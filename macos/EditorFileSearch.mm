// SPDX-License-Identifier: GPL-3.0-only
#import "EditorFileSearch.h"
#import "EditorSearchBuffer.h"
#import "EditorText.h"
#import "ScintillaView.h"

#include <algorithm>
#include <exception>
#include <fnmatch.h>
#include <forward_list>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

#include "ScintillaTypes.h"
#include "BoostRegexSearch.h"
#include "ILexer.h"
#include "ILoader.h"
#include "Debugging.h"
#include "CharacterType.h"
#include "CharacterCategoryMap.h"
#include "Position.h"
#include "SplitVector.h"
#include "Partitioning.h"
#include "RunStyles.h"
#include "CellBuffer.h"
#include "PerLine.h"
#include "CharClassify.h"
#include "Decoration.h"
#include "CaseFolder.h"
#include "Document.h"

@implementation EditorSearchSource
- (instancetype)initWithName:(NSString *)name url:(NSURL *)url document:(EditorDocument *)document utf8:(NSData *)utf8 range:(NSRange)range
{
	if ((self = [super init]))
	{
		_name = [name copy];
		_url = url;
		_document = document;
		_utf8 = [utf8 copy];
		_range = range;
	}
	return self;
}
@end

@interface EditorSearchMatch ()
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, weak) EditorDocument *document;
@property(nonatomic) NSUInteger line;
@property(nonatomic) NSRange byteRange;
@property(nonatomic, copy) NSString *lineText;
@property(nonatomic) NSRange highlight;
@property(nonatomic, strong) NSData *matchedBytes;
@property(nonatomic, strong) NSData *replacementBytes;
@end
@implementation EditorSearchMatch
@end

@interface EditorSearchFile ()
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, weak) EditorDocument *document;
@property(nonatomic, copy) NSArray<EditorSearchMatch *> *matches;
@property(nonatomic) BOOL fromOpenBuffer;
@property(nonatomic, strong) NSData *originalUTF8;
@property(nonatomic, strong) NSData *originalDiskData;
@property(nonatomic) NSStringEncoding encoding;
@property(nonatomic, strong) NSData *bom;
@end

@interface EditorSearchReport ()
@property(nonatomic, copy) NSString *query;
@property(nonatomic, copy) NSArray<EditorSearchFile *> *files;
@property(nonatomic) NSUInteger searchedFiles;
@property(nonatomic) NSUInteger skippedFiles;
@property(nonatomic) NSUInteger hits;
@end
@implementation EditorSearchReport
- (void)discardReplacementSnapshots
{
	for (EditorSearchFile *file in self.files)
	{
		file.originalDiskData = nil;
		file.originalUTF8 = nil;
		for (EditorSearchMatch *match in file.matches)
			match.replacementBytes = nil;
	}
}
@end

NSArray<EditorSearchReport *> *SearchReportsRemovingRows(NSArray<EditorSearchReport *> *reports, NSSet *rows)
{
	NSMutableArray *remaining = [NSMutableArray array];
	for (EditorSearchReport *report in reports)
	{
		if ([rows containsObject:report])
			continue;
		NSMutableArray *files = [NSMutableArray array];
		NSUInteger count = 0;
		for (EditorSearchFile *file in report.files)
		{
			if ([rows containsObject:file])
				continue;
			NSMutableArray *matches = [NSMutableArray array];
			for (EditorSearchMatch *match in file.matches)
				if (![rows containsObject:match])
					[matches addObject:match];
			if (!matches.count)
				continue;
			if (matches.count == file.matches.count)
				[files addObject:file];
			else
			{
				EditorSearchFile *copy = [EditorSearchFile new];
				copy.name = file.name;
				copy.url = file.url;
				copy.document = file.document;
				copy.matches = matches;
				[files addObject:copy];
			}
			count += matches.count;
		}
		if (count == report.hits)
			[remaining addObject:report];
		else
		{
			EditorSearchReport *copy = [EditorSearchReport new];
			copy.query = report.query;
			copy.files = files;
			copy.searchedFiles = report.searchedFiles;
			copy.skippedFiles = report.skippedFiles;
			copy.hits = count;
			[remaining addObject:copy];
		}
	}
	return remaining;
}

// The upstream Boost.Regex adapter keeps its last diagnostic in a process-wide string.
static std::mutex RegexMutex;

std::shared_ptr<Scintilla::Internal::Document> EditorSearchBuffer(NSData *utf8)
{
	using namespace Scintilla;
	auto buffer = std::make_shared<Internal::Document>(DocumentOption::StylesNone);
	buffer->SetDBCSCodePage(SC_CP_UTF8);
	buffer->SetCaseFolder(std::make_unique<Internal::CaseFolderUnicode>());
	buffer->SetUndoCollection(false);
	buffer->InsertString(0, static_cast<const char *>(utf8.bytes), utf8.length);
	return buffer;
}

NSRange EditorFindPattern(Scintilla::Internal::Document &buffer, const char *expression, NSRange range)
{
	if (!*expression || !range.length)
		return NSMakeRange(NSNotFound, 0);
	using namespace Scintilla;
	Sci::Position length = strlen(expression);
	constexpr auto flags = static_cast<FindOption>(SCFIND_REGEXP | SCFIND_POSIX | SCFIND_REGEXP_DOTMATCHESNL);
	std::lock_guard lock(RegexMutex);
	const auto start = buffer.FindText(range.location, NSMaxRange(range), expression, flags, &length);
	if (start < 0 || start + length > NSMaxRange(range))
		return NSMakeRange(NSNotFound, 0);
	return NSMakeRange(start, length);
}

NSInteger SearchEditorFromAnchor(ScintillaView *editor, unsigned int message, NSUInteger flags, NSInteger text)
{
	std::unique_lock lock(RegexMutex, std::defer_lock);
	if (flags & SCFIND_REGEXP)
		lock.lock();
	return [editor message:message wParam:flags lParam:text];
}

NSInteger SearchEditorTarget(ScintillaView *editor, NSString *query, NSUInteger flags)
{
	[editor message:SCI_SETSEARCHFLAGS wParam:flags];
	std::unique_lock lock(RegexMutex, std::defer_lock);
	if (flags & SCFIND_REGEXP)
		lock.lock();
	return [editor message:SCI_SEARCHINTARGET wParam:[query lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
		lParam:reinterpret_cast<sptr_t>(query.UTF8String)];
}

static NSError *SearchError(NSURL *url, NSInteger code, NSString *description)
{
	return [NSError errorWithDomain:NSCocoaErrorDomain code:code userInfo:url ?
		@{NSURLErrorKey: url, NSLocalizedDescriptionKey: description} : @{NSLocalizedDescriptionKey: description}];
}

@implementation EditorSearchFile
- (BOOL)replaceOnDisk:(NSError **)error
{
	if (self.fromOpenBuffer || !self.originalDiskData || !self.matches.firstObject.replacementBytes)
	{
		if (error)
			*error = SearchError(self.url, NSFileWriteUnknownError, @"The open buffer changed or closed after the search.");
		return NO;
	}
	const char *source = static_cast<const char *>(self.originalUTF8.bytes);
	NSMutableData *result = [NSMutableData data];
	NSUInteger position = 0;
	for (EditorSearchMatch *match in self.matches)
	{
		if (match.byteRange.location > position)
			[result appendBytes:source + position length:match.byteRange.location - position];
		[result appendData:match.replacementBytes];
		position = NSMaxRange(match.byteRange);
	}
	if (position < self.originalUTF8.length)
		[result appendBytes:source + position length:self.originalUTF8.length - position];
	NSData *output = EncodeEditorText(result, self.encoding, self.bom);
	if (!output)
	{
		if (error)
			*error = SearchError(self.url, NSFileWriteInapplicableStringEncodingError, @"The existing file encoding cannot represent the replacement.");
		return NO;
	}

	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	NSError *coordinationError = nil;
	__block NSError *failure = nil;
	__block BOOL written = NO;
	[coordinator coordinateWritingItemAtURL:self.url options:NSFileCoordinatorWritingForReplacing
		error:&coordinationError byAccessor:^(NSURL *url) {
			NSNumber *link = nil;
			NSNumber *regular = nil;
			if (![url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:&failure] ||
				![url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:&failure])
				return;
			NSData *current = !link.boolValue && regular.boolValue ? [NSData dataWithContentsOfURL:url options:0 error:&failure] : nil;
			if (![current isEqualToData:self.originalDiskData])
			{
				if (!failure)
					failure = SearchError(url, NSFileWriteUnknownError, @"The file changed after the search.");
				return;
			}
			written = [output writeToURL:url options:NSDataWritingAtomic error:&failure];
		}];
	if (!written && error)
		*error = failure ?: coordinationError;
	return written;
}
@end

struct SearchFilters
{
	std::vector<std::string> include;
	std::vector<std::string> exclude;
	std::vector<std::string> excludeDirectory;
	std::vector<std::string> excludeRootDirectory;

	explicit SearchFilters(NSString *input)
	{
		NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@" ;\t\r\n"];
		for (NSString *part in [input componentsSeparatedByCharactersInSet:separators])
		{
			std::string_view name = part.UTF8String;
			if (name.starts_with("!+\\") || name.starts_with("!+/"))
				excludeDirectory.emplace_back(name.substr(3));
			else if (name.starts_with("!\\") || name.starts_with("!/"))
				excludeRootDirectory.emplace_back(name.substr(2));
			else if (name.starts_with("!+"))
				excludeDirectory.emplace_back(name.substr(2));
			else if (name.starts_with("!"))
				exclude.emplace_back(name.substr(1));
			else if (!name.empty())
				include.emplace_back(name == "*.*" ? "*" : name);
		}
	}

	static bool matches(const std::vector<std::string> &patterns, NSString *name)
	{
		return std::any_of(patterns.begin(), patterns.end(), [name](const std::string &pattern) {
			return fnmatch(pattern.c_str(), name.UTF8String, FNM_CASEFOLD) == 0;
		});
	}
};

static NSString *Excerpt(NSData *data, Sci::Position start, Sci::Position end)
{
	if (end <= start)
		return @"";
	const char *bytes = static_cast<const char *>(data.bytes);
	return [[NSString alloc] initWithBytes:bytes + start length:end - start encoding:NSUTF8StringEncoding] ?: @"";
}

static NSArray<EditorSearchMatch *> *SearchSnapshot(NSURL *url, NSData *data, NSString *query, NSUInteger flags, NSString *replacement,
	NSRange range, NSIndexSet *lines, NSProgress *progress, NSError **error)
{
	using namespace Scintilla;
	const auto search = EditorSearchBuffer(data);
	Internal::Document &buffer = *search;
	const auto length = static_cast<Sci::Position>(range.location == NSNotFound ? buffer.Length() : MIN(NSMaxRange(range), buffer.Length()));
	const auto queryLength = [query lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	const char *pattern = query.UTF8String;
	NSData *literal = [replacement dataUsingEncoding:NSUTF8StringEncoding];
	NSMutableArray<EditorSearchMatch *> *matches = [NSMutableArray array];
	for (Sci::Position position = range.location == NSNotFound ? 0 : range.location; position <= length && !progress.cancelled;)
	{
		Sci::Position matchLength = queryLength;
		Sci::Position found = -1;
		NSData *replacementBytes = literal;
		{
			std::unique_lock lock(RegexMutex, std::defer_lock);
			if (flags & SCFIND_REGEXP)
				lock.lock();
			found = buffer.FindText(position, length, pattern, static_cast<FindOption>(flags), &matchLength);
			if (literal && found >= 0 && (flags & SCFIND_REGEXP))
			{
				Sci::Position resultLength = literal.length;
				try
				{
					const char *result = buffer.SubstituteByPosition(replacement.UTF8String, &resultLength);
					replacementBytes = result ? [NSData dataWithBytes:result length:resultLength] : nil;
				}
				catch (const std::exception &)
				{
					replacementBytes = nil;
				}
			}
		}
		if (found < -1)
		{
			if (error)
				*error = SearchError(url, NSFileReadUnknownError,
					found == -2 ? @"Invalid regular expression." : @"The regular expression could not finish searching this file.");
			return nil;
		}
		if (found < 0)
			break;
		if (literal && !replacementBytes)
		{
			if (error)
				*error = SearchError(url, NSFileWriteUnknownError, @"The replacement expression could not be expanded.");
			return nil;
		}
		const auto line = buffer.SciLineFromPosition(found);
		const auto lineStart = buffer.LineStart(line);
		const auto lineEnd = buffer.LineEnd(line);
		if (lines && (![lines containsIndex:line] || found + matchLength > lineEnd))
		{
			if (!matchLength && found == length)
				break;
			position = matchLength ? found + matchLength : buffer.NextPosition(found, 1);
			continue;
		}
		const auto contextStart = buffer.MovePositionOutsideChar(std::max(lineStart, found - 100), 1, false);
		const auto contextEnd = buffer.MovePositionOutsideChar(std::min(lineEnd, found + 360), -1, false);
		NSString *prefix = Excerpt(data, contextStart, found);
		NSString *ellipsis = contextStart > lineStart ? @"…" : @"";
		EditorSearchMatch *match = [[EditorSearchMatch alloc] init];
		match.url = url;
		match.line = line + 1;
		match.byteRange = NSMakeRange(found, matchLength);
		match.matchedBytes = [data subdataWithRange:match.byteRange];
		match.replacementBytes = replacementBytes;
		match.lineText = [NSString stringWithFormat:@"%@%@%@", ellipsis, Excerpt(data, contextStart, contextEnd),
			contextEnd < lineEnd ? @"…" : @""];
		match.highlight = NSMakeRange(MIN(match.lineText.length, ellipsis.length + prefix.length),
			Excerpt(data, found, std::min(contextEnd, found + matchLength)).length);
		[matches addObject:match];
		if (!matchLength && found == length)
			break;
		position = matchLength ? found + matchLength : buffer.NextPosition(found, 1);
	}
	return matches;
}

EditorSearchReport *SearchDirectory(NSURL *directory, NSString *query, NSString *filters, NSUInteger flags,
	BOOL recursive, BOOL includeHidden, NSDictionary<NSURL *, NSData *> *openFiles, NSString *replacement, NSProgress *progress, NSError **error)
{
	NSNumber *isDirectory = nil;
	if (!directory.isFileURL || !query.length || ![directory getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:error] ||
		!isDirectory.boolValue)
	{
		if (error && !*error)
			*error = SearchError(directory, NSFileReadNoSuchFileError, @"Choose an existing folder and enter text to find.");
		return nil;
	}
	SearchFilters patterns(filters);
	EditorSearchReport *report = [[EditorSearchReport alloc] init];
	report.query = query;
	NSMutableArray<EditorSearchFile *> *files = [NSMutableArray array];
	NSDirectoryEnumerationOptions options = recursive ? 0 : NSDirectoryEnumerationSkipsSubdirectoryDescendants;
	if (!includeHidden)
		options |= NSDirectoryEnumerationSkipsHiddenFiles;
	NSArray *keys = @[NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey];
	NSDirectoryEnumerator<NSURL *> *entries = [[NSFileManager defaultManager] enumeratorAtURL:directory
		includingPropertiesForKeys:keys options:options errorHandler:^BOOL(NSURL *url, NSError *failure) {
			++report.skippedFiles;
			return !progress.cancelled;
		}];
	NSError *failure = nil;
	for (NSURL *url in entries)
	{
		if (progress.cancelled)
			return nil;
		@autoreleasepool
		{
			NSDictionary *properties = [url resourceValuesForKeys:keys error:nullptr];
			if ([properties[NSURLIsDirectoryKey] boolValue] &&
				(SearchFilters::matches(patterns.excludeDirectory, url.lastPathComponent) ||
					(entries.level == 1 && SearchFilters::matches(patterns.excludeRootDirectory, url.lastPathComponent))))
				[entries skipDescendants];
			if (![properties[NSURLIsRegularFileKey] boolValue] || [properties[NSURLIsSymbolicLinkKey] boolValue] ||
				SearchFilters::matches(patterns.exclude, url.lastPathComponent) ||
				(!patterns.include.empty() && !SearchFilters::matches(patterns.include, url.lastPathComponent)))
				continue;
			NSData *utf8 = openFiles[url.URLByStandardizingPath];
			BOOL fromOpenBuffer = utf8 != nil;
			NSData *raw = nil;
			NSData *bom = nil;
			NSStringEncoding encoding = NSUTF8StringEncoding;
			if (!utf8)
			{
				// Replacement needs an immutable disk snapshot for the final content check.
				raw = [NSData dataWithContentsOfURL:url options:replacement ? 0 : NSDataReadingMappedIfSafe error:nullptr];
				utf8 = [DecodeEditorText(raw, &encoding, &bom) dataUsingEncoding:NSUTF8StringEncoding];
			}
			if (!utf8)
			{
				++report.skippedFiles;
				continue;
			}
			++report.searchedFiles;
			NSArray<EditorSearchMatch *> *matches = SearchSnapshot(url, utf8, query, flags, replacement,
				NSMakeRange(NSNotFound, 0), nil, progress, &failure);
			if (!matches)
				break;
			if (matches.count)
			{
				EditorSearchFile *file = [[EditorSearchFile alloc] init];
				file.name = url.path;
				file.url = url;
				file.matches = matches;
				if (replacement)
				{
					file.fromOpenBuffer = fromOpenBuffer;
					file.originalUTF8 = utf8;
					file.originalDiskData = raw;
					file.encoding = encoding;
					file.bom = bom;
				}
				[files addObject:file];
				report.hits += matches.count;
			}
		}
	}
	if (failure)
	{
		if (error)
			*error = failure;
		return nil;
	}
	report.files = [files sortedArrayUsingComparator:^NSComparisonResult(EditorSearchFile *a, EditorSearchFile *b) {
		return [a.name localizedStandardCompare:b.name];
	}];
	return progress.cancelled ? nil : report;
}

EditorSearchReport *SearchSources(NSArray<EditorSearchSource *> *sources, NSString *query, NSString *filters,
	NSUInteger flags, NSString *replacement, NSProgress *progress, NSError **error)
{
	SearchFilters patterns(filters ?: @"");
	EditorSearchReport *report = [EditorSearchReport new];
	report.query = query;
	NSMutableArray<EditorSearchFile *> *files = [NSMutableArray array];
	for (EditorSearchSource *source in sources)
	{
		if (progress.cancelled)
			return nil;
		@autoreleasepool
		{
			NSString *name = source.url.lastPathComponent ?: source.name;
			if (SearchFilters::matches(patterns.exclude, name) ||
				(!patterns.include.empty() && !SearchFilters::matches(patterns.include, name)))
				continue;
			NSData *utf8 = source.utf8;
			NSData *raw = nil;
			NSData *bom = nil;
			NSStringEncoding encoding = NSUTF8StringEncoding;
			if (!utf8)
			{
				NSNumber *regular = nil, *link = nil;
				[source.url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nullptr];
				[source.url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nullptr];
				if (regular.boolValue && !link.boolValue)
					raw = [NSData dataWithContentsOfURL:source.url options:replacement ? 0 : NSDataReadingMappedIfSafe error:nullptr];
				utf8 = [DecodeEditorText(raw, &encoding, &bom) dataUsingEncoding:NSUTF8StringEncoding];
			}
			if (!utf8)
			{
				++report.skippedFiles;
				continue;
			}
			++report.searchedFiles;
			NSArray<EditorSearchMatch *> *matches = SearchSnapshot(source.url, utf8, query, flags, replacement, source.range, source.lines, progress, error);
			if (!matches)
				return nil;
			if (!matches.count)
				continue;
			for (EditorSearchMatch *match in matches)
				match.document = source.document;
			EditorSearchFile *file = [EditorSearchFile new];
			file.name = source.name;
			file.url = source.url;
			file.document = source.document;
			file.matches = matches;
			file.fromOpenBuffer = source.utf8 != nil;
			if (replacement)
			{
				file.originalUTF8 = utf8;
				file.originalDiskData = raw;
				file.encoding = encoding;
				file.bom = bom;
			}
			[files addObject:file];
			report.hits += matches.count;
		}
	}
	report.files = files;
	return progress.cancelled ? nil : report;
}

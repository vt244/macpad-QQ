// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#include <memory>

namespace Scintilla::Internal { class Document; }

std::shared_ptr<Scintilla::Internal::Document> EditorSearchBuffer(NSData *utf8);
NSRange EditorFindPattern(Scintilla::Internal::Document &buffer, const char *expression, NSRange range);

// SPDX-License-Identifier: GPL-3.0-only
#ifndef MACPAD_PLUGIN_H
#define MACPAD_PLUGIN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MACPAD_PLUGIN_ABI_VERSION 1

typedef struct MacpadEditorV1
{
	void *context;
	// Returns the required byte count without a terminator and copies up to capacity bytes.
	size_t (*copySelection)(void *context, char *buffer, size_t capacity);
	// Returns 1 on success. Text must be valid UTF-8. Both callbacks are valid only during run().
	int (*replaceSelection)(void *context, const char *utf8, size_t length);
} MacpadEditorV1;

typedef struct MacpadPluginV1
{
	uint32_t version;
	const char *title;
	void (*run)(const MacpadEditorV1 *editor);
} MacpadPluginV1;

typedef const MacpadPluginV1 *(*MacpadPluginEntry)(void);

// Export this symbol from the macOS dylib.
const MacpadPluginV1 *macpad_plugin(void);

#ifdef __cplusplus
}
#endif
#endif

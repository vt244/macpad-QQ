// SPDX-License-Identifier: GPL-3.0-only
#include "MacpadPlugin.h"

static void Run(const MacpadEditorV1 *editor)
{
	char selected[8];
	if (editor->copySelection(editor->context, selected, sizeof(selected)) == 3 &&
		selected[0] == 'd' && selected[1] == 'e' && selected[2] == 'f')
		editor->replaceSelection(editor->context, "class", 5);
}

const MacpadPluginV1 *macpad_plugin(void)
{
	static const MacpadPluginV1 plugin = {MACPAD_PLUGIN_ABI_VERSION, "Smoke: Replace Selection", Run};
	return &plugin;
}

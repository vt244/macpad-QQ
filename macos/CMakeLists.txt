# SPDX-License-Identifier: GPL-3.0-only
cmake_minimum_required(VERSION 3.20)
project(macpad LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD 20)
set(root "${CMAKE_CURRENT_LIST_DIR}/..")
set(sci "${root}/scintilla")
set(lex "${root}/lexilla")
file(GLOB scintilla_sources CONFIGURE_DEPENDS "${sci}/src/*.cxx" "${sci}/cocoa/*.mm")
file(GLOB lexilla_sources CONFIGURE_DEPENDS "${lex}/lexlib/*.cxx" "${lex}/lexers/Lex*.cxx")

# The upstream UDL lexer uses Win32. Drop its entry from the generated registry
# for this target while keeping the vendored sources intact.
list(FILTER lexilla_sources EXCLUDE REGEX "/LexUser[.]cxx$")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${lex}/src/Lexilla.cxx")
file(READ "${lex}/src/Lexilla.cxx" registry)
string(REGEX REPLACE "[^\n]*lmUserDefine[^\n]*\n" "" registry "${registry}")
file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/Lexilla.cxx" CONTENT "${registry}")

add_library(editor STATIC ${scintilla_sources} ${lexilla_sources} "${CMAKE_CURRENT_BINARY_DIR}/Lexilla.cxx"
	"${root}/boostregex/BoostRegExSearch.cxx" "${root}/boostregex/UTF8DocumentIterator.cxx")
target_compile_definitions(editor PRIVATE SCI_OWNREGEX BOOST_REGEX_STANDALONE)
target_compile_options(editor PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_include_directories(editor PUBLIC "${sci}/include" "${sci}/cocoa" "${lex}/include")
target_include_directories(editor PRIVATE "${sci}/src" "${lex}/lexlib" "${root}/boostregex")

add_executable(macpad macos-main.mm EditorDocument.mm EditorChrome.mm EditorResources.mm EditorPlugins.mm EditorSmoke.mm
	EditorText.mm EditorFileSearch.mm EditorSearchResultsView.mm
	EditorDocumentList.mm EditorPanelChrome.mm EditorContextMenus.mm EditorDock.mm EditorFolderPanel.mm EditorProjectPanel.mm
	EditorIncrementalSearch.mm
	)
set_target_properties(macpad PROPERTIES OUTPUT_NAME "macpad++")
target_compile_options(macpad PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_include_directories(macpad PRIVATE "${root}/PowerEditor/src/pugixml" "${sci}/src")
target_link_libraries(macpad PRIVATE editor "-framework Cocoa" "-framework QuartzCore" "-framework CoreText"
	"-framework CoreGraphics" "-framework UniformTypeIdentifiers")

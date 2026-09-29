# Lists client/bin/marque.gdextension in client/.godot/extension_list.cfg.
#
# Godot loads the extensions in that list during startup. An extension missing
# from it is found by the editor's first filesystem scan and loaded mid-scan,
# which makes Godot 4.7 regenerate its docs on a worker thread. When the editor
# quits before that worker finishes (a short headless --import), the worker's
# deferred EditorHelp::_gen_extensions_docs runs after the docs are freed and
# the editor segfaults (godotengine/godot#111645). Listing the extension up
# front removes the mid-scan load.

set(list_file "${CLIENT_DIR}/.godot/extension_list.cfg")
set(entry "res://bin/marque.gdextension")

if(EXISTS "${list_file}")
    file(STRINGS "${list_file}" entries)
    if(entry IN_LIST entries)
        return()
    endif()
endif()

file(MAKE_DIRECTORY "${CLIENT_DIR}/.godot")
file(APPEND "${list_file}" "${entry}\n")

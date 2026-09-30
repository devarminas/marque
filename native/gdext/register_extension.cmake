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

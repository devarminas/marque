cmake_minimum_required(VERSION 3.28)
project(marque_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# marque_core: engine-independent library. Sources are globbed so adding a
# .cpp under core/src needs no edit here; CONFIGURE_DEPENDS reruns the glob
# when the build system reconfigures.
file(GLOB_RECURSE MARQUE_CORE_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/core/src/*.cpp")

add_library(marque_core STATIC ${MARQUE_CORE_SOURCES})
target_include_directories(marque_core PUBLIC core/include)
target_compile_options(marque_core PRIVATE -Wall -Wextra -Werror)

enable_testing()

# Every core/tests/*.cpp becomes its own ctest executable named after its
# file stem. Adding a test file needs no edit here either.
file(GLOB MARQUE_CORE_TEST_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/core/tests/*.cpp")

foreach(test_source ${MARQUE_CORE_TEST_SOURCES})
    get_filename_component(test_name ${test_source} NAME_WE)
    add_executable(${test_name} ${test_source})
    target_link_libraries(${test_name} PRIVATE marque_core)
    target_compile_options(${test_name} PRIVATE -Wall -Wextra -Werror)
    add_test(NAME ${test_name} COMMAND ${test_name})
endforeach()

# marque_gdext: the GDExtension binding Godot loads from client/bin. godot-cpp
# is pinned by commit hash; it bundles the 4.7 extension API, matching
# compatibility_minimum in client/bin/marque.gdextension.
include(FetchContent)
set(GODOTCPP_API_VERSION "4.7" CACHE STRING "")
FetchContent_Declare(godot-cpp
    GIT_REPOSITORY https://github.com/godotengine/godot-cpp.git
    GIT_TAG 507ed9d840c01a3c5b2a39af8bb4000bfac30bf5
    SYSTEM)
FetchContent_MakeAvailable(godot-cpp)

file(GLOB_RECURSE MARQUE_GDEXT_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/gdext/src/*.cpp")

add_library(marque_gdext SHARED ${MARQUE_GDEXT_SOURCES})
target_link_libraries(marque_gdext PRIVATE marque_core godot-cpp)
target_compile_options(marque_gdext PRIVATE -Wall -Wextra -Werror)
get_target_property(GODOTCPP_SUFFIX godot-cpp GODOTCPP_SUFFIX)
set_target_properties(marque_gdext PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    PREFIX "lib"
    OUTPUT_NAME "marque${GODOTCPP_SUFFIX}"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../client/bin")

add_custom_target(marque_gdext_register ALL
    COMMAND ${CMAKE_COMMAND} -DCLIENT_DIR=${CMAKE_CURRENT_SOURCE_DIR}/../client
        -P ${CMAKE_CURRENT_SOURCE_DIR}/gdext/register_extension.cmake
    DEPENDS marque_gdext
    VERBATIM)

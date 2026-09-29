cmake_minimum_required(VERSION 3.28)
project(marque_proto LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(marque_core STATIC core/src/world.cpp)
target_include_directories(marque_core PUBLIC core/include)
target_compile_options(marque_core PRIVATE -Wall -Wextra -Werror)

enable_testing()
add_executable(marque_core_tests core/tests/test_world.cpp)
target_link_libraries(marque_core_tests PRIVATE marque_core)
add_test(NAME core COMMAND marque_core_tests)

set(GODOTCPP_CUSTOM_API_FILE "${CMAKE_CURRENT_SOURCE_DIR}/api/extension_api.json" CACHE FILEPATH "" FORCE)
add_subdirectory(godot-cpp)

add_library(marque_gdext SHARED gdext/src/world_client.cpp gdext/src/register_types.cpp)
target_link_libraries(marque_gdext PRIVATE marque_core godot-cpp)
get_target_property(GODOTCPP_SUFFIX godot-cpp GODOTCPP_SUFFIX)
set_target_properties(marque_gdext PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    PREFIX "lib"
    OUTPUT_NAME "marque${GODOTCPP_SUFFIX}"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/project/bin")

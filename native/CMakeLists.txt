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

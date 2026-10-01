cmake_minimum_required(VERSION 3.28)
project(marque_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(MARQUE_FUZZ "Build libFuzzer targets for the wire decoders (clang only)" OFF)
if(MARQUE_FUZZ)
    if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        message(FATAL_ERROR "MARQUE_FUZZ needs clang; configure with CXX=clang++")
    endif()
    add_compile_options(-fsanitize=fuzzer-no-link,address,undefined -fno-sanitize-recover=undefined -g -O1)
    add_link_options(-fsanitize=address,undefined)
endif()

# marque_core: engine-independent library. Sources are globbed so adding a
# .cpp under core/src needs no edit here; CONFIGURE_DEPENDS reruns the glob
# when the build system reconfigures.
file(GLOB_RECURSE MARQUE_CORE_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/core/src/*.cpp")

if(CMAKE_BUILD_TYPE MATCHES "^(Release|MinSizeRel|RelWithDebInfo)$")
    set(MARQUE_DEV_ISSUER_DEFAULT OFF)
else()
    set(MARQUE_DEV_ISSUER_DEFAULT ON)
endif()
option(MARQUE_DEV_ISSUER "Build the development connect-token issuer and its fixed key" ${MARQUE_DEV_ISSUER_DEFAULT})
if(NOT MARQUE_DEV_ISSUER)
    list(FILTER MARQUE_CORE_SOURCES EXCLUDE REGEX "/core/src/transport/dev/")
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(SODIUM REQUIRED IMPORTED_TARGET libsodium)

add_library(marque_core STATIC ${MARQUE_CORE_SOURCES})
target_include_directories(marque_core PUBLIC core/include)
target_compile_options(marque_core PRIVATE -Wall -Wextra -Werror)
target_link_libraries(marque_core PUBLIC PkgConfig::SODIUM)

enable_testing()

file(GLOB MARQUE_CORE_TEST_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/core/tests/*.cpp")
if(NOT MARQUE_DEV_ISSUER)
    list(FILTER MARQUE_CORE_TEST_SOURCES EXCLUDE REGEX "dev_issuer")
endif()

foreach(test_source ${MARQUE_CORE_TEST_SOURCES})
    get_filename_component(test_name ${test_source} NAME_WE)
    add_executable(${test_name} ${test_source})
    target_link_libraries(${test_name} PRIVATE marque_core)
    target_compile_options(${test_name} PRIVATE -Wall -Wextra -Werror)
    add_test(NAME ${test_name} COMMAND ${test_name})
endforeach()

if(MARQUE_FUZZ)
    add_subdirectory(fuzz)
endif()

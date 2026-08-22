cmake_minimum_required(VERSION 3.15)
project(retune_driver LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Point this to the cloned libASPL repo
set(LIBASPL_DIR "${CMAKE_CURRENT_LIST_DIR}/../ref-repos/libASPL")

add_subdirectory(${LIBASPL_DIR} libaspl_build EXCLUDE_FROM_ALL)

add_library(retune_driver SHARED
    src/EntryPoint.cpp
)

# Build a HAL plugin bundle
set_target_properties(retune_driver PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION "driver"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_LIST_DIR}/Info.plist"
)

target_include_directories(retune_driver PRIVATE
    ${LIBASPL_DIR}/include
)

target_link_libraries(retune_driver PRIVATE aspl)

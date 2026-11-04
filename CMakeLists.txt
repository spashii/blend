cmake_minimum_required(VERSION 3.24)

set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0 CACHE STRING "")
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "")

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" BLEND_VERSION LIMIT_COUNT 1)
project(Blend VERSION ${BLEND_VERSION} LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

option(BLEND_BUILD_SPIKES "Build the test tools in spikes/" ON)

# Ad hoc signing by default, which runs on the Mac that built it. tools/build.sh passes a
# stable development identity so macOS privacy grants survive rebuilds; tools/release.sh
# passes a Developer ID with the hardened runtime and a timestamp.
set(BLEND_CODESIGN_ID "-" CACHE STRING "Code signing identity; empty to skip signing")
set(BLEND_KEYCHAIN "" CACHE FILEPATH "Keychain holding the signing identity, if not the default")
set(BLEND_CODESIGN_FLAGS "" CACHE STRING "Extra codesign flags")

function(blend_codesign target path)
  if(BLEND_CODESIGN_ID STREQUAL "")
    return()
  endif()
  set(keychain)
  if(BLEND_KEYCHAIN)
    set(keychain --keychain "${BLEND_KEYCHAIN}")
  endif()
  separate_arguments(flags UNIX_COMMAND "${BLEND_CODESIGN_FLAGS}")
  add_custom_command(TARGET ${target} POST_BUILD
    COMMAND codesign --force --sign "${BLEND_CODESIGN_ID}" ${keychain} ${flags} ${ARGN} "${path}"
    VERBATIM)
endfunction()

enable_testing()
add_subdirectory(driver)
add_subdirectory(engine)
if(BLEND_BUILD_SPIKES)
  add_subdirectory(spikes/lab)
endif()

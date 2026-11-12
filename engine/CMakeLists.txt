include(FetchContent)
FetchContent_Declare(json
  URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(json)

# WebRTC's audio processing (echo cancellation), as packaged by freedesktop.org and built
# with Meson. Its abseil dependency is always built from source, never taken from the
# system, so Blend.app depends on nothing outside its bundle. Everything ends up in one
# archive, libwebrtc-apm.a, which kit/CMakeLists.txt merges with libBlendEngine.a into the
# XCFramework the app links.
include(ExternalProject)
set(WEBRTC_PREFIX "${CMAKE_BINARY_DIR}/webrtc")
set(WEBRTC_SOURCE "${CMAKE_BINARY_DIR}/webrtc-src")
set(WEBRTC_LIB "${WEBRTC_PREFIX}/lib/libwebrtc-apm.a")
set(WEBRTC_ENV ${CMAKE_COMMAND} -E env MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET})
ExternalProject_Add(webrtc_ext
  GIT_REPOSITORY https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git
  GIT_TAG v2.1
  GIT_SHALLOW TRUE
  UPDATE_DISCONNECTED TRUE
  SOURCE_DIR "${WEBRTC_SOURCE}"
  INSTALL_DIR "${WEBRTC_PREFIX}"
  CONFIGURE_COMMAND ${WEBRTC_ENV} meson setup <BINARY_DIR> <SOURCE_DIR>
    --prefix=<INSTALL_DIR> --libdir=lib --buildtype=release --default-library=static
    -Db_ndebug=true -Dcpp_std=c++17 --force-fallback-for=abseil-cpp
  BUILD_COMMAND ${WEBRTC_ENV} ninja -C <BINARY_DIR>
  INSTALL_COMMAND ${WEBRTC_ENV} meson install -C <BINARY_DIR> --quiet
    COMMAND ${CMAKE_COMMAND} -DPREFIX=<INSTALL_DIR> -DBUILD=<BINARY_DIR> -DSOURCE=<SOURCE_DIR>
      -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/MergeWebRTC.cmake
  BUILD_BYPRODUCTS "${WEBRTC_LIB}")
# Imported targets need their include folders to exist before the first build.
file(MAKE_DIRECTORY "${WEBRTC_PREFIX}/include/webrtc-audio-processing-2")
add_library(webrtc_apm STATIC IMPORTED GLOBAL)
set_target_properties(webrtc_apm PROPERTIES IMPORTED_LOCATION "${WEBRTC_LIB}")
target_include_directories(webrtc_apm INTERFACE
  "${WEBRTC_PREFIX}/include/webrtc-audio-processing-2" "${WEBRTC_PREFIX}/include")
target_compile_definitions(webrtc_apm INTERFACE WEBRTC_POSIX WEBRTC_MAC)
add_dependencies(webrtc_apm webrtc_ext)

# AddressSanitizer for the engine and its tests: cmake -DBLEND_ASAN=ON. WebRTC stays as built.
option(BLEND_ASAN "Build the engine and its tests with AddressSanitizer" OFF)
if(BLEND_ASAN)
  add_compile_options(-fsanitize=address -fno-omit-frame-pointer)
  add_link_options(-fsanitize=address)
endif()

add_library(BlendEngine STATIC
  src/Apps.mm
  src/BlendEngine.mm
  src/BlendKit.mm
  src/CallCapture.mm
  src/CallPipeline.cpp
  src/Config.cpp
  src/Engine.mm
  src/MicCapture.mm
  src/MicProcessor.mm
  src/ProcessTap.mm
  src/Probes.mm
  src/Sources.mm)
target_include_directories(BlendEngine PUBLIC include PRIVATE src)
# BKVersion reports the Blend release the library was built from.
set_source_files_properties(src/BlendKit.mm PROPERTIES
  COMPILE_DEFINITIONS "BLEND_KIT_VERSION=\"${BLEND_VERSION}\"")
target_compile_options(BlendEngine PRIVATE
  $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
  -Wall -Wextra -Wno-unused-parameter)
target_link_libraries(BlendEngine
  PRIVATE nlohmann_json::nlohmann_json webrtc_apm
  PUBLIC "-framework CoreAudio" "-framework AudioToolbox" "-framework Foundation"
    "-framework AppKit")

add_executable(BlendDspTests tests/DspTests.cpp)
add_test(NAME dsp COMMAND BlendDspTests)

# Not a test: CPU of a mix block with ducking on and off, run by hand.
add_executable(BlendDuckBench tests/DuckBench.cpp)

add_executable(BlendConfigTests tests/ConfigTests.cpp src/Config.cpp)
target_include_directories(BlendConfigTests PRIVATE src)
target_link_libraries(BlendConfigTests PRIVATE nlohmann_json::nlohmann_json)
add_test(NAME config COMMAND BlendConfigTests)

add_executable(BlendIdentityTests tests/IdentityTests.cpp)
target_link_libraries(BlendIdentityTests PRIVATE nlohmann_json::nlohmann_json)
file(GLOB BLEND_INVENTORIES ${CMAKE_SOURCE_DIR}/spikes/identity/data/*.json)
add_test(NAME identity COMMAND BlendIdentityTests ${BLEND_INVENTORIES})

add_executable(BlendProcessingTests tests/ProcessingTests.mm)
target_link_libraries(BlendProcessingTests PRIVATE BlendEngine)
target_compile_options(BlendProcessingTests PRIVATE -fobjc-arc)
add_test(NAME processing COMMAND BlendProcessingTests)

add_executable(BlendCaptureTests tests/CaptureTests.mm)
target_link_libraries(BlendCaptureTests PRIVATE BlendEngine)
target_compile_options(BlendCaptureTests PRIVATE -fobjc-arc)
add_test(NAME capture COMMAND BlendCaptureTests)

add_executable(BlendTimerTests tests/TimerTests.mm)
target_link_libraries(BlendTimerTests PRIVATE BlendEngine)
target_compile_options(BlendTimerTests PRIVATE -fobjc-arc)
add_test(NAME timer COMMAND BlendTimerTests)

add_executable(BlendKitTests tests/KitTests.mm)
target_link_libraries(BlendKitTests PRIVATE BlendEngine)
target_compile_options(BlendKitTests PRIVATE -fobjc-arc)
add_test(NAME kit COMMAND BlendKitTests)

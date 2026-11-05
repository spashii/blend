include(ExternalProject)

# libASPL's own build does not nest with add_subdirectory, so it is built as a separate
# project and installed into the build tree.
set(LIBASPL_PREFIX "${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix")
ExternalProject_Add(libASPL_ext
  GIT_REPOSITORY https://github.com/gavv/libASPL.git
  GIT_TAG v3.1.2
  GIT_SHALLOW TRUE
  INSTALL_DIR "${LIBASPL_PREFIX}"
  # Its custom commands confuse Ninja, so it always builds with Make.
  CMAKE_GENERATOR "Unix Makefiles"
  CMAKE_ARGS
    -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -Wno-dev
    -DCMAKE_OSX_ARCHITECTURES=${CMAKE_OSX_ARCHITECTURES}
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}
  BUILD_BYPRODUCTS "${LIBASPL_PREFIX}/lib/libASPL.a"
  UPDATE_DISCONNECTED TRUE)

# The driver keeps its own version, raised only when its code changes. Setup compares the
# installed driver with the bundled one by code directory hash, which covers this Info.plist,
# so following the app's version would ask every user to reinstall the driver on each release.
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" BLEND_DRIVER_VERSION LIMIT_COUNT 1)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION")

# MODULE gives a loadable Mach-O bundle; the properties below wrap it in the
# BlendDriver.driver directory that coreaudiod loads from /Library/Audio/Plug-Ins/HAL.
add_library(BlendDriver MODULE src/Driver.cpp)
add_dependencies(BlendDriver libASPL_ext)
target_include_directories(BlendDriver PRIVATE "${LIBASPL_PREFIX}/include")
target_link_libraries(BlendDriver PRIVATE
  "${LIBASPL_PREFIX}/lib/libASPL.a"
  "-framework CoreFoundation"
  "-framework CoreAudio")
set_target_properties(BlendDriver PROPERTIES
  OUTPUT_NAME "BlendDriver"
  BUNDLE TRUE
  BUNDLE_EXTENSION "driver"
  PREFIX ""
  SUFFIX ""
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "BlendDriver"
  MACOSX_BUNDLE_GUI_IDENTIFIER "app.blend.driver"
  MACOSX_BUNDLE_BUNDLE_VERSION "${BLEND_DRIVER_VERSION}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${BLEND_DRIVER_VERSION}")

blend_codesign(BlendDriver "${CMAKE_CURRENT_BINARY_DIR}/BlendDriver.driver")

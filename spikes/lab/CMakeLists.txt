add_executable(BlendLab MACOSX_BUNDLE Lab.mm)
target_compile_options(BlendLab PRIVATE -fobjc-arc -Wall -Wno-unused-parameter)
target_link_libraries(BlendLab PRIVATE
  BlendEngine
  "-framework Foundation"
  "-framework AppKit"
  "-framework AVFoundation"
  "-framework CoreAudio")
set_target_properties(BlendLab PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in")
blend_codesign(BlendLab "${CMAKE_CURRENT_BINARY_DIR}/BlendLab.app")

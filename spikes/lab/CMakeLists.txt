add_executable(BlendLab MACOSX_BUNDLE Lab.mm)
target_compile_options(BlendLab PRIVATE -fobjc-arc -Wall -Wno-unused-parameter)
# The call tap tests build captures and probes from the engine's own classes.
target_include_directories(BlendLab PRIVATE ${CMAKE_SOURCE_DIR}/engine/src)
target_link_libraries(BlendLab PRIVATE
  BlendEngine
  "-framework Foundation"
  "-framework AppKit"
  "-framework AVFoundation"
  "-framework CoreAudio")
set_target_properties(BlendLab PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in")
blend_codesign(BlendLab "${CMAKE_CURRENT_BINARY_DIR}/BlendLab.app")

# A stand-in call app for spikes/call-tap; it needs no permission.
add_executable(BlendLabSpeaker MACOSX_BUNDLE Speaker.mm)
target_compile_options(BlendLabSpeaker PRIVATE -fobjc-arc -Wall -Wno-unused-parameter)
target_link_libraries(BlendLabSpeaker PRIVATE
  "-framework Foundation"
  "-framework AppKit"
  "-framework AudioToolbox")
set_target_properties(BlendLabSpeaker PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Speaker.plist.in")
blend_codesign(BlendLabSpeaker "${CMAKE_CURRENT_BINARY_DIR}/BlendLabSpeaker.app")

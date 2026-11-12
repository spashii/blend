# BlendKitCore: the engine and WebRTC's audio processing as one static archive, wrapped as
# an XCFramework that the BlendKit Swift package links. Static, so everything ends up in
# the host app's own binary under its own signature and nothing has to be embedded.
#
# libBlendKitCore.a and the XCFramework build with everything else. The zip and its
# checksum, which a release publishes, are separate targets: BlendKitCoreZip.

set(KIT_BUILD "${CMAKE_BINARY_DIR}/kit")
set(KIT_LIBRARY "${KIT_BUILD}/libBlendKitCore.a")
set(KIT_HEADERS "${KIT_BUILD}/headers/BlendKitCore")
# kit/Package.swift points its binary target here; the folder is git-ignored.
set(KIT_XCFRAMEWORK "${CMAKE_CURRENT_SOURCE_DIR}/BlendKitCore.xcframework")
set(KIT_ZIP "${KIT_BUILD}/BlendKitCore-${BLEND_VERSION}.xcframework.zip")

add_custom_command(OUTPUT "${KIT_LIBRARY}"
  COMMAND ${CMAKE_COMMAND} -E make_directory "${KIT_BUILD}"
  COMMAND libtool -static -no_warning_for_no_symbols -o "${KIT_LIBRARY}"
    $<TARGET_FILE:BlendEngine> $<TARGET_FILE:webrtc_apm>
  DEPENDS BlendEngine webrtc_apm
  COMMENT "Merging the engine and WebRTC into libBlendKitCore.a"
  VERBATIM)

# The headers come from engine/include, so the C interface has one source.
set(KIT_HEADER_FILES
  "${KIT_HEADERS}/BlendEngine.h"
  "${KIT_HEADERS}/BlendKit.h"
  "${KIT_HEADERS}/module.modulemap")
add_custom_command(OUTPUT ${KIT_HEADER_FILES}
  COMMAND ${CMAKE_COMMAND} -E make_directory "${KIT_HEADERS}"
  COMMAND ${CMAKE_COMMAND} -E copy
    "${CMAKE_SOURCE_DIR}/engine/include/BlendEngine.h"
    "${CMAKE_SOURCE_DIR}/engine/include/BlendKit.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/include/BlendKitCore/module.modulemap"
    "${KIT_HEADERS}"
  DEPENDS "${CMAKE_SOURCE_DIR}/engine/include/BlendEngine.h"
    "${CMAKE_SOURCE_DIR}/engine/include/BlendKit.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/include/BlendKitCore/module.modulemap"
  VERBATIM)

add_custom_command(OUTPUT "${KIT_XCFRAMEWORK}/Info.plist"
  COMMAND ${CMAKE_COMMAND} -E rm -rf "${KIT_XCFRAMEWORK}"
  COMMAND xcodebuild -create-xcframework -library "${KIT_LIBRARY}" -headers "${KIT_BUILD}/headers"
    -output "${KIT_XCFRAMEWORK}"
  DEPENDS "${KIT_LIBRARY}" ${KIT_HEADER_FILES}
  COMMENT "Creating BlendKitCore.xcframework"
  VERBATIM)
add_custom_target(BlendKitCore ALL DEPENDS "${KIT_XCFRAMEWORK}/Info.plist")

# The release asset: the XCFramework with the licenses its contents require, and the
# checksum Package.swift pins.
add_custom_command(OUTPUT "${KIT_ZIP}" "${KIT_ZIP}.checksum"
  COMMAND ${CMAKE_COMMAND} -E rm -rf "${KIT_BUILD}/zip"
  COMMAND ${CMAKE_COMMAND} -E make_directory "${KIT_BUILD}/zip"
  COMMAND ditto "${KIT_XCFRAMEWORK}" "${KIT_BUILD}/zip/BlendKitCore.xcframework"
  COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_SOURCE_DIR}/LICENSE"
    "${CMAKE_CURRENT_SOURCE_DIR}/THIRD_PARTY_NOTICES.md" "${KIT_BUILD}/zip"
  COMMAND ${CMAKE_COMMAND} -E rm -f "${KIT_ZIP}"
  COMMAND ditto -c -k "${KIT_BUILD}/zip" "${KIT_ZIP}"
  COMMAND sh -c "swift package compute-checksum '${KIT_ZIP}' > '${KIT_ZIP}.checksum'"
  DEPENDS "${KIT_XCFRAMEWORK}/Info.plist" "${CMAKE_SOURCE_DIR}/LICENSE"
    "${CMAKE_CURRENT_SOURCE_DIR}/THIRD_PARTY_NOTICES.md"
  COMMENT "Zipping BlendKitCore.xcframework"
  VERBATIM)
add_custom_target(BlendKitCoreZip DEPENDS "${KIT_ZIP}")

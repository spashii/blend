# Run with cmake -P after webrtc-audio-processing is installed into PREFIX. Merges it and
# the abseil parts it was built with into one archive, and installs abseil's headers next
# to WebRTC's, since WebRTC's public headers include them.
#
# Variables: PREFIX (install prefix), BUILD (Meson build folder), SOURCE (source folder).

file(GLOB_RECURSE absl_archives "${BUILD}/subprojects/*/libabsl_*.a")
if(NOT absl_archives)
  message(FATAL_ERROR "no abseil archives under ${BUILD}/subprojects")
endif()
execute_process(
  COMMAND libtool -static -no_warning_for_no_symbols -o "${PREFIX}/lib/libwebrtc-apm.a"
    "${PREFIX}/lib/libwebrtc-audio-processing-2.a" ${absl_archives}
  RESULT_VARIABLE result)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "libtool failed: ${result}")
endif()

file(GLOB absl_sources "${SOURCE}/subprojects/abseil-cpp-*")
list(GET absl_sources 0 absl_source)
file(COPY "${absl_source}/absl" DESTINATION "${PREFIX}/include"
  FILES_MATCHING PATTERN "*.h" PATTERN "*.inc")

cmake_minimum_required(VERSION 3.22.1)
project(aveditor_ffmpeg C)

set(FFMPEG_TAG n8.1.2)
set(FFMPEG_SRC ${CMAKE_BINARY_DIR}/FFmpeg-${FFMPEG_TAG})
if(NOT EXISTS ${FFMPEG_SRC}/libavcodec/avcodec.h)
  message(STATUS "Downloading FFmpeg ${FFMPEG_TAG} headers")
  file(DOWNLOAD
    https://github.com/FFmpeg/FFmpeg/archive/refs/tags/${FFMPEG_TAG}.tar.gz
    ${CMAKE_BINARY_DIR}/ffmpeg-n8.1.2.tar.gz
    SHOW_PROGRESS
    STATUS DOWNLOAD_STATUS)
  list(GET DOWNLOAD_STATUS 0 DOWNLOAD_CODE)
  if(NOT DOWNLOAD_CODE EQUAL 0)
    message(FATAL_ERROR "FFmpeg header download failed: ${DOWNLOAD_STATUS}")
  endif()
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E tar xf ${CMAKE_BINARY_DIR}/ffmpeg-n8.1.2.tar.gz
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
    COMMAND_ERROR_IS_FATAL ANY)
endif()

file(WRITE ${FFMPEG_SRC}/libavutil/avconfig.h
"#pragma once\n#define AV_HAVE_BIGENDIAN 0\n#define AV_HAVE_FAST_UNALIGNED 1\n")

file(GLOB FFMPEG_AAR
  "$ENV{HOME}/.gradle/caches/modules-2/files-2.1/com.antonkarpenko/ffmpeg-kit-min-gpl/2.2.3/*/*.aar")
if(NOT FFMPEG_AAR)
  message(FATAL_ERROR "ffmpeg-kit-min-gpl AAR is not in the Gradle cache")
endif()
list(GET FFMPEG_AAR 0 FFMPEG_AAR_PATH)
set(FFMPEG_JNI ${CMAKE_BINARY_DIR}/ffmpeg-aar/jni/${ANDROID_ABI})
if(NOT EXISTS ${FFMPEG_JNI}/libavformat.so)
  file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/ffmpeg-aar)
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E tar xf ${FFMPEG_AAR_PATH} jni/${ANDROID_ABI}
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/ffmpeg-aar
    COMMAND_ERROR_IS_FATAL ANY)
endif()

function(import_av name)
  add_library(${name} SHARED IMPORTED)
  set_target_properties(${name} PROPERTIES
    IMPORTED_LOCATION ${FFMPEG_JNI}/lib${name}.so)
endfunction()

import_av(avutil)
import_av(swresample)
import_av(swscale)
import_av(avcodec)
import_av(avformat)

add_library(aveditor_ffmpeg SHARED ffmpeg_player.c)
target_include_directories(aveditor_ffmpeg PRIVATE ${FFMPEG_SRC})
target_link_libraries(aveditor_ffmpeg
  avformat avcodec swscale swresample avutil android log)
target_compile_options(aveditor_ffmpeg PRIVATE -Wall -Wextra -Wno-unused-parameter)

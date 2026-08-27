cmake_minimum_required(VERSION 3.5.0)
project(PhoneMirrorCompanion)

set(CMAKE_CXX_STANDARD 17)
add_library(entry SHARED napi_init.cpp sample_callback.cpp)
target_include_directories(entry PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_buffer.so
    libnative_avscreen_capture.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libnative_media_venc.so
    libnative_window.so)

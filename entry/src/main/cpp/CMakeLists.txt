cmake_minimum_required(VERSION 3.16)
project(bilimpv LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_SKIP_RPATH TRUE)

if(NOT OHOS_ARCH STREQUAL "arm64-v8a")
  message(FATAL_ERROR "The pinned OHOS libmpv release supports arm64-v8a only")
endif()

add_library(mpv SHARED IMPORTED)
set_target_properties(mpv PROPERTIES IMPORTED_LOCATION
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libmpv.so")

add_library(bilimpv SHARED bilimpv.cpp mpv_session.cpp)
target_include_directories(bilimpv PRIVATE third_party/mpv/include)
target_compile_options(bilimpv PRIVATE -Wall -Wextra -Werror -Wno-unused-command-line-argument -fvisibility=hidden)
target_link_libraries(bilimpv PRIVATE mpv libace_napi.z.so)

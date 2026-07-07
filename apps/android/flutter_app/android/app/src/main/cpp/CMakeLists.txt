cmake_minimum_required(VERSION 3.22)
project(toytalk_mobile_jni LANGUAGES CXX)

add_library(toytalk_mobile_core STATIC IMPORTED)
set_target_properties(toytalk_mobile_core PROPERTIES
  IMPORTED_LOCATION "${PLUSHPAL_RUST_LIB_DIR}/${ANDROID_ABI}/libplushpal_mobile_bridge.a")

add_library(toytalk_mobile_jni SHARED native_mobile_jni.cpp)
target_compile_features(toytalk_mobile_jni PRIVATE cxx_std_17)
target_include_directories(toytalk_mobile_jni PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../../../native/mobile_bridge/include")
target_link_libraries(toytalk_mobile_jni PRIVATE toytalk_mobile_core log android)

cmake_minimum_required(VERSION 3.20)
project(plushpal_llama_abi LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_UI OFF CACHE BOOL "" FORCE)

set(PLUSHPAL_LLAMA_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/llama.cpp"
    CACHE PATH "Path to the pinned llama.cpp source")

add_subdirectory(
  "${PLUSHPAL_LLAMA_CPP_DIR}"
  "${CMAKE_CURRENT_BINARY_DIR}/llama.cpp"
  EXCLUDE_FROM_ALL
)

option(PLUSHPAL_LLAMA_SHARED "Build the PlushPal llama ABI as a shared library" ON)
if(PLUSHPAL_LLAMA_SHARED)
  add_library(plushpal_llama SHARED src/plushpal_llama.cpp)
else()
  add_library(plushpal_llama STATIC src/plushpal_llama.cpp)
endif()
target_include_directories(plushpal_llama
  PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE
    "${PLUSHPAL_LLAMA_CPP_DIR}/include"
    "${PLUSHPAL_LLAMA_CPP_DIR}/ggml/include"
)
target_link_libraries(plushpal_llama PRIVATE llama)

include(CTest)
if(BUILD_TESTING)
  add_executable(plushpal_llama_abi_conformance tests/abi_conformance.cpp)
  target_link_libraries(plushpal_llama_abi_conformance PRIVATE plushpal_llama llama)
  add_test(NAME plushpal_llama_abi_conformance COMMAND plushpal_llama_abi_conformance)
endif()

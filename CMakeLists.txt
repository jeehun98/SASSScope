cmake_minimum_required(VERSION 3.24)

project(SASSScope LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# RTX 30xx / Ampere = 86
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES 86 CACHE STRING "CUDA architectures")
endif()

# Build target experiment
set(SASSSCOPE_EXPERIMENT
    "exp002_4_2_bias_relu_variants"
    CACHE STRING "Experiment directory under experiments/"
)

set(SASSSCOPE_EXPERIMENT_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/experiments/${SASSSCOPE_EXPERIMENT}"
)

if(NOT EXISTS "${SASSSCOPE_EXPERIMENT_DIR}")
    message(FATAL_ERROR
        "Experiment directory not found: ${SASSSCOPE_EXPERIMENT_DIR}\n"
        "Available experiments are under: ${CMAKE_CURRENT_SOURCE_DIR}/experiments"
    )
endif()

set(SASSSCOPE_EXPERIMENT_SRC_DIR
    "${SASSSCOPE_EXPERIMENT_DIR}/src"
)

set(SASSSCOPE_EXPERIMENT_INCLUDE_DIR
    "${SASSSCOPE_EXPERIMENT_DIR}/include"
)

if(NOT EXISTS "${SASSSCOPE_EXPERIMENT_SRC_DIR}/main.cu")
    message(FATAL_ERROR
        "Missing experiment main file:\n"
        "${SASSSCOPE_EXPERIMENT_SRC_DIR}/main.cu"
    )
endif()

file(GLOB SASSSCOPE_CUDA_SOURCES CONFIGURE_DEPENDS
    "${SASSSCOPE_EXPERIMENT_SRC_DIR}/*.cu"
)

if(SASSSCOPE_CUDA_SOURCES STREQUAL "")
    message(FATAL_ERROR
        "No CUDA source files found in:\n"
        "${SASSSCOPE_EXPERIMENT_SRC_DIR}"
    )
endif()

message(STATUS "SASSScope experiment: ${SASSSCOPE_EXPERIMENT}")
message(STATUS "Experiment dir: ${SASSSCOPE_EXPERIMENT_DIR}")
message(STATUS "CUDA sources: ${SASSSCOPE_CUDA_SOURCES}")

add_executable(sassscope
    ${SASSSCOPE_CUDA_SOURCES}
)

target_include_directories(sassscope PRIVATE
    "${SASSSCOPE_EXPERIMENT_INCLUDE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

option(SASSSCOPE_USE_FAST_MATH "Enable CUDA --use_fast_math" OFF)
option(SASSSCOPE_LINEINFO "Enable CUDA -lineinfo" ON)
option(SASSSCOPE_PTXAS_VERBOSE "Enable ptxas verbose output" ON)

target_compile_options(sassscope PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:-O3>
)

if(SASSSCOPE_LINEINFO)
    target_compile_options(sassscope PRIVATE
        $<$<COMPILE_LANGUAGE:CUDA>:-lineinfo>
    )
endif()

if(SASSSCOPE_PTXAS_VERBOSE)
    target_compile_options(sassscope PRIVATE
        $<$<COMPILE_LANGUAGE:CUDA>:--ptxas-options=-v>
    )
endif()

if(SASSSCOPE_USE_FAST_MATH)
    target_compile_options(sassscope PRIVATE
        $<$<COMPILE_LANGUAGE:CUDA>:--use_fast_math>
    )
endif()

if(MSVC)
    target_compile_options(sassscope PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:/O2;/W4;/utf-8>
        $<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=/utf-8>
    )
endif()

set_target_properties(sassscope PROPERTIES
    OUTPUT_NAME "${SASSSCOPE_EXPERIMENT}"
    CUDA_SEPARABLE_COMPILATION OFF
    CUDA_RESOLVE_DEVICE_SYMBOLS ON
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/experiments/${SASSSCOPE_EXPERIMENT}"
)
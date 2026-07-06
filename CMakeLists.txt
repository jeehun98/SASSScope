cmake_minimum_required(VERSION 3.24)
project(SASSScope LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES 86)
endif()

add_executable(sassscope
    src/main.cu
    src/probes.cu
)
target_include_directories(sassscope PRIVATE include)

target_compile_options(sassscope PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:-O3;-lineinfo;--use_fast_math;--ptxas-options=-v>
)
if(MSVC)
    target_compile_options(sassscope PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:/O2;/W4>
    )
endif()

set_target_properties(sassscope PROPERTIES
    CUDA_SEPARABLE_COMPILATION OFF
    CUDA_RESOLVE_DEVICE_SYMBOLS ON
)

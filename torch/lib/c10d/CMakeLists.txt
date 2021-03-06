cmake_minimum_required(VERSION 3.2 FATAL_ERROR)

# Find modules.
list(APPEND CMAKE_MODULE_PATH
  /usr/lib/x86_64-linux-gnu/
  ${CMAKE_CURRENT_SOURCE_DIR}/../../../cmake/public
  ${CMAKE_CURRENT_SOURCE_DIR}/../../../cmake/Modules
  ${CMAKE_CURRENT_SOURCE_DIR}/../../../cmake/Modules_CUDA_fix)

# Polyfill for upstream FindCUDA
include(CMakeInitializeConfigs)

# Relies on CMAKE_INSTALL_PREFIX to be set to ../tmp_install.
# It then finds $PREFIX/share/cmake/ATen/ATenConfig.cmake,
# which defines ATEN_INCLUDE_DIR and ATEN_LIBRARIES.
find_package(Caffe2 REQUIRED)
if(NOT Caffe2_FOUND)
  message(FATAL_ERROR "Caffe2 not found")
endif()

find_package(Gloo REQUIRED)
if(Gloo_FOUND)
  message(STATUS "Gloo_LIBRARY: ${Gloo_LIBRARY}")
  message(STATUS "Gloo_NATIVE_LIBRARY: ${Gloo_NATIVE_LIBRARY}")
  message(STATUS "Gloo_INCLUDE_DIR: ${Gloo_INCLUDE_DIR}")
else()
  message(FATAL_ERROR "Gloo not found")
endif()

find_package(MPI)
if(MPI_FOUND)
  message(STATUS "MPI_INCLUDE_PATH: ${MPI_INCLUDE_PATH}")
  message(STATUS "MPI_LIBRARIES: ${MPI_LIBRARIES}")
  message(STATUS "MPIEXEC: ${MPIEXEC}")
else()
  message(STATUS "Not able to find MPI, will compile c10d without MPI support")
endif()

find_package(NCCL)
IF(NCCL_FOUND)
  message(STATUS "NCCL_LIBRARIES: ${NCCL_LIBRARIES}")
  message(STATUS "NCCL_INCLUDE_DIRS: ${NCCL_INCLUDE_DIRS}")
  IF(NCCL_MAJOR_VERSION AND NOT (NCCL_MAJOR_VERSION LESS 2))
    message(STATUS "NCCL Version 2 or higher found, will "
                   "compile with NCCL distributed backend")
    SET(DISTRIBUTED_NCCL_FOUND TRUE)
  else()
    message(STATUS "Found NCCL, but the NCCL version is either not 2+ or not "
                   "determinable, will not compile with NCCL distributed "
                   "backend")
  endif()
else()
  message(STATUS "Not able to find NCCL, will not "
                 "compile with NCCL distributed backend")
endif()

find_package(CUDA REQUIRED)
if(NOT CUDA_FOUND)
  message(FATAL_ERROR "CUDA not found")
endif()

set(C10D_SRCS
  Utils.cpp
  Store.cpp
  FileStore.cpp
  TCPStore.cpp
  ProcessGroup.cpp
  CUDAUtils.cpp
  )

add_library(c10d ${C10D_SRCS})
target_compile_options(c10d PUBLIC
  -Wall
  -Wextra
  -Wno-unused-parameter
  -Wno-missing-field-initializers
  -Wno-write-strings
  -Wno-unknown-pragmas
  )
target_link_libraries(c10d PUBLIC caffe2_gpu)

# c10d links to Caffe2/ATen, but the targets don't add TH/THC to the include path
target_include_directories(c10d PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../tmp_install/include/TH)
target_include_directories(c10d PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../tmp_install/include/THC)

# For torch/csrc/utils/hash.h and torch/csrc/utils/functional.h
target_include_directories(c10d PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../../..)

set(C10D_GLOO_SRCS
  ProcessGroupGloo.cpp
  )

add_library(c10d_gloo ${C10D_GLOO_SRCS})
target_include_directories(c10d_gloo PUBLIC ${GLOO_INCLUDE_DIR})
target_link_libraries(c10d_gloo PUBLIC c10d ${Gloo_NATIVE_LIBRARY} ${Gloo_LIBRARY})

if(MPI_FOUND)
  set(C10D_MPI_SRCS
    ProcessGroupMPI.cpp
  )
  add_library(c10d_mpi ${C10D_MPI_SRCS})
  target_include_directories(c10d_mpi PUBLIC ${MPI_INCLUDE_PATH})
  target_link_libraries(c10d_mpi PUBLIC c10d ${MPI_LIBRARIES})
endif()

if(DISTRIBUTED_NCCL_FOUND)
  set(C10D_NCCL_SRCS
    ProcessGroupNCCL.cpp
  )
  add_library(c10d_nccl ${C10D_NCCL_SRCS})
  target_include_directories(c10d_nccl PUBLIC ${NCCL_INCLUDE_DIRS})
  target_link_libraries(c10d_nccl PUBLIC c10d ${NCCL_LIBRARIES})
endif()

add_subdirectory(example)

enable_testing()
add_subdirectory(test)

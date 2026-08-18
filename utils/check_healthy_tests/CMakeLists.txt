# Health-check microkernels for checkmate.
#
# Every microkernel used by system_monitoring/run_health_checks.py is built
# from this tree. Targets are grouped by what they exercise:
#
#   src/memory   CPU and GPU memory inventory        (no MPI)
#   src/network  MPI injection / bisection bandwidth (MPI)
#   src/gpu      per-node GPU microbenchmarks        (OpenMP offload / SYCL / Level Zero)
#
# Feature options gate each dependency separately so the tree still configures
# on a login node that lacks a GPU compiler. A missing dependency downgrades to
# a warning and drops the affected targets; it is never a hard error.
#
# Options (all default ON except SYCL and Level Zero, which need icpx):
#   HEALTH_CHECKS_ENABLE_MPI         MPI microkernels
#   HEALTH_CHECKS_ENABLE_OPENMP      OpenMP-offload microkernels (triad, flops)
#   HEALTH_CHECKS_ENABLE_SYCL        SYCL/oneMKL microkernels (pci, peer2pear, gemm, fftc2c)
#   HEALTH_CHECKS_ENABLE_LEVEL_ZERO  Level Zero fabric topology tool
#
# Typical Aurora configure:
#   cmake -S . -B build -DHEALTH_CHECKS_ENABLE_SYCL=ON -DHEALTH_CHECKS_ENABLE_LEVEL_ZERO=ON
#
# See README.md for per-target requirements and run instructions.

cmake_minimum_required(VERSION 3.18)
project(health_microkernels LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# All executables land directly in the top of the build directory. The YAML
# config addresses them as {build_dir}/<target>, so this layout must stay flat.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")

option(HEALTH_CHECKS_ENABLE_MPI        "Build MPI-based microkernels"        ON)
option(HEALTH_CHECKS_ENABLE_OPENMP     "Build OpenMP offload microkernels"   ON)
option(HEALTH_CHECKS_ENABLE_SYCL       "Build SYCL/oneMKL microkernels"      OFF)
option(HEALTH_CHECKS_ENABLE_LEVEL_ZERO "Build Level Zero topology tool"      OFF)

# ---------------------------------------------------------------------------
# Dependency discovery. Each block sets a HEALTH_CHECKS_HAVE_* flag that the
# subdirectories test, so dependency probing happens exactly once and the
# summary printed at the end reflects what will actually be built.
# ---------------------------------------------------------------------------

set(HEALTH_CHECKS_HAVE_MPI OFF)
if(HEALTH_CHECKS_ENABLE_MPI)
  find_package(MPI QUIET)
  if(MPI_FOUND)
    set(HEALTH_CHECKS_HAVE_MPI ON)
  else()
    message(WARNING "MPI not found; MPI-dependent microkernels will be skipped.")
  endif()
endif()

set(HEALTH_CHECKS_HAVE_OPENMP OFF)
if(HEALTH_CHECKS_ENABLE_OPENMP)
  find_package(OpenMP QUIET)
  if(OpenMP_CXX_FOUND)
    set(HEALTH_CHECKS_HAVE_OPENMP ON)
  else()
    message(WARNING "OpenMP not found; OpenMP-offload microkernels will be skipped.")
  endif()
endif()

# SYCL is detected by compiler identity rather than find_package: oneAPI ships
# SYCL inside icpx itself, so there is no separate package to locate.
set(HEALTH_CHECKS_HAVE_SYCL OFF)
if(HEALTH_CHECKS_ENABLE_SYCL)
  if(CMAKE_CXX_COMPILER_ID MATCHES "IntelLLVM"
     OR CMAKE_CXX_COMPILER_ID MATCHES "Clang"
     OR CMAKE_CXX_COMPILER MATCHES "(icpx|mpicxx|dpcpp)$")
    set(HEALTH_CHECKS_HAVE_SYCL ON)
  else()
    message(WARNING
      "HEALTH_CHECKS_ENABLE_SYCL=ON but CMAKE_CXX_COMPILER (${CMAKE_CXX_COMPILER}, "
      "id=${CMAKE_CXX_COMPILER_ID}) does not look like a SYCL compiler. "
      "Re-run with -DCMAKE_CXX_COMPILER=mpicxx after `module load oneapi`. "
      "SYCL targets skipped.")
  endif()
endif()

set(HEALTH_CHECKS_HAVE_LEVEL_ZERO OFF)
if(HEALTH_CHECKS_ENABLE_LEVEL_ZERO)
  find_path(LEVEL_ZERO_INCLUDE_DIR level_zero/ze_api.h)
  find_library(LEVEL_ZERO_LOADER ze_loader)
  if(LEVEL_ZERO_INCLUDE_DIR AND LEVEL_ZERO_LOADER)
    set(HEALTH_CHECKS_HAVE_LEVEL_ZERO ON)
  else()
    message(WARNING "Level Zero headers/loader not found; topology target skipped.")
  endif()
endif()

add_subdirectory(src/memory)
add_subdirectory(src/network)
add_subdirectory(src/gpu)

# ---------------------------------------------------------------------------
# Configure summary. Printed on every configure so a missing dependency is
# visible immediately rather than surfacing later as a missing binary.
# ---------------------------------------------------------------------------
message(STATUS "")
message(STATUS "health_microkernels configuration")
message(STATUS "  MPI .......... ${HEALTH_CHECKS_HAVE_MPI}")
message(STATUS "  OpenMP ....... ${HEALTH_CHECKS_HAVE_OPENMP}")
message(STATUS "  SYCL ......... ${HEALTH_CHECKS_HAVE_SYCL}")
message(STATUS "  Level Zero ... ${HEALTH_CHECKS_HAVE_LEVEL_ZERO}")
message(STATUS "  Output dir ... ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}")
message(STATUS "")

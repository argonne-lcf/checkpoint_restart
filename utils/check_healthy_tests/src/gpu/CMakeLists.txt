# Per-node GPU microbenchmarks.
#
# Three tiers of dependency, gated independently so a partial toolchain still
# produces the targets it can:
#
#   OpenMP offload + MPI ... triad, flops
#   SYCL + MPI ............. pci, peer2pear
#   SYCL + oneMKL + MPI .... gemm, fftc2c
#   Level Zero ............. topology (no MPI)

# --- OpenMP offload -------------------------------------------------------
if(HEALTH_CHECKS_HAVE_MPI AND HEALTH_CHECKS_HAVE_OPENMP)
  add_executable(triad triad.cpp)
  target_link_libraries(triad PRIVATE MPI::MPI_CXX OpenMP::OpenMP_CXX)
  target_compile_definitions(triad PRIVATE HEALTH_CHECKS_HAVE_MPI_TIMER)

  add_executable(flops flops.cpp)
  target_link_libraries(flops PRIVATE MPI::MPI_CXX OpenMP::OpenMP_CXX)
  target_compile_definitions(flops PRIVATE HEALTH_CHECKS_HAVE_MPI_TIMER)

  # Offload to Intel GPUs requires the SPIR-V target explicitly; without it the
  # `omp target` regions silently fall back to the host and the reported
  # numbers describe the CPU rather than the GPU.
  foreach(_omp_target triad flops)
    target_compile_options(${_omp_target} PRIVATE -fiopenmp -fopenmp-targets=spir64)
    target_link_options(${_omp_target}    PRIVATE -fiopenmp -fopenmp-targets=spir64)
  endforeach()

  install(TARGETS triad flops DESTINATION bin)
endif()

# --- SYCL -----------------------------------------------------------------
if(HEALTH_CHECKS_HAVE_MPI AND HEALTH_CHECKS_HAVE_SYCL)
  add_executable(pci pci.cpp)
  add_executable(peer2pear peer2pear.cpp)

  foreach(_sycl_target pci peer2pear)
    target_link_libraries(${_sycl_target} PRIVATE MPI::MPI_CXX)
    target_compile_definitions(${_sycl_target} PRIVATE HEALTH_CHECKS_HAVE_MPI_TIMER)
    target_compile_options(${_sycl_target} PRIVATE -fsycl)
    target_link_options(${_sycl_target}    PRIVATE -fsycl)
  endforeach()

  install(TARGETS pci peer2pear DESTINATION bin)

  # oneMKL-backed kernels. MKL_ROOT is exported by the oneAPI environment
  # (`module load oneapi`); -qmkl asks the Intel driver to resolve the library
  # set, so no explicit find_package is needed.
  if(DEFINED ENV{MKLROOT})
    add_executable(gemm gemm.cpp)
    add_executable(fftc2c fftc2c.cpp)

    foreach(_mkl_target gemm fftc2c)
      target_link_libraries(${_mkl_target} PRIVATE MPI::MPI_CXX)
      target_compile_definitions(${_mkl_target} PRIVATE HEALTH_CHECKS_HAVE_MPI_TIMER)
      target_compile_options(${_mkl_target} PRIVATE -fsycl -qmkl)
      target_link_options(${_mkl_target}    PRIVATE -fsycl -qmkl)
    endforeach()

    install(TARGETS gemm fftc2c DESTINATION bin)
  else()
    message(WARNING
      "MKLROOT is not set; gemm and fftc2c skipped. Run `module load oneapi` "
      "(or source setvars.sh) before configuring to build them.")
  endif()
endif()

# --- Level Zero -----------------------------------------------------------
if(HEALTH_CHECKS_HAVE_LEVEL_ZERO)
  add_executable(topology topology.cpp)
  target_include_directories(topology PRIVATE ${LEVEL_ZERO_INCLUDE_DIR})
  target_link_libraries(topology PRIVATE ${LEVEL_ZERO_LOADER})
  install(TARGETS topology DESTINATION bin)
endif()

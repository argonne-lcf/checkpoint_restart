# MPI injection and bisection bandwidth microkernels.
#
# Two independent implementations of the same pair of measurements are kept on
# purpose; see README.md for when to use which.
#
#   simple_injection_bisection  nonblocking Isend/Irecv, reports non-blocking %
#   full_injection_bisection    blocking Sendrecv, serialised peer loop

if(NOT HEALTH_CHECKS_HAVE_MPI)
  return()
endif()

add_executable(simple_injection_bisection simple_injection_bisection.c)
target_link_libraries(simple_injection_bisection PRIVATE MPI::MPI_C)
  target_compile_definitions(simple_injection_bisection PRIVATE HEALTH_CHECKS_HAVE_MPI_TIMER)

add_executable(full_injection_bisection full_injection_bisection.c)
target_link_libraries(full_injection_bisection PRIVATE MPI::MPI_C)
  target_compile_definitions(full_injection_bisection PRIVATE HEALTH_CHECKS_HAVE_MPI_TIMER)

install(TARGETS simple_injection_bisection full_injection_bisection DESTINATION bin)

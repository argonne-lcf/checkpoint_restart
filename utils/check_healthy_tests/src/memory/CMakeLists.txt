# Memory inventory microkernel. No MPI, no GPU compiler: the Level Zero loader
# is opened with dlopen at run time, so this builds anywhere with a C++17
# compiler and still reports GPU memory when the loader is present.

add_executable(mem_and_gpu_row mem_and_gpu_row.cpp)

if(UNIX)
  target_link_libraries(mem_and_gpu_row PRIVATE ${CMAKE_DL_LIBS})
endif()

install(TARGETS mem_and_gpu_row DESTINATION bin)

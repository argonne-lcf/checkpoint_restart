# Memory inventory microkernel. No MPI, no GPU compiler: the Level Zero loader
# is opened with dlopen at run time, so this builds anywhere with a C++17
# compiler and still reports GPU memory when the loader is present.

add_executable(mem_and_gpu_row mem_and_gpu_row.cpp)

# The Level Zero loader is opened with dlopen and creates threads of its own.
# Without -pthread the process resolves the pthread stubs in libc and aborts
# on the loader's first thread creation:
#
#   what():  Enable multithreading to use std::thread: Operation not permitted
#
# The failure only appears where the loader is actually present, so a login
# node build runs clean and a compute node aborts with exit 134.
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)
target_link_libraries(mem_and_gpu_row PRIVATE Threads::Threads)

if(UNIX)
  target_link_libraries(mem_and_gpu_row PRIVATE ${CMAKE_DL_LIBS})
endif()

install(TARGETS mem_and_gpu_row DESTINATION bin)

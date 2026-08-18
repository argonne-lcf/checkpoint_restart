// flops.cpp -- peak FLOP rate via OpenMP target offload.
//
// Runs a dense chain of fused multiply-add operations with no memory traffic in
// the inner loop, so the result is compute-bound and approaches the device
// peak. Both single and double precision are measured.
//
// Each work item performs 128 iterations of MAD_16 (16 MADs, 2 flops each):
//   workPerWI = 128 * 16 * 2 = 4096 flops
//   gflops    = workPerWI * globalWI * world_size * 1e-9 / min_time
//
// The MAD_4/16/64 macros expand into straight-line dependent FMAs; the
// dependency chain is deliberate, it stops the compiler from vectorising the
// work away. Adapted from clpeak (https://github.com/krrishnarraj/clpeak/).
//
// A strided isfinite() scan after the timed region guards against the whole
// chain being optimised out or the device returning garbage. It is a plain if
// rather than an assert: the default build is Release and -DNDEBUG would
// remove an assert, leaving the kernel with no validation at all.
//
// REQUIREMENTS  MPI, OpenMP offload to SPIR-V (-fiopenmp -fopenmp-targets=spir64).
// USAGE         mpiexec -n <ranks> [--] gpu_tile_compact.sh ./flops
// OUTPUT        "Single Precision Peak Flops: <v> GFlop/s" and the double
//               precision equivalent, from rank 0.

#undef MAD_4
#undef MAD_16
#undef MAD_64

#define MAD_4(x, y)                                                                                \
  x = y * x + y;                                                                                   \
  y = x * y + x;                                                                                   \
  x = y * x + y;                                                                                   \
  y = x * y + x;
#define MAD_16(x, y)                                                                               \
  MAD_4(x, y);                                                                                     \
  MAD_4(x, y);                                                                                     \
  MAD_4(x, y);                                                                                     \
  MAD_4(x, y);
#define MAD_64(x, y)                                                                               \
  MAD_16(x, y);                                                                                    \
  MAD_16(x, y);                                                                                    \
  MAD_16(x, y);                                                                                    \
  MAD_16(x, y);

// Naive port of some portion of clpeak
// (https://github.com/krrishnarraj/clpeak/)
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
#include <mpi.h>
#include <sstream>
#include <omp.h>
#include <vector>

#include "rank_identity.hpp"

#include "kernel_timer.hpp"

template <typename T> void bench(std::string precision) {
  int world_size, world_rank;
  MPI_Comm_size(MPI_COMM_WORLD, &world_size);
  MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);
  // Emit the rank -> host/tile map so a slow aggregate can be
  // attributed to specific hardware.
  health_checks::print_rank_identity("flops");

  const int64_t globalWI{20000000};
  const int num_iteration{100};

  const T x0 = 1.1;
  const T y0 = -x0;

  std::vector<T> A(globalWI, x0);
  T *Aptr{A.data()};
#pragma omp target enter data map(to : Aptr[0 : globalWI])
  double min_time = std::numeric_limits<double>::max();
  for (int r = 0; r < num_iteration; r++) {
#pragma omp target update to(Aptr[0 : globalWI])
    MPI_Barrier(MPI_COMM_WORLD);
    const double l_start = omp_get_wtime();
#pragma omp target teams distribute parallel for
    for (int64_t i = 0; i < globalWI; i++) {
      T x = Aptr[i];
      T y = y0;
      for (int j = 0; j < 128; j++) {
        MAD_16(x, y);
      }
      Aptr[i] = y;
    }
    const double l_end = omp_get_wtime();
    double start, end;
    MPI_Reduce(&l_start, &start, 1, MPI_DOUBLE, MPI_MIN, 0, MPI_COMM_WORLD);
    MPI_Reduce(&l_end, &end, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);
    const double time = end - start;
    min_time = std::min(time, min_time);
  }
#pragma omp target exit data map(from : Aptr[0 : globalWI])
  // Validation must survive the Release build: assert() is removed by
  // -DNDEBUG, which is on the default compile line. Checking Aptr[0] alone
  // would also miss a tile that corrupts only part of its range, so this
  // samples across the whole buffer. It runs after the timed region.
  const int64_t kValidateStride = 4096;
  long nonfinite = 0;
  int64_t first_bad = -1;
  for (int64_t i = 0; i < globalWI; i += kValidateStride) {
    if (!std::isfinite(Aptr[i])) {
      if (first_bad < 0)
        first_bad = i;
      nonfinite++;
    }
  }

  if (nonfinite > 0) {
    const long checked = (globalWI + kValidateStride - 1) / kValidateStride;
    // One write, not one per field: every rank shares this stderr, and
    // per-field writes interleave into unreadable lines.
    std::ostringstream msg;
    msg << "VALIDATION FAILED flops " << precision << " rank=" << world_rank
        << " host=" << health_checks::rank_host()
        << " tile=" << health_checks::rank_tile()
        << " nonfinite=" << nonfinite << "/" << checked
        << " first_index=" << first_bad << "\n";
    std::cerr << msg.str() << std::flush;
    MPI_Abort(MPI_COMM_WORLD, 3);
  }

  const double workPerWI{128 * 16 * 2}; // Indicates flops executed per work-item
  const double gflops = (workPerWI * globalWI * world_size * 1E-9) / min_time;
  if (world_rank == 0)
    std::cout << precision << ": " << gflops << " GFlop/s"<< std::endl;
}

int main(int argc, char **argv) {
  // Wall-clock for the whole kernel, reported as KERNEL_TIME.
  health_checks::KernelTimer kernel_timer_("flops");


  MPI_Init(NULL, NULL);
  bench<float>("Single Precision Peak Flops");
  bench<double>("Double Precision Peak Flops");
  kernel_timer_.report();
  MPI_Finalize();
}

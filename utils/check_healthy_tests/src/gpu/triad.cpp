// triad.cpp -- STREAM triad memory bandwidth via OpenMP target offload.
//
// Computes A[i] = 2*B[i] + C[i] over 65,536,000 doubles on the GPU, 100 times,
// and reports the best (minimum-time) result. Each rank drives one GPU tile,
// so the aggregate scales with rank count.
//
// Bandwidth counts three arrays touched per element (two read, one written):
//   bw = 3 * sizeof(double) * globalWI * world_size / min_time
//
// Timing is bracketed by MPI_Reduce of per-rank start/end across all ranks, so
// the reported time is the slowest rank's span, not a local measurement.
//
// REQUIREMENTS  MPI, OpenMP offload to SPIR-V (-fiopenmp -fopenmp-targets=spir64).
//               Built without those flags the target regions run on the host
//               and the number describes CPU memory, not GPU.
// USAGE         mpiexec -n <ranks> [--] gpu_tile_compact.sh ./triad
// OUTPUT        "Memory Bandwidth (triad): <value> GB/s" from rank 0.
// VALIDATION    Every 1024th element is re-checked on the host after the timed
//               region. A mismatch prints the rank, host, tile and offending
//               index, then calls MPI_Abort, so a silent-corruption GPU fails
//               the node instead of reporting a healthy bandwidth. The check
//               is a plain if, not an assert: the default build is Release and
//               -DNDEBUG would remove an assert entirely.

#include <algorithm>
#include <assert.h>
#include <iostream>
#include <limits>
#include <mpi.h>
#include <sstream>
#include <omp.h>
#include <vector>

#include "rank_identity.hpp"

#include "kernel_timer.hpp"

bool almost_equal(double x, double gold, double rel_tol = 1e-09, double abs_tol = 0.0) {
  return std::abs(x - gold) <= std::max(rel_tol * std::max(std::abs(x), std::abs(gold)), abs_tol);
}

int main() {
  // Wall-clock for the whole kernel, reported as KERNEL_TIME.
  health_checks::KernelTimer kernel_timer_("triad");

  MPI_Init(NULL, NULL);
  int world_size, world_rank;
  MPI_Comm_size(MPI_COMM_WORLD, &world_size);
  MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);
  // Emit the rank -> host/tile map so a slow aggregate can be
  // attributed to specific hardware.
  health_checks::print_rank_identity("triad");

  const int globalWI{65536000};
  const int num_iteration{100};

  std::vector<double> A(globalWI), B(globalWI), C(globalWI);
  std::generate(B.begin(), B.end(), std::rand);
  std::generate(C.begin(), C.end(), std::rand);
  double *Aptr{A.data()};
  double *Bptr{B.data()};
  double *Cptr{C.data()};
#pragma omp target enter data map(alloc : Aptr[ : globalWI])                                       \
    map(to : Bptr[ : globalWI], Cptr[ : globalWI])
  double min_time = std::numeric_limits<double>::max();
  for (int r = 0; r < num_iteration; r++) {
    MPI_Barrier(MPI_COMM_WORLD);
    const double l_start = omp_get_wtime();
#pragma omp target teams distribute parallel for
    for (int i = 0; i < globalWI; i++)
      Aptr[i] = 2.0 * Bptr[i] + Cptr[i];
    const double l_end = omp_get_wtime();
    double start, end;
    MPI_Reduce(&l_start, &start, 1, MPI_DOUBLE, MPI_MIN, 0, MPI_COMM_WORLD);
    MPI_Reduce(&l_end, &end, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);
    const double time = end - start;
    min_time = std::min(time, min_time);
  }
#pragma omp target exit data map(from : Aptr[ : globalWI])
  const double bw = (3 * sizeof(double) * globalWI * world_size * 1E-9) / min_time;
  if (world_rank == 0)
    std::cout << "Memory Bandwidth (triad): " << bw << " GB/s"<< std::endl;

  // Validation must survive the Release build: assert() is removed by
  // -DNDEBUG, which is on the default compile line, so a GPU returning wrong
  // results would report full bandwidth and pass. This runs after the timed
  // region, so it does not affect the reported bandwidth.
  //
  // Strided rather than exhaustive: 65,536,000 host-side comparisons cost
  // real time for no extra diagnostic value. A tile computing garbage fails
  // on the first few samples, not on element 40,000,000.
  const int kValidateStride = 1024;
  long validation_failures = 0;
  int first_bad = -1;
  for (int i = 0; i < globalWI; i += kValidateStride) {
    if (!almost_equal(Aptr[i], 2.0 * Bptr[i] + Cptr[i], 0.01)) {
      if (first_bad < 0)
        first_bad = i;
      validation_failures++;
    }
  }

  if (validation_failures > 0) {
    const long checked = (globalWI + kValidateStride - 1) / kValidateStride;
    // One write, not one per field: every rank shares this stderr, and
    // per-field writes interleave into unreadable lines.
    std::ostringstream msg;
    msg << "VALIDATION FAILED triad rank=" << world_rank
        << " host=" << health_checks::rank_host()
        << " tile=" << health_checks::rank_tile() << " mismatches="
        << validation_failures << "/" << checked
        << " first_index=" << first_bad
        << " got=" << Aptr[first_bad]
        << " want=" << (2.0 * Bptr[first_bad] + Cptr[first_bad]) << "\n";
    std::cerr << msg.str() << std::flush;
    MPI_Abort(MPI_COMM_WORLD, 3);
  }
  kernel_timer_.report();
  MPI_Finalize();
}

// gemm.cpp -- dense matrix-multiply throughput via oneMKL, per GPU tile.
//
// Runs 8192x8192 GEMM in six precisions, 100 iterations each, reporting the
// best. Covers the full Intel GPU datapath from FP64 down to INT8:
//   DGEMM     double
//   SGEMM     float
//   HGEMM     half
//   BF16GEMM  bfloat16 in, float accumulate
//   TF32GEMM  float in, TF32 compute mode
//   I8GEMM    int8 in, float accumulate
//
// A precision that is markedly off its expected ratio to the others points at
// a specific functional unit rather than a sick GPU overall, which is what
// makes this useful as a health check and not just a benchmark.
//
// OUTLIER REPORTING
//   Every rank times its own tile independently, so a slow tile can be named
//   rather than merely dragging down an allocation-wide average. Each tile is
//   compared against two references:
//
//     vs_node    the median tile on the same host  -- isolates one bad tile
//                or one bad GPU among its siblings
//     vs_global  the median tile across every host -- catches a host whose
//                tiles are uniformly slow, which a node-local comparison
//                cannot see because every tile there is equally bad
//
//   A tile is an OUTLIER when it falls below either median by more than the
//   threshold (default 10%, --threshold or GEMM_OUTLIER_PCT). The trailing
//   "candidates for exclusion" block ranks tiles by how many precisions they
//   were slow in, which is the list to feed a node filter. A tile slow in all
//   six precisions is degraded hardware; a tile slow in one is more likely a
//   thermal excursion or a noisy neighbour.
//
//   The median is the reference rather than the mean because the mean is
//   dragged down by the very outlier being searched for; with two bad tiles in
//   twelve, a mean-based comparison can hide both.
//
// Matrices are seeded with scaled random values; max_array_value is clamped so
// the accumulation cannot overflow the output type at this matrix size.
//
// REQUIREMENTS  MPI, SYCL, oneMKL (-fsycl -qmkl). Needs MKLROOT set.
// USAGE         mpiexec -n <ranks> [--] gpu_tile_compact.sh ./gemm [options]
//
//   --csv                 emit machine-readable CSV instead of tables
//   --threshold <pct>     outlier threshold, default 10
//   --fail-on-outlier     exit 3 when any tile is an outlier (for gating)
//   --quiet-tiles         summary only, suppress the per-tile table
//
// OUTPUT        One "<NAME>: <v> GFlop/s" aggregate line per precision from
//               rank 0 (unchanged, parsed by tools/gen_mk_table.py), followed
//               by the per-tile table and outlier summary. Every added line is
//               prefixed so it cannot collide with the aggregate lines.
//
// EXIT STATUS   0 normally; 3 when --fail-on-outlier is set and a tile was
//               flagged. Note that run_health_checks.py treats any nonzero
//               status as FAIL, so --fail-on-outlier turns this kernel into a
//               pass/fail gate rather than a report.

#include "float.h"
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <list>
#include <map>
#include <random>
#include <string>
#include <vector>

#include <unistd.h>

#include "mkl.h"
#include "oneapi/mkl/blas.hpp"
#include <sycl/sycl.hpp>

#include <mpi.h>

#include "kernel_timer.hpp"

namespace {

constexpr int kHostLen = 64;
constexpr int kMaskLen = 32;

// Per-precision measurement produced by every rank.
struct Measurement {
  std::string name;
  double local_gflops;      // this rank's own tile
  double aggregate_gflops;  // allocation-wide, rank 0 only
};

double median_of(std::vector<double> v) {
  if (v.empty())
    return 0.0;
  std::sort(v.begin(), v.end());
  const size_t n = v.size();
  return (n % 2) ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2]);
}

// Percentage difference of value against reference; negative means slower.
double pct_vs(double value, double reference) {
  if (reference <= 0.0)
    return 0.0;
  return 100.0 * (value - reference) / reference;
}

}  // namespace

template <typename fp_ab, typename fp_c, typename fp_scalar>
Measurement run_gemm_example(
    sycl::queue Q, int size, std::string name,
    oneapi::mkl::blas::compute_mode mode = oneapi::mkl::blas::compute_mode::standard) {

  auto transA = oneapi::mkl::transpose::nontrans;
  auto transB = oneapi::mkl::transpose::nontrans;

  fp_scalar alpha = fp_scalar(1.0);
  fp_scalar beta = fp_scalar(0.0);

  auto A = sycl::malloc_shared<fp_ab>(size * size, Q);
  auto B = sycl::malloc_shared<fp_ab>(size * size, Q);
  auto C = sycl::malloc_shared<fp_c>(size * size, Q);

  if (!A || !B || !C)
    throw std::runtime_error("Failed to allocate USM memory.");

  fp_ab max_ab = std::numeric_limits<fp_ab>::max();

  // Workaround for some type
  if (max_ab == 0)
    max_ab = 100;

  fp_c max_c_array_value = std::sqrt(std::numeric_limits<fp_c>::max() / size);
  // assumes fp_c is bigger
  fp_ab max_array_value = std::min((fp_c)max_c_array_value, (fp_c)max_ab / 2);

  // A(size, size)
  for (size_t i = 0; i < (size * size); i++) {
    A[i] = fp_ab(max_array_value) * double((std::rand() / (double)RAND_MAX));
  }

  // B(size,size)
  for (size_t i = 0; i < (size * size); i++) {
    B[i] = fp_ab(max_array_value) * double((std::rand() / (double)RAND_MAX));
  }

  unsigned long min_time = std::numeric_limits<unsigned long>::max();
  // Best local iteration for this rank alone. The reduced window below spans
  // every rank, so it can only describe the allocation; attributing a slow
  // tile needs the timing that never left this process.
  unsigned long local_min_time = std::numeric_limits<unsigned long>::max();

  int niter = 100;
  for (int i = 0; i < niter; i++) {
    MPI_Barrier(MPI_COMM_WORLD);
    const unsigned long l_start = std::chrono::duration_cast<std::chrono::nanoseconds>(
                                      std::chrono::high_resolution_clock::now().time_since_epoch())
                                      .count();

    oneapi::mkl::blas::column_major::gemm(Q, transA, transB, size, size, size, alpha, A, size, B,
                                          size, beta, C, size, mode)
        .wait();
    const unsigned long l_end = std::chrono::duration_cast<std::chrono::nanoseconds>(
                                    std::chrono::high_resolution_clock::now().time_since_epoch())
                                    .count();

    local_min_time = std::min(l_end - l_start, local_min_time);

    unsigned long start, end;
    MPI_Reduce(&l_start, &start, 1, MPI_UNSIGNED_LONG, MPI_MIN, 0, MPI_COMM_WORLD);
    MPI_Reduce(&l_end, &end, 1, MPI_UNSIGNED_LONG, MPI_MAX, 0, MPI_COMM_WORLD);

    const unsigned long time = end - start;
    min_time = std::min(time, min_time);
  }

  free(A, Q);
  free(B, Q);
  free(C, Q);

  int world_size, world_rank;
  MPI_Comm_size(MPI_COMM_WORLD, &world_size);
  MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);

  // Work is 2*N^3 flops; nanosecond timings make the ratio GFlop/s directly.
  const double flops = (2. * size * size * size * world_size) / min_time;
  const double local_flops = (2. * size * size * size) / local_min_time;

  if (world_rank == 0) {
    // Unchanged aggregate line. tools/gen_mk_table.py matches this with
    // startswith(<PRECISION>), so the prefix and field order are load-bearing.
    std::cout << name << ": " << flops << " GFlop/s" << std::endl;
  }

  return Measurement{name, local_flops, flops};
}

int main(int argc, char **argv) {
  // Wall-clock for the whole kernel, reported as KERNEL_TIME.
  health_checks::KernelTimer kernel_timer_("gemm");


  MPI_Init(NULL, NULL);

  int world_size = 1, world_rank = 0;
  MPI_Comm_size(MPI_COMM_WORLD, &world_size);
  MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);

  bool csv = false;
  bool fail_on_outlier = false;
  bool quiet_tiles = false;
  double threshold = 10.0;
  if (const char *env = std::getenv("GEMM_OUTLIER_PCT"))
    threshold = std::atof(env);

  for (int i = 1; i < argc; i++) {
    const std::string arg = argv[i];
    if (arg == "--csv")
      csv = true;
    else if (arg == "--fail-on-outlier")
      fail_on_outlier = true;
    else if (arg == "--quiet-tiles")
      quiet_tiles = true;
    else if (arg == "--threshold" && i + 1 < argc)
      threshold = std::atof(argv[++i]);
    else if (world_rank == 0)
      std::cerr << "gemm: ignoring unrecognised argument '" << arg << "'" << std::endl;
  }

  // Identify this rank's tile. gpu_tile_compact.sh sets ZE_AFFINITY_MASK to
  // "<gpu>.<tile>"; without that wrapper every rank shares tile 0.0 and the
  // per-tile comparison below is meaningless, so say so rather than emit a
  // confident-looking table of identical numbers.
  char host[kHostLen];
  std::memset(host, 0, sizeof(host));
  if (gethostname(host, sizeof(host) - 1) != 0)
    std::strncpy(host, "unknown", sizeof(host) - 1);

  char mask[kMaskLen];
  std::memset(mask, 0, sizeof(mask));
  const char *env_mask = std::getenv("ZE_AFFINITY_MASK");
  std::strncpy(mask, env_mask ? env_mask : "unset", sizeof(mask) - 1);

  int size = 8192;
  sycl::queue Q;

  std::vector<Measurement> results;
  results.push_back(run_gemm_example<double, double, double>(Q, size, "DGEMM"));
  kernel_timer_.phase("DGEMM");
  results.push_back(run_gemm_example<float, float, float>(Q, size, "SGEMM"));
  kernel_timer_.phase("SGEMM");
  results.push_back(run_gemm_example<sycl::half, sycl::half, sycl::half>(Q, size, "HGEMM"));
  kernel_timer_.phase("HGEMM");

  results.push_back(run_gemm_example<oneapi::mkl::bfloat16, float, float>(Q, size, "BF16GEMM"));
  kernel_timer_.phase("BF16GEMM");
  results.push_back(run_gemm_example<float, float, float>(
      Q, size, "TF32GEMM", oneapi::mkl::blas::compute_mode::float_to_tf32));
  kernel_timer_.phase("TF32GEMM");
  results.push_back(run_gemm_example<std::int8_t, float, float>(Q, size, "I8GEMM"));
  kernel_timer_.phase("I8GEMM");

  // ---- collect every tile's own numbers on rank 0 --------------------------

  std::vector<char> all_hosts;
  std::vector<char> all_masks;
  if (world_rank == 0) {
    all_hosts.resize(static_cast<size_t>(kHostLen) * world_size);
    all_masks.resize(static_cast<size_t>(kMaskLen) * world_size);
  }
  MPI_Gather(host, kHostLen, MPI_CHAR, all_hosts.data(), kHostLen, MPI_CHAR, 0, MPI_COMM_WORLD);
  MPI_Gather(mask, kMaskLen, MPI_CHAR, all_masks.data(), kMaskLen, MPI_CHAR, 0, MPI_COMM_WORLD);

  const size_t nprec = results.size();
  std::vector<std::vector<double>> per_prec(nprec);
  for (size_t p = 0; p < nprec; p++) {
    if (world_rank == 0)
      per_prec[p].resize(world_size);
    MPI_Gather(&results[p].local_gflops, 1, MPI_DOUBLE, per_prec[p].data(), 1, MPI_DOUBLE, 0,
               MPI_COMM_WORLD);
  }

  int exit_code = 0;

  if (world_rank == 0) {
    std::vector<std::string> hosts(world_size), masks(world_size);
    for (int r = 0; r < world_size; r++) {
      hosts[r] = std::string(&all_hosts[static_cast<size_t>(r) * kHostLen]);
      masks[r] = std::string(&all_masks[static_cast<size_t>(r) * kMaskLen]);
    }

    // Rank indices grouped by host, for the node-local median.
    std::map<std::string, std::vector<int>> by_host;
    for (int r = 0; r < world_size; r++)
      by_host[hosts[r]].push_back(r);

    bool masks_usable = true;
    for (int r = 0; r < world_size && masks_usable; r++)
      if (masks[r] == "unset")
        masks_usable = false;

    // Number of precisions in which each rank was flagged, and its worst case.
    std::vector<int> slow_count(world_size, 0);
    std::vector<double> worst_pct(world_size, 0.0);
    std::vector<double> sum_pct(world_size, 0.0);

    if (!csv) {
      std::cout << "\n=== Per-tile GEMM throughput ===" << std::endl;
      if (world_size < 2)
        std::cout << "GEMM_NOTE single rank; no peer comparison is possible." << std::endl;
      if (!masks_usable)
        std::cout << "GEMM_NOTE ZE_AFFINITY_MASK unset on at least one rank; ranks may share a "
                     "tile. Launch through scripts/gpu_tile_compact.sh."
                  << std::endl;
      std::cout << "GEMM_NOTE reference is the median tile; negative percentages are slower."
                << std::endl;
    } else {
      std::cout << "precision,host,tile,rank,gflops,node_median,global_median,vs_node_pct,"
                   "vs_global_pct,outlier"
                << std::endl;
    }

    for (size_t p = 0; p < nprec; p++) {
      const std::string &name = results[p].name;
      const std::vector<double> &v = per_prec[p];

      const double gmed = median_of(v);
      std::map<std::string, double> node_med;
      for (const auto &kv : by_host) {
        std::vector<double> nv;
        nv.reserve(kv.second.size());
        for (int r : kv.second)
          nv.push_back(v[r]);
        node_med[kv.first] = median_of(nv);
      }

      if (!csv && !quiet_tiles) {
        std::cout << "\n-- " << name << " (global median " << std::fixed << std::setprecision(1)
                  << gmed << " GFlop/s)" << std::endl;
        std::cout << "GEMM_TILE " << std::left << std::setw(22) << "host" << std::setw(7) << "tile"
                  << std::setw(7) << "rank" << std::right << std::setw(12) << "GFlop/s"
                  << std::setw(12) << "vs_node" << std::setw(12) << "vs_global" << "  flag"
                  << std::endl;
      }

      int slowest_rank = 0;
      for (int r = 1; r < world_size; r++)
        if (v[r] < v[slowest_rank])
          slowest_rank = r;

      for (int r = 0; r < world_size; r++) {
        const double vn = pct_vs(v[r], node_med[hosts[r]]);
        const double vg = pct_vs(v[r], gmed);
        const bool outlier = (world_size > 1) && (vn < -threshold || vg < -threshold);

        if (outlier) {
          slow_count[r]++;
          worst_pct[r] = std::min(worst_pct[r], std::min(vn, vg));
        }
        sum_pct[r] += std::min(vn, vg);

        if (csv) {
          std::cout << name << "," << hosts[r] << "," << masks[r] << "," << r << "," << std::fixed
                    << std::setprecision(1) << v[r] << "," << node_med[hosts[r]] << "," << gmed
                    << "," << std::setprecision(2) << vn << "," << vg << ","
                    << (outlier ? "1" : "0") << std::endl;
        } else if (!quiet_tiles) {
          std::cout << "GEMM_TILE " << std::left << std::setw(22) << hosts[r] << std::setw(7)
                    << masks[r] << std::setw(7) << r << std::right << std::fixed
                    << std::setprecision(1) << std::setw(12) << v[r] << std::setprecision(2)
                    << std::setw(11) << vn << "%" << std::setw(11) << vg << "%"
                    << (outlier ? "  OUTLIER" : "") << std::endl;
        }
      }

      if (!csv && world_size > 1) {
        std::cout << "GEMM_SLOWEST " << name << " " << hosts[slowest_rank] << " tile "
                  << masks[slowest_rank] << " rank " << slowest_rank << " " << std::fixed
                  << std::setprecision(1) << v[slowest_rank] << " GFlop/s " << std::setprecision(2)
                  << pct_vs(v[slowest_rank], gmed) << "% vs global median" << std::endl;
      }
    }

    // ---- ranked exclusion candidates ---------------------------------------
    // Ordered by how many precisions flagged the tile, then by worst deficit.
    // Consistency across precisions is the signal: all six means the hardware
    // is degraded, one means a transient.
    if (!csv && world_size > 1) {
      std::vector<int> order;
      for (int r = 0; r < world_size; r++)
        if (slow_count[r] > 0)
          order.push_back(r);

      std::sort(order.begin(), order.end(), [&](int a, int b) {
        if (slow_count[a] != slow_count[b])
          return slow_count[a] > slow_count[b];
        return worst_pct[a] < worst_pct[b];
      });

      std::cout << "\n=== Candidates for exclusion (threshold " << std::fixed
                << std::setprecision(1) << threshold << "%) ===" << std::endl;
      if (order.empty()) {
        std::cout << "GEMM_VERDICT none; every tile within " << threshold << "% of its peers"
                  << std::endl;
      } else {
        for (int r : order) {
          std::cout << "GEMM_CANDIDATE " << hosts[r] << " tile " << masks[r] << " rank " << r
                    << " slow_in " << slow_count[r] << "/" << nprec << " worst " << std::fixed
                    << std::setprecision(2) << worst_pct[r] << "% mean "
                    << (sum_pct[r] / static_cast<double>(nprec)) << "%" << std::endl;
        }
        std::cout << "GEMM_VERDICT " << order.size() << " tile(s) on "
                  << [&] {
                       std::vector<std::string> hs;
                       for (int r : order)
                         if (std::find(hs.begin(), hs.end(), hosts[r]) == hs.end())
                           hs.push_back(hosts[r]);
                       std::string s;
                       for (size_t i = 0; i < hs.size(); i++)
                         s += (i ? "," : "") + hs[i];
                       return s;
                     }()
                  << " below threshold" << std::endl;
        if (fail_on_outlier)
          exit_code = 3;
      }
    }
  }

  // Every rank must agree on the status, or mpiexec reports a partial failure.
  MPI_Bcast(&exit_code, 1, MPI_INT, 0, MPI_COMM_WORLD);

  kernel_timer_.report();
  MPI_Finalize();
  return exit_code;
}

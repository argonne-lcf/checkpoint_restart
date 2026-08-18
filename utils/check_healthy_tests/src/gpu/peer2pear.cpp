// peer2pear.cpp -- GPU-to-GPU bandwidth via SYCL + MPI.
//
// Ranks are paired (even rank with the next odd rank) and exchange a 128 MiB
// device buffer, first one-way then bidirectionally, best of 10 iterations.
//
// The mode argument is a label only -- it does not change what is measured.
// Which GPUs actually talk to each other is decided by the wrapper script that
// sets ZE_AFFINITY_MASK before exec:
//   gpu_tile_compact.sh       adjacent tiles      -> pass "Tile2Tile"
//   gpu_tile_plan_compact.sh  same-plane GPUs     -> pass "GPU2GPU"
// Passing the wrong label with the wrong wrapper produces correctly measured
// numbers under a misleading name.
//
// REQUIREMENTS  MPI, SYCL (-fsycl). For the GPU2GPU path the topology binary
//               must be built and present in the working directory, since
//               gpu_tile_plan_compact.sh shells out to it.
// USAGE         mpiexec -n <even rank count> -- gpu_tile_compact.sh \
//                 ./peer2pear "Tile2Tile"
// OUTPUT        "<mode> Unidirectional/Bidirectional Bandwidth: <v> GB/s".
//
// NOTE ON THE NAME  "peer2pear" is a typo for peer2peer that is preserved
// because run.sh, the sample outputs, and existing job scripts all refer to it.

#include <cstdint>
#include <limits>
#include <mpi.h>
#include <random>
#include <sycl/sycl.hpp>
#include <vector>

#include "rank_identity.hpp"

#include "kernel_timer.hpp"

void fill_randomly(sycl::queue Q, int N, std::vector<float *> ptrs) {
  std::vector<float> v(N);
  std::iota(v.begin(), v.end(), 0);

  std::minstd_rand g;
  for (auto &ptr : ptrs) {
    std::shuffle(v.begin(), v.end(), g);
    Q.memcpy(ptr, v.data(), N * sizeof(float)).wait();
  }

}

unsigned long datatransfer(int N, std::vector<std::pair<int, float *>> &sends,
                           std::vector<std::pair<int, float *>> &recvs) {

  unsigned long min_time = std::numeric_limits<unsigned long>::max();
  int num_iteration = 10;

  for (int r = 0; r < num_iteration; r++) {
    MPI_Barrier(MPI_COMM_WORLD);
    const unsigned long l_start =
        std::chrono::high_resolution_clock::now().time_since_epoch().count();

    std::vector<MPI_Request> requests;

    for (auto &[dest, ptr] : sends) {
      MPI_Request request = MPI_REQUEST_NULL;
      MPI_Isend(ptr, N, MPI_FLOAT, dest, 0, MPI_COMM_WORLD, &request);
      requests.push_back(request);
    }

    for (auto &[src, ptr] : recvs) {
      MPI_Request request = MPI_REQUEST_NULL;
      MPI_Irecv(ptr, N, MPI_FLOAT, src, 0, MPI_COMM_WORLD, &request);
      requests.push_back(request);
    }

    MPI_Waitall(requests.size(), requests.data(), MPI_STATUS_IGNORE);

    const unsigned long l_end =
        std::chrono::high_resolution_clock::now().time_since_epoch().count();
    unsigned long start, end;
    MPI_Reduce(&l_start, &start, 1, MPI_UNSIGNED_LONG, MPI_MIN, 0, MPI_COMM_WORLD);
    MPI_Reduce(&l_end, &end, 1, MPI_UNSIGNED_LONG, MPI_MAX, 0, MPI_COMM_WORLD);
    const unsigned long time = end - start;
    min_time = std::min(time, min_time);
  }
  return min_time;
}

int main(int argc, char *argv[]) {
  // Wall-clock for the whole kernel, reported as KERNEL_TIME.
  health_checks::KernelTimer kernel_timer_("peer2pear");


  std::string mode = (argc == 1) ? "Tile2Tile" : argv[1];
  MPI_Init(NULL, NULL);
  int world_size, world_rank;
  MPI_Comm_size(MPI_COMM_WORLD, &world_size);
  MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);
  // Emit the rank -> host/tile map so a slow aggregate can be
  // attributed to specific hardware.
  health_checks::print_rank_identity("peer2pear");
  int num_pair = world_size / 2;

  sycl::queue Q(sycl::gpu_selector_v);
  const int N = 1 << 25;
  const int N_byte = N * sizeof(float);
  auto *a_gpu = sycl::malloc_device<float>(N, Q);
  fill_randomly(Q, N, {a_gpu});

  std::vector<std::pair<int, float *>> sends;
  std::vector<std::pair<int, float *>> recvs;

  if (world_rank % 2 == 0)
    sends.push_back({world_rank + 1, a_gpu});
  else
    recvs.push_back({world_rank - 1, a_gpu});

  auto unitime = datatransfer(N, sends, recvs);
  if (world_rank == 0) {
    const double unitime_bw = (N_byte * num_pair) / unitime;
    std::cout << mode << " Unidirectional Bandwidth: " << unitime_bw << " GB/s" << std::endl;
  }
  if (world_rank % 2 == 0)
    recvs.push_back({world_rank + 1, a_gpu});
  else
    sends.push_back({world_rank - 1, a_gpu});

  auto bitime = datatransfer(N, sends, recvs);
  if (world_rank == 0) {
    const double bitime_bw = (2L * N_byte * num_pair) / bitime;
    std::cout << mode << " Bidirectional Bandwidth: " << bitime_bw << " GB/s" << std::endl;
  }
}

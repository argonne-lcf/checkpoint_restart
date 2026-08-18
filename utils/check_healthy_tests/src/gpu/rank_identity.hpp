// rank_identity.hpp -- shared rank/host/tile attribution for the GPU kernels.
//
// The GPU microkernels report a single aggregate number from rank 0, which is
// enough to say "this allocation is slow" but not "this tile is slow". Without
// a rank-to-host mapping the aggregate cannot be attributed to hardware, so a
// slow node cannot be named and therefore cannot be drained.
//
// print_rank_identity() gathers each rank's hostname and ZE_AFFINITY_MASK and
// prints one RANK_MAP line per rank from rank 0. It deliberately does NOT
// touch the kernels' existing output lines, because tools/gen_mk_table.py
// matches those with startswith() on the metric name.
//
// Every emitted line is prefixed RANK_MAP or RANK_NOTE so it can be grepped
// and cannot collide with a metric line.
//
// Usage, immediately after MPI_Comm_rank:
//     print_rank_identity("triad");

#ifndef HEALTH_CHECKS_RANK_IDENTITY_HPP
#define HEALTH_CHECKS_RANK_IDENTITY_HPP

#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>

#include <mpi.h>
#include <unistd.h>

namespace health_checks {

constexpr int kRankIdHostLen = 64;
constexpr int kRankIdMaskLen = 32;

// This rank's hostname, or "unknown" if it cannot be read. Used both for the
// rank map and to name the hardware in a validation failure.
inline std::string rank_host() {
  char host[kRankIdHostLen];
  std::memset(host, 0, sizeof(host));
  if (gethostname(host, sizeof(host) - 1) != 0)
    std::strncpy(host, "unknown", sizeof(host) - 1);
  return std::string(host);
}

// This rank's tile affinity from ZE_AFFINITY_MASK, or "unset". On Aurora the
// launch wrapper assigns one tile per rank, so this identifies the device that
// produced a result.
inline std::string rank_tile() {
  const char *env_mask = std::getenv("ZE_AFFINITY_MASK");
  return std::string(env_mask ? env_mask : "unset");
}

// Gathers hostname and tile affinity for every rank and prints the map from
// rank 0. Collective: every rank must call it.
inline void print_rank_identity(const std::string &kernel_name) {
  int world_size = 1, world_rank = 0;
  MPI_Comm_size(MPI_COMM_WORLD, &world_size);
  MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);

  char host[kRankIdHostLen];
  std::memset(host, 0, sizeof(host));
  std::strncpy(host, rank_host().c_str(), sizeof(host) - 1);

  char mask[kRankIdMaskLen];
  std::memset(mask, 0, sizeof(mask));
  std::strncpy(mask, rank_tile().c_str(), sizeof(mask) - 1);

  std::vector<char> all_hosts, all_masks;
  if (world_rank == 0) {
    all_hosts.resize(static_cast<size_t>(kRankIdHostLen) * world_size);
    all_masks.resize(static_cast<size_t>(kRankIdMaskLen) * world_size);
  }

  MPI_Gather(host, kRankIdHostLen, MPI_CHAR, all_hosts.data(), kRankIdHostLen, MPI_CHAR, 0,
             MPI_COMM_WORLD);
  MPI_Gather(mask, kRankIdMaskLen, MPI_CHAR, all_masks.data(), kRankIdMaskLen, MPI_CHAR, 0,
             MPI_COMM_WORLD);

  if (world_rank != 0)
    return;

  bool masks_usable = true;
  for (int r = 0; r < world_size; r++) {
    if (std::string(&all_masks[static_cast<size_t>(r) * kRankIdMaskLen]) == "unset") {
      masks_usable = false;
      break;
    }
  }

  std::cout << "RANK_NOTE kernel=" << kernel_name << " ranks=" << world_size << std::endl;
  if (!masks_usable) {
    // Without the wrapper every rank can land on the same tile, which makes
    // the mapping misleading rather than merely incomplete.
    std::cout << "RANK_NOTE ZE_AFFINITY_MASK unset on at least one rank; ranks may share a tile. "
                 "Launch through scripts/gpu_tile_compact.sh."
              << std::endl;
  }

  for (int r = 0; r < world_size; r++) {
    std::cout << "RANK_MAP rank=" << std::setw(4) << std::left << r
              << " host=" << std::setw(22) << std::left
              << std::string(&all_hosts[static_cast<size_t>(r) * kRankIdHostLen])
              << " tile=" << std::string(&all_masks[static_cast<size_t>(r) * kRankIdMaskLen])
              << std::endl;
  }
  std::cout.flush();
}

}  // namespace health_checks

#endif  // HEALTH_CHECKS_RANK_IDENTITY_HPP

// kernel_timer.hpp -- uniform wall-clock reporting for the C++ microkernels.
//
// Every kernel prints one line just before it exits:
//
//   KERNEL_TIME <name> <seconds> s
//
// and, where a kernel runs several distinct phases, one line per phase:
//
//   PHASE_TIME <kernel> <phase> <seconds> s
//
// The prefixes are deliberately distinct from every metric line the kernels
// already emit, so tools/gen_mk_table.py (which matches lines by startswith on
// the precision name) keeps parsing exactly what it parsed before.
//
// Timing is host wall clock, taken on rank 0 only. That is the number a user
// waiting on a job actually experiences; it deliberately includes allocation,
// warmup, verification and MPI barriers, which per-iteration kernel timings
// exclude. A kernel's own reported throughput and this figure answer different
// questions and will not agree.

#ifndef HEALTH_CHECKS_KERNEL_TIMER_HPP
#define HEALTH_CHECKS_KERNEL_TIMER_HPP

#include <chrono>
#include <cstdio>
#include <string>

#ifdef HEALTH_CHECKS_HAVE_MPI_TIMER
#include <mpi.h>
#endif

namespace health_checks {

class KernelTimer {
public:
  explicit KernelTimer(std::string name)
      : name_(std::move(name)), start_(clock::now()), phase_(clock::now()) {}

  // Report a named phase and reset the phase clock.
  void phase(const std::string &label) {
    const double secs = seconds_since(phase_);
    if (is_root()) {
      std::printf("PHASE_TIME %s %s %.3f s\n", name_.c_str(), label.c_str(), secs);
      std::fflush(stdout);
    }
    phase_ = clock::now();
  }

  // Total elapsed since construction. Safe to call more than once.
  double total() const { return seconds_since(start_); }

  // Emitted automatically so a kernel cannot forget to report, including on
  // an early return.
  ~KernelTimer() {
    if (reported_) {
      return;
    }
    const double secs = total();
    if (is_root()) {
      std::printf("KERNEL_TIME %s %.3f s\n", name_.c_str(), secs);
      std::fflush(stdout);
    }
  }

  // Report early and suppress the destructor's line. Use before MPI_Finalize
  // so the print still happens while MPI is alive.
  void report() {
    if (reported_) {
      return;
    }
    const double secs = total();
    if (is_root()) {
      std::printf("KERNEL_TIME %s %.3f s\n", name_.c_str(), secs);
      std::fflush(stdout);
    }
    reported_ = true;
  }

private:
  using clock = std::chrono::steady_clock;

  static double seconds_since(const clock::time_point &t) {
    return std::chrono::duration<double>(clock::now() - t).count();
  }

  // Only rank 0 prints. Without MPI, or once MPI has finalized, every process
  // prints -- which for a serial kernel is exactly one line.
  static bool is_root() {
#ifdef HEALTH_CHECKS_HAVE_MPI_TIMER
    int initialized = 0;
    int finalized = 0;
    MPI_Initialized(&initialized);
    MPI_Finalized(&finalized);
    if (initialized && !finalized) {
      int rank = 0;
      MPI_Comm_rank(MPI_COMM_WORLD, &rank);
      return rank == 0;
    }
#endif
    return true;
  }

  std::string name_;
  clock::time_point start_;
  clock::time_point phase_;
  bool reported_ = false;
};

} // namespace health_checks

#endif // HEALTH_CHECKS_KERNEL_TIMER_HPP

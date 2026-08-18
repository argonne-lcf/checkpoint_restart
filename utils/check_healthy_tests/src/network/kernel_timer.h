/* kernel_timer.h -- uniform wall-clock reporting for the C microkernels.
 *
 * C counterpart of kernel_timer.hpp. Prints one line before exit:
 *
 *   KERNEL_TIME <name> <seconds> s
 *
 * Usage:
 *   kernel_timer_t t;
 *   kernel_timer_start(&t, "simple_injection_bisection");
 *   ...
 *   kernel_timer_report(&t);   // call BEFORE MPI_Finalize
 *
 * Rank 0 prints when MPI is live; otherwise the calling process prints.
 */

#ifndef HEALTH_CHECKS_KERNEL_TIMER_H
#define HEALTH_CHECKS_KERNEL_TIMER_H

#include <stdio.h>
#include <time.h>

#ifdef HEALTH_CHECKS_HAVE_MPI_TIMER
#include <mpi.h>
#endif

typedef struct {
  struct timespec start;
  const char *name;
  int reported;
} kernel_timer_t;

static inline void kernel_timer_start(kernel_timer_t *t, const char *name) {
  t->name = name;
  t->reported = 0;
  clock_gettime(CLOCK_MONOTONIC, &t->start);
}

static inline double kernel_timer_elapsed(const kernel_timer_t *t) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (double)(now.tv_sec - t->start.tv_sec) +
         (double)(now.tv_nsec - t->start.tv_nsec) / 1e9;
}

static inline int kernel_timer_is_root(void) {
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
  return 1;
}

static inline void kernel_timer_report(kernel_timer_t *t) {
  double secs;
  if (t->reported) {
    return;
  }
  secs = kernel_timer_elapsed(t);
  if (kernel_timer_is_root()) {
    printf("KERNEL_TIME %s %.3f s\n", t->name, secs);
    fflush(stdout);
  }
  t->reported = 1;
}

#endif /* HEALTH_CHECKS_KERNEL_TIMER_H */

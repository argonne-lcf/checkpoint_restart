// inj_bis_ordered.c
// Runs both injection and bisection by default (1 MiB).
// Output is globally ordered: first by hostname (lexicographic), then by rank.
// Each line: "<hostname> rank=XX | ...", with zero-padded ranks.

#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdarg.h>
#include <unistd.h>

#define DEFAULT_MSG_SIZE (1<<20)   // 1 MiB
#define DEFAULT_NITERS   100
#define HOSTLEN          256

// ---------------- Globals for printing & ordering ----------------
static char g_hostname[HOSTLEN] = "unknown";
static int  g_rank_digits = 1;      // zero-padding width
static int *g_order = NULL;         // permutation of ranks sorted by (hostname, rank)
static int  g_nprocs = 1;
static int  g_rank   = 0;

// Normal print (no global ordering), with padded rank
static void print_hr(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    printf("%s rank=%0*d | ", g_hostname, g_rank_digits, g_rank);
    vprintf(fmt, ap);
    printf("\n");
    fflush(stdout);
    va_end(ap);
}

// Build global order: gather hostnames, sort by (hostname, rank)
static void build_global_order(MPI_Comm comm) {
    char *all_hosts = (char*)malloc(g_nprocs * HOSTLEN);
    if (!all_hosts) { fprintf(stderr, "OOM: all_hosts\n"); MPI_Abort(comm, 1); }

    MPI_Allgather(g_hostname, HOSTLEN, MPI_CHAR,
                  all_hosts, HOSTLEN, MPI_CHAR, comm);

    g_order = (int*)malloc(g_nprocs * sizeof(int));
    if (!g_order) { fprintf(stderr, "OOM: g_order\n"); MPI_Abort(comm, 1); }
    for (int i = 0; i < g_nprocs; ++i) g_order[i] = i;

    // Stable insertion sort by (hostname, rank)
    for (int i = 1; i < g_nprocs; ++i) {
        int key = g_order[i];
        int j = i - 1;
        while (j >= 0) {
            const char *ha = all_hosts + g_order[j] * HOSTLEN;
            const char *hb = all_hosts + key * HOSTLEN;
            int c = strcmp(ha, hb);
            if (c > 0 || (c == 0 && g_order[j] > key)) {
                g_order[j+1] = g_order[j];
                --j;
            } else break;
        }
        g_order[j+1] = key;
    }

    free(all_hosts);
}

// Ordered print: all ranks print in global order (hostname, then rank)
static void print_hr_ordered(MPI_Comm comm, int enabled, const char *fmt, ...) {
    char line[1024] = {0};
    if (enabled) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(line, sizeof(line), fmt, ap);
        va_end(ap);
    }
    for (int pos = 0; pos < g_nprocs; ++pos) {
        if (enabled && g_order[pos] == g_rank) {
            printf("%s rank=%0*d | %s\n", g_hostname, g_rank_digits, g_rank, line);
            fflush(stdout);
        }
        MPI_Barrier(comm); // advance to next rank in the global order
    }
}

// ---------------- Helpers ----------------
static size_t parse_size(const char *arg) {
    char *end;
    double val = strtod(arg, &end);
    size_t mult = 1;
    if (*end != '\0') {
        switch (tolower(*end)) {
            case 'k': mult = 1UL << 10; break;
            case 'm': mult = 1UL << 20; break;
            case 'g': mult = 1UL << 30; break;
            default:
                fprintf(stderr, "Unknown size suffix '%c' in %s\n", *end, arg);
                MPI_Abort(MPI_COMM_WORLD, 1);
        }
    }
    return (size_t)(val * mult);
}
static int parse_iters(const char *arg) { return atoi(arg); }

// ---------------- Injection test (deadlock-safe, nonblocking) ----------------
static void run_injection_test(MPI_Comm nodecomm,
                               int local_rank,
                               char *buf, int niters, size_t msg_size,
                               double *global_inj_oneway, double *global_inj_bidirectional) {
    int nprocs;
    MPI_Comm_size(MPI_COMM_WORLD, &nprocs);

    MPI_Request *reqs_send = (MPI_Request*)malloc((nprocs-1) * sizeof(MPI_Request));
    MPI_Request *reqs_recv = (MPI_Request*)malloc((nprocs-1) * sizeof(MPI_Request));
    char **recvbufs = (char**)malloc((nprocs-1) * sizeof(char*));
    if (!reqs_send || !reqs_recv || !recvbufs) { print_hr("OOM"); MPI_Abort(MPI_COMM_WORLD, 1); }
    for (int i = 0; i < nprocs-1; i++) {
        recvbufs[i] = (char*)malloc(msg_size);
        if (!recvbufs[i]) { print_hr("OOM recvbuf"); MPI_Abort(MPI_COMM_WORLD, 1); }
    }

    MPI_Barrier(MPI_COMM_WORLD);
    double t0 = MPI_Wtime();

    for (int it = 0; it < niters; ++it) {
        int idx = 0;
        for (int src = 0; src < nprocs; ++src) {
            if (src == g_rank) continue;
            MPI_Irecv(recvbufs[idx], (int)msg_size, MPI_CHAR, src, 100,
                      MPI_COMM_WORLD, &reqs_recv[idx]);
            idx++;
        }
        idx = 0;
        for (int dst = 0; dst < nprocs; ++dst) {
            if (dst == g_rank) continue;
            MPI_Isend(buf, (int)msg_size, MPI_CHAR, dst, 100,
                      MPI_COMM_WORLD, &reqs_send[idx++]);
        }
        MPI_Waitall(nprocs-1, reqs_send, MPI_STATUSES_IGNORE);
        MPI_Waitall(nprocs-1, reqs_recv, MPI_STATUSES_IGNORE);
    }

    double t1 = MPI_Wtime();

    double bytes_sent_oneway = (double)(nprocs - 1) * (double)msg_size * (double)niters;
    double rank_inj_bw_oneway = (bytes_sent_oneway / (t1 - t0)) / 1e9;

    // Per-rank (ordered) print
    print_hr_ordered(MPI_COMM_WORLD, 1,
                     "injection (one-way send only) = %.3f GB/s", rank_inj_bw_oneway);

    // Optional node aggregate (ordered; only local_rank==0 prints)
    double node_inj = 0.0;
    MPI_Reduce(&rank_inj_bw_oneway, &node_inj, 1, MPI_DOUBLE, MPI_SUM, 0, nodecomm);
    print_hr_ordered(MPI_COMM_WORLD, (local_rank == 0),
                     "[node aggregate injection] = %.3f GB/s", node_inj);

    // Global aggregate (rank 0 only)
    MPI_Reduce(&rank_inj_bw_oneway, global_inj_oneway, 1, MPI_DOUBLE, MPI_SUM, 0, MPI_COMM_WORLD);
    *global_inj_bidirectional = *global_inj_oneway * 2.0;
    if (g_rank == 0) {
        print_hr("GLOBAL injection (one-way)       = %.3f GB/s", *global_inj_oneway);
        print_hr("GLOBAL injection (bidirectional) = %.3f GB/s (approx)", *global_inj_bidirectional);
    }

    for (int i = 0; i < nprocs-1; i++) free(recvbufs[i]);
    free(recvbufs);
    free(reqs_send);
    free(reqs_recv);
}

// ---------------- Bisection test ----------------
static void run_bisection_test(char *buf, int niters, size_t msg_size,
                               double global_inj_oneway, double global_inj_bidirectional) {
    int nprocs;
    MPI_Comm_size(MPI_COMM_WORLD, &nprocs);
    int half = nprocs / 2;
    if (half == 0) {
        if (g_rank == 0) print_hr("Need at least 2 ranks for bisection test");
        return;
    }
    int partner = (g_rank < half) ? g_rank + half : g_rank - half;

    MPI_Barrier(MPI_COMM_WORLD);
    double tb0 = MPI_Wtime();

    for (int it = 0; it < niters; ++it) {
        MPI_Request r[2];
        MPI_Isend(buf, (int)msg_size, MPI_CHAR, partner, 200, MPI_COMM_WORLD, &r[0]);
        MPI_Irecv(buf, (int)msg_size, MPI_CHAR, partner, 200, MPI_COMM_WORLD, &r[1]);
        MPI_Waitall(2, r, MPI_STATUSES_IGNORE);
    }

    double tb1 = MPI_Wtime();
    double rank_bytes_two_way = (double)msg_size * (double)niters * 2.0;
    double rank_bw_two_way = (rank_bytes_two_way / (tb1 - tb0)) / 1e9;

    // Per-rank (ordered) print
    print_hr_ordered(MPI_COMM_WORLD, 1,
                     "bisection (two-way with partner %d) = %.3f GB/s",
                     partner, rank_bw_two_way);

    double total_bis_bytes_two_way = 0.0;
    MPI_Reduce(&rank_bytes_two_way, &total_bis_bytes_two_way, 1, MPI_DOUBLE, MPI_SUM, 0, MPI_COMM_WORLD);

    if (g_rank == 0) {
        double bis_total_bw_two_way = (total_bis_bytes_two_way / (tb1 - tb0)) / 1e9;
        double bis_total_bw_one_way = bis_total_bw_two_way / 2.0;
        print_hr("Bisection measured (two-way aggregate) = %.3f GB/s", bis_total_bw_two_way);
        print_hr("Bisection measured (one-way  aggregate) = %.3f GB/s", bis_total_bw_one_way);

        double nb_oneway = (global_inj_oneway > 0) ? (bis_total_bw_one_way / global_inj_oneway * 100.0) : 0.0;
        double nb_bidirectional = (global_inj_bidirectional > 0) ? (bis_total_bw_two_way / global_inj_bidirectional * 100.0) : 0.0;
        print_hr("Non-blocking %% (one-way)        = %.2f %%", nb_oneway);
        print_hr("Non-blocking %% (bidirectional) = %.2f %%", nb_bidirectional);
    }
}

// ---------------- Main ----------------
int main(int argc, char *argv[]) {
    MPI_Init(&argc, &argv);

    // hostname for all prints
    if (gethostname(g_hostname, sizeof(g_hostname)) != 0) {
        strncpy(g_hostname, "unknown", sizeof(g_hostname)-1);
        g_hostname[sizeof(g_hostname)-1] = '\0';
    }

    MPI_Comm_rank(MPI_COMM_WORLD, &g_rank);
    MPI_Comm_size(MPI_COMM_WORLD, &g_nprocs);

    // zero-padding width for rank
    { int maxr = (g_nprocs > 0 ? g_nprocs - 1 : 0);
      g_rank_digits = 1; while (maxr >= 10) { g_rank_digits++; maxr /= 10; } }

    // Build global ordering (hostname, then rank)
    build_global_order(MPI_COMM_WORLD);

    // Node-local communicator (for optional node aggregates)
    MPI_Comm nodecomm;
    MPI_Comm_split_type(MPI_COMM_WORLD, MPI_COMM_TYPE_SHARED, 0, MPI_INFO_NULL, &nodecomm);
    int local_rank = 0, local_size = 1;
    MPI_Comm_rank(nodecomm, &local_rank);
    MPI_Comm_size(nodecomm, &local_size);

    // Defaults: both tests, 1 MiB, 100 iters
    size_t msg_size = DEFAULT_MSG_SIZE;
    int niters = DEFAULT_NITERS;
    int run_injection = 1, run_bisection = 1;

    // Parse options
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--size") == 0 && i+1 < argc) msg_size = parse_size(argv[++i]);
        else if (strcmp(argv[i], "--iters") == 0 && i+1 < argc) niters = parse_iters(argv[++i]);
        else if (strcmp(argv[i], "--inject") == 0)   { run_injection = 1; run_bisection = 0; }
        else if (strcmp(argv[i], "--bisection") == 0){ run_injection = 0; run_bisection = 1; }
        else if (strcmp(argv[i], "--all") == 0)      { run_injection = 1; run_bisection = 1; }
    }

    if (g_rank == 0) {
        print_hr("Running tests with msg_size=%zu bytes, niters=%d", msg_size, niters);
        print_hr("Modes: %s%s", run_injection ? "Injection " : "", run_bisection ? "Bisection" : "");
    }

    // Buffers
    char *buf = (char*)malloc(msg_size);
    if (!buf) { print_hr("Allocation failed for msg_size=%zu", msg_size); MPI_Abort(MPI_COMM_WORLD, 1); }
    memset(buf, 1 + (g_rank % 7), msg_size);

    double global_inj_oneway = 0.0, global_inj_bidirectional = 0.0;

    if (run_injection) {
        run_injection_test(nodecomm, local_rank, buf, niters, msg_size,
                           &global_inj_oneway, &global_inj_bidirectional);
    }

    if (run_bisection) {
        if (!run_injection) {
            // if injection wasn't run, set a placeholder aggregate
            double inj_tmp = 0.0;
            MPI_Reduce(&inj_tmp, &global_inj_oneway, 1, MPI_DOUBLE, MPI_SUM, 0, MPI_COMM_WORLD);
            global_inj_bidirectional = global_inj_oneway * 2.0;
        }
        run_bisection_test(buf, niters, msg_size, global_inj_oneway, global_inj_bidirectional);
    }

    free(buf);
    free(g_order);
    MPI_Comm_free(&nodecomm);
    MPI_Finalize();
    return 0;
}
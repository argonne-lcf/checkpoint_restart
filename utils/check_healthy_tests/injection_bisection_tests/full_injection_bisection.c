#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdarg.h>
#include <unistd.h>

#define DEFAULT_MSG_SIZE (1<<20)   // 1 MB
#define DEFAULT_NITERS   100
#define HOSTLEN          256

// -------------------- globals for printing/order --------------------
static char g_hostname[HOSTLEN] = "unknown";
static int  g_rank_digits   = 1;         // width for zero-padding (computed in main)
static int  g_rank          = 0;
static int  g_nprocs        = 1;
static int *g_order         = NULL;      // permutation: ranks sorted by (hostname, rank)

// Normal print (no ordering), with padded rank
static void print_hr(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    printf("%s rank=%0*d | ", g_hostname, g_rank_digits, g_rank);
    vprintf(fmt, ap);
    printf("\n");
    fflush(stdout);
    va_end(ap);
}

// Build global print order: first by hostname (lexicographic), then by rank
static void build_global_order(MPI_Comm comm) {
    char *all_hosts = (char*)malloc(g_nprocs * HOSTLEN);
    if (!all_hosts) { fprintf(stderr, "OOM: all_hosts\n"); MPI_Abort(comm, 1); }

    MPI_Allgather(g_hostname, HOSTLEN, MPI_CHAR,
                  all_hosts,   HOSTLEN, MPI_CHAR, comm);

    g_order = (int*)malloc(g_nprocs * sizeof(int));
    if (!g_order) { fprintf(stderr, "OOM: g_order\n"); MPI_Abort(comm, 1); }
    for (int i = 0; i < g_nprocs; ++i) g_order[i] = i;

    // Stable insertion sort by (hostname, rank)
    for (int i = 1; i < g_nprocs; ++i) {
        int key = g_order[i];
        int j = i - 1;
        while (j >= 0) {
            const char *ha = all_hosts + g_order[j] * HOSTLEN;
            const char *hb = all_hosts + key        * HOSTLEN;
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

// Ordered print: all ranks print in strictly increasing order by (hostname, rank)
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
        MPI_Barrier(comm);
    }
}

// --------------------------------------------------
// Helpers
// --------------------------------------------------
size_t parse_size(const char *arg) {
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

int parse_iters(const char *arg) {
    return atoi(arg);
}

// --------------------------------------------------
// Injection Bandwidth Test
// --------------------------------------------------
double run_injection_test(char *sendbuf, char *recvbuf, int niters, size_t msg_size) {
    MPI_Barrier(MPI_COMM_WORLD);

    int nprocs;
    MPI_Comm_size(MPI_COMM_WORLD, &nprocs);

    double t_start = MPI_Wtime();
    for (int it = 0; it < niters; it++) {
        for (int peer = 0; peer < nprocs; peer++) {
            if (peer == g_rank) continue;
            MPI_Sendrecv(sendbuf, (int)msg_size, MPI_CHAR, peer, 0,
                         recvbuf, (int)msg_size, MPI_CHAR, peer, 0,
                         MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        }
    }
    double t_end = MPI_Wtime();

    double local_bytes = (double)(nprocs - 1) * (double)msg_size * (double)niters * 2.0;
    double local_bw = (local_bytes / (t_end - t_start)) / 1e9;

    // Ordered per-rank print
    print_hr_ordered(MPI_COMM_WORLD, 1, "injection BW = %.2f GB/s", local_bw);

    double global_bw = 0.0;
    MPI_Reduce(&local_bw, &global_bw, 1, MPI_DOUBLE, MPI_SUM, 0, MPI_COMM_WORLD);

    if (g_rank == 0) {
        print_hr("GLOBAL injection bandwidth = %.2f GB/s", global_bw);
    }

    return local_bw;
}

// --------------------------------------------------
// Bisection Bandwidth Test
// --------------------------------------------------
double run_bisection_test(char *sendbuf, char *recvbuf, int niters, size_t msg_size) {
    int nprocs;
    MPI_Comm_size(MPI_COMM_WORLD, &nprocs);
    int half = nprocs / 2;
    if (half == 0) {
        if (g_rank == 0) print_hr("Need at least 2 ranks for bisection test");
        return 0.0;
    }
    int partner = (g_rank < half) ? g_rank + half : g_rank - half;

    MPI_Barrier(MPI_COMM_WORLD);

    double t_start = MPI_Wtime();
    for (int it = 0; it < niters; it++) {
        MPI_Sendrecv(sendbuf, (int)msg_size, MPI_CHAR, partner, 0,
                     recvbuf, (int)msg_size, MPI_CHAR, partner, 0,
                     MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    }
    double t_end = MPI_Wtime();

    double bis_local_bytes = (double)msg_size * (double)niters * 2.0;
    double bis_local_bw = (bis_local_bytes / (t_end - t_start)) / 1e9;

    // Ordered per-rank print
    print_hr_ordered(MPI_COMM_WORLD, 1,
                     "bisection BW (partner=%d) = %.2f GB/s", partner, bis_local_bw);

    double bis_total_bw = 0.0;
    MPI_Reduce(&bis_local_bw, &bis_total_bw, 1, MPI_DOUBLE, MPI_SUM, 0, MPI_COMM_WORLD);

    if (g_rank == 0) {
        print_hr("BISECTION bandwidth (aggregate two-way) = %.2f GB/s", bis_total_bw);
    }

    return bis_local_bw;
}

// --------------------------------------------------
// Main
// --------------------------------------------------
int main(int argc, char *argv[]) {
    MPI_Init(&argc, &argv);

    // hostname for all prints
    if (gethostname(g_hostname, sizeof(g_hostname)) != 0) {
        strncpy(g_hostname, "unknown", sizeof(g_hostname)-1);
        g_hostname[sizeof(g_hostname)-1] = '\0';
    }

    MPI_Comm_rank(MPI_COMM_WORLD, &g_rank);
    MPI_Comm_size(MPI_COMM_WORLD, &g_nprocs);

    // Compute width for zero-padded rank label
    {
        int maxr = (g_nprocs > 0 ? g_nprocs - 1 : 0);
        g_rank_digits = 1;
        while (maxr >= 10) { g_rank_digits++; maxr /= 10; }
    }

    // Build global (hostname,rank) ordering for prints
    build_global_order(MPI_COMM_WORLD);

    size_t msg_size = DEFAULT_MSG_SIZE;
    int niters = DEFAULT_NITERS;

    // Default: run BOTH tests unless user forces just one mode
    int run_injection = 1, run_bisection = 1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--size") == 0 && i+1 < argc) {
            msg_size = parse_size(argv[++i]);
        } else if (strcmp(argv[i], "--iters") == 0 && i+1 < argc) {
            niters = parse_iters(argv[++i]);
        } else if (strcmp(argv[i], "injection") == 0) {
            run_injection = 1; run_bisection = 0;
        } else if (strcmp(argv[i], "bisection") == 0) {
            run_injection = 0; run_bisection = 1;
        }
    }

    if (g_rank == 0) {
        print_hr("Running tests with msg_size=%zu bytes, niters=%d", msg_size, niters);
        print_hr("Modes: %s%s", run_injection ? "Injection " : "", run_bisection ? "Bisection" : "");
    }

    // Buffers
    char *sendbuf = (char*)malloc(msg_size);
    char *recvbuf = (char*)malloc(msg_size);
    if (!sendbuf || !recvbuf) {
        print_hr("Allocation failed for msg_size=%zu", msg_size);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }
    memset(sendbuf, 1, msg_size);
    memset(recvbuf, 0, msg_size);

    // Run tests (in order: injection then bisection if both selected)
    if (run_injection) {
        run_injection_test(sendbuf, recvbuf, niters, msg_size);
    }
    if (run_bisection) {
        run_bisection_test(sendbuf, recvbuf, niters, msg_size);
    }

    free(sendbuf);
    free(recvbuf);
    free(g_order);
    MPI_Finalize();
    return 0;
}
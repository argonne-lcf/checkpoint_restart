// mem_and_gpu_row.cpp -- one-line CPU and GPU memory inventory.
//
// Emits a single TSV or CSV row describing host memory (parsed from
// /proc/meminfo) and Intel GPU memory (queried through Level Zero). Designed
// to be run per node and concatenated, so a whole job's memory state is one
// table.
//
// This is the only microkernel with no build-time GPU dependency: the Level
// Zero loader is opened with dlopen at run time and every entry point is
// resolved with dlsym. On a node with no GPU or no loader the GPU columns come
// back zero and the process still exits 0.
//
// GPU QUERY, TWO PATHS
//   Sysman  zesInit -> zesDriverGet -> zesDeviceGet -> zesDeviceEnumMemoryModules
//           -> zesMemoryGetState. Reports both total and used. Preferred.
//   Core    zeDeviceGetMemoryProperties. Reports total only; there is no used
//           figure in the core API. Used when Sysman is unavailable.
//   The core path scans the returned property struct for a plausible 64-bit
//   size (1 GiB to 16 TiB) every 4 bytes rather than casting to a fixed struct
//   layout, because that layout varies across Level Zero versions. It is
//   deliberately tolerant, and it is why the core numbers should be treated as
//   approximate.
//
// USAGE   mem_and_gpu_row [--csv] [--no-header] [--ze <path to libze_loader>]
// OUTPUT  A header line (unless --no-header) and one data row.
//
// READING THE OUTPUT
//   low mem_available_mib + high anon_lru_mib      real pressure from processes
//   high filecache_* but mem_available_mib large   cache, not pressure
//   sysman columns zero, core columns nonzero      Sysman disabled by policy
//   all GPU columns zero                           non-GPU node, or no /dev/dri
//
// COLUMN NOTES
//   mem_used_incl_cache_mib  MemTotal - MemFree; includes cache and buffers
//   nonreclaim_est_mib       MemTotal - MemFree - Buffers - Cached - KReclaimable;
//                            a heuristic for memory that will not free up
//                            quickly under pressure
//   Slab = SReclaimable + SUnreclaim, and KReclaimable already includes
//   SReclaimable. Do not sum those columns together.

// mem_and_gpu_row.cpp
// One-line system summary (TSV/CSV): timestamp, hostname, CPU RAM buckets (MiB), Intel GPU memory.
// Sysman path (zesInit->zesDriverGet->zesDeviceGet->zesMemoryGetState) for used/total,
// and a robust Level Zero *core* fallback for total VRAM when Sysman is unavailable.

// g++ -O2 -std=gnu++17 -pthread mem_and_gpu_row.cpp -o mem_and_gpu_row -ldl
// # Typical (TSV with header)
// ./mem_and_gpu_row

// # CSV
// ./mem_and_gpu_row --csv

// # No header (just the row)
// ./mem_and_gpu_row --no-header

// # Point to a specific loader
// ZES_ENABLE_SYSMAN=1 ./mem_and_gpu_row --ze /usr/lib64/libze_loader.so



// CPU RAM (from /proc/meminfo)
// 	•	mem_total_mib – MemTotal: total physical RAM.
// 	•	mem_used_incl_cache_mib – MemTotal - MemFree; a coarse “used” that includes caches and buffers.
// 	•	mem_available_mib – MemAvailable: kernel’s estimate of memory you could use without swapping (accounts for cache reclaimability).
// 	•	anon_lru_mib – Active(anon) + Inactive(anon): anonymous memory on the LRU lists (heap/stack/pages backing processes, not file-backed).
// 	•	filecache_lru_mib – Active(file) + Inactive(file): file-backed page cache on LRUs (reclaimable under pressure).
// 	•	filecache_cached_minus_shmem_mib – max(Cached - Shmem, 0): another view of file cache that removes tmpfs/IPC shared memory from Cached.
// 	•	shmem_mib – Shmem: tmpfs/IPC shared memory (e.g., /dev/shm, tmpfs files); distinct from file cache.
// 	•	slab_mib – Slab: kernel metadata allocations.
// 	•	sreclaimable_mib – SReclaimable: reclaimable portion of Slab (e.g., dentries, inodes).
// 	•	sunreclaimable_mib – SUnreclaim: non-reclaimable portion of Slab.
// 	•	kreclaimable_mib – KReclaimable: kernel memory considered reclaimable (often ≥ SReclaimable; don’t add both—they overlap).
// 	•	kernel_overheads_mib – PageTables + KernelStack: page tables and per-thread kernel stacks.
// 	•	nonreclaim_est_mib – Heuristic “hard used” estimate:

//     MemTotal - MemFree - Buffers - Cached - KReclaimable
//     Rough idea of what won’t drop quickly under pressure (not perfect, but useful).

// Note on overlaps: Slab = SReclaimable + SUnreclaim.
// KReclaimable includes SReclaimable (and sometimes more). Don’t sum them together.

// Intel GPU memory
// 	•	gpu_sysman_devices – Number of GPUs discovered via Level Zero Sysman (requires ZES_ENABLE_SYSMAN=1 and site support).
// 	•	gpu_sysman_total_mib – Sum of GPU memory sizes across Sysman memory modules (per device), via zesMemoryGetState(...).size.
// 	•	gpu_sysman_used_mib – Sum of GPU memory used (size - free) across Sysman memory modules.
// 	•	gpu_core_devices – Number of GPUs found via core Level Zero (zeDeviceGet) when Sysman isn’t available.
// 	•	gpu_core_total_mib – Sum of total VRAM from core memory properties (no “used” available in core). If this is 0, it usually means the runtime can’t expose VRAM totals in your environment (e.g., wrong node, missing /dev/dri, or driver policy).

// ⸻

// How to read it quickly
// 	•	Low mem_available_mib with high anon_lru_mib ⇒ real pressure from process memory.
// 	•	High filecache_* and high mem_used_incl_cache_mib, but mem_available_mib stays large ⇒ plenty of cache that can shrink; not real pressure.
// 	•	Lots of kreclaimable_mib / sreclaimable_mib ⇒ kernel can likely reclaim a chunk if needed.
// 	•	GPU: prefer gpu_sysman_* when present (has used). If Sysman columns are zero but gpu_core_* is nonzero, Sysman is disabled; you still get total VRAM via core. If both are zero, you’re likely on a non-GPU/login node or lack access to /dev/dri.


#include <algorithm>
#include <cstddef>
#include <cctype>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <dlfcn.h>
#include <errno.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <utility>
#include <vector>

#include "kernel_timer.hpp"

using namespace std;

// ---------------- utils ----------------
static inline bool fileExists(const string& p){ struct stat st{}; return ::stat(p.c_str(), &st) == 0; }
static inline string slurp(const string& p){ ifstream f(p); if(!f) return {}; return string((istreambuf_iterator<char>(f)), istreambuf_iterator<char>()); }
static inline long long kib_to_mib(long long kib){ return kib < 0 ? -1 : kib / 1024; }

static inline string timestamp_now_iso(){
    char buf[32];
    time_t t = time(nullptr);
    tm tmv; localtime_r(&t, &tmv);
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S", &tmv);
    return string(buf);
}
static inline string hostname_now(){
    char h[256]; if(gethostname(h, sizeof(h))!=0) return "unknown";
    h[sizeof(h)-1] = '\0'; return string(h);
}

// --------------- /proc/meminfo ---------------
struct MemInfo { unordered_map<string,long long> kv; }; // KiB
static MemInfo readMeminfo(){
    MemInfo mi; string t = slurp("/proc/meminfo"); istringstream is(t); string line;
    while(getline(is,line)){
        auto pos = line.find(':'); if(pos==string::npos) continue;
        string k = line.substr(0,pos);
        string v = line.substr(pos+1);
        long long x=0;
        for(size_t i=0;i<v.size();++i) if(isdigit((unsigned char)v[i])){
            size_t j=i; while(j<v.size() && isdigit((unsigned char)v[j])) ++j; x = stoll(v.substr(i,j-i)); break;
        }
        mi.kv[k]=x; // KiB
    }
    return mi;
}
static inline long long get(const MemInfo& mi, const string& k, long long d=0){
    auto it=mi.kv.find(k); return it==mi.kv.end()? d : it->second;
}

struct CpuRow {
    long long mem_total_mib=-1;
    long long mem_used_incl_cache_mib=-1;
    long long mem_available_mib=-1;
    long long anon_lru_mib=-1;
    long long filecache_lru_mib=-1;
    long long filecache_cached_minus_shmem_mib=-1;
    long long shmem_mib=-1;
    long long slab_mib=-1, sreclaim_mib=-1, sunreclaim_mib=-1;
    long long kreclaimable_mib=-1;
    long long kernel_overheads_mib=-1; // page tables + kernel stacks
    long long nonreclaim_est_mib=-1;   // MemTotal - MemFree - Buffers - Cached - KReclaimable
};
static CpuRow gather_cpu_row(){
    CpuRow r;
    auto mi = readMeminfo();
    if(mi.kv.empty()) return r;

    long long total   = get(mi,"MemTotal");
    long long free_   = get(mi,"MemFree");
    long long avail   = get(mi,"MemAvailable");
    long long buffers = get(mi,"Buffers");
    long long cached  = get(mi,"Cached");
    long long shmem   = get(mi,"Shmem");
    long long srecl   = get(mi,"SReclaimable");
    long long sunrecl = get(mi,"SUnreclaim");
    long long slab    = get(mi,"Slab");
    long long krecl   = get(mi,"KReclaimable"); // may be 0 on older kernels
    long long act_anon   = get(mi,"Active(anon)");
    long long inact_anon = get(mi,"Inactive(anon)");
    long long act_file   = get(mi,"Active(file)");
    long long inact_file = get(mi,"Inactive(file)");
    long long pagetab = get(mi,"PageTables");
    long long kstack  = get(mi,"KernelStack");

    long long used_incl_cache = total - free_;
    long long filecache_lru   = act_file + inact_file;
    long long filecache_cached_minus_shmem = max(cached - shmem, 0LL);
    long long anon_working_lru = act_anon + inact_anon;
    long long nonreclaim_est = max(total - free_ - buffers - cached - krecl, 0LL);

    r.mem_total_mib  = kib_to_mib(total);
    r.mem_used_incl_cache_mib = kib_to_mib(used_incl_cache);
    r.mem_available_mib = kib_to_mib(avail);
    r.anon_lru_mib   = kib_to_mib(anon_working_lru);
    r.filecache_lru_mib = kib_to_mib(filecache_lru);
    r.filecache_cached_minus_shmem_mib = kib_to_mib(filecache_cached_minus_shmem);
    r.shmem_mib      = kib_to_mib(shmem);
    r.slab_mib       = kib_to_mib(slab);
    r.sreclaim_mib   = kib_to_mib(srecl);
    r.sunreclaim_mib = kib_to_mib(sunrecl);
    r.kreclaimable_mib = kib_to_mib(krecl);
    r.kernel_overheads_mib = kib_to_mib(pagetab + kstack);
    r.nonreclaim_est_mib   = kib_to_mib(nonreclaim_est);
    return r;
}

// --------------- Level Zero dynamic ABI ---------------
// Core
using ze_result_t = int;
using ze_driver_handle_t = void*;
using ze_device_handle_t = void*;
// Sysman
using zes_result_t = int;
using zes_driver_handle_t = void*;
using zes_device_handle_t = void*;
using zes_mem_handle_t    = void*;

struct zes_mem_state_t {
    int32_t  health;      // zes_mem_health_t
    uint64_t free;        // bytes
    uint64_t size;        // bytes
    uint64_t reserved[6];
};

// Core fn ptrs
using PFN_zeInit    = ze_result_t (*)(uint32_t);
using PFN_zeDriverGet = ze_result_t (*)(uint32_t*, ze_driver_handle_t*);
using PFN_zeDeviceGet = ze_result_t (*)(ze_driver_handle_t, uint32_t*, ze_device_handle_t*);
using PFN_zeDeviceGetMemoryProperties = ze_result_t (*)(ze_device_handle_t, uint32_t*, void*);
// Sysman fn ptrs
using PFN_zesInit   = zes_result_t (*)(uint32_t);
using PFN_zesDriverGet = zes_result_t (*)(uint32_t*, zes_driver_handle_t*);
using PFN_zesDeviceGet = zes_result_t (*)(zes_driver_handle_t, uint32_t*, zes_device_handle_t*);
using PFN_zesDeviceEnumMemoryModules = zes_result_t (*)(zes_device_handle_t, uint32_t*, zes_mem_handle_t*);
using PFN_zesMemoryGetState = zes_result_t (*)(zes_mem_handle_t, zes_mem_state_t*);

struct L0 {
    void* lib=nullptr;
    // Core
    PFN_zeInit zeInit=nullptr;
    PFN_zeDriverGet zeDriverGet=nullptr;
    PFN_zeDeviceGet zeDeviceGet=nullptr;
    PFN_zeDeviceGetMemoryProperties zeDeviceGetMemoryProperties=nullptr;
    // Sysman
    PFN_zesInit zesInit=nullptr;
    PFN_zesDriverGet zesDriverGet=nullptr;
    PFN_zesDeviceGet zesDeviceGet=nullptr;
    PFN_zesDeviceEnumMemoryModules zesDeviceEnumMemoryModules=nullptr;
    PFN_zesMemoryGetState zesMemoryGetState=nullptr;
    string path;
};

static bool loadL0(L0& l0, const string& explicitPath){
    vector<string> cand;
    if(!explicitPath.empty()) cand.push_back(explicitPath);
    if(const char* env = getenv("ZE_LOADER_PATH")) if(*env) cand.emplace_back(env);
    cand.emplace_back("/usr/lib64/libze_loader.so");
    cand.emplace_back("/usr/lib64/libze_loader.so.1");
    cand.emplace_back("libze_loader.so.1");
    cand.emplace_back("libze_loader.so");

    for(const auto& p : cand){
        if(p.empty()) continue;
        void* h = dlopen(p.c_str(), RTLD_NOW | RTLD_GLOBAL);
        if(!h) continue;
        l0.lib = h; l0.path = p;

        // Core
        l0.zeInit  = (PFN_zeInit)dlsym(h,"zeInit");
        l0.zeDriverGet = (PFN_zeDriverGet)dlsym(h,"zeDriverGet");
        l0.zeDeviceGet  = (PFN_zeDeviceGet)dlsym(h,"zeDeviceGet");
        l0.zeDeviceGetMemoryProperties = (PFN_zeDeviceGetMemoryProperties)dlsym(h,"zeDeviceGetMemoryProperties");

        // Sysman
        l0.zesInit  = (PFN_zesInit)dlsym(h,"zesInit");
        l0.zesDriverGet = (PFN_zesDriverGet)dlsym(h,"zesDriverGet");
        l0.zesDeviceGet = (PFN_zesDeviceGet)dlsym(h,"zesDeviceGet");
        l0.zesDeviceEnumMemoryModules = (PFN_zesDeviceEnumMemoryModules)dlsym(h,"zesDeviceEnumMemoryModules");
        l0.zesMemoryGetState = (PFN_zesMemoryGetState)dlsym(h,"zesMemoryGetState");

        if(l0.zeInit && l0.zeDriverGet) return true;
        dlclose(h); l0 = L0{};
    }
    return false;
}

// ---- robust scan for totalSize inside each ze_device_memory_properties_t ----
// Level Zero device memory properties, prefix only.
//
// This file loads libze_loader.so with dlopen and deliberately does not
// include the Level Zero headers, so that it builds on a node with no GPU
// toolchain. The fields below are the documented leading members of
// ze_device_memory_properties_t in the same order; only totalSize is read.
//
// The previous implementation avoided declaring the struct by scanning the
// returned buffer for any 8-byte value that looked like a memory size. That
// produced 12.5 TiB per device against 124488 MiB of real HBM, because a
// 296-byte struct contains many 4-byte fields whose adjacent pairs read as a
// plausible 64-bit size (job 8763459).
// Value of ze_structure_type_t::ZE_STRUCTURE_TYPE_DEVICE_MEMORY_PROPERTIES.
#define ZE_STRUCTURE_TYPE_DEVICE_MEMORY_PROPERTIES 0x00000009

struct ze_device_memory_properties_prefix {
    int          stype;
    void*        pNext;
    uint32_t     flags;
    uint32_t     maxClockRate;
    uint32_t     maxBusWidth;
    uint64_t     totalSize;
    char         name[256];
};

// The driver writes an array of the full struct. Reading element k requires
// the driver's element size, not a guess: an assumed 256-byte stride against
// a real 296-byte struct silently misreads every element after the first.
static_assert(offsetof(ze_device_memory_properties_prefix, totalSize) == 24 ||
              offsetof(ze_device_memory_properties_prefix, totalSize) == 32,
              "unexpected layout for ze_device_memory_properties_t prefix");

struct GpuRow {
    int sysman_devices=0;
    long long sysman_total_mib=0; // sum across devices/modules
    long long sysman_used_mib=0;

    int core_devices=0;
    long long core_total_mib=0;   // sum across devices/modules
};

static GpuRow gather_gpu_row(const string& zePath){
    GpuRow g;
    // Encourage Sysman (if disabled by policy this is harmless)
    if(!getenv("ZES_ENABLE_SYSMAN")) setenv("ZES_ENABLE_SYSMAN","1",1);

    L0 l0;
    if(!loadL0(l0, zePath)) return g;

    const ze_result_t OK = 0;
    if(!l0.zeInit || l0.zeInit(0) != OK) return g;
    if(l0.zesInit) l0.zesInit(0);

    // --- Sysman path for used+total ---
    if(l0.zesDriverGet && l0.zesDeviceGet && l0.zesDeviceEnumMemoryModules && l0.zesMemoryGetState){
        uint32_t nd=0;
        if(l0.zesDriverGet(&nd, nullptr) == OK && nd>0){
            vector<zes_driver_handle_t> zdrivers(nd);
            if(l0.zesDriverGet(&nd, zdrivers.data()) == OK){
                for(auto zd : zdrivers){
                    uint32_t ndev=0;
                    if(l0.zesDeviceGet(zd, &ndev, nullptr) != OK || ndev==0) continue;
                    vector<zes_device_handle_t> zdevs(ndev);
                    if(l0.zesDeviceGet(zd, &ndev, zdevs.data()) != OK) continue;
                    g.sysman_devices += (int)ndev;
                    for(auto dev : zdevs){
                        uint32_t nmem=0;
                        if(l0.zesDeviceEnumMemoryModules(dev, &nmem, nullptr) != OK || nmem==0) continue;
                        vector<zes_mem_handle_t> mems(nmem);
                        if(l0.zesDeviceEnumMemoryModules(dev, &nmem, mems.data()) != OK) continue;
                        for(auto mh : mems){
                            zes_mem_state_t st{}; // zero
                            if(l0.zesMemoryGetState(mh, &st) == OK && st.size>0){
                                g.sysman_total_mib += (long long)(st.size / (1024ULL*1024ULL));
                                g.sysman_used_mib  += (long long)((st.size - st.free) / (1024ULL*1024ULL));
                            }
                        }
                    }
                }
            }
        }
    }

    // --- Core fallback: total VRAM per device (no 'used' available) ---
    if(l0.zeDeviceGet && l0.zeDeviceGetMemoryProperties){
        uint32_t nDrivers=0;
        if(l0.zeDriverGet(&nDrivers, nullptr)==OK && nDrivers>0){
            vector<ze_driver_handle_t> drivers(nDrivers);
            if(l0.zeDriverGet(&nDrivers, drivers.data())==OK){
                for(auto d : drivers){
                    uint32_t devCount=0;
                    if(l0.zeDeviceGet(d, &devCount, nullptr)!=OK || devCount==0) continue;
                    vector<ze_device_handle_t> devs(devCount);
                    if(l0.zeDeviceGet(d, &devCount, devs.data())!=OK) continue;
                    g.core_devices += (int)devCount;

                    for(auto dv : devs){
                        uint32_t mcount=0;
                        if(l0.zeDeviceGetMemoryProperties(dv, &mcount, nullptr)!=OK || mcount==0) continue;
                        // A real array of the real type: the driver strides by
                        // sizeof(the struct), so anything else misreads element k>0.
                        vector<ze_device_memory_properties_prefix> props(mcount);
                        for(auto &p : props){
                            memset(&p, 0, sizeof(p));
                            p.stype = ZE_STRUCTURE_TYPE_DEVICE_MEMORY_PROPERTIES;
                        }
                        if(l0.zeDeviceGetMemoryProperties(dv, &mcount, props.data())!=OK) continue;

                        uint64_t totalSum=0;
                        for(uint32_t k=0;k<mcount;++k){
                            totalSum += props[k].totalSize;   // documented field
                        }
                        g.core_total_mib += (long long)(totalSum / (1024ULL*1024ULL));
                    }
                }
            }
        }
    }
    return g;
}

// --------------- output helpers ---------------
static string csv_escape(const string& s){
    bool need = s.find_first_of(",\"\n\t") != string::npos;
    if(!need) return s;
    string out="\"";
    for(char c: s){ if(c=='"') out+="\"\""; else out+=c; }
    out+="\""; return out;
}

int main(int argc, char** argv){
  // Wall-clock for the whole kernel, reported as KERNEL_TIME.
  health_checks::KernelTimer kernel_timer_("mem_and_gpu_row");

    ios::sync_with_stdio(false);
    cin.tie(nullptr);

    bool csv=false, header=true;
    string zePath;

    for(int i=1;i<argc;++i){
        string a=argv[i];
        if(a=="--csv") csv=true;
        else if(a=="--no-header") header=false;
        else if(a=="--ze" && i+1<argc) zePath=argv[++i];
        else if(a=="-h"||a=="--help"){
            cerr <<
"Usage: mem_and_gpu_row [--csv] [--no-header] [--ze PATH]\n"
"Outputs one line (TSV default) with: timestamp, hostname, CPU RAM buckets (MiB),\n"
"and Intel GPU memory (Sysman used/total if available; otherwise core total VRAM).\n";
            return 0;
        }
    }

    const char delim = csv ? ',' : '\t';
    string ts = timestamp_now_iso();
    string host = hostname_now();
    CpuRow  cpu = gather_cpu_row();
    GpuRow  gpu = gather_gpu_row(zePath);

    // Header
    if(header){
        vector<string> H = {
            "timestamp",
            "hostname",
            "mem_total_mib","mem_used_incl_cache_mib","mem_available_mib",
            "anon_lru_mib","filecache_lru_mib","filecache_cached_minus_shmem_mib",
            "shmem_mib","slab_mib","sreclaimable_mib","sunreclaimable_mib",
            "kreclaimable_mib","kernel_overheads_mib","nonreclaim_est_mib",
            "gpu_sysman_devices","gpu_sysman_total_mib","gpu_sysman_used_mib",
            "gpu_core_devices","gpu_core_total_mib"
        };
        for(size_t i=0;i<H.size();++i){
            if(csv) cout << csv_escape(H[i]); else cout << H[i];
            if(i+1<H.size()) cout << delim;
        }
        cout << "\n";
    }

    // Row
    vector<string> row;
    auto add_ll = [&](long long v){ row.push_back( to_string(v) ); };
    auto add_i  = [&](int v){ row.push_back( to_string(v) ); };

    row.push_back(ts);
    row.push_back(host);

    add_ll(cpu.mem_total_mib);
    add_ll(cpu.mem_used_incl_cache_mib);
    add_ll(cpu.mem_available_mib);
    add_ll(cpu.anon_lru_mib);
    add_ll(cpu.filecache_lru_mib);
    add_ll(cpu.filecache_cached_minus_shmem_mib);
    add_ll(cpu.shmem_mib);
    add_ll(cpu.slab_mib);
    add_ll(cpu.sreclaim_mib);
    add_ll(cpu.sunreclaim_mib);
    add_ll(cpu.kreclaimable_mib);
    add_ll(cpu.kernel_overheads_mib);
    add_ll(cpu.nonreclaim_est_mib);

    add_i (gpu.sysman_devices);
    add_ll(gpu.sysman_total_mib);
    add_ll(gpu.sysman_used_mib);         // 0 if Sysman unavailable
    add_i (gpu.core_devices);
    add_ll(gpu.core_total_mib);

    for(size_t i=0;i<row.size();++i){
        if(csv) cout << csv_escape(row[i]); else cout << row[i];
        if(i+1<row.size()) cout << delim;
    }
    cout << "\n";

    // Flush the row before the timer prints: cout and printf use separate
    // buffers, and without this KERNEL_TIME appears before the CSV header.
    cout.flush(); kernel_timer_.report();
    return 0;
}
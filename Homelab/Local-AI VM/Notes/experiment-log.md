# Local AI on Proxmox/Fedora — CPU Inference Experiment Log

A running log of decisions, hardware specifics, and results for this particular machine. For definitions of terms used here (quantization, AVX2, NUMA, etc.), see **`concepts-glossary.md`** — that file is kept generic/reusable; this one is specific to this box.

---

## 1. This Machine's Setup

| Component | Detail |
|---|---|
| Host | Dell OptiPlex, running Proxmox (hypervisor) |
| Guest OS | Fedora 44 Server (VM) |
| CPU | Intel Core i7-8700 @ 3.20GHz — 6 physical cores / 12 threads (Coffee Lake, 2017) |
| GPU | None — CPU-only inference |
| RAM allocated to VM | **8.00 GiB** |
| vCPUs allocated to VM | **6 cores** (1 socket × 6 cores, `[host]` CPU type, matches all 6 physical cores of the host CPU — no logical/hyperthread cores passed through) |
| Highest SIMD support | AVX2 (no AVX-512 — Coffee Lake predates it) |
| BIOS | OVMF (UEFI) |
| Machine type | Default (i440fx) |
| Storage controller | VirtIO SCSI single |
| Disk | `local-lvm`, 10G, `discard=on`, `iothread=1` |
| Network | VirtIO, bridged to `vmbr0`, firewall enabled |
| EFI Disk | `local-lvm`, 4M, `pre-enrolled-keys=1` |

**Note on `numa=1`:** Proxmox shows `[numa=1]` in the Processors line. This just enables NUMA-awareness in the VM config — it does **not** mean the VM has multiple NUMA nodes. Since both the host and this VM are single-socket, there's effectively only one NUMA node here regardless of this flag. Doesn't change any of the guidance in the glossary about NUMA being irrelevant for single-socket setups.

### VM CPU type history
- Initially set to **`x86-64-v2-AES`** in Proxmox → AVX2 was *not* visible inside the Fedora guest.
- Changed to **`host`** → AVX2 became visible. Chosen because this is a single-node box with no plans to migrate the VM elsewhere.
- Verified with:
  ```bash
  cat /proc/cpuinfo | grep avx2
  ```

---

## 2. Tooling Decision: Ollama vs llama.cpp

**Decision: llama.cpp directly**, at least to start.

Reasoning specific to this setup:
- CPU-only + old hardware = performance tuning matters a lot, so direct access to thread count, batch size, and quantization choice (via llama.cpp) is worth the extra setup effort over Ollama's more opaque defaults.
- Plan to compile natively for this exact CPU to fully exploit AVX2.
- May layer Ollama on top later for day-to-day convenience once a good model/quant is identified — it can reuse the same GGUF files.

(See glossary for full Ollama vs. llama.cpp trade-off explanation.)

---

## 3. Build Plan for llama.cpp on This Machine

Target CPU: i7-8700, AVX2, no AVX-512, 6 physical cores.

```bash
# Clone the repo
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp

# Build with CMake, compiling natively for this exact CPU
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON
cmake --build build --config Release -j 6
```

**Flag notes (specific to this machine):**
- `-DGGML_NATIVE=ON` — tells the build to auto-detect and use this CPU's full instruction set (AVX2, FMA, SSE4.2, etc.) — equivalent in spirit to `-march=native`. Appropriate here since this binary will only ever run on this exact VM/CPU. (If we ever wanted a portable binary to copy to different hardware, we'd instead target an explicit level like AVX2-only flags rather than NATIVE.)
- `-j 6` — parallel compile jobs, matched to the 6 physical cores, just to keep the build itself efficient. Doesn't affect the resulting binary's runtime performance.
- No need for any AVX-512-specific flags — this CPU doesn't have it, so `GGML_NATIVE` won't enable it anyway.
- After building, the binaries (`llama-cli`, `llama-server`, `llama-bench`, etc.) will be under `build/bin/`.

**Sanity check after building** — `llama-cli --version` only prints build/compiler info, NOT CPU feature detection (corrected after testing — the earlier version of this note was wrong). To actually confirm AVX2:
- Check what CMake detected/enabled at configure time: `grep -i avx build/CMakeCache.txt` — this showed all `GGML_AVX2` etc. as `OFF`, which looked alarming but is a **red herring**: those are manual/explicit feature-selection flags only used when `GGML_NATIVE=OFF`. In native mode, they're bypassed entirely.
- **Confirmed via actual compile flags instead:**
  ```
  CXX_FLAGS = ... -march=native -fopenmp
  C_FLAGS = ... -march=native -fopenmp
  ```
  Found in `build/CMakeFiles/ggml-cpu.dir/flags.make`. This is the real mechanism `GGML_NATIVE=ON` uses — it tells GCC to auto-detect and target the exact CPU it's compiling on. Since `-march=native` on a genuine Coffee Lake CPU always resolves to include AVX2 (present since Haswell, 2013), this is strong confirmation AVX2 is compiled in.
- Final/undeniable confirmation still pending: the `system_info:` line printed at runtime when actually loading a model — expected to show `AVX2 = 1`.

**Storage note:** model files will be stored on an external NAS share (not the 10G local VM disk) — disk space is not a constraint for model storage on this setup.

---

**Note on the 6 vCPUs:** the VM was given all 6 physical cores of the host (not the 12 logical/hyperthreaded ones), so there's no oversubscription — the VM effectively "owns" the whole CPU's real compute. This also means `-t 6` is the natural starting point for thread count when running models (see benchmarking section below), since that matches both the vCPU count and the physical core count. Worth still testing `-t 5` in case leaving one thread free for Proxmox/host overhead helps — Proxmox itself still needs some scheduling overhead, so total contention isn't quite zero even though vCPUs == physical cores.

**Open concern (raised 2026-09-01, resolved — see 3c): other VMs share this host.** Since this VM's 6 vCPUs originally mapped 1:1 to all 6 physical cores, this VM could claim 100% of the host's CPU under load, starving other Proxmox VMs regardless of their own vCPU allocations. See glossary entry "CPU isolation between VMs sharing one host" for general options, and Section 3c below for the implemented fix.

## 3a. Build Dependencies (Fedora 44)

Fedora doesn't ship a full C/C++ toolchain by default on a minimal Server install, so these need to be installed first:

```bash
sudo dnf install -y gcc gcc-c++ cmake git make libcurl-devel
```

**What each package is for:**
- `gcc` / `gcc-c++` — the C and C++ compilers. llama.cpp is written in C/C++, so these are non-negotiable.
- `cmake` — the build system generator llama.cpp uses (see build commands above).
- `git` — to clone the repo (and pull updates later).
- `make` — used under the hood by CMake's default generator on Linux.
- `libcurl-devel` — needed if you want llama.cpp's built-in model-downloading support (`--hf-repo` style pulls directly from Hugging Face). Since you're sourcing models via NAS instead, this is technically optional — but cheap to install now and saves a rebuild later if you change your mind.

**Optional, not required to build:**
- `python3` / `python3-pip` — only needed if you plan to use llama.cpp's Python conversion scripts (e.g. converting a raw Hugging Face model to GGUF yourself, rather than downloading pre-made GGUF files). Not needed if you're only ever using pre-quantized GGUF files from the NAS.
- An optimized BLAS library (e.g. `openblas-devel`) — llama.cpp's own AVX2-optimized kernels are typically fast enough on CPU already, and `GGML_NATIVE=ON` covers this. Not needed for the initial benchmark; something to revisit only if a specific bottleneck shows up later.

**Verify the toolchain versions after install (useful to have logged):**
```bash
gcc --version
cmake --version
```

## 3b. Build Log Notes

**Build ran successfully.** Compiled dozens of targets — the core `ggml`/`llama` libraries, CLI tools (`llama-cli`, `llama-bench`, `llama-server`), a large set of multimodal/vision-model adapters under `tools/mtmd` (built by default even though not needed for basic text inference), and the test suite.

**Warnings observed — confirmed harmless, safe to ignore:**
- `-Wdeprecated-enum-enum-conversion` — llama.cpp's own upstream code does a bitwise OR between two different C++ enum types (e.g. combining a scale-mode enum with a scale-flag enum). Newer/stricter compilers (build used GCC 16) flag this as deprecated style, but it still compiles and functions correctly. Purely upstream code style, unrelated to this machine's config.
- `-Wdeprecated-declarations` on `fs::u8path` — a filesystem API that's deprecated in favor of a newer one, still fully functional.
- Neither warning stopped the build (`Linking CXX executable` / `Built target ...` lines confirm successful completion) and neither relates to CPU flags, AVX2 detection, or performance.
- General rule: **warnings** (compiler noticed something, build continues) vs. **errors** (build stops, no binary produced) — always check for errors, warnings from upstream project code are normal in fast-moving open source projects and not something to chase down.

## 3c. CPU Pinning / Core Isolation — **Implemented and Active**

**Reason:** this VM's 6 vCPUs originally mapped 1:1 to all 6 physical cores of the host, meaning it could claim 100% of host CPU under load and starve other Proxmox VMs. Based on Run #4/#5 thread-sweep data (diminishing returns past ~4 threads for generation speed), the decision was made to sacrifice a small amount of generation speed (~5%, measured) in exchange for guaranteeing 2 full physical cores stay available to other VMs on the host.

**Current, active configuration:**
- VM pinned to physical cores **0–3** via Proxmox `affinity`.
- vCPU allocation reduced from 6 → **4** (`cores: 4` in the VM config).
- Physical cores 4 and 5 are left fully free for other Proxmox VMs.

**Determining which logical CPUs to pin to:** ran `lscpu -e` on the Proxmox host to check the physical core / hyperthread mapping before picking core IDs (important — picking two logical CPUs that are actually hyperthreads of the *same* physical core would only yield ~2 real cores' worth of compute, not 4). Confirmed mapping for this host's i7-8700:

| Physical CORE | Logical CPU pair |
|---|---|
| 0 | 0, 6 |
| 1 | 1, 7 |
| 2 | 2, 8 |
| 3 | 3, 9 |
| 4 | 4, 10 |
| 5 | 5, 11 |

Logical CPUs **0, 1, 2, 3** map to 4 distinct physical cores (0-3) — confirmed correct choice.

**First attempt — `cpuset: 0-3` — did NOT work.** Added `cpuset: 0-3` directly to `/etc/pve/qemu-server/105.conf`. The key was accepted and written to the file, but verification showed **no actual effect**:
```bash
grep Cpus_allowed_list /proc/$(cat /var/run/qemu-server/105.pid)/task/*/status | sort -u
# → showed 0-11 (all cores) for every VM thread, not 0-3
```
**Root cause: `cpuset` is not a real/recognized Proxmox VM config key** (at least on this Proxmox version). Proxmox silently stores unrecognized keys in the `.conf` file without validating or applying them — so it *looked* configured but was never actually enforced by the kernel/cgroup layer.

**Correct fix: use `affinity` instead of `cpuset`.**
```bash
qm set 105 --affinity 0-3
```
This is the real, supported Proxmox option (Proxmox 8.x+) for pinning a VM's cgroup CPU affinity, applied via `taskset`/cgroups under the hood. Unlike the old `cpuset` misconception, this can typically be applied to a running VM without a full stop/start, since it operates on the already-running QEMU process directly.

**Verification (confirmed working):**
```bash
grep affinity /etc/pve/qemu-server/105.conf
grep Cpus_allowed_list /proc/$(cat /var/run/qemu-server/105.pid)/task/*/status | sort -u
```
Both now correctly show `0-3` instead of `0-11`.

**Status: ✅ implemented, verified, and currently active.** Cores 4-5 (physical) are reliably free for other Proxmox VMs regardless of LLM workload intensity on this VM.

## 4a. First Test Model

**Storage:** models are stored on an external NAS share, mounted into the Fedora VM (not on the 10G local VM disk). Note: llama.cpp by default memory-maps (`mmap`s) model files rather than loading fully into RAM upfront — see glossary "Memory-mapped file loading (mmap) and network/NAS storage." Testing on 2026-09-01 found NAS vs. local disk made only a marginal difference in practice for this workload (see `benchmark-results-log.md`); the dominant real-world RAM/performance issue turned out to be unset context size (KV cache sizing), not NAS storage itself.

**Chosen first model: Llama 3.2 3B Instruct, Q4_K_M quant**
- Small (~2.02 GB), fast, well-supported — good first test to validate the whole pipeline (build → load → inference) before trying anything bigger.
- Source: `bartowski/Llama-3.2-3B-Instruct-GGUF` on Hugging Face (community-maintained GGUF quantization repo).
- Confirmed file size: 2.02 GB.

**Download command:**
```bash
wget -O /path/to/nas/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf \
  https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf
```
(Replace `/path/to/nas/models/` with the actual mount path of the NAS share on the Fedora VM.)

**Why a third-party GGUF repo (e.g. bartowski) instead of Meta's official release directly:**
Meta publishes official weights in PyTorch/safetensors format, meant for GPU inference frameworks — not GGUF. llama.cpp requires GGUF. Community uploaders like bartowski take the same official Meta weights and run them through llama.cpp's own open-source `convert_hf_to_gguf.py` + `llama-quantize` pipeline — same model, just converted/compressed, not a different or altered model. This is standard practice in the llama.cpp community; verifiable via published SHA256 checksums. Self-converting is only really needed for a quant level nobody's uploaded yet, full chain-of-custody requirements, or custom fine-tuning/calibration work.


```bash
./build/bin/llama-cli -m /path/to/nas/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf -p "Hello, how are you?" -n 64
```



## 4. RAM Budget Notes (8GB VM)

With 8GB total RAM for the VM (shared with the OS itself), rough model-size budget:
- Fedora Server + overhead: likely leaves **~6–7GB usable** for model weights + context/KV cache.
- A **Q4_K_M** quantized 7B model is roughly **4–4.5GB** on disk/in RAM → comfortably fits.
- A **Q4_K_M** quantized 13B model is roughly **7.5–8GB** → likely too tight alongside OS overhead and context memory; risk of swapping (which would tank performance further). Better to avoid 13B+ on this RAM budget for now.
- Plan: start with a **3B model** to get a fast baseline, then step up to 7B–8B and see how it feels once we have real benchmark numbers.

---

## 5. Realistic Performance Expectations (rough ballpark, unverified until benchmarked)

**⚠️ First benchmark run (see `benchmark-results-log.md` for full detail) came back suspiciously slow, and the console output revealed the binary being tested was a debug/asserts-enabled build, not the intended Release build.** Numbers from that run are not being trusted as the real baseline. Need to confirm `CMAKE_BUILD_TYPE` actually took effect and rebuild cleanly before treating any benchmark as representative. Full results, raw numbers, and analysis are tracked separately in **`benchmark-results-log.md`** going forward — this section just holds the pre-benchmark ballpark estimate for comparison.

For this specific CPU (6-core Coffee Lake, dual-channel DDR4, AVX2):
- **3B models, Q4_K_M**: ~8–15 tok/s
- **7B–8B models, Q4_K_M**: ~3–7 tok/s
- **13B+**: not attempting given the 8GB RAM ceiling

To be replaced with **actual** `llama-bench` numbers once available. (Update 2026-09-01: superseded — see `benchmark-results-log.md` for actual measured results, now the real baseline.)

---

## 5a. Precompiled Binary Comparison Attempt (2026-09-01) — Not Recommended, Documented for Reference

**What was tried:** installed a precompiled `llama-bench`/`llama-cli` from a distro repo (available as `llama-bench` on PATH, separate from the self-built `./build/bin/llama-bench`), to compare against the self-built binary.

**Result: not a valid comparison.** The precompiled binary reported `backend: ROCm` (AMD's GPU compute framework) and printed:
```
ggml_cuda_init: failed to initialize ROCm: no ROCm-capable device is detected
```
followed by drastically worse numbers (pp512: 5.12 t/s, tg128: 4.39 t/s) vs. the self-built CPU binary's ~55-56 t/s pp512 / ~13 t/s tg128 at the same thread count (4).

**Root cause:** the precompiled package is built with ROCm (AMD GPU) support compiled in — likely the distro's default/generic "llama.cpp" package variant. This Dell OptiPlex has **no AMD GPU** (or any discrete GPU), so this is fundamentally the wrong build variant for this hardware, independent of any flags.

**Attempted fix:** `-ngl 0` (offload zero layers to GPU, i.e. force full CPU execution) did not resolve it — the binary still reported/attempted the ROCm backend. Likely a compiled-in default or packaging quirk in that specific binary rather than expected llama.cpp behavior; not investigated further.

**Decision: not pursuing this further.** The self-built binary (CPU-only, `-march=native`, confirmed AVX2, confirmed via clean-rebuild benchmarks) is already the correct, purpose-built binary for this exact hardware. A ROCm-targeted precompiled binary is not a meaningful CPU-performance comparison point on a machine with no AMD GPU. **All benchmark numbers in this project use the self-built binary at `./build/bin/`.**



## 7. System-Wide Install: `llama-server` as a Normal Command

**Goal:** run `llama-server` as a long-lived local API/service, callable like any normal installed binary (no `./build/bin/` prefix, no `cd`-ing into the repo).

### 7a. Relocated source tree

Moved the repo out of the home directory into `/opt` (conventional location for manually-installed, non-package-manager software on Linux):

```bash
sudo mv llama.cpp/ /opt
cd /opt
sudo chown -R ai:ai llama.cpp/
```

`chown` needed since `sudo mv` leaves root as owner; want the regular user to keep building/pulling updates without `sudo` each time.

### 7b. Symlinked binaries into PATH

```bash
sudo ln -s /opt/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server
sudo ln -s /opt/llama.cpp/build/bin/llama-cli /usr/local/bin/llama-cli
sudo ln -s /opt/llama.cpp/build/bin/llama-bench /usr/local/bin/llama-bench
```

`/usr/local/bin` is already on `PATH` by default on Fedora and is the standard place for locally-built binaries, kept separate from anything `dnf` manages. Needed `sudo` for the symlink creation itself (not owned by `ai` user). Symlinking (rather than copying) means future rebuilds in place are picked up automatically with no reinstall step.

### 7c. Issue: missing shared libraries

```
llama-server: error while loading shared libraries: libllama-server-impl.so: cannot open shared object file: No such file or directory
```

**Cause:** llama.cpp builds its core logic as shared libraries (`libllama-server-impl.so`, `libggml.so`, `libllama.so`, etc.) that live in `build/bin/` alongside the executables — they are not statically linked in. Symlinking just the binary into `/usr/local/bin` doesn't help, because the dynamic linker (`ld.so`) resolves shared-library dependencies by searching a fixed set of system paths (plus `LD_LIBRARY_PATH`/the `ldconfig` cache) — `/opt/llama.cpp/build/bin` isn't one of them by default.

**Fix chosen: register the build directory with `ldconfig`** (system-wide, permanent, closest to how a real package would install its libs):

```bash
echo "/opt/llama.cpp/build/bin" | sudo tee /etc/ld.so.conf.d/llama-cpp.conf
sudo ldconfig
```

Verified working with:
```bash
llama-server -v
ldconfig -p | grep llama
```

**Alternatives considered, not used:**
- `LD_LIBRARY_PATH` env var — works but session/service-scoped only, easy to forget in a new shell or future systemd unit. Rejected as fragile long-term.
- Symlinking each `.so` individually into `/usr/local/lib` — works but same maintenance burden as the `ldconfig` fix (needs re-running after rebuilds that add/rename libs), with no real advantage. Rejected in favor of the `ldconfig` approach.

**Maintenance note for future rebuilds:** if `build/` is ever wiped and reconfigured/rebuilt (e.g. version update), the `.so` files regenerate at the same path, so the `ld.so.conf.d` entry keeps working with no changes needed — just re-run `sudo ldconfig` after any rebuild as a safety habit, since the cache sometimes needs a manual refresh even when the path hasn't changed.

---

## 8. Next Steps

**Completed:**
- [x] Build llama.cpp with `GGML_NATIVE=ON` — done, AVX2 confirmed via compile flags and runtime `system_info:` line
- [x] Confirm AVX2 detected — confirmed (see section 3)
- [x] Download small test model — Llama 3.2 3B Instruct Q4_K_M
- [x] Run `llama-bench` for real tok/s numbers — done, see `benchmark-results-log.md` (Run #2, after fixing a debug-build contamination issue in Run #1)
- [x] Tune thread count against benchmark results — full 1-6 thread sweep done for both 3B and 8B models (Runs #4, #5); ~3-4 threads captures most of the achievable generation speed, `-t 6` best overall but by a small margin
- [x] Try a same-family larger model and compare — Llama 3.1 8B Instruct Q4_K_M added (closest same-family option; Llama 3.2 generation only released a 3B text model); ~2.5x params → ~2.5x/2.26x slower, roughly linear scaling
- [x] Real-world interactive test (not just synthetic benchmark) — done via `llama-cli` + `/usr/bin/time -v` + btop; uncovered and root-caused a KV-cache/context-size RAM issue (see `benchmark-results-log.md` Run #6 and follow-ups)
- [x] Precompiled binary comparison — attempted, found to be a ROCm (AMD GPU) build, not a valid CPU comparison on this hardware; abandoned as documented
- [x] Decide whether to layer Ollama on top for day-to-day convenience — **decided: sticking with direct llama.cpp**, not layering Ollama on top for now
- [x] Implement CPU pinning/isolation decision — **implemented and active**: pinned to 4 physical cores via `affinity: 0-3` (corrected from the non-functional `cpuset` key) and reduced vCPU allocation to `cores: 4`. See Section 3c for full details
- [x] System-wide `llama-server` install — binaries symlinked into `/usr/local/bin`, shared library resolution fixed via `ldconfig`. See Section 7 for full details

**Still open:**
- [ ] Try a different quant level (e.g. Q5_K_M or Q3_K_M) on an existing model to see the quality/speed tradeoff directly — decision made to pursue this; results to be logged once run
- [ ] Re-run the 8B model with an explicit, sensible `-c` context size (same fix validated on the 3B model) to confirm the same RAM/swap improvement applies
- [ ] Decide on a "standard" `-c` value to use going forward for normal interactive use on this hardware
- [ ] Decide final `-t` value for the server, consistent with the current 4-core pin (Section 3c)
- [ ] Decide `--host`/`--port` and whether `llama-server` should be reachable beyond localhost
- [ ] Write a systemd unit for `llama-server` so it runs as a persistent background service

---

*Log started: 2026-08-31*
*Section 7 added: 2026-09-01 — system-wide install of llama-server, shared library fix*

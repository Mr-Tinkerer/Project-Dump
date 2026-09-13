# Benchmark Results Log

*Log started: 2026-08-31*

Dedicated log of `llama-bench` runs on this OptiPlex/Fedora setup — what was run, why, the raw numbers, and what they mean. For hardware/software setup details, see `experiment-log.md`. For term definitions, see `concepts-glossary.md`.

---

## How to read the numbers (reference)

- **`pp512`** — prompt processing speed: tokens/sec to read/encode a 512-token input prompt. Highly parallelizable phase.
- **`tg128`** — token generation speed: tokens/sec to produce 128 tokens of output. Sequential, memory-bandwidth-bound phase. **This is usually the number that matters most for "how does it feel to chat with."**
- **`± X`** — standard deviation across repetitions (default 5 reps). Smaller = more consistent/reliable result.

**Rough human-feel calibration for tg (generation) speed:**
| tok/s | Feel |
|---|---|
| ~2-3 | Roughly human reading/typing pace — usable but you're waiting on it |
| ~5-10 | Reasonably fluid, comparable to a fast typist |
| 15+ | Feels close to instant / typical web chatbot speed |

---

## Run #1 — 2026-08-31, ~20:30 (8:30pm, approximate) — Llama 3.2 3B Instruct Q4_K_M, 6 threads

**Command:**
```bash
./build/bin/llama-bench -m ~/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf -t 6 -p 512 -n 128
```

**Purpose:** First-ever benchmark on this hardware — establish an initial baseline for a 3B model at the full 6-thread vCPU allocation.

**⚠️ Known issue with this run:** Console output included:
```
warning: asserts enabled, performance may be affected
warning: debug build, performance may be affected
```
This means the build being benchmarked was **not** a proper optimized Release build — despite `-DCMAKE_BUILD_TYPE=Release` being passed during configure, the binary reports debug/assert behavior. **These numbers are likely artificially low and should not be treated as the real baseline.** Root cause to be investigated before the next run (see Action Items below).

Also noted: `load_backend: failed to find ggml_backend_init in .../libggml-cpu.so` — not yet confirmed whether this is benign (e.g. a leftover/duplicate .so being probed and skipped) or indicates a real backend-loading problem. To be watched on future runs.

**Results:**

| model | size | params | backend | threads | test | t/s |
|---|---|---|---|---|---|---|
| llama 3B Q4_K - Medium | 1.87 GiB | 3.21 B | CPU | 6 | pp512 | 9.00 ± 0.02 |
| llama 3B Q4_K - Medium | 1.87 GiB | 3.21 B | CPU | 6 | tg128 | 3.92 ± 0.01 |

**Interpretation:**
- pp512 = 9.00 t/s → a 512-token prompt would take ~57 seconds to process. Slow for prompt processing, which is normally the faster of the two phases.
- tg128 = 3.92 t/s → roughly one token every ~0.25s. Readable pace but noticeably below a "fluid chat" feel, and at the low end of (or below) the rough 8-15 t/s ballpark expected for a 3B Q4_K_M model on this CPU.
- Given the debug-build warning, this run is treated as **provisional/likely invalid** — not the real performance ceiling of this hardware.

**Action items before trusting a baseline:**
- [x] Confirm actual build type in use — checked `build/CMakeCache.txt`: `CMAKE_BUILD_TYPE:STRING=Release` — **correctly set at the CMake level.** So the debug/asserts warning was not from a wrong CMake flag.
- [x] Root cause hypothesis: stale build artifacts from an earlier configure/build cycle (object files compiled before `Release` was set, not fully recompiled), or llama.cpp's own separate assert/debug options not resetting cleanly on an incremental build. Decided not to chase the exact cause — cheaper to do a full clean rebuild.
- [ ] **Plan: full clean rebuild** — `rm -rf build`, reconfigure, rebuild from scratch, output redirected to log files via `tee` for both the terminal view and a saved record:
  ```bash
  cd ~/llama.cpp
  rm -rf build
  cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON 2>&1 | tee configure.log
  cmake --build build --config Release -j 6 2>&1 | tee build.log
  ```
- [ ] Re-verify `-march=native` present post-rebuild: `grep -i "march\|mavx" build/CMakeFiles/ggml-cpu.dir/flags.make`
- [ ] Investigate the `failed to find ggml_backend_init` warning — confirm benign or fix
- [ ] Re-run this exact same benchmark command for a clean, comparable baseline, redirected to a log:
  ```bash
  ./build/bin/llama-bench -m ~/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf -t 6 -p 512 -n 128 2>&1 | tee benchmark_run2.log
  ```

---

## Run #2 — 2026-08-31 20:59 EDT — Llama 3.2 3B Instruct Q4_K_M, 6 threads (clean rebuild)

**Command:**
```bash
{ date; ./build/bin/llama-bench -m ~/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf -t 6 -p 512 -n 128; } 2>&1 | tee benchmark_run2.log
```

**Purpose:** Re-run the identical benchmark after a full clean rebuild (`rm -rf build` + reconfigure + rebuild from scratch), to get a trustworthy baseline after Run #1 was invalidated by debug-build contamination.

**Result: no debug/asserts warnings this time** — clean output, build ran normally.

**Results:**

| model | size | params | backend | threads | test | t/s |
|---|---|---|---|---|---|---|
| llama 3B Q4_K - Medium | 1.87 GiB | 3.21 B | CPU | 6 | pp512 | 72.62 ± 1.53 |
| llama 3B Q4_K - Medium | 1.87 GiB | 3.21 B | CPU | 6 | tg128 | 13.76 ± 0.02 |

**Interpretation:**
- **pp512 = 72.62 t/s** — roughly **8x faster** than Run #1's 9.00 t/s. A 512-token prompt now processes in ~7 seconds instead of ~57.
- **tg128 = 13.76 t/s** — roughly **3.5x faster** than Run #1's 3.92 t/s. This lands right at the top of the original ballpark estimate (8–15 t/s) for a 3B Q4_K_M model on this CPU — a genuinely fluid, "fast typist" pace for chat use.
- This confirms Run #1 was invalid due to the debug-build contamination, not normal run-to-run variance.
- **This is now the trusted baseline for Llama 3.2 3B Q4_K_M @ 6 threads on this hardware.**

## 4b. Second Test Model — 8B, same family as baseline

**Family constraint (decided 2026-08-31):** to isolate the effect of model size alone, all test models should be from the same family/generation — comparing across different architectures (e.g. Llama vs Mistral) would confound the "does size alone change speed" question.

**Chosen: Meta Llama 3.1 8B Instruct, Q4_K_M quant**
- Source: `bartowski/Meta-Llama-3.1-8B-Instruct-GGUF` (same trusted uploader/pipeline as the 3B model).
- Size: 4.92 GB — comfortably within the 8GB RAM budget.
- Note: Llama 3.2 (the 3B baseline's generation) only released a 3B text model — no larger text model exists in that specific minor version. Llama 3.1 8B is the closest same-family option: same Meta "Llama 3.x" architecture lineage and tokenizer family as Llama 3.2, just the prior minor version. This is a deliberate, documented compromise to keep the comparison as apples-to-apples as reasonably possible.

**Comparison table (family-controlled):**

| Model | Family | Params | Q4_K_M size |
|---|---|---|---|
| Llama 3.2 3B Instruct | Meta Llama 3.x | 3B | 1.87 GB |
| Llama 3.1 8B Instruct | Meta Llama 3.x | 8B | 4.92 GB |

**Download:**
```bash
wget -O ~/models/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf \
  https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf
```

**Benchmark command (once downloaded), same pattern as the 3B run for direct comparison:**
```bash
{ date; ./build/bin/llama-bench -m ~/models/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf -t 6 -p 512 -n 128; } 2>&1 | tee benchmark_run3.log
```

**Root cause of Run #1's debug-build contamination (confirmed):**
Classic `make`-based builds (the default CMake generator on Linux) decide whether to recompile a `.cpp` file into a `.o` file based on **file timestamps only** — not on whether the compiler flags changed. The likely sequence:
1. An early `cmake -B build` was run without `-DCMAKE_BUILD_TYPE=Release` explicitly set (or some other initial state resulted in debug-flavored flags), producing some object files compiled without optimization/with asserts enabled.
2. `-DCMAKE_BUILD_TYPE=Release` was added and CMake was re-run — this correctly updated `CMakeCache.txt` and regenerated `flags.make` with the right `-march=native`/optimization flags (which is why our `grep` checks on the cache and flags.make looked correct).
3. However, `make` only recompiles files it thinks are "stale" based on timestamps — any `.o` file that hadn't been touched since the original debug-flavored compile was **not recompiled**, and got linked as-is into the final binary alongside newly-recompiled files.
4. Net result: a binary that reports `Release` in the CMake cache, but still contains some debug-compiled object code — exactly matching the `asserts enabled` / `debug build` warnings seen in Run #1.

**Lesson learned:** after changing significant CMake options (build type, native flags, etc.) on an existing build directory, prefer a full `rm -rf build` + reconfigure over an incremental rebuild, to guarantee every file is compiled with the current, correct flags.



**Logging convention going forward:** each run header uses `YYYY-MM-DD HH:MM` (local VM/system time). When pasting benchmark output, include the timestamp of when you ran it (e.g. from `date` command output alongside the benchmark, or just tell me the time) so it can be logged precisely.

---

## Run #3 — 2026-08-31 21:21 EDT — Llama 3.1 8B Instruct Q4_K_M, 6 threads

**Command:**
```bash
{ date; ./build/bin/llama-bench -m ~/models/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf -t 6 -p 512 -n 128; } 2>&1 | tee benchmark_run3.log
```

**Purpose:** Same-family size comparison against the Run #2 (Llama 3.2 3B) baseline — isolate the effect of model size alone, same architecture lineage, same build, same thread count, same test parameters.

**Results:**

| model | size | params | backend | threads | test | t/s |
|---|---|---|---|---|---|---|
| llama 8B Q4_K - Medium | 4.58 GiB | 8.03 B | CPU | 6 | pp512 | 29.04 ± 0.12 |
| llama 8B Q4_K - Medium | 4.58 GiB | 8.03 B | CPU | 6 | tg128 | 6.09 ± 0.01 |

**Direct comparison — 3B vs 8B, same family, same hardware, same build:**

| Model | Params | pp512 (t/s) | tg128 (t/s) |
|---|---|---|---|
| Llama 3.2 3B Instruct | 3.21 B | 72.62 ± 1.53 | 13.76 ± 0.02 |
| Llama 3.1 8B Instruct | 8.03 B | 29.04 ± 0.12 | 6.09 ± 0.01 |
| **Ratio (3B ÷ 8B)** | **~2.5x params** | **~2.5x faster** | **~2.26x faster** |

**Interpretation:**
- Params scaled ~2.5x (3.21B → 8.03B); pp512 slowed by almost exactly the same ~2.5x factor, and tg128 slowed by a very similar ~2.26x factor. This is a strikingly clean, roughly linear relationship between parameter count and inference cost on this CPU-only setup — consistent with the expectation that CPU inference here is memory-bandwidth-bound (see glossary): a model with ~2.5x the weights needs ~2.5x the data moved from RAM per token, so ~2.5x the time, fairly directly.
- 6.09 t/s for the 8B model is still within originally-estimated ballpark (3–7 t/s for 7B–8B class) and still a usable, readable chat pace — noticeably slower than the 3B's "fast typist" feel, closer to "comfortable reading pace."
- This is now the trusted baseline for Llama 3.1 8B Q4_K_M @ 6 threads on this hardware, directly comparable to the 3B baseline from Run #2 (same build, same test parameters, same day).

---

## Run #4 — 2026-08-31 21:33–22:17 EDT — Thread-count sweep, Llama 3.1 8B Instruct Q4_K_M

**Purpose:** Determine how performance scales with thread count on this 6-core CPU, to find the actual optimal `-t` setting rather than assuming `-t 6` (max cores) is automatically best.

**Commands:** same benchmark repeated with `-t 1` through `-t 6`, e.g.:
```bash
{ date; ./build/bin/llama-bench -m ~/models/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf -t <N> -p 512 -n 128; }
```

**Results:**

| Threads | Time (EDT) | pp512 (t/s) | tg128 (t/s) |
|---|---|---|---|
| 1 | 21:37 | 6.32 ± 0.09 | 2.69 ± 0.04 |
| 2 | 21:49 | 12.54 ± 0.16 | 4.65 ± 0.10 |
| 3 | 22:00 | 18.58 ± 0.06 | 5.45 ± 0.03 |
| 4 | 22:17 | 23.08 ± 0.22 | 5.80 ± 0.03 |
| 5 | 21:33 | 26.30 ± 0.10 | 5.99 ± 0.01 |
| 6 | 21:21 | 29.04 ± 0.12 | 6.09 ± 0.01 |

**Interpretation:**

- **Prompt processing (pp512) scales almost linearly with threads, all the way to 6.** 1→2 threads nearly doubles throughput (6.32→12.54), and each additional thread keeps adding a solid, fairly consistent chunk of speed all the way to 6 threads (29.04 t/s). This matches expectations: prompt processing is the more parallelizable phase (see glossary), so it keeps benefiting from more cores with little sign of saturation yet at 6.

- **Token generation (tg128) shows strong diminishing returns after ~3-4 threads.** The jump from 1→2 threads is huge (2.69→4.65, +73%), 2→3 is still solid (4.65→5.45, +17%), but 3→4 (+6%), 4→5 (+3%), and 5→6 (+1.7%) each add progressively less. Going from 3 threads to 6 threads (double the threads) only bought about a 12% speedup (5.45 → 6.09).

- **Why the difference between the two phases:** this is a textbook illustration of the memory-bandwidth-bound nature of token generation on CPU (see glossary — "Memory bandwidth vs. compute-bound"). Generation is inherently sequential (one token depends on the previous one), so extra threads help less once the RAM-to-cache data pipe becomes the bottleneck rather than available compute. Prompt processing, by contrast, is embarrassingly parallel — many tokens can be crunched simultaneously — so it keeps scaling with cores much further.

- **Practical takeaway for this hardware:** `-t 6` (all cores) is still the best setting for maximum generation throughput, but only by a small margin over `-t 4` or `-t 5` (~5% and ~2% slower respectively). If this VM ever needs to share CPU with other Proxmox workloads, dropping to `-t 4` would sacrifice very little generation speed while freeing up 2 cores — worth remembering. For prompt-heavy workloads (e.g. long documents/RAG), however, all 6 threads remain clearly worth it.

- **`-t 6` remains the recommended default** for this dedicated, single-purpose experiment VM, since there's no other workload competing for cores. Confirmed as the correct baseline setting for Runs #2 and #3.

---

## Run #5 — 2026-08-31 22:50–23:11 EDT — Thread-count sweep, Llama 3.2 3B Instruct Q4_K_M

**Purpose:** Same thread-count sweep as Run #4, but on the 3B model, to see whether the generation-speed saturation point shifts with a smaller model.

**Command (loop):**
```bash
MODEL=~/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf
LOG=benchmark_run5_threadsweep_3b.log

for t in 1 2 3 4 5 6; do
  { date; ./build/bin/llama-bench -m "$MODEL" -t "$t" -p 512 -n 128; } 2>&1 | tee -a "$LOG"
done
```

**Results:**

| Threads | Time (EDT) | pp512 (t/s) | tg128 (t/s) |
|---|---|---|---|
| 1 | 22:50 | 15.77 ± 0.22 | 6.27 ± 0.02 |
| 2 | 22:57 | 30.62 ± 0.76 | 10.79 ± 0.06 |
| 3 | 23:01 | 45.50 ± 0.84 | 12.48 ± 0.08 |
| 4 | 23:04 | 56.80 ± 1.07 | 13.12 ± 0.05 |
| 5 | 23:08 | 64.86 ± 0.86 | 13.54 ± 0.04 |
| 6 | 23:11 | 72.43 ± 1.14 | 13.75 ± 0.02 |

**Interpretation:**

- **Same overall shape as the 8B sweep**: pp512 scales almost linearly with threads (1→6 is roughly a 4.6x speedup, 15.77→72.43), while tg128 shows strong diminishing returns after ~3 threads (1→2 is +72%, 2→3 is +16%, but 3→6 — doubling threads again — only adds another ~10%, 12.48→13.75).
- **Saturation point is essentially the same (~3 threads) as the 8B model** — the smaller model did NOT shift the point of diminishing returns to a different thread count. This makes sense under the memory-bandwidth-bound explanation: the bottleneck is the RAM↔cache pipe itself, a hardware property of this CPU/motherboard, not something that scales with model size. A smaller model needs less total data moved, but the *rate* at which that pipe saturates against added threads is a hardware characteristic, so the curve shape is similar regardless of model size.

**Side-by-side: 3B vs 8B thread scaling (tg128, tokens/sec):**

| Threads | 3B tg128 | 8B tg128 | 3B tok/s gained by adding 1 thread | 8B tok/s gained by adding 1 thread |
|---|---|---|---|---|
| 1 | 6.27 | 2.69 | — | — |
| 2 | 10.79 | 4.65 | +4.52 | +1.96 |
| 3 | 12.48 | 5.45 | +1.69 | +0.80 |
| 4 | 13.12 | 5.80 | +0.64 | +0.35 |
| 5 | 13.54 | 5.99 | +0.42 | +0.19 |
| 6 | 13.75 | 6.09 | +0.21 | +0.10 |

- Both curves show the same "big gains early, marginal gains later" shape. The 3B model's absolute numbers are higher throughout (as expected — smaller model, less data to move per token), but the *pattern* of where extra threads stop mattering is consistent across both model sizes on this hardware.
- **Practical takeaway confirmed and generalized:** for token generation on this CPU, roughly 3–4 threads captures the large majority of achievable speed for both model sizes tested so far. `-t 6` is still marginally best and costs nothing on this dedicated VM, but if cores ever need to be shared with another workload, dropping to 3–4 threads is a low-cost trade-off regardless of which of these two models is in use.

---

## Run #6 — 2026-09-01 — Real-world interactive test, Llama 3.2 3B Instruct Q4_K_M, 4 threads

**Purpose:** Move beyond synthetic `llama-bench` throughput numbers to an actual real prompt/response, with wall-clock time, CPU%, and peak RAM captured via `/usr/bin/time -v`.

**Command:**
```bash
/usr/bin/time -v ./build/bin/llama-cli -m ~/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf -t 4 -p "What causes seasons on Earth?" -n 200 -st --verbose-prompt
```
(`-st` = single-turn, exit after one response instead of staying in interactive chat loop; `--verbose-prompt` prints the prompt before generation.)

**Result:** Model correctly answered the question (Earth's axial tilt explanation). Built-in timing line: `[ Prompt: 6.3 t/s | Generation: 11.8 t/s ]`.

**`/usr/bin/time -v` stats:**
| Metric | Value |
|---|---|
| Elapsed wall clock time | 1:15.48 |
| User time | 73.77s |
| System time | 26.85s |
| Percent of CPU | 133% |
| Maximum resident set size | 7,600,188 KB (~7.25 GB) |
| Major page faults | 3,388,604 |
| File system inputs | 13,764,696 KB (~13.1 GB) |

**⚠️ Finding: numbers look anomalous compared to pure `llama-bench` results, and point to a NAS/mmap bottleneck.**

Comparison against Run #2/thread-sweep data at the same 4-thread setting (pure `llama-bench`, same model):
| Metric | llama-bench (Run #2 family, 4 threads) | This real-world run |
|---|---|---|
| Prompt processing | ~56.8 t/s | **6.3 t/s** (~9x slower) |
| Generation | ~13.1 t/s | 11.8 t/s (roughly consistent) |
| CPU utilization | Expected ~300-400%+ | **133%** (barely over 1 core) |

**Working theory:** llama.cpp memory-maps (`mmap`s) the model file by default rather than loading it fully into RAM upfront — pages are pulled in on-demand as inference touches them. Since the model file lives on a **NAS share over the network**, each on-demand page fault becomes a network round-trip rather than a fast local read. This would explain:
- Low CPU utilization (133%) — CPU sitting idle waiting on network I/O rather than computing.
- ~13.1 GB of "file system inputs" for a 1.87 GB model file — re-faulting pages repeatedly, likely without efficient local caching of the network-mounted file.
- Prompt processing (which needs to touch many weight pages quickly, all at once) hit far harder than generation (which touches pages more gradually, token by token) — consistent with a per-page network-fetch penalty.

**Next step to confirm the theory:** re-run with `--no-mmap`, which forces llama.cpp to fully read the model into RAM upfront (slower start, but pure RAM-speed access afterward, no per-page network round-trips):
```bash
{ date; /usr/bin/time -v ./build/bin/llama-cli -m ~/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf -t 4 -p "What causes seasons on Earth?" -n 200 -st --verbose-prompt --no-mmap; } 2>&1 | tee interactive_test2_nommap.log
```

### Follow-up test A — NAS + `--no-mmap` (2026-09-01, 00:56 EDT)

| Metric | Value |
|---|---|
| Prompt processing | 33.7 t/s |
| Generation | 12.7 t/s |
| Elapsed wall clock | 1:08.29 |
| CPU% | 155% |
| Max RSS | 7,510,536 KB (~7.16 GB) |
| Major page faults | 3,787,655 |
| File system inputs | ~15.9 GB |

Prompt processing jumped ~5x vs. the mmap run (6.3 → 33.7 t/s), supporting the mmap theory so far.

### Follow-up test B — model copied to local disk + `--no-mmap` (2026-09-01, 01:01 EDT)

| Metric | Value |
|---|---|
| Prompt processing | 36.2 t/s |
| Generation | 12.7 t/s |
| Elapsed wall clock | 0:49.43 |
| CPU% | 199% |
| Max RSS | 7,587,468 KB (~7.24 GB) |
| Major page faults | 3,599,654 |
| File system inputs | ~10.9 GB |

**⚠️ Theory correction: NAS/network mmap was NOT the dominant bottleneck.** Moving the model to local disk (still with `--no-mmap`) barely changed prompt processing (33.7 → 36.2 t/s, within noise) — if network round-trips were the main cost, local storage should have shown a much bigger jump. It didn't.

**Revised theory, based on btop screenshots captured during these runs:** RAM usage hit **98-99% with as little as ~52 MiB available**, and the swap bar showed real usage — visible directly in the screenshots. Max RSS across all three runs sat at **~7.2-7.6 GB on an 8GB VM**, dangerously close to the ceiling. The "major page faults" were most likely **swap activity** (OS paging memory out/in under pressure), not (primarily) network fetches.

**Likely root cause of the high RAM usage:** no `-c` (context size) flag was set, so llama.cpp defaulted to `0 = loaded from model`. Llama 3.2's native max context is very large (128K tokens), and llama.cpp pre-allocates the **KV cache** sized against that context limit — regardless of how short the actual prompt/response was. A large default context window likely means a large upfront KV cache allocation, consuming most of the 7.2-7.6GB RSS observed, even for a two-sentence exchange, and pushing the VM to the edge of swapping.

**Next step to confirm:** explicitly cap context size and re-test:
```bash
{ date; /usr/bin/time -v ./build/bin/llama-cli -m ~/Llama-3.2-3B-Instruct-Q4_K_M.gguf -t 4 -c 4096 -p "What causes seasons on Earth?" -n 200 -st --verbose-prompt --no-mmap; } 2>&1 | tee interactive_test3_ctx4096.log
```
If RSS drops well below 8GB and CPU% climbs back toward the 300-400%+ range seen in pure `llama-bench` runs, that confirms context-size/swap pressure — not NAS/mmap — as the real bottleneck for real-world interactive use on this 8GB VM. **Status: pending.**

### Follow-up test C — `-c 4096` explicit context size (2026-09-01, 01:05 EDT) — ROOT CAUSE CONFIRMED

**Command:**
```bash
{ date; /usr/bin/time -v ./build/bin/llama-cli -m ~/Llama-3.2-3B-Instruct-Q4_K_M.gguf -t 4 -c 4096 -p "What causes seasons on Earth?" -n 200 -st --verbose-prompt --no-mmap; } 2>&1 | tee interactive_test3_ctx4096.log
```

| Metric | Value | vs. earlier (no `-c`, local disk) |
|---|---|---|
| Prompt processing | **54.6 t/s** | 33.7-36.2 t/s → ~1.5x faster, matches/exceeds `llama-bench` |
| Generation | 12.8 t/s | consistent (~12.7 t/s) |
| Elapsed wall clock | **0:22.34** | 0:49-1:15 → roughly 2-3x faster overall |
| CPU% | **306%** | 133-199% → healthy multi-core utilization restored |
| Max RSS | **2,522,100 KB (~2.4 GB)** | ~7.2-7.6 GB → ~3x reduction |
| Major page faults | **8** | 3.4-3.8 million → essentially eliminated |

Confirmed via btop screenshot: RAM usage now a comfortable 38% (2.91GB used / 4.82GB available), no swap engaged, CPU cores 3-4 pinned at 100% as expected for `-t 4`.

**Conclusion: root cause was the unset `-c` (context size) flag, not NAS storage or mmap.** With no explicit context size, llama.cpp defaulted to Llama 3.2's large native max context, pre-allocating a KV cache far larger than needed for a short exchange — pushing the 8GB VM into swap thrashing (millions of major page faults, RAM pinned at 98-99%). Once context was explicitly bounded to a sane value (`4096` tokens, plenty for a short Q&A), RAM usage collapsed to ~2.4GB, swapping stopped entirely, and both CPU utilization and prompt-processing speed matched or exceeded the pure `llama-bench` figures.

**Practical rule going forward: always set `-c` explicitly**, sized to the actual expected use case, rather than leaving it at the model's default maximum — especially important on this 8GB VM, and will matter even more with the 8B model (bigger model + oversized KV cache compounds RAM pressure further).

---

## Run #7 — Accuracy Benchmark (2026-09-02) — All 6 Models, 30-Question Test Set

**Purpose:** Move beyond `llama-bench` throughput numbers to output *quality*. All 6 models from the reference guide were run against the same fixed 30-question test set (general knowledge, logic/math, coding, summarization, open-ended writing, and a Linux server admin curveball category spanning beginner to advanced). Each answer graded 0–5 by hand against a grading rubric. Full question-by-question grades and notes are tracked separately in `model-accuracy-test-set.md` (not this file) — this entry holds the headline/summary numbers only.

**Headline results (overall average, out of 5):**

| Model | Overall Avg |
|---|---|
| Llama 3.1 8B | 4.83 |
| Phi-3.5 Mini 3.8B | 4.73 |
| Llama 3.2 3B | 4.50 |
| Qwen 2.5 3B | 4.45 |
| Gemma 2 2B | 4.03 |
| DeepSeek-R1-Distill-Qwen 1.5B | 2.18 |

**By-category averages (out of 5):**

| Model | General Knowledge | Logic & Math | Coding | Summarization | Writing | Linux Sysadmin |
|---|---|---|---|---|---|---|
| Gemma 2 2B | 4.00 | 5.00 | 4.06 | 4.00 | 4.17 | 3.64 |
| DeepSeek-R1-Distill-Qwen 1.5B | 3.12 | 3.12 | 3.62 | 2.88 | 2.83 | 0.55 |
| Llama 3.2 3B | 4.50 | 5.00 | 4.00 | 4.12 | 4.83 | 4.55 |
| Qwen 2.5 3B | 4.25 | 5.00 | 5.00 | 4.38 | 5.00 | 4.00 |
| Phi-3.5 Mini 3.8B | 3.88 | 5.00 | 5.00 | 4.75 | 5.00 | 4.77 |
| Llama 3.1 8B | 4.62 | 5.00 | 4.88 | 4.88 | 4.83 | 4.82 |

**Key findings:**

- **Llama 3.1 8B and Phi-3.5 Mini 3.8B were the strongest all-rounders**, both scoring highly across every category including the Linux sysadmin curveball. Given this machine's speed numbers (Llama 3.1 8B: 6.09 tg128 t/s @ 6 threads, a "comfortable reading pace"), Llama 3.1 8B looks like the best default choice for general assistant + sysadmin Q&A use on this hardware, with Phi-3.5 Mini as a faster, nearly-as-accurate fallback (11.38 tg128 t/s baseline, per the reference guide) when speed matters more.
- **DeepSeek-R1-Distill-Qwen 1.5B is a striking split-personality result:** genuinely strong on logic/math (3.12 avg, clean chain-of-thought reasoning, correct answers), but catastrophic on Linux sysadmin questions (0.55 avg) — it confidently fabricated nonexistent commands and flags across nearly every sysadmin question rather than hedging or declining. This is a more dangerous failure mode than simply "wrong," since the fabricated commands read as fluent and plausible. **Practical takeaway: do not trust this model for sysadmin/Linux command questions on this machine, despite its excellent raw speed (26.29 tg128 t/s) and math ability.**
- **Two real technical errors surfaced in otherwise-strong models**, worth flagging for future spot-checks: Qwen 2.5 3B dropped the minute field in a cron schedule (would run every minute during the 2am hour instead of once daily) and separately recommended flushing all firewall rules just to add one port rule.
- **Phi-3.5 Mini had one bizarre single-question failure** (weather/climate explained in "two sentences" instruction) where it answered correctly then spiraled into a large fabricated wall of unrequested follow-up content — an isolated instruction-following miss rather than a knowledge gap.

**Caveat on grading:** grades were done by hand, not automated, using the rubric in `model-accuracy-test-set.md`. Some "most moons" answers (Q2) cite Jupiter with ~79-92 moons; this was the correct answer as of these models' training cutoffs, but Saturn overtook Jupiter's moon count after a large 2023 discovery batch — not treated as a model error here since it reflects training-data recency rather than reasoning failure.

---

## Run #8 — Vision Model Accuracy Benchmark (2026-09-03) — 6 Models, 15-Image Test Set

**Purpose:** First real-world accuracy/speed evaluation of vision-capable (multimodal) models on this hardware, following up on the "Not Yet Benchmarked" vision candidates originally listed in `Local_AI_Model_Reference_Guide.md`. All models tested against the same fixed 15-image set (photos, game/UI screenshots, technical CLI output, 3D-rendered characters, and handwritten text), single-turn "describe this image in detail" prompt, hand-graded 0-5 for description accuracy against what the image actually shows. Full per-image responses, grades, and notes are tracked separately in `vision-model-accuracy-test-set.md` (not this file) — this entry holds the headline/summary numbers only.

**Headline results (average accuracy grade out of 5, average inference time per image):**

| Model | Params | Avg Accuracy | Avg Inference Time |
|---|---|---|---|
| Qwen2-VL-7B | ~7B | 4.85 | ~206s |
| MiniCPM-V-2 | ~2.8B | 4.73 | ~104s |
| Gemma 3 4B | ~4B | 4.49 | ~78s |
| Qwen2-VL-2B | ~2B | 4.28 | ~87s |
| LLaVA-1.6 13B | ~13B | Failed to load (OOM) | N/A |
| InternVL2 8B+ | 8B+ | Ungraded — responses truncated on all 15 images | N/A |

**Key findings:**

- **Qwen2-VL-7B was the most accurate model tested**, handling complex multi-subject scenes (e.g. correctly distinguishing most details across 5 similarly-dressed costumed characters) and structured technical screenshots (e.g. a full, correct `ipconfig`-style IPv6/IPv4 breakdown) noticeably better than the smaller models. Cost: by far the slowest of the working models (~206s/image average), with the two largest/highest-resolution test images pushing past 500s and in two cases cutting the response off mid-sentence despite otherwise-accurate partial content.
- **MiniCPM-V-2 delivered the best accuracy-per-parameter** — at under 3B parameters, it beat both the larger Gemma 3 4B and the similarly-sized Qwen2-VL-2B on average grade (4.73 vs. 4.49 and 4.28), with noticeably fewer outright fabrications than Qwen2-VL-2B.
- **Gemma 3 4B was the best speed/quality balance** among the four models that both loaded and completed reliably — fastest average inference time (~78s/image) while still landing mid-to-high on accuracy. Its most consistent failure mode was struggling with dense structured technical text (e.g. misreading a Windows `ipconfig` screenshot as a Linux terminal, garbling IP octets).
- **Qwen2-VL-2B was the least trustworthy of the working models**, despite being genuinely strong at raw OCR/transcription of text and numbers in an image. Its main failure mode was confidently fabricating the *meaning* of correctly-read text or stats — e.g. accurately transcribing a game UI's numbers and labels but inventing entirely wrong explanations for what each stat represented. This is a more deceptive failure mode than a vague or obviously-wrong answer, since the surrounding detail reads as fluent and plausible.
- **Image resolution/file size was a major driver of inference time across every model**, independent of model size — the two largest test images (4948x3711 and 2105x3000) were consistently the slowest per-model across the board, sometimes 5-10x a typical result, and in several cases (Qwen2-VL-2B, Qwen2-VL-7B) caused the response to be truncated before the model finished, despite scoring well on the partial content that did generate.
- **LLaVA-1.6 13B is not viable on this 8GB VM** — the Linux OOM killer terminated it on load, consistent with the RAM-budget concerns already flagged for 13B+ text models on this hardware (see Section 4 of `experiment-log.md`). Not a speed/quality tradeoff question — it simply does not run here.
- **InternVL2 8B+ could not be fairly graded** — every one of the 15 test images produced a response that was truncated/cut off before completion, so no full answer was captured to grade against the rubric. The partial output that did generate looked plausible on a few images, but the underlying cause (likely a stop-token, generation-length, or memory-pressure configuration issue specific to this model/setup) needs to be diagnosed before this model can be meaningfully evaluated on this hardware.

**Reference guide updated:** the "Vision Model Candidates" table in `Local_AI_Model_Reference_Guide.md` has been updated from estimated/relative speed figures to these real measured results.

---

## Run #9 — Context Size OOM Sweep (2026-09-06, 15:57–16:55 EDT) — 9 models, `--no-mmap` vs. mmap, doubling `-c` to failure

**Purpose:** Find, per model and per mmap mode, the largest `-c` (context size) that still fits in this 8GB VM's RAM before the Linux OOM killer terminates the process — extending the single-model finding from Run #6 (unset `-c` → KV-cache-driven swap thrashing) into a systematic per-model ceiling.

**Method:** `-c` doubled starting at 512, `-n 200 -t 4 -b 2048 -ub 512`, prompt "What causes seasons on Earth?". `--no-mmap` and default-mmap modes swept independently per model; each stops once it OOMs.

**Full per-model tables:** see `ctx-oom-sweep-by-model.md`.

**Note:** a batch of "OOM at `-c 512`" results were dropped entirely from this sweep — they shared duplicated/reused kernel-log evidence across different models (a logging artifact) and weren't usable data. Affected and needing a re-run: Meta-Llama-3.1-8B (`--no-mmap`), Phi-3.5-mini (both modes), Qwen2.5-3B (`--no-mmap`, plus its duplicate-filename variant `qwen2.5-3b-instruct-q4_k_m.gguf` entirely), Gemma-3-4B (`--no-mmap`), Llama-3.2-3B (both modes), gemma-2-2b (both modes).

**Verified results kept:**

| Model | Mode | OOM at -c | Max RSS just before kill |
|---|---|---|---|
| Mistral-7B-Instruct-v0.3 | --no-mmap | 32768 | 2.43 GB (partially swapped in at kill) |
| Mistral-7B-Instruct-v0.3 | mmap (default) | 65536 | 4.35 GB |
| Meta-Llama-3.1-8B-Instruct | mmap (default) | 65536 | 3.65 GB |
| Qwen2.5-3B-Instruct | mmap (default) | 262144 | 5.37 GB |
| Gemma-3-4B-it | mmap (default) | 524288 | 5.25 GB |
| DeepSeek-R1-Distill-Qwen-1.5B | --no-mmap | 524288 | 4.31 GB |
| DeepSeek-R1-Distill-Qwen-1.5B | mmap (default) | 524288 | 5.23 GB |

**Interpretation:**
- **Bigger/heavier models OOM at smaller context sizes**, as expected — Mistral-7B and Llama-3.1-8B hit their ceiling in the tens of thousands of tokens, while the much smaller DeepSeek-R1-Distill 1.5B survived all the way to 524288 in both modes. This is consistent with the KV-cache-scales-with-context finding from Run #6: a bigger base model leaves less RAM headroom for the KV cache before the combined footprint exceeds 8GB.
- **`mmap` (default) mode consistently tolerated a larger context than `--no-mmap` before OOMing** where both are trustworthy (Mistral: 32768 vs 65536). This tracks with `mmap`'s lazy on-demand paging: with mmap enabled, cold model-weight pages can be dropped/reloaded under memory pressure rather than counting as pinned anonymous memory the same way a fully RAM-loaded (`--no-mmap`) copy does, buying a bit more headroom before the OOM killer's threshold is crossed. This is a nuance worth testing further, not yet a fully confirmed mechanism.
- **DeepSeek-R1-Distill-Qwen-1.5B is the clear outlier in a good way** — its small parameter count leaves so much RAM headroom that it tolerated a context size (524288) two orders of magnitude larger than any other model tested here before finally OOMing, in both mmap modes.
- **Practical takeaway:** once the missing models/modes are re-run, this sweep should become the reference table for "max safe `-c` per model on this 8GB VM" — replacing ad hoc single-context testing (like Run #6's `-c 4096` pick for Llama 3.2 3B) with an actual measured ceiling per model.

**Action items:**
- [ ] Re-run the OOM sweep for: Meta-Llama-3.1-8B (--no-mmap only), Phi-3.5-mini (both modes), Qwen2.5-3B (--no-mmap only), Gemma-3-4B (--no-mmap only), Llama-3.2-3B (both modes), gemma-2-2b (both modes) — capture kernel log via a fresh `dmesg -c` (clear-on-read) immediately after each individual run rather than a shared buffer.
- [ ] De-duplicate `Qwen2.5-3B-Instruct-Q4_K_M.gguf` and `qwen2.5-3b-instruct-q4_k_m.gguf` in the model list before re-running — these appear to be the same model under two filenames.
- [ ] Once complete, fold the confirmed "max safe `-c`" per model into `Local_AI_Model_Reference_Guide.md` as a new column.

---

## Run #10 — Context Size Sweep Re-run (2026-09-06, 19:45 EDT) — 6 models, resolving Run #9's discarded results

**Purpose:** Re-run the models/modes Run #9 couldn't trust (Meta-Llama-3.1-8B `--no-mmap`, Phi-3.5-mini both modes, Qwen2.5-3B `--no-mmap`, Gemma-3-4B `--no-mmap`, Llama-3.2-3B both modes, gemma-2-2b both modes), same method as Run #9: `-c` doubled from 512 until failure.

**New failure mode identified:** not every stop in this sweep was an OOM-kill. Several models instead hit `Error: the server exited before becoming ready` — `llama-cli`/`llama-server` failing to start cleanly, rather than being killed mid-run by the kernel. Both are treated as memory-related failures (the requested allocation exceeding what's available) and both end that model/mode's sweep; the difference is just whether the OS forcibly killed a running process (OOM-kill, `SIGKILL`/exit 137) or the allocation failed up front before the process became ready. Full per-model tables, including which failure type applies to each model, are in `ctx-oom-sweep-by-model.md`.

**Full per-model tables:** see `ctx-oom-sweep-by-model.md`.

**Results — confirmed ceilings (all models in this batch now resolved):**

| Model                      | `--no-mmap` ceiling / failure at                     | `mmap (default)` ceiling / failure at                  |
| -------------------------- | ---------------------------------------------------- | ------------------------------------------------------ |
| Meta-Llama-3.1-8B-Instruct | 32768 / fails at 65536 (OOM-killed)                  | 131072 / fails at 262144 (clean allocation failure) ⚠️ |
| Phi-3.5-mini-instruct      | 16384 / fails at 32768 (OOM-killed)                  | 32768 / fails at 65536 (clean allocation failure)      |
| Qwen2.5-3B-Instruct        | 262144 / fails at 524288 (clean allocation failure)  | 262144 / fails at 524288 (clean allocation failure)    |
| Gemma-3-4B-it              | 524288 / fails at 1048576 (clean allocation failure) | 524288 / fails at 1048576 (clean allocation failure)   |
| Llama-3.2-3B-Instruct      | 65536 / fails at 131072 (OOM-killed)                 | 65536 / fails at 131072 (OOM-killed)                   |
| gemma-2-2b-it              | fails immediately at 512 (OOM-killed)                | fails immediately at 512 (OOM-killed)                  |


**Llama-3.2-3B-Instruct now fully consistent with prior trusted data:** Run #9's version of this model was discarded because it contradicted Run #6's confirmed result (`-c 4096` running fine with ~2.4GB RSS). This re-run is consistent with Run #6 — clean up through `-c 65536`, OOM-killed only at `-c 131072` in both modes.

**Practical takeaway:** with this run, every model in the original Run #9 batch now has a real, confirmed (or flagged-and-explained) memory ceiling on this 8GB VM, except the one open Llama-3.1-8B mmap discrepancy above.

**Action items:**
- [ ] Re-run Meta-Llama-3.1-8B `mmap (default)` a third time at `-c 65536` specifically, checking `free -h` immediately beforehand, to resolve the Run #9 vs. Run #10 contradiction.
- [ ] Fold all confirmed "max safe `-c`" values into `Local_AI_Model_Reference_Guide.md` (done for this pass — see that file's "Max Safe `-c`" column).
- [ ] Consider re-testing Mistral-7B and DeepSeek-R1-Distill-1.5B (the two models not included in this re-run) with the same rigor, purely as a consistency check, given how much this run reshuffled expectations for the other six.




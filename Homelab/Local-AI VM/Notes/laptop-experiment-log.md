# Local AI on Gigabyte Laptop (RTX 5060 8GB, CachyOS) — Experiment Log

A running log of decisions, hardware specifics, and results for this laptop. This is a **separate machine** from the OptiPlex/Fedora CPU-only box tracked in `experiment-log.md` / `benchmark-results-log.md` — do not mix numbers between the two. For definitions of terms used here, see `concepts-glossary.md` (kept generic/reusable across machines).

---

## 1. This Machine's Setup

| Component | Detail |
|---|---|
| Host | Gigabyte GAMING A16 (laptop) |
| OS | CachyOS x86_64, kernel 7.2.6-1-cachyos |
| CPU | 13th Gen Intel Core i7-13620H (12+4 cores, hybrid P/E), up to 4.90 GHz |
| GPU (discrete) | NVIDIA GeForce RTX 5060 Laptop/Max-Q, 7705 MiB usable VRAM (~8GB card) |
| GPU (integrated) | Intel UHD Graphics |
| RAM | 30.97 GiB total |
| Inference engine | llama.cpp, CUDA backend (`libggml-cuda.so`), CPU backend `libggml-cpu-alderlake.so` |
| Power management | `powerprofilesctl` (performance / balanced / power-saver profiles) |

**Build source — different from the OptiPlex project:** `llama.cpp` and `ggml-cuda` were installed here as **prebuilt Arch/CachyOS repo packages**, not self-compiled. The OptiPlex project's `rm -rf build` / stale-incremental-object-file explanation for the "asserts enabled, performance may be affected" warning does **not** apply here — there is no local `build/` directory or incremental-compile history to have gone stale. The warning is showing up on a fresh distro package instead, so the cause is different (likely how the CachyOS/Arch package itself is built — possibly a deliberate choice for upstream bug-reporting, or the distro maintainer's default build flags) and hasn't been root-caused yet on this machine.
- **Action item:** check the CachyOS/AUR/Arch package build recipe (`PKGBUILD`) for `llama.cpp`/`ggml-cuda` to see whether asserts/debug flags are intentionally enabled in the packaged build, or file/check for an existing upstream report. If a Release-optimized build is wanted, the alternative is self-compiling from source on this machine (same process documented in `experiment-log.md` section 3) rather than relying on the repo package.
- Numbers below should still be treated as provisional versus a confirmed-Release build, but the power-profile *comparison* between runs is unaffected since all runs used the same package binary.

---

## 2. Power Profile Comparison — Llama 3.1 8B Instruct Q4_K_M, `-ngl 999` (full GPU offload)

**Purpose:** Test whether `powerprofilesctl` power profile affects local inference speed on this laptop, expecting `performance` to be fastest.

**Command pattern:**
```bash
powerprofilesctl set performance && llama-bench -m Llama-3.1-8B-Instruct-Q4_K_M.gguf -ngl 999
powerprofilesctl set power-saver && llama-bench -m Llama-3.1-8B-Instruct-Q4_K_M.gguf -ngl 999
```

**Results:**

| Power Profile | pp512 (t/s) | tg128 (t/s) |
|---|---|---|
| `performance` | 1551.00 ± 212.77 | 31.72 ± 0.44 |
| `power-saver` | 2081.93 ± 213.33 | 59.98 ± 0.23 |

**⚠️ Counterintuitive finding: `power-saver` was faster than `performance` on both metrics** — pp512 ~34% faster, tg128 ~89% faster (nearly 2x).

**✅ Root cause confirmed directly via `nvidia-smi -q -d POWER`** — no need to infer from throughput alone. The GPU's own power limit is set **inversely** to what the profile name suggests:

| Power Profile | GPU Current/Requested Power Limit | Default Power Limit |
|---|---|---|
| `performance` | **45.85 W** | 50.00 W |
| `balanced` | 53.77 W | 50.00 W |
| `power-saver` | **60.86 W** | 50.00 W |

**This confirms the shared/inverse power-budget theory as fact on this machine, not just a plausible explanation:** the `performance` profile actually *caps the GPU's power limit below* its own default (45.85W vs. 50W default), while `power-saver` *raises* the GPU's power limit above default (60.86W vs. 50W). The OS-level "performance" profile is evidently tuned around CPU performance (sustained high CPU clocks/power), and on this laptop's shared power/thermal design, that comes directly at the cost of the GPU's allowed power ceiling — the opposite trade a user would reasonably expect from a profile named "performance" if their workload is GPU-bound. `power-saver`, despite the name, gives the GPU the *most* headroom of the three profiles, explaining the higher pp512/tg128 throughput measured under it.

**Practical takeaway for this machine:** for GPU-bound local inference (`-ngl 999`/full offload), use `power-saver` — it is not a trade-off against speed here, it is strictly faster than `performance` for this workload. `performance` mode is presumably the right choice only for CPU-bound workloads on this laptop, where the naming would make sense.

**Remaining action items:**
- [ ] Test a CPU-only run (`-ngl 0`) across the three profiles to confirm `performance` actually wins for CPU-bound work here (would confirm the profile is CPU-tuned as theorized, rather than being uniformly mis-tuned).
- [ ] Check whether the GPU power limit is adjustable independently of the OS power profile (e.g. `nvidia-smi -pl <watts>`, if permitted on this laptop/driver) to see if `performance` CPU behavior can be combined with `power-saver`-level GPU headroom.
- [ ] Investigate whether this is standard Gigabyte/Nvidia Advanced Optimus behavior on this model or a CachyOS power-profile-daemon mapping quirk — check `powerprofilesctl` / `power-profiles-daemon` config for how each profile is defined on this system.
- [ ] Resolve the debug-build/assert warning (see Build Source note above) before trusting absolute t/s numbers, independent of this power-profile finding.

---

---

## 3. Full Model Benchmark + Context Sweep — All Models, Full GPU Offload

**Purpose:** Extend the single-model power-profile test (Section 2) into a full per-model throughput and max-context sweep on this GPU, using the same model set tracked for the OptiPlex CPU box (`Local_AI_Model_Reference_Guide.md`) for a like-for-like comparison point.

**Scripts used:**
- [Model-Benchmark.sh](https://github.com/Mr-Tinkerer/Project-Dump/blob/main/Homelab/Local-AI%20VM/Notes/Benchmark%20Scripts/Model-Benchmark.sh) — per-model `llama-bench` pp512/tg128 sweep.
- [ctx_sweep.sh](https://github.com/Mr-Tinkerer/Project-Dump/blob/main/Homelab/Local-AI%20VM/Notes/Benchmark%20Scripts/ctx_sweep.sh) — doubling `-c` context size per model to find the max safe value on this GPU (same methodology as the OptiPlex OOM sweep in `benchmark-results-log.md` Runs #9/#10, adapted for VRAM instead of system RAM).

**Results (full GPU offload, `-ngl 999`):**

| Model | Params | pp512 (t/s) | tg128 (t/s) | Max safe `-c` |
|---|---|---|---|---|
| DeepSeek-R1-Distill-Qwen 1.5B | 1.5B | 8587.02 | 175.96 | 2,097,152 |
| Gemma 2 2B | 2B | 6024.78 | 100.19 | 262,144 |
| Llama 3.2 3B | 3B | 4436.13 | 164.79 | 262,144 |
| Qwen 2.5 3B | 3B | 4272.83 | 93.30 | 1,048,576 |
| Phi-3.5 Mini 3.8B | 3.8B | 3106.71 | 76.32 | 131,072 |
| Llama 3.1 8B | 8B | 1878.74 | 44.42 | 262,144 |
| Mistral 7B | ~7B | 1913.68 | 48.97 | 262,144 |

**Notes / not yet recorded:**
- [ ] Power profile used for this sweep was not logged — given the Section 2 finding (`power-saver` outperforming `performance` on this laptop's GPU-bound workloads), the profile in effect during this run should be confirmed/recorded before treating these as a stable baseline, and ideally the full sweep re-run under whichever profile is chosen as the laptop's standard.
- [ ] `-fa/--flash-attn` state during this run not recorded — worth confirming on/off, since flash attention can be a meaningful speed/VRAM difference on supported GPUs (see GPU flag reference in `concepts-glossary.md`).
- [ ] Max-safe-`-c` figures above are VRAM-driven ceilings (8GB card), not the RAM/OOM ceilings tracked for the OptiPlex box — the two are not directly comparable numbers even for the same model name.
- [ ] Compare these numbers directly against the OptiPlex CPU baselines in `Local_AI_Model_Reference_Guide.md` once profile/flash-attention state is confirmed, to quantify the GPU speedup per model.

---

## 4. Power Profile Comparison — CPU-Only Inference (`-ngl 0`), Llama 3.1 8B Instruct Q4_K_M

**Purpose:** Follow-up action item from Section 2 — confirm whether `performance` power profile actually wins for CPU-bound work on this laptop (as theorized), now that Section 2 established it *loses* for GPU-bound work.

**Note on `-ngl 0` and the `backend` column:** setting `-ngl 0` does **not** stop llama.cpp from loading/initializing the CUDA backend — it just stops model layers from being offloaded to it. `llama-bench`'s `backend` column still reports `CUDA` even at `-ngl 0`, which is a labeling artifact (which backend loaded), not a statement of what actually computed. Confirmed via `btop` during these runs that the CPU (not GPU) was doing the work despite the misleading column. `CUDA_VISIBLE_DEVICES=""` would suppress CUDA entirely and give a cleaner backend label if wanted for future runs, but wasn't necessary here since GPU utilization was independently verified as idle via `btop`.

**Results (`-ngl 0`, all layers on CPU):**

| Power Profile | pp512 (t/s) | tg128 (t/s) |
|---|---|---|
| `power-saver` | 470.88 ± 36.38 | 2.84 ± 0.02 |
| `performance` | 725.47 ± 2.73 | 7.29 ± 0.56 |

**Comparison against full GPU offload (Section 2, same model):**

| Mode | pp512 (t/s) | tg128 (t/s) |
|---|---|---|
| Full GPU (`-ngl 999`) | 1707.84 ± 26.98 | 39.42 ± 0.22 |
| CPU-only, `power-saver` | 470.88 ± 36.38 | 2.84 ± 0.02 |
| CPU-only, `performance` | 725.47 ± 2.73 | 7.29 ± 0.56 |

**✅ Theory confirmed, and more pronounced than the GPU-bound case:** `performance` mode beat `power-saver` on CPU-only work by ~54% on pp512 and **~2.6x** on tg128 (7.29 vs 2.84 t/s) — the opposite direction from Section 2's GPU-bound result, and a larger swing than the ~89% `power-saver` advantage seen there. This is consistent with `performance` mode prioritizing sustained CPU clocks/power at the GPU's expense (Section 2), which is exactly the right trade for a CPU-bound workload and the wrong one for a GPU-bound workload.

**Practical takeaway for this machine, now complete:**
- GPU-bound inference (`-ngl` high/full offload) → use `power-saver`.
- CPU-only inference (`-ngl 0`) → use `performance`.
- Whichever profile the workload favors, the effect size here (up to ~2.6x on generation speed) is large enough that picking the wrong profile is a bigger performance loss than most other single tuning choice tested on this machine so far.

**Still open:**
- [ ] `balanced` profile not yet tested for the CPU-only case (only tested for GPU-bound in Section 2) — would complete the 3x3 matrix.
- [ ] Thread count (`-t`) not explicitly set for these runs — given the hybrid P/E-core CPU (12+4), a thread-count sweep (like the OptiPlex's) is still worth doing to see if the P/E split changes the "diminishing returns" thread count found on the OptiPlex's uniform-core CPU.
- [ ] Debug/assert build warning (see Section 1) still unresolved — these numbers are trustworthy as relative profile comparisons on the same binary, but not yet a confirmed absolute performance ceiling for this machine.

---


## 5. `-nkvo` vs. Context Size Sweep — Llama 3.1 8B Instruct Q4_K_M, `-ngl 999`

**Purpose:** Follow-up on Section 4-era `-nkvo` spot check — determine whether an oversized KV cache (relative to remaining VRAM after model weights) causes a hard cutover to CPU-speed generation or a gradual slowdown, and find the practical crossover point where `-nkvo` starts being worth using on this GPU.

**Method:** `tg128`-equivalent generation speed measured across a range of `-c` context sizes, with and without `-nkvo`, full GPU offload (`-ngl 999`) throughout.

**Results (t/s):**

| Context (`-c`) | Without `-nkvo` | With `-nkvo` |
|---|---|---|
| ~11,264 | 37.5 | 33.2 |
| 23,552 | 22.2 | 27.7 |
| 29,696 | 17.6 | 27.0 |
| 41,984 | 14.1 | 28.1 |
| 60,416 | 11.3 | 28.2 |
| 72,704 | 10.5 | 27.6 |

**Interpretation:**
- **Without `-nkvo`: continuous degradation as context grows** — 37.5 → 10.5 t/s across the range tested, a ~3.6x collapse. Confirms the KV-cache-crowds-VRAM effect (first observed via `btop` showing CPU activity at large `-c`) is a sliding scale tied to how much VRAM the growing cache consumes, not a one-time fallback threshold.
- **With `-nkvo`: flat throughput regardless of context** — ~27-33 t/s across the whole range, since the cache lives in RAM from the start and never displaces weights from VRAM. Only a fairly constant PCIe-transfer cost is paid per token, independent of context size in this data.
- **There is a real crossover point — `-nkvo` is not a universal win.** At small context (~11K tokens), leaving `-nkvo` off is faster (37.5 vs 33.2 t/s) — no VRAM pressure yet, so the PCIe tax of `-nkvo` isn't worth paying. Somewhere between ~11K and ~24K tokens the lines cross; past that, `-nkvo` wins by a growing margin, up to ~2.6x faster at 72,704 tokens (27.6 vs 10.5 t/s).
- **Practical rule for this machine:** leave `-nkvo` off for short-context use (roughly under ~15-20K tokens), turn it on for anything expected to run into the tens of thousands of tokens of context. Exact crossover will depend on available VRAM and model size — this number is specific to an 8B model on a 7705 MiB card, re-verify for other model sizes on this same GPU rather than assuming the same crossover point transfers.
- **This also retroactively explains the earlier `btop`-observed "silently uses CPU at `-c 72704`" finding** — it wasn't a discrete fallback event, just the tail end of this same continuous slowdown, at a large enough context that most of the effective throughput was already lost.

**Open items:**
- [ ] Narrow down the exact crossover context size (currently only bounded to "somewhere between ~11K and ~24K tokens") with a finer-grained sweep in that range.
- [ ] Repeat this sweep on a different model size (e.g. the 3B or Mistral 7B already benchmarked in Section 3) to see whether the crossover point scales with model size / remaining VRAM headroom.
- [ ] Confirm `pp512`-equivalent (prompt processing) shows the same pattern, or if prompt processing behaves differently from generation under VRAM pressure (worth checking, since pp and tg have different parallelism/memory-access characteristics per the CPU-side findings in `concepts-glossary.md`).

---

*Section 5 added: 2026-09-24 — `-nkvo` vs. context size sweep, confirming gradual (not binary) VRAM-crowding slowdown and a measured crossover point for when `-nkvo` becomes worth using.*

## 6. Partial Offload, Larger Model — Qwen3-14B Q4_K_M (doesn't fit in VRAM)

**Purpose:** Real-world check of a model too large to fully offload to this laptop's 7705 MiB VRAM — first test where offload was left to automatic behavior rather than explicitly set.

**Command:**
```
llama-cli -m Qwen3-14B-Q4_K_M.gguf -p "Write me a 1000 word story about how AI is going to kill all humans" -st -c 11265 -nkvo
```
(No `-ngl` specified. `-nkvo` used, so KV cache forced to system RAM regardless of layer split.)

**Result:** `Prompt: 56.9 t/s | Generation: 9.9 t/s`. Observed via `btop`: most of the model resident in VRAM, remainder in system RAM — confirms partial/hybrid offload happened automatically with no `-ngl` given (see corrected default-`-ngl` note in `concepts-glossary.md`).

**Comparison against same-laptop 8B numbers:**

| Model / mode | tg128-equivalent (t/s) |
|---|---|
| Llama 3.1 8B, full GPU offload | 39.42 |
| Llama 3.1 8B, CPU-only (`performance` profile) | 7.29 |
| Qwen3-14B, automatic partial offload + `-nkvo`, `-c 11265` | **9.9** |

**Interpretation:** even with "most" of a larger (14B) model sitting in fast VRAM, generation speed (9.9 t/s) lands much closer to the CPU-only 8B baseline (7.29 t/s) than to anything GPU-offload-speed — consistent with the earlier theory that hybrid-split throughput gets dragged down toward CPU-layer speed rather than averaging proportionally by the fraction of layers offloaded. Not yet confirmed exactly how many layers were on GPU vs. CPU (the usual `load_tensors: offloaded X/Y layers to GPU` line was not visible in this run's output — possibly scrolled past, or this build's default logging is quieter than expected; re-run with output piped to a log file to capture it, or pass a verbose flag if the build supports one).

**Open items:**
- [ ] Re-run with output captured to a file (`2>&1 | tee`) to get the exact offloaded-layer count and confirm/refute the "auto-offload as many layers as fit" default-`-ngl` theory directly from the load log.
- [ ] Re-run the same prompt with explicit `-ngl` values (e.g. matching what auto-offload chose, then a few steps above/below) to see how sensitive throughput is to the exact layer count for a model this size.
- [ ] Test without `-nkvo` at the same `-c` for comparison, now that Section 5 showed `-nkvo` isn't a universal win at small-to-mid context sizes.

---

*Section 6 added: 2026-09-24 — Qwen3-14B partial/automatic offload real-world test, first case of auto-offload behavior with no explicit `-ngl`.*

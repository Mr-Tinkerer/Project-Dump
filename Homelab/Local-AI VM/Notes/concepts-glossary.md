# Local AI Inference — Concepts & Vocabulary Glossary

A reference glossary for running local LLMs, especially in CPU-only environments. Written to be **hardware-agnostic** — applicable to any machine, not just one specific setup. Machine-specific numbers/decisions go in a separate experiment log; this file is the "what does this term mean" reference.

---

## Tools

**Ollama**
A wrapper around llama.cpp. Adds a model manager, REST API, OpenAI-compatible endpoint, and simple CLI (`ollama pull`, `ollama run`). Trades fine-grained control for convenience. Good for quickly getting something running; less good when you want to tune performance precisely.

**llama.cpp**
The underlying inference engine itself (no wrapper). Exposes direct control over threading, batch size, quantization format, and compile-time optimization flags. More setup effort, but necessary if you want to actually understand and tune performance — especially important on CPU-only or otherwise constrained hardware.

**GGUF**
The file format llama.cpp (and Ollama, under the hood) uses for model weights. A single `.gguf` file bundles the quantized weights, tokenizer, and metadata needed to run a model.

**llama-bench**
A benchmarking tool bundled with llama.cpp for measuring real tokens/sec on your specific hardware and build. Always trust benchmark numbers from your own machine over ballpark figures from the internet.

---

## CPU / Hardware Concepts

**SIMD (Single Instruction, Multiple Data)**
A category of CPU instructions that perform the same operation on multiple data points in one instruction cycle. Matrix multiplication — the core operation in neural network inference — benefits enormously from SIMD, which is why CPU inference speed depends so heavily on which SIMD extensions the CPU (and the software build) support.

**AVX / AVX2 / AVX-512**
Successive generations of x86 SIMD instruction extensions from Intel/AMD:
- **AVX2**: 256-bit-wide SIMD operations. Common from ~2013 onward (Haswell generation and later). A large speed win over no SIMD optimization at all.
- **AVX-512**: 512-bit-wide SIMD operations (~2x the throughput of AVX2 per instruction). Only present on newer/higher-end chips (server-class Skylake-X/Ice Lake and later, some newer consumer chips). Not universal — always check before assuming it's available.
- Takeaway: the newest/widest SIMD extension your specific CPU supports should be the one you compile llama.cpp for. Compiling for an extension the CPU doesn't have will crash or silently fall back to a slower path; compiling for less than the CPU supports leaves performance on the table.

**x86-64 microarchitecture levels (v1–v4)**
A standardized shorthand (used by compilers, glibc, and virtualization CPU-type settings) for "which instruction set extensions can I assume are present":

| Level | Adds on top of previous | Roughly corresponds to |
|---|---|---|
| x86-64 (baseline) | Original AMD64 spec | Any 64-bit x86 CPU |
| x86-64-v2 | SSE3, SSSE3, SSE4.1, SSE4.2, POPCNT | ~2008+ |
| x86-64-v3 | AVX, AVX2, FMA, BMI1/2, MOVBE | ~2013+ |
| x86-64-v4 | AVX-512 | Higher-end / server chips, varies |

This matters most in **virtualized environments** (see below) where the hypervisor decides what CPU flags the guest OS is allowed to see, independent of what the physical hardware actually supports.

**Virtual CPU type (in a hypervisor, e.g. Proxmox/KVM/QEMU)**
When a VM's CPU type is set to a generic/portable profile (e.g. an explicit microarchitecture level, or a generic baseline model), the guest OS only sees the instruction set flags included in that profile — even if the underlying physical CPU supports more. Two common approaches:
- **Host passthrough** (often literally called `host`): the guest sees the exact flags of the real CPU. Maximizes performance; the trade-off is the VM becomes less portable to different hardware (e.g. for live migration between hosts with different CPUs).
- **Explicit microarchitecture level** (e.g. `x86-64-v3`): guarantees a defined feature set that's portable across any host CPU supporting that level, without pinning to exact silicon. Good middle ground if the VM might move between different physical machines.
- Always verify what the guest actually sees rather than assuming — check on Linux with:
  ```bash
  cat /proc/cpuinfo | grep -o 'avx[0-9]*\|avx512[a-z]*' | sort -u
  ```

**NUMA (Non-Uniform Memory Access)**
Relevant only on **multi-socket** systems, where each physical CPU socket has its own directly-attached RAM. A CPU accessing "its own" socket's RAM is faster than reaching across to another socket's RAM. On single-socket machines (most desktops, laptops, and many small servers), NUMA is not a factor and related flags can be ignored.

**Memory bandwidth vs. compute-bound**
CPU inference of LLMs is typically **memory-bandwidth-bound** for token generation — the bottleneck is how fast weights can be streamed from RAM into CPU cache, not how many FLOPs the CPU can theoretically do. This is why RAM speed/channels matters as much as or more than raw core count, and why quantization (below) helps so much: smaller weights = less data to move per token.

**Memory-mapped file loading (`mmap`) and network/NAS storage**
Many inference tools, including llama.cpp by default, load model files using `mmap` rather than reading the whole file into RAM upfront. With `mmap`, the file is "mapped" into the process's address space, and the operating system only actually reads a given chunk (page) from disk **the first time it's touched** — a lazy, on-demand loading strategy. This is normally a good thing: it makes startup faster and lets the OS manage caching efficiently for files on local, fast storage.
- **Theoretical concern with network storage (NAS/NFS/SMB):** if the model file lives on a network share, on-demand page loads become network round-trips instead of local reads, which could bottleneck a workload that touches the file rapidly.
- **Tested and found NOT to be the dominant factor in practice (see experiment log, 2026-09-01):** moving a model from NAS to local disk (with `mmap` disabled either way) produced only a marginal difference in a real test — the actual bottleneck turned out to be RAM pressure/swapping (see KV cache entry below), not network I/O. Worth being aware of as a *possible* factor, but don't assume it's the cause of slow real-world performance without also ruling out memory pressure first.
- **Disabling mmap** (commonly a `--no-mmap`-style flag) forces a full upfront read into RAM instead of on-demand paging — useful as a diagnostic step to isolate whether an issue is mmap-related, and also means the "loading" phase takes the full read time upfront rather than being spread out lazily during inference.

**Context length in a filename (e.g. "4k" / "128k" in `Phi-3-mini-4k-instruct`)**
Some model families release multiple context-window variants of the same underlying model side by side, with the max context size spelled out directly in the filename (using the same "K" shorthand as the "Scale of common context sizes" table above — `4k` = 4,096 tokens, `128k` = 131,072 tokens). This differs from most other families, where context length is a fixed spec of the one released model rather than a choice between named variants:
- The different context-length versions are typically the same base training run, but the longer-context variant is further adapted with a technique for extending reliable attention across much longer sequences (e.g. modified positional-encoding/RoPE scaling), rather than just declaring a bigger number.
- **The trade-off:** a shorter native context (e.g. `4k`) is generally slightly more efficient/reliable within its intended range, while a longer native context (`128k`) trades some of that for the ability to handle much larger documents — pick the variant matching your actual expected use case rather than always grabbing the largest, especially on RAM-constrained hardware where a needlessly large native context can compound the KV-cache sizing issue described above.
- Note: picking a `4k`-native model still lets you set `-c` lower than 4096 if you want (see KV cache entry above) — the filename number is that variant's *maximum* trained context, not a forced setting.

**Microsoft's size-tier naming ("mini" / "small" / "medium" in Phi filenames)**
Microsoft's Phi family uses relative size-tier names (mini, small, medium) rather than putting a parameter count directly in the model name the way "3B"/"7B" do elsewhere. These tiers aren't a standardized cross-family unit — "mini" specifically refers to the ~3.8B parameter version of Phi-3 (the same model tracked elsewhere in this project as "Phi-3.5 Mini 3.8B"). When comparing across families, translate a Microsoft tier name to its actual parameter count rather than assuming "mini" means the same absolute size as another family's "small"-labeled model.

**Date stamps in a model name (e.g. "0528" in `DeepSeek-R1-0528-Qwen3-8B-GGUF`)**
Some model releases embed a **release date** directly in the name — commonly `MMDD` (here, `0528` = May 28) — to distinguish an updated checkpoint from an earlier release of the "same" named model, without inventing a new version number (R1.1, R2, etc.).
- **Why it exists:** a model creator can quietly ship a meaningfully improved checkpoint under the same base name (e.g. DeepSeek released an updated R1 checkpoint with better reasoning/less hallucination than their original R1 release) — the date stamp is how downstream repos disambiguate which underlying checkpoint they're built from.
- **Practical implication:** two repos sharing the same base model name but different date stamps are **not interchangeable** and can have real quality/behavior differences — always check which dated version a benchmark, recommendation, or download link actually refers to before assuming "R1" alone is specific enough.
- **Combined with Distill naming:** `DeepSeek-R1-0528-Qwen3-8B` follows the same teacher→student pattern as the "Distill" entry above (teacher named first, student base named last), just with the word "Distill" itself dropped from the name and the teacher's specific dated checkpoint (the May 28 R1 update, not the original R1) called out instead — Qwen3-8B is the student base, DeepSeek-R1-0528 is the specific teacher checkpoint it was distilled from.

**Context window — what it is**
The context window is the maximum number of **tokens** a model can "see"/attend to in a single inference pass. Critically, this is a *shared* budget across everything currently "in play": the system prompt, prior conversation history, the current prompt, and the tokens being generated as output all count against the same limit together — it is not "how long can my question be," it's closer to "the model's total working memory for this exchange." Internally, the transformer's attention mechanism computes relationships between every token and every other token currently within the window; if a conversation grows beyond the configured context size, the oldest tokens get dropped/truncated to make room, and the model effectively "forgets" the earlier parts.

**Token-to-word rule of thumb**
Roughly **1 token ≈ 0.75 English words** for typical prose (equivalently, ~1.3 tokens per word). Useful for translating a context-size number into a rough sense of how much text it represents.

**Scale of common context sizes**
| Context size | Rough word equivalent | Typical use case |
|---|---|---|
| 2,048 (2K) | ~1,500 words | Older-generation default; a few paragraphs of chat |
| 4,096 (4K) | ~3,000 words | A normal short chat session, short documents |
| 8,192 (8K) | ~6,000 words | Longer conversations, medium-length documents |
| 32,768 (32K) | ~24,000 words | A book chapter, a sizable code file, longer chat history |
| 131,072 (128K) | ~98,000 words | Multiple long documents, whole books, large codebases |
| 1,000,000+ (1M) | ~750,000 words | Frontier-scale, entire large codebases/books at once |

**KV cache and context size — a hidden RAM cost**
Beyond the model weights themselves, LLM inference engines allocate a **KV (key-value) cache** — a memory buffer that stores intermediate attention data so each new token doesn't require recomputing relationships with all previous tokens from scratch. Its size scales with the **configured maximum context size**, not with the length of the actual conversation being had — the memory is reserved upfront for the *ceiling*, whether or not it's ever filled.
- **The trap:** if context size isn't explicitly set, many tools default to the model's maximum supported/trained context (which can be very large — some modern models support 128K+ tokens). This can pre-allocate a large KV cache **upfront**, even for a two-sentence exchange, consuming far more RAM than the model file's own size would suggest. This happens because model publishers advertise a high native max context as a genuine capability, while the inference tool has no way to know in advance whether the next request is one short question or an entire pasted document — so many tools default toward the capability ceiling rather than typical-use efficiency.
- **Symptom:** RAM usage (resident set size) far exceeding the model file's size on disk, RAM pressure/swapping on memory-constrained machines, and confusingly slow performance that looks like a CPU or I/O problem but is actually a memory-pressure problem (see "diagnostic tip" below).
- **Fix:** explicitly set a context size appropriate to the actual use case (e.g. a flag like `-c 4096` for a single short exchange) rather than leaving it at a model's maximum default, especially on RAM-constrained hardware.
- **The tradeoff:** a larger configured context means more RAM/KV-cache overhead reserved upfront (and somewhat more prompt-processing compute as the window fills), while a smaller context uses far less RAM but will truncate/"forget" anything beyond that size — a real constraint for long multi-turn conversations or large pasted documents. Size `-c` to match the actual expected use case rather than defaulting to either extreme.
- **Diagnostic tip:** if real-world memory usage is much higher than expected, check RAM usage and swap activity (e.g. via `btop`, `htop`, or `free -h`) during the run before assuming the bottleneck is CPU or disk/network I/O — swapping can produce symptoms (high "major page fault" counts, unexpectedly low CPU utilization) that superficially resemble an I/O bottleneck elsewhere in the pipeline. Confirmed in practice on this project (see experiment log, 2026-09-01): an unset context size caused KV-cache-driven swap thrashing that looked at first like a NAS/network storage bottleneck, until directly tested and ruled out.

**What happens if you deliberately configure more memory usage (e.g. context size) than physical RAM allows**
The OS doesn't refuse the allocation outright — it starts moving less-urgently-needed pages of memory out to **swap** (disk-backed virtual memory) to free up physical RAM, then reads them back in when needed again. This "works" in the sense that the process doesn't necessarily crash, but performance degrades severely, because of a massive speed mismatch:
- RAM access: nanoseconds.
- Disk access (even fast NVMe): tens of microseconds — roughly 100-1000x slower than RAM, and the random-access pattern of memory paging is close to a worst case for a disk. Slower/network-backed storage makes this even worse.
- LLM inference is a particularly bad workload to run under heavy swapping: token generation is already memory-bandwidth-bound under *normal* conditions (the CPU frequently waits on RAM), so silently redirecting that RAM traffic through swap/disk replaces an already-sensitive bottleneck with a far slower one — and because inference repeatedly touches large portions of the model's weights, this pattern tends to cause repeated "thrashing" (the same data paged in and out over and over) rather than a one-time cost.
- **Observable symptoms:** generation speed collapsing to a small fraction of normal (potentially minutes per token in severe cases), CPU utilization looking paradoxically *low* (the CPU is idle, waiting on disk), a large jump in major page faults, and — if swap itself is undersized or exhausted — the OS's **OOM (out-of-memory) killer** may forcibly terminate the process rather than let it run slowly to completion.
- **Practical takeaway:** swap is a safety net for rare/occasional overflow, not a substitute for having enough RAM for the actual working set. If a model or context size doesn't fit in available RAM, the standard fixes are: use a smaller or more aggressively quantized model, reduce context size, or add more RAM — not rely on swap as normal operating mode.

**Physical cores vs. logical threads (Hyperthreading/SMT)**
A CPU with Hyperthreading/SMT reports more "logical" threads than physical cores (e.g. 6 physical cores → 12 logical threads). For compute-heavy matrix math, performance scales mainly with *physical* cores — setting a thread count equal to logical thread count usually does **not** give a proportional speedup, and can sometimes be slower due to contention. Good starting point: set thread count to the physical core count, then benchmark ±1-2 to find the actual optimum for your workload.

**Shared CPU/GPU power budget on laptops (GPU inference can get *slower* under a "performance" power profile)**
On many laptops — especially Nvidia Max-Q / Dynamic-Boost-style designs — the CPU and discrete GPU share a combined power and/or thermal budget rather than each having a fully independent ceiling. The OS-level power profile (e.g. `powerprofilesctl`'s `performance`/`balanced`/`power-saver` on Linux, or Windows power plans) primarily governs **CPU** clocks/governor behavior, not GPU clocks directly.
- **The counterintuitive effect:** for a GPU-bound workload (e.g. LLM inference with most/all layers offloaded to GPU, `-ngl 999`), the CPU is mostly idle. Forcing the CPU governor to `performance` can still pull more of the laptop's *shared* power/thermal envelope toward the CPU (higher idle/base clocks, more aggressive boosting on any CPU activity), leaving *less* headroom for the GPU to boost — even though the CPU isn't the bottleneck for that workload. A `power-saver` profile keeps CPU draw low, which can free up more of the shared budget for the GPU to clock higher, paradoxically increasing GPU-bound throughput.
- **This is real and machine-dependent, not a fixed rule:** whether — and how strongly — this happens depends on the specific laptop's power-delivery/thermal design (how tightly CPU and GPU budgets are coupled), the GPU's boost algorithm (Nvidia Dynamic Boost 2.0 explicitly shares budget between CPU/GPU on supported laptops), and how the OS power-profile daemon maps its profiles to actual CPU governor/clock behavior. Don't assume this transfers to every laptop, or to desktop/workstation GPUs with independent power delivery.
- **How to confirm rather than assume:** capture actual GPU power draw/limit and clock speed (e.g. `nvidia-smi -q -d POWER,CLOCK`, or `nvidia-smi --query-gpu=power.draw,clocks.sm,clocks.mem --format=csv -l 1`) during both a `performance`-profile run and a `power-saver`-profile run of the same GPU-bound benchmark.
- **Confirmed in practice, not just theoretical:** on one tested laptop (Gigabyte GAMING A16, RTX 5060 Laptop/Max-Q), `nvidia-smi -q -d POWER` showed the GPU's own *power limit* set inversely to the OS profile name — `performance` capped the GPU to 45.85W (below its 50W default), while `power-saver` raised it to 60.86W (above default), with `balanced` in between at 53.77W. This directly explained a ~2x tg128 throughput difference favoring `power-saver` on a GPU-bound (`-ngl 999`) llama.cpp benchmark — the OS "performance" profile was evidently tuned around sustained CPU performance, which on this laptop's shared power design came directly at the GPU's expense. See the laptop-specific experiment log for full numbers.
- **Practical takeaway:** on a laptop, "performance" power profile is not a safe default assumption for best GPU inference speed — benchmark actual power profiles against each other for GPU-bound workloads specifically (and check `nvidia-smi` power limits directly, don't just infer from throughput), the same way thread counts are benchmarked rather than assumed for CPU-bound workloads (see thread-count sweep methodology elsewhere in this glossary/log). Don't assume the same numeric power-limit values or profile-to-GPU-budget mapping transfer to a different laptop model — the *pattern* (OS "performance" profile potentially throttling GPU headroom) generalizes, but always re-measure on the specific machine.

**CPU isolation between VMs sharing one host**
When a hypervisor host runs multiple VMs, and one VM (e.g. a CPU-intensive LLM workload) is allocated all or most of the physical cores, it can starve other VMs of CPU time whenever it's under load — even if those other VMs have their own vCPU allocations on paper, since vCPU counts don't guarantee physical core availability if everything is contending for the same underlying cores. Common mitigations, roughly in order of how "hard" the guarantee is:
- **CPU pinning / `cpuset`** — dedicate specific physical cores exclusively to specific VMs (e.g. VM A gets cores 0-3, VM B gets cores 4-5). Strongest isolation; other VMs literally cannot touch the pinned VM's cores and vice versa.
- **CPU limit / throttling** — cap a VM's *total* CPU time (e.g. "no more than the equivalent of 4 cores' worth"), without dedicating specific cores. Softer guarantee: other VMs get more breathing room without hard-partitioning the hardware.
- **Reducing vCPU allocation** — the simplest option: just give the heavy VM fewer vCPUs than the host's total physical cores, structurally guaranteeing some cores are never claimed by it.
- Combined with benchmarking (measuring how much performance is actually lost by capping threads/cores below the physical maximum) this lets you make an informed trade-off between one workload's raw speed and overall host stability.

**Partial GPU offload when a model doesn't fit in VRAM (`-ngl` hybrid split)**
`-ngl`/`--n-gpu-layers` controls how many of a model's sequential transformer layers are placed on GPU vs. left on CPU/system RAM:
- `-ngl 999` (or any value ≥ total layer count) → full offload, all layers on GPU.
- `-ngl 0` → no offload, behaves identically to a CPU-only setup (same as a GPU-less machine).
- A value in between → **hybrid split**: that many layers run on GPU/VRAM, the remainder run on CPU/system RAM, with data transferred between the two each forward pass.
- **Performance is not a smooth blend between full-GPU and full-CPU speed.** Hybrid mode is generally bottlenecked toward the CPU-side layers' speed plus added PCIe transfer overhead, since compute has to hop back and forth every pass. Offloading a large majority of layers (~60-70%+) can still feel meaningfully faster than pure CPU; offloading only a small fraction often gives little benefit over `-ngl 0`, and can sometimes be *slower* than CPU-only due to the added transfer overhead.
- **KV cache competes for the same VRAM budget as offloaded layers** (see KV cache entry above, same concept, VRAM instead of system RAM) — a model that just barely fits fully offloaded may leave little/no VRAM headroom for context size. **By default the KV cache follows the offloaded layers to VRAM** and does not automatically spill into system RAM if it doesn't fit — an oversized `-c` on top of a near-full VRAM offload fails outright at load time (allocation error), the same "no silent overflow" behavior as VRAM in general (see below), not a graceful degradation.
- **`-nkvo`/`--no-kv-offload` is the explicit escape hatch:** forces the KV cache to live in system RAM even while model layers stay offloaded to GPU, freeing VRAM for more layers or larger context. Trade-off: every attention step now reaches across PCIe to a RAM-resident cache instead of a fast on-GPU read, so it buys VRAM headroom at some generation-speed cost — not a free move, and not something that happens automatically without passing the flag.
  - **Empirically, the speed penalty scales with how much KV cache data actually exists** — at a small context (e.g. `llama-bench`'s default 512-token prompt / 128-token generation), the cache is small and the PCIe overhead is modest (~6-9% slower measured on one 8B model on an RTX 5060 Laptop GPU, `pp512` 1530 vs 1670 t/s, `tg128` 34.41 vs 37.99 t/s comparing `-nkvo` on vs off). At much larger context sizes / longer generations, expect the gap to widen, since more cache data has to move per token.
  - **✅ Confirmed via benchmark numbers — gradual VRAM-crowding degradation, not a binary fallback.** Measured `tg128` throughput on one machine (RTX 5060 Laptop, 7705 MiB VRAM, Llama 3.1 8B Q4_K_M, `-ngl 999`) across a range of `-c` context sizes, with and without `-nkvo`:

    | Context (`-c`) | Without `-nkvo` (t/s) | With `-nkvo` (t/s) |
    |---|---|---|
    | ~11,264 | 37.5 | 33.2 |
    | 23,552 | 22.2 | 27.7 |
    | 29,696 | 17.6 | 27.0 |
    | 41,984 | 14.1 | 28.1 |
    | 60,416 | 11.3 | 28.2 |
    | 72,704 | 10.5 | 27.6 |

    **Without `-nkvo`, throughput degrades continuously as context grows** (37.5 → 10.5 t/s, ~3.6x collapse across the range tested) — confirming the earlier observed CPU-speed slowdown is a *sliding scale* driven by increasing VRAM pressure from the growing KV cache, not a one-time threshold/fallback event. **With `-nkvo`, throughput stays essentially flat** (~27-33 t/s) regardless of context size, since the cache never competes with weights for VRAM — only a fairly constant PCIe-transfer cost is paid per token.

    **Practical takeaway — there's a crossover point, so `-nkvo` is not universally better or worse:** at small context (~11K tokens in this test), *not* using `-nkvo` was faster (37.5 vs 33.2 t/s) — the PCIe tax outweighs any VRAM pressure when the cache is small. Somewhere between ~11K and ~24K tokens the lines cross, and past that point `-nkvo` wins by a growing margin (nearly 3x faster at 72,704: 27.6 vs 10.5 t/s). **Rule of thumb for this hardware: leave `-nkvo` off for short-context use, turn it on once expected context climbs into the tens of thousands of tokens** — the exact crossover point will vary by GPU/VRAM size and model, so treat ~15-20K tokens as a starting point to verify per-machine rather than a universal constant.
  - **The real point of `-nkvo` is fitting, not raw speed on a model that already fits.** If a model already fits fully offloaded with its default-size KV cache and VRAM to spare, `-nkvo` just adds overhead with no benefit — it's a tool for the specific case where a model/context combination would otherwise fail to fit in VRAM, not a general performance toggle to reach for by default. (See correction above: at large context, this framing is incomplete — `-nkvo` can also rescue GPU compute speed itself, not just prevent an outright failure.)
- **Failure mode differs from system RAM overflow:** system RAM overflow degrades via swap (slow but often keeps running — see swap entry above). VRAM overflow generally fails outright with an out-of-memory/allocation error at load time rather than silently spilling — `-ngl` is how the user explicitly defines the CPU/GPU split, rather than the driver deciding automatically.
- **Practical approach:** start with a high `-ngl` value and step it down if the load fails with an OOM/allocation error, or use a frontend/tool that auto-calculates a safe value from detected VRAM. Verify empirically per-model via a benchmark sweep (same methodology as thread-count sweeps — see benchmarking practices) rather than assuming a fraction from parameter count alone, since actual layer count/size varies by model.

---

## Model / Quantization Concepts

**Quantization**
Compressing model weights from their native precision (typically 16-bit or 32-bit floating point) down to lower-precision representations (8-bit, 4-bit, etc.). Benefits:
- Smaller file size / RAM footprint
- Less data to move per inference step → faster on memory-bandwidth-bound hardware (i.e., most CPUs)
Trade-off: some loss of output quality/accuracy, more pronounced at very low bit-widths.

**GGUF quant naming scheme** (e.g. `Q4_K_M`, `Q4_0`, `Q3_K_S`)
- **Leading number (Q3/Q4/Q5/Q6/Q8)**: approximate bits used per weight. Lower number = smaller and faster, but lower quality. Q8 is close to full-precision quality; Q3 and below show noticeably more degradation.
- **`_K` suffix**: indicates "k-quants," a method that allocates precision non-uniformly — more bits to weights that matter more for output quality, fewer to weights that matter less. Generally better quality than older non-K methods (like plain `Q4_0`) at the same nominal bit-width.
- **`_S` / `_M` / `_L` suffix**: Small / Medium / Large variants within a K-quant level — small trade of size for accuracy.
- **Rule of thumb starting point**: `Q4_K_M` is the community-standard default balance of size, speed, and quality for most use cases. Start there before tuning up or down.

**bitsandbytes / "bnb-4bit" (e.g. `gemma-3-270m-unsloth-bnb-4bit`) — NOT a GGUF/llama.cpp format**
`bnb-4bit` refers to **bitsandbytes**, a quantization library used in the Hugging Face `transformers`/PyTorch ecosystem — a completely separate quantization format from GGUF's own schemes (`Q4_K_M`, etc.). Important distinction when browsing Hugging Face for models:
- **bnb-4bit models are for running/fine-tuning directly in Python** via `transformers` + `bitsandbytes`, normally on a GPU — not for llama.cpp. `llama-cli`/`llama-server` only load the GGUF file format, so a bnb-4bit repo is the wrong artifact type for a llama.cpp-based setup, even though it's the "same" underlying model.
- When looking for a model to run in llama.cpp, look for a separate `-GGUF` repo of the same model (often published by the same or a different uploader) rather than a bnb-4bit one.
- **"unsloth" in a filename** (e.g. `gemma-3-270m-unsloth-bnb-4bit`) is simply the name of the group/tool that produced that specific release — Unsloth is a well-known fine-tuning library/community known for memory-efficient training and quantization pipelines. It's an uploader/toolchain credit, the same kind of signal as seeing "bartowski" in a GGUF filename, not a description of the model's architecture or behavior. Unsloth does also publish GGUF versions of models in many cases — the suffix on the specific repo (`-bnb-4bit` vs. `-GGUF`) is what determines which ecosystem it targets, not the "unsloth" name itself.

**"E" prefix / MatFormer effective-parameter naming (e.g. "E2B", "E4B" in Gemma 3n)**
Google's Gemma 3n family uses a **MatFormer (Matryoshka Transformer)** architecture, where a larger model is trained with a smaller, fully-functional sub-model nested inside it — similar in spirit to Russian nesting dolls. The **"E" prefix stands for "Effective"** parameters, not raw/total parameters: an "E2B" model behaves like a 2B model in memory/compute footprint, but its actual raw parameter count on disk is larger (e.g. Gemma 3n E2B's raw count is ~5-6B, E4B's is ~8B) — techniques like Per-Layer Embeddings and selective parameter activation let the larger set of weights run with a much smaller effective footprint. When budgeting RAM for one of these models, the *effective* number is the more useful real-world sizing guide, but the raw file size on disk will still reflect the larger true parameter count.

**Unsloth Dynamic quantization ("UD" in a filename, e.g. `-UD-Q4_K_XL`)**
Unsloth's own custom quantization method, distinct from vanilla GGUF k-quants. Rather than quantizing every layer to the same uniform bit-width, it selectively keeps more sensitive layers/tensors at higher precision and pushes less-sensitive ones lower, aiming to preserve more quality than a naive uniform quant at the same nominal bit-width. Conceptually similar in goal to GGUF's own `_K` "k-quants" (non-uniform precision allocation, see quant naming scheme above), but it's a separate, Unsloth-branded method/pipeline, not the same implementation. Still typically shipped as a `.gguf` file and loadable in llama.cpp like any other GGUF quant, unlike bnb-4bit or MLX (below).

**MLX — Apple's ML framework, NOT a GGUF/llama.cpp format**
MLX is Apple's own machine learning framework, built specifically for Apple Silicon (M-series Mac) hardware. A model released in MLX format is a **separate file format/runtime from GGUF** and will not load in llama.cpp (`llama-cli`/`llama-server`) — same category of mismatch as `bnb-4bit` (above), just targeting Apple Silicon instead of Nvidia/PyTorch GPU setups. If browsing Hugging Face for a model to run in llama.cpp, an MLX-tagged repo is the wrong artifact type; look for the corresponding `-GGUF` repo of the same model instead.

**Reasoning model / "thinking" models**
A category of model specifically trained to generate an extended internal chain-of-thought — working through a problem step-by-step in visible text (often wrapped in tags like `<think>...</think>`), considering approaches and sometimes backtracking — before producing a final answer, rather than jumping straight to a response.
- **Separate axis from instruction-tuning:** "Instruct"/`-it` means "trained to follow instructions/hold a conversation." Reasoning training is a different, additional axis usually layered on top of an instruct-tuned base, not a replacement for it.
- **How it's usually trained:** via reinforcement learning and/or distillation from a stronger reasoning "teacher" model (see "Distill" entry above) — DeepSeek-R1 is a well-known example of a strong reasoning teacher model, and "R1-Distill" variants (e.g. DeepSeek-R1-Distill-Qwen) are smaller student models trained to imitate that reasoning behavior.
- **"Test-time compute":** the practical trade being made — the model spends extra tokens/time at inference "thinking" in exchange for better accuracy on hard problems, rather than relying only on capability baked in during training. This means a reasoning model's *effective* response time/token count for a given question can be far higher than a similarly-sized non-reasoning model, even with identical raw tokens/sec generation speed — worth factoring into real-world latency expectations, not just throughput benchmarks.
- **Sharpens deduction, not knowledge breadth:** reasoning training tends to help most on tasks requiring step-by-step logical deduction from given information (math, logic puzzles, structured problem-solving), but doesn't reliably improve — and can even worsen — tasks requiring broad factual recall, since the model can "confidently reason" its way to a fluent but fabricated answer when it lacks the underlying facts. (Reflected directly in this project's own testing — see `benchmark-results-log.md` Run #7: DeepSeek-R1-Distill-Qwen scored well on logic/math but catastrophically on Linux sysadmin recall, fabricating plausible-sounding but nonexistent commands.)

**Parameter count (e.g. "7B", "3B")**
The number of weights in the model (in billions) — the individual learned numerical values (in the matrices/tensors) that get adjusted during training and then used in the matrix-multiplication math that turns input tokens into output tokens. Every parameter has to be stored in memory and computed against for each token generated, which is why parameter count directly drives both RAM footprint and compute cost — bigger models are proportionally slower and more memory-hungry, which matters most on constrained hardware.
- **Correlates with capability, but isn't the whole story:** training data quality/quantity and architecture/fine-tuning choices matter enormously too — a well-trained smaller model can match or beat a larger one on specific tasks (e.g. a model trained on dense, textbook-style synthetic data punching above its raw parameter count on reasoning benchmarks).
- **Roughly linear cost scaling in practice (CPU, dense models):** because CPU inference is typically memory-bandwidth-bound (see above), a model with ~2.5x the parameters of another tends to take ~2.5x as long per token — the relationship is close to directly proportional, not some steeper or more complex curve.
- See "Dense vs. Mixture of Experts (MoE) Architecture" below for a case where a model's *advertised* parameter count doesn't map simply to its RAM cost.

**Quantization-Aware Training (QAT) vs. Post-Training Quantization (PTQ)**
Two different approaches to producing a quantized model, often signaled by a `-qat-` suffix in a GGUF release name (e.g. `gemma-3-270m-it-qat-GGUF`):
- **Post-training quantization (PTQ)** — the normal/default path: the model is trained fully at high precision (16/32-bit), then quantized down afterward as a separate step (this is what community GGUF conversions, e.g. bartowski's uploads, do). The model's weights were never adjusted with quantization in mind.
- **Quantization-aware training (QAT)** — quantization is simulated *during* training itself (fake low-precision rounding in the forward pass), so the model's weights adapt to tolerate that precision loss as part of learning, rather than having it applied afterward.
- **Practical effect:** a QAT model quantized to a given bit-width typically retains noticeably more quality than a PTQ model at that same bit-width, since the weights were shaped to survive quantization from the start. The trade-off is that QAT must be done by the original model creator as part of their own training pipeline — it can't be applied after the fact the way ordinary community GGUF conversions are.

**Google's "-it" naming suffix (e.g. `gemma-3-270m-it`)**
Google's Gemma family uses **`-it`** ("instruction-tuned") where other families use "-Instruct" (Llama) or "Instruct" as a separate word (Qwen, Phi) — same underlying meaning as the Base vs. Instruct model entry below, just a family-specific naming convention. A "-qat-" and "-it" suffix are often combined in the same release name (e.g. `-it-qat-`), and are independent flags: one says how it was quantized, the other says whether it's the instruction-following variant.

**Abliterated model**
A model that's had its built-in safety refusal behavior surgically removed directly from the weights via a one-time weight edit, rather than through prompting or additional fine-tuning. The term is a portmanteau of "ablate" + "obliterate."
- **How it works (roughly):** a model's tendency to refuse a request corresponds to an identifiable direction in its internal activation space, learned during the original safety training. By comparing internal activations on harmless vs. harmful prompts, that "refusal direction" can be located and then mathematically projected out of/zeroed out in the weight matrices — removing that specific behavior while leaving the rest of the weights and general knowledge otherwise intact. This is a cheap, fast, one-time edit compared to actual fine-tuning, which is part of why the technique spread quickly through the community.
- **Side effects:** because it's a fairly blunt edit rather than a perfectly isolated feature removal in practice, abliteration can sometimes cause collateral quality degradation — small drops in coherence or reasoning ability — depending on how carefully the specific abliteration was done. Unlike quantization (a well-understood, predictable trade-off), abliteration quality varies significantly by uploader/method.
- **Naming/sourcing:** shows up as an `-abliterated` suffix on community-uploaded models (e.g. `Llama-3-8B-Instruct-abliterated`), almost always from independent uploaders rather than the original model creator.
- **Distinct from related concepts in this glossary:** not quantization (doesn't touch precision/bit-width), not fine-tuning (no new training data involved), and not the same as a plain base model — a base model was never safety-tuned to begin with, while an abliterated model *was* safety-tuned (as an Instruct/it model) and then specifically had that behavior stripped back out.

**Base model vs. "Instruct" model**
Most model families release (at least) two variants of the same underlying weights:
- **Base model**: trained only to predict the next word across large amounts of text. No inherent concept of "having a conversation" — may continue a question with more questions, ramble, or complete text like it's finishing an essay rather than answering directly.
- **Instruct model** (sometimes "Chat"): the base model further fine-tuned on conversational/instruction-following data (Q&A pairs, chat transcripts, system-prompt examples) so it reliably behaves like an assistant — follows instructions, answers directly, respects turn-based chat structure.
For any interactive/chat use case, always use the Instruct variant. Base models are mainly useful for research or as a starting point for custom fine-tuning.

**"Distill" in a model name (e.g. "DeepSeek-R1-Distill-Qwen")**
Refers to **knowledge distillation**: a smaller "student" model is trained to mimic the behavior/outputs of a larger, more capable "teacher" model, rather than (or in addition to) being trained from scratch on raw data alone. The goal is transferring as much of the teacher's capability as possible into a smaller, cheaper-to-run package. A distilled model often inherits a specific strength from its teacher (e.g. chain-of-thought reasoning style) more strongly than it inherits general/broad knowledge, since distillation training data is usually focused on demonstrating that specific behavior rather than covering the full breadth of a from-scratch pretraining run.
- **Naming convention — who's student vs. teacher:** the base model being distilled *into* (the student) is named last; the source of the distilled behavior (the teacher) comes first. In "DeepSeek-R1-Distill-Qwen," **Qwen** (Alibaba's model family) is the student base, and **DeepSeek-R1** (a large reasoning model) is the teacher whose chain-of-thought reasoning behavior was distilled into it.

**Embedding model**
A model whose job is to convert text (a word, sentence, or document) into a fixed-length vector of numbers ("an embedding"), positioned in vector space such that semantically similar text ends up close together. Unlike a chat/instruct model, it does not generate text — its only output is the vector itself.
- **Why it matters for local setups:** embedding models are the engine behind the "retrieval" step in RAG (see "RAG / context stuffing" below) — documents are embedded once and stored in a vector index, the user's question is embedded the same way, and the closest-matching document vectors are pulled into context for that query.
- **Typically small and fast** relative to chat models, since the output is a short number array rather than generated text — this makes them cheap to run even on constrained CPU-only hardware, and a natural pairing with a larger local chat model for a full local RAG pipeline.

**Prompt processing vs. token generation**
Two distinct phases of inference with different performance characteristics:
- **Prompt processing** (reading/encoding your input): more parallelizable, benefits more from larger batch sizes.
- **Token generation** (producing the reply, one token at a time): inherently sequential, generally memory-bandwidth-bound rather than batch-size-bound.
Benchmarks and tuning should be considered separately for each phase.

**What "pp512" and "tg128" mean in `llama-bench` output**
`llama-bench`'s test names encode the phase and how many tokens were measured:
- **`pp512`** = **p**rompt **p**rocessing test using a 512-token synthetic prompt. Measures how fast the model can "read"/encode input — the number after `pp` is the prompt length in tokens, and is configurable via the `-p` flag.
- **`tg128`** = **t**oken **g**eneration test producing 128 new tokens. Measures how fast the model can "write" output — the number after `tg` is how many tokens were generated, configurable via the `-n` flag.
- Both are reported in **tokens per second (t/s)** — higher is faster/better for both.

**Interpreting the token/sec scale (rough feel, applies broadly, not just to one model)**
| tok/s (generation) | Rough feel |
|---|---|
| <2 | Frustratingly slow — long waits per response |
| ~2-3 | Roughly human reading/typing pace — usable but you're waiting on it |
| ~5-10 | Reasonably fluid, comparable to a fast typist |
| 15+ | Feels close to instant / typical web chatbot speed |
Prompt processing speed matters most for how long you wait *before* a response starts (especially with long inputs); generation speed matters most for how fast the response *streams in* once it starts.

**Why prompt processing and token generation scale differently with threads/cores**
Prompt processing is **embarrassingly parallel** — many tokens' worth of math can be computed simultaneously, so it tends to scale close to linearly with added CPU threads/cores, well past the point token generation stops improving. Token generation is **inherently sequential** — each new token depends on the one before it — and is generally memory-bandwidth-bound (see above) rather than compute-bound, so it hits diminishing returns from added threads much sooner, once available threads exceed what's needed to saturate the memory pipe. This is a common and expected pattern, not a bug or misconfiguration.

**Batch size**
How many tokens are processed together in a single forward pass. Primarily affects prompt processing throughput; has a smaller/different effect on generation speed. Worth tuning experimentally per-machine rather than assuming a default is optimal.

**Dense vs. Mixture of Experts (MoE) Architecture**
- **Dense Models**: Every parameter in the network is computed for every token generated (e.g., Llama 3.2 3B, Llama 3.1 8B). Compute cost scales directly with total model size.
- **MoE Models**: Replaces large dense layers with multiple specialized sub-networks ("experts") and a "router." For each token, the router selects only 1 or 2 experts to process the data.
- **Total vs. Active Parameters**: An MoE model might have 17B *total* parameters, but only 3B *active* parameters per token. While token generation speed can feel as fast as a 3B model, **100% of the weights must still reside in system memory**. MoE reduces compute per token, but does not reduce RAM requirements.

**Multimodal input (images / audio) in llama.cpp — `mtmd` / `libmtmd`**
llama.cpp can accept images (and, experimentally, audio) as part of the input, but this is not automatic for any arbitrary model — it requires two things together:
- A **vision/multimodal-capable model** (e.g. Gemma 3, LLaVA, MiniCPM-V, InternVL, Qwen2-VL). A plain text-only model (e.g. Llama 3.2 3B Instruct, Llama 3.1 8B Instruct) has no image understanding no matter what flags are passed.
- A matching **multimodal projector file (`mmproj-*.gguf`)**, separate from the main model GGUF. The projector encodes the image into embeddings that get fed alongside the text tokens into the language model. This file is architecture-specific — a projector from one model family cannot be paired with a different model's weights (mismatched embedding dimensions will fail to load).
- Tooling: `llama-mtmd-cli` and `llama-server` both support this via `-hf <repo>` (auto-fetches a bundled model+projector pair) or `-m model.gguf --mmproj file.gguf` (explicit local files).
- By default the projector offloads to GPU if present (`--no-mmproj-offload` to force CPU). To disable multimodal loading when using `-hf`, pass `--no-mmproj`.
- Some multimodal models expect a larger context window than a typical text exchange, since image tokens consume part of the same context budget (see context window entry above).
- Note: the standard llama.cpp build compiles the `mtmd` tooling by default even for text-only use cases — its presence in a build doesn't mean it's being used.

**Non-text file input (Markdown, PDFs, other documents)**
llama.cpp has no built-in file-ingestion pipeline beyond plain text tokens (and image/audio via `mtmd`, above) — anything else must be converted to text before it reaches the model.
- **Markdown, plain text, code files, etc.**: trivial — the raw file contents are just text. `llama-cli -f file.md` reads a file's contents directly as the prompt. Markdown syntax (`#`, `-`, backticks, etc.) is simply seen as ordinary characters, not rendered/interpreted.
- **PDFs**: not natively parsed. Two approaches:
  - **Extract text first** with an external tool (`pdftotext`, `pypdf`, etc.), then feed the extracted text in like any other text file. Cheapest option; works well for text-based PDFs but loses layout, tables, and embedded images.
  - **Treat pages as images**, using a multimodal model with OCR-capable vision (some `mtmd`-supported models are explicitly trained for document/OCR tasks) — render each page to an image and run it through the mmproj pipeline (see multimodal entry above). Preserves layout and handles scanned/non-text PDFs, but adds the full multimodal memory/compute overhead on top of the base model.
- On RAM-constrained CPU-only hardware, text extraction (the first PDF approach) is generally the far cheaper path versus adding a multimodal OCR model into the pipeline.

**Office/document formats that don't reduce cleanly to text**
Most office formats (`.pptx`, `.docx`, `.xlsx`, `.csv`) extract to text easily via mature libraries (e.g. `python-pptx`, `libreoffice --headless --convert-to txt`) — the underlying files are structured XML, so pulling out titles/body text/notes/tables is straightforward, even though visual layout is lost. Genuinely hard cases are:
- Slides/pages that are mostly **diagrams, charts, or screenshots** with little native text — extraction only recovers titles/captions, missing the content that actually matters.
- **Scanned documents / image-only PDFs** — no text layer exists to extract at all.
- Content where **layout itself carries meaning** (tables, flowcharts, arrows/connections between elements).

Options for these cases, roughly cheapest to most expensive:
1. **Accept the lossy version** — extract whatever text does exist (titles, notes, captions) and skip the visual content, if it isn't essential to the task.
2. **OCR as a separate preprocessing step** (e.g. `tesseract`) — produces rough text fed into a normal text model. Cheap and avoids the RAM/compute cost of a vision model, but still loses layout/structure and can do poorly on charts/diagrams.
3. **Render to images + multimodal/OCR-capable vision model** (see multimodal entry above) — preserves layout and handles genuinely visual content, but incurs the full mmproj memory/compute overhead per page/slide.
On RAM-constrained CPU-only hardware, option 2 is generally the best balance for image-heavy documents when a full vision model isn't otherwise justified.

---

## `llama-cli` / `llama-server` Flag Reference

Common flags shared by both binaries (llama.cpp built on the standard `common` param parser), with their default values when not explicitly set. Defaults can shift between llama.cpp versions — treat this as a working reference to sanity-check against `--help` output on your actual build, not a permanent guarantee.

### Model loading & hardware

| Flag | Meaning | Default if unset |
|---|---|---|
| `-m, --model <path>` | Path to the GGUF model file | none — required |
| `--mmproj <path>` | Path to a multimodal projector file (see glossary entry above) | none |
| `-t, --threads <N>` | CPU threads for generation | Number of "performance" cores the runtime detects, varies by platform |
| `--threads-batch <N>` | CPU threads for prompt processing/batch phase specifically | Same as `-t` if unset |
| `-ngl, --n-gpu-layers <N>` | Number of model layers to offload to GPU | `0` (all layers stay on CPU) in builds with no GPU backend compiled in. **⚠️ Correction:** in builds with a GPU backend compiled in and a device detected (e.g. this project's CUDA-enabled laptop build), the effective default is NOT `0` — observed behavior shows `llama-cli`/`llama-server` auto-offloading as many layers as fit in available VRAM when `-ngl` is left unspecified, falling back to CPU/RAM for whatever doesn't fit (see laptop experiment log, Qwen3-14B test: no `-ngl` given, "most of the model" ended up in VRAM with the rest in RAM automatically). This is runtime auto-fitting logic, not a value read from the GGUF file itself — GGUF metadata does not store a recommended/preferred `-ngl` value. Always pass `-ngl` explicitly to be certain of the actual split, rather than relying on default behavior, since it clearly varies by build/backend. |
| `--no-mmap` | Disable `mmap`, force full upfront read into RAM (see glossary) | mmap enabled (off) |
| `--mlock` | Lock model pages in RAM, prevent them from being swapped out | disabled |
| `-b, --batch-size <N>` | Logical batch size for prompt processing | `2048` |
| `-ub, --ubatch-size <N>` | Physical/micro batch size (actual chunk size per forward pass) | `512` |

### GPU-specific

| Flag | Meaning | Default if unset |
|---|---|---|
| `-ngl, --n-gpu-layers <N>` | Number of model layers to offload to GPU. `0` = CPU/RAM only, a number ≥ total layer count (e.g. `999` as a safe "all layers" shorthand) = full GPU/VRAM offload, a value in between = hybrid split across VRAM and RAM | `0` (all layers stay on CPU) |
| `-nkvo, --no-kv-offload` | Keep the KV cache on CPU RAM even when layers are offloaded to GPU — isolates "weights on GPU, cache on CPU" as a distinct test case | KV cache offloaded to GPU when layers are offloaded |
| `-fa, --flash-attn` | Enable flash attention — typically a speed and VRAM-efficiency win on supported GPUs | disabled |
| `-mg, --main-gpu <N>` | Which GPU index is "main" (only matters with multiple GPUs) | `0` |
| `-sm, --split-mode <none\|layer\|row>` | How to split work across multiple GPUs | `layer` |
| `-ts, --tensor-split <a,b,...>` | Ratio to split layers across multiple GPUs | none (even split) |

### Context & generation length

| Flag | Meaning | Default if unset |
|---|---|---|
| `-c, --ctx-size <N>` | Max context size (tokens) — see KV cache glossary entry for why this matters so much on RAM-constrained hardware | `4096` in most recent builds (older builds: `0` = pulled from the model's own trained max, which can be far larger — **always check your specific build**, since this default has changed across llama.cpp versions and is the single most consequential flag for RAM usage) |
| `-n, --predict <N>` | Max tokens to generate for a single response — **hard-stops output exactly at this count regardless of whether the model was "done"** (this is what caused the mid-sentence cutoffs in this project) | `-1` in newer builds (generate until natural stop/EOS) — verify on your build, since some older defaults were a small positive number |
| `--no-context-shift` | Disable automatic trimming of old tokens to make room when context fills, instead of silently truncating | context-shift enabled (flag off) |
| `-e, --escape` | Interpret escape sequences (`\n`, etc.) in the prompt string | enabled |
| `-p, --prompt <text>` | One-shot prompt text (non-interactive single response) | none |
| `-f, --file <path>` | Read prompt from a file instead of `-p` | none |
| `-i, --interactive` | Enter interactive chat mode | off unless invoked (llama-cli only) |
| `-st, --single-turn` | Exit after one response instead of looping in interactive mode | off |
| `-sys, --system-prompt <text>` | Set a system prompt for chat-formatted models | none / model's own default template behavior |
| `--verbose-prompt` | Print the fully-formatted prompt before generation | off |

### Sampling (affects output style/quality, not speed or memory)

| Flag | Meaning | Default if unset |
|---|---|---|
| `--temp <float>` | Sampling temperature — higher = more random/creative, lower = more deterministic | `0.8` |
| `--top-k <N>` | Restrict sampling to the top K most likely tokens | `40` |
| `--top-p <float>` | Nucleus sampling — restrict to smallest token set whose cumulative probability ≥ this value | `0.95` |
| `--repeat-penalty <float>` | Penalize tokens that already appeared recently, to discourage repetition/looping | `1.1` |
| `--repeat-last-n <N>` | How many recent tokens count toward the repeat penalty | `64` |
| `--seed <N>` | RNG seed for reproducible sampling | `-1` (random each run) |
| `--ignore-eos` | Never stop on the model's own end-of-sequence token — keeps generating until `-n` or context limit instead | disabled |

### `llama-server`-specific

| Flag | Meaning | Default if unset |
|---|---|---|
| `--host <addr>` | Address to bind the HTTP server to | `127.0.0.1` (localhost only) |
| `--port <N>` | Port to listen on | `8080` |
| `--api-key <key>` | Require a bearer token to access the API | none (open access on whatever `--host`/`--port` is reachable) |
| `-cb, --cont-batching` | Allow multiple requests to be batched/processed concurrently | enabled in recent builds |
| `--parallel <N>` | Number of concurrent request "slots" the server can serve at once | `1` |
| `--embedding` | Run in embedding-output mode instead of chat/completion mode | disabled |

### Build/compile-time (not runtime flags, covered here for completeness)

| Flag | Meaning | Default if unset |
|---|---|---|
| `-DGGML_NATIVE` | Compile targeting the exact build machine's CPU (`-march=native`) | `ON` in current CMakeLists defaults, but always confirm — worth explicitly passing regardless (see build section) |
| `-DCMAKE_BUILD_TYPE` | Release vs. Debug build (see glossary entry on build types) | Often unset/empty by default depending on generator — **always pass explicitly**, since an unset value can behave like a debug build (see this project's Run #1 contamination incident) |

**Practical note specific to this project's incident:** `-n` and `-c` are independent settings — a large `-c` does not protect against a small `-n` cutting a response short, and vice versa a small `-c` will truncate/drop old context regardless of how large `-n` is set. Always check both when a response looks wrong, and cross-check actual behavior against `--help` on your specific build/version rather than trusting defaults from memory, since these have changed across llama.cpp releases.

---

## Knowledge vs. Inference Ability — Bridging Gaps Without Retraining

**RAG (Retrieval-Augmented Generation) / "context stuffing"**
Feeding relevant documents/text directly into a model's context window at inference time, so it can reference that information while answering, rather than relying only on what it learned during training. This does NOT change the model's weights — it's the equivalent of handing someone a reference book right before asking them a question, rather than expecting them to have memorized it.
- **Trade-off, not a free win:** a small model with lots of relevant documents in context does not become "smarter" in a general sense, and its per-token inference speed is unchanged (same weights, same compute per token) — but the larger context needed to hold those documents means a larger KV cache, which costs RAM and slows prompt processing (see "KV cache and context size" above). On RAM-constrained hardware, stuffing in too many documents can reintroduce the same swap-thrashing problem caused by an oversized default context.
- **Still bottlenecked by the model's own reading comprehension:** having the correct facts in context doesn't guarantee a correct answer — a weaker model can still misread, misweight, or misstate information that's right in front of it (see Qwen2-VL-2B's confabulation failure mode in the vision benchmark as a related example: accurate transcription, inaccurate interpretation).
- **"Lost in the middle" effect:** very long contexts can cause a model to under-weight or miss details buried in the middle of a large document set, even though those tokens are technically within the context window.
- **Good fit for:** a fast, general-purpose small model that needs to answer questions grounded in a specific, bounded set of documents (manuals, logs, a knowledge base) without the cost of retraining.

**Fine-tuning (contrast with RAG)**
Actually updates a model's weights using additional training data, permanently baking new knowledge or behavior into the model itself, rather than supplying it at inference time. Far more RAM/compute-intensive than RAG, not something done casually per-session, and generally overkill for "answer questions about these documents" use cases — RAG is the cheaper, more common solution for that specific problem.

**Per-query retrieval vs. whole-context stuffing (statelessness makes this possible)**
A model is stateless between inference calls — nothing is "loaded" persistently in the model itself; the RAM/KV-cache cost of a document exists only for the duration of the specific call that included it in context. This means documents don't have to be held in context for an entire session just to be "available":
- A proper RAG pipeline does a **retrieval step** before each question — searching a document collection (typically via embeddings/vector search) for just the small number of chunks relevant to *that specific question* — then injects only those chunks into context for that one call. The next question triggers a fresh, independent retrieval; nothing carries over unless deliberately re-included.
- This keeps per-query context size (and therefore RAM/KV cache cost) small and roughly constant, regardless of how large the total document collection is — a multi-gigabyte document set can sit on disk untouched, with only a few KB of the most relevant snippets ever entering context at once.
- **Trade-off:** retrieval quality becomes the new bottleneck — if the search step selects the wrong or incomplete chunks, the model will confidently answer based on what it was given, with no way to know what it's missing. The retrieval/search step itself is separate tooling (an embedding model + vector index/search), not something llama.cpp's CLI/server do natively.
- **Note on conversation history:** this per-query swap applies to bulk reference material, not necessarily to ongoing chat history — a multi-turn conversation typically still needs its prior turns retained in context for continuity, even while reference documents are being retrieved and dropped per-question.

---

## Build / Compilation Concepts

**Compiling "natively" (e.g. `-march=native`)**
A compiler flag that tells the compiler to detect and use the full instruction set of the machine it's currently building on, rather than a generic/portable baseline. Produces the fastest possible binary for that specific machine, but the resulting binary may not run (or won't use its full speed) on a different CPU. Fine for a single dedicated machine; a downside if you plan to copy the binary elsewhere.

**Precompiled/generic binaries**
Prebuilt binaries (like Ollama's default releases) are typically compiled for a broad compatibility baseline so they run on the widest range of hardware out of the box. This is more convenient but leaves performance on the table on any given specific machine compared to a native build.

**CMake build process (configure vs. build)**
Most modern C/C++ projects, including llama.cpp, use a two-stage build:
1. **Configure step** (`cmake -B <dir> [options]`): inspects the system (compiler, libraries, hardware) and generates the actual low-level build instructions (e.g. Makefiles) into a build directory, without compiling anything yet. This is where project-specific options (like enabling native CPU optimization) and build type (Release vs. Debug) are set.
2. **Build step** (`cmake --build <dir> [-j N]`): invokes the underlying build tool to actually compile and link everything. The `-j N` flag controls how many files compile in parallel — a good default is your physical core count, purely to speed up the build itself (has no effect on the resulting binary's runtime speed).

**Release vs. Debug build type**
- **Release**: compiler optimizations enabled (faster resulting binary), debug symbols stripped. What you want for a performance-sensitive deployment.
- **Debug**: optimizations off, debug info included — larger and slower, but easier to troubleshoot with a debugger. Not needed unless actively debugging a crash.

**Compiler warnings vs. errors**
- A **warning** means the compiler noticed something worth flagging (deprecated syntax, questionable pattern) but still produced a working binary.
- An **error** means the compiler refused to produce a binary at all.
- Seeing warnings — especially in a large, fast-moving open source project's own code — is normal and not something to chase down, as long as the build completes and links successfully. Only errors need fixing.

**Incremental builds can silently use stale compiler flags**
Classic `make`-based builds (CMake's default generator on Linux) decide whether to recompile a source file based on **file timestamps** — is the source newer than the existing object file? — not on whether the compiler flags actually changed. If you change a significant build option (build type, optimization flags, `-march=native`, etc.) on an *existing* build directory, any object file that wasn't touched since the last build can get linked into the final binary still carrying the **old** flags — even though the build system's cache/config correctly shows the new setting. This produces a binary that looks correctly configured on paper (checking `CMakeCache.txt` or `flags.make` shows the right values) but actually behaves like the old configuration, because it's a mix of newly- and previously-compiled object files.
- **Symptom:** unexpectedly poor performance, or runtime warnings (e.g. "debug build" messages) that contradict what the build configuration claims.
- **Fix:** after changing significant build options, do a full clean rebuild (`rm -rf build` + reconfigure + rebuild) rather than an incremental one, to guarantee every file compiles under the current, correct flags.

**BLAS (Basic Linear Algebra Subprograms)**
A standardized *interface* (not a specific piece of software) for common math operations like matrix multiplication and vector dot products. Many different libraries implement this interface (OpenBLAS, Intel MKL, Apple Accelerate, etc.), each optimized differently for different hardware. llama.cpp can optionally route its matrix math through an external BLAS library instead of its own built-in `ggml` tensor math kernels.
- llama.cpp's built-in kernels (used automatically, especially with a native-CPU build) are already hand-tuned for LLM inference and use available SIMD extensions (AVX2 etc.) directly — for CPU **token generation**, these are typically as fast or faster than an external BLAS library.
- An external BLAS backend can sometimes help specifically with **prompt processing** (the more parallelizable, batch-heavy phase) on certain hardware, since general BLAS libraries are extremely mature and tuned for raw throughput.
- Not required for a first setup — worth experimenting with only if prompt processing specifically turns out to be a bottleneck later.

---

*This file is meant to stay generic — update the experiment log (not this file) with machine-specific numbers, decisions, and results.*

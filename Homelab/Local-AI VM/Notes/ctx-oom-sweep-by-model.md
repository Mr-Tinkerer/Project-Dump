# Context Size OOM Sweep — By Model

**Prompt:** "What causes seasons on Earth?"
**Fixed parameters:** `-n 200 -t 4 -b 2048 -ub 512` (mmap mode varies per row)
**Method:** context size doubled each run starting at 512 until either the Linux OOM killer terminates the process, or `llama-cli`/`llama-server` fails to start at all with `Error: the server exited before becoming ready`. Both failure types are treated as memory-related (the model attempting to allocate more than the system has available) and both end that model/mode's sweep — the distinction is *how* the OS/process responded (hard kill vs. a clean failed allocation), not a difference in root cause. In the tables below, a table that simply stops after a row marked "No" means the **next** doubled `-c` value (2x the last row shown) is where the clean allocation failure occurred.
---

## Mistral-7B-Instruct-v0.3-Q4_K_M.gguf

| Context Size (-c) | Mmap Mode | Max RSS | Peak Swap Used | Stopped?
|---|---|---|---|---|---|
| 512 | --no-mmap | 4.17 GB | 0.7 MB | No |
| 512 | mmap (default) | 5.28 GB | 5.16 GB | No |
| 1024 | --no-mmap | 4.23 GB | 0.6 MB | No |
| 1024 | mmap (default) | 5.23 GB | 1.38 GB | No |
| 2048 | --no-mmap | 4.28 GB | 3.44 GB | No |
| 2048 | mmap (default) | 5.29 GB | 2.43 GB | No |
| 4096 | --no-mmap | 4.60 GB | 0.0 MB | No |
| 4096 | mmap (default) | 5.32 GB | 2.75 GB | No |
| 8192 | --no-mmap | 5.10 GB | 0.0 MB | No |
| 8192 | mmap (default) | 5.32 GB | 2.37 GB | No |
| 16384 | --no-mmap | 5.38 GB | 4.93 GB | No |
| 16384 | mmap (default) | 5.36 GB | 4.84 GB | No |
| 32768 | --no-mmap | 2.43 GB | 5.51 GB | **Yes (OOM-killed)** |
| 32768 | mmap (default) | 5.30 GB | 5.53 GB | No |
| 65536 | mmap (default) | 4.35 GB | 5.42 GB | **Yes (OOM-killed)** |

**Stop points**: `--no-mmap` → OOM at 32768. `mmap (default)` → OOM at 65536. 

---

## Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf

| Context Size (-c) | Mmap Mode | Max RSS | Peak Swap Used | Stopped? |
|---|---|---|---|---|
| 512 | --no-mmap | 4.73 GB | 0.0 MB | No |
| 512 | mmap (default) | 7.14 GB | 2.62 GB | No |
| 1024 | --no-mmap | 4.47 GB | 4.21 GB | No |
| 1024 | mmap (default) | 7.31 GB | 2.58 GB | No |
| 2048 | --no-mmap | 4.92 GB | 12.7 MB | No |
| 2048 | mmap (default) | 7.34 GB | 2.84 GB | No |
| 4096 | --no-mmap | 4.84 GB | 4.36 GB | No |
| 4096 | mmap (default) | 7.36 GB | 2.78 GB | No |
| 8192 | --no-mmap | 5.34 GB | 4.56 GB | No |
| 8192 | mmap (default) | 7.32 GB | 1.76 GB | No |
| 16384 | --no-mmap | 6.34 GB | 3.88 GB | No |
| 16384 | mmap (default) | 7.24 GB | 0.0 MB | No |
| 32768 | --no-mmap | 7.03 GB | 6.19 GB | No |
| 32768 | mmap (default) | 7.32 GB | 2.69 GB | No |
| 65536 | --no-mmap | 3.83 GB | 7.55 GB | **Yes (OOM-killed)** |
| 65536 | mmap (default) | 7.34 GB | 7.65 GB | No |
| 131072 | mmap (default) | 7.05 GB | 2.74 GB | No |

**Stop points:** `--no-mmap` → OOM-killed at 65536. `mmap (default)` → clean allocation failure at 131072.

## Phi-3.5-mini-instruct-Q4_K_M.gguf

| Context Size (-c) | Mmap Mode | Max RSS | Peak Swap Used | Stopped? |
|---|---|---|---|---|
| 512 | --no-mmap | 2.48 GB | 0.0 MB | No |
| 512 | mmap (default) | 3.66 GB | 0.0 MB | No |
| 1024 | --no-mmap | 2.66 GB | 0.0 MB | No |
| 1024 | mmap (default) | 3.85 GB | 0.0 MB | No |
| 2048 | --no-mmap | 2.95 GB | 2.69 GB | No |
| 2048 | mmap (default) | 4.22 GB | 0.0 MB | No |
| 4096 | --no-mmap | 3.70 GB | 2.85 GB | No |
| 4096 | mmap (default) | 4.97 GB | 0.0 MB | No |
| 8192 | --no-mmap | 5.29 GB | 0.1 MB | No |
| 8192 | mmap (default) | 6.47 GB | 0.0 MB | No |
| 16384 | --no-mmap | 7.30 GB | 3.47 GB | No |
| 16384 | mmap (default) | 7.39 GB | 3.39 GB | No |
| 32768 | --no-mmap | 7.36 GB | 7.62 GB | **Yes (OOM-killed)** |
| 32768 | mmap (default) | 7.35 GB | 7.65 GB | No |
| 65536 | mmap (default) | 3.47 GB | 0.0 MB | **Yes (clean allocation failure)** — RSS/swap look tame here because the process failed to start rather than running and being killed |

**Stop points:** `--no-mmap` → OOM-killed at 32768. `mmap (default)` → clean allocation failure at 65536.

---

## Qwen2.5-3B-Instruct-Q4_K_M.gguf

| Context Size (-c) | Mmap Mode | Max RSS | Peak Swap Used | Stopped? |
|---|---|---|---|---|
| 512 | --no-mmap | 1.89 GB | 0.0 MB | No |
| 512 | mmap (default) | 3.12 GB | 0.0 MB | No |
| 1024 | --no-mmap | 1.91 GB | 0.0 MB | No |
| 1024 | mmap (default) | 3.14 GB | 0.0 MB | No |
| 2048 | --no-mmap | 1.94 GB | 0.0 MB | No |
| 2048 | mmap (default) | 3.17 GB | 0.0 MB | No |
| 4096 | --no-mmap | 2.01 GB | 0.0 MB | No |
| 4096 | mmap (default) | 3.24 GB | 0.0 MB | No |
| 8192 | --no-mmap | 2.15 GB | 0.0 MB | No |
| 8192 | mmap (default) | 3.39 GB | 0.0 MB | No |
| 16384 | --no-mmap | 2.43 GB | 0.0 MB | No |
| 16384 | mmap (default) | 3.67 GB | 0.0 MB | No |
| 32768 | --no-mmap | 3.00 GB | 0.0 MB | No |
| 32768 | mmap (default) | 4.23 GB | 0.0 MB | No |
| 65536 | --no-mmap | 4.08 GB | 2.31 GB | No |
| 65536 | mmap (default) | 5.36 GB | 0.0 MB | No |
| 131072 | --no-mmap | 6.37 GB | 0.0 MB | No |
| 131072 | mmap (default) | 7.33 GB | 1.66 GB | No |
| 262144 | --no-mmap | 7.34 GB | 5.70 GB | No |
| 262144 | mmap (default) | 7.36 GB | 6.05 GB | No |
| 524288 | --no-mmap | 1.88 GB | 0.0 MB | **Yes (clean allocation failure)** |
| 524288 | mmap (default) | 3.12 GB | 0.0 MB | **Yes (clean allocation failure)** |

**Stop points:** Both modes → clean allocation failure at 524288.

---

## Gemma-3-4B_gemma-3-4b-it-Q4_K_M.gguf

| Context Size (-c) | Mmap Mode | Max RSS | Peak Swap Used | Stopped? |
|---|---|---|---|---|
| 512 | --no-mmap | 2.46 GB | 0.0 MB | No |
| 512 | mmap (default) | 3.88 GB | 0.0 MB | No |
| 1024 | --no-mmap | 2.52 GB | 0.0 MB | No |
| 1024 | mmap (default) | 3.95 GB | 0.0 MB | No |
| 2048 | --no-mmap | 2.60 GB | 0.0 MB | No |
| 2048 | mmap (default) | 4.02 GB | 0.0 MB | No |
| 4096 | --no-mmap | 2.64 GB | 0.0 MB | No |
| 4096 | mmap (default) | 4.06 GB | 0.0 MB | No |
| 8192 | --no-mmap | 2.72 GB | 0.0 MB | No |
| 8192 | mmap (default) | 4.14 GB | 0.0 MB | No |
| 16384 | --no-mmap | 2.87 GB | 0.0 MB | No |
| 16384 | mmap (default) | 4.30 GB | 0.0 MB | No |
| 32768 | --no-mmap | 3.19 GB | 0.0 MB | No |
| 32768 | mmap (default) | 4.61 GB | 0.0 MB | No |
| 65536 | --no-mmap | 3.81 GB | 0.0 MB | No |
| 65536 | mmap (default) | 5.24 GB | 0.0 MB | No |
| 131072 | --no-mmap | 5.07 GB | 0.0 MB | No |
| 131072 | mmap (default) | 6.20 GB | 1.77 GB | No |
| 262144 | --no-mmap | 7.37 GB | 3.85 GB | No |
| 262144 | mmap (default) | 7.38 GB | 3.11 GB | No |
| 524288 | --no-mmap | 7.34 GB | 7.64 GB | No |
| 524288 | mmap (default) | 7.32 GB | 7.65 GB | No |
| 1048576 | --no-mmap | 2.43 GB | 0.0 MB | **Yes (clean allocation failure)** |
| 1048576 | mmap (default) | 3.85 GB | 0.0 MB | **Yes (clean allocation failure)** |

**Stop points:** Both modes → clean allocation failure at 1,048,576

---

## Llama-3.2-3B-Instruct-Q4_K_M.gguf

| Context Size (-c) | Mmap Mode | Max RSS | Peak Swap Used | Stopped? |
|---|---|---|---|---|
| 512 | --no-mmap | 2.02 GB | 0.0 MB | No |
| 512 | mmap (default) | 3.29 GB | 0.0 MB | No |
| 1024 | --no-mmap | 2.08 GB | 0.0 MB | No |
| 1024 | mmap (default) | 3.34 GB | 0.0 MB | No |
| 2048 | --no-mmap | 2.19 GB | 0.0 MB | No |
| 2048 | mmap (default) | 3.45 GB | 0.0 MB | No |
| 4096 | --no-mmap | 2.41 GB | 0.0 MB | No |
| 4096 | mmap (default) | 3.67 GB | 0.0 MB | No |
| 8192 | --no-mmap | 2.84 GB | 0.0 MB | No |
| 8192 | mmap (default) | 4.11 GB | 0.0 MB | No |
| 16384 | --no-mmap | 3.66 GB | 1.64 GB | No |
| 16384 | mmap (default) | 4.98 GB | 0.0 MB | No |
| 32768 | --no-mmap | 5.47 GB | 0.0 MB | No |
| 32768 | mmap (default) | 6.73 GB | 0.0 MB | No |
| 65536 | --no-mmap | 7.34 GB | 5.07 GB | No |
| 65536 | mmap (default) | 7.38 GB | 4.23 GB | No |
| 131072 | --no-mmap | 7.38 GB | 7.58 GB | **Yes (OOM-killed)** |
| 131072 | mmap (default) | 7.33 GB | 7.65 GB | **Yes (OOM-killed)** |

**Stop points:** Both modes → OOM-killed at 131072. 

---

## gemma-2-2b-it-Q4_K_M.gguf 

| Context Size (-c) | Mmap Mode | Max RSS (RAM) | Peak Swap Used (during run) | OOM Killed? |
|---|---|---|---|---|
| 512 | --no-mmap | 1.67 GB | 3.00 GB | No |
| 512 | mmap (default) | 2.61 GB | 0.0 MB | No |
| 1024 | --no-mmap | 1.76 GB | 0.0 MB | No |
| 1024 | mmap (default) | 2.66 GB | 0.0 MB | No |
| 2048 | --no-mmap | 1.86 GB | 0.0 MB | No |
| 2048 | mmap (default) | 2.76 GB | 0.0 MB | No |
| 4096 | --no-mmap | 2.06 GB | 0.0 MB | No |
| 4096 | mmap (default) | 2.96 GB | 0.0 MB | No |
| 8192 | --no-mmap | 2.29 GB | 0.0 MB | No |
| 8192 | mmap (default) | 3.19 GB | 0.0 MB | No |
| 16384 | --no-mmap | 2.70 GB | 0.0 MB | No |
| 16384 | mmap (default) | 3.60 GB | 0.0 MB | No |
| 32768 | --no-mmap | 3.51 GB | 0.0 MB | No |
| 32768 | mmap (default) | 4.41 GB | 0.0 MB | No |
| 65536 | --no-mmap | 5.14 GB | 0.4 MB | No |
| 65536 | mmap (default) | 6.04 GB | 0.0 MB | No |
| 131072 | --no-mmap | 7.22 GB | 2.90 GB | No |
| 131072 | mmap (default) | 7.27 GB | 3.13 GB | No |
| 262144 | --no-mmap | 5.70 GB | 7.56 GB | Yes |
| 262144 | mmap (default) | 7.18 GB | 7.55 GB | Yes |

**Stop points:** Both modes → OOM-killed at 262144.

---

## DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf

| Context Size (-c) | Mmap Mode | Max RSS | Peak Swap Used | Stopped? |
|---|---|---|---|---|---|
| 512 | --no-mmap | 1.12 GB | 0.0 MB | No |
| 512 | mmap (default) | 1.70 GB | 0.0 MB | No |
| 1024 | --no-mmap | 1.14 GB | 0.0 MB | No |
| 1024 | mmap (default) | 1.71 GB | 0.0 MB | No |
| 2048 | --no-mmap | 1.16 GB | 0.0 MB | No |
| 2048 | mmap (default) | 1.74 GB | 0.0 MB | No |
| 4096 | --no-mmap | 1.22 GB | 0.0 MB | No |
| 4096 | mmap (default) | 1.75 GB | 0.0 MB | No |
| 8192 | --no-mmap | 1.33 GB | 0.0 MB | No |
| 8192 | mmap (default) | 1.90 GB | 0.0 MB | No |
| 16384 | --no-mmap | 1.55 GB | 0.0 MB | No |
| 16384 | mmap (default) | 2.12 GB | 0.0 MB | No |
| 32768 | --no-mmap | 1.98 GB | 0.0 MB | No |
| 32768 | mmap (default) | 2.56 GB | 0.0 MB | No |
| 65536 | --no-mmap | 2.86 GB | 0.1 MB | No |
| 65536 | mmap (default) | 3.43 GB | 0.0 MB | No |
| 131072 | --no-mmap | 4.61 GB | 0.0 MB | No |
| 131072 | mmap (default) | 5.19 GB | 0.3 MB | No |
| 262144 | --no-mmap | 5.33 GB | 3.97 GB | No |
| 262144 | mmap (default) | 5.32 GB | 4.00 GB | No |
| 524288 | --no-mmap | 4.31 GB | 5.53 GB | **Yes (OOM-killed)** |
| 524288 | mmap (default) | 5.23 GB | 5.53 GB | **Yes (OOM-killed)** |

**Stop points:** Both modes → OOM-killed at 524288.

---

## Cross-model summary — max safe `-c` on this 8GB VM (all models now confirmed)

| Model | `--no-mmap` ceiling | `--no-mmap` failure type | `mmap (default)` ceiling | `mmap (default)` failure type |
|---|---|---|---|---|
| Mistral-7B-Instruct-v0.3 | 16384 (fails at 32768) | OOM-killed | 32768 (fails at 65536) | OOM-killed |
| Meta-Llama-3.1-8B-Instruct | 32768 (fails at 65536) | OOM-killed | 131072 (fails at 262144)⚠️ | Clean allocation failure — unconfirmed, contradicts Run #9 |
| Phi-3.5-mini-instruct | 16384 (fails at 32768) | OOM-killed | 32768 (fails at 65536) | Clean allocation failure |
| Qwen2.5-3B-Instruct | 262144 (fails at 524288) | Clean allocation failure | 262144 (fails at 524288) | Clean allocation failure |
| Gemma-3-4B-it | 524288 (fails at 1048576) | Clean allocation failure | 524288 (fails at 1048576) | Clean allocation failure |
| Llama-3.2-3B-Instruct | 65536 (fails at 131072) | OOM-killed | 65536 (fails at 131072) | OOM-killed |
| gemma-2-2b-it-Q4_K_M.gguf | 262144 | OOM-killed | 262144 | OOM-killed |
| DeepSeek-R1-Distill-Qwen-1.5B | 262144 (fails at 524288) | OOM-killed | 262144 (fails at 524288) | OOM-killed |

**Open item:** re-test Meta-Llama-3.1-8B `mmap (default)` a third time to resolve the Run #9 vs. Run #10 contradiction at `-c 65536` before fully trusting its 131072 ceiling.

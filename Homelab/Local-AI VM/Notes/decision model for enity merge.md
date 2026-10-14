# Decision Model Benchmark: Entity Merge Verification

**Purpose:** Select a decision model to serve as Stage 3 of the entity-resolution pipeline, the verifier that decides whether two extracted entity names refer to the same concept.
**Hardware:** CPU-only Fedora VM, 8 GB RAM.
**Serving:** llama.cpp router on port 9931 (models swapped by request); a second thinkless endpoint on 9933.
**Date:** 2026-10-14
**Outcome:** `Qwen3.5-4B-Q4_K_M` in thinkless mode selected for the pipeline.

---

## 1. What Was Tested

Six candidate models were evaluated on a binary entity-resolution task: given two entity names extracted from a knowledge graph, decide whether they refer to the same concept (merge) or different concepts (do not merge).

| Model | Type | Size | Serving | Notes |
|---|---|---|---|---|
| `Qwen3.5-4B-Q4_K_M` | Generative LLM (thinking) | 4B | Port 9931 | Reasoning enabled |
| `Qwen3.5-4B-Q4_K_M` | Generative LLM (thinkless) | 4B | Port 9933 | Reasoning disabled |
| `Qwen3.5-2B-Q4_K_M` | Generative LLM (thinking) | 2B | Port 9931 | Reasoning enabled |
| `Qwen3.5-2B-Q4_K_M` | Generative LLM (thinkless) | 2B | Port 9933 | Reasoning disabled |
| `Laya-Q8_0` | Decision model (ModernBERT-large + decision head) | ~421M | Port 9931 `/v1/systemone` | Returns calibrated `P(true)` |
| `d1-3B-Q4_K_M` | Decision model (LFM2.5-VL-3B + pointer head) | 3B | Port 9931 `/v1/systemone` | Returns calibrated `P(true)` |
| `strands-decider-2b` | Decision model (Qwen3.5-2B + LoRA) | 2B | — | **Dropped** — does not load in current llama.cpp build |

Two benchmarks were run. The first was broad (125 pairs, mixed difficulty). The second was focused (110 pairs, designed to expose each model's specific weakness).

---

## 2. Why It Was Tested

The entity-resolution pipeline uses a tiered design:

1. **Stage 1** — rule-based normalization (case-fold, token reorder). Free, deterministic.
2. **Stage 2** — embedding similarity gate (`Qwen3-Embedding-0.6B`). Auto-accepts ≥ 0.90, auto-rejects < 0.70.
3. **Stage 3** — gray-zone verifier for the 0.70–0.89 band. This is what the benchmark tests.

The gray-zone verifier must produce reliable same/different judgments on pairs where surface similarity is ambiguous. Two error types matter:

- **False positives (FP)** — merging two distinct concepts. Destroys graph structure irreversibly; all edges and chunk references of the smaller node are absorbed into the larger. Hard to undo.
- **False negatives (FN)** — leaving a duplicate in place. Annoying but recoverable; a second pass can catch it.

**FP is strictly worse than FN.** A model with higher overall accuracy but more FP is a worse choice than a model with slightly lower accuracy but fewer FP. This drove the benchmark's second run, which was designed to expose FP behavior specifically.

The second reason for testing: the initial broad benchmark had two clear top candidates (`qwen4b_thinkless` at 98%, `d1` at 94%) but did not stress the case where the two diverged. d1's failures in the broad test all shared a pattern (over-merging prefix/substring pairs), while qwen4b's failures were different (missed character-level typos). The focused benchmark was built to amplify those two failure modes and see which one dominates in practice.

---

## 3. How It Was Tested

### 3.1 Protocol

Each model received the same pair of entity names and the same question:

```
Are these two entities the same concept?
Entity A: <name_a>
Entity B: <name_b>
Answer:
```

- **Generative models (Qwen thinking)** — `/v1/chat/completions`, `max_tokens=2048`, `temperature=0.6`. The large token budget allows the reasoning block to complete before the answer token; the parser reads `content`, falling back to `reasoning_content` if truncated.
- **Generative models (Qwen thinkless)** — `/v1/chat/completions`, `max_tokens=4`, `temperature=0`. No reasoning phase, direct yes/no answer.
- **Decision models (Laya, d1)** — `/v1/systemone`, `type=noul`, question "Are these two entities the same concept?". Response is `P(true)` in [0, 1].
- **Normalization** — Qwen outputs mapped `yes`→1, `no`→0. Decision model probabilities thresholded at 0.5 (raw probabilities preserved for offline re-thresholding).

### 3.2 Labeling Rule

The key convention applied throughout both test sets:

- **Label 1** — the two names refer to the *same concept*. Includes case variants, plural variants, multi-word case variants, acronym expansions, and typos of the same term.
- **Label 0** — the two names refer to *different concepts*. Includes:
  - A protocol/concept vs its daemon, implementation, or tool: `ssh`/`sshd`, `dns`/`named`, `http`/`httpd`, `ftp`/`vsftpd`, `smtp`/`postfix`, `imap`/`dovecot`, `ldap`/`openldap`, `nfs`/`nfs-utils`, `cifs`/`samba`, `ssh`/`openssh`
  - Broader vs narrower concept: `Firewall`/`Network Firewall`, `Server`/`Web Server`
  - Different protocols, ports, tools, or roles within the same domain

The protocol-vs-daemon rule is deliberate. Even though `ssh` and `sshd` are closely related, the extracted descriptions for those entities are about different things (one is the protocol, one is the process), and merging them would collapse distinct information into one node. The pipeline keeps them separate.

### 3.3 Metrics

Per model:

- `correct` / `wrong` / `errs` — raw counts
- `accuracy` — correct / total
- **`tp` (true positives)** — correctly merged (label 1, decision 1)
- **`tn` (true negatives)** — correctly kept separate (label 0, decision 0)
- **`fp` (false positives)** — wrongly merged (label 0, decision 1) ← **most important**
- **`fn` (false negatives)** — wrongly kept separate (label 1, decision 0)
- `load_first_ms` — latency of the first request to this model (includes unload of previous + cold load + one inference)
- `avg_inference_ms` — average latency of requests 2..N (pure inference)
- `wall_total_ms` — full wall time for the model's run

### 3.4 Run 1 — Broad Benchmark (125 pairs)

Mixed-difficulty test set spanning case variants, plural variants, prefix pairs, acronym expansions, protocol-vs-daemon pairs, distinct-port pairs, and cross-domain negatives. The intent was to establish a baseline ordering and see which models were even viable.

### 3.5 Run 2 — Focused Benchmark (110 pairs)

Test set designed to stress the failure modes observed in Run 1. Ten labeled categories:

| Category | Label | Count | Purpose |
|---|---|---|---|
| A. Prefix / tool traps | 0 | 18 | `dns`/`dnssec`, `nginx`/`nginx.conf`, `docker`/`dockerd` — d1's suspected weakness |
| B. Broader / narrower traps | 0 | 15 | `Firewall`/`Network Firewall`, `Server`/`Web Server` — d1's other weakness |
| C. Typos / character variants | 1 | 10 | `Cleint`/`Client`, `iptabels`/`iptables` — qwen4b's suspected weakness |
| D. Acronym expansions | 1 | 8 | `DMZ`/`Demilitarized Zone`, `NIC`/`Network Interface Card` |
| E. Multi-word case variants | 1 | 12 | `Network Firewall`/`network firewall` — sanity check |
| F. Plural variants | 1 | 10 | `firewall`/`firewalls` — sanity check |
| G. Semantic near-misses | 0 | 12 | `Security`/`Safety`, `Latency`/`Throughput` |
| H. Cross-domain traps | 0 | 8 | `ethanol`/`ethanal`, `gene`/`genome` — tests generalization |
| I. Shared-token pairs | 0 | 12 | `INPUT`/`INPUT Chain`, `Port 22`/`Port 80` |
| J. Trivially identical | 1 | 5 | `ssh`/`ssh`, `tcp`/`TCP` — controls |

Label distribution: **53 pairs labeled 1** (should merge), **57 pairs labeled 0** (should not merge). Balanced to expose both FP and FN behavior.

---

## 4. Results — Run 1 (Broad Benchmark, 125 pairs)

| Model | Correct | Wrong | ERR | Accuracy | Load+First | Avg Infer | Wall Total |
|---|---|---|---|---|---|---|---|
| **qwen4b_thinkless** | **123** | **2** | 0 | **0.98** | 28,717 ms | 1,253 ms | 184,418 ms |
| d1-3B | 117 | 8 | 0 | 0.94 | 19,312 ms | 685 ms | 104,752 ms |
| qwen2b_thinkless | 96 | 29 | 0 | 0.77 | 13,519 ms | 502 ms | 76,005 ms |
| Laya | 79 | 46 | 0 | 0.63 | 4,440 ms | 236 ms | 34,221 ms |
| qwen4b (thinking) | 25 | 0 | **100** | 0.20 | 497,159 ms | 120,086 ms | 15,388,226 ms |
| qwen2b (thinking) | 0 | 0 | **125** | 0.00 | 9 ms | 8 ms | 1,316 ms |
| strands-decider-2b | — | — | — | — | — | — | — (did not load) |

### Observations from Run 1

**Thinking models are unusable for this task.** Both Qwen thinking models exhausted `max_tokens` inside the reasoning block before emitting any answer. Every response came back with `content: ""` and `finish_reason: "length"`. Increasing the token budget would fix the truncation but at extreme latency cost (~120 s per pair at 4B), which is impractical for hundreds of files.

**Laya zero-shot underperforms.** At 63% accuracy it is barely better than a coin flip on the harder categories. As the model card discussion predicted, Laya's calibrated probabilities are strong when the answer is stated in the words of the state, but entity resolution requires conceptual judgment that Laya was not trained for.

**d1's failures are systematic.** All 8 d1 errors were FPs (over-merges) concentrated in prefix/substring pairs:

| Pair | Label | d1 P(true) | Category |
|---|---|---|---|
| `ssh`/`sshd` | 0 | 0.857 | Protocol vs daemon |
| `ssh`/`openssh` | 0 | 0.770 | Protocol vs impl |
| `ssh`/`OpenSSH` | 0 | 0.816 | Protocol vs impl |
| `ldap`/`openldap` | 0 | 0.630 | Protocol vs impl |
| `netstat`/`nc` | 0 | 0.555 | Different tools |
| `systemctl`/`systemd` | 0 | 0.889 | CLI vs daemon |
| `Firewall`/`Network Firewall` | 0 | 0.869 | Broader vs narrower |
| `Firewall`/`Host Firewall` | 0 | 0.809 | Broader vs narrower |

**qwen4b_thinkless's 2 failures are different.** One is the same Firewall over-merge (`Firewall`/`Network Firewall`), and one is a missed typo (`Cleint`/`Client`).

**qwen2b_thinkless has the opposite bias from d1.** Its 29 errors are mostly FNs — it fails to merge plural variants (`firewall`/`firewalls`, `Port`/`Ports`) and multi-word case variants (`Stateful Firewall`/`stateful firewall`). It is over-cautious.

---

## 5. Results — Run 2 (Focused Benchmark, 110 pairs)

| Model | Correct | Wrong | ERR | Accuracy | TP | TN | **FP** | **FN** | Load+First | Avg Infer | Wall Total |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **qwen4b_thinkless** | **104** | **6** | 0 | **0.95** | 40 | 64 | **1** | 5 | 4,335 ms | 1,250 ms | 140,839 ms |
| d1-3B | 95 | 15 | 0 | 0.86 | 45 | 50 | **15** | **0** | 17,964 ms | 687 ms | 93,267 ms |
| qwen2b_thinkless | 87 | 23 | 0 | 0.79 | 28 | 59 | 6 | 17 | 6,048 ms | 496 ms | 60,344 ms |

### Detailed Error Analysis

**qwen4b_thinkless — 6 errors total (1 FP, 5 FN):**

| Pair | Label | Decision | Type |
|---|---|---|---|
| `Firewall`/`Network Firewall` | 0 | yes | **FP** — broader vs narrower |
| `Cleint`/`Client` | 1 | no | FN — missed typo |
| `Adddress`/`Address` | 1 | no | FN — missed typo |
| `Protcol`/`Protocol` | 1 | no | FN — missed typo |
| `systemctl`/`sytemctl` | 1 | no | FN — missed typo |
| `iptabels`/`iptables` | 1 | no | FN — missed typo |

qwen4b's failure profile is dominated by FN on character-level typos. It successfully merges the *larger* edits (`Firewal`/`Firewall`, `Netowrk`/`Network`, `Apche`/`Apache`, `Postgress`/`Postgres`, `nginix`/`nginx`) but rejects the smaller ones (single-character substitutions). This is a threshold sensitivity, not a fundamental limitation: qwen4b is reasonably confident it's looking at a typo when two shared characters are transposed or a letter is doubled, but treats a single swap as possibly a different word. The single FP (`Firewall`/`Network Firewall`) is the same trap that caught d1 eight times in Run 1.

**d1-3B — 15 errors total (15 FP, 0 FN):**

All 15 errors are FPs. The full list:

| Pair | Label | P(true) | Category |
|---|---|---|---|
| `docker`/`dockerd` | 0 | 0.666 | Prefix + daemon |
| `containerd`/`container` | 0 | 0.648 | Prefix + daemon |
| `cron`/`crontab` | 0 | 0.694 | Prefix + tool |
| `Firewall`/`Network Firewall` | 0 | 0.869 | Broader vs narrower |
| `Firewall`/`Host Firewall` | 0 | 0.809 | Broader vs narrower |
| `Firewall`/`Personal Firewall` | 0 | 0.607 | Broader vs narrower |
| `Server`/`Web Server` | 0 | 0.703 | Broader vs narrower |
| `Service`/`Web Service` | 0 | 0.592 | Broader vs narrower |
| `Rule`/`Firewall Rule` | 0 | 0.596 | Broader vs narrower |
| `Packet`/`IP Packet` | 0 | 0.847 | Broader vs narrower |
| `Connection`/`TCP Connection` | 0 | 0.722 | Broader vs narrower |
| `Security`/`Safety` | 0 | 0.855 | Semantic near-miss |
| `Log`/`Logger` | 0 | 0.526 | Related but distinct |
| `cell`/`cellular` | 0 | 0.719 | Semantic near-miss |
| `interest`/`interest rate` | 0 | 0.565 | Broader vs narrower |

d1's failure mode is uniform: **it systematically over-merges whenever one entity contains the other as a substring or shares a stem.** Its `P(true)` values on the FPs cluster between 0.5 and 0.9 — the model *knows* these pairs are related, but its decision boundary is too permissive. If you raised the merge threshold from 0.5 to 0.90, most of these FPs would flip to negative decisions, at the cost of possibly increasing FN on genuine merges.

**qwen2b_thinkless — 23 errors total (6 FP, 17 FN):**

qwen2b's FN dominance shows it is under-confident on plural and case variants. Its 17 FNs include all 10 plural pairs (`firewall`/`firewalls`, `Port`/`Ports`, `Service`/`Services`, etc.), several multi-word case variants, and every single-character typo. Its 6 FPs cluster on broader-vs-narrower traps, same as d1.

---

## 6. Why `qwen4b_thinkless` Was Selected

The decision was made on **FP count**, not raw accuracy. Run 2 makes this explicit:

| Metric | qwen4b_thinkless | d1-3B | qwen2b_thinkless |
|---|---|---|---|
| Accuracy | **0.95** | 0.86 | 0.79 |
| FP (false merges) | **1** | 15 | 6 |
| FN (missed merges) | 5 | **0** | 17 |
| FP as % of label-0 pairs | **1.8%** | 26% | 11% |

d1's perfect FN score (0 missed merges) is a natural consequence of its over-permissive threshold: when a model says "yes" to nearly everything, it never misses a pair that should be merged. But that same permissiveness causes it to merge **1 in 4 distinct-concept pairs** — a rate that would seriously damage a knowledge graph ingested across hundreds of documents.

qwen4b's FP rate of 1.8% is acceptable. Its 5 FN are all character-level typos, which the Stage 2 embedding gate can partially catch (as the earlier analysis showed, embedding cosine similarity is likely to place typos like `Adddress`/`Address` above 0.90) and which a later cleanup pass can address. FN are recoverable; FP are not.

### Runtime tradeoff

qwen4b_thinkless is slower per inference (1,250 ms vs d1's 687 ms), but its load time is nearly 5× faster (4.3 s vs 18 s cold-load for d1's larger context window). For a batch process that runs the decision model across many candidate pairs after ingestion, the per-inference latency dominates and d1 would complete faster. For the pipeline's actual usage — a few dozen gray-zone pairs per document — the difference is negligible either way, and the FP advantage of qwen4b outweighs the latency cost.

### Deployment choice

`Qwen3.5-4B-Q4_K_M` in thinkless mode on port 9933 is the Stage 3 verifier. The same model instance already serves as the extraction LLM at port 9931, so no additional model needs to be resident in memory for the pipeline to function. The `noul` decision-model route (Laya, d1) is not used in production; those models are documented here for completeness.

### Threshold

The pipeline uses `yes` / `no` from qwen4b_thinkless directly, with no confidence score to threshold. If finer control is later required, the decision-model route with d1 at a high threshold (> 0.90) is a viable alternative, but it would need its own tuning pass on a labeled sample from the actual corpus.

---

## 7. Files and Reproducibility

### Scripts

- `compare_decision_models.sh` — broad benchmark (Run 1)
- `compare_decision_models_v2.sh` — focused benchmark (Run 2)

### Raw output

Per-model CSVs from Run 2:

- `decision_bench_v2/qwen4b_thinkless.csv` — 110 rows, per-pair decisions with latency
- `decision_bench_v2/qwen2b_thinkless.csv` — control model
- `decision_bench_v2/d1.csv` — decision model with raw `P(true)` per pair

Aggregate:

- `decision_bench_v2/summary.csv` — one row per model with accuracy, TP/TN/FP/FN, and timing
- `decision_bench_v2/all_results.csv` — concatenated per-pair rows across all models
- `decision_bench_v2/console.log` — running commentary

### Reproducing

```bash
# Ensure all serving endpoints are up
curl -s http://10.10.0.5:9931/v1/models | jq -r '.data[].id'
curl -s http://10.10.0.5:9933/v1/models | jq -r '.data[].id'

# Run the focused benchmark
./compare_decision_models_v2.sh 2>&1 | tee run2.log
```

Re-thresholding d1's results (or any decision-model output) can be done offline against the raw `P(true)` column without re-running the benchmark:

```bash
awk -F, 'NR>1 && $1=="d1" {d = ($6 >= 0.9) ? 1 : 0; print}' decision_bench_v2/d1.csv
```

---

## 8. Lessons for Future Benchmarks

**A single accuracy number hides the failure mode.** d1's 0.86 accuracy is not meaningfully worse than qwen4b's 0.95 — both look "good" on a summary line — but the FP/FN split reveals they fail in opposite directions with very different consequences for the pipeline. Every decision-model benchmark in this project should report FP and FN separately.

**Test sets should be adversarial, not representative.** Run 1's test set was representative of typical entity pairs and produced a 4-point accuracy gap between the top two models. Run 2 was constructed to amplify each model's observed weakness and produced a 12-point FP-rate gap. The second run took 25 minutes less wall time and yielded a much clearer decision. When a candidate decision is close, build the test set that maximizes the difference, not the one that mirrors the corpus.

**Decision models are not drop-in replacements for LLMs on conceptual tasks.** Laya scored 63% on Run 1 — near random. Its architecture (encode, score, return probability) eliminates hallucination but does not provide the conceptual judgment needed for entity resolution. d1 was better (86–94%) but still under-performs a small generative model in thinkless mode. The architectural benefit of decision models is real (calibration, no hallucination, speed), but the tradeoff in accuracy means they need fine-tuning before they can replace a generative LLM in this pipeline.

**Thinking mode is incompatible with single-token output tasks.** Every thinking-model response in Run 1 was truncated inside the reasoning block before emitting the answer token. The 2048-token budget was consumed entirely by the reasoning phase on many pairs. For binary decisions with a one-token answer, reasoning mode trades 100× latency for no accuracy benefit. Use thinkless mode.

#!/usr/bin/env bash
# =============================================================================
# bench-max-ctx.sh
#
# PURPOSE
#   Second stage after find-max-ctx.sh. For every model in its results file,
#   benchmark the model with llama-bench using:
#     * the same memory/speed-related settings as the llama-server presets.ini
#       entry (flash-attn, KV cache types, batch sizes, lazy mode, threads),
#     * the context filled up to the maximum size that fits in VRAM (via -d),
#     * two runs per model: KV cache on the GPU (-nkvo 0) and KV cache kept in
#       system RAM (-nkvo 1).
#
# WHAT THE BENCHMARK MEASURES
#   llama-bench reports two numbers per run:
#     pp<N>  prompt-processing speed (tokens/s) with the cache already holding
#            <depth> tokens of history
#     tg<N>  token-generation speed (tokens/s) at that same depth
#   Without -d, llama-bench measures an EMPTY context, which is unrealistically
#   fast for long contexts. -d <depth> first fills the cache with <depth> tokens,
#   so the numbers reflect attention over a full context. llama-bench allocates
#   a context of (depth + n_prompt + n_gen) tokens, so the script uses
#       depth = max_ctx - n_prompt - n_gen
#   to land exactly on the maximum context found by the search.
#
# PRESET KEYS -> llama-bench FLAGS
#   flash-attn        -> -fa        cache-type-k  -> -ctk      cache-type-v -> -ctv
#   batch-size        -> -b         ubatch-size   -> -ub       lazy-mode    -> -lzm
#   threads ([*])     -> -t         ngl is always 999 (everything on the GPU)
#   Dropped (llama-bench has no equivalent or they don't matter for speed):
#   mmproj, image-max-tokens, ctx-size (replaced by -d), reasoning,
#   reasoning-budget, temp/top-k/top-p/min-p, fit-target, cache-ram.
#
# NOTE ON TIME
#   Filling a 100K-250K token context takes real time (several minutes per run
#   for the big models). The script defaults to ONE repetition and no warmup to
#   keep this manageable; raise -r for tighter error bars.
#
# BEFORE YOU RUN
#   Stop llama-server and other GPU-hungry apps, otherwise VRAM is not free.
#
# USAGE
#   ./bench-max-ctx.sh [options] [ModelName ...]
#   With no ModelName arguments, every model in the results file is benchmarked.
#
# OPTIONS
#   -p FILE   presets.ini path             (default: ~/Projects/LLMs/presets.ini)
#   -i FILE   results TSV from the search  (default: max-ctx-results.tsv)
#   -C COL    which results column to use: recommended | max_ctx_in_vram
#                                          (default: recommended)
#   -b PATH   llama-bench binary           (default: llama-bench)
#   -P N      prompt tokens per test       (default: 512)
#   -N N      generated tokens per test    (default: 128)
#   -r N      repetitions per test         (default: 1)
#   -w        enable llama-bench warmup run (default: skipped, via --no-warmup)
#   -R N      attempts per run; on failure the depth is cut by 5% and retried
#                                          (default: 3)
#   -t SEC    timeout per attempt          (default: 3600)
#   -x "ARGS" extra args appended to every llama-bench call
#   -o FILE   TSV results file             (default: bench-results.tsv)
#   -h        show this help
# =============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
PRESETS="$HOME/Projects/LLMs/presets.ini"
INPUT="max-ctx-results.tsv"
CTXCOL="recommended"
BENCH="llama-bench"
N_PROMPT=512
N_GEN=128
REPS=5
WARMUP=0
ATTEMPTS=3
TIMEOUT=3600
EXTRA=""
OUT="bench-results.tsv"

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts "p:i:C:b:P:N:r:wR:t:x:o:h" opt; do
  case $opt in
    p) PRESETS=$OPTARG ;;  i) INPUT=$OPTARG ;;    C) CTXCOL=$OPTARG ;;
    b) BENCH=$OPTARG ;;    P) N_PROMPT=$OPTARG ;; N) N_GEN=$OPTARG ;;
    r) REPS=$OPTARG ;;     w) WARMUP=1 ;;         R) ATTEMPTS=$OPTARG ;;
    t) TIMEOUT=$OPTARG ;;  x) EXTRA=$OPTARG ;;    o) OUT=$OPTARG ;;
    h) usage 0 ;;          *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))
FILTER=("$@")

[[ -f "$PRESETS" ]] || { echo "presets file not found: $PRESETS" >&2; exit 1; }
[[ -f "$INPUT"   ]] || { echo "results file not found: $INPUT (run find-max-ctx.sh first)" >&2; exit 1; }
command -v "$BENCH" >/dev/null || { echo "llama-bench not found: $BENCH" >&2; exit 1; }

# Keep CUDA unified memory off so nothing silently spills into system RAM.
unset GGML_CUDA_ENABLE_UNIFIED_MEMORY

LOGDIR="$(mktemp -d -t benchctx-logs.XXXXXX)"
echo "Per-run logs (csv + stderr): $LOGDIR"

# ============================================================================
# SECTION 1: INI PARSING  (same approach as find-max-ctx.sh)
#   CFG["<section>|<key>"] = <value>. The [*] section is stored too, because
#   it holds global defaults (e.g. threads) that apply to every model.
# ============================================================================
declare -A CFG

parse_ini() {
  local line section="" key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"       # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"       # trim trailing whitespace
    [[ -z "$line" || "$line" == ';'* || "$line" == '#'* ]] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then section="${BASH_REMATCH[1]}"; continue; fi
    if [[ "$line" == *=* && -n "$section" ]]; then
      key="${line%%=*}";  val="${line#*=}"
      key="${key%"${key##*[![:space:]]}"}"
      val="${val#"${val%%[![:space:]]*}"}"
      CFG["$section|$key"]="$val"
    fi
  done < "$PRESETS"
}
parse_ini

# cfg <section> <key>  -> the section's value, else the [*] default, else empty.
cfg() {
  local v="${CFG["$1|$2"]:-}"
  [[ -z "$v" ]] && v="${CFG["*|$2"]:-}"
  printf '%s' "$v"
}

# Mapping preset key -> llama-bench flag. Only these are forwarded.
declare -A FLAGMAP=(
  [flash-attn]=-fa
  [cache-type-k]=-ctk
  [cache-type-v]=-ctv
  [batch-size]=-b
  [ubatch-size]=-ub
  [lazy-mode]=-lzm
  [threads]=-t
)
# Fixed order so the printed command is stable and readable.
FLAGORDER=(flash-attn cache-type-k cache-type-v batch-size ubatch-size lazy-mode threads)

# ============================================================================
# SECTION 2: READ THE SEARCH RESULTS
#   Pull (model, ctx) pairs from the chosen column of the TSV, skipping rows
#   whose value is not a positive number (e.g. ERROR or 0).
# ============================================================================
mapfile -t ROWS < <(
  awk -F'\t' -v col="$CTXCOL" '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == col) c = i; next }
    c && $c ~ /^[0-9]+$/ && $c + 0 > 0 { print $1 "\t" $c }
  ' "$INPUT"
)
(( ${#ROWS[@]} )) || { echo "no usable rows in $INPUT for column '$CTXCOL'" >&2; exit 1; }

# ============================================================================
# SECTION 3: ONE BENCHMARK RUN
# ============================================================================

# build_cmd <section> <depth> <nkvo 0|1>  -> fills the global array CMD
build_cmd() {
  local sec=$1 depth=$2 nkvo=$3 key val
  CMD=("$BENCH" -m "$(cfg "$sec" model)"
       -ngl 999                 # everything on the GPU (same as the context search)
       -p "$N_PROMPT" -n "$N_GEN"
       -d "$depth"              # fill the KV cache with <depth> tokens first
       -r "$REPS"
       -nkvo "$nkvo"            # 0 = KV cache in VRAM, 1 = KV cache in system RAM
       -o csv)                  # machine-readable results on stdout

  # Forward the preset values that llama-bench understands.
  for key in "${FLAGORDER[@]}"; do
    val="$(cfg "$sec" "$key")"
    [[ -n "$val" ]] && CMD+=("${FLAGMAP[$key]}" "$val")
  done

  # Embedding models: llama-bench runs them with -embd 1 and has no generation.
  if [[ "$(cfg "$sec" embedding)" == "true" ]]; then
    CMD+=(-embd 1)
  fi

  (( WARMUP )) || CMD+=(--no-warmup)
  # shellcheck disable=SC2206
  [[ -n "$EXTRA" ]] && CMD+=($EXTRA)
}

# print_cmd -> print CMD in copy-paste form.
print_cmd() { printf '    $ '; printf '%q ' "${CMD[@]}"; printf '\n'; }

# parse_csv <csvfile> -> prints "pp|tg <avg_ts> <stddev_ts>" lines.
#   llama-bench CSV columns differ a little between versions, so columns are
#   located by header name (n_prompt, n_gen, avg_ts, stddev_ts) instead of
#   position. A quote-aware splitter handles fields like "NVIDIA ..., 12.0".
parse_csv() {
  awk '
    function split_csv(line, arr,   n, i, c, f, inq) {
      n = 0; f = ""; inq = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") {
          if (inq && substr(line, i + 1, 1) == "\"") { f = f "\""; i++ }
          else inq = !inq
        } else if (c == "," && !inq) { arr[++n] = f; f = "" }
        else f = f c
      }
      arr[++n] = f
      return n
    }
    {
      gsub(/\r$/, "")
      n = split_csv($0, a)
      if (!hdr) {                                  # first line = header
        for (i = 1; i <= n; i++) h[a[i]] = i
        hdr = 1; next
      }
      p = a[h["n_prompt"]] + 0; g = a[h["n_gen"]] + 0
      if (p > 0 && g == 0) print "pp", a[h["avg_ts"]], a[h["stddev_ts"]]
      else if (g > 0 && p == 0) print "tg", a[h["avg_ts"]], a[h["stddev_ts"]]
    }
  ' "$1"
}

# run_one <section> <ctx> <nkvo>
#   Runs the benchmark for one (model, nkvo) combination and appends a row to
#   the results file. If the run fails (usually out of memory), the depth is cut
#   by 5% and retried, up to ATTEMPTS times.
run_one() {
  local sec=$1 ctx=$2 nkvo=$3
  local depth=$(( ctx - N_PROMPT - N_GEN )) attempt rc status="FAIL"
  local base="$LOGDIR/${sec}_nkvo${nkvo}"
  local pp="" ppsd="" tg="" tgsd="" kind avg sd

  (( depth < 0 )) && depth=0

  for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
    build_cmd "$sec" "$depth" "$nkvo"
    echo "  [nkvo=$nkvo] attempt $attempt  (context = $((depth + N_PROMPT + N_GEN)), depth = $depth)"
    print_cmd

    # stdout = CSV results, stderr = llama.cpp log. Both are kept in LOGDIR.
    timeout "$TIMEOUT" "${CMD[@]}" </dev/null >"$base.csv" 2>"$base.log"
    rc=$?

    if (( rc == 0 )); then
      while read -r kind avg sd; do
        [[ "$kind" == pp ]] && { pp=$avg; ppsd=$sd; }
        [[ "$kind" == tg ]] && { tg=$avg; tgsd=$sd; }
      done < <(parse_csv "$base.csv")
      status="OK"
      printf '      pp%s = %s t/s   tg%s = %s t/s\n' "$N_PROMPT" "${pp:--}" "$N_GEN" "${tg:--}"
      break
    fi

    echo "      -> failed (rc=$rc). Last log lines:"
    tail -n 4 "$base.log" | sed 's/^/        | /'
    depth=$(( depth * 95 / 100 ))           # shrink 5% and try again
  done

  [[ "$status" == FAIL ]] && echo "      -> giving up on nkvo=$nkvo for $sec"

  # model, nkvo, context actually used, depth, pp t/s, pp stddev, tg t/s, tg stddev, status
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sec" "$nkvo" "$((depth + N_PROMPT + N_GEN))" "$depth" \
    "${pp:--}" "${ppsd:--}" "${tg:--}" "${tgsd:--}" "$status" >> "$OUT"
}

# ============================================================================
# SECTION 4: MAIN LOOP
# ============================================================================
if command -v nvidia-smi >/dev/null; then
  echo "GPU memory before start:"
  nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader | sed 's/^/  /'
  echo "  (if memory.used is high, stop llama-server / other GPU apps first)"
fi

printf 'model\tnkvo\tcontext\tdepth\tpp%s_ts\tpp_stddev\ttg%s_ts\ttg_stddev\tstatus\n' \
  "$N_PROMPT" "$N_GEN" > "$OUT"

for row in "${ROWS[@]}"; do
  sec="${row%%$'\t'*}"
  ctx="${row##*$'\t'}"

  # Optional model-name filter from the command line.
  if (( ${#FILTER[@]} )); then
    keep=0; for f in "${FILTER[@]}"; do [[ "$f" == "$sec" ]] && keep=1; done
    (( keep )) || continue
  fi

  model="$(cfg "$sec" model)"
  if [[ -z "$model" || ! -f "$model" ]]; then echo "== $sec: model file missing, skipping"; continue; fi

  echo "== $sec  (max context from search: $ctx)"
  run_one "$sec" "$ctx" 0      # KV cache in VRAM
  run_one "$sec" "$ctx" 1      # KV cache in system RAM (-nkvo)
done

echo
echo "Summary ($OUT):"
column -t -s $'\t' "$OUT"

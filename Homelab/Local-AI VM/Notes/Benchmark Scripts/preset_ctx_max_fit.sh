#!/usr/bin/env bash
# =============================================================================
# find-max-ctx.sh
#
# PURPOSE
#   For every model entry in a llama-server router presets.ini, find the largest
#   --ctx-size that still lets the WHOLE model + KV cache + compute buffers live
#   in GPU VRAM (i.e. nothing spills to the CPU / system RAM).
#
# HOW IT WORKS (parametric search on a monotone yes/no predicate)
#   Define fits(ctx) = "model loads fully on the GPU with this context size".
#   Bigger context -> bigger KV cache -> more VRAM, so fits() is true for small
#   values and flips to false at some threshold. We find that threshold with few
#   trials instead of testing every value:
#     1. PREFLIGHT: run the raw command once at the minimum context and print it.
#        If it fails, try fallback flag variants (some llama-cli builds reject
#        some flags) and print the error tail, so a broken command is visible
#        immediately instead of being mistaken for "doesn't fit".
#     2. Galloping phase: try MIN, 2*MIN, 4*MIN ... until a trial fails (or MAX).
#     3. Binary search between the last good and first bad value until the gap
#        is no larger than STEP.
#
# WHAT ONE TRIAL IS
#   A tiny llama-cli run based on your template (1 token, grammar "yes"|"no",
#   temp 0) plus:
#     -ngl 999   -> every layer on the GPU
#     --fit off  -> disable llama.cpp auto-fit (it would silently shrink things)
#   A trial "fits" if the program exits 0 AND (when the log reports it) all
#   layers were offloaded to the GPU.
#
# BEFORE YOU RUN
#   Stop llama-server and other GPU-hungry apps, otherwise results are too low.
#
# USAGE
#   ./find-max-ctx.sh [options] [ModelName ...]
#   With no ModelName arguments, every section except [*] is tested.
#
# OPTIONS
#   -p FILE     presets.ini path            (default: ~/Projects/LLMs/presets.ini)
#   -c PATH     llama-cli binary            (default: llama-cli)
#   -e PATH     llama-embedding binary      (default: llama-embedding)
#   -l N        smallest ctx to try         (default: 512)
#   -u N        largest ctx to try          (default: 262144)
#   -s N        resolution in tokens        (default: 512)
#   -t SEC      timeout per trial           (default: 300)
#   -H PCT      headroom % subtracted for the "recommended" column (default: 0)
#   -x "ARGS"   extra args appended to every trial (e.g. "--parallel 1")
#   -M          ignore mmproj (vision projector) when testing
#   -o FILE     TSV results file            (default: max-ctx-results.tsv)
#   -h          show this help
# =============================================================================

# -u: error on unset variables, -o pipefail: failures inside pipes count.
# (No -e: failed trials are expected and handled explicitly.)
set -uo pipefail

# ----------------------------------------------------------------------------
# Defaults (override with the options above)
# ----------------------------------------------------------------------------
PRESETS="$HOME/Projects/LLMs/presets.ini"
LLAMA_CLI="llama-cli"
LLAMA_EMB="llama-embedding"
MIN_CTX=512
MAX_CTX=262144
STEP=512
TIMEOUT=300
HEADROOM=0
EXTRA=""
USE_MMPROJ=1
OUT="max-ctx-results.tsv"

# Print the header comment block as help text.
usage() {
  sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while getopts "p:c:e:l:u:s:t:H:x:Mo:h" opt; do
  case $opt in
    p) PRESETS=$OPTARG ;;   c) LLAMA_CLI=$OPTARG ;;  e) LLAMA_EMB=$OPTARG ;;
    l) MIN_CTX=$OPTARG ;;   u) MAX_CTX=$OPTARG ;;    s) STEP=$OPTARG ;;
    t) TIMEOUT=$OPTARG ;;   H) HEADROOM=$OPTARG ;;   x) EXTRA=$OPTARG ;;
    M) USE_MMPROJ=0 ;;      o) OUT=$OPTARG ;;        h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))
FILTER=("$@")     # remaining arguments = optional list of section names to test

[[ -f "$PRESETS" ]] || { echo "presets file not found: $PRESETS" >&2; exit 1; }
command -v "$LLAMA_CLI" >/dev/null || { echo "llama-cli not found: $LLAMA_CLI" >&2; exit 1; }

# CUDA "unified memory" lets the GPU silently use system RAM when VRAM runs out,
# which would make every trial "fit". Make sure it is off.
unset GGML_CUDA_ENABLE_UNIFIED_MEMORY

# Full output of every FAILED trial is saved here for inspection.
LOGDIR="$(mktemp -d -t maxctx-logs.XXXXXX)"
echo "Failed-trial logs: $LOGDIR"

# ============================================================================
# SECTION 1: INI PARSING
#   CFG["<section>|<key>"] = <value>; SECTIONS keeps section names in file order.
#   The [*] section (global llama-server defaults) is skipped: none of its keys
#   change VRAM use in this test.
# ============================================================================
declare -A CFG
declare -a SECTIONS=()

parse_ini() {
  local line section="" key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"       # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"       # trim trailing whitespace
    [[ -z "$line" || "$line" == ';'* || "$line" == '#'* ]] && continue   # blanks/comments

    if [[ "$line" =~ ^\[(.+)\]$ ]]; then          # section header
      section="${BASH_REMATCH[1]}"
      [[ "$section" != "*" ]] && SECTIONS+=("$section")
      continue
    fi

    if [[ "$line" == *=* && -n "$section" ]]; then   # key = value
      key="${line%%=*}";  val="${line#*=}"
      key="${key%"${key##*[![:space:]]}"}"
      val="${val#"${val%%[![:space:]]*}"}"
      CFG["$section|$key"]="$val"
    fi
  done < "$PRESETS"
}
parse_ini

# Preset keys that change VRAM usage; each is forwarded as "--<key> <value>".
# Samplers, threads, reasoning, fit-target etc. don't affect memory, so skipped.
PASS_KEYS=(flash-attn cache-type-k cache-type-v batch-size ubatch-size lazy-mode image-max-tokens)

# ============================================================================
# SECTION 2: BUILDING AND RUNNING A SINGLE TRIAL
# ============================================================================

# llama-cli flags that only make it behave in a one-shot, script-friendly way
# (no interactive chat). Different llama.cpp builds accept different spellings,
# so the preflight tries these variants in order and keeps the first that works.
CLI_VARIANTS=(
  "-no-cnv --no-display-prompt --simple-io"
  "-no-cnv --no-display-prompt"
  "-no-cnv"
  "--single-turn --no-display-prompt"
  "--single-turn"
  ""
)
SEL_VARIANT="${CLI_VARIANTS[0]}"   # variant currently in use (set by preflight)
SEL_MMPROJ=$USE_MMPROJ             # 1 = pass --mmproj (may be turned off by preflight)

# build_cmd <section> <ctx>  -> fills the global array CMD
build_cmd() {
  local sec=$1 ctx=$2 model mmproj k v
  model="${CFG["$sec|model"]:-}"
  mmproj="${CFG["$sec|mmproj"]:-}"
  CMD=()

  if [[ "${CFG["$sec|embedding"]:-}" == "true" ]]; then
    # Embedding models can't generate text, so use llama-embedding.
    CMD=("$LLAMA_EMB" -m "$model" -p "Is the sky blue?")
  else
    # Your template: answer "yes"/"no", one token, deterministic.
    CMD=("$LLAMA_CLI" -m "$model" -p "Is the sky blue?"
         --grammar 'root ::= "yes" | "no"' -n 1 --temp 0)
    # shellcheck disable=SC2206
    [[ -n "$SEL_VARIANT" ]] && CMD+=($SEL_VARIANT)     # one-shot flags (intentional word-split)
  fi

  # The flags that define the experiment:
  #   -c <ctx>   context size under test
  #   -ngl 999   everything on the GPU
  #   --fit off  no automatic trimming, so a too-big context really fails
  CMD+=(-c "$ctx" -ngl 999 --fit off)

  # Vision projector takes VRAM at runtime, so include it for realistic numbers.
  if (( SEL_MMPROJ )) && [[ -n "$mmproj" && "${CFG["$sec|embedding"]:-}" != "true" ]]; then
    CMD+=(--mmproj "$mmproj")
  fi

  # Forward the memory-relevant preset keys (KV cache type, batch sizes, ...).
  for k in "${PASS_KEYS[@]}"; do
    v="${CFG["$sec|$k"]:-}"
    [[ -n "$v" ]] && CMD+=("--$k" "$v")
  done

  # shellcheck disable=SC2206
  [[ -n "$EXTRA" ]] && CMD+=($EXTRA)                   # user extras (-x)
}

# print_cmd -> prints CMD exactly as it could be pasted into a shell (%q quotes it).
print_cmd() {
  printf '    $ '
  printf '%q ' "${CMD[@]}"
  printf '\n'
}

# run_trial -> runs CMD, sets OUT_TEXT (combined output) and RC (exit code).
run_trial() {
  OUT_TEXT=$(timeout "$TIMEOUT" "${CMD[@]}" </dev/null 2>&1); RC=$?
}

# judge -> returns 0 if the last run_trial result means "fits fully on the GPU".
judge() {
  local n m
  (( RC != 0 )) && return 1                    # crash / OOM / bad flag / timeout
  if [[ "$OUT_TEXT" =~ offloaded\ ([0-9]+)/([0-9]+)\ layers\ to\ GPU ]]; then
    n=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}
    (( n != m )) && return 1                   # some layers stayed on the CPU
  fi
  return 0                                     # no such line? exit code 0 is enough
}

declare -A CACHE     # CACHE["section|ctx"]=1/0, so no ctx is loaded twice per model
TRIALS=0             # real model loads for the current model

# fits <section> <ctx> -> status 0 if the model fits fully in VRAM at that ctx.
# Progress goes to stderr; on failure, the last lines of output are shown so the
# real reason (OOM vs. bad flag) is visible.
fits() {
  local sec=$1 ctx=$2 ok=1
  if [[ -n "${CACHE["$sec|$ctx"]:-}" ]]; then return $(( 1 - CACHE["$sec|$ctx"] )); fi

  build_cmd "$sec" "$ctx"
  TRIALS=$((TRIALS + 1))
  printf '    ctx=%-8s ' "$ctx" >&2
  run_trial
  judge || ok=0

  if (( ok )); then
    echo "fits" >&2
  else
    echo "FAIL (rc=$RC)" >&2
    printf '%s\n' "${CMD[*]}" > "$LOGDIR/${sec}_$ctx.log"
    printf '%s\n' "$OUT_TEXT" >> "$LOGDIR/${sec}_$ctx.log"
    printf '%s\n' "$OUT_TEXT" | tail -n 4 | sed 's/^/        | /' >&2
  fi
  CACHE["$sec|$ctx"]=$ok
  return $(( 1 - ok ))
}

# ============================================================================
# SECTION 3: PREFLIGHT (print the raw command and prove it can run at all)
# ============================================================================

# preflight <section>
#   Prints the raw command, runs it at MIN_CTX, and if it fails tries fallback
#   variants (other one-shot flags, then without --mmproj). On success the
#   working settings stay in SEL_VARIANT / SEL_MMPROJ and it returns 0.
#   If nothing works it prints the error tail and returns 1 (model is skipped).
preflight() {
  local sec=$1 v mm first_out="" first_rc=0 tried=0
  local variants=("$SEL_VARIANT")                  # try the last working variant first
  for v in "${CLI_VARIANTS[@]}"; do [[ "$v" != "$SEL_VARIANT" ]] && variants+=("$v"); done
  [[ "${CFG["$sec|embedding"]:-}" == "true" ]] && variants=("")   # no variants for embeddings

  local mm_options=($USE_MMPROJ)
  # Fallback: if this entry has a projector, also try without it.
  [[ -n "${CFG["$sec|mmproj"]:-}" ]] && (( USE_MMPROJ )) && mm_options+=(0)

  echo "  Raw command (ctx=$MIN_CTX):"
  for mm in "${mm_options[@]}"; do
    for v in "${variants[@]}"; do
      SEL_VARIANT=$v; SEL_MMPROJ=$mm
      build_cmd "$sec" "$MIN_CTX"
      print_cmd
      run_trial
      tried=$((tried + 1))
      if (( tried == 1 )); then first_out=$OUT_TEXT; first_rc=$RC; fi
      if judge; then
        (( mm != USE_MMPROJ )) && echo "  ! WARNING: only works WITHOUT --mmproj; projector VRAM is not counted (subtract ~1 GiB-worth of context yourself)"
        echo "  Preflight OK (variant: '${SEL_VARIANT:-none}', mmproj: $SEL_MMPROJ)"
        return 0
      fi
      echo "      -> failed (rc=$RC)"
    done
  done

  echo "  Preflight FAILED for every variant. Output of the first attempt (rc=$first_rc):"
  printf '%s\n' "$first_out" | tail -n 15 | sed 's/^/      | /'
  SEL_VARIANT="${CLI_VARIANTS[0]}"; SEL_MMPROJ=$USE_MMPROJ
  return 1
}

# ============================================================================
# SECTION 4: THE SEARCH ITSELF
# ============================================================================

BEST=0     # result of search(): global (NOT captured via $(...)) so that the
           # TRIALS counter and CACHE survive; subshells would lose them.

# search <section> -> sets BEST to the largest ctx that fits (0 if none).
search() {
  local sec=$1 lo hi mid
  BEST=0

  # Step 1: smallest context (already proven by preflight, answered from cache or reloaded).
  fits "$sec" "$MIN_CTX" || return
  lo=$MIN_CTX                    # invariant from here: 'lo' ALWAYS fits

  # Step 2: galloping phase. Double until something fails -> bracket [lo ok, hi bad].
  hi=$((lo * 2))
  while :; do
    (( hi > MAX_CTX )) && hi=$MAX_CTX                 # never exceed the cap
    if fits "$sec" "$hi"; then
      lo=$hi                                          # fits: raise the floor
      if (( hi >= MAX_CTX )); then BEST=$lo; return; fi   # cap reached and still fits
      hi=$((hi * 2))
    else
      break                                           # first failure: bracket complete
    fi
  done

  # Step 3: binary search. 'lo' fits, 'hi' fails; stop when within STEP tokens.
  while (( hi - lo > STEP )); do
    mid=$(( (lo + hi) / 2 / STEP * STEP ))            # midpoint rounded to a multiple of STEP
    (( mid <= lo )) && break
    if fits "$sec" "$mid"; then lo=$mid; else hi=$mid; fi
  done
  BEST=$lo
}

# ============================================================================
# SECTION 5: MAIN LOOP
# ============================================================================

if command -v nvidia-smi >/dev/null; then
  echo "GPU memory before start:"
  nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader | sed 's/^/  /'
  echo "  (if memory.used is high, stop llama-server / other GPU apps first)"
fi

printf 'model\tconfigured_ctx\tmax_ctx_in_vram\trecommended\ttrials\n' > "$OUT"

TARGETS=()
if (( ${#FILTER[@]} )); then TARGETS=("${FILTER[@]}"); else TARGETS=("${SECTIONS[@]}"); fi

for sec in "${TARGETS[@]}"; do
  model="${CFG["$sec|model"]:-}"
  if [[ -z "$model" ]]; then echo "== $sec: no 'model' key, skipping"; continue; fi
  if [[ ! -f "$model" ]]; then echo "== $sec: file missing ($model), skipping"; continue; fi

  echo "== $sec"
  TRIALS=0
  SEL_MMPROJ=$USE_MMPROJ

  # Show the raw command and make sure it runs before searching.
  if ! preflight "$sec"; then
    echo "  -> SKIPPED: command itself fails (see output above), not a VRAM result"
    printf '%s\t%s\t%s\t%s\t%s\n' "$sec" "${CFG["$sec|ctx-size"]:-default}" "ERROR" "ERROR" 0 >> "$OUT"
    continue
  fi

  echo "  Searching (min=$MIN_CTX max=$MAX_CTX step=$STEP):"
  search "$sec"

  if (( BEST == 0 )); then
    rec=0
    echo "  -> does not fit fully in VRAM even at ctx=$MIN_CTX"
  else
    rec=$(( BEST * (100 - HEADROOM) / 100 / STEP * STEP ))
    echo "  -> max ctx = $BEST  (recommended ctx-size = $rec, $TRIALS trials)"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$sec" "${CFG["$sec|ctx-size"]:-default}" "$BEST" "$rec" "$TRIALS" >> "$OUT"
done

echo
echo "Summary ($OUT):"
column -t -s $'\t' "$OUT"

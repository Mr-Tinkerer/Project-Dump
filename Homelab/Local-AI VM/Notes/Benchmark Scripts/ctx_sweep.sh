#!/usr/bin/env bash
#
# ctx_oom_sweep.sh
#
# Sweeps llama.cpp's context size (-c) upward, doubling each run, until the
# Linux kernel's OOM killer terminates llama-cli. At each context size, both
# --no-mmap and default (mmap-enabled) modes are tested, logging context
# size, mmap mode, RAM usage, and peak swap usage to a single markdown table
# so the two modes can be compared directly at the same -c value.
#
# Held constant across every run (see concepts-glossary.md — "Isolating the
# RAM cost of context size" / "Batch size"): same model, same prompt, same
# -n, same -t, same -b/-ub. Only -c and mmap mode vary.
#
# Usage:
#   ./ctx_oom_sweep.sh
#
# Edit the CONFIG block below before running.

set -uo pipefail

# ── CONFIG ────────────────────────────────────────────────────────────────
LLAMA_CLI="llama-cli"                      # resolved via PATH (see Section 7
                                            # of experiment-log-1.md — symlinked
                                            # into /usr/local/bin)
MODEL_DIR="$HOME/models"                   # directory all models below live in
MODELS=(
    "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf"
    "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
    "Phi-3.5-mini-instruct-Q4_K_M.gguf"
    "Qwen2.5-3B-Instruct-Q4_K_M.gguf"
    "Gemma-3-4B_gemma-3-4b-it-Q4_K_M.gguf"
    "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
    "gemma-2-2b-it-Q4_K_M.gguf"
    "DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
  # Add more .gguf filenames here, one per line, one per model to test —
  # each is tested independently with the full -c + mmap-mode sweep below.
)
PROMPT="What causes seasons on Earth?"
N_PREDICT=200                              # -n, fixed across all runs
THREADS=4                                  # -t, fixed across all runs
BATCH_SIZE=2048                            # -b, fixed across all runs
UBATCH_SIZE=512                            # -ub, fixed across all runs
START_CTX=512                              # first -c value tested
MAX_CTX=1073741824                         # hard safety ceiling (1B tokens) —
                                            # loop will hit OOM long before this
OUTPUT_MD="ctx_oom_sweep_results.md"       # markdown results file
RAW_LOG_DIR="ctx_oom_sweep_raw_logs"       # per-run raw /usr/bin/time output
SWAP_POLL_INTERVAL="0.2"                   # seconds between swap samples while
                                            # the run is in flight
                                            # (both --no-mmap and mmap modes are
                                            # tested at every -c value)
# ─────────────────────────────────────────────────────────────────────────

if ! command -v "$LLAMA_CLI" >/dev/null 2>&1; then
  echo "ERROR: '$LLAMA_CLI' not found on PATH. Confirm the symlink into" >&2
  echo "/usr/local/bin exists (see experiment-log-1.md Section 7b)." >&2
  exit 1
fi

if [ "${#MODELS[@]}" -eq 0 ]; then
  echo "ERROR: MODELS array is empty. Add at least one .gguf filename." >&2
  exit 1
fi

for m in "${MODELS[@]}"; do
  if [ ! -f "$MODEL_DIR/$m" ]; then
    echo "ERROR: model file not found: $MODEL_DIR/$m" >&2
    exit 1
  fi
done

mkdir -p "$RAW_LOG_DIR"

# ── Markdown file header (only written once, at the start of this sweep) ──
{
  echo "# Context Size OOM Sweep — $(date '+%Y-%m-%d %H:%M %Z')"
  echo
  echo "**Models tested:**"
  for m in "${MODELS[@]}"; do
    echo "- \`$m\`"
  done
  echo
  echo "**Prompt:** \"$PROMPT\""
  echo "**Fixed parameters:** \`-n $N_PREDICT -t $THREADS -b $BATCH_SIZE -ub $UBATCH_SIZE\` (mmap mode varies — see table)"
  echo
  echo "Context size doubled each run, starting at $START_CTX, until the Linux OOM killer terminates the process (or llama.cpp fails to allocate cleanly). Every model in the list above is swept independently and in full (both \`--no-mmap\` and default mmap-enabled modes, at every \`-c\` value) before moving to the next model, each with its own results table below. Each model+mode combination tracks its own stop point independently — a combination that has already stopped is skipped in later rows while other combinations continue."
} > "$OUTPUT_MD"

# ── Helper: current swap used system-wide, in KB ───────────────────────────
get_swap_used_kb() {
  # SwapTotal - SwapFree, from /proc/meminfo, in KB
  awk '
    /^SwapTotal:/ { total=$2 }
    /^SwapFree:/  { free=$2 }
    END { print (total - free) }
  ' /proc/meminfo
}

kb_to_human() {
  local kb=$1
  if [ "$kb" -ge 1048576 ]; then
    awk -v kb="$kb" 'BEGIN { printf "%.2f GB", kb/1048576 }'
  else
    awk -v kb="$kb" 'BEGIN { printf "%.1f MB", kb/1024 }'
  fi
}

# ── Run one test at a given context size + mmap mode ────────────────────────
# Returns 0 normally; returns 1 if this run was OOM-killed.
run_one_test() {
  local MODEL_NAME="$1"
  local MODEL_PATH="$2"
  local CTX="$3"
  local MODE="$4"      # "nomap" or "mmap"
  local RUN_NUM="$5"

  local MMAP_FLAG=""
  local MODE_LABEL="mmap (default)"
  if [ "$MODE" = "nomap" ]; then
    MMAP_FLAG="--no-mmap"
    MODE_LABEL="--no-mmap"
  fi

  echo "=== Run $RUN_NUM: model=$MODEL_NAME, -c $CTX, mode=$MODE_LABEL ==="

  local MODEL_LOG_DIR="$RAW_LOG_DIR/${MODEL_NAME}"
  mkdir -p "$MODEL_LOG_DIR"
  local RAW_LOG="$MODEL_LOG_DIR/run_${RUN_NUM}_ctx_${CTX}_${MODE}.log"
  local SWAP_POLL_LOG="$MODEL_LOG_DIR/run_${RUN_NUM}_ctx_${CTX}_${MODE}_swap_poll.log"

  local SWAP_BASELINE_KB
  SWAP_BASELINE_KB=$(get_swap_used_kb)

  # Launch llama-cli in the background under /usr/bin/time -v so we can poll
  # swap WHILE it runs — checking before/after misses transient spikes that
  # get reclaimed once the process exits or memory pressure eases.
  # shellcheck disable=SC2086
  /usr/bin/time -v "$LLAMA_CLI" \
    -m "$MODEL_PATH" \
    -t "$THREADS" \
    -c "$CTX" \
    -b "$BATCH_SIZE" \
    -ub "$UBATCH_SIZE" \
    -p "$PROMPT" \
    -n "$N_PREDICT" \
    -st \
    $MMAP_FLAG \
    > "$RAW_LOG" 2>&1 &
  local CMD_PID=$!

  # Background poller: sample system-wide swap usage every
  # SWAP_POLL_INTERVAL seconds until the process exits, tracking the peak.
  : > "$SWAP_POLL_LOG"
  (
    while kill -0 "$CMD_PID" 2>/dev/null; do
      get_swap_used_kb >> "$SWAP_POLL_LOG"
      sleep "$SWAP_POLL_INTERVAL"
    done
  ) &
  local POLL_PID=$!

  wait "$CMD_PID"
  local EXIT_CODE=$?

  # Stop the poller (it should exit on its own once CMD_PID is gone, but
  # make sure) and take one final sample in case the peak landed in the gap
  # between the last poll and process exit.
  get_swap_used_kb >> "$SWAP_POLL_LOG"
  kill "$POLL_PID" 2>/dev/null
  wait "$POLL_PID" 2>/dev/null

  # Peak swap-used during the run = max sample seen minus the pre-run
  # baseline (so we're reporting what THIS run added, not whatever swap
  # was already in use system-wide beforehand).
  local PEAK_SWAP_DURING_RUN_KB
  PEAK_SWAP_DURING_RUN_KB=$(sort -n "$SWAP_POLL_LOG" | tail -n 1)
  PEAK_SWAP_DURING_RUN_KB=${PEAK_SWAP_DURING_RUN_KB:-$SWAP_BASELINE_KB}
  local SWAP_USED_KB=$(( PEAK_SWAP_DURING_RUN_KB - SWAP_BASELINE_KB ))
  if [ "$SWAP_USED_KB" -lt 0 ]; then
    SWAP_USED_KB=0
  fi
  local SWAP_USED_HUMAN
  SWAP_USED_HUMAN=$(kb_to_human "$SWAP_USED_KB")

  # Extract Max RSS from the /usr/bin/time -v output (in KB), convert.
  local MAX_RSS_KB
  MAX_RSS_KB=$(grep -oP 'Maximum resident set size \(kbytes\):\s*\K[0-9]+' "$RAW_LOG")
  local MAX_RSS_HUMAN
  if [ -n "${MAX_RSS_KB:-}" ]; then
    MAX_RSS_HUMAN=$(kb_to_human "$MAX_RSS_KB")
  else
    MAX_RSS_HUMAN="N/A (process likely killed before /usr/bin/time could report)"
  fi

  # Detect OOM kill: exit code 137 (SIGKILL), OR confirm via dmesg/journalctl
  # mentioning the OOM killer, whichever is available.
  local OOM_DETECTED="No"
  local NOTES=""

  if [ "$EXIT_CODE" -eq 137 ]; then
    OOM_DETECTED="Yes"
    NOTES="Exit code 137 (SIGKILL)"
  fi

  local OOM_KERNEL_MSG=""
  if command -v journalctl >/dev/null 2>&1; then
    OOM_KERNEL_MSG=$(journalctl -k --since "-2min" 2>/dev/null \
      | grep -i "out of memory\|oom-kill\|Killed process" \
      | tail -n 3)
  elif command -v dmesg >/dev/null 2>&1; then
    OOM_KERNEL_MSG=$(dmesg -T 2>/dev/null \
      | grep -i "out of memory\|oom-kill\|Killed process" \
      | tail -n 3)
  fi

  if [ -n "$OOM_KERNEL_MSG" ]; then
    OOM_DETECTED="Yes"
    NOTES="${NOTES:+$NOTES; }Confirmed via kernel log: $(echo "$OOM_KERNEL_MSG" | tail -n 1)"
  fi

  if [ "$OOM_DETECTED" = "No" ] && [ "$EXIT_CODE" -ne 0 ]; then
    NOTES="${NOTES:+$NOTES; }Non-zero exit ($EXIT_CODE), not OOM — likely a clean allocation failure (e.g. \"server exited before becoming ready\") at a -c value too large to allocate. Check raw log: $RAW_LOG"
  fi

  echo "| $CTX | $MODE_LABEL | $MAX_RSS_HUMAN | $SWAP_USED_HUMAN | $OOM_DETECTED |" >> "$OUTPUT_MD"

  echo "    Max RSS: $MAX_RSS_HUMAN | Peak swap: $SWAP_USED_HUMAN | OOM: $OOM_DETECTED | exit=$EXIT_CODE${NOTES:+ | $NOTES}"

  if [ "$OOM_DETECTED" = "Yes" ]; then
    return 1
  fi
  # A nonzero, non-OOM exit means llama.cpp failed to even start at this -c
  # (typically a clean allocation failure once -c is large enough) — this
  # combination should also stop, since it will never recover by doubling
  # -c further; it will just keep failing the same way up to MAX_CTX.
  if [ "$EXIT_CODE" -ne 0 ]; then
    return 2
  fi
  return 0
}

# ── Sweep loop — every model in MODELS[], each fully swept in turn ──────────
RUN_NUM=1
declare -A MODEL_NOMAP_STOPPED_CTX
declare -A MODEL_MMAP_STOPPED_CTX
declare -A MODEL_NOMAP_STOP_REASON
declare -A MODEL_MMAP_STOP_REASON

for MODEL_NAME in "${MODELS[@]}"; do
  MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
  echo
  echo "############################################################"
  echo "# Starting sweep for model: $MODEL_NAME"
  echo "############################################################"

  {
    echo
    echo "## $MODEL_NAME"
    echo
    echo "| Context Size (-c) | Mmap Mode | Max RSS (RAM) | Peak Swap Used (during run) | OOM Killed? |"
    echo "|---|---|---|---|---|"
  } >> "$OUTPUT_MD"

  CTX=$START_CTX
  NOMAP_STOPPED=0
  MMAP_STOPPED=0

  while [ "$CTX" -le "$MAX_CTX" ] && { [ "$NOMAP_STOPPED" -eq 0 ] || [ "$MMAP_STOPPED" -eq 0 ]; }; do

    if [ "$NOMAP_STOPPED" -eq 0 ]; then
      run_one_test "$MODEL_NAME" "$MODEL_PATH" "$CTX" "nomap" "$RUN_NUM"
      RESULT=$?
      if [ "$RESULT" -eq 1 ]; then
        NOMAP_STOPPED=1
        MODEL_NOMAP_STOPPED_CTX["$MODEL_NAME"]=$CTX
        MODEL_NOMAP_STOP_REASON["$MODEL_NAME"]="OOM-killed"
        echo "[$MODEL_NAME] --no-mmap mode OOM'd at -c $CTX. That combination stops here."
      elif [ "$RESULT" -eq 2 ]; then
        NOMAP_STOPPED=1
        MODEL_NOMAP_STOPPED_CTX["$MODEL_NAME"]=$CTX
        MODEL_NOMAP_STOP_REASON["$MODEL_NAME"]="clean allocation failure (not OOM)"
        echo "[$MODEL_NAME] --no-mmap mode failed to allocate (non-OOM) at -c $CTX. That combination stops here."
      fi
      RUN_NUM=$((RUN_NUM + 1))
    fi

    if [ "$MMAP_STOPPED" -eq 0 ]; then
      run_one_test "$MODEL_NAME" "$MODEL_PATH" "$CTX" "mmap" "$RUN_NUM"
      RESULT=$?
      if [ "$RESULT" -eq 1 ]; then
        MMAP_STOPPED=1
        MODEL_MMAP_STOPPED_CTX["$MODEL_NAME"]=$CTX
        MODEL_MMAP_STOP_REASON["$MODEL_NAME"]="OOM-killed"
        echo "[$MODEL_NAME] mmap (default) mode OOM'd at -c $CTX. That combination stops here."
      elif [ "$RESULT" -eq 2 ]; then
        MMAP_STOPPED=1
        MODEL_MMAP_STOPPED_CTX["$MODEL_NAME"]=$CTX
        MODEL_MMAP_STOP_REASON["$MODEL_NAME"]="clean allocation failure (not OOM)"
        echo "[$MODEL_NAME] mmap (default) mode failed to allocate (non-OOM) at -c $CTX. That combination stops here."
      fi
      RUN_NUM=$((RUN_NUM + 1))
    fi

    CTX=$((CTX * 2))
  done

  if [ "$NOMAP_STOPPED" -eq 0 ] || [ "$MMAP_STOPPED" -eq 0 ]; then
    echo "[$MODEL_NAME] Reached MAX_CTX ($MAX_CTX) before one or both modes stopped."
  fi
done

{
  echo
  echo "## Summary — stop point and reason per model/mode"
  echo
  echo "| Model | --no-mmap stopped at -c | --no-mmap reason | mmap (default) stopped at -c | mmap (default) reason |"
  echo "|---|---|---|---|---|"
  for MODEL_NAME in "${MODELS[@]}"; do
    NOMAP_CTX_RESULT="${MODEL_NOMAP_STOPPED_CTX[$MODEL_NAME]:-did not stop within MAX_CTX}"
    NOMAP_REASON_RESULT="${MODEL_NOMAP_STOP_REASON[$MODEL_NAME]:-—}"
    MMAP_CTX_RESULT="${MODEL_MMAP_STOPPED_CTX[$MODEL_NAME]:-did not stop within MAX_CTX}"
    MMAP_REASON_RESULT="${MODEL_MMAP_STOP_REASON[$MODEL_NAME]:-—}"
    echo "| $MODEL_NAME | $NOMAP_CTX_RESULT | $NOMAP_REASON_RESULT | $MMAP_CTX_RESULT | $MMAP_REASON_RESULT |"
  done
  echo
  echo "Raw logs for every run are in \`$RAW_LOG_DIR/<model filename>/\`."
} >> "$OUTPUT_MD"
echo
echo "All sweeps finished. Results: $OUTPUT_MD"

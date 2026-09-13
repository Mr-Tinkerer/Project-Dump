#!/usr/bin/env bash

set -euo pipefail

MODELS_DIR="$HOME/models"
BENCH_BIN="$HOME/llama.cpp/build/bin/llama-bench"
CLI_BIN="$HOME/llama.cpp/build/bin/llama-cli"

# Updated Model URLs
QUANTS=(
  "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q8_0.gguf"
  "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_S.gguf"
  "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-IQ3_M.gguf"
)

# Shared Evaluation Prompts
PROMPTS=(
  "Sally has 3 brothers. Each brother has 2 sisters. How many sisters does Sally have? Explain your reasoning briefly."
  "Output ONLY a raw JSON object containing 2 solar system planets with keys: 'name', 'moons_count', and 'has_rings'."
  "Write a concise Python function to check if a word is a palindrome."
)

mkdir -p "$MODELS_DIR"

# ---------------------------------------------------------
# 1. Download Models
# ---------------------------------------------------------
echo "=========================================="
echo " Starting Downloads"
echo "=========================================="
for url in "${QUANTS[@]}"; do
  filename=$(basename "$url")
  filepath="$MODELS_DIR/$filename"
  if [ -f "$filepath" ]; then
    echo "[EXISTS] Skipping $filename"
  else
    echo "[DOWNLOADING] $filename..."
    curl -C - -L --progress-bar "$url" -o "$filepath"
  fi
done

# ---------------------------------------------------------
# 2. Run Speed Benchmarks (llama-bench)
# ---------------------------------------------------------
echo ""
echo "=========================================="
echo " Running Performance Benchmarks (-t 4, -c 4096)"
echo "=========================================="
for url in "${QUANTS[@]}"; do
  filename=$(basename "$url")
  filepath="$MODELS_DIR/$filename"
  echo ""
  echo "--- Benchmarking: $filename ---"
  "$BENCH_BIN" -m "$filepath" -t 4 -c 4096
done

# ---------------------------------------------------------
# 3. Quality & Reasoning Evaluation (llama-cli)
# ---------------------------------------------------------
echo ""
echo "=========================================="
echo " Starting Model Quality Evaluation"
echo "=========================================="

for url in "${QUANTS[@]}"; do
  filename=$(basename "$url")
  filepath="$MODELS_DIR/$filename"

  echo ""
  echo "=================================================================="
  echo " MODEL: $filename"
  echo "=================================================================="

  prompt_idx=1
  for prompt in "${PROMPTS[@]}"; do
    echo ""
    echo "--- [Prompt $prompt_idx]: \"$prompt\" ---"

    "$CLI_BIN" \
      -m "$filepath" \
      -t 4 \
      -c 4096 \
      -n 200 \
      --temp 0.2 \
      -p "$prompt" \
      --no-display-prompt \
      2>/dev/null

    echo ""
    ((prompt_idx++))
  done
done

#!/usr/bin/env bash

set -euo pipefail

# Directories and binary paths
MODELS_DIR="$HOME/models"
BENCH_BIN="$HOME/llama.cpp/build/bin/llama-bench"

# Benchmark options
THREADS=4

# Model download URLs for unbenchmarked models (4-bit Q4_K_M quants)
MODELS=(
  "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
  "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf"
  "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf"
  "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf"
)

# Verify llama-bench exists
if [ ! -f "$BENCH_BIN" ]; then
  echo "Error: llama-bench binary not found at $BENCH_BIN"
  exit 1
fi

# Ensure output directory exists
mkdir -p "$MODELS_DIR"

echo "=========================================="
echo " Starting Downloads (Remaining Models)"
echo "=========================================="

for url in "${MODELS[@]}"; do
  filename=$(basename "$url")
  filepath="$MODELS_DIR/$filename"

  if [ -f "$filepath" ]; then
    echo "[EXISTS] Skipping download for $filename"
  else
    echo "[DOWNLOADING] $filename..."
    # -C - enables resume if interrupted; -L follows redirects
    curl -C - -L --progress-bar "$url" -o "$filepath"
  fi
done

echo ""
echo "=========================================="
echo " Starting Benchmarks (-t $THREADS)"
echo "=========================================="

for url in "${MODELS[@]}"; do
  filename=$(basename "$url")
  filepath="$MODELS_DIR/$filename"

  if [ -f "$filepath" ]; then
    echo ""
    echo "Benchmarking: $filename"
    echo "------------------------------------------"
    "$BENCH_BIN" -m "$filepath" -t "$THREADS"
  else
    echo "[WARNING] $filename not found, skipping benchmark."
  fi
done

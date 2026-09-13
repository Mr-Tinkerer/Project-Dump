#!/usr/bin/env bash
#
# VLM Vision Benchmark Script for llama.cpp
# Phase 1: Downloads 6 quantized GGUF vision models into ~/models safely (.part verification).
# Phase 2: Benchmarks models on 15 images with -st, -c 4096, timing, and Markdown logging.

set -euo pipefail

# --- Configuration & Paths ---
IMAGE_DIR="${HOME}/images"
MODELS_DIR="${HOME}/models"
OUTPUT_FILE="vision_benchmark_results2.md"
TEMP_OUT="temp_output.txt"

# Set llama.cpp binary (override by passing LLAMA_BIN=./path/to/llama-cli)
LLAMA_BIN="${LLAMA_BIN:-llama-cli}"

# --- Prerequisites Check ---
if ! command -v curl &> /dev/null; then
    echo "Error: curl is required but not installed." >&2
    exit 1
fi

if ! command -v "${LLAMA_BIN}" &> /dev/null; then
    echo "Error: ${LLAMA_BIN} executable not found in PATH." >&2
    echo "Tip: Run with 'LLAMA_BIN=/path/to/llama-cli $0' or ensure it is in your PATH." >&2
    exit 1
fi

if [[ ! -d "${IMAGE_DIR}" ]]; then
    echo "Error: Image directory '${IMAGE_DIR}' does not exist." >&2
    exit 1
fi

mkdir -p "${MODELS_DIR}"

# --- Model Definitions ---
# Format: "MODEL_NAME|BASE_URL|MODEL_FILENAME|MMPROJ_FILENAME"
MODELS=(
   "Qwen2-VL-2B|https://huggingface.co/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main|Qwen2-VL-2B-Instruct-Q4_K_M.gguf|mmproj-Qwen2-VL-2B-Instruct-f16.gguf"
   "MiniCPM-V-2|https://huggingface.co/openbmb/MiniCPM-V-2_6-gguf/resolve/main|ggml-model-Q4_K_M.gguf|mmproj-model-f16.gguf"
   "Gemma-3-4B|https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main|gemma-3-4b-it-Q4_K_M.gguf|mmproj-model-f16.gguf"
   "Qwen2-VL-7B|https://huggingface.co/bartowski/Qwen2-VL-7B-Instruct-GGUF/resolve/main|Qwen2-VL-7B-Instruct-Q4_K_M.gguf|mmproj-Qwen2-VL-7B-Instruct-f16.gguf"
   "LLaVA-1.6-13B|https://huggingface.co/cjpais/llava-v1.6-vicuna-13b-gguf/resolve/main|llava-v1.6-vicuna-13b.Q4_K_M.gguf|mmproj-model-f16.gguf"
    "InternVL2-8B|https://huggingface.co/ggml-org/InternVL2_5-4B-GGUF/resolve/main|InternVL2_5-4B-Q8_0.gguf|mmproj-InternVL2_5-4B-Q8_0.gguf"
)

# Helper function to reliably download a file and ensure it is 100% complete
download_file() {
    local url="$1"
    local final_dest="$2"
    local part_dest="${final_dest}.part"

    if [[ -f "${final_dest}" ]]; then
        echo "  [✔] Already fully downloaded: $(basename "${final_dest}")"
        return 0
    fi

    echo "  [↓] Downloading: $(basename "${final_dest}")..."

    local curl_args=("-f" "-L" "--progress-bar")
    if [[ -f "${part_dest}" ]]; then
        curl_args+=("-C" "-")
        echo "      (Resuming partial download)"
    fi

    if curl "${curl_args[@]}" "${url}" -o "${part_dest}"; then
        mv "${part_dest}" "${final_dest}"
        echo "  [✔] Download complete!"
    else
        echo "  [✖] Error downloading $(basename "${final_dest}")." >&2
        exit 1
    fi
}

# Helper function to locate image files 1..15 regardless of extension (.png/.jpg)
find_image() {
    local idx="$1"
    for ext in png jpg jpeg PNG JPG JPEG; do
        if [[ -f "${IMAGE_DIR}/${idx}.${ext}" ]]; then
            echo "${IMAGE_DIR}/${idx}.${ext}"
            return 0
        fi
    done
    return 1
}

# ==============================================================================
# PHASE 1: Download All Models
# ==============================================================================
echo "=================================================="
echo "PHASE 1: Downloading Models to ${MODELS_DIR}"
echo "=================================================="

for entry in "${MODELS[@]}"; do
    IFS="|" read -r MODEL_NAME BASE_URL MODEL_FILE MMPROJ_FILE <<< "${entry}"

    echo "Checking files for ${MODEL_NAME}..."

    LOCAL_MODEL_PATH="${MODELS_DIR}/${MODEL_NAME}_${MODEL_FILE}"
    LOCAL_MMPROJ_PATH="${MODELS_DIR}/${MODEL_NAME}_${MMPROJ_FILE}"

    download_file "${BASE_URL}/${MODEL_FILE}" "${LOCAL_MODEL_PATH}"
    download_file "${BASE_URL}/${MMPROJ_FILE}" "${LOCAL_MMPROJ_PATH}"
    echo ""
done

# ==============================================================================
# PHASE 2: Benchmark Models
# ==============================================================================
echo "=================================================="
echo "PHASE 2: Running Inference Benchmarks"
echo "=================================================="

# Delete existing output and temp files before starting
rm -f "${OUTPUT_FILE}" "${TEMP_OUT}"

# Initialize fresh Markdown output report
cat <<EOF > "${OUTPUT_FILE}"
# Vision Model Evaluation Report
Date: $(date '+%Y-%m-%d %H:%M:%S')

EOF

for entry in "${MODELS[@]}"; do
    IFS="|" read -r MODEL_NAME _ MODEL_FILE MMPROJ_FILE <<< "${entry}"

    LOCAL_MODEL_PATH="${MODELS_DIR}/${MODEL_NAME}_${MODEL_FILE}"
    LOCAL_MMPROJ_PATH="${MODELS_DIR}/${MODEL_NAME}_${MMPROJ_FILE}"

    echo "Testing Model: ${MODEL_NAME}..."

    cat <<EOF >> "${OUTPUT_FILE}"
## Model: ${MODEL_NAME}

| Image Index | Inference Time | Model Description | Accuracy Grade |
| :---: | :---: | :--- | :---: |
EOF

    for i in $(seq 1 15); do
        IMAGE_PATH=$(find_image "$i" || true)

        if [[ -z "${IMAGE_PATH}" ]]; then
            echo "  Warning: Image ${i} not found in ${IMAGE_DIR}. Skipping..."
            echo "| ${i} | N/A | [Image file missing] | |" >> "${OUTPUT_FILE}"
            continue
        fi

        echo "  - Analyzing Image ${i}..."

        rm -f "${TEMP_OUT}"
        start_time=$SECONDS

        # Run inference
        "${LLAMA_BIN}" \
            -m "${LOCAL_MODEL_PATH}" \
            --mmproj "${LOCAL_MMPROJ_PATH}" \
            --image "${IMAGE_PATH}" \
            -p "Describe what you see in this image in detail." \
            -c 4096 \
            -st \
            -o "${TEMP_OUT}" \
            > /dev/null 2>&1 || true

        elapsed_time=$(( SECONDS - start_time ))

        # Extract output and sanitize (flatten lines, escape markdown pipes, collapse whitespace safely without xargs)
        if [[ -f "${TEMP_OUT}" && -s "${TEMP_OUT}" ]]; then
            DESCRIPTION=$(tr '\n' ' ' < "${TEMP_OUT}" | sed -E 's/\|/\\|/g; s/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')
        else
            DESCRIPTION="[No output generated or error executing llama.cpp]"
        fi

        echo "| ${i} | ${elapsed_time}s | ${DESCRIPTION} | |" >> "${OUTPUT_FILE}"
    done

    echo "" >> "${OUTPUT_FILE}"
    rm -f "${TEMP_OUT}"
    echo "Finished evaluation for ${MODEL_NAME}."
    echo ""
done

echo "Benchmark complete! Results written to fresh '${OUTPUT_FILE}'."

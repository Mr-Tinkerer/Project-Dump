#!/usr/bin/env bash

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration & Setup
# ------------------------------------------------------------------------------
MODEL_DIR="$HOME/models"
OUTPUT_DIR="./eval_results"
mkdir -p "$MODEL_DIR" "$OUTPUT_DIR"

# Common llama-cli settings
CTX_SIZE=4096
TEMP=0.8
THREADS=4

# Map display names to direct Hugging Face download URLs (4-bit quants)
declare -A MODEL_URLS=(
  ["DeepSeek-R1-Distill-Qwen 1.5B"]="https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
  ["Gemma 2 2B"]="https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf"
  ["Llama 3.2 3B"]="https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
  ["Qwen 2.5 3B"]="https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf"
  ["Phi-3.5 Mini 3.8B"]="https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf"
  ["Llama 3.1 8B"]="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
)

# Questions array (index 1-30)
QUESTIONS=(
  "" # 1-based indexing alignment
  "What is the capital of Australia, and why is it not Sydney or Melbourne?"
  "List the planets of the solar system in order from the Sun, then tell me which one has the most moons."
  "Explain the difference between weather and climate in two sentences."
  "Follow this instruction exactly: respond with only the word \"acknowledged\" and nothing else."
  "A farmer has 17 sheep. All but 9 die. How many are left?"
  "If a train travels 60 km in 45 minutes, what is its speed in km/h?"
  "Solve: 3x + 7 = 22. What is x?"
  "Three friends split a \$60 bill unevenly: Alice pays twice what Bob pays, and Carol pays \$10 more than Bob. How much does each person pay?"
  "Write a Python function that returns the nth Fibonacci number using memoization."
  "Output the following as valid JSON only, no extra text: a person named \"Sam\", age 34, hobbies [\"reading\", \"cycling\"]."
  "Write a Bash one-liner that finds all .log files larger than 100MB under /var/log."
  "Fix the bug in this Python snippet: def add(a, b): return a - b"
  "Summarize in one sentence: \"The meeting covered Q3 budget overruns, a proposed hiring freeze, and a decision to delay the product launch to Q1 next year.\""
  "Extract the date, time, and location from: \"Let's meet next Thursday at 3pm at the downtown office on 5th street.\""
  "Summarize the plot of Romeo and Juliet in 3 sentences."
  "Given a paragraph about a company's Q2 earnings (model should ask or assume a generic example if none given), extract just the revenue figure and growth percentage."
  "Write a short, friendly email declining a meeting invite due to a scheduling conflict."
  "Write a two-sentence product description for a reusable water bottle."
  "Explain what a \"large language model\" is to a curious 10-year-old."
  "How do I check how much free disk space is left on a Linux server?"
  "What command shows currently running processes, and how do I kill one by its PID?"
  "How do I view the last 50 lines of a log file, and keep watching it live as new lines are added?"
  "How do I create a new user, add them to the sudo group, and set their password, all from the command line?"
  "Explain how to create a systemd service that starts a custom script on boot and restarts it if it crashes."
  "How do I schedule a script to run every day at 2am using cron, and where do I check if it actually ran?"
  "A server's firewall (using firewalld or ufw) needs to allow inbound traffic on port 8080. Walk through the commands."
  "A Linux server is showing high load average but low CPU usage in top. What are the likely causes, and what tools would you use to diagnose it further?"
  "Explain the difference between major and minor page faults, and what it means if major page faults spike dramatically during normal operation."
  "Walk through hardening SSH on a public-facing server: at minimum, disabling password auth, changing the default port, and restricting login to a specific user."
  "A process's memory usage keeps growing until the OOM killer terminates it. What steps would you take to identify whether this is a memory leak vs. legitimate high memory need, and what tools would you use?"
)

# Reference Answers / Grading Hints (index 1-30)
HINTS=(
  "" # 1-based indexing alignment
  "Mentions Canberra as capital; notes compromise between Sydney/Melbourne."
  "Mercury, Venus, Earth, Mars, Jupiter, Saturn, Uranus, Neptune. Identifies Saturn."
  "Strictly 2 sentences. Differentiates weather (short-term) vs climate (long-term)."
  "Correct Answer: 'acknowledged' (strictly no extra text or quotes)."
  "Correct Answer: 9"
  "Correct Answer: 80 km/h"
  "Correct Answer: x = 5"
  "Correct Answer: Bob = \$12.50, Alice = \$25.00, Carol = \$22.50"
  "Uses cache wrapper/dict/@functools.lru_cache or DP array; handles base cases."
  "Valid JSON only: {\"name\": \"Sam\", \"age\": 34, \"hobbies\": [\"reading\", \"cycling\"]}"
  "find /var/log -type f -name \"*.log\" -size +100M"
  "Change '-' to '+' (return a + b)."
  "Strictly 1 sentence. Includes Q3 overruns, hiring freeze, Q1 delay."
  "Date: Next Thursday | Time: 3pm | Location: Downtown office on 5th street"
  "Strictly 3 sentences. Mentions rival families, lovers, secret marriage, tragedy."
  "Identifies missing data or creates sample text; extracts revenue ($) and growth (%)."
  "Polite tone, declines, cites schedule conflict, proposes alternative."
  "Strictly 2 sentences. Highlights benefits (e.g., eco-friendly, insulation)."
  "Kid-friendly analogies (autocomplete/big reader); avoids jargon."
  "df -h"
  "Process list: ps aux or top/htop | Kill: kill <PID> or kill -9 <PID>"
  "tail -n 50 -f /path/to/logfile"
  "Uses useradd/adduser, usermod -aG sudo (or wheel), and passwd."
  "Covers /etc/systemd/system/ service unit, ExecStart, Restart=always/on-failure."
  "Cron syntax: 0 2 * * * /script.sh | Check: /var/log/syslog, /var/log/cron, or journalctl."
  "ufw allow 8080/tcp OR firewall-cmd --add-port=8080/tcp --permanent & reload."
  "Identifies I/O wait (D state) or lock contention. Tools: iostat, iotop, vmstat."
  "Explains minor (RAM) vs major (Disk/swap). Spike = disk thrashing/swapping."
  "sshd_config: PasswordAuthentication no, Port <new>, AllowUsers <user>, restart sshd."
  "Distinguishes growth vs workload; tools: valgrind, gdb, pmap, memray, Prometheus."
)

# Helper function to sanitize raw output into single-line markdown text
clean_markdown() {
  local text="$1"
  text="${text//\|/\\|}" # Escape markdown table pipes
  echo "$text" | tr '\n' ' ' | tr '\r' ' ' | sed -E 's/[[:space:]]+/ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ------------------------------------------------------------------------------
# Model Verification & Download Step
# ------------------------------------------------------------------------------
echo "=================================================================="
echo "Step 1: Checking existing models / Downloading via curl to $MODEL_DIR"
echo "=================================================================="

for MODEL_NAME in "${!MODEL_URLS[@]}"; do
  URL="${MODEL_URLS[$MODEL_NAME]}"
  FILENAME=$(basename "$URL")
  FILE_PATH="$MODEL_DIR/$FILENAME"

  echo "Checking $MODEL_NAME ($FILENAME)..."

  # Fetch the remote file size in bytes via HTTP HEAD headers
  REMOTE_SIZE=$(curl -sIL "$URL" | grep -i "content-length:" | tail -n1 | awk '{print $2}' | tr -d '\r')

  if [[ -f "$FILE_PATH" && -n "$REMOTE_SIZE" ]]; then
    LOCAL_SIZE=$(stat -c%s "$FILE_PATH" 2>/dev/null || stat -f%z "$FILE_PATH" 2>/dev/null)

    if [[ "$LOCAL_SIZE" -eq "$REMOTE_SIZE" ]]; then
      echo " -> File already complete ($LOCAL_SIZE bytes). Skipping download."
      continue
    else
      echo " -> Partial or mismatched download detected (Local: ${LOCAL_SIZE:-0} / Remote: $REMOTE_SIZE). Resuming download..."
    fi
  else
    echo " -> Model not found locally. Starting download..."
  fi

  # Download model while allowing resumed transfers (-C -)
  curl -L -C - --progress-bar "$URL" -o "$FILE_PATH"
done

# ------------------------------------------------------------------------------
# Evaluation Step
# ------------------------------------------------------------------------------
echo "=================================================================="
echo "Step 2: Running Evaluation Questions and generating Log Files"
echo "=================================================================="

for MODEL_NAME in "${!MODEL_URLS[@]}"; do
  URL="${MODEL_URLS[$MODEL_NAME]}"
  FILENAME=$(basename "$URL")
  FILE_PATH="$MODEL_DIR/$FILENAME"

  SAN_NAME=$(echo "$MODEL_NAME" | tr ' ' '_')
  LOG_FILE="$OUTPUT_DIR/${SAN_NAME}_results.md"

  echo "# Evaluation Results: $MODEL_NAME" > "$LOG_FILE"
  echo "" >> "$LOG_FILE"
  echo "| # | Question Prompt | Correct Answer / Grading Hints | Model Response | Grade |" >> "$LOG_FILE"
  echo "| :--- | :--- | :--- | :--- | :--- |" >> "$LOG_FILE"

  echo "Evaluating model: $MODEL_NAME..."

  for i in $(seq 1 30); do
    PROMPT="${QUESTIONS[$i]}"
    HINT="${HINTS[$i]}"

    echo "  [Q$i/30] Running inference..."

    # Ensure output file is clean before running
    rm -f output.txt

    # Run inference with llama-cli in single-turn mode (-st) outputting to text file
    llama-cli -m "$FILE_PATH" \
      -c "$CTX_SIZE" \
      --temp "$TEMP" \
      -t "$THREADS" \
      -n 1024 \
      -st \
      -p "$PROMPT" \
      -o output.txt > /dev/null 2>&1 || echo "[Execution Error - CLI Crashed]"

    # Extract model output using awk
    if [[ -f "output.txt" ]]; then
      RAW_OUTPUT=$(awk '/Assistant:/{flag=1; next} flag' output.txt)
      if [[ -z "$RAW_OUTPUT" ]]; then
        RAW_OUTPUT=$(cat output.txt)
      fi
    else
      RAW_OUTPUT="[Execution Failed - output.txt not generated]"
    fi

    CLEAN_PROMPT=$(clean_markdown "$PROMPT")
    CLEAN_HINT=$(clean_markdown "$HINT")
    CLEAN_RESPONSE=$(clean_markdown "$RAW_OUTPUT")

    # Log to table with an empty column for 'Grade'
    echo "| **$i** | $CLEAN_PROMPT | $CLEAN_HINT | $CLEAN_RESPONSE | |" >> "$LOG_FILE"
  done

  # Clean up temporary output file
  rm -f output.txt

  echo "Finished $MODEL_NAME. Saved results to $LOG_FILE"
done

echo "=================================================================="
echo "Complete! All evaluation files written to: $OUTPUT_DIR"
echo "=================================================================="

#!/usr/bin/env bash
# compare_decision_models.sh
# Benchmarks decision models on llama.cpp router (port 9931).
# Every request specifies the model in the body. Timer includes cold-load time.

set -uo pipefail

# ---------- CONFIG ----------
BASE_URL="http://10.10.0.5:9931"
BASE_URL_THINKLESS="http://10.10.0.5:9933"
RESULTS_DIR="./decision_bench"
mkdir -p "$RESULTS_DIR"
SUMMARY_CSV="$RESULTS_DIR/summary.csv"
COMBINED_CSV="$RESULTS_DIR/all_results.csv"

# Model IDs as the router knows them. Verify with:
#   curl -s http://10.10.0.5:9931/v1/models | jq -r '.data[].id'
MODEL_QWEN4B="Qwen3.5-4B-Q4_K_M"
MODEL_QWEN2B="Qwen3.5-2B-Q4_K_M"
MODEL_LAYA="Laya-Q8_0"
MODEL_D1="d1-3B-Q4_K_M"

MAX_TIME=500   # seconds; cold load of a 4B on CPU can take a while

# ---------- TEST SET ----------
# Format: entity_a|entity_b|label   (1 = same concept, 0 = different)
#
# Labeling rule (per user):
#   * Case, plural, and multi-word-case variants of the SAME string  → 1
#   * A protocol/concept vs its daemon/implementation/tool          → 0
#     (e.g. ssh vs sshd, dns vs named, http vs httpd, ftp vs vsftpd)
#   * Different protocols, tools, ports, chain names, or roles      → 0
TEST_SET=(
  # ─── Case-only variants (→ 1) ───────────────────────────────────
  "ssh|SSH|1"
  "http|HTTP|1"
  "ftp|FTP|1"
  "smtp|SMTP|1"
  "imap|IMAP|1"
  "ldap|LDAP|1"
  "dns|DNS|1"
  "nfs|NFS|1"
  "cifs|CIFS|1"
  "tcp|TCP|1"
  "ipv4|IPv4|1"
  "iptables|Iptables|1"
  "iptables|IPtables|1"
  "httpd|Httpd|1"
  "httpd|HTTPD|1"
  "named|Named|1"
  "postfix|Postfix|1"
  "dovecot|Dovecot|1"
  "samba|Samba|1"
  "openssh|OpenSSH|1"
  "netstat|Netstat|1"
  "sshd|SSHD|1"
  "firewall|Firewall|1"
  "ports|Ports|1"
  "protocols|Protocols|1"
  "services|Services|1"
  "client|Client|1"
  "server|Server|1"

  # ─── Plural variants (→ 1) ──────────────────────────────────────
  "firewall|firewalls|1"
  "Firewall|Firewalls|1"
  "Stateful Firewall|Stateful Firewalls|1"
  "Stateless Firewall|Stateless Firewalls|1"
  "Port|Ports|1"
  "Service|Services|1"
  "Protocol|Protocols|1"
  "Rule|Rules|1"
  "Chain|Chains|1"
  "Table|Tables|1"

  # ─── Multi-word case variants (→ 1) ─────────────────────────────
  "Network Firewall|network firewall|1"
  "Host Firewall|host firewall|1"
  "Stateful Firewall|stateful firewall|1"
  "Stateless Firewall|stateless firewall|1"
  "Perimeter Firewall|perimeter firewall|1"
  "Internal Firewall|internal firewall|1"
  "DMZ|dmz|1"
  "filter Table|Filter Table|1"
  "nat Table|NAT Table|1"
  "mangle Table|Mangle Table|1"
  "raw Table|Raw Table|1"

  # ─── Port number case variants (→ 1) ────────────────────────────
  "Port 22|port 22|1"
  "Port 25|port 25|1"
  "Port 53|port 53|1"
  "Port 80|port 80|1"
  "Port 143|port 143|1"
  "Port 389|port 389|1"
  "Port 443|port 443|1"
  "Port 445|port 445|1"
  "Port 2049|port 2049|1"
  "Port 21|port 21|1"

  # ─── Protocol/concept vs daemon/tool (→ 0) ← KEY RULE ───────────
  "ssh|sshd|0"
  "dns|named|0"
  "http|httpd|0"
  "ftp|vsftpd|0"
  "smtp|postfix|0"
  "smtp|master|0"
  "imap|dovecot|0"
  "ldap|openldap|0"
  "nfs|nfs-utils|0"
  "cifs|samba|0"
  "ssh|openssh|0"
  "ssh|OpenSSH|0"

  # ─── Different tools that serve similar purposes (→ 0) ──────────
  "iptables|ip6tables|0"
  "iptables|ufw|0"
  "netstat|ss|0"
  "netstat|netcat|0"
  "netstat|nc|0"
  "ss|nc|0"
  "lsof|netstat|0"
  "ping|netstat|0"
  "journalctl|systemctl|0"
  "systemctl|systemd|0"
  "vsftpd|proftpd|0"
  "postfix|sendmail|0"
  "dovecot|cyrus|0"
  "named|dnsmasq|0"

  # ─── Different protocols entirely (→ 0) ─────────────────────────
  "ssh|ssl|0"
  "http|https|0"
  "dns|dnssec|0"
  "tcp|udp|0"
  "ipv4|ipv6|0"
  "nfs|smb|0"
  "ftp|smtp|0"
  "http|ftp|0"

  # ─── Different ports (→ 0) ──────────────────────────────────────
  "Port 22|Port 80|0"
  "Port 80|Port 443|0"
  "Port 143|Port 389|0"
  "Port 389|Port 445|0"
  "Port 445|Port 2049|0"
  "Port 2049|Port 53|0"
  "Port 53|Port 22|0"
  "Port 25|Port 143|0"
  "Port 443|Port 22|0"

  # ─── Related but distinct concepts (→ 0) ────────────────────────
  "Client|Server|0"
  "Server|Service|0"
  "Firewall|Network Firewall|0"
  "Firewall|Host Firewall|0"
  "Stateful Firewall|Stateless Firewall|0"
  "Perimeter Firewall|Internal Firewall|0"
  "Internal Firewall|External Firewall|0"
  "Security|Compliance|0"
  "Ports|Protocols|0"
  "DMZ|VPN|0"
  "ACCEPT|DROP|0"
  "LISTEN|ESTABLISHED|0"
  "INPUT|OUTPUT|0"
  "INPUT Chain|OUTPUT Chain|0"
  "IPv4 connections|IPv6 connections|0"

  # ─── Entries from kv_store_full_entities.json (mixed) ───────────
  "Cleint|Client|1"                            # typo of same concept → merge
  "/var/log/syslog|/var/log/messages|0"        # different log files
  "authorized traffic|malicious traffic|0"     # different concepts
  "demilitarized zone|DMZ|1"                   # expansion of same acronym
  "active Internet connections|listening ports|0"
  "network connections|network services|0"
  "Service Access|service access|1"            # case variant
  "performance measurement|performance measurements|1"  # plural
)

# TEST_SET=(
#   # === A. Prefix / tool traps (0) — d1's weakness ===
#   "dns|dnssec|0"
#   "bind|bind9|0"
#   "nginx|nginx.conf|0"
#   "ssh|ssh-agent|0"
#   "ssh|ssh-keygen|0"
#   "git|github|0"
#   "java|javascript|0"
#   "sql|sqlite|0"
#   "postgres|postgrest|0"
#   "docker|dockerd|0"
#   "containerd|container|0"
#   "iptables|ip6tables|0"
#   "cron|crontab|0"
#   "log|logger|0"
#   "hash|hashtable|0"
#   "stack|stackoverflow|0"
#   "queue|priority_queue|0"
#   "tree|treewalk|0"
#
#   # === B. Broader / narrower concept traps (0) — d1's weakness ===
#   "Firewall|Network Firewall|0"
#   "Firewall|Host Firewall|0"
#   "Firewall|Personal Firewall|0"
#   "Server|Web Server|0"
#   "Service|Web Service|0"
#   "Network|Subnet|0"
#   "Protocol|TCP|0"
#   "User|Admin User|0"
#   "File|Log File|0"
#   "Rule|Firewall Rule|0"
#   "Table|Filter Table|0"
#   "Packet|IP Packet|0"
#   "Connection|TCP Connection|0"
#   "Address|IP Address|0"
#   "Port|Port Range|0"
#
#   # === C. Typos / character-level variants (1) — qwen4b's weakness ===
#   "Cleint|Client|1"
#   "Firewal|Firewall|1"
#   "Adddress|Address|1"
#   "Protcol|Protocol|1"
#   "Netowrk|Network|1"
#   "Apche|Apache|1"
#   "Postgress|Postgres|1"
#   "nginix|nginx|1"
#   "systemctl|sytemctl|1"
#   "iptabels|iptables|1"
#
#   # === D. Acronym expansions (1) ===
#   "DMZ|Demilitarized Zone|1"
#   "VPN|Virtual Private Network|1"
#   "NIC|Network Interface Card|1"
#   "HTTP|HyperText Transfer Protocol|1"
#   "DNS|Domain Name System|1"
#   "SSH|Secure Shell|1"
#   "FTP|File Transfer Protocol|1"
#   "TCP|Transmission Control Protocol|1"
#
#   # === E. Multi-word case variants (1) — sanity ===
#   "Network Firewall|network firewall|1"
#   "Host Firewall|host firewall|1"
#   "Stateful Firewall|stateful firewall|1"
#   "Stateless Firewall|stateless firewall|1"
#   "Perimeter Firewall|perimeter firewall|1"
#   "Internal Firewall|internal firewall|1"
#   "filter Table|Filter Table|1"
#   "nat Table|NAT Table|1"
#   "mangle Table|Mangle Table|1"
#   "raw Table|Raw Table|1"
#   "Service Access|service access|1"
#   "Network Setup Verification|network setup verification|1"
#
#   # === F. Plural variants (1) — sanity ===
#   "firewall|firewalls|1"
#   "Firewall|Firewalls|1"
#   "Port|Ports|1"
#   "Service|Services|1"
#   "Protocol|Protocols|1"
#   "Rule|Rules|1"
#   "Chain|Chains|1"
#   "Table|Tables|1"
#   "Connection|Connections|1"
#   "Address|Addresses|1"
#
#   # === G. Semantic near-misses (0) ===
#   "Security|Safety|0"
#   "Latency|Throughput|0"
#   "Latency|Bandwidth|0"
#   "Route|Router|0"
#   "Log|Logger|0"
#   "Load

TOTAL=${#TEST_SET[@]}
echo "Test set: $TOTAL pairs"
echo ""

# ---------- HELPERS ----------
now_ms() { date +%s%3N; }

# Decision models via /v1/systemone (d1, Laya)
ask_systemone() {
  local model="$1" a="$2" b="$3"
  curl -s --max-time "$MAX_TIME" "$BASE_URL/v1/systemone" \
    -H "Content-Type: application/json" \
    -d "{ \"model\": \"$model\", \"state\": {\"entity_a\": \"$a\", \"entity_b\": \"$b\"}, \"questions\": { \"merge\": { \"type\": \"noul\", \"instructions\": \"Are these two entities the same concept?\" } } }" \
  | jq -r '.answers.merge.noul // "ERR"'
}

# Qwen thinking model via /v1/chat/completions on 9931
ask_qwen4b() {
  local model="$1" a="$2" b="$3"
  local prompt="Are these two entities the same concept? Answer only yes or no. \n Entity A: $a \n Entity B: $b \n Answer:"
  curl -s --max-time "$MAX_TIME" "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"$model\",\"messages\": [{\"role\": \"user\", \"content\": \"$prompt\"}],\"max_tokens\": 2048,\"temperature\": 0.6}" \
    | jq -r '.choices[0].message.content // "ERR"' \
    | tr -d '\n\r' | tr '[:upper:]' '[:lower:]'
}

# Qwen non-thinking model via /v1/chat/completions on 9933
ask_qwen4b_thinkless() {
  local model="$1" a="$2" b="$3"
  local prompt="Are these two entities the same concept? Answer only yes or no. \n Entity A: $a \n Entity B: $b \n Answer:"
  curl -s --max-time "$MAX_TIME" "$BASE_URL_THINKLESS/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"$model\",\"messages\": [{\"role\": \"user\", \"content\": \"$prompt\"}],\"max_tokens\": 4,\"temperature\": 0}" \
    | jq -r '.choices[0].message.content // "ERR"' \
    | tr -d '\n\r' | tr '[:upper:]' '[:lower:]'
}

# Normalize any model output to 0 / 1 / ERR
normalize() {
  local raw="$1"
  case "$raw" in
    yes|1|true)  echo 1 ;;
    no|0|false)  echo 0 ;;
    ERR|"")      echo ERR ;;
    *)
      if [[ "$raw" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        awk -v p="$raw" 'BEGIN{ print (p >= 0.5) ? 1 : 0 }'
      else
        echo ERR
      fi
      ;;
  esac
}

# ---------- RUN ONE MODEL ----------
run_model() {
  local name="$1" model="$2" fn="$3"
  local out="$RESULTS_DIR/${name}.csv"
  echo "model,pair_index,entity_a,entity_b,label,raw,decision,latency_ms,is_first" > "$out"

  local correct=0 wrong=0 errs=0
  local first_latency=""
  local sum_after_first=0 count_after_first=0

  local wall_start wall_end
  wall_start=$(now_ms)

  local i=0
  for entry in "${TEST_SET[@]}"; do
    IFS='|' read -r a b label <<< "$entry"
    local start end lat raw decision
    start=$(now_ms)
    raw=$($fn "$model" "$a" "$b")
    end=$(now_ms)
    lat=$((end - start))
    decision=$(normalize "$raw")

    local is_first=0
    if [[ $i -eq 0 ]]; then
      is_first=1
      first_latency=$lat
    else
      sum_after_first=$((sum_after_first + lat))
      count_after_first=$((count_after_first + 1))
    fi

    if [[ "$decision" == "ERR" ]]; then
      errs=$((errs + 1))
    elif [[ "$decision" == "$label" ]]; then
      correct=$((correct + 1))
    else
      wrong=$((wrong + 1))
    fi

    echo "${name},${i},${a},${b},${label},${raw},${decision},${lat},${is_first}" >> "$out"
    printf "  [%3d/%3d] %-25s vs %-25s label=%s decision=%s (%d ms)\n" \
      $((i+1)) "$TOTAL" "$a" "$b" "$label" "$decision" "$lat"
    i=$((i + 1))
  done

  wall_end=$(now_ms)
  local wall_total=$((wall_end - wall_start))
  local avg_after=0
  if [[ $count_after_first -gt 0 ]]; then
    avg_after=$((sum_after_first / count_after_first))
  fi
  local acc
  acc=$(awk "BEGIN{printf \"%.2f\", $correct/$TOTAL}")

  echo "" | tee -a "$RESULTS_DIR/console.log"
  echo "  → ${name}: ${correct}/${TOTAL} correct (${acc}), ${wrong} wrong, ${errs} ERR" | tee -a "$RESULTS_DIR/console.log"
  echo "    load+first_inference: ${first_latency} ms" | tee -a "$RESULTS_DIR/console.log"
  echo "    avg_inference (2..N): ${avg_after} ms" | tee -a "$RESULTS_DIR/console.log"
  echo "    wall_total:           ${wall_total} ms" | tee -a "$RESULTS_DIR/console.log"
  echo "" | tee -a "$RESULTS_DIR/console.log"

  echo "${name},${correct},${wrong},${errs},${acc},${first_latency},${avg_after},${wall_total}" >> "$SUMMARY_CSV"
}

# ---------- MAIN ----------
echo "model,correct,wrong,errs,accuracy,load_first_ms,avg_inference_ms,wall_total_ms" > "$SUMMARY_CSV"
: > "$RESULTS_DIR/console.log"

echo "=== Qwen3.5-4B (thinking) ==="
run_model "qwen4b" "$MODEL_QWEN4B" ask_qwen4b

echo "=== Qwen3.5-2B (thinking) ==="
run_model "qwen2b" "$MODEL_QWEN2B" ask_qwen4b

echo "=== Qwen3.5-4B (thinkless, 9933) ==="
run_model "qwen4b_thinkless" "$MODEL_QWEN4B" ask_qwen4b_thinkless

echo "=== Qwen3.5-2B (thinkless, 9933) ==="
run_model "qwen2b_thinkless" "$MODEL_QWEN2B" ask_qwen4b_thinkless

echo "=== Laya ==="
run_model "laya" "$MODEL_LAYA" ask_systemone

echo "=== d1-3B ==="
run_model "d1" "$MODEL_D1" ask_systemone

# Combine per-model CSVs (skip header lines)
{
  echo "model,pair_index,entity_a,entity_b,label,raw,decision,latency_ms,is_first"
  for f in "$RESULTS_DIR"/qwen4b.csv "$RESULTS_DIR"/qwen2b.csv \
           "$RESULTS_DIR"/qwen4b_thinkless.csv "$RESULTS_DIR"/qwen2b_thinkless.csv \
           "$RESULTS_DIR"/laya.csv "$RESULTS_DIR"/d1.csv; do
    [[ -f "$f" ]] && tail -n +2 "$f"
  done
} > "$COMBINED_CSV"

echo ""
echo "============================================================"
echo "Summary (accuracy | load+first ms | avg_inference ms | wall ms)"
echo "============================================================"
column -t -s, "$SUMMARY_CSV"
echo ""
echo "Per-model CSVs:  $RESULTS_DIR/<model>.csv"
echo "Combined CSV:    $COMBINED_CSV"
echo "Summary CSV:     $SUMMARY_CSV"

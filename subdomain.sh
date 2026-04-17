#!/bin/bash

# =========================
# STRICT MODE
# =========================
set -euo pipefail

# =========================
# TOOL CHECK
# =========================
REQUIRED_TOOLS=(
    subfinder
    assetfinder
    amass
    httpx
    curl
    jq
)

echo "[*] Checking required tools..."

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        echo "[-] Error: $tool is not installed"
        exit 1
    fi
done

echo "[+] All required tools are installed"

# Optional tool
if command -v chaos &>/dev/null; then
    HAS_CHAOS=true
    echo "[+] chaos found"
else
    HAS_CHAOS=false
    echo "[!] chaos not found (skipping)"
fi

# =========================
# INPUT
# =========================
if [[ -z "${1:-}" ]]; then
    echo "Usage:"
    echo "  $0 example.com"
    echo "  $0 domains.txt"
    exit 1
fi

INPUT=$1

if [[ -f "$INPUT" ]]; then
    TARGETS=$(cat "$INPUT")
else
    TARGETS=$INPUT
fi

OUTPUT_DIR="subdomains"
mkdir -p "$OUTPUT_DIR"

# =========================
# MAIN LOOP
# =========================
for TARGET in $TARGETS; do

    echo "========================================"
    echo "[+] Target: $TARGET"

    TMP=$(mktemp)
    TMP_LIVE=$(mktemp)

    # =========================
    # PASSIVE ENUM
    # =========================
    echo "[*] Collecting subdomains..."

    subfinder -d "$TARGET" -silent >> "$TMP"
    assetfinder --subs-only "$TARGET" >> "$TMP"
    amass enum -passive -d "$TARGET" >> "$TMP"

    # crt.sh (clean + controlled)
    echo "[*] Fetching crt.sh..."

    curl -s "https://crt.sh/?q=%25.$TARGET&output=json" | \
    jq -r '.[].name_value' 2>/dev/null | \
    sed 's/\*\.//g' | \
    sort -u | \
    head -n 10000 >> "$TMP"   # LIMIT to avoid explosion

    # chaos (optional)
    if $HAS_CHAOS; then
        chaos -d "$TARGET" -silent >> "$TMP"
    fi

    # =========================
    # CLEAN + UNIQUE
    # =========================
    sort -u "$TMP" > "$TMP.clean"

    COUNT=$(wc -l < "$TMP.clean")
    echo "[+] Total collected: $COUNT"

    if [[ "$COUNT" -eq 0 ]]; then
        echo "[-] No subdomains found"
        rm -f "$TMP" "$TMP.clean"
        continue
    fi

    # =========================
    # LIVE PROBING (FAST MODE)
    # =========================
    echo "[*] Probing live hosts (fast mode)..."

    httpx -l "$TMP.clean" \
        -ports 80,443 \
        -threads 500 \
        -timeout 5 \
        -retries 1 \
        -silent > "$TMP_LIVE"

    LIVE_COUNT=$(wc -l < "$TMP_LIVE")

    if [[ "$LIVE_COUNT" -eq 0 ]]; then
        echo "[-] No live hosts"
        rm -f "$TMP" "$TMP.clean" "$TMP_LIVE"
        continue
    fi

    # =========================
    # SAVE FINAL
    # =========================
    OUTPUT_FILE="$OUTPUT_DIR/$TARGET.txt"
    sort -u "$TMP_LIVE" > "$OUTPUT_FILE"

    echo "[+] Live subdomains: $LIVE_COUNT"
    echo "[✔] Saved: $OUTPUT_FILE"

    # =========================
    # CLEANUP
    # =========================
    rm -f "$TMP" "$TMP.clean" "$TMP_LIVE"

    echo

done

#!/bin/bash

# =========================
# STRICT MODE (FAIL FAST)
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
    dnsgen
    puredns
    curl
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
# INPUT HANDLING
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

RESOLVERS="resolvers.txt"

# =========================
# RESOLVER SETUP
# =========================
if [[ ! -f "$RESOLVERS" ]]; then
    echo "[*] Creating resolvers.txt..."

    cat <<EOF > "$RESOLVERS"
1.1.1.1
1.0.0.1
8.8.8.8
8.8.4.4
9.9.9.9
149.112.112.112
208.67.222.222
208.67.220.220
EOF
fi

# Enrich resolvers (safe)
curl -s https://raw.githubusercontent.com/trickest/resolvers/main/resolvers.txt \
    | head -n 50 >> "$RESOLVERS" 2>/dev/null || true

sort -u "$RESOLVERS" -o "$RESOLVERS"

echo "[+] Total resolvers: $(wc -l < $RESOLVERS)"

# =========================
# MAIN LOOP
# =========================
for TARGET in $TARGETS; do

    echo "========================================"
    echo "[+] Target: $TARGET"

    TMP_PASSIVE=$(mktemp)
    TMP_PERM=$(mktemp)
    TMP_RESOLVED=$(mktemp)
    TMP_LIVE=$(mktemp)

    # =========================
    # PASSIVE ENUMERATION
    # =========================
    echo "[*] Passive collection..."

    subfinder -d "$TARGET" -silent >> "$TMP_PASSIVE"
    assetfinder --subs-only "$TARGET" >> "$TMP_PASSIVE"
    amass enum -passive -d "$TARGET" >> "$TMP_PASSIVE"

    curl -s "https://crt.sh/?q=%25.$TARGET&output=json" | \
    grep -oE '"name_value":"[^"]+"' | \
    cut -d':' -f2 | tr -d '"' | \
    sed 's/\\n/\n/g' >> "$TMP_PASSIVE"

    if $HAS_CHAOS; then
        chaos -d "$TARGET" -silent >> "$TMP_PASSIVE"
    fi

    sort -u "$TMP_PASSIVE" | sed 's/\*\.//' > "$TMP_PASSIVE.clean"

    COUNT_PASSIVE=$(wc -l < "$TMP_PASSIVE.clean")
    echo "[+] Passive: $COUNT_PASSIVE"

    if [[ "$COUNT_PASSIVE" -eq 0 ]]; then
        echo "[-] No subdomains found"
        rm -f $TMP_PASSIVE*
        continue
    fi

    # =========================
    # PERMUTATION
    # =========================
    echo "[*] Generating permutations..."

    dnsgen "$TMP_PASSIVE.clean" > "$TMP_PERM"
    cat "$TMP_PASSIVE.clean" "$TMP_PERM" | sort -u > "$TMP_PERM.all"

    echo "[+] After permutation: $(wc -l < "$TMP_PERM.all")"

    # =========================
    # RESOLUTION
    # =========================
    echo "[*] Resolving..."

    if ! puredns resolve "$TMP_PERM.all" \
        --resolvers "$RESOLVERS" \
        --quiet > "$TMP_RESOLVED"; then

        echo "[-] puredns failed. Stopping."
        exit 1
    fi

    COUNT_RESOLVED=$(wc -l < "$TMP_RESOLVED")
    echo "[+] Valid: $COUNT_RESOLVED"

    if [[ "$COUNT_RESOLVED" -eq 0 ]]; then
        echo "[-] Nothing resolved"
        rm -f $TMP_PASSIVE* $TMP_PERM* $TMP_RESOLVED
        continue
    fi

    # =========================
    # LIVE PROBING
    # =========================
    echo "[*] Probing live..."

    if ! httpx -l "$TMP_RESOLVED" \
        -ports 80,443,8080,8000,8888 \
        -threads 200 \
        -silent > "$TMP_LIVE"; then

        echo "[-] httpx failed. Stopping."
        exit 1
    fi

    COUNT_LIVE=$(wc -l < "$TMP_LIVE")

    if [[ "$COUNT_LIVE" -eq 0 ]]; then
        echo "[-] No live hosts"
        rm -f $TMP_PASSIVE* $TMP_PERM* $TMP_RESOLVED $TMP_LIVE
        continue
    fi

    # =========================
    # SAVE FINAL OUTPUT
    # =========================
    OUTPUT_FILE="$OUTPUT_DIR/$TARGET.txt"
    sort -u "$TMP_LIVE" > "$OUTPUT_FILE"

    echo "[+] Live subdomains: $COUNT_LIVE"
    echo "[✔] Saved: $OUTPUT_FILE"

    # =========================
    # CLEANUP
    # =========================
    rm -f $TMP_PASSIVE* $TMP_PERM* $TMP_RESOLVED $TMP_LIVE

    echo

done

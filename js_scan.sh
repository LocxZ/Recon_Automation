#!/bin/bash

set -uo pipefail

# =========================
# COLORS
# =========================
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
RESET="\033[0m"

section() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BLUE}[+] $1${RESET}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

good() { echo -e "${GREEN}[✔] $1${RESET}"; }
warn() { echo -e "${YELLOW}[!] $1${RESET}"; }
bad() { echo -e "${RED}[✘] $1${RESET}"; }

# =========================
# TOOL CHECK
# =========================
section "Checking Tools"

MISSING=0

check_tool() {
    if command -v "$1" >/dev/null 2>&1; then
        good "$1 found"
    else
        bad "$1 missing"
        MISSING=1
    fi
}

check_tool gau
check_tool katana
check_tool httpx
check_tool curl
check_tool python3

[[ ! -f ~/tools/LinkFinder/linkfinder.py ]] && bad "LinkFinder missing" && MISSING=1 || good "LinkFinder found"
[[ ! -f ~/tools/SecretFinder/SecretFinder.py ]] && bad "SecretFinder missing" && MISSING=1 || good "SecretFinder found"

[[ "$MISSING" -eq 1 ]] && bad "Fix tools first" && exit 1

# =========================
# INPUT
# =========================
[[ -z "${1:-}" ]] && bad "Usage: $0 subdomains.txt" && exit 1
SUBS=$1

TMP_ALL=$(mktemp)
TMP_JS=$(mktemp)
TMP_LIVE=$(mktemp)

# =========================
# COLLECTION
# =========================
section "Collecting JS"

cat "$SUBS" | gau --threads 50 >> "$TMP_ALL"
cat "$SUBS" | katana -silent -jc -d 2 >> "$TMP_ALL"

grep -E "\.js($|\?)" "$TMP_ALL" | sed 's/?.*//' | sort -u > "$TMP_JS"

good "JS found: $(wc -l < "$TMP_JS")"

# =========================
# LIVE FILTER
# =========================
section "Filtering Live JS"

httpx -l "$TMP_JS" -silent -threads 200 > "$TMP_LIVE"
good "Live JS: $(wc -l < "$TMP_LIVE")"

# =========================
# ANALYSIS
# =========================
section "Extracting Signals"

> raw.txt

analyze_js() {
    js="$1"

    content=$(curl -s --max-time 10 "$js" | head -c 400000 || echo "")

    # URLs
    echo "$content" | grep -oE 'https?://[^"'\'' ]+' >> raw.txt

    # endpoints
    echo "$content" | grep -oE '/(api|admin|internal|auth)[a-zA-Z0-9_/.-]*' >> raw.txt

    # params
    echo "$content" | grep -oE '[?&][a-zA-Z0-9_]+=' | sed 's/[?&]//' >> raw.txt

    # secrets
    echo "$content" | grep -iE \
    "api[_-]?key|secret|token|password|bearer|authorization" \
    >> raw.txt

    # linkfinder
    timeout 15 python3 ~/tools/LinkFinder/linkfinder.py -i "$js" -o cli >> raw.txt 2>/dev/null || true

    # secretfinder
    timeout 15 python3 ~/tools/SecretFinder/SecretFinder.py -i "$js" -o cli >> raw.txt 2>/dev/null || true
}

export -f analyze_js
cat "$TMP_LIVE" | xargs -P 10 -I {} bash -c 'analyze_js "$@"' _ {}

good "Extraction done"

# =========================
# ULTRA FILTER (REAL FIX)
# =========================
section "Filtering REAL Data (Anti-Garbage Engine)"

cat raw.txt | \
grep -Ei \
'^https?://|^/api|^/admin|^/internal|^/auth|token|key|secret|password|bearer|redirect|callback' | \
grep -vE \
'webpack|function\(|exports|__|react|jquery|bootstrap|\.js$|\.css|\.svg|\.png|\.jpg|\.woff|\.ttf|chunk|polyfill' | \
grep -vE \
'^[{}();,"'\''[:space:]]+$' | \
grep -vE \
'^[a-zA-Z0-9_]{1,25}$' | \
grep -vE \
'^[0-9]+$' | \
awk 'length($0) < 300' | \
sort -u > final_clean_js.txt

COUNT=$(wc -l < final_clean_js.txt)

if [[ "$COUNT" -eq 0 ]]; then
    warn "No useful data"
else
    good "Clean findings: $COUNT"
fi

good "Saved → final_clean_js.txt"

# =========================
# CLEANUP
# =========================
rm -f "$TMP_ALL" "$TMP_JS" "$TMP_LIVE" raw.txt

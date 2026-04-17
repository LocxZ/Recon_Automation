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
# RATE LIMIT CHECK
# =========================
check_rate_limit() {
    remaining=$(gh api rate_limit --jq '.rate.remaining')
    reset=$(gh api rate_limit --jq '.rate.reset')

    now=$(date +%s)
    wait_time=$((reset - now + 5))

    if [[ "$remaining" -lt 50 ]]; then
        warn "Low rate limit: $remaining requests left"
        warn "Sleeping for $wait_time seconds..."
        sleep "$wait_time"
    else
        good "Rate limit OK: $remaining remaining"
    fi
}

# =========================
# TOOL CHECK
# =========================
section "Checking Tools"

MISSING=0

check_tool() {
    command -v "$1" >/dev/null 2>&1 && good "$1 found" || { bad "$1 missing"; MISSING=1; }
}

check_tool git
check_tool gh
check_tool trufflehog
check_tool rg
check_tool python3

if [[ -f ~/tools/gitGraber/gitGraber.py ]]; then
    GITGRABER="python3 ~/tools/gitGraber/gitGraber.py"
    good "gitGraber found"
else
    bad "gitGraber missing"
    MISSING=1
fi

[[ "$MISSING" -eq 1 ]] && bad "Fix tools first" && exit 1

# =========================
# INPUT
# =========================
[[ -z "${1:-}" ]] && bad "Usage: $0 domain.txt" && exit 1
INPUT=$1

TMP_REPOS=$(mktemp)
TMP_CLONES="github_repos"
TMP_GITGRABBER=$(mktemp)
OUTPUT_RAW="github_raw.txt"

rm -rf "$TMP_CLONES"
mkdir "$TMP_CLONES"
> "$OUTPUT_RAW"

# =========================
# REPO SEARCH
# =========================
section "GitHub Repo Search"

while read domain; do
    check_rate_limit

    echo -e "${YELLOW}[*] Searching repos: $domain${RESET}"
    gh search repos "$domain" --limit 20 --json url -q '.[].url' >> "$TMP_REPOS"

done < "$INPUT"

sort -u "$TMP_REPOS" > repos.txt
good "Repos found: $(wc -l < repos.txt)"

# =========================
# CLONE
# =========================
section "Cloning Repos"

while read repo; do
    git clone --depth 1 "$repo" "$TMP_CLONES/$(basename "$repo")" >/dev/null 2>&1 || true
done < repos.txt

good "Cloning done"

# =========================
# gitGraber
# =========================
section "Running gitGraber"

while read domain; do
    check_rate_limit

    echo -e "${YELLOW}[*] gitGraber: $domain${RESET}"
    $GITGRABER -k "$domain" -n 15 >> "$TMP_GITGRABBER" 2>/dev/null || true

    sleep 2
done < "$INPUT"

cat "$TMP_GITGRABBER" >> "$OUTPUT_RAW"

good "gitGraber done"

# =========================
# TRUFFLEHOG
# =========================
section "Running TruffleHog"

trufflehog filesystem "$TMP_CLONES" --no-update >> "$OUTPUT_RAW" 2>/dev/null || true

good "TruffleHog done"

# =========================
# RG SCAN
# =========================
section "Running High-Signal Scan"

rg -i \
"api[_-]?key|secret|token|password|bearer|authorization|client_secret|private_key" \
"$TMP_CLONES" >> "$OUTPUT_RAW" 2>/dev/null || true

rg -oE 'https?://[^" ]+' "$TMP_CLONES" >> "$OUTPUT_RAW" 2>/dev/null || true

good "Scan done"

# =========================
# FILTER
# =========================
section "Filtering Juicy Data"

cat "$OUTPUT_RAW" | \
grep -Ei 'api|token|secret|key|password|bearer|auth|internal|aws|firebase' | \
grep -vE '\.png|\.jpg|\.svg|node_modules|vendor|test|example|sample|README' | \
grep -vE '^[a-zA-Z0-9_]{1,25}$' | \
sort -u > github_final.txt

good "Saved → github_final.txt"
good "Findings: $(wc -l < github_final.txt)"

# =========================
# CLEANUP
# =========================
rm -rf "$TMP_CLONES" "$TMP_REPOS" "$TMP_GITGRABBER" repos.txt "$OUTPUT_RAW"

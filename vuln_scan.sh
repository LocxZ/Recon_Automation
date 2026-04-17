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
hit() { echo -e "${RED}🔥 $1${RESET}"; }

# =========================
# TOOL CHECK
# =========================
section "Checking Tools"

MISSING=0

check_tool() {
    command -v "$1" >/dev/null 2>&1 && good "$1 found" || { bad "$1 missing"; MISSING=1; }
}

check_tool httpx
check_tool dalfox
check_tool curl
check_tool nuclei

[[ "$MISSING" -eq 1 ]] && bad "Install missing tools" && exit 1

# =========================
# INPUT
# =========================
if [[ -z "${1:-}" || -z "${2:-}" ]]; then
    bad "Usage: $0 urls.txt subdomains.txt"
    exit 1
fi

URLS=$1
SUBS=$2

> xss.txt
> redirect.txt
> takeover.txt
> ssrf.txt
> nuclei.txt

# =========================
# XSS
# =========================
section "XSS Scanning (Dalfox)"

cat "$URLS" | dalfox pipe \
--silence \
--no-color \
--skip-bav \
--only-poc \
-o xss.txt

good "XSS findings: $(wc -l < xss.txt)"

# =========================
# OPEN REDIRECT (FIXED)
# =========================
section "Open Redirect Scanning (Fixed)"

PAYLOADS=(
"https://evil.com"
"//evil.com"
"///evil.com"
"https:evil.com"
)

replace_param() {
    url="$1"
    payload="$2"
    echo "$url" | sed -E "s/(=)[^&]*/=\$PAYLOAD/g" | sed "s|\$PAYLOAD|$payload|g"
}

while read url; do

    [[ "$url" != *"="* ]] && continue

    for payload in "${PAYLOADS[@]}"; do

        test_url=$(replace_param "$url" "$payload")

        location=$(curl -s -I --max-time 10 "$test_url" | \
        grep -i "^Location:" | tr -d '\r')

        if echo "$location" | grep -q "evil.com"; then
            echo "$test_url" >> redirect.txt
            hit "Redirect → $test_url"
        fi

    done

done < "$URLS"

good "Redirect findings: $(wc -l < redirect.txt)"

# =========================
# SSRF (CANDIDATES)
# =========================
section "SSRF Candidate Extraction"

cat "$URLS" | grep -Ei \
'url=|uri=|redirect=|dest=|callback=|next=|return=' \
> ssrf.txt

good "SSRF candidates: $(wc -l < ssrf.txt)"

# =========================
# SUBDOMAIN TAKEOVER
# =========================
section "Subdomain Takeover Check"

cat "$SUBS" | httpx -silent -status-code -title | \
grep -Ei \
"not found|no such app|heroku|github pages|aws bucket|fastly error" \
> takeover.txt

good "Takeover candidates: $(wc -l < takeover.txt)"

# =========================
# NUCLEI
# =========================
section "Running Nuclei"

cat "$URLS" | nuclei \
-tags xss,redirect,ssrf,takeover \
-silent \
-o nuclei.txt

good "Nuclei findings: $(wc -l < nuclei.txt)"

# =========================
# SUMMARY
# =========================
section "Summary"

good "XSS → $(wc -l < xss.txt)"
good "Redirect → $(wc -l < redirect.txt)"
good "SSRF → $(wc -l < ssrf.txt)"
good "Takeover → $(wc -l < takeover.txt)"
good "Nuclei → $(wc -l < nuclei.txt)"

echo -e "${GREEN}All results saved in current directory${RESET}"

#!/bin/bash

set -euo pipefail

# =========================
# TOOL CHECK
# =========================
REQUIRED_TOOLS=(
    gau
    waybackurls
    katana
    httpx
    curl
    jq
)

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        echo "[-] $tool not installed"
        exit 1
    fi
done

# =========================
# INPUT
# =========================
if [[ -z "${1:-}" ]]; then
    echo "Usage:"
    echo "  $0 subdomains.txt"
    exit 1
fi

SUBS=$1

TMP_ALL=$(mktemp)
TMP_PARAM=$(mktemp)
TMP_DEDUP=$(mktemp)
TMP_LIVE=$(mktemp)

echo "[+] Collecting URLs..."

# =========================
# GAU (wayback + commoncrawl + otx)
# =========================
cat "$SUBS" | gau --threads 50 >> "$TMP_ALL"

# =========================
# WAYBACK (extra coverage)
# =========================
cat "$SUBS" | waybackurls >> "$TMP_ALL"

# =========================
# URLSCAN
# =========================
echo "[*] URLScan..."
while read -r domain; do
    curl -s "https://urlscan.io/api/v1/search/?q=domain:$domain" | \
    jq -r '.results[].page.url' 2>/dev/null >> "$TMP_ALL" || true
done < "$SUBS"

# =========================
# ALIENVAULT OTX
# =========================
echo "[*] AlienVault..."
while read -r domain; do
    curl -s "https://otx.alienvault.com/api/v1/indicators/domain/$domain/url_list" | \
    jq -r '.url_list[].url' 2>/dev/null >> "$TMP_ALL" || true
done < "$SUBS"

# =========================
# KATANA (live crawl)
# =========================
echo "[*] Katana..."
cat "$SUBS" | katana -silent -jc -d 2 >> "$TMP_ALL"

# =========================
# CLEAN + UNIQUE
# =========================
sort -u "$TMP_ALL" > "$TMP_ALL.clean"

echo "[+] Total URLs collected: $(wc -l < "$TMP_ALL.clean")"

# =========================
# FILTER PARAM URLS
# =========================
grep "=" "$TMP_ALL.clean" > "$TMP_PARAM" || true

# =========================
# DEDUP BY PARAM STRUCTURE (KEEP REAL VALUE)
# =========================
echo "[*] Deduplicating by parameter pattern..."

awk -F'?' '
{
    if (NF < 2) next;

    base=$1;
    split($2, params, "&");

    key=base"?";
    for (i in params) {
        split(params[i], kv, "=");
        key=key kv[1]"&";
    }

    if (!seen[key]++) {
        print $0;
    }
}
' "$TMP_PARAM" > "$TMP_DEDUP"

echo "[+] Unique param patterns: $(wc -l < "$TMP_DEDUP")"

# =========================
# LIVE FILTER
# =========================
echo "[*] Checking live endpoints..."

httpx -l "$TMP_DEDUP" \
  -threads 300 \
  -timeout 5 \
  -retries 1 \
  -silent > "$TMP_LIVE"

LIVE_COUNT=$(wc -l < "$TMP_LIVE")

if [[ "$LIVE_COUNT" -eq 0 ]]; then
    echo "[-] No live endpoints"
    rm -f "$TMP_ALL" "$TMP_ALL.clean" "$TMP_PARAM" "$TMP_DEDUP" "$TMP_LIVE"
    exit 0
fi

# =========================
# FINAL OUTPUT
# =========================
sort -u "$TMP_LIVE" > final_urls.txt

echo "[✔] Final output: final_urls.txt"
echo "[+] Total endpoints: $LIVE_COUNT"

# =========================
# CLEANUP
# =========================
rm -f "$TMP_ALL" "$TMP_ALL.clean" "$TMP_PARAM" "$TMP_DEDUP" "$TMP_LIVE"

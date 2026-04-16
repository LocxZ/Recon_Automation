#!/bin/bash

# =========================
# INPUT HANDLING
# =========================
if [[ -z "$1" ]]; then
    echo "Usage:"
    echo "  $0 example.com"
    echo "  $0 domains.txt"
    exit 1
fi

INPUT=$1

# Detect input type
if [[ -f "$INPUT" ]]; then
    TARGETS=$(cat "$INPUT")
else
    TARGETS=$INPUT
fi

DORK_FILE="dorks.txt"

# =========================
# MAIN LOOP
# =========================
for TARGET in $TARGETS; do

    echo "========================================"
    echo "[+] Target: $TARGET"

    TMP=$(mktemp)

    # =========================
    # RUN DORKS
    # =========================
    while read -r dork; do
        [[ "$dork" =~ ^#.*$ || -z "$dork" ]] && continue

        query=$(echo "$dork" | sed "s/{TARGET}/$TARGET/g")

        echo "[*] $query"

        googler --np -n 20 "$query" 2>/dev/null | \
        grep -Eo 'https?://[^ ]+' >> "$TMP"

        sleep 2

    done < "$DORK_FILE"

    # =========================
    # CLEAN + UNIQUE
    # =========================
    UNIQUE_RESULTS=$(cat "$TMP" | sed 's/#.*//' | sort -u)
    COUNT=$(echo "$UNIQUE_RESULTS" | grep -c .)

    rm "$TMP"

    # =========================
    # CHECK RESULTS
    # =========================
    if [[ "$COUNT" -eq 0 ]]; then
        echo "[-] No results found for $TARGET"
        echo
        continue
    fi

    # =========================
    # CREATE FOLDER ONLY IF DATA EXISTS
    # =========================
    BASE_DIR="recon_$TARGET/google_dork"
    mkdir -p "$BASE_DIR/categorized"

    RESULTS="$BASE_DIR/results.txt"

    echo "$UNIQUE_RESULTS" > "$RESULTS"

    echo "[+] Found $COUNT unique URLs"

    # =========================
    # CATEGORIZATION
    # =========================
    grep -E "\.env|\.log|\.sql|\.bak|\.zip" "$RESULTS" > "$BASE_DIR/categorized/sensitive.txt"
    grep -E "admin|login|dashboard" "$RESULTS" > "$BASE_DIR/categorized/panels.txt"
    grep -E "api|graphql|v1|v2" "$RESULTS" > "$BASE_DIR/categorized/api.txt"
    grep -E "redirect|url=|next=|return=" "$RESULTS" > "$BASE_DIR/categorized/redirect.txt"
    grep -E "\.js" "$RESULTS" > "$BASE_DIR/categorized/js.txt"
    grep -E "\.pdf|\.docx|\.xlsx|\.csv" "$RESULTS" > "$BASE_DIR/categorized/docs.txt"

    echo "[✔] Saved in $BASE_DIR"
    echo

done

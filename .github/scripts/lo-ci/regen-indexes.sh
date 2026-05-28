#!/usr/bin/env bash
# Regenerate the listing pages so the static-website endpoint browses cleanly.
#   /                   — top-level (lo + app builds, recent first)
#   /lo-builds/         — list of LO builds
#   /app-builds/        — list of online app builds
set -euo pipefail

# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
ensure_storage_key

ACCT="${AZURE_STORAGE_ACCOUNT:?}"
SITE="${STATIC_SITE_BASE:?}"

list_prefix() {
    local prefix="$1"
    az storage blob list \
        --account-name "$ACCT" \
        --container-name '$web' \
        --prefix "$prefix" \
        --query "[?ends_with(name, '/manifest.json')].name" \
        -o tsv 2>/dev/null | sort -r
}

WORK="$(mktemp -d)"
trap "rm -rf '$WORK'" EXIT

# ── per-section listings ────────────────────────────────────────
gen_section() {
    local prefix="$1" title="$2" out="$3"
    {
        cat <<HTML
<!doctype html>
<meta charset="utf-8"><title>$title</title>
<style>body{font:14px system-ui;margin:2rem;max-width:60rem}h1{margin-bottom:.2rem}
table{border-collapse:collapse;width:100%}td,th{padding:.4rem .6rem;border-bottom:1px solid #eee;text-align:left}
a{color:#0066cc;text-decoration:none}a:hover{text-decoration:underline}
.muted{color:#666}.ok{color:#2e7d32}.bad{color:#c62828}</style>
<h1>$title</h1>
<p><a href="../">← root</a></p>
<table><thead><tr><th>Build ID</th><th>When</th><th>Notes</th></tr></thead><tbody>
HTML
        local manifests
        manifests="$(list_prefix "$prefix")"
        if [[ -z "$manifests" ]]; then
            echo '<tr><td colspan="3" class="muted">no builds yet</td></tr>'
        else
            local n=0
            while IFS= read -r mfp; do
                [[ -z "$mfp" ]] && continue
                local id when notes
                # path is "<prefix><id>/manifest.json"
                id="${mfp#$prefix}"; id="${id%/manifest.json}"
                local tmp="$WORK/m-$n.json"; n=$((n+1))
                az storage blob download --account-name "$ACCT" \
                    --container-name '$web' --name "$mfp" --file "$tmp" --no-progress >/dev/null 2>&1 || continue
                when="$(jq -r '.completed_utc // ""' "$tmp" 2>/dev/null)"
                if [[ "$prefix" == "app-builds/" ]]; then
                    local rc lo
                    rc="$(jq -r '.test_report.exit_code // empty' "$tmp" 2>/dev/null)"
                    lo="$(jq -r '.lo_build_id // ""' "$tmp" 2>/dev/null)"
                    if [[ -z "$rc" ]]; then notes="LO=$lo · <span class=\"muted\">no tests yet</span>"
                    elif [[ "$rc" == "0" ]]; then notes="LO=$lo · <span class=\"ok\">tests passed</span>"
                    else notes="LO=$lo · <span class=\"bad\">tests failed (rc=$rc)</span>"
                    fi
                else
                    notes="$(jq -r '.git_short_sha // ""' "$tmp" 2>/dev/null)"
                fi
                printf '<tr><td><a href="%s/">%s</a></td><td class="muted">%s</td><td>%s</td></tr>\n' \
                    "$id" "$id" "$when" "$notes"
                [[ $n -ge 50 ]] && break
            done <<< "$manifests"
        fi
        echo '</tbody></table>'
    } > "$out"
}

gen_section "lo-builds/" "LibreOffice WASM builds" "$WORK/lo-builds.html"

# Only lo-builds/ is the LO repo's responsibility now.
#
# app-builds/, editor-builds/, local-builds/ AND the root index are
# all owned by szsz/online's regen-indexes.sh, which uses a richer
# 7-column schema (Branch / Commit / Tests / Editor) and lists every
# section. Writing them here clobbered Online's nicer version every
# LO build — the deployed app-builds/index.html stayed frozen on
# April-29 content because each LO build re-emitted the old
# 3-column format AND missed any blobs past the az-list default
# 5000-blob cap (per-test screenshots saturate that long before
# recent manifest.json entries).

upload() {
    local src="$1" name="$2"
    az storage blob upload \
        --account-name "$ACCT" \
        --container-name '$web' --name "$name" --file "$src" \
        --content-type 'text/html; charset=utf-8' \
        --overwrite --no-progress >/dev/null
}

upload "$WORK/lo-builds.html" "lo-builds/index.html"

echo "Index refreshed: $SITE/lo-builds/"

#!/bin/bash
# Upload only mailboxes that haven't finished yet.
#
# Heuristic (based on imap_upload --error files):
#   - no Foo.upload-errors.mbox          → never uploaded → upload Foo.mbox
#   - Foo.upload-errors.mbox empty       → finished OK → skip
#   - Foo.upload-errors*.mbox non-empty  → retry latest leftovers only
#   - after a clean retry (0 new errors), leftovers are renamed *.done
#
# Safe to re-run. Does NOT re-upload completed mailboxes.

prompt_if_empty() {
    local var_name=$1
    local prompt_text=$2
    local is_password=$3

    if [ -z "${!var_name}" ]; then
        if [ "$is_password" = "true" ]; then
            read -sp "$prompt_text: " input
            echo
        else
            read -p "$prompt_text: " input
        fi
        eval "$var_name='$input'"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR=""
EMAIL=""
PASSWORD=""
DRY_RUN=false
RETRY=5
SLEEP_SECS=2

gmail_remote_box() {
    # Gmail rejects/ignores trailing spaces and collapses runs of spaces;
    # APPEND then returns TRYCREATE if we keep the Yahoo spelling.
    local name
    name=$(echo "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')
    case "$name" in
        INBOX|Inbox)  echo "INBOX" ;;
        Sent)         echo "[Gmail]/Sent Mail" ;;
        Trash)        echo "[Gmail]/Trash" ;;
        Draft|Drafts) echo "[Gmail]/Drafts" ;;
        Bulk|Spam)    echo "[Gmail]/Spam" ;;
        *)            echo "$name" ;;
    esac
}

file_size() {
    wc -c < "$1" | tr -d ' '
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--email) EMAIL="$2"; shift 2 ;;
        -p|--password) PASSWORD="$2"; shift 2 ;;
        --source) SOURCE_DIR="$2"; shift 2 ;;
        --gmail) shift ;; # always gmail for this helper
        --dry-run) DRY_RUN=true; shift ;;
        -w|--wait) SLEEP_SECS="$2"; shift 2 ;;
        -h|--help)
            cat <<'EOF'
Usage: ./upload_remaining.sh --source DIR -e EMAIL

Uploads only folders not yet complete:
  - skips mailboxes whose .upload-errors.mbox is empty (already done)
  - retries non-empty .upload-errors*.mbox leftovers
  - uploads never-started .mbox files as Gmail labels

Example:
  bash ./upload_remaining.sh \
    --source /Users/joelleabejero/dev/imapgrab/downloaded_emails/Jack_steadfastinc_com \
    -e "Jack@steadfastinc.com"
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

prompt_if_empty "EMAIL" "Destination email" "false"
prompt_if_empty "PASSWORD" "Destination password / app password" "true"
prompt_if_empty "SOURCE_DIR" "Source mbox directory" "false"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "Source directory not found: $SOURCE_DIR"
    exit 1
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

echo "Upload remaining"
echo "  Source: $SOURCE_DIR"
echo "  Dest:   Gmail ($EMAIL)"
echo "----------------------------------------"

WORK=()
SKIP=0

while IFS= read -r -d '' mbox; do
    rel="${mbox#"$SOURCE_DIR"/}"
    case "$rel" in
        *upload-errors*) continue ;;
    esac

    size=$(file_size "$mbox")
    [ "$size" -eq 0 ] && continue

    dir=$(dirname "$mbox")
    base=$(basename "$mbox" .mbox)
    label="${rel%.mbox}"
    remote=$(gmail_remote_box "$label")

    primary_err="$dir/${base}.upload-errors.mbox"

    # Collect leftover chain: upload-errors, upload-errors2, ...
    # Successful retries rename leftovers to *.done and may leave an empty
    # errorsN file — both mean "already finished" when nothing nonempty remains.
    latest_nonempty=""
    max_n=0
    has_empty_err=false
    has_done=false
    for candidate in "$dir/${base}.upload-errors.mbox" \
                     "$dir/${base}.upload-errors2.mbox" \
                     "$dir/${base}.upload-errors3.mbox" \
                     "$dir/${base}.upload-errors4.mbox" \
                     "$dir/${base}.upload-errors5.mbox"; do
        [ -f "$candidate" ] || continue
        bn=$(basename "$candidate")
        if [[ "$bn" =~ upload-errors([0-9]*)\.mbox$ ]]; then
            n="${BASH_REMATCH[1]}"
            [ -z "$n" ] && n=1
            if [ "$(file_size "$candidate")" -gt 0 ]; then
                latest_nonempty="$candidate"
                max_n=$n
            else
                has_empty_err=true
            fi
        fi
    done
    for donef in "$dir/${base}".upload-errors*.mbox.done \
                 "$dir/${base}".upload-errors*.mbox.toobig; do
        [ -f "$donef" ] && has_done=true && break
    done

    if [ -n "$latest_nonempty" ]; then
        next_n=$((max_n + 1))
        if [ "$next_n" -eq 2 ]; then
            next_err="$dir/${base}.upload-errors2.mbox"
        else
            next_err="$dir/${base}.upload-errors${next_n}.mbox"
        fi
        WORK+=("$latest_nonempty|$remote|$next_err|RETRY|$primary_err")
    elif $has_empty_err || $has_done; then
        SKIP=$((SKIP + 1))
        continue
    else
        WORK+=("$mbox|$remote|$primary_err|NEW|")
    fi
done < <(find "$SOURCE_DIR" -type f -name '*.mbox' -print0 | sort -z)

echo "Skip (already done): $SKIP"
echo "To upload: ${#WORK[@]}"
echo "----------------------------------------"

if [ ${#WORK[@]} -eq 0 ]; then
    echo "Nothing left to upload."
    exit 0
fi

# Preview first few
echo "Next up:"
preview=0
for entry in "${WORK[@]}"; do
    preview=$((preview + 1))
    [ "$preview" -gt 8 ] && break
    IFS='|' read -r src remote err kind _ <<< "$entry"
    echo "  ($kind) ${src#"$SOURCE_DIR"/} -> $remote"
done
if [ ${#WORK[@]} -gt 8 ]; then
    extra=$((${#WORK[@]} - 8))
    echo "  ... +${extra} more"
fi
echo "----------------------------------------"

failed=0
i=0
for entry in "${WORK[@]}"; do
    i=$((i + 1))
    IFS='|' read -r src remote err kind primary_err <<< "$entry"
    rel_src="${src#"$SOURCE_DIR"/}"
    size=$(file_size "$src")
    human=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "${size}B")
    # Mailbox base name (strip .upload-errorsN.mbox or .mbox)
    src_bn=$(basename "$src")
    box_base=$(echo "$src_bn" | sed -E 's/\.upload-errors[0-9]*\.mbox$//; s/\.mbox$//')
    box_dir=$(dirname "$src")

    echo
    echo "[$i/${#WORK[@]}] ($kind) $rel_src ($human) -> $remote"

    args=(--gmail --retry "$RETRY"
          --user "$EMAIL" --password "$PASSWORD"
          --box "$remote"
          --error "$err")
    $DRY_RUN && args+=(--dry-run)

    if python3 "$SCRIPT_DIR/imap_upload.py" "${args[@]}" "$src"; then
        # If retry produced no new failures, archive ALL leftover error mboxes
        # for this mailbox (older copies often hold the same messages).
        if [ "$kind" = "RETRY" ] && [ -f "$err" ] && [ "$(file_size "$err")" -eq 0 ]; then
            for leftover in "$box_dir/${box_base}".upload-errors*.mbox; do
                [ -f "$leftover" ] || continue
                case "$leftover" in *.done) continue ;; esac
                mv "$leftover" "${leftover}.done"
            done
            echo "  OK (marked leftovers as done)"
        else
            echo "  OK"
        fi
    else
        rc=$?
        echo "  FAILED (exit $rc) (see $err)"
        failed=$((failed + 1))
        # Connect/login failures create an empty --error mbox; remove it so the
        # folder is not treated as "already done" on the next run.
        if [ -f "$err" ] && [ "$(file_size "$err")" -eq 0 ]; then
            rm -f "$err"
        fi
        if [ "$rc" -eq 3 ]; then
            echo
            echo "Gmail OVERQUOTA / rate limit hit. Stopping."
            echo "Wait longer (often overnight), then re-run this script — it will resume leftovers only."
            exit 3
        fi
        # Gmail rejects messages over ~25MB; re-running will never clear these.
        if [ -f "$err" ] && [ "$(file_size "$err")" -gt 26214400 ]; then
            echo "  Note: leftover is >25MB — likely Gmail [TOOBIG]. Park to skip:"
            echo "    for f in \"$box_dir/${box_base}\".upload-errors*.mbox; do mv \"\$f\" \"\$f.toobig\"; done"
        fi
    fi

    sleep "$SLEEP_SECS"
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All remaining uploads finished."
else
    echo "$failed mailbox(es) had failures. Re-run this script to continue."
    exit 1
fi

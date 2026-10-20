#!/bin/bash
# Upload downloaded .mbox files from imapgrab to an IMAP server.
# Skips empty mboxes. Uses imap_upload.py with SSL + retries.

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
SOURCE_DIR="/Users/joelleabejero/dev/imapgrab/downloaded_emails/admin_steadfastinc_com"

EMAIL=""
PASSWORD=""
HOST=""
PORT="993"
USE_GMAIL=false
DRY_RUN=false
RETRY=5

# Local mbox basename -> remote IMAP box name
# For Gmail, use special-use folders so Sent/Trash aren't plain labels.
declare -a UPLOADS=(
    "Inbox.mbox|INBOX"
    "Sent.mbox|Sent"
    "Archive.mbox|Archive"
    "Bulk.mbox|Bulk"
    "Taxes.mbox|Taxes"
    "Trash.mbox|Trash"
    "Draft.mbox|Draft"
)

# Override remote box names when targeting Gmail.
gmail_remote_box() {
    # Gmail rejects/ignores trailing spaces and collapses runs of spaces;
    # APPEND then returns TRYCREATE if we keep the Yahoo spelling.
    local name
    name=$(echo "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')
    case "$name" in
        Sent)  echo "[Gmail]/Sent Mail" ;;
        Trash) echo "[Gmail]/Trash" ;;
        Draft) echo "[Gmail]/Drafts" ;;
        Bulk)  echo "[Gmail]/Spam" ;;
        *)     echo "$name" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--email) EMAIL="$2"; shift 2 ;;
        -p|--password) PASSWORD="$2"; shift 2 ;;
        -s|--host|--server) HOST="$2"; shift 2 ;;
        -P|--port) PORT="$2"; shift 2 ;;
        --gmail) USE_GMAIL=true; HOST="imap.gmail.com"; PORT="993"; shift ;;
        --source) SOURCE_DIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --list-boxes)
            prompt_if_empty "EMAIL" "Destination email" "false"
            prompt_if_empty "PASSWORD" "Destination password" "true"
            if [ -z "$HOST" ]; then
                prompt_if_empty "HOST" "IMAP host" "false"
            fi
            extra=()
            $USE_GMAIL && extra+=(--gmail)
            [ -n "$HOST" ] && extra+=(--host "$HOST" --port "$PORT" --ssl)
            python3 "$SCRIPT_DIR/imap_upload.py" "${extra[@]}" \
                --user "$EMAIL" --password "$PASSWORD" --list_boxes
            exit $?
            ;;
        -h|--help)
            cat <<'EOF'
Usage: ./upload_mailboxes.sh [options]

Uploads non-empty mbox files from the imapgrab download folder.

Options:
  -e, --email EMAIL       Destination account email
  -p, --password PASS     Destination password / app password
  -s, --host HOST         Destination IMAP host
  -P, --port PORT         Destination IMAP port (default: 993)
      --gmail             Shortcut for Gmail (imap.gmail.com:993 SSL)
      --source DIR        Folder containing *.mbox (default: imapgrab download dir)
      --list-boxes        List destination mailboxes and exit
      --dry-run           Pass --dry-run to imap_upload.py
  -h, --help              Show help

Examples:
  # List folders on destination first
  bash ./upload_mailboxes.sh --gmail -e you@gmail.com --list-boxes

  # Upload everything we have
  bash ./upload_mailboxes.sh --gmail -e you@gmail.com

  # Custom IMAP host
  bash ./upload_mailboxes.sh -s imap.example.com -e you@example.com
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
if ! $USE_GMAIL; then
    prompt_if_empty "HOST" "Destination IMAP host" "false"
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "Source directory not found: $SOURCE_DIR"
    exit 1
fi

echo "Upload plan"
echo "  Source: $SOURCE_DIR"
if $USE_GMAIL; then
    echo "  Dest:   Gmail ($EMAIL)"
else
    echo "  Dest:   $HOST:$PORT ($EMAIL)"
fi
echo "----------------------------------------"

failed=0
for entry in "${UPLOADS[@]}"; do
    local_name="${entry%%|*}"
    remote_box="${entry##*|}"
    if $USE_GMAIL; then
        remote_box=$(gmail_remote_box "$remote_box")
    fi
    local_path="$SOURCE_DIR/$local_name"

    if [ ! -f "$local_path" ]; then
        echo "Skip (missing): $local_name"
        continue
    fi

    size=$(wc -c < "$local_path" | tr -d ' ')
    if [ "$size" -eq 0 ]; then
        echo "Skip (empty): $local_name"
        continue
    fi

    human=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "${size}B")
    echo
    echo "Uploading $local_name ($human) -> $remote_box"

    args=(--ssl --host "$HOST" --port "$PORT" --retry "$RETRY"
          --user "$EMAIL" --password "$PASSWORD"
          --box "$remote_box"
          --error "$SOURCE_DIR/${local_name%.mbox}.upload-errors.mbox")
    $USE_GMAIL && args=(--gmail --retry "$RETRY"
          --user "$EMAIL" --password "$PASSWORD"
          --box "$remote_box"
          --error "$SOURCE_DIR/${local_name%.mbox}.upload-errors.mbox")
    $DRY_RUN && args+=(--dry-run)

    if python3 "$SCRIPT_DIR/imap_upload.py" "${args[@]}" "$local_path"; then
        echo "  OK: $local_name"
    else
        echo "  FAILED: $local_name (failed msgs in ${local_name%.mbox}.upload-errors.mbox if any)"
        failed=$((failed + 1))
    fi
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All uploads finished."
else
    echo "$failed mailbox(es) had failures. Re-run; error mboxes can be retried as sources."
    exit 1
fi

#!/bin/bash
# livex-kb-upload.sh — Upload teach-ai documents (RAG) or website URLs to a LiveX agent corpus
#
# Usage:
#   ./livex-kb-upload.sh <agent_id> [file_or_dir_or_url] [OPTIONS]
#
# Options:
#   --profile NAME        Use named credential profile
#   --env ENV             Environment: dev (default), staging, production
#   --url URL             Upload a website URL or XML sitemap (repeatable)
#   --url-file PATH       Upload URLs from file (one URL per line)
#   --website-type TYPE   Website type for URL uploads (default: static)
#   --reprocess-schedule VALUE
#                         Request automatic reprocessing schedule for URL uploads
#   --include-attachments Include attachments when the upstream source supports them
#   --target-url-regex REGEX
#                         Limit URL ingestion to matching pages (useful with sitemaps)
#   --scraper-config JSON|@FILE
#                         Pass scraper config JSON inline or from a file
#   --wait                Poll until uploaded docs report doc_size > 0 (processed)
#   --wait-timeout N      Stop waiting after N seconds (default: 300)
#   --poll-interval N     Poll every N seconds while waiting (default: 10)
#   --replace             Delete existing doc with same title before uploading
#   --yes                 Skip confirmation prompt for production
#   --help                Show this help message
#
# Supported file formats: .md, .txt, .pdf, .docx, .html
#
# Examples:
#   ./livex-kb-upload.sh abc-123 ./kb-teach-ai/knowledge.md --profile prd-gtc
#   ./livex-kb-upload.sh abc-123 ./kb-teach-ai/ --profile prd-gtc --replace --yes
#   ./livex-kb-upload.sh abc-123 https://docs.example.com/sitemap.xml --profile prd-gtc --wait --yes

source "$(dirname "$0")/_lib.sh"

SUPPORTED_EXTS="md|txt|pdf|docx|html"
DEFAULT_WAIT_TIMEOUT=300
DEFAULT_POLL_INTERVAL=10

usage() {
    echo "Usage: $(basename "$0") <agent_id> [file_or_dir_or_url] [OPTIONS]"
    echo ""
    echo "Upload teach-ai documents (RAG) or website URLs to a LiveX agent corpus."
    echo "Supports files: .md, .txt, .pdf, .docx, .html"
    echo ""
    echo "Options:"
    echo "  --profile NAME        Use named credential profile"
    echo "  --env ENV             Environment: dev (default), staging, production"
    echo "  --url URL             Upload a website URL or XML sitemap (repeatable)"
    echo "  --url-file PATH       Upload URLs from file (one URL per line)"
    echo "  --website-type TYPE   Website type for URL uploads (default: static)"
    echo "  --reprocess-schedule VALUE"
    echo "                        Request automatic reprocessing schedule for URL uploads"
    echo "  --include-attachments Include attachments when the upstream source supports them"
    echo "  --target-url-regex REGEX"
    echo "                        Limit URL ingestion to matching pages (useful with sitemaps)"
    echo "  --scraper-config JSON|@FILE"
    echo "                        Pass scraper config JSON inline or from a file"
    echo "  --wait                Poll until uploaded docs report doc_size > 0 (processed)"
    echo "  --wait-timeout N      Stop waiting after N seconds (default: ${DEFAULT_WAIT_TIMEOUT})"
    echo "  --poll-interval N     Poll every N seconds while waiting (default: ${DEFAULT_POLL_INTERVAL})"
    echo "  --replace             Delete existing doc with same title before uploading"
    echo "  --yes                 Skip confirmation prompt for production"
    echo "  --help                Show this help message"
    exit "${1:-$EXIT_USAGE}"
}

read_urls_from_file() {
    local path="$1"
    local line trimmed

    [[ -f "$path" ]] || die $EXIT_USAGE "URL file not found: ${path}"

    while IFS= read -r line || [[ -n "$line" ]]; do
        trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ -n "$trimmed" ]] || continue
        [[ "$trimmed" =~ ^# ]] && continue
        validate_url "$trimmed" "URL in ${path}"
        urls+=("$trimmed")
    done < "$path"
}

resolve_scraper_config() {
    local input="$1"
    local resolved=""

    if [[ -z "$input" ]]; then
        printf '%s' ""
        return
    fi

    if [[ "$input" == @* ]]; then
        local path="${input#@}"
        [[ -f "$path" ]] || die $EXIT_USAGE "scraper config file not found: ${path}"
        resolved=$(cat "$path")
    else
        resolved="$input"
    fi

    printf '%s' "$resolved" | jq -e . >/dev/null 2>&1 || die $EXIT_USAGE "scraper config must be valid JSON"
    printf '%s' "$resolved"
}

find_doc_record_by_id() {
    local docs_json="$1"
    local doc_id="$2"

    printf '%s\n' "$docs_json" | jq -c --arg did "$doc_id" '.response[]? | select(.document_id == $did)' 2>/dev/null | head -1
}

poll_until_ready() {
    local deadline=$((SECONDS + WAIT_TIMEOUT))
    local pending_ids=("${uploaded_ids[@]}")
    local pending_titles=("${uploaded_titles[@]}")
    local total="${#uploaded_ids[@]}"
    local remaining_items=()
    local docs_resp record doc_id title doc_size chunk_count ready_count item

    [[ "$total" -gt 0 ]] || return 0

    info "Waiting for ${total} uploaded document(s) to finish processing..."

    while true; do
        docs_resp=$(api_get "${LIVEX_API_HOST}/api/v1/documents?account_id=${LIVEX_ACCOUNT_ID}&corpus_id=${CORPUS_ID}")
        remaining_items=()
        ready_count=0

        for idx in "${!pending_ids[@]}"; do
            doc_id="${pending_ids[$idx]}"
            title="${pending_titles[$idx]}"
            record=$(find_doc_record_by_id "$docs_resp" "$doc_id")

            if [[ -z "$record" ]]; then
                warn "Verification lost document ${doc_id} (${title}) from corpus listing"
                remaining_items+=("$doc_id"$'\t'"$title")
                continue
            fi

            doc_size=$(printf '%s\n' "$record" | jq -r '.doc_size // 0' 2>/dev/null || echo 0)
            chunk_count=$(get_doc_chunk_count "$doc_id")
            if [[ "$doc_size" -gt 0 ]] || [[ "$chunk_count" =~ ^[0-9]+$ && "$chunk_count" -gt 0 ]]; then
                echo -e "    ${GREEN}ready${NC}  ${title}  id=${doc_id}  size=${doc_size}  chunks=${chunk_count}" >&2
                ready_count=$((ready_count + 1))
            else
                remaining_items+=("$doc_id"$'\t'"$title")
            fi
        done

        if [[ "${#remaining_items[@]}" -eq 0 ]]; then
            success "All uploaded documents are processed (verified via doc_size or chunk count)"
            return 0
        fi

        if (( SECONDS >= deadline )); then
            warn "Timed out after ${WAIT_TIMEOUT}s waiting for processing"
            for item in "${remaining_items[@]}"; do
                doc_id="${item%%$'\t'*}"
                title="${item#*$'\t'}"
                echo -e "    ${YELLOW}processing${NC}  ${title}  id=${doc_id}" >&2
            done
            return 1
        fi

        info "Processed ${ready_count}/${total}; ${#remaining_items[@]} still processing. Polling again in ${POLL_INTERVAL}s..."
        pending_ids=()
        pending_titles=()
        for item in "${remaining_items[@]}"; do
            pending_ids+=("${item%%$'\t'*}")
            pending_titles+=("${item#*$'\t'}")
        done
        sleep "$POLL_INTERVAL"
    done
}

AGENT_ID=""
FILE_INPUT=""
ENV_FLAG="dev"
REPLACE=false
SKIP_CONFIRM="false"
URL_FILE=""
WEBSITE_TYPE="static"
REPROCESS_SCHEDULE=""
INCLUDE_ATTACHMENTS=false
TARGET_URL_REGEX=""
SCRAPER_CONFIG_INPUT=""
WAIT_FOR_READY=false
WAIT_TIMEOUT="$DEFAULT_WAIT_TIMEOUT"
POLL_INTERVAL="$DEFAULT_POLL_INTERVAL"
urls=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage $EXIT_SUCCESS ;;
        --env) ENV_FLAG="${2:?--env requires a value}"; shift 2 ;;
        --profile) export LIVEX_PROFILE="${2:?--profile requires a name}"; shift 2 ;;
        --url) urls+=("${2:?--url requires a value}"); shift 2 ;;
        --url-file) URL_FILE="${2:?--url-file requires a path}"; shift 2 ;;
        --website-type) WEBSITE_TYPE="${2:?--website-type requires a value}"; shift 2 ;;
        --reprocess-schedule) REPROCESS_SCHEDULE="${2:?--reprocess-schedule requires a value}"; shift 2 ;;
        --include-attachments) INCLUDE_ATTACHMENTS=true; shift ;;
        --target-url-regex) TARGET_URL_REGEX="${2:?--target-url-regex requires a value}"; shift 2 ;;
        --scraper-config) SCRAPER_CONFIG_INPUT="${2:?--scraper-config requires a value}"; shift 2 ;;
        --wait) WAIT_FOR_READY=true; shift ;;
        --wait-timeout) WAIT_TIMEOUT="${2:?--wait-timeout requires a value}"; shift 2 ;;
        --poll-interval) POLL_INTERVAL="${2:?--poll-interval requires a value}"; shift 2 ;;
        --replace) REPLACE=true; shift ;;
        --yes) SKIP_CONFIRM="true"; shift ;;
        -*) die $EXIT_USAGE "Unknown option: $1\nRun with --help for usage." ;;
        *)
            if [[ -z "$AGENT_ID" ]]; then
                AGENT_ID="$1"
            elif [[ -z "$FILE_INPUT" ]]; then
                FILE_INPUT="$1"
            else
                die $EXIT_USAGE "Unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

[[ -n "$AGENT_ID" ]] || usage

check_deps
load_env
resolve_api_host "$ENV_FLAG"
export SKIP_CONFIRM

files=()
if [[ -n "$FILE_INPUT" ]]; then
    if [[ "$FILE_INPUT" =~ ^https?:// ]]; then
        urls+=("$FILE_INPUT")
    elif [[ -d "$FILE_INPUT" ]]; then
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(find "$FILE_INPUT" -maxdepth 1 -type f \( -iname "*.md" -o -iname "*.txt" -o -iname "*.pdf" -o -iname "*.docx" -o -iname "*.html" \) -print0 2>/dev/null)
        if [[ ${#files[@]} -eq 0 ]]; then
            die $EXIT_USAGE "No supported files found in ${FILE_INPUT} (supported: ${SUPPORTED_EXTS})"
        fi
    elif [[ -f "$FILE_INPUT" ]]; then
        ext="${FILE_INPUT##*.}"
        if ! echo "$ext" | grep -qiE "^(${SUPPORTED_EXTS})$"; then
            die $EXIT_USAGE "Unsupported file type: .${ext} (supported: ${SUPPORTED_EXTS})"
        fi
        files=("$FILE_INPUT")
    else
        die $EXIT_USAGE "Not found: $FILE_INPUT"
    fi
fi

if [[ -n "$URL_FILE" ]]; then
    read_urls_from_file "$URL_FILE"
fi

if [[ ${#urls[@]} -gt 0 ]]; then
    for url in "${urls[@]}"; do
        validate_url "$url"
    done
fi

SCRAPER_CONFIG=$(resolve_scraper_config "$SCRAPER_CONFIG_INPUT")

[[ ${#files[@]} -gt 0 || ${#urls[@]} -gt 0 ]] || usage
[[ "$WAIT_TIMEOUT" =~ ^[0-9]+$ ]] || die $EXIT_USAGE "--wait-timeout must be an integer number of seconds"
if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$POLL_INTERVAL" -le 0 ]]; then
    die $EXIT_USAGE "--poll-interval must be a positive integer number of seconds"
fi

info "Files to upload: ${#files[@]}"
if [[ ${#files[@]} -gt 0 ]]; then
    for f in "${files[@]}"; do
        info "  $(basename "$f")"
    done
fi
info "URLs to upload: ${#urls[@]}"
if [[ ${#urls[@]} -gt 0 ]]; then
    for url in "${urls[@]}"; do
        info "  ${url}"
    done
fi

info "Fetching agent config to extract corpus_id..."
agent_resp=$(api_get "${LIVEX_API_HOST}/api/v1/agent?account_id=${LIVEX_ACCOUNT_ID}&agent_id=${AGENT_ID}")
CORPUS_ID=$(extract_corpus_id "$agent_resp")

if [[ -z "$CORPUS_ID" ]]; then
    die $EXIT_API "Could not extract corpus_id from agent config"
fi
info "corpus_id: ${CORPUS_ID}"

confirm_production

existing_docs=""
if [[ "$REPLACE" == "true" ]]; then
    info "Fetching existing documents for replacement check..."
    existing_docs=$(api_get "${LIVEX_API_HOST}/api/v1/documents?account_id=${LIVEX_ACCOUNT_ID}&corpus_id=${CORPUS_ID}")
fi

uploaded=0
failed=0
uploaded_ids=()
uploaded_titles=()
uploaded_sources=()
total_inputs=$(( ${#files[@]} + ${#urls[@]} ))

for filepath in ${files[@]+"${files[@]}"}; do
    filename=$(basename "$filepath")

    if [[ "$REPLACE" == "true" && -n "$existing_docs" ]]; then
        existing_id=$(printf '%s\n' "$existing_docs" | jq -r --arg title "$filename" '.response[]? | select(.title == $title) | .document_id // empty' 2>/dev/null)
        if [[ -n "$existing_id" ]]; then
            info "Replacing: deleting existing ${filename} (${existing_id})..."
            api_delete "${LIVEX_API_HOST}/api/v1/document?doc_id=${existing_id}&account_id=${LIVEX_ACCOUNT_ID}" >/dev/null 2>&1 || warn "Failed to delete existing doc ${existing_id}"
            sleep 0.5
        fi
    fi

    info "Uploading file: ${filename}..."
    if result=$(api_post_multipart "${LIVEX_API_HOST}/api/v1/document-file-v2" \
        "file=@${filepath}" \
        "agent_id=${AGENT_ID}" \
        "corpus_id=${CORPUS_ID}" \
        "account_id=${LIVEX_ACCOUNT_ID}" 2>&1); then
        uploaded=$((uploaded + 1))
        doc_id=$(printf '%s\n' "$result" | jq -r '.response.document_id // "?"' 2>/dev/null)
        success "Uploaded ${uploaded}/${total_inputs}: ${filename} → ${doc_id}"
        uploaded_ids+=("$doc_id")
        uploaded_titles+=("$filename")
        uploaded_sources+=("file")
    else
        failed=$((failed + 1))
        warn "Failed: ${filename} — ${result}"
    fi

    sleep 0.3
done

for url in ${urls[@]+"${urls[@]}"}; do
    if [[ "$REPLACE" == "true" && -n "$existing_docs" ]]; then
        existing_id=$(printf '%s\n' "$existing_docs" | jq -r --arg title "$url" '.response[]? | select(.title == $title) | .document_id // empty' 2>/dev/null)
        if [[ -n "$existing_id" ]]; then
            info "Replacing: deleting existing ${url} (${existing_id})..."
            api_delete "${LIVEX_API_HOST}/api/v1/document?doc_id=${existing_id}&account_id=${LIVEX_ACCOUNT_ID}" >/dev/null 2>&1 || warn "Failed to delete existing doc ${existing_id}"
            sleep 0.5
        fi
    fi

    payload=$(jq -n \
        --arg aid "$AGENT_ID" \
        --arg handle "$url" \
        --arg title "$url" \
        --arg corpus "$CORPUS_ID" \
        --arg acct "$LIVEX_ACCOUNT_ID" \
        --arg website_type "$WEBSITE_TYPE" \
        --arg reprocess_schedule "$REPROCESS_SCHEDULE" \
        --arg target_url_regex "$TARGET_URL_REGEX" \
        --arg scraper_config "$SCRAPER_CONFIG" \
        --argjson include_attachments "$INCLUDE_ATTACHMENTS" \
        '{
            agent_id: $aid,
            doc_handle: $handle,
            doc_type: "website",
            title: $title,
            corpus_id: $corpus,
            account_id: $acct,
            include_attachments: $include_attachments
        }
        + (if $website_type != "" then {website_type: $website_type} else {} end)
        + (if $reprocess_schedule != "" then {reprocess_schedule: $reprocess_schedule} else {} end)
        + (if $target_url_regex != "" then {target_url_regex: $target_url_regex} else {} end)
        + (if $scraper_config != "" then {scraper_config: $scraper_config} else {} end)')

    info "Creating website document: ${url}..."
    if result=$(api_post "${LIVEX_API_HOST}/api/v1/document-url" "$payload" 2>&1); then
        uploaded=$((uploaded + 1))
        doc_id=$(printf '%s\n' "$result" | jq -r '.response.document_id // "?"' 2>/dev/null)
        success "Uploaded ${uploaded}/${total_inputs}: ${url} → ${doc_id}"
        uploaded_ids+=("$doc_id")
        uploaded_titles+=("$url")
        uploaded_sources+=("url")
    else
        failed=$((failed + 1))
        warn "Failed: ${url} — ${result}"
    fi

    sleep 0.3
done

echo "" >&2
if [[ "$failed" -ne 0 ]]; then
    warn "Uploaded ${uploaded}/${total_inputs} (${failed} failed)"
    exit $EXIT_API
fi

success "Uploaded ${uploaded}/${total_inputs} documents to ${ENV_LABEL}"
info "Verifying uploads in corpus..."
verify_resp=$(api_get "${LIVEX_API_HOST}/api/v1/documents?account_id=${LIVEX_ACCOUNT_ID}&corpus_id=${CORPUS_ID}")
final_count=$(printf '%s\n' "$verify_resp" | jq '[.response[]?.document_id // empty] | length' 2>/dev/null || echo "?")
echo -e "  ${BOLD}Corpus doc count:${NC} ${final_count}" >&2
echo -e "  ${BOLD}Upload check:${NC}" >&2

verify_missing=0
processing_count=0

for idx in "${!uploaded_ids[@]}"; do
    doc_id="${uploaded_ids[$idx]}"
    title="${uploaded_titles[$idx]}"
    source_kind="${uploaded_sources[$idx]}"
    record=$(find_doc_record_by_id "$verify_resp" "$doc_id")

    if [[ -z "$record" ]]; then
        echo -e "    ${RED}NOT FOUND${NC}  ${title}  id=${doc_id}  source=${source_kind}" >&2
        verify_missing=$((verify_missing + 1))
        continue
    fi

    doc_size=$(printf '%s\n' "$record" | jq -r '.doc_size // 0' 2>/dev/null || echo 0)
    if [[ "$doc_size" -gt 0 ]]; then
        echo -e "    ${GREEN}ready${NC}  ${title}  id=${doc_id}  source=${source_kind}  size=${doc_size}" >&2
    else
        echo -e "    ${YELLOW}processing${NC}  ${title}  id=${doc_id}  source=${source_kind}  size=0" >&2
        processing_count=$((processing_count + 1))
    fi
done

if [[ "$verify_missing" -gt 0 ]]; then
    die $EXIT_API "Post-upload verification failed: ${verify_missing} document(s) missing from target corpus"
fi

if [[ "$WAIT_FOR_READY" == "true" ]]; then
    if ! poll_until_ready; then
        exit $EXIT_API
    fi
elif [[ "$processing_count" -gt 0 ]]; then
    warn "${processing_count} document(s) are still processing. Re-run livex-kb-list.sh or use --wait for readiness verification."
fi

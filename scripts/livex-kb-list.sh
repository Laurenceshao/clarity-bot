#!/bin/bash
# livex-kb-list.sh — List all KB content for a LiveX agent
#
# Usage:
#   ./livex-kb-list.sh <agent_id> [OPTIONS]
#   ./livex-kb-list.sh --all [OPTIONS]
#
# Options:
#   --all            Audit KB for ALL agents on the account (max 4 concurrent)
#   --profile NAME   Use named credential profile
#   --env ENV        Environment: dev (default), staging, production
#   --wait-ready     Poll until all teach-ai documents report ready status
#   --wait-timeout N Stop waiting after N seconds (default: 300)
#   --poll-interval N
#                    Poll every N seconds while waiting (default: 10)
#   --json           Output structured JSON to stdout
#   --help           Show this help message
#
# Examples:
#   ./livex-kb-list.sh abc-123 --profile prd-gtc
#   ./livex-kb-list.sh abc-123 --profile prd-gtc --json
#   ./livex-kb-list.sh --all --profile prd-gtc

source "$(dirname "$0")/_lib.sh"

# Wrapper for api_get that degrades gracefully instead of dying on error.
# Used for secondary KB fetches (docs, products, expert) where partial results
# are better than aborting the whole inventory.  _check_body_error inside api_get
# dies in the $() subshell; the `if` catches the non-zero exit and warns.
# Stderr is NOT suppressed — error messages from _check_body_error flow through.
_resilient_api_get() {
    local url="$1" fallback="$2" label="${3:-API call}"
    local resp
    if resp=$(api_get "$url"); then
        printf '%s\n' "$resp"
    else
        warn "${label}: request failed — using empty fallback"
        printf '%s\n' "$fallback"
    fi
}

usage() {
    echo "Usage: $(basename "$0") <agent_id> [OPTIONS]"
    echo "       $(basename "$0") --all [OPTIONS]"
    echo ""
    echo "List all KB content (documents, products, expert KB) for a LiveX agent."
    echo ""
    echo "Options:"
    echo "  --all            Audit KB for ALL agents on the account"
    echo "  --profile NAME   Use named credential profile"
    echo "  --env ENV        Environment: dev (default), staging, production"
    echo "  --wait-ready     Poll until all teach-ai documents report ready status"
    echo "  --wait-timeout N Stop waiting after N seconds (default: 300)"
    echo "  --poll-interval N"
    echo "                   Poll every N seconds while waiting (default: 10)"
    echo "  --json           Output structured JSON to stdout"
    echo "  --help           Show this help message"
    exit "${1:-$EXIT_USAGE}"
}

fetch_docs_json() {
    local docs_resp raw_docs enriched doc_id doc_size chunk_count

    docs_resp=$(_resilient_api_get "${LIVEX_API_HOST}/api/v1/documents?account_id=${LIVEX_ACCOUNT_ID}&corpus_id=${CORPUS_ID}" '{"response":[]}' "teach-ai documents")
    raw_docs=$(printf '%s\n' "$docs_resp" | jq '.response // []' 2>/dev/null || echo "[]")

    # First pass: mark status using doc_size
    enriched=$(printf '%s\n' "$raw_docs" | jq '
        map(. + {
            processing_status: (if (.doc_size // 0) > 0 then "ready" else "unknown" end),
            is_ready: ((.doc_size // 0) > 0),
            chunk_count: null
        })
    ' 2>/dev/null || echo "[]")

    # Second pass: for docs with doc_size=0, verify via chunk count (platform bug:
    # gateway never updates doc_size after processing, so doc_size=0 is unreliable).
    local unknown_ids
    unknown_ids=$(printf '%s\n' "$enriched" | jq -r '[.[] | select(.is_ready != true) | .document_id] | .[]' 2>/dev/null)

    if [[ -n "$unknown_ids" ]]; then
        while IFS= read -r doc_id; do
            [[ -n "$doc_id" ]] || continue
            chunk_count=$(get_doc_chunk_count "$doc_id")
            if [[ "$chunk_count" =~ ^[0-9]+$ && "$chunk_count" -gt 0 ]]; then
                enriched=$(printf '%s\n' "$enriched" | jq --arg did "$doc_id" --argjson cc "$chunk_count" '
                    map(if .document_id == $did then . + {processing_status: "ready", is_ready: true, chunk_count: $cc} else . end)
                ' 2>/dev/null || printf '%s\n' "$enriched")
            else
                enriched=$(printf '%s\n' "$enriched" | jq --arg did "$doc_id" '
                    map(if .document_id == $did then . + {processing_status: "processing"} else . end)
                ' 2>/dev/null || printf '%s\n' "$enriched")
            fi
        done <<< "$unknown_ids"
    fi

    printf '%s\n' "$enriched"
}

AGENT_ID=""
ENV_FLAG="dev"
JSON_OUTPUT=false
WAIT_READY=false
WAIT_TIMEOUT=300
POLL_INTERVAL=10
ALL_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage $EXIT_SUCCESS ;;
        --all) ALL_MODE=true; shift ;;
        --env) ENV_FLAG="${2:?--env requires a value}"; shift 2 ;;
        --profile) export LIVEX_PROFILE="${2:?--profile requires a name}"; shift 2 ;;
        --wait-ready) WAIT_READY=true; shift ;;
        --wait-timeout) WAIT_TIMEOUT="${2:?--wait-timeout requires a value}"; shift 2 ;;
        --poll-interval) POLL_INTERVAL="${2:?--poll-interval requires a value}"; shift 2 ;;
        --json) JSON_OUTPUT=true; shift ;;
        --yes) shift ;;  # tolerated — read-only command
        -*) die $EXIT_USAGE "Unknown option: $1\nRun with --help for usage." ;;
        *)
            if [[ -z "$AGENT_ID" ]]; then
                AGENT_ID="$1"
            else
                die $EXIT_USAGE "Unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

if [[ "$ALL_MODE" == "true" && -n "$AGENT_ID" ]]; then
    die $EXIT_USAGE "--all and a specific agent_id are mutually exclusive"
fi
if [[ "$ALL_MODE" == "false" ]]; then
    [[ -n "$AGENT_ID" ]] || usage
fi

check_deps
load_env
resolve_api_host "$ENV_FLAG"

[[ "$WAIT_TIMEOUT" =~ ^[0-9]+$ ]] || die $EXIT_USAGE "--wait-timeout must be an integer number of seconds"
if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$POLL_INTERVAL" -le 0 ]]; then
    die $EXIT_USAGE "--poll-interval must be a positive integer number of seconds"
fi

# --- All-agents mode ---
if [[ "$ALL_MODE" == "true" ]]; then
    info "Listing agents for account ${LIVEX_ACCOUNT_ID}..."
    list_resp=$(api_get "${LIVEX_API_HOST}/api/v1/agents/accounts/${LIVEX_ACCOUNT_ID}")

    # Extract agent IDs and names
    _all_tmpdir=$(mktemp -d)
    trap 'rm -rf "$_all_tmpdir"' EXIT
    echo "$list_resp" | jq -r '
        (if type == "array" then . elif .response then .response elif .agents then .agents elif .data then .data else [.] end)
        | if type == "array" then . else [.] end
        | .[] | [.id, (.nickname // .name // "unnamed")] | @tsv
    ' 2>/dev/null > "$_all_tmpdir/agents.tsv"

    agent_total=$(wc -l < "$_all_tmpdir/agents.tsv" | tr -d ' ')
    if [[ "$agent_total" -eq 0 ]]; then
        die $EXIT_API "No agents found on account ${LIVEX_ACCOUNT_ID}"
    fi
    info "Found ${agent_total} agent(s). Auditing KB (max 4 concurrent)..."

    # Run per-agent KB list in parallel (max 4 at a time)
    _running=0
    _idx=0
    while IFS=$'\t' read -r _aid _aname; do
        [[ -n "$_aid" ]] || continue
        _idx=$((_idx + 1))
        (
            # Each worker writes its result to a temp file
            _out="$_all_tmpdir/result_${_aid}.json"
            _agent_resp=$(_resilient_api_get "${LIVEX_API_HOST}/api/v1/agent?account_id=${LIVEX_ACCOUNT_ID}&agent_id=${_aid}" '{"response":{"config":{}}}' "agent ${_aid}")
            _corpus=$( echo "$_agent_resp" | jq -r '.response.config.tools.document_qa.corpus_id // .response.corpus_id // empty' 2>/dev/null)
            _pstore_ids=$(echo "$_agent_resp" | jq -r '[.response.config.tools.document_qa.product_stores[]?.id // empty] | join(",")' 2>/dev/null)

            _dcount=0
            if [[ -n "$_corpus" ]]; then
                _docs=$(_resilient_api_get "${LIVEX_API_HOST}/api/v1/documents?account_id=${LIVEX_ACCOUNT_ID}&corpus_id=${_corpus}" '{"response":[]}' "docs")
                _dcount=$(echo "$_docs" | jq '.response // [] | length' 2>/dev/null || echo 0)
            fi

            _pcount=0
            if [[ -n "$_pstore_ids" ]]; then
                _prods=$(_resilient_api_get "${LIVEX_API_HOST}/api/v1/product-knowledge?account_id=${LIVEX_ACCOUNT_ID}" '{"response":[]}' "products")
                _pcount=$(echo "$_prods" | jq --arg ids "$_pstore_ids" '($ids | split(",")) as $id_list | [.response[]? | select(.document_id as $did | $id_list | any(. == $did))] | length' 2>/dev/null || echo 0)
            fi

            _expert_resp=$(_resilient_api_get "${LIVEX_API_HOST}/api/v1/expert-knowledge/accounts/${LIVEX_ACCOUNT_ID}" '{"response":[]}' "expert")
            _ecount=$(echo "$_expert_resp" | jq --arg aid "$_aid" '[.response[]? // .[]? | select(.agent_id == $aid or (.agent_id | type == "array" and any(. == $aid)))] | length' 2>/dev/null || echo 0)

            jq -n --arg id "$_aid" --arg name "$_aname" --argjson docs "$_dcount" --argjson prods "$_pcount" --argjson expert "$_ecount" \
                '{agent_id: $id, agent_name: $name, docs: $docs, products: $prods, expert: $expert}' > "$_out"
        ) &
        _running=$((_running + 1))
        if [[ "$_running" -ge 4 ]]; then
            wait -n 2>/dev/null || wait
            _running=$((_running - 1))
        fi
    done < "$_all_tmpdir/agents.tsv"
    wait

    # Collect results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        jq -s '.' "$_all_tmpdir"/result_*.json 2>/dev/null
    else
        echo "" >&2
        printf "  ${BOLD}%-35s %-10s %-10s %-10s${NC}\n" "AGENT" "DOCS" "PRODUCTS" "EXPERT" >&2
        printf "  %-35s %-10s %-10s %-10s\n" "---" "---" "---" "---" >&2
        _total_docs=0 _total_prods=0 _total_expert=0
        for _rf in "$_all_tmpdir"/result_*.json; do
            [[ -f "$_rf" ]] || continue
            _rname=$(jq -r '.agent_name' "$_rf" 2>/dev/null)
            _rdocs=$(jq -r '.docs' "$_rf" 2>/dev/null)
            _rprods=$(jq -r '.products' "$_rf" 2>/dev/null)
            _rexpert=$(jq -r '.expert' "$_rf" 2>/dev/null)
            [[ ${#_rname} -gt 33 ]] && _rname="${_rname:0:30}..."
            printf "  %-35s %-10s %-10s %-10s\n" "$_rname" "$_rdocs" "$_rprods" "$_rexpert" >&2
            _total_docs=$((_total_docs + _rdocs))
            _total_prods=$((_total_prods + _rprods))
            _total_expert=$((_total_expert + _rexpert))
        done
        echo "" >&2
        printf "  ${BOLD}%-35s %-10s %-10s %-10s${NC}\n" "TOTAL" "$_total_docs" "$_total_prods" "$_total_expert" >&2
        echo "" >&2
    fi
    success "Account-wide KB audit: ${agent_total} agents from ${ENV_LABEL}"
    exit $EXIT_SUCCESS
fi

info "Fetching agent config..."
agent_resp=$(api_get "${LIVEX_API_HOST}/api/v1/agent?account_id=${LIVEX_ACCOUNT_ID}&agent_id=${AGENT_ID}")
CORPUS_ID=$(extract_corpus_id "$agent_resp")
PRODUCT_STORE_IDS=$(printf '%s\n' "$agent_resp" | jq -r '[.response.config.tools.document_qa.product_stores[]?.id // empty] | join(",")' 2>/dev/null)
SOURCES=$(printf '%s\n' "$agent_resp" | jq -r '[.response.config.tools.document_qa.sources[]? // empty]' 2>/dev/null)

doc_count=0
docs_json="[]"
if [[ -n "$CORPUS_ID" ]]; then
    docs_json=$(fetch_docs_json)
    doc_count=$(printf '%s\n' "$docs_json" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$WAIT_READY" == "true" && "$doc_count" -gt 0 ]]; then
        info "Waiting for all teach-ai documents to finish processing..."
        deadline=$((SECONDS + WAIT_TIMEOUT))
        stale_polls=0
        prev_processing_count=""
        while true; do
            doc_processing_count=$(printf '%s\n' "$docs_json" | jq '[.[] | select(.is_ready != true)] | length' 2>/dev/null || echo 0)
            if [[ "$doc_processing_count" == "0" ]]; then
                success "All teach-ai documents report ready status"
                break
            fi
            if (( SECONDS >= deadline )); then
                warn "Timed out after ${WAIT_TIMEOUT}s waiting for teach-ai documents to finish processing"
                break
            fi
            # Detect stale corpus: if count unchanged for 3 consecutive polls, warn
            if [[ "$doc_processing_count" == "$prev_processing_count" ]]; then
                stale_polls=$((stale_polls + 1))
            else
                stale_polls=0
            fi
            if [[ "$stale_polls" -ge 3 && "$doc_processing_count" == "$doc_count" ]]; then
                warn "All ${doc_count} documents show doc_size=0 after ${stale_polls} polls — known platform bug: gateway never updates doc_size after processing. Falling back to chunk verification..."
                # Re-fetch with chunk verification (fetch_docs_json does this automatically)
                docs_json=$(fetch_docs_json)
                break
            fi
            prev_processing_count="$doc_processing_count"
            info "${doc_processing_count} document(s) still processing. Polling again in ${POLL_INTERVAL}s..."
            sleep "$POLL_INTERVAL"
            docs_json=$(fetch_docs_json)
        done
    fi
fi

product_store_count=0
product_item_count=0
products_json="[]"
products_resp=$(_resilient_api_get "${LIVEX_API_HOST}/api/v1/product-knowledge?account_id=${LIVEX_ACCOUNT_ID}" '{"response":[]}' "product KB")
all_products=$(printf '%s\n' "$products_resp" | jq '.response // []' 2>/dev/null || echo "[]")

if [[ -n "$PRODUCT_STORE_IDS" ]]; then
    products_json=$(printf '%s\n' "$all_products" | jq --arg ids "$PRODUCT_STORE_IDS" '
        ($ids | split(",")) as $id_list |
        [.[] | select(.document_id as $did | $id_list | any(. == $did))]
    ' 2>/dev/null || echo "[]")
else
    products_json="[]"
fi
product_store_count=$(printf '%s\n' "$products_json" | jq 'length' 2>/dev/null || echo 0)
product_item_count=$(printf '%s\n' "$products_json" | jq '[.[].data // [] | length] | add // 0' 2>/dev/null || echo 0)

expert_count=0
expert_json="[]"
expert_resp=$(_resilient_api_get "${LIVEX_API_HOST}/api/v1/expert-knowledge/accounts/${LIVEX_ACCOUNT_ID}" '{"response":[]}' "expert KB")
expert_json=$(printf '%s\n' "$expert_resp" | jq --arg aid "$AGENT_ID" '[
    .response[]? // .[]? |
    select(.agent_id == $aid or (.agent_id | type == "array" and any(. == $aid)))
]' 2>/dev/null || echo "[]")
expert_count=$(printf '%s\n' "$expert_json" | jq 'length' 2>/dev/null || echo 0)

doc_ready_count=$(printf '%s\n' "$docs_json" | jq '[.[] | select(.is_ready == true)] | length' 2>/dev/null || echo 0)
doc_processing_count=$(printf '%s\n' "$docs_json" | jq '[.[] | select(.is_ready != true)] | length' 2>/dev/null || echo 0)

if [[ "$JSON_OUTPUT" == "true" ]]; then
    # Pipe large JSON through stdin to avoid "Argument list too long" on large corpora
    jq -n \
        --arg corpus_id "${CORPUS_ID:-}" \
        --argjson sources "${SOURCES:-[]}" \
        '{corpus_id: $corpus_id, sources: $sources}' \
    | jq --slurpfile docs <(printf '%s\n' "$docs_json") \
          --slurpfile products <(printf '%s\n' "$products_json") \
          --slurpfile expert <(printf '%s\n' "$expert_json") \
        '. + {
            documents: {
                count: ($docs[0] | length),
                ready_count: ([$docs[0][] | select(.is_ready == true)] | length),
                processing_count: ([$docs[0][] | select(.is_ready != true)] | length),
                items: $docs[0]
            },
            products: {
                store_count: ($products[0] | length),
                item_count: ([$products[0][].data // [] | length] | add // 0),
                stores: $products[0]
            },
            expert_kb: {
                count: ($expert[0] | length),
                entries: $expert[0]
            }
        }'
else
    echo "" >&2
    echo -e "${BOLD}=== KB Inventory: ${AGENT_ID} (${ENV_LABEL}) ===${NC}" >&2
    echo "" >&2

    echo -e "${BOLD}Documents (${doc_count}; ready: ${doc_ready_count}, processing: ${doc_processing_count}):${NC}" >&2
    if [[ "$doc_count" -gt 0 ]]; then
        printf '%s\n' "$docs_json" | jq -r '.[] | "  \(.document_id[0:8])  \(.title // "untitled" | .[0:40])  \(.doc_type // "?")  status: \(.processing_status)\(if .chunk_count then "  chunks: \(.chunk_count)" else "" end)  size: \(.doc_size // 0)  \(.latest_file_updated_at // "" | .[0:10])"' >&2
    else
        echo "  (none)" >&2
    fi
    echo "" >&2

    echo -e "${BOLD}Products (${product_store_count} store(s), ${product_item_count} items):${NC}" >&2
    if [[ "$product_store_count" -gt 0 ]]; then
        printf '%s\n' "$products_json" | jq -r '.[] | "  \(.document_id[0:8])  \(.customer_name // "unnamed" | .[0:40])  status: \(if .status == 1 then "active" elif .status == 2 then "processing" else "unknown" end)  items: \(.data // [] | length)"' >&2
    else
        echo "  (none)" >&2
    fi
    echo "" >&2

    echo -e "${BOLD}Expert KB (${expert_count} entries):${NC}" >&2
    if [[ "$expert_count" -gt 0 ]]; then
        printf '%s\n' "$expert_json" | jq -r '.[0:5][] | "  \(.expert_knowledge_id[0:8] // "?")  \(.question[0:70])"' >&2
        if [[ "$expert_count" -gt 5 ]]; then
            echo "  ... and $((expert_count - 5)) more" >&2
        fi
    else
        echo "  (none)" >&2
    fi
    echo "" >&2

    echo -e "${BOLD}Sources config:${NC}" >&2
    echo "  ${SOURCES:-[]}" >&2
    if [[ "$product_store_count" -gt 0 ]]; then
        has_product_search=$(echo "${SOURCES:-[]}" | jq 'any(. == "knowledge_product_search")' 2>/dev/null || echo "false")
        if [[ "$has_product_search" != "true" ]]; then
            warn "Product stores exist but 'knowledge_product_search' is NOT in sources array"
        fi
    fi
    echo "" >&2
fi

success "KB inventory for ${AGENT_ID} from ${ENV_LABEL}"

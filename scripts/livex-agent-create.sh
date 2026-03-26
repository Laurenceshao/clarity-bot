#!/bin/bash
# livex-agent-create.sh — Create a new LiveX agent (2-step: corpus + agent)
#
# Usage:
#   ./livex-agent-create.sh --name "Agent Name" [OPTIONS]
#
# Options:
#   --name NAME         Agent display name (required; optional with --duplicate)
#   --desc DESC         Agent description
#   --config JSON       Initial config override (JSON string or @file)
#   --from AGENT_ID     Clone config from existing agent (new corpus)
#   --duplicate ID      Server-side duplicate (shared corpus, V2 semantics)
#   --from-profile PRF  Profile for --from source (cross-account clone)
#   --env ENV           Environment: dev (default), staging, production
#   --profile PROFILE   Target profile
#   --yes               Skip confirmation prompt for production
#   --help              Show this help message
#
# Examples:
#   ./livex-agent-create.sh --name "My Agent"
#   ./livex-agent-create.sh --name "My Agent" --desc "Customer support bot"
#   ./livex-agent-create.sh --name "Clone" --from abc-123
#   ./livex-agent-create.sh --name "Clone" --from abc-123 --from-profile dev --profile prod
#   ./livex-agent-create.sh --duplicate abc-123 --name "Copy of Agent"

source "$(dirname "$0")/_lib.sh"

# --- Baseline validation ---
_run_baseline_check() {
    local agent_id="$1"
    local baseline_file="${SCRIPT_DIR}/../skills/config-manage/references/baseline-values.json"
    if [[ ! -f "$baseline_file" ]]; then
        return 0
    fi
    info "Checking baseline config values..."
    local agent_resp config_json
    agent_resp=$(api_get "${LIVEX_API_HOST}/api/v1/agent?account_id=${LIVEX_ACCOUNT_ID}&agent_id=${agent_id}" 2>/dev/null) || { warn "Could not read agent for baseline check"; return 0; }
    config_json=$(extract_config "$agent_resp")

    local total=0 mismatches=0
    echo -e "\n  ${BOLD}Baseline Validation:${NC}" >&2
    while IFS=$'\t' read -r path expected; do
        [[ -n "$path" ]] || continue
        total=$((total + 1))
        local actual
        actual=$(echo "$config_json" | jq -r "${path} // \"(not set)\"" 2>/dev/null)
        local expected_str
        expected_str=$(echo "$expected" | jq -r 'if type == "string" then . else tostring end' 2>/dev/null || echo "$expected")
        local actual_str
        actual_str=$(echo "$actual" | jq -r 'if type == "string" then . else tostring end' 2>/dev/null || echo "$actual")
        if [[ "$actual_str" == "$expected_str" ]]; then
            echo -e "  ${GREEN}MATCH${NC}     ${path}: ${actual_str}" >&2
        else
            echo -e "  ${RED}MISMATCH${NC}  ${path}: got ${actual_str}, expected ${expected_str}" >&2
            mismatches=$((mismatches + 1))
        fi
    done < <(jq -r '.fields[] | [.path, (.expected | tojson)] | @tsv' "$baseline_file" 2>/dev/null)

    if [[ "$mismatches" -gt 0 ]]; then
        warn "${mismatches}/${total} fields differ from baseline. Use --apply-baseline --yes to auto-fix."
    else
        success "All ${total} baseline fields match"
    fi
}

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") --name <name> [OPTIONS]"
    echo ""
    echo "Create a new LiveX agent (2-step: corpus creation + agent creation)."
    echo ""
    echo "Options:"
    echo "  --name NAME         Agent display name (required; optional with --duplicate)"
    echo "  --desc DESC         Agent description"
    echo "  --config JSON       Initial config override (JSON or @file)"
    echo "  --from AGENT_ID     Clone config from existing agent (new corpus)"
    echo "  --duplicate ID      Server-side duplicate (shared corpus, V2 semantics)"
    echo "  --from-profile PRF  Profile for --from source (cross-account clone)"
    echo "  --env ENV           Environment: dev (default), staging, production"
    echo "  --profile PROFILE   Target profile"
    echo "  --yes               Skip confirmation prompt for production"
    echo "  --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") --name \"My Agent\""
    echo "  $(basename "$0") --name \"My Agent\" --desc \"Customer support\""
    echo "  $(basename "$0") --name \"Clone\" --from abc-123-def"
    echo "  $(basename "$0") --name \"Clone\" --from abc-123 --from-profile dev --profile prod"
    echo "  $(basename "$0") --duplicate abc-123 --name \"Copy of Agent\""
    exit "${1:-$EXIT_USAGE}"
}

# --- Parse args ---
AGENT_NAME=""
AGENT_DESC=""
CONFIG_INPUT=""
CLONE_FROM=""
DUPLICATE_FROM=""
FROM_PROFILE=""
ENV_FLAG="dev"
SKIP_CONFIRM="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)        usage $EXIT_SUCCESS ;;
        --name)           AGENT_NAME="${2:?--name requires a value}"; shift 2 ;;
        --desc)           AGENT_DESC="${2:?--desc requires a value}"; shift 2 ;;
        --config)         CONFIG_INPUT="${2:?--config requires JSON or @file}"; shift 2 ;;
        --from)           CLONE_FROM="${2:?--from requires an agent_id}"; shift 2 ;;
        --duplicate)      DUPLICATE_FROM="${2:?--duplicate requires a source agent_id}"; shift 2 ;;
        --from-profile)   FROM_PROFILE="${2:?--from-profile requires a name}"; shift 2 ;;
        --env)            ENV_FLAG="${2:?--env requires a value}"; shift 2 ;;
        --profile)        export LIVEX_PROFILE="${2:?--profile requires a name}"; shift 2 ;;
        --yes)            SKIP_CONFIRM="true"; shift ;;
        -*)               die $EXIT_USAGE "Unknown option: $1\nRun with --help for usage." ;;
        *)                die $EXIT_USAGE "Unexpected argument: $1\nUse --name to set the agent name." ;;
    esac
done

if [[ -n "$DUPLICATE_FROM" ]]; then
    [[ -z "$CLONE_FROM" ]] || die $EXIT_USAGE "--duplicate and --from are mutually exclusive"
    [[ -z "$CONFIG_INPUT" ]] || die $EXIT_USAGE "--duplicate and --config are mutually exclusive"
    [[ -z "$FROM_PROFILE" ]] || die $EXIT_USAGE "--duplicate and --from-profile are mutually exclusive"
fi

if [[ -z "$AGENT_NAME" && -z "$DUPLICATE_FROM" ]]; then
    die $EXIT_USAGE "Missing required --name flag.\nRun with --help for usage."
fi

# --- Init ---
check_deps
load_env
resolve_api_host "$ENV_FLAG"
export SKIP_CONFIRM

# --- Duplicate flow (short-circuit) ---
if [[ -n "$DUPLICATE_FROM" ]]; then
    confirm_production
    info "Duplicating agent ${DUPLICATE_FROM} in ${ENV_LABEL}..."
    dup_url="${LIVEX_API_HOST}/api/v1/accounts/${LIVEX_ACCOUNT_ID}/agents/${DUPLICATE_FROM}/duplicate-agent"
    _dup_raw=$(curl -s --max-time 30 -w "\n%{http_code}" \
        -X POST "$dup_url" \
        -H "X-API-KEY: ${LIVEX_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{}" 2>/dev/null) || die $EXIT_API "Network error: could not reach ${dup_url}"
    _dup_http=$(echo "$_dup_raw" | tail -n1)
    dup_resp=$(echo "$_dup_raw" | sed '$d')
    if [[ "$_dup_http" == "404" || "$_dup_http" == "405" ]]; then
        warn "duplicate-agent endpoint unavailable (HTTP ${_dup_http}) — falling back to manual clone"
        CLONE_FROM="$DUPLICATE_FROM"
        DUPLICATE_FROM=""
    elif [[ "$_dup_http" -lt 200 || "$_dup_http" -ge 300 ]]; then
        die $EXIT_API "Duplicate failed (HTTP ${_dup_http}): $(echo "$dup_resp" | jq -r '.error.message // .error // .message // "unknown error"' 2>/dev/null)"
    fi
    if [[ -n "$DUPLICATE_FROM" ]]; then
        agent_id=$(echo "$dup_resp" | jq -r '.response.id // .data.id // .id // empty' 2>/dev/null)
        if [[ -z "$agent_id" ]]; then
            die $EXIT_API "Failed to extract agent_id from duplicate response: $(echo "$dup_resp" | jq -c . 2>/dev/null)"
        fi
        # Optional rename
        if [[ -n "$AGENT_NAME" ]]; then
            info "Renaming duplicate to \"${AGENT_NAME}\"..."
            rename_body=$(jq -n --arg name "$AGENT_NAME" '{name: $name}')
            api_put "${LIVEX_API_HOST}/api/v1/agent-config/accounts/${LIVEX_ACCOUNT_ID}/agents/${agent_id}" "$rename_body" >/dev/null 2>&1 || warn "Rename failed — agent created with default name"
        fi
        # Output
        echo "" >&2
        success "Duplicated agent from ${DUPLICATE_FROM}"
        echo -e "  ${BOLD}Agent ID:${NC}     ${agent_id}" >&2
        echo -e "  ${BOLD}Environment:${NC}  ${ENV_LABEL}" >&2
        echo -e "  ${BOLD}Source:${NC}       ${DUPLICATE_FROM}" >&2
        echo -e "  ${BOLD}Corpus:${NC}       shared with source (V2 semantics)" >&2
        # Run baseline validation (dry-run report)
        _run_baseline_check "$agent_id"
        echo "$agent_id"
        exit 0
    fi
fi

# --- Resolve config ---
config_json="{}"

if [[ -n "$CLONE_FROM" ]]; then
    # Clone from existing agent
    if [[ -n "$FROM_PROFILE" ]]; then
        info "Reading source agent from profile '${FROM_PROFILE}'..."
        saved_profile="${LIVEX_PROFILE:-}"
        export LIVEX_PROFILE="$FROM_PROFILE"
        load_env
        source_resp=$(api_get "${LIVEX_API_HOST}/api/v1/agent?account_id=${LIVEX_ACCOUNT_ID}&agent_id=${CLONE_FROM}")
        # Restore target profile
        if [[ -n "$saved_profile" ]]; then
            export LIVEX_PROFILE="$saved_profile"
        else
            unset LIVEX_PROFILE
        fi
        load_env
    else
        info "Reading source agent ${CLONE_FROM}..."
        source_resp=$(api_get "${LIVEX_API_HOST}/api/v1/agent?account_id=${LIVEX_ACCOUNT_ID}&agent_id=${CLONE_FROM}")
    fi
    config_json=$(extract_config "$source_resp")
    # Strip reserved fields that shouldn't be cloned (including nested corpus_id)
    config_json=$(echo "$config_json" | jq 'del(.agent_id, .account_id, .published_id, .corpus_id, .user_id, .created_at, .updated_at, .tools.document_qa.corpus_id, .tools.workflow_tool.workflow_list)' 2>/dev/null)
    # Warn if source had agentflows (not cloned)
    _source_flows=$(echo "$source_resp" | jq -r '.response.config.tools.workflow_tool.workflow_list // [] | length' 2>/dev/null || echo 0)
    if [[ "${_source_flows:-0}" -gt 0 ]]; then
        warn "Source had ${_source_flows} flow(s) — not cloned. Use livex-flow-create.sh --from to copy flows separately."
    fi
    info "Cloned config from ${CLONE_FROM} (reserved fields stripped)"
elif [[ -n "$CONFIG_INPUT" ]]; then
    # Config from argument
    if [[ "$CONFIG_INPUT" == @* ]]; then
        filepath="${CONFIG_INPUT#@}"
        [[ -f "$filepath" ]] || die $EXIT_USAGE "File not found: $filepath"
        config_json=$(cat "$filepath")
    else
        config_json="$CONFIG_INPUT"
    fi
    # Validate JSON
    if ! echo "$config_json" | jq . >/dev/null 2>&1; then
        die $EXIT_USAGE "Invalid JSON: $(echo "$config_json" | jq . 2>&1 | head -1)"
    fi
fi

# --- Production confirmation ---
confirm_production

# --- Step 1: Create corpus ---
corpus_title=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "corpus-$(date +%s)")
corpus_body=$(jq -n --arg title "$corpus_title" --arg acct "$LIVEX_ACCOUNT_ID" \
    '{"title": $title, "account_id": $acct}')

info "Creating corpus in ${ENV_LABEL}..."
corpus_resp=$(api_post "${LIVEX_API_HOST}/api/v1/corpus" "$corpus_body")

# Check for API error in response body
if echo "$corpus_resp" | jq -e '.error' >/dev/null 2>&1; then
    error_msg=$(echo "$corpus_resp" | jq -r '.error.message // .error // "unknown error"' 2>/dev/null)
    die $EXIT_API "Corpus creation failed: ${error_msg}"
fi

corpus_id=$(echo "$corpus_resp" | jq -r '.response.corpus_id // .data.corpus_id // .corpus_id // empty' 2>/dev/null)
if [[ -z "$corpus_id" ]]; then
    die $EXIT_API "Failed to extract corpus_id from response: $(echo "$corpus_resp" | jq -c . 2>/dev/null || echo "$corpus_resp")"
fi
success "Created corpus: ${corpus_id}"

# --- Step 2: Create agent ---
# Inject new corpus_id into config (ensures KB uploads target the correct corpus)
if echo "$config_json" | jq -e '.tools.document_qa' >/dev/null 2>&1; then
    config_json=$(echo "$config_json" | jq --arg cid "$corpus_id" '.tools.document_qa.corpus_id = $cid')
fi

agent_body=$(jq -n \
    --arg corpus "$corpus_id" \
    --arg name "$AGENT_NAME" \
    --arg desc "$AGENT_DESC" \
    --arg acct "$LIVEX_ACCOUNT_ID" \
    --argjson config "$config_json" \
    '{
        "corpus_id": $corpus,
        "name": $name,
        "desc": $desc,
        "account_id": $acct,
        "config": $config
    }')

info "Creating agent \"${AGENT_NAME}\" in ${ENV_LABEL}..."
agent_resp=$(api_post "${LIVEX_API_HOST}/api/v1/agent" "$agent_body")

# Check for API error in response body
if echo "$agent_resp" | jq -e '.error' >/dev/null 2>&1; then
    error_msg=$(echo "$agent_resp" | jq -r '.error.message // .error // "unknown error"' 2>/dev/null)
    die $EXIT_API "Agent creation failed: ${error_msg}"
fi

agent_id=$(echo "$agent_resp" | jq -r '.response.id // .data.id // .id // empty' 2>/dev/null)
published_id=$(echo "$agent_resp" | jq -r '.response.published_id // .data.published_id // .published_id // empty' 2>/dev/null)

if [[ -z "$agent_id" ]]; then
    die $EXIT_API "Failed to extract agent_id from response: $(echo "$agent_resp" | jq -c . 2>/dev/null || echo "$agent_resp")"
fi

# --- Output ---
echo "" >&2
success "Created agent \"${AGENT_NAME}\""
echo -e "  ${BOLD}Agent ID:${NC}     ${agent_id}" >&2
echo -e "  ${BOLD}Published ID:${NC} ${published_id}" >&2
echo -e "  ${BOLD}Corpus ID:${NC}    ${corpus_id}" >&2
echo -e "  ${BOLD}Environment:${NC}  ${ENV_LABEL}" >&2

if [[ -n "$CLONE_FROM" ]]; then
    echo -e "  ${BOLD}Cloned from:${NC} ${CLONE_FROM}" >&2

    # Post-clone corpus isolation verification
    info "Verifying corpus isolation..."
    _source_corpus=$(extract_corpus_id "$source_resp")
    _source_corpus="${_source_corpus:-(none)}"
    _new_check=$(api_get "${LIVEX_API_HOST}/api/v1/agent?account_id=${LIVEX_ACCOUNT_ID}&agent_id=${agent_id}")
    _new_corpus=$(extract_corpus_id "$_new_check")
    _new_corpus="${_new_corpus:-(none)}"

    echo -e "  ${BOLD}Source corpus:${NC} ${_source_corpus}" >&2
    echo -e "  ${BOLD}New corpus:${NC}    ${_new_corpus}" >&2

    if [[ "$_source_corpus" != "(none)" && "$_new_corpus" != "(none)" && "$_source_corpus" != "$_new_corpus" ]]; then
        success "Corpus isolation verified: new agent has separate corpus"
    elif [[ "$_source_corpus" == "$_new_corpus" && "$_source_corpus" != "(none)" ]]; then
        warn "CORPUS COLLISION: new agent shares corpus_id with source! KB uploads will affect both agents."
    fi
fi

# Run baseline validation
_run_baseline_check "$agent_id"

# Output agent_id to stdout for piping
echo "$agent_id"

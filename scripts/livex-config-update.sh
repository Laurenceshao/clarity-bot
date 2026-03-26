#!/bin/bash
# livex-config-update.sh — Push partial config update to a LiveX agent
#
# Usage:
#   ./livex-config-update.sh <agent_id> <config> [OPTIONS]
#
# Arguments:
#   agent_id    The agent UUID
#   config      JSON string or @path/to/file.json
#
# Options:
#   --env ENV    Environment: dev (default), staging, production
#   --dry-run    Show what would be sent without sending
#   --yes        Skip confirmation prompt for production
#   --full-write Write via archived endpoint + debug code (gateway-stripped fields)
#   --field PATH Set a single field by jq path (use with --value or --value-json)
#   --value STR  String value for --field
#   --value-json JSON  Typed JSON value for --field (number, bool, array, object)
#   --help       Show this help message
#
# Examples:
#   ./livex-config-update.sh abc-123 '{"nickname":"new-name"}'
#   ./livex-config-update.sh abc-123 @changes.json
#   ./livex-config-update.sh abc-123 '{"nickname":"new-name"}' --dry-run
#   ./livex-config-update.sh abc-123 @changes.json --env production --yes
#   ./livex-config-update.sh abc-123 @voice-fix.json --full-write
#   ./livex-config-update.sh abc-123 @voice-fix.json --full-write --dry-run

source "$(dirname "$0")/_lib.sh"

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") <agent_id> <config> [OPTIONS]"
    echo ""
    echo "Push a partial config update to a LiveX agent (ES merge semantics)."
    echo "Only the fields you include will be updated; others remain unchanged."
    echo ""
    echo "Arguments:"
    echo "  agent_id    The agent UUID"
    echo "  config      JSON string or @path/to/file.json"
    echo ""
    echo "Options:"
    echo "  --env ENV    Environment: dev (default), staging, production"
    echo "  --dry-run    Show what would be sent without sending"
    echo "  --yes        Skip confirmation prompt for production"
    echo "  --full-write Write via archived endpoint + debug code (gateway-stripped fields)"
    echo "  --field PATH Set a single field by jq path (use with --value or --value-json)"
    echo "  --value STR  String value for --field"
    echo "  --value-json JSON  Typed JSON value for --field (number, bool, array, object)"
    echo "  --help       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") abc-123 '{\"nickname\":\"new-name\"}'"
    echo "  $(basename "$0") abc-123 @changes.json"
    echo "  $(basename "$0") abc-123 '{\"personality\":\"friendly\"}' --dry-run"
    echo "  $(basename "$0") abc-123 @voice-fix.json --full-write"
    echo "  $(basename "$0") abc-123 @voice-fix.json --full-write --dry-run"
    echo "  $(basename "$0") abc-123 --field .nickname --value 'New Name'"
    echo "  $(basename "$0") abc-123 --field .voice.speaking_speed --value-json 1.2"
    echo "  $(basename "$0") abc-123 --field .business_voice.enabled --value-json true"
    exit "${1:-$EXIT_USAGE}"
}

# --- Parse args ---
AGENT_ID=""
CONFIG_INPUT=""
ENV_FLAG="dev"
DRY_RUN=false
SKIP_CONFIRM="false"
FULL_WRITE=false
FIELD_PATH=""
FIELD_VALUE=""
FIELD_VALUE_JSON=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)    usage $EXIT_SUCCESS ;;
        --env)        ENV_FLAG="${2:?--env requires a value}"; shift 2 ;;
        --profile)    export LIVEX_PROFILE="${2:?--profile requires a name}"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --yes)        SKIP_CONFIRM="true"; shift ;;
        --full-write) FULL_WRITE=true; shift ;;
        --field)      FIELD_PATH="${2:?--field requires a jq path}"; shift 2 ;;
        --value)      FIELD_VALUE="${2:?--value requires a string}"; shift 2 ;;
        --value-json) FIELD_VALUE_JSON="${2:?--value-json requires valid JSON}"; shift 2 ;;
        -*)           die $EXIT_USAGE "Unknown option: $1\nRun with --help for usage." ;;
        *)
            if [[ -z "$AGENT_ID" ]]; then
                AGENT_ID="$1"
            elif [[ -z "$CONFIG_INPUT" ]]; then
                CONFIG_INPUT="$1"
            else
                die $EXIT_USAGE "Unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

# --- Field-path mode: construct config_json from --field + --value/--value-json ---
if [[ -n "$FIELD_PATH" ]]; then
    # Validate: need either --value or --value-json
    if [[ -z "$FIELD_VALUE" && -z "$FIELD_VALUE_JSON" ]]; then
        die $EXIT_USAGE "--field requires either --value or --value-json"
    fi
    if [[ -n "$FIELD_VALUE" && -n "$FIELD_VALUE_JSON" ]]; then
        die $EXIT_USAGE "Use either --value (string) or --value-json (typed), not both"
    fi
    # Require agent_id but not config positional arg
    [[ -n "$AGENT_ID" ]] || usage
    # Path-level writability validation
    if [[ "$FULL_WRITE" != "true" ]]; then
        _load_field_manifest
        if [[ "$_MANIFEST_LOADED" == "true" ]]; then
            top_key=$(echo "$FIELD_PATH" | sed 's/^\.\{0,1\}\([^.]*\).*/\1/')
            wrt=$(_check_field_writability ".$top_key")
            if [[ "$wrt" == "read_only" ]]; then
                warn "Field '${top_key}' is read-only (gateway_write: false) — the API will silently ignore it"
            fi
        fi
    fi
    # Construct config JSON from field path using jq setpath
    # Handles array indices: .voice.language_models[0].code → ["voice","language_models",0,"code"]
    # Reject [] iterator syntax — can't setpath on all elements; use --value-json for whole array
    if echo "$FIELD_PATH" | grep -q '\[\]'; then
        die $EXIT_USAGE "Array iterator '[]' not supported in --field paths. Use a specific index (e.g. [0]) or set the whole array with --field '.parent.array_field' --value-json '[...]'"
    fi
    _clean_path=$(echo "$FIELD_PATH" | sed 's/^\.//')
    local_path_json=$(echo "$_clean_path" | jq -R '
        # Split on "." but handle [N] array indices
        split(".") | [.[] |
            # Split "key[0]" into "key" and 0
            if test("\\[[0-9]+\\]$") then
                (capture("^(?<k>.+)\\[(?<i>[0-9]+)\\]$") | .k, (.i | tonumber))
            else . end
        ]
    ') || die $EXIT_USAGE "Failed to parse field path: $FIELD_PATH"
    if [[ -n "$FIELD_VALUE" ]]; then
        config_json=$(jq -n --arg val "$FIELD_VALUE" --argjson path "$local_path_json" 'setpath($path; $val)') || \
            die $EXIT_USAGE "Failed to construct JSON for path: $FIELD_PATH"
    else
        echo "$FIELD_VALUE_JSON" | jq -e . >/dev/null 2>&1 || die $EXIT_USAGE "Invalid JSON for --value-json: $FIELD_VALUE_JSON"
        config_json=$(jq -n --argjson val "$FIELD_VALUE_JSON" --argjson path "$local_path_json" 'setpath($path; $val)') || \
            die $EXIT_USAGE "Failed to construct JSON for path: $FIELD_PATH"
    fi
else
    [[ -n "$AGENT_ID" && -n "$CONFIG_INPUT" ]] || usage
fi

# --- Resolve config input (skip if field-path mode already set config_json) ---
if [[ -n "$FIELD_PATH" ]]; then
    : # config_json already constructed above
elif [[ "$CONFIG_INPUT" == @* ]]; then
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

if ! echo "$config_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    json_type=$(echo "$config_json" | jq -r 'type' 2>/dev/null || echo "unknown")
    die $EXIT_USAGE "Config update must be a JSON object (got ${json_type}). Wrap nested values like {\"voice\":{\"language_models\":[...]}}."
fi

# Check for empty config
field_count=$(echo "$config_json" | jq 'length' 2>/dev/null || echo 0)
if [[ "$field_count" == "0" ]]; then
    warn "Config is empty — no fields to update"
    exit $EXIT_SUCCESS
fi

# --- Init ---
check_deps
load_env
resolve_api_host "$ENV_FLAG"
export SKIP_CONFIRM

# Warn on read-only fields (manifest-driven, top-level keys only)
if [[ "$FULL_WRITE" == "true" ]]; then
    warn "Full-write mode: archived endpoint + debug code bypass"
else
    _load_field_manifest
fi
if [[ "$FULL_WRITE" != "true" && "$_MANIFEST_LOADED" == "true" ]]; then
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local_wrt=$(_check_field_writability ".$key")
        if [[ "$local_wrt" == "read_only" ]]; then
            warn "Field '${key}' is read-only (gateway_write: false) — the API will silently ignore it"
        fi
    done < <(echo "$config_json" | jq -r 'keys[]' 2>/dev/null)
fi

# --- Build URL and request body ---
read_url="${LIVEX_API_HOST}/api/v1/agent?account_id=${LIVEX_ACCOUNT_ID}&agent_id=${AGENT_ID}"

if [[ "$FULL_WRITE" == "true" ]]; then
    # Archived endpoint: bypasses gateway field stripping
    update_url="${LIVEX_API_HOST}/api/v1/archived/agent/${AGENT_ID}"
    update_url=$(_append_debug_code "$update_url")
    read_url=$(_append_debug_code "$read_url")

    # Fetch current agent to preserve MySQL top-level fields.
    # The archived endpoint's Agent.Update writes: name, nickname, desc, logo, custom_qr_code_url
    # (see copilot-api-gateway/api/models/agent.go:35-43). Omitting any field zeros it in MySQL.
    info "Fetching current agent state (to preserve top-level fields)..."
    agent_resp=$(api_get "$read_url")
    agent_name=$(echo "$agent_resp" | jq -r '.response.name // empty' 2>/dev/null)
    agent_nickname=$(echo "$agent_resp" | jq -r '.response.nickname // empty' 2>/dev/null)
    agent_desc=$(echo "$agent_resp" | jq -r '.response.desc // empty' 2>/dev/null)
    agent_logo=$(echo "$agent_resp" | jq -r '.response.logo // empty' 2>/dev/null)
    agent_qr_url=$(echo "$agent_resp" | jq -r '.response.custom_qr_code_url // empty' 2>/dev/null)

    # Build full request body with top-level fields + config delta
    request_body=$(jq -n \
        --arg id "$AGENT_ID" \
        --arg account_id "$LIVEX_ACCOUNT_ID" \
        --arg name "$agent_name" \
        --arg nickname "$agent_nickname" \
        --arg desc "$agent_desc" \
        --arg logo "$agent_logo" \
        --arg qr "$agent_qr_url" \
        --argjson cfg "$config_json" \
        '{id: $id, account_id: $account_id, name: $name, nickname: $nickname,
          desc: $desc, logo: $logo, custom_qr_code_url: $qr, config: $cfg}')
else
    # Standard endpoint
    update_url="${LIVEX_API_HOST}/api/v1/agent-config/accounts/${LIVEX_ACCOUNT_ID}/agents/${AGENT_ID}"
    request_body=$(jq -n --argjson cfg "$config_json" '{"config": $cfg}')
fi

# --- Dry run ---
if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY RUN — would send to ${ENV_LABEL}:"
    echo -e "${YELLOW}PUT${NC} ${update_url}" >&2
    echo -e "${YELLOW}Auth:${NC} X-API-KEY" >&2
    echo -e "${YELLOW}Body:${NC}" >&2
    echo "$request_body" | jq . >&2

    # Show diff of what would change
    if [[ "$FULL_WRITE" == "true" ]]; then
        # Already fetched for top-level fields
        current_config=$(extract_config "$agent_resp")
    else
        info "Fetching current config for comparison..."
        current_resp=$(api_get "$read_url")
        current_config=$(extract_config "$current_resp")
    fi

    # Merge preview: overlay new fields onto current
    merged=$(echo "$current_config" | jq --argjson new "$config_json" '. * $new' 2>/dev/null)

    info "Fields that would change:"
    diff_output=$(diff -u \
        --label "current" \
        --label "after update" \
        <(echo "$current_config" | jq -S . 2>/dev/null) \
        <(echo "$merged" | jq -S . 2>/dev/null) 2>/dev/null || true)

    if [[ -z "$diff_output" ]]; then
        warn "No changes detected — config already matches"
    else
        echo "$diff_output" | colorize_diff
    fi
    exit $EXIT_SUCCESS
fi

# --- Production confirmation ---
confirm_production

# --- Fetch before state ---
info "Updating ${AGENT_ID} in ${ENV_LABEL}..."
if [[ "$FULL_WRITE" == "true" ]]; then
    # Already fetched above for top-level fields
    before_config=$(extract_config "$agent_resp")
else
    before_resp=$(api_get "$read_url")
    before_config=$(extract_config "$before_resp")
fi

# --- Send update ---
result=$(api_put "$update_url" "$request_body")

# Check for errors in response
if echo "$result" | jq -e '.error' >/dev/null 2>&1; then
    error_msg=$(echo "$result" | jq -r '.error // "unknown error"')
    die $EXIT_API "Update failed: ${error_msg}"
fi

# --- Fetch after state and show diff ---
after_resp=$(api_get "$read_url")
after_config=$(extract_config "$after_resp")

diff_output=$(diff -u \
    --label "before" \
    --label "after" \
    <(echo "$before_config" | jq -S . 2>/dev/null) \
    <(echo "$after_config" | jq -S . 2>/dev/null) 2>/dev/null || true)

if [[ -z "$diff_output" ]]; then
    if [[ "$FULL_WRITE" == "true" ]]; then
        warn "No visible diff — verify with: livex-config-read.sh ${AGENT_ID} --full --profile ${LIVEX_PROFILE:-\$profile}"
    else
        warn "No changes detected after update — the API may have stripped all fields"
    fi
else
    echo "$diff_output" | colorize_diff
fi

success "Updated ${AGENT_ID} in ${ENV_LABEL}"

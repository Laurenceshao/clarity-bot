#!/bin/bash
# livex-flow-create.sh — Create a new LiveX agentflow (workflow)
#
# Usage:
#   ./livex-flow-create.sh <config> [OPTIONS]
#   ./livex-flow-create.sh --from <workflow_id> [OPTIONS]
#
# Arguments:
#   config    JSON string or @path/to/file.json
#
# Options:
#   --from WORKFLOW_ID     Copy from existing workflow
#   --from-profile PRF    Profile for --from source (cross-account copy)
#   --name NAME            Override or set workflow name
#   --type TYPE            Workflow type: ai-based (default), rule-based
#   --env ENV              Environment: dev (default), staging, production
#   --profile PROFILE      Target profile
#   --yes                  Skip confirmation prompt for production
#   --help                 Show this help message
#
# Examples:
#   ./livex-flow-create.sh @flow.json
#   ./livex-flow-create.sh @flow.json --name "My Flow"
#   ./livex-flow-create.sh --from abc-123 --name "Copy of Flow"
#   ./livex-flow-create.sh --from abc-123 --from-profile dev --profile prod

source "$(dirname "$0")/_lib.sh"

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") [<config>] [OPTIONS]"
    echo ""
    echo "Create a new agentflow from JSON or copy an existing one."
    echo ""
    echo "Arguments:"
    echo "  config    JSON string or @path/to/file.json"
    echo ""
    echo "Options:"
    echo "  --from WORKFLOW_ID     Copy from existing workflow"
    echo "  --from-profile PRF    Profile for --from source (cross-account)"
    echo "  --name NAME            Override or set workflow name"
    echo "  --type TYPE            Workflow type: ai-based (default), rule-based"
    echo "  --env ENV              Environment: dev (default), staging, production"
    echo "  --profile PROFILE      Target profile"
    echo "  --yes                  Skip confirmation prompt for production"
    echo "  --help                 Show this help message"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") @flow.json"
    echo "  $(basename "$0") @flow.json --name \"My New Flow\""
    echo "  $(basename "$0") --from abc-123 --name \"Copy of Flow\""
    echo "  $(basename "$0") --from abc-123 --from-profile dev --profile prod"
    exit "${1:-$EXIT_USAGE}"
}

# --- Parse args ---
CONFIG_INPUT=""
COPY_FROM=""
FROM_PROFILE=""
FLOW_NAME=""
WORKFLOW_TYPE="ai-based"
ENV_FLAG="dev"
SKIP_CONFIRM="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)        usage $EXIT_SUCCESS ;;
        --from)           COPY_FROM="${2:?--from requires a workflow_id}"; shift 2 ;;
        --from-profile)   FROM_PROFILE="${2:?--from-profile requires a name}"; shift 2 ;;
        --name)           FLOW_NAME="${2:?--name requires a value}"; shift 2 ;;
        --type)           WORKFLOW_TYPE="${2:?--type requires a value}"; shift 2 ;;
        --env)            ENV_FLAG="${2:?--env requires a value}"; shift 2 ;;
        --profile)        export LIVEX_PROFILE="${2:?--profile requires a name}"; shift 2 ;;
        --yes)            SKIP_CONFIRM="true"; shift ;;
        -*)               die $EXIT_USAGE "Unknown option: $1\nRun with --help for usage." ;;
        *)
            if [[ -z "$CONFIG_INPUT" ]]; then
                CONFIG_INPUT="$1"
            else
                die $EXIT_USAGE "Unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

# Must provide config or --from
if [[ -z "$CONFIG_INPUT" && -z "$COPY_FROM" ]]; then
    die $EXIT_USAGE "Provide config JSON (or @file) or --from <workflow_id>.\nRun with --help for usage."
fi

# --- Init ---
check_deps
load_env
resolve_api_host "$ENV_FLAG"
export SKIP_CONFIRM

# --- Resolve config ---
if [[ -n "$COPY_FROM" ]]; then
    # Copy from existing workflow
    if [[ -n "$FROM_PROFILE" ]]; then
        info "Reading source workflow from profile '${FROM_PROFILE}'..."
        saved_profile="${LIVEX_PROFILE:-}"
        export LIVEX_PROFILE="$FROM_PROFILE"
        load_env
        source_resp=$(api_get "$(workflow_base_url "$WORKFLOW_TYPE")")
        # Restore target profile (unset stale hosts before reload)
        if [[ -n "$saved_profile" ]]; then
            export LIVEX_PROFILE="$saved_profile"
        else
            unset LIVEX_PROFILE
        fi
        unset LIVEX_API_HOST LIVEX_CHAT_HOST
        load_env
        resolve_api_host "$ENV_FLAG"
    else
        info "Reading source workflow ${COPY_FROM}..."
        source_resp=$(api_get "$(workflow_base_url "$WORKFLOW_TYPE")")
    fi

    config_json=$(echo "$source_resp" | jq -r --arg wid "$COPY_FROM" '.response[] | select(.workflow_id == $wid)' 2>/dev/null)
    if [[ -z "$config_json" || "$config_json" == "null" ]]; then
        die $EXIT_API "Source workflow '${COPY_FROM}' not found"
    fi

    # Strip protected/auto-generated fields
    config_json=$(echo "$config_json" | jq 'del(.workflow_id, .account_id, .public, .versions, .draft_versions, .created_ts, .updated_ts, .author)' 2>/dev/null)
    source_name=$(echo "$config_json" | jq -r '.workflow_name // "unnamed"' 2>/dev/null)
    info "Copied config from \"${source_name}\" (protected fields stripped)"
elif [[ "$CONFIG_INPUT" == @* ]]; then
    filepath="${CONFIG_INPUT#@}"
    [[ -f "$filepath" ]] || die $EXIT_USAGE "File not found: $filepath"
    config_json=$(cat "$filepath")
else
    config_json="$CONFIG_INPUT"
fi

normalize_workflow_config_json "$config_json"
config_json="$WORKFLOW_CONFIG_JSON_NORMALIZED"

# Override name if provided
if [[ -n "$FLOW_NAME" ]]; then
    config_json=$(echo "$config_json" | jq --arg name "$FLOW_NAME" '.workflow_name = $name' 2>/dev/null)
fi

# Validate: must have workflow_name
flow_name=$(echo "$config_json" | jq -r '.workflow_name // empty' 2>/dev/null)
if [[ -z "$flow_name" ]]; then
    die $EXIT_USAGE "Config must include 'workflow_name'. Use --name to set it."
fi

# Build request body
request_body=$(jq -n --argjson cfg "$config_json" '{"workflow_config": $cfg}')

# --- Production confirmation ---
confirm_production

# --- Create ---
info "Creating workflow \"${flow_name}\" in ${ENV_LABEL}..."
result=$(api_post "$(workflow_base_url "$WORKFLOW_TYPE")" "$request_body")

# Check for API error in response body (API returns HTTP 200 with error in body)
if echo "$result" | jq -e '.error' >/dev/null 2>&1; then
    error_msg=$(echo "$result" | jq -r '.error.message // .error // "unknown error"' 2>/dev/null)
    die $EXIT_API "Create failed: ${error_msg}"
fi

# Extract new workflow_id
new_id=$(echo "$result" | jq -r '.response.workflow_id // .data.workflow_id // empty' 2>/dev/null)
if [[ -z "$new_id" ]]; then
    # Try extracting from the full response (some APIs return the full object)
    new_id=$(echo "$result" | jq -r '.workflow_id // empty' 2>/dev/null)
fi

if [[ -z "$new_id" ]]; then
    warn "Could not extract workflow_id from response"
    echo "$result" | jq . >&2 2>/dev/null || echo "$result" >&2
else
    echo "" >&2
    success "Created workflow \"${flow_name}\""
    echo -e "  ${BOLD}Workflow ID:${NC}  ${new_id}" >&2
    echo -e "  ${BOLD}Type:${NC}         ${WORKFLOW_TYPE}" >&2
    echo -e "  ${BOLD}Environment:${NC}  ${ENV_LABEL}" >&2
    if [[ -n "$COPY_FROM" ]]; then
        echo -e "  ${BOLD}Copied from:${NC} ${COPY_FROM}" >&2
    fi

    # Post-create verification
    info "Verifying created workflow..."
    verify_list=$(api_get "$(workflow_base_url "$WORKFLOW_TYPE")")
    verify_wf=$(echo "$verify_list" | jq -r --arg wid "$new_id" '.response[]? | select(.workflow_id == $wid)' 2>/dev/null)

    if [[ -n "$verify_wf" && "$verify_wf" != "null" ]]; then
        _v_name=$(echo "$verify_wf" | jq -r '.workflow_name // "unnamed"' 2>/dev/null)
        _v_steps=$(echo "$verify_wf" | jq -r '.steps | length' 2>/dev/null || echo "?")
        _v_type=$(echo "$verify_wf" | jq -r '.workflow_type // "unknown"' 2>/dev/null)
        echo -e "  ${BOLD}Verified:${NC}     ${_v_name} (${_v_steps} steps, type: ${_v_type})" >&2

        if [[ -n "$COPY_FROM" ]]; then
            _src_steps=$(echo "$config_json" | jq '.steps | length' 2>/dev/null || echo "?")
            if [[ "$_v_steps" == "$_src_steps" ]]; then
                success "Step count matches source (${_src_steps} steps)"
            else
                warn "Step count mismatch: source had ${_src_steps}, new has ${_v_steps}"
            fi
        fi
    else
        warn "Could not verify: workflow ${new_id} not found in list after creation"
    fi

    # Output workflow_id to stdout for piping
    echo "$new_id"
fi

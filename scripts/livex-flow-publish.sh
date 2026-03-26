#!/bin/bash
# livex-flow-publish.sh — Publish or deploy a LiveX agentflow (workflow)
#
# Usage:
#   ./livex-flow-publish.sh <workflow_id> [OPTIONS]
#
# Options:
#   --version NUM     Deploy a specific published version (instead of publishing draft)
#   --type TYPE       Workflow type: ai-based (default), rule-based
#   --yes             Skip confirmation prompt
#   --env ENV         Environment: dev (default), staging, production
#   --profile PROFILE Profile name
#   --help            Show this help message
#
# Examples:
#   ./livex-flow-publish.sh abc-123
#   ./livex-flow-publish.sh abc-123 --version 3
#   ./livex-flow-publish.sh abc-123 --env production --yes

source "$(dirname "$0")/_lib.sh"

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") <workflow_id> [OPTIONS]"
    echo ""
    echo "Publish the current draft of an agentflow, or deploy a specific version."
    echo ""
    echo "Options:"
    echo "  --version NUM     Deploy a specific published version"
    echo "  --type TYPE       Workflow type: ai-based (default), rule-based"
    echo "  --yes             Skip confirmation prompt"
    echo "  --env ENV         Environment: dev (default), staging, production"
    echo "  --profile PROFILE Profile name"
    echo "  --help            Show this help message"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") abc-123-def"
    echo "  $(basename "$0") abc-123-def --version 3"
    echo "  $(basename "$0") abc-123-def --env production --yes"
    exit "${1:-$EXIT_USAGE}"
}

# --- Parse args ---
WORKFLOW_ID=""
DEPLOY_VERSION=""
WORKFLOW_TYPE="ai-based"
SKIP_CONFIRM="false"
ENV_FLAG="dev"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)    usage $EXIT_SUCCESS ;;
        --version)    DEPLOY_VERSION="${2:?--version requires a number}"; shift 2 ;;
        --type)       WORKFLOW_TYPE="${2:?--type requires a value}"; shift 2 ;;
        --yes)        SKIP_CONFIRM="true"; shift ;;
        --env)        ENV_FLAG="${2:?--env requires a value}"; shift 2 ;;
        --profile)    export LIVEX_PROFILE="${2:?--profile requires a name}"; shift 2 ;;
        -*)           die $EXIT_USAGE "Unknown option: $1\nRun with --help for usage." ;;
        *)
            if [[ -z "$WORKFLOW_ID" ]]; then
                WORKFLOW_ID="$1"
            else
                die $EXIT_USAGE "Unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

[[ -n "$WORKFLOW_ID" ]] || usage

# --- Init ---
check_deps
load_env
resolve_api_host "$ENV_FLAG"
export SKIP_CONFIRM

# --- Fetch workflow summary ---
info "Fetching workflow ${WORKFLOW_ID} from ${ENV_LABEL}..."
list_resp=$(api_get "$(workflow_base_url "$WORKFLOW_TYPE")")
workflow=$(echo "$list_resp" | jq -r --arg wid "$WORKFLOW_ID" '.response[] | select(.workflow_id == $wid)' 2>/dev/null)

if [[ -z "$workflow" || "$workflow" == "null" ]]; then
    die $EXIT_API "Workflow '${WORKFLOW_ID}' not found in ${WORKFLOW_TYPE} workflows"
fi

name=$(echo "$workflow" | jq -r '.workflow_name // "unnamed"' 2>/dev/null)
steps=$(echo "$workflow" | jq -r '.steps | length' 2>/dev/null || echo "?")

# Fetch current version info
version_resp=$(api_get "${LIVEX_API_HOST}/api/v1/workflow/versions/accounts/${LIVEX_ACCOUNT_ID}/workflows/${WORKFLOW_ID}")
current_ver=$(echo "$version_resp" | jq -r '.response.public.version_number // .data.public.version_number // "none"' 2>/dev/null)
version_count=$(echo "$version_resp" | jq -r '.response.versions // .data.versions // [] | length' 2>/dev/null)

echo -e "\n${BOLD}Workflow summary:${NC}" >&2
echo -e "  Name:            ${name}" >&2
echo -e "  Steps:           ${steps}" >&2
echo -e "  Current version: ${current_ver}" >&2
echo -e "  Total versions:  ${version_count}" >&2
echo "" >&2

# --- Confirmation ---
if [[ -n "$DEPLOY_VERSION" ]]; then
    action_desc="deploy version ${DEPLOY_VERSION}"
else
    action_desc="publish current draft as new version"
fi

if [[ "$SKIP_CONFIRM" != "true" ]]; then
    echo -e "${YELLOW}This will ${action_desc} for \"${name}\" in ${ENV_LABEL}.${NC}" >&2
    echo -n "Type 'yes' to continue: " >&2
    local_answer=""
    read -r local_answer
    if [[ "$local_answer" != "yes" ]]; then
        die $EXIT_USAGE "Aborted."
    fi
fi

# --- Publish or deploy ---
version_base="${LIVEX_API_HOST}/api/v1/workflow/versions/accounts/${LIVEX_ACCOUNT_ID}/workflows/${WORKFLOW_ID}"

if [[ -n "$DEPLOY_VERSION" ]]; then
    info "Deploying version ${DEPLOY_VERSION} of \"${name}\" in ${ENV_LABEL}..."
    result=$(api_post "${version_base}/versions/${DEPLOY_VERSION}" "{}")
else
    info "Publishing draft of \"${name}\" in ${ENV_LABEL}..."
    result=$(api_post "$version_base" "{}")
fi

# Check for API error in response body
if echo "$result" | jq -e '.error' >/dev/null 2>&1; then
    error_msg=$(echo "$result" | jq -r '.error.message // .error // "unknown error"' 2>/dev/null)
    die $EXIT_API "Publish failed: ${error_msg}"
fi

# Extract new version info
new_ver=$(echo "$result" | jq -r '.response.public.version_number // .data.public.version_number // "unknown"' 2>/dev/null)
deployed_ts=$(echo "$result" | jq -r '.response.public.deployed_ts // .data.public.deployed_ts // "unknown"' 2>/dev/null)

if [[ -n "$DEPLOY_VERSION" ]]; then
    success "Deployed version ${DEPLOY_VERSION} of \"${name}\" in ${ENV_LABEL}"
else
    success "Published \"${name}\" as version ${new_ver} in ${ENV_LABEL}"
fi
echo -e "  ${BOLD}Active version:${NC} ${new_ver}" >&2
echo -e "  ${BOLD}Deployed at:${NC}   ${deployed_ts}" >&2

# --- Post-publish verification ---
info "Verifying published version..."
verify_resp=$(api_get "${LIVEX_API_HOST}/api/v1/workflow/versions/accounts/${LIVEX_ACCOUNT_ID}/workflows/${WORKFLOW_ID}")
verify_ver=$(echo "$verify_resp" | jq -r '.response.public.version_number // .data.public.version_number // "unknown"' 2>/dev/null)
verify_count=$(echo "$verify_resp" | jq -r '.response.versions // .data.versions // [] | length' 2>/dev/null)

verify_workflow=$(api_get "$(workflow_base_url "$WORKFLOW_TYPE")")
active_steps=$(echo "$verify_workflow" | jq -r --arg wid "$WORKFLOW_ID" '.response[]? | select(.workflow_id == $wid) | .steps | length' 2>/dev/null || echo "?")

_expected_ver="${DEPLOY_VERSION:-$new_ver}"
if [[ "$verify_ver" == "$_expected_ver" ]]; then
    success "Verified: version ${_expected_ver} is active (${active_steps} steps, ${verify_count} total versions)"
else
    warn "Expected active version ${_expected_ver} but found ${verify_ver}"
fi

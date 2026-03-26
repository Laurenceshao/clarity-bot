#!/bin/bash
# livex-config-publish.sh — Publish draft config to live
#
# Usage:
#   ./livex-config-publish.sh <agent_id> [OPTIONS]
#
# Options:
#   --env ENV    Environment: dev (default), staging, production
#   --yes        Skip confirmation prompt
#   --help       Show this help message
#
# Examples:
#   ./livex-config-publish.sh abc-123
#   ./livex-config-publish.sh abc-123 --env production --yes

source "$(dirname "$0")/_lib.sh"

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") <agent_id> [OPTIONS]"
    echo ""
    echo "Publish an agent's draft config to live (promoted to published)."
    echo ""
    echo "Options:"
    echo "  --env ENV    Environment: dev (default), staging, production"
    echo "  --yes        Skip confirmation prompt"
    echo "  --help       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") 220d84bc-82e5-4d79-851c-409d2f513921"
    echo "  $(basename "$0") 220d84bc-... --env production --yes"
    exit "${1:-$EXIT_USAGE}"
}

# --- Parse args ---
AGENT_ID=""
ENV_FLAG="dev"
SKIP_CONFIRM="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)    usage $EXIT_SUCCESS ;;
        --env)        ENV_FLAG="${2:?--env requires a value}"; shift 2 ;;
        --profile)    export LIVEX_PROFILE="${2:?--profile requires a name}"; shift 2 ;;
        --yes)        SKIP_CONFIRM="true"; shift ;;
        -*)           die $EXIT_USAGE "Unknown option: $1\nRun with --help for usage." ;;
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

[[ -n "$AGENT_ID" ]] || usage

# --- Init ---
check_deps
load_env
resolve_api_host "$ENV_FLAG"
export SKIP_CONFIRM

# --- Fetch draft summary ---
info "Fetching draft config for ${AGENT_ID} from ${ENV_LABEL}..."
response=$(api_get "${LIVEX_API_HOST}/api/v1/agent?account_id=${LIVEX_ACCOUNT_ID}&agent_id=${AGENT_ID}")
config=$(extract_config "$response")

name=$(echo "$config" | jq -r '.name // .nickname // "unnamed"' 2>/dev/null)
model=$(echo "$config" | jq -r '.tool_agent.llm_config.model // "unknown"' 2>/dev/null)
tools=$(echo "$config" | jq -r '.tool_agent.tools | length' 2>/dev/null || echo "?")
personality=$(echo "$config" | jq -r '.personality // "unknown"' 2>/dev/null)

echo -e "\n${BOLD}Draft config summary:${NC}" >&2
echo -e "  Name:        ${name}" >&2
echo -e "  Model:       ${model}" >&2
echo -e "  Tools:       ${tools}" >&2
echo -e "  Personality: ${personality}" >&2
echo "" >&2

# --- Confirmation ---
if [[ "$SKIP_CONFIRM" != "true" ]]; then
    echo -e "${YELLOW}This will publish the draft config to LIVE for \"${name}\".${NC}" >&2
    echo -n "Type 'yes' to continue: " >&2
    local_answer=""
    read -r local_answer
    if [[ "$local_answer" != "yes" ]]; then
        die $EXIT_USAGE "Aborted."
    fi
fi

# --- Publish ---
info "Publishing ${AGENT_ID} to live in ${ENV_LABEL}..."
publish_url="${LIVEX_API_HOST}/api/v1/agents-published/accounts/${LIVEX_ACCOUNT_ID}/agents/${AGENT_ID}"
result=$(api_put "$publish_url" "{}")

# Check for API error in response body
if echo "$result" | jq -e '.error' >/dev/null 2>&1; then
    error_msg=$(echo "$result" | jq -r '.error.message // .error // "unknown error"' 2>/dev/null)
    die $EXIT_API "Publish failed: ${error_msg}"
fi

success "Published \"${name}\" (${AGENT_ID}) to live in ${ENV_LABEL}"

# --- Post-publish verification ---
# The public API returns a stripped widget config (no corpus_id, personality, model, sources).
# We verify: (1) published config exists, (2) name matches draft, (3) key widget fields present.
info "Verifying published config..."
pub_id="pub-${AGENT_ID}"
pub_resp=$(api_get_public "${LIVEX_API_HOST}/api/v1/public/agents/${pub_id}" 2>/dev/null) || {
    warn "Could not fetch published config for verification (may be first publish)"
    exit $EXIT_SUCCESS
}
pub_config=$(extract_config "$pub_resp")

echo -e "\n${BOLD}Publish verification:${NC}" >&2
verify_fields_match "$config" "$pub_config" \
    "name:.name"

# Check key widget fields are present in published config
_pub_has_tools=$(echo "$pub_config" | jq -e '.tools' >/dev/null 2>&1 && echo "yes" || echo "no")
_pub_has_style=$(echo "$pub_config" | jq -e '.style' >/dev/null 2>&1 && echo "yes" || echo "no")
if [[ "$_pub_has_tools" == "yes" ]]; then
    echo -e "  ${GREEN}present${NC}  tools config" >&2
else
    echo -e "  ${RED}MISSING${NC}  tools config" >&2
    _verify_ok=false
fi
if [[ "$_pub_has_style" == "yes" ]]; then
    echo -e "  ${GREEN}present${NC}  style config" >&2
else
    echo -e "  ${RED}MISSING${NC}  style config" >&2
    _verify_ok=false
fi

echo "" >&2
if [[ "$_verify_ok" == "true" ]]; then
    success "Published config verified (name matches, widget config present)"
    info "Note: operational fields (corpus_id, personality, model) are not exposed by the public API"
else
    warn "Some fields differ or missing between draft and published — review above"
fi

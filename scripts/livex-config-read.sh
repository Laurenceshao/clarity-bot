#!/bin/bash
# livex-config-read.sh — Read LiveX agent config (draft or published)
#
# Usage:
#   ./livex-config-read.sh <agent_id> [OPTIONS]
#
# Options:
#   --env ENV        Environment: dev (default), staging, production
#   --published      Read published (live) config instead of draft
#   --full           Read draft config with gateway-hidden fields (internal only)
#   --field JQ_PATH  Extract specific field (jq syntax)
#   --raw            Output full API response (don't extract .config)
#   --help           Show this help message
#
# Examples:
#   ./livex-config-read.sh abc-123
#   ./livex-config-read.sh abc-123 --published
#   ./livex-config-read.sh abc-123 --field .nickname
#   ./livex-config-read.sh abc-123 --field '.voice.language_models[0]'
#   ./livex-config-read.sh abc-123 --env production
#   ./livex-config-read.sh abc-123 --full --field '.voice.language_models[0]'

source "$(dirname "$0")/_lib.sh"

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") <agent_id> [OPTIONS]"
    echo ""
    echo "Read LiveX agent config as formatted JSON."
    echo ""
    echo "Options:"
    echo "  --env ENV        Environment: dev (default), staging, production"
    echo "  --published      Read published (live) config instead of draft"
    echo "  --full           Read draft config with gateway-hidden fields (internal only)"
    echo "  --field JQ_PATH  Extract specific field (jq syntax, e.g. .nickname)"
    echo "  --raw            Output full API response (don't extract .config)"
    echo "  --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") 220d84bc-82e5-4d79-851c-409d2f513921"
    echo "  $(basename "$0") 220d84bc-... --field .nickname"
    echo "  $(basename "$0") 220d84bc-... --published"
    echo "  $(basename "$0") 220d84bc-... --field '.voice.language_models' --env production"
    echo "  $(basename "$0") 220d84bc-... --full --field '.voice.language_models'"
    exit "${1:-$EXIT_USAGE}"
}

# --- Parse args ---
AGENT_ID=""
ENV_FLAG="dev"
PUBLISHED=false
FULL=false
FIELD=""
RAW=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)    usage $EXIT_SUCCESS ;;
        --env)        ENV_FLAG="${2:?--env requires a value}"; shift 2 ;;
        --profile)    export LIVEX_PROFILE="${2:?--profile requires a name}"; shift 2 ;;
        --published)  PUBLISHED=true; shift ;;
        --full)       FULL=true; shift ;;
        --field)      FIELD="${2:?--field requires a jq path}"; shift 2 ;;
        --raw)        RAW=true; shift ;;
        --yes)        shift ;;  # tolerated — read-only command
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

if [[ "$PUBLISHED" == "true" && "$FULL" == "true" ]]; then
    die $EXIT_USAGE "--full only supports draft reads. Published reads use the public endpoint and cannot expose gateway-hidden fields."
fi

# --- Init ---
check_deps
load_env
resolve_api_host "$ENV_FLAG"

# --- Fetch ---
if [[ "$PUBLISHED" == "true" ]]; then
    # Published config uses the published_id (pub- prefix)
    pub_id="$AGENT_ID"
    [[ "$pub_id" == pub-* ]] || pub_id="pub-${AGENT_ID}"
    info "Reading published config for ${pub_id} from ${ENV_LABEL}..."
    response=$(api_get_public "${LIVEX_API_HOST}/api/v1/public/agents/${pub_id}")
else
    draft_url="${LIVEX_API_HOST}/api/v1/agent?account_id=${LIVEX_ACCOUNT_ID}&agent_id=${AGENT_ID}"
    if [[ "$FULL" == "true" ]]; then
        warn "Full-read mode enabled: using internal gateway bypass to expose hidden draft fields"
        draft_url=$(_append_debug_code "$draft_url")
        info "Reading full draft config for ${AGENT_ID} from ${ENV_LABEL}..."
    else
        info "Reading draft config for ${AGENT_ID} from ${ENV_LABEL}..."
    fi
    response=$(api_get "$draft_url")
fi

# --- Extract and output ---
if [[ "$RAW" == "true" ]]; then
    echo "$response" | jq .
else
    config=$(extract_config "$response")

    if [[ -n "$FIELD" ]]; then
        result=$(echo "$config" | jq "$FIELD" 2>/dev/null)
        if [[ "$result" == "null" ]]; then
            warn "Field '${FIELD}' not found in config (returned null)"
        fi
        echo "$result"
    else
        echo "$config" | jq .
    fi
fi

name=$(echo "$response" | jq -r '(.response.config.nickname // .response.name // .config.nickname // .name // "unknown") | select(. != "") // "unknown"' 2>/dev/null || echo "unknown")
success "Read config for \"${name}\" (${AGENT_ID}) from ${ENV_LABEL}"

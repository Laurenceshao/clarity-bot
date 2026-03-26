#!/bin/bash
# _lib.sh — Shared functions for LiveX API scripts
# Source this file: source "$(dirname "$0")/_lib.sh"

# --- Strict mode ---
set -euo pipefail

# --- Colors (stderr only) ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# --- Exit codes ---
readonly EXIT_SUCCESS=0
readonly EXIT_USAGE=1
readonly EXIT_API=2
readonly EXIT_AUTH=3
readonly EXIT_PARTIAL=4

# --- Internal gateway bypass ---
# Internal-only debug code used to expose gateway-hidden config fields.
readonly LIVEX_FULL_CONFIG_DEBUG_CODE='VlHVHg'
readonly LIVEX_FULL_CONFIG_DEBUG_PARAM='copilot_debug_code'

# --- Messaging (all to stderr) ---
info()    { echo -e "${BLUE}[info]${NC} $*" >&2; }
success() { echo -e "${GREEN}[ok]${NC} $*" >&2; }
warn()    { echo -e "${YELLOW}[warn]${NC} $*" >&2; }
die()     { local code=$1; shift; echo -e "${RED}[error]${NC} $*" >&2; exit "$code"; }

# --- Validation helpers ---
validate_uuid() {
    local value="$1" label="${2:-ID}"
    if [[ ! "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        die $EXIT_USAGE "${label} must be a full UUID (got ${#value} chars). Run livex-kb-list.sh to find full IDs."
    fi
}

validate_url() {
    local value="$1" label="${2:-URL}"
    if [[ ! "$value" =~ ^https?:// ]]; then
        die $EXIT_USAGE "${label} must start with http:// or https://"
    fi
}

# Normalizes workflow config input for create/update scripts.
# Accepts either a bare JSON object or a single-object array wrapper ([{...}]).
# NOTE: Result is returned via global WORKFLOW_CONFIG_JSON_NORMALIZED, not stdout.
# Do NOT call in a subshell — the assignment will be invisible to the parent.
normalize_workflow_config_json() {
    local config_json="$1"
    WORKFLOW_CONFIG_JSON_NORMALIZED=""

    if ! printf '%s\n' "$config_json" | jq . >/dev/null 2>&1; then
        die $EXIT_USAGE "Invalid JSON: $(printf '%s\n' "$config_json" | jq . 2>&1 | head -1)"
    fi

    if printf '%s\n' "$config_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        local array_len
        array_len=$(printf '%s\n' "$config_json" | jq -r 'length' 2>/dev/null || echo "unknown")
        if [[ "$array_len" != "1" ]]; then
            die $EXIT_USAGE "Workflow config array must contain exactly one object (got ${array_len})"
        fi
        if ! printf '%s\n' "$config_json" | jq -e '.[0] | type == "object"' >/dev/null 2>&1; then
            die $EXIT_USAGE "Workflow config array must contain an object as its first entry"
        fi
        config_json=$(printf '%s\n' "$config_json" | jq '.[0]')
        info "Unwrapped array wrapper from input"
    fi

    if ! printf '%s\n' "$config_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
        local json_type
        json_type=$(printf '%s\n' "$config_json" | jq -r 'type' 2>/dev/null || echo "unknown")
        die $EXIT_USAGE "Workflow config must be a JSON object (got ${json_type})"
    fi

    WORKFLOW_CONFIG_JSON_NORMALIZED="$config_json"
}

# --- Verification helpers ---
# Extract corpus_id from agent config response (handles both nesting paths)
extract_corpus_id() {
    local json="$1"
    echo "$json" | jq -r '.response.config.tools.document_qa.corpus_id // .response.config.corpus_id // .config.tools.document_qa.corpus_id // .config.corpus_id // empty' 2>/dev/null
}

# Extract array items from API response (normalizes .response[] vs .[])
extract_items() {
    local json="$1"
    echo "$json" | jq '[.response[]? // .[]?]' 2>/dev/null || echo "[]"
}

# Check if an ID is absent from a list response. Returns 0 if absent, 1 if present.
# Usage: verify_item_absent "$api_response" ".document_id" "$target_id"
verify_item_absent() {
    local json="$1" field="$2" target="$3"
    local count
    count=$(echo "$json" | jq -r --arg tid "$target" "[.response[]? // .[]? | select(${field} == \$tid)] | length" 2>/dev/null || echo "?")
    [[ "$count" == "0" ]]
}

# Compare key fields between two JSON objects. Prints match/MISMATCH per field.
# Usage: verify_fields_match "$draft_json" "$published_json" "label:jq_path" ...
# Sets _verify_ok=false on any mismatch.
verify_fields_match() {
    local draft="$1" published="$2"
    shift 2
    _verify_ok=true
    for _fp in "$@"; do
        local _label="${_fp%%:*}"
        local _path="${_fp#*:}"
        local _draft_val _pub_val
        _draft_val=$(echo "$draft" | jq -r "${_path} // \"(not set)\"" 2>/dev/null)
        _pub_val=$(echo "$published" | jq -r "${_path} // \"(not set)\"" 2>/dev/null)
        if [[ "$_draft_val" == "$_pub_val" ]]; then
            echo -e "  ${GREEN}match${NC}  ${_label}: ${_draft_val}" >&2
        else
            echo -e "  ${RED}MISMATCH${NC}  ${_label}: draft=${_draft_val}  published=${_pub_val}" >&2
            _verify_ok=false
        fi
    done
}

# --- Environment ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"

load_env() {
    local profile="${LIVEX_PROFILE:-}"
    local config_dir="${LIVEX_CONFIG_DIR:-${HOME}/.config/livex-api}"
    local profiles_file="${config_dir}/profiles"
    local active_file="${config_dir}/active"

    # Resolve profile name: explicit > active file
    if [[ -z "$profile" ]]; then
        if [[ -f "$active_file" ]]; then
            profile=$(head -1 "$active_file" | tr -d '[:space:]')
        fi
        if [[ -z "$profile" ]]; then
            die $EXIT_USAGE "No profile specified and no active profile set.\nRun: livex-profiles.sh add"
        fi
    fi

    # Profiles file must exist
    if [[ ! -f "$profiles_file" ]]; then
        die $EXIT_USAGE "No profiles file at ${profiles_file}\nRun: livex-profiles.sh add"
    fi

    # Look up profile by name (first field, skip comments/blanks)
    local line
    line=$(awk -v name="$profile" '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ && $1 == name { print; exit }' "$profiles_file")

    if [[ -z "$line" ]]; then
        die $EXIT_USAGE "Profile '${profile}' not found in ${profiles_file}\nRun: livex-profiles.sh list"
    fi

    # Parse: name  api_key  account_id  [host_override]
    LIVEX_API_KEY=$(echo "$line" | awk '{print $2}')
    LIVEX_ACCOUNT_ID=$(echo "$line" | awk '{print $3}')
    local host_override
    host_override=$(echo "$line" | awk '{print $4}')

    # Derive host from prefix, or use explicit override
    if [[ -n "$host_override" ]]; then
        LIVEX_API_HOST="$host_override"
    else
        local prefix="${profile%%-*}"
        case "$prefix" in
            prd)  LIVEX_API_HOST="https://api.copilot.livex.ai" ;;
            dev)  LIVEX_API_HOST="https://dv.copilot.livex.ai" ;;
            stg)  LIVEX_API_HOST="https://stg.copilot.livex.ai" ;;
            jp)   LIVEX_API_HOST="https://api.jp.copilot.livex.ai" ;;
            *)    die $EXIT_USAGE "Cannot derive host from prefix '${prefix}'. Add host as 4th column in profiles file." ;;
        esac
    fi

    # Validate
    if [[ -z "${LIVEX_API_KEY:-}" ]]; then
        die $EXIT_AUTH "LIVEX_API_KEY empty for profile '${profile}'"
    fi
    if [[ -z "${LIVEX_ACCOUNT_ID:-}" ]]; then
        die $EXIT_USAGE "LIVEX_ACCOUNT_ID empty for profile '${profile}'"
    fi

    info "Using profile: ${profile}"
}

# --- Host resolution ---
# Sets LIVEX_API_HOST and ENV_LABEL based on --env flag or profile
resolve_api_host() {
    local env_flag="${1:-dev}"

    # If LIVEX_API_HOST was pre-set (e.g., from profile), derive ENV_LABEL from it
    if [[ -n "${LIVEX_API_HOST:-}" ]]; then
        case "$LIVEX_API_HOST" in
            *api.jp.copilot.livex.ai*)  ENV_LABEL="JAPAN" ;;
            *api.copilot.livex.ai*)     ENV_LABEL="PRODUCTION" ;;
            *dv.copilot.livex.ai*)      ENV_LABEL="DEV" ;;
            *stg.copilot.livex.ai*)     ENV_LABEL="STAGING" ;;
            *)                          ENV_LABEL="CUSTOM" ;;
        esac
        return
    fi

    case "$env_flag" in
        dev|development)
            LIVEX_API_HOST="https://dv.copilot.livex.ai"
            ENV_LABEL="DEV"
            ;;
        staging|stg)
            LIVEX_API_HOST="https://stg.copilot.livex.ai"
            ENV_LABEL="STAGING"
            ;;
        production|prod|prd)
            LIVEX_API_HOST="https://api.copilot.livex.ai"
            ENV_LABEL="PRODUCTION"
            ;;
        japan|jp)
            LIVEX_API_HOST="https://api.jp.copilot.livex.ai"
            ENV_LABEL="JAPAN"
            ;;
        *)
            die $EXIT_USAGE "Unknown environment: $env_flag (use dev, stg, prd, or jp)"
            ;;
    esac
}

# Sets LIVEX_CHAT_HOST based on environment (chat-engine service)
# Expert KB create/update goes to chat-engine, not api-gateway.
# If LIVEX_API_HOST is already set (e.g., from profile), derives chat host from it.
resolve_chat_host() {
    # If already set explicitly, keep it
    if [[ -n "${LIVEX_CHAT_HOST:-}" ]]; then
        return
    fi

    # Derive from LIVEX_API_HOST if set (profile may set API host directly)
    if [[ -n "${LIVEX_API_HOST:-}" ]]; then
        case "$LIVEX_API_HOST" in
            *api.copilot.livex.ai*)     LIVEX_CHAT_HOST="https://chat.copilot.livex.ai" ;;
            *dv.copilot.livex.ai*)      LIVEX_CHAT_HOST="https://chat.dv.copilot.livex.ai" ;;
            *stg.copilot.livex.ai*)     LIVEX_CHAT_HOST="https://chat.stg.copilot.livex.ai" ;;
            *api.jp.copilot.livex.ai*)  LIVEX_CHAT_HOST="https://chat.jp.copilot.livex.ai" ;;
        esac
        if [[ -n "${LIVEX_CHAT_HOST:-}" ]]; then
            return
        fi
    fi

    # Fall back to env flag
    local env_flag="${1:-dev}"
    case "$env_flag" in
        dev|development)     LIVEX_CHAT_HOST="https://chat.dv.copilot.livex.ai" ;;
        staging|stg)         LIVEX_CHAT_HOST="https://chat.stg.copilot.livex.ai" ;;
        production|prod|prd) LIVEX_CHAT_HOST="https://chat.copilot.livex.ai" ;;
        japan|jp)            LIVEX_CHAT_HOST="https://chat.jp.copilot.livex.ai" ;;
        *)                   die $EXIT_USAGE "Unknown environment for chat host: $env_flag" ;;
    esac
}

# --- Dependency check ---
check_deps() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v jq >/dev/null 2>&1 || missing+=("jq (install: brew install jq)")
    if [[ ${#missing[@]} -gt 0 ]]; then
        die $EXIT_USAGE "Missing dependencies: ${missing[*]}"
    fi
}

# --- API wrappers ---

# Internal retry wrapper for GET requests only.
# POST/PUT/DELETE are NOT retried — they are non-idempotent.
# Retries on: 502 (bad gateway), 503 (service unavailable), 504 (gateway timeout), 429 (rate limited)
# Usage: _curl_with_retry <max_attempts> <curl_args...>
# Returns: curl output (response body + http_code on last line)
_curl_with_retry() {
    local max_attempts="$1"; shift
    local attempt=1
    local response http_code delay
    while true; do
        response=$(curl "$@" 2>/dev/null) || {
            if (( attempt >= max_attempts )); then
                return 1
            fi
            delay=$(( attempt * attempt ))  # 1s, 4s, 9s
            warn "Network error (attempt ${attempt}/${max_attempts}), retrying in ${delay}s..."
            sleep "$delay"
            attempt=$((attempt + 1))
            continue
        }
        http_code=$(echo "$response" | tail -n1)
        case "$http_code" in
            502|503|504|429)
                if (( attempt >= max_attempts )); then
                    printf '%s\n' "$response"
                    return 0
                fi
                delay=$(( attempt * attempt ))
                warn "HTTP ${http_code} (attempt ${attempt}/${max_attempts}), retrying in ${delay}s..."
                sleep "$delay"
                attempt=$((attempt + 1))
                ;;
            *)
                printf '%s\n' "$response"
                return 0
                ;;
        esac
    done
}

# Detects body-level errors returned with HTTP 200.
# LiveX API sometimes wraps errors as {"error":"...", "status":400} (string)
# or {"error":{"code":N,"message":"..."}, "status":400} (object).
# Fast string pre-check avoids jq overhead on normal responses.
_check_body_error() {
    local body="$1" context="${2:-API call}"
    # Quick string test — avoids jq on the vast majority of successful responses
    [[ "$body" == *'"error"'* ]] || return 0
    # Confirm it's actually a top-level .error key, not a coincidental string match
    if printf '%s\n' "$body" | jq -e '.error' >/dev/null 2>&1; then
        local msg
        msg=$(printf '%s\n' "$body" | jq -r '
            .error | if type == "string" then .
                     elif type == "object" then (.message // tojson)
                     else tojson end
        ' 2>/dev/null)
        die $EXIT_API "${context} failed: ${msg:-unknown error}"
    fi
}

# Makes a GET request with X-API-KEY auth
# Outputs response body on stdout. Dies on error.
# Retries up to 3 times on transient errors (502/503/504/429).
api_get() {
    local url="$1"
    local response
    response=$(_curl_with_retry 3 -s --max-time 30 -w "\n%{http_code}" \
        -H "X-API-KEY: ${LIVEX_API_KEY}" \
        -H "Content-Type: application/json" \
        "$url") || die $EXIT_API "Network error: could not reach ${url}"

    local http_code body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201)
            _check_body_error "$body" "GET ${url}"
            printf '%s\n' "$body"
            ;;
        401|403)
            die $EXIT_AUTH "Authentication failed (HTTP ${http_code}). Check LIVEX_API_KEY."
            ;;
        404)
            die $EXIT_API "Not found (HTTP 404). Check agent_id and account_id."
            ;;
        *)
            local msg
            msg=$(echo "$body" | jq -r '.message // .error // empty' 2>/dev/null || true)
            die $EXIT_API "API error (HTTP ${http_code}): ${msg:-$body}"
            ;;
    esac
}

# Makes a PUT request with X-API-KEY auth
api_put() {
    local url="$1"
    local data="$2"
    local response
    response=$(curl -s --max-time 30 -w "\n%{http_code}" \
        -X PUT \
        -H "X-API-KEY: ${LIVEX_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "$url" 2>/dev/null) || die $EXIT_API "Network error: could not reach ${url}"

    local http_code body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201)
            _check_body_error "$body" "PUT ${url}"
            printf '%s\n' "$body"
            ;;
        401|403)
            die $EXIT_AUTH "Authentication failed (HTTP ${http_code}). Check LIVEX_API_KEY."
            ;;
        404)
            die $EXIT_API "Not found (HTTP 404). Check agent_id and account_id."
            ;;
        *)
            local msg
            msg=$(echo "$body" | jq -r '.message // .error // empty' 2>/dev/null || true)
            die $EXIT_API "API error (HTTP ${http_code}): ${msg:-$body}"
            ;;
    esac
}

# Makes a POST request with X-API-KEY auth
api_post() {
    local url="$1"
    local data="$2"
    local response
    response=$(curl -s --max-time 30 -w "\n%{http_code}" \
        -X POST \
        -H "X-API-KEY: ${LIVEX_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "$url" 2>/dev/null) || die $EXIT_API "Network error: could not reach ${url}"

    local http_code body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201)
            _check_body_error "$body" "POST ${url}"
            printf '%s\n' "$body"
            ;;
        401|403)
            die $EXIT_AUTH "Authentication failed (HTTP ${http_code}). Check LIVEX_API_KEY."
            ;;
        404)
            die $EXIT_API "Not found (HTTP 404). Check endpoint URL."
            ;;
        *)
            local msg
            msg=$(echo "$body" | jq -r '.message // .error // empty' 2>/dev/null || true)
            die $EXIT_API "API error (HTTP ${http_code}): ${msg:-$body}"
            ;;
    esac
}

# Makes a multipart/form-data POST request with X-API-KEY auth
# Usage: api_post_multipart <url> <form_args...>
# form_args are key=value pairs for curl -F (e.g. "file=@doc.md" "agent_id=abc")
api_post_multipart() {
    local url="$1"; shift
    local curl_args=(-s --max-time 120 -X POST -H "X-API-KEY: ${LIVEX_API_KEY}" -w "\n%{http_code}")
    while [[ $# -gt 0 ]]; do
        curl_args+=(-F "$1")
        shift
    done
    curl_args+=("$url")

    local response
    response=$(curl "${curl_args[@]}" 2>/dev/null) || die $EXIT_API "Network error: could not reach ${url}"

    local http_code body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201) _check_body_error "$body" "POST ${url}"; printf '%s\n' "$body" ;;
        401|403) die $EXIT_AUTH "Authentication failed (HTTP ${http_code}). Check LIVEX_API_KEY." ;;
        404)     die $EXIT_API "Not found (HTTP 404). Check endpoint URL." ;;
        *)
            local msg
            msg=$(echo "$body" | jq -r '.message // .error // empty' 2>/dev/null || true)
            die $EXIT_API "API error (HTTP ${http_code}): ${msg:-$body}"
            ;;
    esac
}

# Makes a DELETE request with X-API-KEY auth
api_delete() {
    local url="$1"
    local response
    response=$(curl -s --max-time 30 -w "\n%{http_code}" \
        -X DELETE \
        -H "X-API-KEY: ${LIVEX_API_KEY}" \
        -H "Content-Type: application/json" \
        "$url" 2>/dev/null) || die $EXIT_API "Network error: could not reach ${url}"

    local http_code body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201)
            _check_body_error "$body" "DELETE ${url}"
            printf '%s\n' "$body"
            ;;
        401|403)
            die $EXIT_AUTH "Authentication failed (HTTP ${http_code}). Check LIVEX_API_KEY."
            ;;
        404)
            die $EXIT_API "Not found (HTTP 404). Check workflow_id."
            ;;
        *)
            local msg
            msg=$(echo "$body" | jq -r '.message // .error // empty' 2>/dev/null || true)
            die $EXIT_API "API error (HTTP ${http_code}): ${msg:-$body}"
            ;;
    esac
}

# Makes a DELETE request with JSON body and X-API-KEY auth
api_delete_with_body() {
    local url="$1"
    local data="$2"
    local response
    response=$(curl -s --max-time 30 -w "\n%{http_code}" \
        -X DELETE \
        -H "X-API-KEY: ${LIVEX_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "$url" 2>/dev/null) || die $EXIT_API "Network error: could not reach ${url}"

    local http_code body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201) _check_body_error "$body" "DELETE ${url}"; printf '%s\n' "$body" ;;
        401|403) die $EXIT_AUTH "Authentication failed (HTTP ${http_code}). Check LIVEX_API_KEY." ;;
        404)     die $EXIT_API "Not found (HTTP 404). Check resource ID." ;;
        *)
            local msg
            msg=$(echo "$body" | jq -r '.message // .error // empty' 2>/dev/null || true)
            die $EXIT_API "API error (HTTP ${http_code}): ${msg:-$body}"
            ;;
    esac
}

# Downloads a file from the API, saving binary content to a local path.
# Returns non-zero on failure (does NOT die) so callers can handle partial failures.
# Retries up to 3 times on transient errors (502/503/504/429).
# Usage: api_get_file <url> <output_path>
api_get_file() {
    local url="$1"
    local output_path="$2"
    local attempt=1 max_attempts=3 http_code delay
    while true; do
        http_code=$(curl -s --max-time 120 -w "%{http_code}" \
            -H "X-API-KEY: ${LIVEX_API_KEY}" \
            -o "$output_path" \
            "$url" 2>/dev/null) || { warn "Network error: could not reach ${url}"; return $EXIT_API; }
        case "$http_code" in
            502|503|504|429)
                if (( attempt >= max_attempts )); then break; fi
                delay=$(( attempt * attempt ))
                warn "HTTP ${http_code} downloading file (attempt ${attempt}/${max_attempts}), retrying in ${delay}s..."
                sleep "$delay"
                attempt=$((attempt + 1))
                continue
                ;;
            *) break ;;
        esac
    done

    case "$http_code" in
        200|201) return 0 ;;
        401|403) rm -f "$output_path"; warn "Authentication failed (HTTP ${http_code})."; return $EXIT_AUTH ;;
        404)     rm -f "$output_path"; warn "Not found (HTTP 404). Check doc_id."; return $EXIT_API ;;
        *)       rm -f "$output_path"; warn "API error (HTTP ${http_code}). Could not download file."; return $EXIT_API ;;
    esac
}

# --- Workflow URL helper ---
workflow_base_url() {
    local type="${1:-ai-based}"
    echo "${LIVEX_API_HOST}/api/v1/workflow/types/${type}/accounts/${LIVEX_ACCOUNT_ID}"
}

_append_debug_code() {
    local url="$1"
    local param="${LIVEX_FULL_CONFIG_DEBUG_PARAM}=${LIVEX_FULL_CONFIG_DEBUG_CODE}"
    if [[ "$url" == *"${LIVEX_FULL_CONFIG_DEBUG_PARAM}="* ]]; then
        printf '%s\n' "$url"
    elif [[ "$url" == *\?* ]]; then
        printf '%s&%s\n' "$url" "$param"
    else
        printf '%s?%s\n' "$url" "$param"
    fi
}

# Makes a GET request WITHOUT auth (for public endpoints)
api_get_public() {
    local url="$1"
    local response
    response=$(curl -s --max-time 30 -w "\n%{http_code}" \
        "$url" 2>/dev/null) || die $EXIT_API "Network error: could not reach ${url}"

    local http_code body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in
        200|201)
            _check_body_error "$body" "GET (public) ${url}"
            printf '%s\n' "$body"
            ;;
        404)
            die $EXIT_API "Published config not found (HTTP 404). Agent may not be published."
            ;;
        *)
            local msg
            msg=$(echo "$body" | jq -r '.message // .error // empty' 2>/dev/null || true)
            die $EXIT_API "API error (HTTP ${http_code}): ${msg:-$body}"
            ;;
    esac
}

# --- Production safety ---
confirm_production() {
    if [[ "${ENV_LABEL:-}" == "PRODUCTION" && "${SKIP_CONFIRM:-}" != "true" ]]; then
        echo -e "${RED}${BOLD}=== PRODUCTION ENVIRONMENT ===${NC}" >&2
        echo -e "${YELLOW}You are about to modify PRODUCTION config.${NC}" >&2
        echo -n "Type 'yes' to continue: " >&2
        local answer
        read -r answer
        if [[ "$answer" != "yes" ]]; then
            die $EXIT_USAGE "Aborted."
        fi
    fi
}

# --- Diff coloring ---
colorize_diff() {
    while IFS= read -r line; do
        case "$line" in
            ---*)   printf "${RED}%s${NC}\n" "$line" ;;
            +++*)   printf "${GREEN}%s${NC}\n" "$line" ;;
            @@*)    printf "${BLUE}%s${NC}\n" "$line" ;;
            -*)     printf "${RED}%s${NC}\n" "$line" ;;
            +*)     printf "${GREEN}%s${NC}\n" "$line" ;;
            *)      printf "%s\n" "$line" ;;
        esac
    done
}

# --- Config extraction helper ---
# Extracts .config from API response, or returns raw if no wrapper
extract_config() {
    local json="$1"
    # API wraps in {response: {config: ...}} — extract config
    local config
    config=$(echo "$json" | jq -r '.response.config // .config // .response // .' 2>/dev/null)
    echo "$config"
}

# --- Document chunk verification ---
# Queries chunk count for a document. Returns integer or "?" on failure.
# Used as a fallback for doc_size=0 platform bug (doc appears "processing" when ready).
get_doc_chunk_count() {
    local doc_id="$1"
    local payload chunks_resp
    payload=$(jq -n --arg acct "$LIVEX_ACCOUNT_ID" --arg did "$doc_id" '{account_id: $acct, document_id: $did}')
    if chunks_resp=$(api_post "${LIVEX_API_HOST}/api/v1/document/get-chunks" "$payload" 2>/dev/null); then
        printf '%s\n' "$chunks_resp" | jq -r '.response // [] | length' 2>/dev/null || echo "?"
    else
        echo "?"
    fi
}

# --- Field manifest helpers ---
# Parallel indexed arrays (bash 3.2 compat — no associative arrays, no mapfile)
_MANIFEST_PATHS=()
_MANIFEST_GW_READ=()
_MANIFEST_GW_WRITE=()
_MANIFEST_LOADED=false

# Loads field-manifest.json into parallel arrays. Idempotent.
_load_field_manifest() {
    if [[ "$_MANIFEST_LOADED" == "true" ]]; then
        return 0
    fi
    local manifest="${SCRIPT_DIR}/../skills/config-manage/references/field-manifest.json"
    if [[ ! -f "$manifest" ]]; then
        warn "Field manifest not found at ${manifest}"
        return 0
    fi
    local path gw_read gw_write
    while IFS=$'\t' read -r path gw_read gw_write; do
        _MANIFEST_PATHS+=("$path")
        _MANIFEST_GW_READ+=("$gw_read")
        _MANIFEST_GW_WRITE+=("$gw_write")
    done < <(jq -r '.[] | select(._comment == null) | [.path, (.gateway_read | tostring), (.gateway_write | tostring)] | @tsv' "$manifest" 2>/dev/null)
    _MANIFEST_LOADED=true
    return 0
}

# Strips all array notation from a jq path for comparison.
# .voice.language_models[].language_code  -> .voice.language_models.language_code
# .voice.language_models[0].language_code -> .voice.language_models.language_code
# .tool_agent.tools[]                     -> .tool_agent.tools
_normalize_field_path() {
    local p="$1"
    # Remove all [N] and [] segments (bash 3.2 compat: loop instead of regex)
    while [[ "$p" == *'['*']'* ]]; do
        local before="${p%%\[*}"
        local after="${p#*\]}"
        p="${before}${after}"
    done
    echo "$p"
}

# Prints one of: "readable", "hidden", "unknown" to stdout.
# String return avoids set -e/pipefail killing the caller on nonzero exit.
# Normalizes array notation: .voice.language_models, .voice.language_models[],
# and .voice.language_models[0] all match the same manifest entry.
_check_field_visibility() {
    local field="$1"
    [[ "$field" == .* ]] || field=".$field"
    local field_norm
    field_norm=$(_normalize_field_path "$field")
    local i mpath mpath_norm
    for i in "${!_MANIFEST_PATHS[@]}"; do
        mpath="${_MANIFEST_PATHS[$i]}"
        mpath_norm=$(_normalize_field_path "$mpath")
        if [[ "$mpath_norm" == "$field_norm" ]]; then
            if [[ "${_MANIFEST_GW_READ[$i]}" == "true" ]]; then
                echo "readable"
            else
                echo "hidden"
            fi
            return 0
        fi
    done
    echo "unknown"
    return 0
}

# Prints one of: "writable", "read_only", "unknown" to stdout.
# Same pattern as _check_field_visibility — string return, always exits 0.
_check_field_writability() {
    local field="$1"
    [[ "$field" == .* ]] || field=".$field"
    local field_norm
    field_norm=$(_normalize_field_path "$field")
    local i mpath mpath_norm
    for i in "${!_MANIFEST_PATHS[@]}"; do
        mpath="${_MANIFEST_PATHS[$i]}"
        mpath_norm=$(_normalize_field_path "$mpath")
        if [[ "$mpath_norm" == "$field_norm" ]]; then
            if [[ "${_MANIFEST_GW_WRITE[$i]}" == "true" ]]; then
                echo "writable"
            else
                echo "read_only"
            fi
            return 0
        fi
    done
    echo "unknown"
    return 0
}

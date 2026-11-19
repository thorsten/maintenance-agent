#!/usr/bin/env bash
# Shared helpers for the orchestrator and the adapters.

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_env() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "variable $v is missing"
  done
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "program $c is missing"
  done
}

basic_auth() { printf '%s' "$1" | base64 | tr -d '\n'; }

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# BRANCH_PREFIX is a comma-separated list (e.g. "renovate/,dependabot/").
# Prints it as a JSON array for use with jq --argjson.
branch_prefixes_json() {
  jq -cn --arg p "${BRANCH_PREFIX:-}" \
    '$p | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

# jq helper for the adapters: `select(.branch | has_prefix($p))`.
# shellcheck disable=SC2034
JQ_HAS_PREFIX='def has_prefix($ps): . as $b | any($ps[]; . as $x | $b | startswith($x));'

# Call git with an auth header. This keeps the token out of .git/config and
# out of the remote URL, so the agent cannot find it in the working directory.
git_auth() {
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=http.extraHeader \
  GIT_CONFIG_VALUE_0="Authorization: Basic $(adapter_git_basic)" \
  GIT_TERMINAL_PROMPT=0 \
    git "$@"
}

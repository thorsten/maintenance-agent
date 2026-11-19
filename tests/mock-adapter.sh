#!/usr/bin/env bash
# Test adapter: reads candidates from MOCK_CANDIDATES (filtered by BRANCH_PREFIX like the
# real adapters), writes comments and labels to MOCK_OUT.
adapter_check_env() { require_env MOCK_CANDIDATES MOCK_OUT; }
adapter_git_basic() { basic_auth "mock:mock"; }
adapter_list() {
  jq -c --argjson p "$(branch_prefixes_json)" "$JQ_HAS_PREFIX"'select(.source | has_prefix($p))' "$MOCK_CANDIDATES"
}
adapter_comment() { cp "$2" "$MOCK_OUT/comment-$(jq -r '.number' <<<"$1").md"; }
adapter_label() { echo "$2" >"$MOCK_OUT/label-$(jq -r '.number' <<<"$1")"; }

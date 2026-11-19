#!/usr/bin/env bash
# GitHub adapter (github.com and Enterprise Server).
#
# Variables:
#   GITHUB_TOKEN         GitHub App token (recommended) or PAT
#   GITHUB_OWNER         user or organisation whose repos are searched
#   GITHUB_SEARCH_SCOPE  optional, instead of GITHUB_OWNER, e.g. "repo:a/b repo:a/c"
#   GITHUB_API           optional, default https://api.github.com
#   GITHUB_GRAPHQL_URL   optional, default $GITHUB_API/graphql

GITHUB_API="${GITHUB_API:-https://api.github.com}"
GITHUB_GRAPHQL_URL="${GITHUB_GRAPHQL_URL:-$GITHUB_API/graphql}"

adapter_check_env() {
  require_env GITHUB_TOKEN
  [[ -n "${GITHUB_SEARCH_SCOPE:-}" ]] || require_env GITHUB_OWNER
}

adapter_git_basic() { basic_auth "x-access-token:${GITHUB_TOKEN}"; }

_gh() {
  curl -fsS --retry 2 \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$@"
}

adapter_list() {
  local scope="${GITHUB_SEARCH_SCOPE:-user:${GITHUB_OWNER}}"
  local query='query($q:String!){search(query:$q,type:ISSUE,first:100){nodes{... on PullRequest{
    number url headRefName baseRefName mergeable isCrossRepository
    labels(first:30){nodes{name}}
    repository{nameWithOwner url}
    commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}}'
  local resp
  resp="$(jq -n --arg query "$query" --arg q "is:pr is:open archived:false ${scope}" \
            '{query:$query,variables:{q:$q}}' \
          | _gh -X POST "$GITHUB_GRAPHQL_URL" -d @-)"
  if jq -e '.errors' <<<"$resp" >/dev/null; then
    die "GitHub GraphQL: $(jq -c '.errors' <<<"$resp")"
  fi
  jq -c --argjson p "$(branch_prefixes_json)" "$JQ_HAS_PREFIX"'
    .data.search.nodes[]
    | select(.number != null and (.isCrossRepository | not))
    | select(.headRefName | has_prefix($p))
    | {
        id: "\(.repository.nameWithOwner)#\(.number)",
        repo: .repository.nameWithOwner,
        clone_url: "\(.repository.url).git",
        source: .headRefName,
        target: .baseRefName,
        url: .url,
        conflict: (.mergeable == "CONFLICTING"),
        ci_failed: ((.commits.nodes[0].commit.statusCheckRollup.state // "") | IN("FAILURE", "ERROR")),
        labels: [.labels.nodes[].name],
        number: .number
      }' <<<"$resp"
}

adapter_comment() {
  local pr="$1" file="$2" repo number
  repo="$(jq -r '.repo' <<<"$pr")"
  number="$(jq -r '.number' <<<"$pr")"
  jq -Rs '{body: .}' <"$file" \
    | _gh -X POST "$GITHUB_API/repos/$repo/issues/$number/comments" -d @- >/dev/null
}

adapter_label() {
  local pr="$1" label="$2" repo number
  repo="$(jq -r '.repo' <<<"$pr")"
  number="$(jq -r '.number' <<<"$pr")"
  jq -n --arg l "$label" '{labels: [$l]}' \
    | _gh -X POST "$GITHUB_API/repos/$repo/issues/$number/labels" -d @- >/dev/null
}

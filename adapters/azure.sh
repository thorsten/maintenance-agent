#!/usr/bin/env bash
# Azure DevOps adapter (Services and Server).
#
# Variables:
#   AZURE_DEVOPS_PAT      PAT of a service account (Code: Read & Write, PR Threads: Read & Write)
#   AZURE_DEVOPS_ORG      organisation, or instead:
#   AZURE_DEVOPS_URL      full collection URL, e.g. https://dev.azure.com/my-org
#   AZURE_DEVOPS_PROJECT  optional, restrict to one project

if [[ -z "${AZURE_DEVOPS_URL:-}" && -n "${AZURE_DEVOPS_ORG:-}" ]]; then
  AZURE_DEVOPS_URL="https://dev.azure.com/${AZURE_DEVOPS_ORG}"
fi
AZURE_DEVOPS_URL="${AZURE_DEVOPS_URL:-}"
AZURE_DEVOPS_URL="${AZURE_DEVOPS_URL%/}"
_AZ_V="api-version=7.1"

adapter_check_env() { require_env AZURE_DEVOPS_PAT AZURE_DEVOPS_URL; }

adapter_git_basic() { basic_auth ":${AZURE_DEVOPS_PAT}"; }

_az() {
  curl -fsS --retry 2 -u ":${AZURE_DEVOPS_PAT}" \
    -H "Content-Type: application/json" "$@"
}

adapter_list() {
  local base="$AZURE_DEVOPS_URL"
  if [[ -n "${AZURE_DEVOPS_PROJECT:-}" ]]; then
    base="$AZURE_DEVOPS_URL/$(urlencode "$AZURE_DEVOPS_PROJECT")"
  fi

  local prs pr proj_id repo_id id labels evals
  prs="$(_az "$base/_apis/git/pullrequests?searchCriteria.status=active&\$top=200&$_AZ_V" \
         | jq -c --argjson p "$(branch_prefixes_json)" "$JQ_HAS_PREFIX"'
             .value[]
             | select(.sourceRefName | sub("^refs/heads/"; "") | has_prefix($p))
             | select(.forkSource == null)')"

  while IFS= read -r pr; do
    [[ -n "$pr" ]] || continue
    proj_id="$(jq -r '.repository.project.id' <<<"$pr")"
    repo_id="$(jq -r '.repository.id' <<<"$pr")"
    id="$(jq -r '.pullRequestId' <<<"$pr")"

    labels="$(_az "$AZURE_DEVOPS_URL/$proj_id/_apis/git/repositories/$repo_id/pullRequests/$id/labels?$_AZ_V")"
    # Build validation runs through branch policies; "rejected" means the build is red.
    evals="$(_az "$AZURE_DEVOPS_URL/$proj_id/_apis/policy/evaluations?artifactId=vstfs:///CodeReview/CodeReviewId/$proj_id/$id&api-version=7.1-preview.1" \
             || echo '{"value":[]}')"

    jq -c -n --argjson pr "$pr" --argjson labels "$labels" --argjson evals "$evals" \
       --arg base "$AZURE_DEVOPS_URL" '
      ($pr.repository.project.name) as $proj
      | ($pr.repository.name) as $repo
      | {
          id: "\($proj)/\($repo)!\($pr.pullRequestId)",
          repo: "\($proj)/\($repo)",
          clone_url: "\($base)/\($proj | @uri)/_git/\($repo | @uri)",
          source: ($pr.sourceRefName | sub("^refs/heads/"; "")),
          target: ($pr.targetRefName | sub("^refs/heads/"; "")),
          url: "\($base)/\($proj | @uri)/_git/\($repo | @uri)/pullrequest/\($pr.pullRequestId)",
          conflict: ($pr.mergeStatus == "conflicts"),
          ci_failed: ([$evals.value[]?
                       | select((.configuration.type.displayName // "") == "Build")
                       | select(.status == "rejected")] | length > 0),
          labels: [$labels.value[]?.name],
          project_id: $pr.repository.project.id,
          repo_id: $pr.repository.id,
          pr_id: $pr.pullRequestId
        }'
  done <<<"$prs"
}

_az_pr_url() {
  local pr="$1"
  printf '%s/%s/_apis/git/repositories/%s/pullRequests/%s' \
    "$AZURE_DEVOPS_URL" \
    "$(jq -r '.project_id' <<<"$pr")" \
    "$(jq -r '.repo_id' <<<"$pr")" \
    "$(jq -r '.pr_id' <<<"$pr")"
}

adapter_comment() {
  local pr="$1" file="$2"
  jq -Rs '{comments: [{parentCommentId: 0, content: ., commentType: 1}], status: 1}' <"$file" \
    | _az -X POST "$(_az_pr_url "$pr")/threads?$_AZ_V" -d @- >/dev/null
}

adapter_label() {
  local pr="$1" label="$2"
  jq -n --arg l "$label" '{name: $l}' \
    | _az -X POST "$(_az_pr_url "$pr")/labels?$_AZ_V" -d @- >/dev/null
}

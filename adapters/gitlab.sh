#!/usr/bin/env bash
# GitLab adapter (gitlab.com and self-hosted).
#
# Variables:
#   GITLAB_TOKEN   group/project access token or PAT (scopes: api, write_repository)
#   GITLAB_URL     optional, default https://gitlab.com
#   GITLAB_GROUP   optional, group (path or ID). Without it: all MRs visible to the token

GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
GITLAB_URL="${GITLAB_URL%/}"
_GL_API="$GITLAB_URL/api/v4"

adapter_check_env() { require_env GITLAB_TOKEN; }

adapter_git_basic() { basic_auth "oauth2:${GITLAB_TOKEN}"; }

_gl() { curl -fsS --retry 2 -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "$@"; }

adapter_list() {
  local base="$_GL_API/merge_requests"
  if [[ -n "${GITLAB_GROUP:-}" ]]; then
    base="$_GL_API/groups/$(urlencode "$GITLAB_GROUP")/merge_requests"
  fi

  local mrs mr pid iid detail project
  mrs="$(_gl "$base?state=opened&scope=all&per_page=100" \
         | jq -c --argjson p "$(branch_prefixes_json)" "$JQ_HAS_PREFIX"'
             .[]
             | select(.source_branch | has_prefix($p))
             | select(.source_project_id == .target_project_id)')"

  while IFS= read -r mr; do
    [[ -n "$mr" ]] || continue
    pid="$(jq -r '.project_id' <<<"$mr")"
    iid="$(jq -r '.iid' <<<"$mr")"
    # Pipeline status and conflict flag are only reliable in the single-MR request.
    detail="$(_gl "$_GL_API/projects/$pid/merge_requests/$iid")"
    project="$(_gl "$_GL_API/projects/$pid")"
    jq -c -n --argjson mr "$detail" --argjson proj "$project" '{
        id: "\($proj.path_with_namespace)!\($mr.iid)",
        repo: $proj.path_with_namespace,
        clone_url: $proj.http_url_to_repo,
        source: $mr.source_branch,
        target: $mr.target_branch,
        url: $mr.web_url,
        conflict: ($mr.has_conflicts // false),
        ci_failed: (($mr.head_pipeline.status // "") == "failed"),
        labels: ($mr.labels // []),
        project_id: $mr.project_id,
        iid: $mr.iid
      }'
  done <<<"$mrs"
}

adapter_comment() {
  local pr="$1" file="$2" pid iid
  pid="$(jq -r '.project_id' <<<"$pr")"
  iid="$(jq -r '.iid' <<<"$pr")"
  _gl -X POST "$_GL_API/projects/$pid/merge_requests/$iid/notes" \
    --data-urlencode "body@${file}" >/dev/null
}

adapter_label() {
  local pr="$1" label="$2" pid iid
  pid="$(jq -r '.project_id' <<<"$pr")"
  iid="$(jq -r '.iid' <<<"$pr")"
  _gl -X PUT "$_GL_API/projects/$pid/merge_requests/$iid" \
    --data-urlencode "add_labels=${label}" >/dev/null
}

#!/usr/bin/env bash
# Maintenance agent: platform-neutral orchestrator.
#
# Flow per update PR (Renovate/Dependabot) with a conflict or red CI:
#   clone -> agent works locally (without platform token) -> orchestrator pushes
#   and comments. Nothing is ever merged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

PLATFORM="${PLATFORM:-}"
ADAPTER_FILE="${ADAPTER_FILE:-$ROOT/adapters/$PLATFORM.sh}"
[[ -f "$ADAPTER_FILE" ]] || die "PLATFORM must be github, gitlab or azure (is: '${PLATFORM}')"
# shellcheck disable=SC1090
source "$ADAPTER_FILE"

# Comma-separated list of branch prefixes of the update PRs to look at.
export BRANCH_PREFIX="${BRANCH_PREFIX:-renovate/,dependabot/}"
[[ "$(branch_prefixes_json)" != "[]" ]] || die "BRANCH_PREFIX contains no prefix"
MAX_PRS="${MAX_PRS:-5}"
MAX_TURNS="${MAX_TURNS:-80}"
NEEDS_HUMAN_LABEL="${NEEDS_HUMAN_LABEL:-needs-human}"
AGENT_NAME="${AGENT_NAME:-maintenance-agent}"
AGENT_EMAIL="${AGENT_EMAIL:-maintenance-agent@noreply.invalid}"
REPORT_LANGUAGE="${REPORT_LANGUAGE:-English}"
ALLOWED_TOOLS="${ALLOWED_TOOLS:-Read,Edit,Write,Glob,Grep,Bash,WebFetch}"
PROMPT_FILE="${PROMPT_FILE:-$ROOT/prompts/maintain.md}"
DRY_RUN="${DRY_RUN:-0}"
WORKDIR="${WORKDIR:-${TMPDIR:-/tmp}/maintenance-agent}"

# The agent process does not see these variables.
SECRET_VARS=(GITHUB_TOKEN GITLAB_TOKEN AZURE_DEVOPS_PAT RENOVATE_TOKEN GITHUB_COM_TOKEN)

require_cmd git curl jq claude
adapter_check_env
mkdir -p "$WORKDIR"

# finish <pr-json> <report-file> [label]
finish() {
  local pr="$1" file="$2" label="${3:-}"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: would post this comment${label:+ and set label '$label'}:"
    cat "$file" >&2
    return 0
  fi
  adapter_comment "$pr" "$file"
  if [[ -n "$label" ]]; then
    adapter_label "$pr" "$label"
  fi
}

process_pr() {
  local pr="$1"
  local id clone_url source target url reason
  id="$(jq -r '.id' <<<"$pr")"
  clone_url="$(jq -r '.clone_url' <<<"$pr")"
  source="$(jq -r '.source' <<<"$pr")"
  target="$(jq -r '.target' <<<"$pr")"
  url="$(jq -r '.url' <<<"$pr")"
  reason="$(jq -r '[if .conflict then "merge conflict with the target branch" else empty end,
                    if .ci_failed then "CI failed" else empty end] | join(", ")' <<<"$pr")"

  local work repo_dir report
  work="$(mktemp -d "$WORKDIR/pr.XXXXXX")"
  repo_dir="$work/repo"
  report="$work/report.md"

  log "$id: cloning ($reason)"
  git_auth clone --quiet "$clone_url" "$repo_dir"
  git -C "$repo_dir" checkout --quiet "$source"
  git -C "$repo_dir" config user.name "$AGENT_NAME"
  git -C "$repo_dir" config user.email "$AGENT_EMAIL"

  local before
  before="$(git -C "$repo_dir" rev-parse HEAD)"

  # The agent already had a go and it is still not green: do not spend more
  # money, hand over to a human instead.
  if [[ "$(git -C "$repo_dir" log -1 --format=%ae)" == "$AGENT_EMAIL" ]]; then
    log "$id: last commit is from the agent, handing over to a human"
    {
      echo "### Maintenance agent: please check manually"
      echo
      echo "The last commit on this branch is already from the agent, yet this still applies: $reason."
      echo "There will be no second automatic attempt."
    } >"$report"
    finish "$pr" "$report" "$NEEDS_HUMAN_LABEL"
    return 0
  fi

  local prompt
  prompt="$(cat "$PROMPT_FILE")

## Context of this run

- Repository: $(jq -r '.repo' <<<"$pr")
- Pull request: $url
- Working branch (checked out): $source
- Target branch: origin/$target
- Reason: $reason
- Report language: $REPORT_LANGUAGE"

  local unset_args=() v
  for v in "${SECRET_VARS[@]}"; do unset_args+=(-u "$v"); done

  log "$id: starting agent (max. $MAX_TURNS turns)"
  local out rc=0
  out="$(cd "$repo_dir" && env "${unset_args[@]}" claude -p "$prompt" \
          --max-turns "$MAX_TURNS" \
          --permission-mode acceptEdits \
          --allowedTools "$ALLOWED_TOOLS" \
          --output-format json </dev/null)" || rc=$?

  local result status cost turns
  result="$(jq -r '.result // empty' <<<"$out" 2>/dev/null || true)"
  cost="$(jq -r '.total_cost_usd // empty' <<<"$out" 2>/dev/null || true)"
  turns="$(jq -r '.num_turns // empty' <<<"$out" 2>/dev/null || true)"
  status="$(printf '%s\n' "$result" | sed -n 's/^STATUS:[[:space:]]*\([a-z-]*\).*/\1/p' | head -n1)"

  local after branch pushed=0 note=""
  after="$(git -C "$repo_dir" rev-parse HEAD)"
  branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)"

  if [[ $rc -ne 0 ]]; then
    note="The agent run aborted with exit code $rc (turn limit, API error or similar)."
  elif [[ "$status" != "fixed" ]]; then
    note=""
  elif [[ "$branch" != "$source" ]]; then
    note="The agent switched branches ($branch), nothing was pushed."
  elif [[ "$after" == "$before" ]]; then
    note="The agent reports success but did not create a commit. Nothing was pushed."
  elif [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: would push $after to $source"
    pushed=1
  elif git_auth -C "$repo_dir" push --quiet \
         --force-with-lease="refs/heads/$source:$before" \
         origin "HEAD:refs/heads/$source"; then
    log "$id: pushed ($after)"
    pushed=1
  else
    note="The push was rejected (the branch changed in the meantime or is protected)."
  fi

  {
    if [[ $pushed -eq 1 ]]; then
      echo "### Maintenance agent: changes pushed, please review"
    else
      echo "### Maintenance agent: please check manually"
    fi
    echo
    if [[ -n "$note" ]]; then echo "> $note"; echo; fi
    if [[ -n "$result" ]]; then
      printf '%s\n' "$result" | sed '/^STATUS:/d'
    else
      echo "_The agent did not deliver a report._"
    fi
    echo
    echo "---"
    echo "_Reason: ${reason}.${turns:+ Turns: $turns.}${cost:+ Cost: $cost USD.} This agent never merges._"
  } >"$report"

  if [[ $pushed -eq 1 ]]; then
    finish "$pr" "$report"
  else
    finish "$pr" "$report" "$NEEDS_HUMAN_LABEL"
  fi
}

log "Platform: $PLATFORM, branch prefixes: $BRANCH_PREFIX, limit: $MAX_PRS PRs"
candidates="$(adapter_list)"

handled=0
failed=0
while IFS= read -r pr <&3; do
  [[ -n "$pr" ]] || continue
  id="$(jq -r '.id' <<<"$pr")"

  if jq -e --arg l "$NEEDS_HUMAN_LABEL" '.labels | index($l)' <<<"$pr" >/dev/null; then
    log "$id: skipped (label $NEEDS_HUMAN_LABEL)"
    continue
  fi
  if ! jq -e '.conflict or .ci_failed' <<<"$pr" >/dev/null; then
    continue
  fi
  if (( handled >= MAX_PRS )); then
    log "Limit of $MAX_PRS PRs reached, the rest follows in the next run"
    break
  fi
  handled=$((handled + 1))

  # Subshell with its own errexit: a failure only aborts this PR.
  set +e
  ( set -e; process_pr "$pr" )
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    failed=$((failed + 1))
    log "$id: processing failed (exit $rc)"
  fi
done 3<<<"$candidates"

log "Done: $handled processed, $failed with errors"
[[ $failed -eq 0 ]]

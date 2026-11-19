#!/usr/bin/env bash
# Local run without a platform and without a real agent.
# Checks the orchestrator: clone, call the agent, push, comment, label.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail() { echo "FAILED: $*" >&2; exit 1; }

# --- Test repository with the update branches --------------------------------
git init --quiet --bare -b main "$T/origin.git"
git clone --quiet "$T/origin.git" "$T/seed" 2>/dev/null
(
  cd "$T/seed"
  git config user.name seed; git config user.email seed@example.com
  echo '{"dep":"1.0.0"}' >manifest.json
  git add . && git commit --quiet -m "init" && git push --quiet origin main
  for b in renovate/ok renovate/stuck renovate/tried renovate/clean \
           dependabot/npm_and_yarn/dep-2.0.0 feature/red; do
    git checkout --quiet -b "$b" main
    echo "{\"dep\":\"2.0.0\",\"b\":\"$b\"}" >manifest.json
    git commit --quiet -am "chore(deps): update dep to v2"
    git push --quiet origin "$b"
  done
  # "tried": the agent has already committed here once
  git checkout --quiet renovate/tried
  echo fix >fix.txt && git add fix.txt
  git -c user.email=maintenance-agent@noreply.invalid commit --quiet -m "fix: adapt"
  git push --quiet origin renovate/tried
)

cand() { # number branch ci_failed labels
  jq -c -n --arg n "$1" --arg b "$2" --argjson f "$3" --argjson l "$4" --arg u "$T/origin.git" \
    '{id:"mock#\($n)",repo:"mock/repo",clone_url:$u,source:$b,target:"main",
      url:"https://example.invalid/\($n)",conflict:false,ci_failed:$f,labels:$l,number:($n|tonumber)}'
}
{
  cand 1 renovate/ok    true  '[]'
  cand 2 renovate/stuck true  '[]'
  cand 3 renovate/tried true  '[]'
  cand 4 renovate/clean false '[]'
  cand 5 renovate/ok    true  '["needs-human"]'
  cand 6 dependabot/npm_and_yarn/dep-2.0.0 true '[]'
  cand 7 feature/red    true  '[]'
} >"$T/candidates.jsonl"

# --- Stub for the Claude CLI -------------------------------------------------
mkdir -p "$T/bin" "$T/out"
cat >"$T/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Must not see any platform tokens.
if [[ -n "${GITHUB_TOKEN:-}${GITLAB_TOKEN:-}${AZURE_DEVOPS_PAT:-}" ]]; then
  echo "token visible in the agent process" >&2; exit 97
fi
branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" == "renovate/ok" || "$branch" == dependabot/* ]]; then
  echo "adapted" >adapted.txt
  git add adapted.txt && git commit --quiet -m "fix: adapt to dep v2"
  jq -n '{result:"STATUS: fixed\n\n**Update:** dep 1.0.0 -> 2.0.0",total_cost_usd:0.42,num_turns:7}'
else
  jq -n '{result:"STATUS: needs-human\n\n**Please look at:** unclear",total_cost_usd:0.10,num_turns:3}'
fi
STUB
chmod +x "$T/bin/claude"

# --- Run ---------------------------------------------------------------------
PATH="$T/bin:$PATH" \
PLATFORM=mock ADAPTER_FILE="$ROOT/tests/mock-adapter.sh" \
MOCK_CANDIDATES="$T/candidates.jsonl" MOCK_OUT="$T/out" \
WORKDIR="$T/work" GITHUB_TOKEN=secret \
  "$ROOT/bin/run.sh"

# --- Expectations ------------------------------------------------------------
g() { git -C "$T/origin.git" "$@"; }

[[ "$(g log -1 --format=%s renovate/ok)" == "fix: adapt to dep v2" ]] || fail "PR 1: commit not pushed"
[[ "$(g log -1 --format=%ae renovate/ok)" == "maintenance-agent@noreply.invalid" ]] || fail "PR 1: wrong author"
grep -q "changes pushed" "$T/out/comment-1.md" || fail "PR 1: comment missing"
grep -q "STATUS:" "$T/out/comment-1.md" && fail "PR 1: STATUS line in the comment"
[[ ! -e "$T/out/label-1" ]] || fail "PR 1: unexpected label"

[[ "$(g log -1 --format=%s renovate/stuck)" == "chore(deps): update dep to v2" ]] || fail "PR 2: unexpected push"
[[ "$(cat "$T/out/label-2")" == "needs-human" ]] || fail "PR 2: label missing"

grep -q "no second automatic attempt" "$T/out/comment-3.md" || fail "PR 3: no handover comment"
[[ "$(cat "$T/out/label-3")" == "needs-human" ]] || fail "PR 3: label missing"

[[ ! -e "$T/out/comment-4.md" ]] || fail "PR 4: green PR was touched"
[[ ! -e "$T/out/comment-5.md" ]] || fail "PR 5: labelled PR was touched"

[[ "$(g log -1 --format=%s dependabot/npm_and_yarn/dep-2.0.0)" == "fix: adapt to dep v2" ]] || fail "PR 6: Dependabot branch not pushed"
grep -q "changes pushed" "$T/out/comment-6.md" || fail "PR 6: comment missing"
[[ ! -e "$T/out/label-6" ]] || fail "PR 6: unexpected label"

[[ ! -e "$T/out/comment-7.md" ]] || fail "PR 7: branch outside BRANCH_PREFIX was touched"
[[ "$(g log -1 --format=%s feature/red)" == "chore(deps): update dep to v2" ]] || fail "PR 7: unexpected push"

echo "Smoke test passed"

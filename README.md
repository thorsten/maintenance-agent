# maintenance-agent

A central repo that makes dependency updates mergeable across any number of projects. Renovate or Dependabot creates the update PRs, a Claude Code agent fixes merge conflicts and red CI, a human reviews and merges. Runs on GitHub, GitLab and Azure DevOps with the same core.

With Renovate, the maintained repos do not need a file of their own. Dependabot is configured per repo, see [Dependabot](#dependabot).

## How it works

1. **Renovate** runs at night, uses `autodiscover` to find all repos the token has access to, and opens update PRs. It merges patches and dev dependencies itself when CI is green.
2. **The agent** runs a few hours later. `bin/run.sh` uses the platform adapter to fetch all open PRs whose branch starts with `renovate/` or `dependabot/` and that have a conflict or a red CI.
3. Per PR: clone, start Claude Code headless with `prompts/maintain.md`. The agent rebases, regenerates lockfiles, adapts code and runs the checks that the repo's CI prescribes.
4. The orchestrator pushes the agent's commits and posts its report as a comment on the PR. If the agent gets stuck, the PR gets the label `needs-human` instead of a push.

There is at most one agent run per PR: if the last commit is already from the agent and CI is still red, the PR is only labelled.

## Layout

| Path | Purpose |
|---|---|
| `bin/run.sh` | Orchestrator, platform-neutral |
| `prompts/maintain.md` | Generic task for the agent |
| `adapters/{github,gitlab,azure}.sh` | List PRs, comment, label, Git auth |
| `renovate/config.js` | Shared Renovate rules |
| `Dockerfile` | Core image with CLI and toolchains |
| `.github/workflows/`, `.gitlab-ci.yml`, `azure/` | Scheduled pipelines per platform |
| `tests/smoke.sh` | Local run without a platform and without a real agent |

## Setup

**GitHub**
- Create a GitHub App (repository permissions: Contents, Pull requests, Issues, Workflows each Read & Write; Checks and Commit statuses Read) and install it on the desired repos.
- In this repo: variable `MAINT_APP_ID`, secrets `MAINT_APP_PRIVATE_KEY` and `ANTHROPIC_API_KEY`.

**GitLab**
- Group access token (role Developer, scopes `api`, `write_repository`) as the masked variable `MAINT_GITLAB_TOKEN`, plus `ANTHROPIC_API_KEY` and optionally `MAINT_GROUP`.
- Two pipeline schedules with `TASK=renovate` and `TASK=agent`.

**Azure DevOps**
- Service account with a PAT (Code: Read & Write, Pull Request Threads: Read & Write) as the secret variable `MAINT_AZURE_PAT`, plus `ANTHROPIC_API_KEY`.
- Create one pipeline each from `azure/renovate.yml` and `azure/agent.yml`.

Everywhere: the account gets no merge permission on protected branches, and branch protection enforces a review.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PLATFORM` | – | `github`, `gitlab` or `azure` |
| `BRANCH_PREFIX` | `renovate/,dependabot/` | Comma-separated branch prefixes of the PRs the agent touches |
| `MAX_PRS` | `5` | Upper limit per run |
| `MAX_TURNS` | `80` | Upper limit per agent run |
| `NEEDS_HUMAN_LABEL` | `needs-human` | Label for the handover |
| `REPORT_LANGUAGE` | `English` | Language of the PR comment |
| `ALLOWED_TOOLS` | `Read,Edit,Write,Glob,Grep,Bash,WebFetch` | The agent's tools |
| `DRY_RUN` | `0` | `1`: do not push, comment or label |
| `AGENT_NAME`, `AGENT_EMAIL` | `maintenance-agent`, `…@noreply.invalid` | Commit identity |

Model access: `ANTHROPIC_API_KEY`, or pass the usual Claude Code variables for Bedrock, Vertex or Foundry through to the container. Platform-specific variables are listed at the top of the respective adapter file.

Repo specifics belong in a `CLAUDE.md` in the respective repo. The agent reads it but does not need it.

## Dependabot

The agent handles Dependabot PRs the same way as Renovate PRs: it picks up every open PR whose branch starts with `dependabot/`. Only the creation of the PRs differs.

- Dependabot is GitHub's own service and is switched on per repo with a `.github/dependabot.yml`. There is no central configuration, so `renovate/config.js` and the Renovate pipelines play no part. If you only use Dependabot, leave the Renovate schedule disabled.
- Do not let both tools update the same ecosystem in the same repo, or you get two PRs per update.
- To restrict the agent to one tool, set `BRANCH_PREFIX=dependabot/` or `BRANCH_PREFIX=renovate/`.
- Once the agent has pushed to a Dependabot branch, Dependabot stops rebasing and updating that PR. This is intended, as with Renovate. To get a fresh PR, comment `@dependabot recreate`; that discards the agent's commits.
- Workflows triggered by Dependabot itself run with a read-only `GITHUB_TOKEN` and only see Dependabot secrets. A CI that is red only for that reason cannot be fixed in the code: the agent finds nothing to change and the PR ends up as `needs-human`.

## Security

- The agent never merges and does not push itself. The orchestrator does the pushing, with `--force-with-lease` against exactly the state that was cloned.
- The platform token is neither in the remote URL nor in `.git/config` and is removed from the environment of the agent process. This is hygiene, not a hard sandbox: agent and orchestrator run as the same user in the same container. If you want more, start the agent in a container of its own without a token and with restricted network access.
- The agent installs packages and runs their scripts. The job must therefore not see any deploy or production secrets.
- Changelogs and package contents are foreign text. The prompt treats them as data; the review remains mandatory nonetheless. Pay particular attention there to changes to tests and CI files.

## Known limitations

- **Not yet run against real platforms.** What has been checked is the orchestrator (`tests/smoke.sh`) and the parsing of the API responses against sample data. Please do the first run with `DRY_RUN=1`.
- Renovate no longer updates a branch automatically once a foreign commit sits on it. This is intended here, so that the agent's work is preserved. If a newer version arrives later, have Renovate recreate the PR via its rebase checkbox.
- GitHub computes `mergeable` with a delay. A fresh conflict is sometimes only detected in the next run.
- At most 100 open PRs (GitHub, GitLab) or 200 (Azure) are considered per run.
- The image ships Node and PHP 8.2. Add other runtimes in the `Dockerfile`.
- Image tags of Renovate and action versions are not pinned. Fix them before continuous operation.

## Testing locally

```bash
bash tests/smoke.sh

# Real dry run against GitHub
PLATFORM=github GITHUB_TOKEN=… GITHUB_OWNER=… ANTHROPIC_API_KEY=… DRY_RUN=1 MAX_PRS=1 bin/run.sh
```

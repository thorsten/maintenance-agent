# Core image: orchestrator, Claude Code CLI and the common toolchains.
# Add further runtimes (Python, Go, Java, .NET, another PHP version) here.
FROM node:26-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl jq ca-certificates unzip make openssh-client \
      php-cli php-xml php-mbstring php-curl php-zip php-intl composer \
 && rm -rf /var/lib/apt/lists/*

RUN corepack enable \
 && npm install -g @anthropic-ai/claude-code

COPY --chown=node:node . /opt/maintenance-agent

# Do not run as root: fewer privileges for the agent.
USER node
WORKDIR /home/node
ENTRYPOINT ["/opt/maintenance-agent/bin/run.sh"]

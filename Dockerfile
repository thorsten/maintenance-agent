# Core image: orchestrator, Claude Code CLI and the common toolchains.
# Add further runtimes (Python, Go, Java, .NET, another PHP version) here.
FROM node:26-bookworm-slim

# PHP comes from the Sury repository: Debian bookworm itself only ships 8.2.
ARG PHP_VERSION=8.5

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl jq ca-certificates unzip make openssh-client \
 && curl -fsSLo /tmp/sury-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb \
 && dpkg -i /tmp/sury-keyring.deb \
 && rm /tmp/sury-keyring.deb \
 && echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ bookworm main" \
      > /etc/apt/sources.list.d/php.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "php${PHP_VERSION}-cli" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-mbstring" \
      "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-intl" \
      "php${PHP_VERSION}-gd" "php${PHP_VERSION}-sqlite3" "php${PHP_VERSION}-bcmath" \
 && rm -rf /var/lib/apt/lists/*

# Debian's composer package would pull in the distribution's PHP again.
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# Node no longer bundles Corepack (removed in Node 25), so install it from npm.
RUN npm install -g corepack @anthropic-ai/claude-code \
 && corepack enable

COPY --chown=node:node . /opt/maintenance-agent

# Do not run as root: fewer privileges for the agent.
USER node
WORKDIR /home/node
ENTRYPOINT ["/opt/maintenance-agent/bin/run.sh"]

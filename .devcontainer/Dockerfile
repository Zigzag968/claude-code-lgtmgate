# Local Linux sandbox for `claude plugin eval` (probe evals, #81).
# Modelled on the official anthropics/claude-code .devcontainer (node base, npm-installed CLI),
# minus the firewall and shell niceties; adds bubblewrap + socat for the eval Bash sandbox.
FROM node:20

# Pinned by package.json + package-lock.json in this folder (the install checks the integrity hash); the verify-ok
# grader reads that version's trace format. A bump needs a full rerun of the suite
# (scripts/run-probe-evals-docker.sh) and a re-check of the pinned graders.

RUN apt-get update && apt-get install -y --no-install-recommends \
    git gh jq procps ca-certificates bubblewrap socat \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV DEVCONTAINER=true
ENV PATH=$PATH:/opt/claude-cli/node_modules/.bin

RUN NODE_HOME="$(getent passwd node | cut -d: -f6)" \
  && mkdir -p /opt/claude-cli /workspace "$NODE_HOME/.claude" \
  && chown -R node:node /opt/claude-cli /workspace "$NODE_HOME/.claude"

USER node
WORKDIR /opt/claude-cli
COPY --chown=node:node package.json package-lock.json ./
RUN npm ci

WORKDIR /workspace

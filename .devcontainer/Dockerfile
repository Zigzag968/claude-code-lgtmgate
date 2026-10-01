# Local Linux sandbox for `claude plugin eval` (probe evals, #81).
# Modelled on the official anthropics/claude-code .devcontainer (node base, npm-installed CLI),
# minus the firewall and shell niceties; adds bubblewrap + socat for the eval Bash sandbox.
FROM node:20

# Pinned: the verify-ok grader reads the 2.1.286 trace format. A bump needs a full rerun of the suite
# (scripts/run-probe-evals-docker.sh) and a re-check of the pinned graders; keep devcontainer.json in step.
ARG CLAUDE_CODE_VERSION=2.1.286

RUN apt-get update && apt-get install -y --no-install-recommends \
    git gh jq procps ca-certificates bubblewrap socat \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV DEVCONTAINER=true
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

RUN NODE_HOME="$(getent passwd node | cut -d: -f6)" \
  && mkdir -p /usr/local/share/npm-global /workspace "$NODE_HOME/.claude" \
  && chown -R node:node /usr/local/share /workspace "$NODE_HOME/.claude"

USER node
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

WORKDIR /workspace

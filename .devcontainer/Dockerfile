# Local Linux sandbox for `claude plugin eval` (probe evals, #81).
# Modelled on the official anthropics/claude-code .devcontainer (node base, npm-installed CLI),
# minus the firewall and shell niceties; adds bubblewrap + socat for the eval Bash sandbox.
FROM node:20

ARG CLAUDE_CODE_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    git gh jq procps ca-certificates bubblewrap socat \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV DEVCONTAINER=true
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

RUN mkdir -p /usr/local/share/npm-global /workspace /home/node/.claude \
  && chown -R node:node /usr/local/share /workspace /home/node/.claude

USER node
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

WORKDIR /workspace

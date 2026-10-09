'use strict'

// The secret-shaped patterns shared by every screen that must never let a credential through:
// scripts/redact-fixture.cjs (rewrites or refuses) and scripts/agent-context.cjs (refuses). One table,
// so the two screens cannot drift. Regexes carry `/g`: use them with `replace`, never with `.test`.

// GitHub tokens (classic, fine-grained, app), API keys (base64url: `_` included)
const SECRET_REWRITES = [
  { id: 'github-token', kind: 'rewrite', re: /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g, to: 'gh*_REDACTED' },
  { id: 'github-pat', kind: 'rewrite', re: /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g, to: 'github_pat_REDACTED' },
  { id: 'sk-rk-key', kind: 'rewrite', re: /\b(sk|rk)-[A-Za-z0-9_-]{20,}\b/g, to: '$1-REDACTED' },
]

// A PEM private-key header (RSA, EC, OPENSSH, ENCRYPTED...): no safe rewrite, the caller refuses
const PEM_RULE = { id: 'pem-private-key', kind: 'refuse', re: /-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----/ }

module.exports = { SECRET_REWRITES, PEM_RULE }

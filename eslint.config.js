'use strict'
// ESLint config of the code-quality audit (scripts/audit.cjs). CommonJS on purpose: package.json has no
// "type" (it would flip every .js of this repo to ESM) and unicorn is ESM-only (require(esm), Node >= 22.12).
// Scope is size and naming only. Existing findings are frozen by scripts/audit-baseline.json (a ratchet),
// never silenced here and never by an eslint-disable comment.
const unicorn = require('eslint-plugin-unicorn').default

// The workflow files are run through `new Function`: they start with `export const meta` and hold top-level
// `return` / `await`, which no parser accepts as is. Lint them as the body of an async function: blank the
// leading `export `, open the wrapper on line 1 (real line numbers kept), drop the wrapper's own message.
const workflowSource = {
  processors: {
    'workflow-source': {
      preprocess: (text) => [`(async () => {${text.replace(/^export /, '')}\n})`],
      postprocess: (messageLists) => messageLists[0].filter((message) => !(message.ruleId === 'max-lines-per-function' && message.line === 1)),
      supportsAutofix: false,
    },
  },
}

module.exports = [
  { ignores: ['node_modules/**', '**/fixtures/**'] },
  { files: ['**/*.js', '**/*.mjs'], languageOptions: { sourceType: 'module', ecmaVersion: 'latest' } },
  { files: ['**/*.cjs'], languageOptions: { sourceType: 'commonjs', ecmaVersion: 'latest' } },
  {
    files: ['workflows/deliver-pipeline.js', 'templates/test-deliver-pipeline.js'],
    languageOptions: { sourceType: 'commonjs', ecmaVersion: 'latest' },
    plugins: { lgtmgate: workflowSource },
    processor: 'lgtmgate/workflow-source',
  },
  {
    files: ['**/*.js', '**/*.cjs', '**/*.mjs'],
    plugins: { unicorn },
    // Existing `eslint-disable` comments are not ESLint's business here: scripts/audit.cjs counts them as the `suppression` rule and the baseline freezes them.
    linterOptions: { reportUnusedDisableDirectives: 'off' },
    rules: {
      camelcase: 'error',
      'max-lines': ['error', { max: 600 }],
      'max-lines-per-function': ['error', { max: 80 }],
      'no-shadow': 'error',
      'unicorn/name-replacements': ['error', {
        checkFilenames: false, // ls-lint owns file names
        replacements: {
          cfg: { config: true },
          wt: { worktree: true },
          prNum: { prNumber: true },
        },
        // Names accepted in ANY file (none today). Existing identifiers are frozen by the baseline, never listed here.
        allowList: {},
      }],
    },
  },
]

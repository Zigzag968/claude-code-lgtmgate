'use strict'

// Remedy lines of scripts/agent-context.cjs (#416): each refusal rule has one line `agent-context: hint: <rule>: <remedy>; see
// docs/consumer-reference.md#<rule>`, printed once per run after the refusal lines. Pure functions, no git, no file system.
// A rule enters the table with its row in docs/consumer-reference.md (tests/scripts/test-agent-context.sh checks each one).

const { CONTEXT_FILE_HINT } = require('./agent-context-lanes.cjs')

const PATHS_HINT = 'hint: paths takes paths: ["glob", "glob"] or a block list of strings (indented "- item" lines)'

// [rule, remedy, pattern]: the pattern defaults to a message `[<path>: ]<rule>[ at line N]`; the others carry their own.
const REMEDIES = [
  ['folder-absent', 'commit the projectSpecifics folder on the base branch, or fix the projectSpecifics path'],
  ['missing', 'commit the file on the base branch, or fix its path in agentContext'],
  ['invalid-path', 'a path takes only letters, digits and . _ / - characters'],
  ['absolute-path', 'write the path relative to the repository root, without a leading slash'],
  ['bad-segment', 'remove the empty, . and .. segments from the path'],
  ['not-md', 'a listed file must end in .md'],
  ['symlink', 'replace the symbolic link with a regular file'],
  ['submodule', 'a submodule cannot hold rules; commit a regular .md file'],
  ['tree', 'list the .md files of a folder one by one, a folder is not a file'],
  ['not-regular-file', 'commit a regular .md file'],
  ['too-many-files', 'a source holds at most 8 files; list fewer or merge some of them'],
  ['ceiling', 'the files together exceed 65536 bytes; shorten or remove files', /^ceiling: /],
  ['control-char', 'remove the control character from the file'],
  ['invisible-char', 'remove the zero-width or invisible character from the file'],
  ['machine-literal', 'remove the project_specifics tag from the file'],
  ['machine-marker', 'remove the acceptance, ac, pipeline or decision-log comment marker from the file'],
  ['one-way-door-line', 'reword the line that starts with one-way-door:'],
  ['unclosed-comment', 'close the HTML comment with --> or remove its opener'],
  ['secret-*', 'remove the secret from the file and rotate it', /: secret-[a-z0-9-]+ at line \d+$/],
  ['invalid-utf8', 'save the file as UTF-8'],
  ['frontmatter-on-role-file', '<role>.md takes no frontmatter; remove it, or move the rules to a lane file <role>.<lane>.md'],
  ['frontmatter-needs-lane', 'a file with frontmatter needs a lane: add lane: <name> to a <role>.<name>.md file, or remove the frontmatter'],
  ['frontmatter-unknown-key', 'the allowed keys are lane, persona, hint and paths'],
  ['frontmatter-forbidden-value', 'a value may not start with & * ! | or >; write a plain value'],
  ['frontmatter-empty-value', 'give the key a value or remove the line'],
  ['frontmatter-duplicate-key', 'write each key once'],
  ['frontmatter-unclosed', 'close the frontmatter with a line holding only ---'],
  ['frontmatter-second-delimiter', 'remove the second --- line that follows the closing one'],
  ['frontmatter-too-large', 'keep the frontmatter under 1024 bytes'],
  ['frontmatter-paths-too-many', 'paths takes at most 8 entries'],
  ['frontmatter-paths-entry-too-long', 'a paths entry takes at most 80 characters'],
  ['frontmatter-persona-not-one-token', 'persona is one word, without a space'],
  ['frontmatter-persona-too-long', 'persona takes at most 80 characters'],
  ['frontmatter-persona-duplicate', 'give each lane a persona no other lane uses'],
  ['frontmatter-persona-role-name', 'a persona cannot be mia, sam, nick, morgan or theo'],
  ['frontmatter-hint-too-long', 'hint takes at most 120 characters'],
  ['frontmatter-lane-name', 'lane takes 1 to 24 characters among a-z, 0-9 and -'],
  ['frontmatter-lane-mismatch', 'lane must equal the second segment of the file name, as in sam.ios.md with lane: ios'],
  ['frontmatter-lane-metadata-conflict', 'the files of one role and lane give the same persona, paths and hint, or only one of them sets it'],
  ['bad ref', 'pass --ref origin/<branch>, a branch that exists on origin', /^bad ref: /],
  ['unknown role', 'the roles are Mia, Sam, Nick, Morgan and Theo (agentContext also takes *)', /unknown role/],
]

const HINTS = [
  [/: frontmatter-(paths|syntax) at line \d+$/, PATHS_HINT],
  [/: frontmatter-on-context-file at line 1$/, CONTEXT_FILE_HINT],
  ...REMEDIES.map(([rule, remedy, pattern]) => [pattern || new RegExp(`^(?:.+?: )?${rule}(?: at line \\d+)?$`), `hint: ${rule}: ${remedy}; see docs/consumer-reference.md#${rule}`]),
]

// The refusal messages -> the stderr lines to print after them: one per hint a message matches, in table order.
function hintLines(messages) {
  return HINTS.filter(([pattern]) => messages.some((message) => pattern.test(message))).map(([, text]) => `agent-context: ${text}`)
}

module.exports = { hintLines, HINTED_RULES: REMEDIES.map(([rule]) => rule) }

'use strict'

// Lane rules of scripts/agent-context.cjs, moved out to keep that file under the line limit: which owned file belongs to
// which lane, the display list of the lanes and the persona sentence. Pure functions, no git, no file system.

// Remedy shown once per run next to a frontmatter-on-context-file refusal (agent-context.cjs and the init proposal).
const CONTEXT_FILE_HINT = 'hint: a file listed in agentContext is plain text and takes no frontmatter; keep its rules as a lane file <role>.<lane>.md in the specifics folder with lane: (and paths:) in its frontmatter, or remove the frontmatter from the listed file'

// The names the assembler reads in the folder, one definition for the listing and the warnings: <role>.md or <role>.<seg>[.<subject>].md.
function ownsName(lower, name) {
  return name === `${lower}.md` || new RegExp(`^${lower}\\.[A-Za-z0-9._-]+\\.md$`).test(name)
}

// Warnings that leave the payload and the exit code alone (`<rule>` = the kind). One sentence of remedy each, printed once per file and rule.
const WARNING_REMEDY = {
  'not-on-base-ref': 'The file is not on the base ref, so no role receives it; commit it and merge it into the base branch.',
  'no-role-match': 'The name matches no <role>.md, <role>.<lane>.md or shared.md (lowercase role names), so the file is ignored; rename it, or list it in agentContext.',
  'frontmatter-on-shared-file': 'shared.md takes no frontmatter and its keys are discarded; remove the frontmatter block.',
  'lane-captured-from-other-role': 'The file joins a lane that only another role declares; give it its own lane: frontmatter, or rename it so its second segment is not that lane.',
  'empty-ignored': 'The file holds only comments or blank lines and adds nothing; write the rules in it or delete it.',
}
function warningLines(warnings) {
  const seen = new Set()
  const lines = []
  for (const w of warnings) {
    const key = `${w.kind}\0${w.path}`
    if (!WARNING_REMEDY[w.kind] || typeof w.path !== 'string' || seen.has(key)) continue
    seen.add(key)
    lines.push(`agent-context: warning: ${w.path}: ${w.kind}. ${WARNING_REMEDY[w.kind]}`)
  }
  return lines
}

// Files of the folder the assembler does not read, from the ref listing (`children`) and the working tree names:
// -> [{kind, path}], names only, sorted. Dot files and sub-folders are not files of the rules.
function folderWarnings(directory, roles, children, treeNames) {
  const reads = (name) => name === 'shared.md' || roles.some((r) => ownsName(r.toLowerCase(), name))
  const onRef = new Set(children.map((c) => c.name))
  const out = []
  for (const c of children) if (c.type !== 'tree' && !c.name.startsWith('.') && !reads(c.name)) out.push({ kind: 'no-role-match', path: `${directory}/${c.name}` })
  for (const name of treeNames) if (!onRef.has(name) && reads(name)) out.push({ kind: 'not-on-base-ref', path: `${directory}/${name}` })
  return out.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))
}

// Which owned file belongs to which lane, and the metadata of each (role, lane) pair. Refusals are returned as `errors` (the caller exits 2 on any),
// one `<path>: <rule> at line 1` each, never the value. Returns {laneOf: Map(path -> lane), meta: Map("Role:lane" -> md), captured, errors};
// captured = the files that join a lane declared only by another role.
function classifyLanes(roles, done, seqs, owned, directory) {
  const errs = []
  const ownedAll = new Set()
  const reported = new Set()
  const segOf = (role, p) => {
    const name = p.slice(directory.length + 1)
    const lower = role.toLowerCase()
    if (name === `${lower}.md`) return null
    return name.slice(lower.length + 1).split('.')[0]
  }
  const declared = new Map() // lane -> the roles that declare it
  for (const role of roles) for (const p of owned[role]) ownedAll.add(p)
  for (const role of roles) {
    for (const p of owned[role]) {
      const d = done.get(p)
      if (!d || !d.meta) continue
      const seg = segOf(role, p)
      if (seg === null) { errs.push(`${p}: frontmatter-on-role-file at line 1`); continue }
      if (d.meta.lane !== undefined) {
        if (d.meta.lane !== seg) errs.push(`${p}: frontmatter-lane-mismatch at line 1`)
        else declared.set(seg, (declared.get(seg) || new Set()).add(role))
      }
    }
    for (const p of seqs[role]) {
      if (ownedAll.has(p)) continue
      const d = done.get(p)
      if (d && d.meta && !reported.has(p)) { reported.add(p); errs.push(`${p}: frontmatter-on-context-file at line 1`) }
    }
  }
  const laneOf = new Map()
  const captured = []
  const pairs = new Map() // "Role:lane" -> [path]
  for (const role of roles) {
    for (const p of owned[role]) {
      const seg = segOf(role, p)
      if (seg === null) continue
      const d = done.get(p)
      if (!d) continue
      if (!declared.has(seg)) {
        if (d.meta) errs.push(`${p}: frontmatter-needs-lane at line 1`)
        continue
      }
      laneOf.set(p, seg)
      if (!declared.get(seg).has(role)) captured.push(p)
      const k = `${role}:${seg}`
      if (!pairs.has(k)) pairs.set(k, [])
      pairs.get(k).push(p)
    }
  }
  const meta = new Map()
  const personas = new Map()
  const roleNames = roles.map((r) => r.toLowerCase())
  for (const [k, paths] of pairs) {
    const md = {}
    const first = done.get(paths[0]).meta || {}
    for (const f of ['persona', 'paths', 'hint']) {
      if (first[f] !== undefined) md[f] = first[f]
      for (let index = 1; index < paths.length; index++) {
        const m = done.get(paths[index]).meta
        if (!m || m[f] === undefined) continue
        if (first[f] === undefined || JSON.stringify(first[f]) !== JSON.stringify(m[f])) errs.push(`${paths[index]}: frontmatter-lane-metadata-conflict at line 1`)
      }
    }
    meta.set(k, md)
    if (md.persona !== undefined) {
      const low = md.persona.toLowerCase()
      if (roleNames.includes(low)) errs.push(`${paths[0]}: frontmatter-persona-role-name at line 1`)
      else if (personas.has(low)) errs.push(`${paths[0]}: frontmatter-persona-duplicate at line 1`)
      else personas.set(low, k)
    }
  }
  return { laneOf, meta, captured, errors: errs }
}

// Display list, derived from the role blocks: one entry per lane name, the metadata of the first role
// (Sam, Nick, Morgan, Theo, Mia) that declares it.
function displayLanes(roles) {
  const order = ['Sam', 'Nick', 'Morgan', 'Theo', 'Mia']
  const byName = new Map()
  for (const r of order) {
    if (!roles[r]) continue
    for (const l of roles[r].lanes) {
      if (!byName.has(l.name)) byName.set(l.name, { name: l.name, roles: [] })
      const entry = byName.get(l.name)
      entry.roles.push(r)
      for (const f of ['persona', 'paths', 'hint']) if (entry[f] === undefined && l[f] !== undefined) entry[f] = l[f]
    }
  }
  return [...byName.values()].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
}

// `In this lane you act as <persona>[, <hint>].`, '' without a persona. Same text as the workflow copy.
function laneSentence(persona, hint) {
  if (typeof persona !== 'string' || persona === '') return ''
  return typeof hint === 'string' && hint !== '' ? `In this lane you act as ${persona}, ${hint}.` : `In this lane you act as ${persona}.`
}

module.exports = { CONTEXT_FILE_HINT, ownsName, warningLines, folderWarnings, classifyLanes, displayLanes, laneSentence }

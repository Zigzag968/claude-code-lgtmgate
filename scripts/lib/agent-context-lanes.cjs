'use strict'

// Lane rules of scripts/agent-context.cjs, moved out to keep that file under the line limit: which owned file belongs to
// which lane, the display list of the lanes and the persona sentence. Pure functions, no git, no file system.

// Which owned file belongs to which lane, and the metadata of each (role, lane) pair. Refusals are returned as `errors` (the caller exits 2 on any),
// one `<path>: <rule> at line 1` each, never the value. Returns {laneOf: Map(path -> lane), meta: Map("Role:lane" -> md), errors}.
function classifyLanes(roles, done, seqs, owned, directory) {
  const errs = []
  const ownedAll = new Set()
  const segOf = (role, p) => {
    const name = p.slice(directory.length + 1)
    const lower = role.toLowerCase()
    if (name === `${lower}.md`) return null
    return name.slice(lower.length + 1).split('.')[0]
  }
  const declared = new Set()
  for (const role of roles) for (const p of owned[role]) ownedAll.add(p)
  for (const role of roles) {
    for (const p of owned[role]) {
      const d = done.get(p)
      if (!d || !d.meta) continue
      const seg = segOf(role, p)
      if (seg === null) { errs.push(`${p}: frontmatter-on-role-file at line 1`); continue }
      if (d.meta.lane !== undefined) {
        if (d.meta.lane !== seg) errs.push(`${p}: frontmatter-lane-mismatch at line 1`)
        else declared.add(seg)
      }
    }
    for (const p of seqs[role]) {
      if (ownedAll.has(p)) continue
      const d = done.get(p)
      if (d && d.meta) errs.push(`${p}: frontmatter-on-context-file at line 1`)
    }
  }
  const laneOf = new Map()
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
  return { laneOf, meta, errors: errs }
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

module.exports = { classifyLanes, displayLanes, laneSentence }

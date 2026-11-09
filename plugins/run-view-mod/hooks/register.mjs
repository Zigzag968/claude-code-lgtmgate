// Throwaway read-only run-view mod (issue #587). Observes only: every hook passes its event on unchanged.
// Measures which sources fire for workflow agents: agent.spawn, turn.complete, the Workflow tool result.
const FIELDS = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"];

async function persist($, doc) {
  const key = `usage-${doc.runId ?? "unknown"}`;
  try {
    await $.fs.write(`state/${key}.json`, JSON.stringify(doc, null, 2));
  } catch {
    await $.store.set(key, doc);
  }
}

export function register(on) {
  let runId;
  let spawnSeen = false;
  const labels = []; // descriptions seen on agent.spawn, consumed in first-seen order
  const agents = {}; // agentId -> {label, index, <4 token fields>}

  const total = (a) => FIELDS.reduce((s, f) => s + (a[f] ?? 0), 0);

  on("agent.spawn", async ($, e, next) => {
    spawnSeen = true;
    if (!e.resume && e.description) labels.push(e.description);
    return next(e).catch(() => {});
  });

  on("session.append", { door: "tool-result" }, async ($, e, next) => {
    try {
      const text = JSON.stringify(e.message?.content ?? "");
      if (text.includes("transcriptDir") || text.includes("async_launched")) {
        const m = /runId\\?["']?\s*[:=]\s*\\?["']?([A-Za-z0-9_-]+)/.exec(text);
        if (m) runId = m[1];
      }
    } catch {
      // observation only
    }
    return next(e).catch(() => {});
  });

  on("turn.complete", async ($, e, next) => {
    try {
      if (e.agentId && e.usage) {
        let a = agents[e.agentId];
        if (!a) {
          const index = Object.keys(agents).length + 1;
          a = { label: labels.shift() ?? e.agentId, index };
          for (const f of FIELDS) a[f] = 0;
          agents[e.agentId] = a;
        }
        for (const f of FIELDS) a[f] += e.usage[f] ?? 0;
        const m = Object.keys(agents).length;
        const sum = Object.values(agents).reduce((s, x) => s + total(x), 0);
        $.ui.status(`run ${runId ?? "?"} - ${a.label} ${a.index}/${m} - ${sum} tok`);
        await persist($, { runId, spawnSeen, agents });
      }
    } catch {
      // observation only
    }
    return next(e);
  });
}

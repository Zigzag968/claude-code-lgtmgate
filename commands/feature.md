---
description: Deliver a feature end-to-end through the Mia -> Sam -> Nick -> Morgan pipeline (creates the shared worktree, drives feature-pipeline.js).
argument-hint: "[issue] [brief]"
allowed-tools: Bash, Read, Workflow, TaskCreate, TaskUpdate, TaskGet, TaskList, AskUserQuestion, SendMessage, TeamCreate, Agent
---

# /lgtmgate:feature — Runbook (Lead)

Tu es le **Lead**. Tu livres une feature de bout en bout via le pipeline **Mia -> Sam -> Nick -> Morgan**. Le workflow (composant plugin `lgtmgate:feature-pipeline`, ou la copie locale `.claude/workflows/feature-pipeline.js` en fallback — resolution exacte en section "## 1. Lire la config" ci-dessous) orchestre les agents ; toi tu prepares le worktree partage, tu lances le workflow, et tu traites les statuts qu'il te rend.

**Args** : `$ARGUMENTS` = `<issue> "<brief>"` (numero d'issue GitHub + description courte). Si l'un manque, demande-le.

**Bash : path absolu, 1 commande/call, pas de `cd`/`&&`/`|`.**

## 1. Lire la config
- Lis `.claude/pipeline.config.json` (racine projet). Absent → stop : `Pipeline non configure. Lancer /lgtmgate:init d'abord.`
- Garde l'objet JSON en memoire : tu le passes tel quel au workflow (`config`).
- Resous le pipeline a lancer (deux branches, jamais un nom nu) :
  - Le plugin `lgtmgate` (>=0.8.0) fournit le composant workflow **namespaced**
    `lgtmgate:feature-pipeline` (repertoire `workflows/` du plugin, resolution
    par defaut). Si ce plugin est installe a jour, c'est la cible.
  - Sinon (projet pas-encore-migre, ou plugin anterieur a 0.8.0 sans le composant) et
    que `.claude/workflows/feature-pipeline.js` existe encore dans CE projet, retiens
    cette copie locale explicite — le projet garde alors aussi sa propre suite copiee
    (`.claude/workflows/test-feature-pipeline.js`), donc c'est bien SA copie qu'il faut
    executer, jamais le composant du plugin.
  - Ni l'un ni l'autre -> stop : `Pipeline introuvable. Lancer /lgtmgate:init d'abord.`

## 2. Verifier le worktreeRoot
- Resous le worktreeRoot AVANT de verifier (legacy#61 — precedence, workflow sandbox sans filesystem donc c'est TOI qui lis) : `$AGENT_PIPELINE_WORKTREE_ROOT` (env) > `.claude/pipeline.config.local.json:worktreeRoot` (si ce fichier existe — absent = cas normal, ne pas traiter comme une erreur) > `config.worktreeRoot` (defaut versionne).
- Le worktreeRoot RESOLU doit etre monte/accessible. Verifie (ex `test -d "<worktreeRoot resolu>"` ou que le volume parent est monte). Inaccessible → stop et signale a l'utilisateur (ex SSD externe non monte).

## 3. Creer le worktree partage (gele depuis la base branch)
- `git fetch origin` puis assure-toi que la base branch (`config.baseBranch`) est a jour.
- Slug : **`issue-<N>`** (fige). Nick committe sur la branche du worktree (il ne la recalcule plus) — garder un nom previsible et aligne sur le suivi GH. (friction F2)
- `WT="<worktreeRoot>/<slug>"` ; branche `<config.branchPrefix><slug>`.
- Cree-le (1 commande) :
  ```bash
  git worktree add "<WT>" -b <branchPrefix><slug> <baseBranch>
  ```
- Verifie `git worktree list` < 60s apres (mitigation anthropics/claude-code#39886). Echec → corrige avant de lancer le workflow.
- **Base alternative** (feature empilee sur une branche non encore mergee, ou dogfood) : override `config.baseBranch` vers cette branche POUR CE RUN (dans l'objet config passe au workflow) ET cree le worktree depuis elle. Worktree + PR target + regression guard pointent alors vers la bonne base. Verifie qu'elle declenche le CI (`on.pull_request.branches`) ; sinon `ciChecks: []` (Morgan valide sur le green bar local). (friction F3)

## 4. Lancer le workflow
Memes `args` dans les deux cas — seule la CIBLE change, selon la resolution de l'etape 1 :
```
args = {
  issue:  <N>,
  brief:  "<brief>",
  wtPath: "<WT>",
  mode:   "semi",
  pmReview: <true si la checkbox pm_review de l'issue est cochee, sinon false>,
  config: <l'objet .claude/pipeline.config.json complet>,
  configLocal: <contenu parse de .claude/pipeline.config.local.json, ou {} si absent — le sandbox du workflow ne lit pas de fichier (legacy#61), donc c'est le Lead qui lit et transmet>,
  planAudit: <optionnel — true pour forcer l'audit adversarial de plan sur CE run ; absent -> config.planAudit>,
  maxAuditRounds: <optionnel — borne de la boucle auditeur <-> scout, defaut 2, PLAFOND DUR a 2 : au-dela, throw sauf si maxAuditRoundsOverrideReason est fourni>,
  maxAuditRoundsOverrideReason: <obligatoire si maxAuditRounds > 2 — nomme la CLASSE DE RISQUE qui justifie le(s) round(s) supplementaire(s), jamais un depassement silencieux>,
  architectureDecisionApproved: <optionnel — atteste que la passe architecture-only (design-step trigger) a deja eu lieu et a ete approuvee, dispense de proceedThrough:"plan" sur ce lancement>
}
```
- **Composant plugin resolu** -> lance par le nom **namespaced** `lgtmgate:feature-pipeline` (jamais le nom nu `feature-pipeline`, qu'un `--plugin-dir` ou un autre projet peut shadower — claude-agent-pipeline#54).
- **Copie locale pas-encore-migree resolue** -> lance explicitement `Workflow({ scriptPath: "<repo>/.claude/workflows/feature-pipeline.js", args })` — jamais par nom, nu ou namespaced : la suite de tests copiee de ce projet valide encore CETTE copie, pas le composant du plugin.
> `mode: "semi"` = checkpoints aux jalons (plan pret, review demandant des changements). `auto` enchaine tout, `manual` s'arrete a chaque etape. Les agents n'ont PAS le tool Workflow — seul le Lead pilote.
> **Iteration machinery** : si tu patches `.claude/workflows/feature-pipeline.js` en cours de session, relance le workflow via `scriptPath: "<abs path>"` (lecture fraiche du disque) et NON `name:` (resolution cachee au 1er usage → rejouerait l'ancienne version). (friction F9)
> **Suite de tests** : la meme staleness joue A L'INTERIEUR du flow suite — `test-feature-pipeline.js` resout lui aussi le pipeline sous test via le registry. Pour valider une branche, passe `args: { fpScriptPath: "<worktree>/.claude/workflows/feature-pipeline.js" }` ; par `name:` la suite teste silencieusement la copie de la branche de base (incident reel observe : deux cas rapportes en echec contre un pipeline qui n'avait tout simplement pas le gate).

## 5. Traiter le statut retourne
Le workflow rend un objet `{ status, ... }`. Selon `status` :

| status | Sens | Action Lead |
|--------|------|-------------|
| `plan-ready` | Sam a poste son plan (GO), checkpoint semi | Resume l'utilisateur (plan + issue). Sur feu vert : relance le workflow `entryStage:"dev"` + `proceedThrough:"dev"` (ou `"review"`). |
| `dev-done` | Nick a ouvert la PR, checkpoint | Resume (PR URL). Sur feu vert : relance `entryStage:"review"` + `prNumber:<PR>`. |
| `needs-revision` | Morgan a demande des changements (`items`) | Resume les bloqueurs. Sur feu vert : relance `entryStage:"review"` + `prNumber` + `proceedThrough:"review"` (Nick corrige, Morgan re-review). |
| `verified-untickable` | Morgan a prouve chaque box mais n'a pas pu les cocher (permissions) ; `untickableItems[]` = `{item, proof}` par box (pas un defaut de code) | Ne dispatche jamais Nick. Re-execute chaque `proof` porte par le payload (rapide), coche a la main (`gh pr edit <pr> --body ...`) uniquement les boxes dont la preuve passe, puis relance `entryStage:"review"` + `prNumber:<pr>` (Morgan ne voit plus de box ouverte, LGTM, `ready`). Un payload `ready-pending-founder` peut aussi porter `untickableItems[]` : meme traitement pour ceux-la ; les boxes `[founder-gate]` restent founder-only, jamais cochees par toi. |
| `no-go` | Sam a bloque (`reason`) | Relaie le bloqueur a l'utilisateur. Ne pas forcer. |
| `escalate` | 3 rounds sans LGTM (`finalVerdict`), ou `reason:"plan-not-sound"`/`"plan-audit-malformed"` (audit de plan, si `planAudit` actif) | Escalade a l'utilisateur : merge en l'etat + suivi, ou continuer. Un escalate `plan-not-sound` porte `auditTrace`/`roundOneAboveTarget`/`blockingSeries` — lis-les AVANT de decider (ne relance jamais `maxAuditRounds` plus haut sans une raison de classe de risque explicite ; c'est un evenement de routing, pas un signal de reboucler). Un escalate `reason:"mergeable-conflicting"` (legacy#170) : verifie l'etat live (`gh pr view <pr> --json mergeable,mergeStateStatus`) ; si tu decides de laisser Nick reconcilier plutot que traiter en l'etat, relance `entryStage:"dev"` + `prNumber:<pr>` + `resumeReason:"mergeable-conflicting"` (lgtmgate#183) — son prompt portera alors explicitement la raison du resume au lieu de le laisser conclure a tort "deja fait". |
| `design-step-required` | Le design-step trigger a declenche (Theo : >=2 de {etat persistant, auth/securite, config de deploiement}, ou une API vendeur immature) et aucune decision d'architecture n'est encore approuvee | Relance soit avec `proceedThrough:"plan"` + un brief scope au one-pager d'architecture seul (s'arrete a `plan-ready` pour ta validation), soit avec `architectureDecisionApproved:true` si cette passe a deja eu lieu. |
| `ready` | LGTM, PR prete a merger | Resume (PR + branch). Voir §6. |
| `diagnose-died` / `plan-died` / `plan-check-died` / `plan-audit-died` / `dev-died` / `preflight-died` | Un agent est mort (erreur ou reponse vide) sur cette etape apres retry ; `resumable:true` | Diagnostique la cause si possible, puis relance le workflow avec le **meme `config`/`wtPath`** via `resumeFromRunId` (voir §Supervision) — ne jamais relancer a l'identique en boucle sans comprendre pourquoi. |
| `preflight-stuck` | 2 echecs de preflight, run escalade | Verifie d'abord si l'exigence en echec est litteralement ce que le diff de la PR change (`self-reference-preflight`, issue legacy#83) ; si oui c'est un faux-positif connu — verifie l'etat de la branche a la main et ne demande PAS a Nick de satisfaire le check perime. Pour relancer contre la logique de gate courante de la branche, lance un run **NEUF** via `Workflow({ scriptPath: "<worktree>/workflows/feature-pipeline.js", ... })` (lecture fraiche du disque), **jamais** un simple `resumeFromRunId` (il rejoue les inputs caches du run original). |

Relance toujours le workflow avec le **meme `config` et `wtPath`**. Ne re-spawn jamais une etape deja terminee sans `entryStage`.

### Supervision des runs en vol
Avant de considerer le tour termine (checkpoint semi, reprise apres pause, ou avant d'en lancer un
nouveau) : si un run persiste comme non-termine (`.pipeline/<issue>.json`, statut ni
`ready`/`no-go`/`escalate` resolu), fais le tour de garde plutot que de l'abandonner en silence —
- **Vivant** (task en cours, progresse) -> ne pas toucher.
- **Mort ou `review-died`/`resumable`** -> reprendre via `resumeFromRunId` + args persistes, **borne**
  (2-3 essais differents max, jamais la meme relance a l'identique, jamais de boucle).
- **Silencieux au-dela du seuil configure** (`pipeline.config.json` -> `supervision.staleMinutes`,
  defaut 30 min ; le hook `Stop` de garde le detecte automatiquement et re-prompte) -> marquer bloque
  et escalader a l'utilisateur, ne jamais le laisser en l'etat.

## 6. Sur `ready` — cleanup worktree (apres ordre utilisateur)
- La PR est prete (LGTM, acceptance checklist cochee). **Ne merge pas de ta propre initiative.**
- **Ne supprime le worktree qu'apres ordre explicite de l'utilisateur** (un travail non commite pourrait y vivre). Le hook SubagentStop ne fait qu'avertir, jamais supprimer.
- Sur ordre :
  ```bash
  git worktree remove "<WT>"
  ```

## Reporting
Statut court a l'utilisateur a chaque jalon (plan-ready / dev-done / needs-revision / verified-untickable / ready / no-go / escalate) : ce qui s'est passe + la prochaine decision. Bullets, pas de prose.

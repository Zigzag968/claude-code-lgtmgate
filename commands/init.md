---
description: Bootstrap the lgtmgate in this project — copy templates, generate pipeline.config.json, wire GH + settings.
argument-hint: ""
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# /lgtmgate:init — Runbook (Lead)

Tu es le **Lead**. Tu installes le pipeline `lgtmgate` dans le projet courant. But : un `.claude/` pret a l'emploi et un `.claude/pipeline.config.json` valide, sans rien hardcoder de specifique a la stack dans le plugin.

Travaille depuis la racine du projet (`${CLAUDE_PROJECT_DIR}`). Le plugin est sous `${CLAUDE_PLUGIN_ROOT}`. **Bash : path absolu, 1 commande/call, pas de `cd`/`&&`/`|`.**

## 0. Pre-check
- `command -v gh` — confirme que le CLI `gh` est installe. Absent -> stop, demande d'installer https://cli.github.com/.
- `gh auth status` — confirme l'authentification et les scopes. Non authentifie / scopes insuffisants -> stop, demande `gh auth login --scopes "repo,project"`.
- `command -v jq` — confirme que le CLI `jq` est installe (requis par hooks/block-merge-unchecked.sh et hooks/deny-destructive-git.sh, qui echouent fermes sans lui). Absent -> stop, demande d'installer https://jqlang.github.io/jq/.
- `git rev-parse --show-toplevel` — confirme qu'on est dans un repo git. Sinon, stop et demande.
- Si `.claude/pipeline.config.json` existe deja → **AskUserQuestion 3 voies** : (a) **completer** — reposer uniquement les artefacts machinery manquants (workflows/rules/scripts), valider la config existante vs le schema du template, **sans l'ecraser** (defaut recommande si la config est valide) ; (b) **re-init** — tout regenerer, ecrase la config ; (c) **abort**. (friction F1)
  - Note (legacy#73) : `completer` ne rafraichit JAMAIS un fichier deja present (ex. `.claude/rules/pr-acceptance.md`) meme si `templates/pr-acceptance.md` a ete durci depuis le provisioning initial. Apres tout `claude plugin update lgtmgate`, diff manuellement le fichier consommateur contre `${CLAUDE_PLUGIN_ROOT}/templates/pr-acceptance.md` (`diff .claude/rules/pr-acceptance.md ${CLAUDE_PLUGIN_ROOT}/templates/pr-acceptance.md`) et propage les sections durcies — ne suppose jamais que le fichier consommateur suit le canonique automatiquement.

## 1. Copier les templates
Cree les dossiers cibles s'ils manquent (`.claude/workflows`, `.claude/rules`, `.claude/scripts`, **`scripts`** — a la racine du repo, pas sous `.claude/`), puis copie :

- `${CLAUDE_PLUGIN_ROOT}/templates/test-feature-pipeline.js` → `.claude/workflows/test-feature-pipeline.js`
- `${CLAUDE_PLUGIN_ROOT}/templates/pr-acceptance.md`         → `.claude/rules/pr-acceptance.md`
- `${CLAUDE_PLUGIN_ROOT}/templates/gh-pipeline-status.sh`    → `.claude/scripts/gh-pipeline-status.sh`
- `${CLAUDE_PLUGIN_ROOT}/templates/blocked-by-check.sh`      → `.claude/scripts/blocked-by-check.sh`
- `${CLAUDE_PLUGIN_ROOT}/templates/provision_worktree.sh`    → `scripts/provision_worktree.sh`

Puis : `chmod +x .claude/scripts/gh-pipeline-status.sh`, `chmod +x .claude/scripts/blocked-by-check.sh` et `chmod +x scripts/provision_worktree.sh`.

`blocked-by-check.sh` n'est pas fail-closed comme `provision_worktree.sh` — un projet sans dependance cross-repo fonctionne sans, cette copie n'est qu'un slot d'installation optionnel.

Le stage 1 du pipeline (provisioning) est **fail-closed** sur `scripts/provision_worktree.sh` — cette copie n'est pas optionnelle : sans elle, le premier run `exit 127`e.

(1 commande `cp` par fichier — pas de compound.)

**Commit + push AVANT le premier run (obligatoire — MANDATORY, claude-agent-pipeline#51).** Le gate de provisioning execute `bash "<worktree>/scripts/provision_worktree.sh"` **depuis le WORKTREE**, c-a-d le contenu **COMMIT** sur `baseBranch` — pas le working tree du checkout principal ou `init` vient d'ecrire. `git worktree add` clone toujours depuis un ref committe : tant que ces fichiers ne sont pas commit + push sur `baseBranch`, un worktree fraichement cree n'a PAS `scripts/provision_worktree.sh`, le gate `exit 127`e, et le pipeline escalade `provision-failed` des la premiere tache — exactement la panne que ce gate est cense empecher. Avant le premier `/lgtmgate:feature` :
```bash
git add scripts/provision_worktree.sh .claude/workflows .claude/rules .claude/scripts .claude/pipeline.config.json
```
```bash
git commit -m "chore(pipeline): bootstrap lgtmgate machinery"
```
```bash
git push origin <baseBranch>
```
(1 commande par call, pas de compound — meme regle que le reste de ce runbook.)

## 2. Generer `.claude/pipeline.config.json`
Lis le gabarit `${CLAUDE_PLUGIN_ROOT}/templates/pipeline.config.template.json`. Detecte ce que tu peux, demande le reste via **AskUserQuestion** (options lettrees + tradeoff), puis ecris le JSON final avec le tool Write.

### Introspection du repo (faire AVANT de renseigner — friction F13)
Le plugin doit s'integrer au git-flow REEL du repo, pas hardcoder des defauts. Detecte :
- **Branche par defaut** : `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`. Si une branche `develop` existe (`git show-ref --verify --quiet refs/remotes/origin/develop`), git-flow probable → proposer `develop` comme `baseBranch`, sinon la branche par defaut.
- **Prefixe de branche dominant** : `git branch -r | sed -E 's#^ *origin/##' | grep / | cut -d/ -f1 | sort | uniq -c | sort -rn` → prends le prefixe le plus frequent (ex `feature` → `branchPrefix: "feature/"`). **Ne PAS hardcoder `features/`.** Si une rule `.claude/rules/git-workflow.md` existe, ses conventions priment.
- **Filtres de base CI** : pour chaque `.github/workflows/*.yml`, lis `on.pull_request.branches`. **Si `baseBranch` n'y figure pas, AVERTIS** : « les PR vers `<baseBranch>` ne declencheront pas le CI `<workflow>` → soit cibler une base couverte, soit laisser `ciChecks: []` (Morgan validera sur le green bar local) ». Renseigne `ciChecks` avec les job names des workflows qui SE declenchent sur la base retenue.

Champs a renseigner :
- **commands** : `build`, `test`, `format` — la commande exacte de la stack (ex Node : `npm run build` / `npm test` / `npx prettier -w`). Detecte via les manifestes presents (`package.json`, `Cargo.toml`, `*.xcworkspace`, `pyproject.toml`, `Makefile`). Si ambigu → demande.
- **conventionsRule** : chemin de la rule de conventions du projet (defaut `.claude/rules/conventions.md`). Si absente, propose d'en creer un squelette.
- **baseBranch** / **branchPrefix** : issus de l'introspection ci-dessus (branche par defaut + prefixe dominant). Confirme via AskUserQuestion si ambigu. **Ne hardcode jamais `features/`.**
- **worktreeRoot** : racine ou les worktrees partages seront crees (ex `/Users/you/Worktrees/<repo>` ou `../worktrees/<repo>`). Demande si pas evident. **Valeur versionnee = defaut LOGIQUE seulement** (legacy#61) : une racine specifique a la machine va dans `$AGENT_PIPELINE_WORKTREE_ROOT` (env) ou dans `.claude/pipeline.config.local.json` (gitignore, precedence `env > local > versionne`) — ajoute ce chemin au `.gitignore` du projet consommateur.
- **ciChecks** : job names requis verts avant LGTM (ex `["build-and-test"]`), issus des workflows qui se declenchent sur `baseBranch` (cf introspection). Si la base retenue n'est couverte par aucun workflow → **`ciChecks: []`** (Morgan valide sur le green bar local, sans bloquer sur un CI absent).
- **regressionGuard** : `testGlob` (ex `*Tests.swift`, `*.test.ts`, `test_*.py`) + `testFnPattern` (ex `func test`, `it(`, `def test_`).
- **ghProject** : `number`, `id`, le field "Pipeline Status" (`fieldId`) + `statusOptions` (map nom→optionId). Voir §5 si le field n'existe pas. Si le projet n'utilise pas de GH Project, laisse `ghProject` vide — le workflow degrade proprement (skip updateStatus).
- **planAudit** : audit adversarial de solidite du plan avant Dev, defaut `false`. A activer explicitement si le projet veut ce gate (couts : `maxAuditRounds × maxPlanAttempts` spawns opus supplementaires au pire cas).
- **stack** : chaine libre decrivant la stack cible, transmise a l'auditeur de plan (ex `Django 5 / Python 3.12`). Vide → l'auditeur l'infere du worktree.
- **commitHygiene** / **commentHygiene** : cles optionnelles, deliberement absentes de `pipeline.config.template.json` (pas de generation automatique — a activer en connaissance de cause). `commitHygiene: { squashBeforeHandoff, maxCommits }` ne paie que sur un repo dont la base merge avec des merge-commits (sinon un merge squash fait deja le travail gratuitement). `commentHygiene: true` collapse l'historique des rounds de review dans les commentaires PR — le compositeur decision-log a atterri dans cette copie (0.8.2) et preserve cet historique dans le corps de la PR, donc l'activation reste une decision consciente mais n'est plus bloquee par une absence de mecanisme de remplacement.

Valide le JSON ecrit : `python3 -c "import json; json.load(open('.claude/pipeline.config.json'))"`.

## 3. Snippets GitHub (optionnel, proposer)
Propose (AskUserQuestion) d'inserer les snippets pour activer pm_review + le gate d'acceptance :
- `${CLAUDE_PLUGIN_ROOT}/templates/github/feature-pm_review.snippet` → bloc `checkboxes pm_review` a ajouter dans `.github/ISSUE_TEMPLATE/feature.yml`.
- `${CLAUDE_PLUGIN_ROOT}/templates/github/pr-acceptance.snippet` → section `## Acceptance checklist` (avec marqueurs `<!-- acceptance:start/end -->`) a ajouter dans `.github/pull_request_template.md`.

Si les fichiers cibles existent : insere le bloc au bon endroit (Edit). Sinon : propose de creer le fichier a partir du snippet. **Ne jamais ecraser** un template existant sans confirmation.

## 4. Settings (rappel)
Rappelle a l'utilisateur d'activer le plugin dans `.claude/settings.json` (ou le settings global) :
- `extraKnownMarketplaces` → ajouter la marketplace `zigzag-plugins` (`github` / `Zigzag968/lgtmgate`).
- `enabledPlugins` → ajouter `"lgtmgate@zigzag-plugins"`.

Propose de le faire pour eux (Edit du settings) apres confirmation ; sinon affiche le diff a coller.

## 5. (Optionnel) Creer le field GH "Pipeline Status"
Si le projet utilise un GH Project mais n'a pas le field, propose de le creer :
```bash
gh project field-create <number> --owner <owner> --name "Pipeline Status" --data-type SINGLE_SELECT --single-select-options "Planning,Dev,Review,Ready,Blocked"
```
Puis recupere les `optionId` (via `gh project field-list ... --format json`) et renseigne `ghProject.statusOptions` dans la config.

## 6. Resume final
Affiche : fichiers copies, chemin de la config, checks CI retenus, et la prochaine action (`/lgtmgate:feature <issue> "<brief>"`). Si un template source manque sous `${CLAUDE_PLUGIN_ROOT}/templates/`, signale-le clairement (ne fais pas semblant d'avoir copie).

## La checklist d'acceptance d'une PR est un gate vivant

> Regle dure. La checklist d'acceptance d'une PR (sa section **Acceptance checklist**) est un **gate executable**, pas
> de la decoration. Une case cochee est une affirmation de verification ; une case non cochee ou
> perimee bloque le merge.

### Qui l'ecrit — Sam
Sam redige la checklist dans son plan (poste sur l'issue). Chaque item DOIT etre :
- **Pertinent** — un critere d'acceptance qui compte vraiment pour ce que la PR livre.
- **Verifiable par Morgan** — une commande concrete que Morgan peut lancer, ou un artefact qu'il
  peut inspecter. Jamais un item que Morgan ne peut pas verifier (pas de "looks good", pas d'etape
  manuelle hors de sa portee).

Chaque item est une ligne `- [ ]`. Nick copie la checklist **verbatim** dans le body de la PR a
l'ouverture, **entre les marqueurs** `<!-- acceptance:start -->` et `<!-- acceptance:end -->`.

### Qui prouve & coche — Morgan
Morgan execute / inspecte chaque item, puis :
- Coche la case `- [x]` dans le body de la PR (`gh pr edit <N> --body ...`) **uniquement** apres
  avoir vu la preuve.
- Cite cette preuve (commande + sortie, ou l'artefact) dans son commentaire de review.
- Ne rend **LGTM que lorsque toutes les cases sont cochees.** Une seule `- [ ]` restante, ou une
  case qui contredit le diff, = **REQUIRED_CHANGES** — jamais LGTM.
- Si le tick est refuse par les permissions de session alors que la preuve passe : ne coche pas, ne poste jamais « Ready to merge », cite la preuve et classe la box `proven-untickable`. Le workflow rend `verified-untickable` (aucun round Nick) ; le Lead re-verifie la preuve et coche a la main. Une box `[founder-gate]` n'est jamais cochee par ce chemin.

### Marqueurs (obligatoires)
Le bloc d'acceptance vit entre deux marqueurs HTML dans le body :

```
<!-- acceptance:start -->
- [ ] <critere verifiable>
- [ ] <critere verifiable>
<!-- acceptance:end -->
```

Le hook (ci-dessous) n'inspecte **que** les `- [ ]` situees entre ces deux marqueurs. Les autres
checkboxes du template (section remoteconfig) sont hors-scope et ne bloquent jamais le merge.

### Ordre du body (artifact-first)
Le body de la PR suit un ordre fixe, artifact-first : `Closes #N` en premiere ligne ->
`## What this ships` (bullet summary du diff) -> optionnel `## <Founder> — N gestures`
(UNIQUEMENT si un item `[founder-gate]` existe dans la checklist, sinon omettre le H2 — jamais
de section stub vide) -> `## Acceptance checklist` (le bloc entre les marqueurs
`<!-- acceptance:start -->`/`<!-- acceptance:end -->`) -> paire VIDE
`<!-- decision-log:start -->`/`<!-- decision-log:end -->` (workflow-owned, jamais remplie a la
main) -> fold `<details><summary>Technical detail</summary>` (test plan / feature flag / risk).
Cet ordre est celui que l'invariant `pr-body-structure` (`templates/test-canonical-guards.sh`)
verifie mecaniquement sur le prompt Dev-phase de Nick et sur `agents/nick.md`.

### Pivots de scope
Si le scope change en cours de PR, la checklist est mise a jour dans la **meme PR** (Sam l'amende ;
Nick synchronise le body). Une checklist qui contredit le diff bloque le merge — un critere perime
est un defaut, pas un detail.

### Enforcement
- **Morgan est le gate principal** (ci-dessus) — pas de LGTM avec une case ouverte ou non prouvee.
- Un hook `PreToolUse` (`.claude/hooks/block-merge-unchecked.sh`) refuse `gh pr merge` tant que le
  bloc d'acceptance du body contient une `- [ ]`. **Limitation connue** (comme le hook `pre-push`) :
  il n'intercepte que les merges `gh` dans une session hookee — un merge via l'UI GitHub n'est pas
  capte, donc le gate de Morgan reste le vrai controle.

## Autonomie en session non supervisee (regle dure)

> S'applique a toute session pipeline sans humain present pour repondre a un prompt (runner
> planifie, session longue non surveillee, etc.) — Sam, Nick, Morgan, Mia, Theo y sont soumis au meme
> titre.

- **Suppressions** : `git rm <fichier>` pour tout fichier tracke, jamais `rm`/`rm -rf` nu. Fichiers
  temporaires non tracke -> scratchpad de session ou `$TMPDIR`, jamais suppression en place.
- **Renommages** : `git mv <src> <dst>`, jamais `mv` nu sur un fichier tracke.
- **Zero commande interactive** : jamais de prompt shell (pas de `-i`, pas d'edition interactive,
  pas de pager bloquant) — tout doit tourner en mode non-interactif de bout en bout.
- **Zero sudo, zero install global** : aucune elevation de privileges, aucun `npm install -g` /
  `pip install --user` / `brew install` hors du `.venv`/`node_modules` du projet.
- **Rester dans le worktree** : toute lecture/ecriture reste sous le worktree assigne a l'issue
  (`$WT_PATH`) ; jamais de traversee vers un autre worktree, un autre repo, ou hors de l'arborescence
  assignee.
- **Une commande refusee/bloquee : se debrouiller d'abord, borne** — tenter une alternative dans la
  surface autorisee (ex. `rm` refuse -> `git rm` ; outil manquant -> equivalent deja disponible).
  Maximum **2-3 approches DIFFERENTES** par blocage ; ne JAMAIS relancer la commande identique en
  esperant un resultat different ; jamais de boucle sur le meme obstacle. Alternatives epuisees ->
  statut d'echec explicite — un orchestrateur externe le traduit en `no-go`/`escalate`/erreur puis en
  label de blocage pour traitement humain (voir aussi le hook `Stop` de garde des runs en vol, qui
  detecte un run non-terminal reste silencieux au-dela d'un seuil configurable).
- **Echec TLS/certificat sur un install de deps sous sandbox** (`OSStatus -26276`,
  `problem confirming the ssl certificate`, `tls: failed to verify certificate`, `x509`) est une
  **limitation d'outillage connue**, pas un environnement casse : jamais de contournement du sandbox
  pour autant — statut d'echec explicite, blocage reporte au Lead/fondateur. Jamais de `sudo` ni
  d'install global ; rester dans le `.venv`/`node_modules` du projet.
- **Interdits stricts, meme en tentative d'alternative** : commande interactive, `sudo`, install
  globale, contournement d'un guard (hook, assert de merge), desactivation ou bypass du sandbox
  d'outillage. Ces limites ne sont jamais une des 2-3 approches — elles font echouer le blocage
  immediatement.
- **Jamais de push hors branche de feature vers la base branch** : le merge est un geste externe au
  pipeline (script de merge dedie), jamais un `gh pr merge` direct par un agent.

## Articulation avec `code-review-impartial.md`

Les deux regles se completent, **zero doublon** :

| Regle | Nature | Ce qu'elle garantit |
|-------|--------|---------------------|
| **pr-acceptance** (cette regle) | Gate **mecanique** | Les criteres sont cases + prouves, enforced par le hook. Objectif binaire : toutes les cases cochees avec preuve, sinon merge refuse. |
| **code-review-impartial** | Process **humain** | Le reviewer est **impartial** (distinct des fixers Sam/Nick), re-review apres chaque update substantielle. Objectif : jugement du code a froid, sans biais de complaisance. |

**Morgan applique les deux** : il coche les cases d'acceptance (gate mecanique) ET conduit la review
impartiale (jugement qualitatif du diff). Une PR ne merge que si les deux convergent — checklist
entierement prouvee ET reviewer OUI sans reserve bloquante (ou <Founder> tranche).

## Pourquoi
Une checklist que personne n'execute ou ne maintient est un *faux signal de verification*. Cette
regle force chaque case a etre soit prouvee-et-cochee, soit retiree — jamais decorative.

## Faux-positif d'auto-reference (`self-reference-preflight`, legacy#83)

> Classe de PR : le diff modifie la surface de preflight/generation-de-gate du pipeline
> lui-meme (`workflows/feature-pipeline.js`, le prompt de preflight, ou un script de support
> preflight d'un projet). Une PR de cette classe peut faire echouer a tort le HARD-check
> qu'elle corrige elle-meme.

- **Mecanisme** — le `Workflow()` en cours execute le snapshot du script lu au moment du
  DISPATCH ; il note donc une branche POST-PR avec une logique de gate PRE-PR.
- **Regle** — quand l'exigence enoncee par un echec de HARD-check est litteralement ce que le
  diff supprime/change ET que l'etat du worktree correspond a l'etat post-merge vise par la PR
  (verifie independamment, jamais en relancant le check perime), c'est un faux-positif connu ->
  escalader au Lead, jamais muter le worktree pour satisfaire le check.
- **Consequence sur l'acceptance** — pour cette classe de PR, chaque item de la checklist doit
  etre verifiable **offline contre les fichiers de la branche** (grep/diff/scripts lances sur la
  branche), jamais "le preflight live passe".

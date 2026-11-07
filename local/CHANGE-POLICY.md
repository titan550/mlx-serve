# Change policy for the mlx-serve fork

**Hard rules:**
1. Put every change at the **lowest level that works** (machine → config → extension point → build
   flag → small patch → divergent feature). Config beats code; code is the last resort.
2. Every change to an upstream file is a **ledger entry** in [`PATCHES.md`](PATCHES.md).
3. Follow upstream **releases** only (a `v*` tag); **never push to `origin`** (its push URL is `DISABLED`).
4. `fork-main` carries **no commits of its own**: it is the release tag plus merges of the fork's branches.
5. Build with [`local/build.sh`](build.sh), never a bare `app/build.sh`: the build names itself after the tree
   and stages its own plugin kit.

This applies to the owner and to any AI agent working in this repository. Upstream's own rules
(`../AGENTS.md`, each folder's `AGENTS.md`) bind every file you touch.

## 1. What this fork is

Upstream mlx-serve (ddalcu) plus a small delta, kept in one place so adopting a new release stays cheap.
It is **both** a thin private fork and a contribution fork: every change is written upstream-shaped and
offered, but upstream is picky and may decline most of it, so each entry also records what the fork does
when declined. Three invariants:
- **Thin:** changed lines in upstream files stay within the budget in §4; every entry has a reason and an exit
  condition.
- **Upstream-shaped:** a fork change is written as the PR it would be (its tests, its docs line, its
  gotcha), even when it will never be sent. That is what makes a declined change cheap to carry.
- **Recoverable:** the app the owner runs is `app/MLX-Serve.app` from `local/build.sh`; a copy of each
  build worth keeping lives under `~/claude-tmp/*.app` (the ledger names the ones that matter), so a bad build
  is undone by relaunching the previous bundle.

## 2. The ladder

| Level | What changes | Where it lives | Examples in this fork |
|---|---|---|---|
| **L0 Machine** | OS state outside the repo | `iogpu.wired_limit_mb`, keychains | GPU wired limit for the big packs |
| **L1 Config** | Settings the server or app already read | `~/.mlx-serve/{model-settings.json, generation-settings.json, plugins.json, ablation/}`, launch flags, env levers registered in `src/env.zig` | the per-model `ablation` setting instead of a per-request field; a model's `prefix_cache`; `SUSHI_DS41_*` levers |
| **L2 Extension point** | Behaviour through a seam upstream provides | outside plugins (CommunityServe/plugins), skills, providers, MCP | the sushi_ds41 plugin; a pick-tolerance model setting lands in the plugin, not here |
| **L3 Build/packaging** | How the fork builds and names itself | `local/build.sh`, flags, `MLX_SERVE_DEV_VERSION` | the build's version and its staged kit |
| **L4 Small patch** | A focused edit to upstream source, one branch per patch off `origin/main` | `fork/<name>` branches, tests beside the code | F1 dev version (2 lines) |
| **L5 Divergent feature** | A capability upstream does not have | its own branch, new files where possible, one seam | CR-A ablation in qwen4_exp, CR-B prefix cache modes, CR-C model default + UI |

## 3. Choosing the level: ask in this order
1. Can a setting, a launch flag or an existing env lever do it? → L1.
2. Is there a seam (an outside plugin, a skill, a provider)? → L2. A model-specific knob belongs in that
   model's plugin, and for an outside plugin that means the CommunityServe repo, not this one.
3. Can the fork's build script do it? → L3.
4. Is it a bug or a small generality fix upstream would plausibly take? → L4.
5. Is it a new capability? → L5, only with a written design (`local/notes/`) and a measured need.
6. Does it touch the plugin ABI (`src/abi/`), the kernel contract, the format corpus, the release
   workflow or `AGENTS.md` growth policy? → don't, unless it is the point of a PR upstream asked for.

Worked examples:
| Problem | Decision | Why |
|---|---|---|
| Steer a model for every client without each sending a field | **L1 + L5** (CR-C): a per-model setting, read per request | config decides; the code only reads it |
| Build a steering direction for a model | **L2** first (sushi's env tap), **L5** (CR-D) only for a model no plugin taps | an env-gated tap in one plugin is <100 lines and host-free |
| Dev builds report the last release's number, so plugins install against the wrong kit | **L3 + L4** (F1): the build names itself, two lines let it | the plist is upstream's release pipeline's; bumping it dirties the tree on every merge |
| Per-layer steering bank with its own route, ABI bit and CLI (PR #538) | **dropped** → tag `steering-bank-v1` | owned ABI and a route, conflicted on every merge; upstream shipped a seam (#1045) we moved onto |

## 4. Rules per level
- **L1:** a lasting setting is written by the app or recorded in `local/notes/`; a hand edit is an experiment
  until it is.
- **L2:** an outside plugin is reviewed read-only before it is built (network, process spawns, writes outside
  its paths, env reads beyond its documented levers), built from the reviewed commit against **this build's**
  kit (`local/build.sh` stages it; the app's Install button then uses it), and the review is a ledger note.
- **L3:** `local/build.sh` wraps `app/build.sh`; it never edits a tracked file.
- **L4/L5:**
  - **Budget: 500 changed lines in upstream files for fork-only entries** (new files of our own do not count;
    measure with `git diff --numstat origin/main fork-main` over files that exist on `origin/main`). An entry
    with an **open upstream PR is outside the budget while the PR is open**; the day it is declined it is
    inside it, and §7 applies.
  - Called out before it is implemented: level, files and lines touched, conflict points, off switch, drop
    condition. The owner decides whether it is worth carrying.
  - Additive: new code in new files; edits to upstream files are seams or the minimal fix. No refactors,
    reformatting, renames or comment-only edits to upstream code.
  - Tests follow upstream's TDD rule (failing test first, a class guard for a class); shell tests in
    `tests/`, Swift tests in `app/Tests/`. No source-scan tests (upstream's lint refuses them).
  - An off switch (a setting or a registered env lever) unless the ledger justifies none.
  - **One branch per entry off `origin/main`**, named `fork/<name>` (or `ablation/<name>` for the steering
    CRs), merged into `fork-main`. A new release is merged **into each branch** (`git merge v<ver>`), then
    the branches are re-merged into `fork-main`; branches are never rebased while a PR is open.
- **Everything:** state the level and the ledger id in the commit message.

## 5. Ledger template (`PATCHES.md`)
```
### <id> — <one line>
- Level: L<n>          Status: active | pr-open (#NNN) | merged (<ver>) | declined | dropped (<date>)
- Why: <problem, evidence>
- Branch: <name>       Files touched: <paths>       Upstream-file lines: <+a/-d>
- Conflict points: <upstream files/tests most likely to conflict>
- Off switch: <setting | env | none (<reason>)>
- Tests: <files>
- Upstream: yes (<issue/PR>) | no (<reason>)       If declined: <carry | reshape to L<n> | drop>
- Drop when: <condition>
- Notes: <known limitations>
```

## 6. Release workflow
1. Adopt **releases only**, when you choose to: `git fetch origin --tags`; the base is the `v*` tag.
2. Read the release notes and `CHANGELOG.md`; note kit/MLX pin changes (a new MLX means every outside plugin
   is rebuilt by `local/build.sh` + Models > Plugins > Rebuild all).
3. **Per-entry relevance review**, before any merge, for every active entry:
   `git diff <old> <new> -- <its files and conflict points>`; nothing there → skip. Otherwise decide **still
   needed**, **superseded** (upstream fixed it or removed the feature → drop) or **reshaped** (the seam moved
   → re-seat). Write the decision into the entry first, so a conflict is resolved knowing which it is.
4. Merge the tag into each live branch, run that branch's tests (`zig build check`, the touched suites,
   `bash app/test.sh` when `app/` is touched), then rebuild `fork-main`: `git switch -c fork-main-next
   v<new>`, merge each branch, `git branch -f fork-main fork-main-next`.
5. `local/build.sh ko`; smoke the app; `git push private fork-main` and the branches.
6. Update the ledger (status, conflict notes); superseded entries are dropped here with the date.

## 7. Tripwires
- An entry conflicts on **3 releases running**, or its merge takes **more than 2 hours twice** → drop it or
  move it down the ladder.
- The budget in §4 is exceeded → remove something before adding.
- Upstream declines an entry → the owner decides within one release: carry (now inside the budget),
  reshape (lower level, e.g. a plugin-side knob), or drop.

## 8. Repository hygiene
- One canonical checkout (`~/workplace/local-ai/mlx-serve`). Extra worktrees live under
  `~/workplace/local-ai/mlx-serve-wt/<name>` via `git worktree add`; `upstream-main` there is the read-only
  reference. No loose clones under `~/claude-tmp` (scratch apps and logs may live there).
- Remotes: `origin` = upstream, fetch only; `fork` = the public fork (PR branches only); `private` = backup
  of every fork branch. A branch deleted locally is first confirmed on `private` or under a tag.
- `local/` is the fork's own folder (this policy, the ledger, the build script, `notes/`); it rides the
  `fork/local` branch and touches nothing under `src/`, `app/` or `tests/`.
- GitHub Actions on the public fork run upstream's workflows on every push; keep them **disabled**
  (`gh api repos/titan550/mlx-serve/actions/permissions`) unless a PR needs CI from the fork.

## 9. For AI agents
- Before editing, state the level and why a lower one will not do.
- Never implement an L4/L5 change unasked: call it out (§4) and wait for the go.
- Never push to `origin`; never open an upstream PR or issue unless told to; everything stays local until
  the owner has reviewed the branch.
- Never run `app/build.sh` (or `local/build.sh`) without asking: the app serves on :11234 and other sessions
  depend on it. The owner runs the build.
- Every L4/L5 change gets a ledger entry and tests.

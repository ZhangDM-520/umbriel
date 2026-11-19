# Rejected upstream threads

`upstream-rejected` is a fork-only umbrella branch. It carries the work upstream declined, already reviewed and tested, so the fork keeps the behaviour instead of losing it with the closed pull requests. It is never proposed upstream and never becomes a nightly member candidate on its own: it is a member of the integration branch, and the packaging recipe builds from that integration branch.

This file exists only on this branch. It records what the branch owns, why each member is here, what a future absorb has to respect, and how to rebuild it. It is not shipped documentation and carries no user-facing behaviour.

## Members

Each row is a closed, unmerged upstream pull request. The decline quote is what the maintainer actually said; it is recorded so a later reader does not reopen the argument without new evidence.

| PR                                                                           | Title                                                                       | Declined   | Reason                                                                                                                                                               | Commits |
| ---------------------------------------------------------------------------- | --------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| [noctalia-dev/umbriel#713](https://github.com/noctalia-dev/umbriel/pull/713) | `feat(layout)!: place an underfull scrolling strip at start, center or end` | 2026-11-07 | "we don't feel like it's a needed change. Nobody requested it, and I doubt any one would use it, plus it's a breaking change."                                       | 5       |
| [noctalia-dev/umbriel#559](https://github.com/noctalia-dev/umbriel/pull/559) | `perf(view): skip settled views in the animation tick's effect sync`        | 2026-10-25 | "the interactive scenario shows no difference. In exchange, every path outside the tick that stops a view animation now has to call `syncAnimationEffects()` itself" | 1       |
| [noctalia-dev/umbriel#560](https://github.com/noctalia-dev/umbriel/pull/560) | `perf(scene): skip unchanged geometry work in the surface reconfigure`      | 2026-10-25 | "by your own numbers the end-to-end gain is inside the noise floor. In exchange, `surface_apply_geometry` now has to stay a pure function of the snapshotted inputs" | 1       |

Seven commits in total, merged with `--no-ff` so each thread keeps its own tip. The branch base at the time of writing is `upstream/main c89f6771`.

## What each member touches

Shared surfaces matter more than totals: a future member that edits one of these files will conflict with the member named here, and the resolution belongs to whichever side understands the invariant.

| Area                     | Files                                                                                                                                                          | Member |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| Animation effect sync    | `src/view/view_animation.cpp`, `src/view/view.h`, `src/scene/effect_registry.{h,cpp}`, `src/view/view_chrome.cpp`, `src/view/view_state.cpp`                   | #559   |
| Scene surface geometry   | `umbrielfx/types/scene/surface.c`, `umbrielfx/include/umbrielfx/types/wlr_scene.h`, `umbrielfx/tests/abi.c`                                                    | #560   |
| Scrolling strip resting  | `src/layout/scrolling.{h,cpp}`, `src/layout/layout.h`, `src/config/{config.h,fields_layout.cpp,resolve.cpp}`, `docs/user/layout.md`, `docs/user/workspaces.md` | #713   |
| Layout harness and units | `tests/unit/scrolling_layout.cpp`, `tests/unit/config_load.cpp`, `tests/harness/checks/layout/`                                                                | #713   |

`#560` is the only member that changes `umbrielfx`. Its addition to `wlr_scene.h` is an in-tree struct extension, so the ABI guard in `umbrielfx/tests/abi.c` must be updated in the same commit as the struct, and no node may be allocated outside `umbrielfx` afterwards.

## Invariants

- The branch is fork-only. Nothing here is proposed upstream, and no PR is opened from it.
- A member is retired from this branch only when the same behaviour lands upstream. Retiring means deleting its commits from the manifest and the branch, never keeping it "just in case".
- The integration branch is the durable copy. The recipe builds from it, so a member is preserved by ancestry, not by a patch blob. A packaging patch is not the record of this branch.
- Membership is an invariant with a number: seven member commits and three closed PRs. `manifest/upstream-rejected/check.sh` in the maintainer's warehouse enforces it, together with the member commit counts declared below.
- Conflicts are resolved on the member's own history where possible. A `resolve:` commit on this branch is the recorded fallback, not the default.
- The branch lives in exactly one worktree. `~/Projects/umbriel-dev` stays a memory-only checkout with no build directory and no feature branch.

## Rebuild and absorb

### Sync with upstream

The branch syncs lazily. It is not rebased onto every upstream move: a rebuild is forced only when the branch stops building, when a gate fails for a reason upstream introduced, or when a member needs a rebase anyway. `check.sh` reports the drift so staleness is measured rather than assumed.

```
git fetch upstream
git merge upstream/main          # keep merge history; do not rebase a merged umbrella
```

A rebase is acceptable only before the branch is a member of the integration branch. After that, merge: rewriting history would break every downstream ancestry relation.

### Absorb a new member

1. Rebase the member onto the current base in its own worktree, never on this branch.
2. Merge it with `git merge --no-ff <member-tip>` and a message naming the closed PR.
3. Add the row to **Members**, its files to **What each member touches**, and its commit count to the shape control.
4. Run the gate before pushing: a member that cannot reproduce the pass set does not land.

### Gate

The gate is the fork's own, not upstream's CI. Run from the owner worktree:

```
just build debug
meson test -C build-debug <each unit binary>    # a single broken binary aborts the whole suite
just check
just format-docs-check
just lint <changed .cpp files>
```

Compare `just check` against the recorded pass set rather than an absolute count: several failures pre-exist the branch base. The measured baseline and its per-check reasons live in the maintainer's warehouse under `manifest/upstream-rejected/GATE.md`; this file stays free of host-specific results.

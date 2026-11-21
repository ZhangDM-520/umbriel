# nightly integration manifest

`nightly` is rebuilt, not appended to. Reset to `upstream/main`, merge the members below in this order with `--no-ff`, then commit this file last. This file exists only on `nightly`; drop it before any upstream-facing use.

The 2026-11-20 round appended rows 18 and 19 onto the existing tip at the owner's decision, because the base had not moved since the rebuild that produced it. The tree is the same one a replay yields; a rebuild is still what happens whenever `upstream/main` advances.

The 2026-11-21 round is a full replay on a base that moved 24 commits, with three members updated and one added. `fix/overview-scratchpad-fade` is now a single squashed commit on `c89f6771` rather than a commit on the previous base, so its diff includes no upstream revert and its review-round work arrives as one hunk set.

The order is load-bearing: it is the sequence that produced the fewest conflicts, with each shared file landing where its owner expects it. A member that lands upstream is deleted from this table, not kept "just in case".

Integration state: **complete, 20 of 20 merged** on `upstream/main` = `60639b8f`. `fix/spawn-launch-record` landed upstream as #820 and its row is deleted outright. C3 and C4 are cleared by their owning branches (#715 and #570 rebased); C5 is resolved in place by #844. **C1, C2, C6, C7, C8, C9, C10 and C11 are standing work for this branch**: #733 has not carried the `blur_strength` row, #570's release-rehome block has not reached `upstream-rejected`, `feat/resize-physics` predates four merged members, `feat/cli-completions` has not spelled out its `optional<json>` conversion, `fix/resize-lag` was cut on `c89f6771` before all of them, `feat/scratchpad-restore-fade` predates the minimize timeline, `fix/overview-scratchpad-fade` predates the blur protocol and the close-snapshot records, and `feat/scratchpad-drop-adopt` predates the resize grab's own view guard. All recur on every rebuild until absorbed. Apply them from the recipes below rather than rediscovering them. Nothing here is a merge candidate for upstream — `upstream-rejected` alone guarantees that.

**Both branch-owned blockers of the 2026-11-21 attempt are closed at their owners, and this replay carries no provisional union.** `scratchpad-close-animation` (#742) was rebased onto `60639b8f` and now merges clean into both `upstream/main` and this branch, so S1 is retired. `feat/scratchpad-restore-fade` added `d29ba811`, which makes an empty pad's backdrop passive — its dim rect only accepts input while the shown pad has a member — and taught `transient/modal_follow` to dismiss a pad left standing before its overview drop, so S2 is retired. Re-measure both whenever either branch moves: S1 came from upstream movement alone, not from a change on the branch.

The 24 commits between `bc10febd` and this base touch only three files that a member also touches, and each is a clean auto-merge: `4af87f1c` (touch cancel) in `src/input/cursor.cpp`, `f84095ff` (a pressed workspace removed before release) in `src/overview/overview.cpp`, and `dc4de689` plus `17d30208` in `src/server/server_events.cpp`. `dc4de689` moved the close-snapshot purge after the layer-surface destruction and made row 2 stale until it was rebased; nothing else needed action. No member commit landed upstream in this window, so no row was retired.

| #  | Branch                          | PR                    | Owner        | State      | Note                                                   |
| -- | ------------------------------- | --------------------- | ------------ | ---------- | ------------------------------------------------------ |
| 1  | `feat/cli-completions`          | #806                  | `cli`        | merged     |                                                        |
| 2  | `scratchpad-close-animation`    | #742                  | `scratchpad` | merged     | rebased onto the current base; five commits            |
| 3  | `scratchpad-no-recentre`        | #745                  | `scratchpad` | merged     |                                                        |
| 4  | `feat/scratchpad-blur-strength` | —                     | `scratchpad` | merged     | shares `docs/user/animation.md` with 5                 |
| 5  | `floating-minimize-animation`   | #733                  | `minimize`   | **C1, C2** | standing resolutions below                             |
| 6  | `titlebar-adaptive-color`       | #735                  | `titlebar`   | merged     |                                                        |
| 7  | `render-scale`                  | #573                  | `render`     | merged     |                                                        |
| 8  | `downsample-box`                | #575                  | `render`     | merged     | builds on 8                                            |
| 9  | `background-blur-protocol`      | #715                  | `blur`       | merged     | C3 resolved by rebase on 2026-11-19                    |
| 10 | `fix/drag-deform-settle-crop`   | #570                  | `drag`       | merged     | C4 resolved by rebase on 2026-11-19                    |
| 11 | `fix/drag-blur-latency`         | #837                  | `drag`       | merged     | ancestor of 13                                         |
| 12 | `fix/drag-physics-scalability`  | #840                  | `drag`       | merged     | shares `fx_pass.c` with 14                             |
| 13 | `upstream-rejected`             | closed #559/#560/#713 | —            | merged     | shares `view_animation.cpp` with 5                     |
| 14 | `fix/vram-footprint`            | #844                  | `render`     | merged     | C5 resolved in place by #844                           |
| 15 | `feat/resize-physics`           | —                     | `drag`       | merged     | C6 resolved here; ships resize sheet                   |
| 16 | `fix/ram-footprint`             | —                     | `render`     | merged     | reworked onto 8, plus one reclaim commit; merges clean |
| 17 | `fix/resize-lag`                | —                     | `drag`       | **C8**     | cut on `c89f6771`; four hunks, all standing            |
| 18 | `feat/scratchpad-restore-fade`  | —                     | `scratchpad` | **C9**     | cut on row 17; four hunks, all standing                |
| 19 | `fix/overview-scratchpad-fade`  | —                     | `scratchpad` | **C10**    | one squashed commit on c89f6771; pad leaves as a card  |
| 20 | `feat/scratchpad-drop-adopt`    | —                     | `scratchpad` | **C11**    | stacked on row 18; one hunk against row 15             |

Every row is merged. A row's `State` names the resolutions it needs on replay, not an outstanding task: the `C` recipes below are applied during the replay, and a row marked `merged` needs nothing. No row is marked stale: every row merges clean into `upstream/main`, which is the test applied before the replay starts.

## Conflicts

Ownership is decided against `upstream/main`, not against this branch. A collision is **branch-owned** when the branch also fails to merge into `upstream/main`: that branch is stale against the base it targets, and the fix belongs on it. A branch that merges into `upstream/main` cleanly is **fresh**, so the collision it makes here is between two accepted changes and is this branch's job to union. C1, C2, C6, C7, C8, C9, C10 and C11 are fresh-side unions and this branch resolves them; C3, C4 and C5 were stale branches and were fixed at their owners. Row 2 was the stale branch of the previous attempt and has since been rebased, so the replay now runs with no fallback in it.

A branch-owned conflict stops the rebuild: write the report, leave the branch at the last clean merge, push nothing. A `resolve:` commit here is the recorded fallback only when the owner agrees it is mechanical, and it is replaced by the rebase once the owner lands one.

Each owner has a forwardable report in the maintainer's private warehouse at `~/Projects/BRAIN/umbriel-dev/artifacts/briefs/<date>:NIGHTLY-<pr>:conflict.md`, one per branch: `733` (C1, C2), `715` (C3), `570` (C4), `844` (C5). #840 is the other party to C5 and owns no resolution, as #715 and row 18 are the other parties to C10.

### C10 — 19 × 2, 9, 18 and 20, `docs/user/scratchpad.md`, `src/overview/overview.cpp`, `src/workspace/scratchpad.h` (standing resolution, owned by this branch)

`fix/overview-scratchpad-fade` was rebuilt as one squashed commit on `c89f6771`, so it no longer merges clean: its review work now rewrites the pad's overview path, its class records and its user-facing sentence, and it meets four earlier members there. Every hunk is a union of accepted changes.

- `src/overview/overview.cpp` — keep `background-blur-protocol`'s `clientRegion` computation (it is read by `card.blur.update(...)` below), then apply the pad rule instead of a flat `1.0F`: `card.blur.setAlpha(card.transient ? std::clamp(1.0 - m_progress, 0.0, 1.0) : 1.0F)`.
- `src/workspace/scratchpad.h` — drop their `visibleOn()` and keep our `hasVisibleEntriesOn()` (named `showsEntriesOn()` until row 20 renamed it): row 18 already declares `visibleOn()` in the public accessor block, and keeping both is an overload the compiler refuses. Keep `OverviewHidden` and `m_overviewHidden` beside `TrackedCloseSnapshot` and `m_trackedCloseSnapshots`.
- `docs/user/scratchpad.md` — take the branch's sentence: a pad fades out *inside the workspace preview it covered*, and a *gesture* that never opens the overview leaves it alone.
- `src/workspace/scratchpad.cpp` — auto-merges; read it rather than assuming, because it carries both the restore fade's and the drop adoption's edits.

Row 20 is stacked on row 18, so its base is this branch's own merge source and its C6/C9 pairs are already resolved; only the C10 files collide, and `scratchpad.cpp` is left to C11. Falsification: `overview/scratchpad_transition`, `overview/scratchpad_blur`, `overview/scratchpad_cancel`, `overview/scratchpad_open_input` and `scratchpad/empty_stays_open` all pass, and the pad still fades as a card rather than vanishing on the first frame. Owner: `fix/overview-scratchpad-fade`, fresh against upstream, so no report exists.

### C1 — 4 × 5, `docs/user/animation.md` (standing resolution, owned by this branch)

Both rewrite the `## Event tables` table; 6 retypes every row to insert `windows_minimize` and widens the column. #733 has not absorbed the blur row, so this recurs every rebuild.

Recipe: keep row 6's whole table verbatim, then change the scratchpad row's middle cell so it reads `dim`, `blur`, `blur_strength`:

```
| `[animation.scratchpad]`       | `dim`, `blur`, `blur_strength`                                      | Scratchpad show and hide, and its backdrop                 |
```

Row 4's config-example line and its scratchpad paragraph below the table apply without conflict.

### C2 — 5 × 13, `src/view/view_animation.cpp`

Two hunks, both standing work for this branch. Owner: none — #733 is not at fault and `upstream-rejected` is a carrier.

**Hunk 1, `View::cancelFadeAnimation`.** Union, and the order is load-bearing in a way the earlier report had wrong: `abandonMinimizeTransition()` itself calls `m_fade.snap(1.0)`, so `wasAnimating` must be captured **before** the minimize block, not merely before the later snap.

```cpp
void View::cancelFadeAnimation() {
  const bool wasAnimating = m_fade.animating();
  // An unmap or a fresh map abandons a minimize transition. ...
  if (minimizeConcealing()) {
    abandonMinimizeTransition();
  }
  m_minimizePhase = MinimizePhase::None;
  m_fade.snap(1.0);
  setFadeAlpha(1.0F);
  releaseOpeningPresentation();
  if (wasAnimating) {
    syncAnimationEffects();
  }
}
```

**Hunk 2, the animation tick — take OURS, never theirs.** `upstream-rejected`'s side is *empty*, which reads as a deletion and is not one: the block is #570's deferred release re-home, and row 13 predates it. Accepting the empty side silently deletes `m_releaseRehomeArmed` / `flushReleaseRehome` and stops a drag release from ever landing its re-home. Verify with `grep -c m_releaseRehomeArmed src/view/view_animation.cpp` returning 2 before committing.

### C3 — 10 × upstream, `src/view/view.h`

Upstream `3a2d3dfa` added `#include <span>` where 10 added `#include <pixman.h>`. Keep both, sorted. 10 also needs a rebase onto the current base. Owner: `background-blur-protocol`.

### C4 — 11 × upstream, `src/view/view.cpp`, `src/view/view.h`

Upstream `3a2d3dfa` replaced `View::raiseTransientTree()` with `raiseInOrder(std::span<View* const>)` plus `collectTransientTree(std::vector<wlr_scene_node*>&)`; 11 refactors the same function into `walkTransientTree`/`deferRehome`/`applySceneParent`/`demoteDragTreeIfIdle` and still calls `raiseTransientTree()`. Different traversal shapes called from different places, so no textual union compiles. This is a rebase, not a resolution. Owner: `fix/drag-deform-settle-crop`.

### C5 — 12 × 14, `umbrielfx/render/fx_renderer/fx_pass.c` (3 hunks)

15 changes `animation_backdrop()`'s signature and replaces `compute_blur_sample_region` with `init_blur_damage_region`; 13 extends the capture extents and saves/restores the projection around the offscreen draw. Take 15's API as the base and re-apply 13's intent on it; never take 13's pre-15 call signatures. 15 merges last so it carries its own resolution. Owner: `fix/vram-footprint`, with `fix/drag-physics-scalability` in review.

### C6 — `feat/resize-physics` × nightly, seven files, one hunk each (standing resolution, owned by this branch)

Cut on `c89f6771`; it predates four merged members. Six hunks are adjacency, one is a real replacement:

- `view_lifecycle.cpp`: its `resetDragPhysics()` is a strict superset of the bare `m_dragPhysics = DragPhysics{}` we inherited (it also clears `m_dragResizeEdges` and unbinds the drag slot). Take its call; #570's deferred re-home must still run after it.
- `view.cpp`, `view_state.cpp`: it calls `cancelResizeGrab()` exactly where we call `flushReleaseRehome()` or `abandonMinimizeTransition()`. Union all three.
- `view_animation.cpp`: take its tick structure (it handles grabs and resize edges) **and keep `progressed = true`** — `upstream-rejected` gates the effect sync on that flag and the branch predates the gate. Dropping it freezes the sheet's bindings.
- `effect_registry.cpp`, `view.h`: union, both sides' additions survive.
- `animation.md`: keep our table and add `physics` to the `windows_resize` row.

### Retired exclusion — `fix/ram-footprint`

`4a1c52af`, no PR. It was excluded when it and #844 independently rewrote the blur/offscreen-buffer subsystem from the same base `c89f6771`, creating the same helpers on both sides (8 hunks in `fx_offscreen_buffers.c`, 7 in `fx_pass.c`, 6 in `wlr_scene.c`).

The rework **rebased it onto #844's head `8bc74d76`** and added one commit that reclaims blur and animation scratch once idle, and it now merges into this branch with no conflict at all. `e04fc1db` was the pre-rebase tip and is gone; a stale reference to it means someone is reading an old manifest. Keep it after row 14 in the order; it is not a standing resolution.

### C7 — 2 × nightly, `src/cli/ipc_client.cpp` (standing until #806 carries it)

`feat/cli-completions` returns `resp["ok"]` into `std::optional<nlohmann::json>`. `json` converts both to `optional<json>` and to `json` itself, so the return is ambiguous on **GCC 16.2.1**, which CI builds with. Spell the conversion out:

```cpp
return std::optional<nlohmann::json>(resp["ok"]);
```

This host carries a GCC 17 snapshot that resolves the ambiguity, so a local green build does not vouch for this file — only CI's glibc job does. Owner: `cli` (#806); nightly carries it until the branch does.

### C8 — 17 × nightly, four files, one hunk each (standing resolution, owned by this branch)

`fix/resize-lag` was cut on `c89f6771`, three bases behind, so every file it touches that a later member also touched collides. All four hunks are unions; none is a disagreement. Two are **duplicates**: `feat/resize-physics` added `View::cancelResizeGrab()` to `view_floating.cpp` with a body byte-identical to the inline block this branch carries at each site.

- `src/view/view.cpp`, `src/view/view_state.cpp` — take **ours**, the `cancelResizeGrab();` call. Their side inlines the same `Cursor::isResizingView(this)` guard plus `cursor->resetMode()`, which is exactly what `View::cancelResizeGrab()` (`view_floating.cpp`, from row 15) expands to. Two copies of one guard in one function is the defect, not the fix.
- `src/view/view_lifecycle.cpp`, in `View::handleCommit` — union, both closing braces. Ours syncs the adaptive title bar; theirs fires `resizeTrace::commit(*this)`. The trace must stay **after** the ssd sync and inside the same `if`-chain as `hadResizeRequest`, which row 15 does not touch.
- `tests/harness/clients/unmap_client.cpp` — union. Take their `const ssize_t bytesRead = read(...)` binding (it is what lets the trailing `bytesRead == 0` EOF branch work) and their `bytesRead > 0` test, but keep **our** `&& state.mapped` repaint guard and the whole `b`/`t` command set with `repaintBodyOnly` / `repaintBandOnly` / `topBandEnabled` / `topBandSplit`. Their branch predates the band-repaint commands; taking their arm drops them.

Owner: `fix/resize-lag` (held by the `nightly` maintainer). It is a union of a base that no longer exists, not a behaviour decision, so this branch resolves it. Falsification: after the union, `animation/resize_lag` must still report drawn/target lag `0/0` in all three runs — it does — and `animation/` `layout/` `input/` must show only the known reds.

### C9 — 18 × nightly, three files, one hunk in each but two in the last (standing resolution, owned by this branch)

`feat/scratchpad-restore-fade` is cut on row 17 and therefore predates the minimize timeline (row 5) and the blur-strength row (row 4). Its second and third commits carry the empty-pad rule and the passive backdrop; neither touches the three conflicted files, so the union below is unaffected. It merges into `upstream/main` cleanly, so the collision is here and it is ours to union. All three hunks are unions; none re-decides a behaviour.

- `docs/user/animation.md` — keep **our** event table, which carries `windows_minimize`, `physics` on `windows_resize` and `blur_strength` on `scratchpad`, and take only their scratchpad transition cell: `Scratchpad show and hide, a window leaving for its workspace, and its backdrop`. Re-pad the table with `node tools/remark/format.mjs docs/user/animation.md`, which widens the third column and does nothing when given no file. Its second hunk no longer auto-merges: union our blur-strength sentence with the branch's "a pad that loses its last window stays visible" sentence, and keep its "a window leaving a scratchpad" paragraph verbatim. The `### Targets` sentence still auto-merges.
- `src/view/view.h` — union. Their `beginScratchpadRestoreFade` keeps its position right after `animateFadeTo`; our minimize cluster follows it verbatim. `fadeEvent()` and `m_fadeEvent` auto-merge elsewhere in the file.
- `src/view/view_animation.cpp`, `View::syncAnimationEffects` — declare `const AnimationEvent fade = fadeEvent();` and keep **our** minimize branch on it: `if (fade == AnimationEvent::Scratchpad || !minimizeFadeActive())` binds, else `clearAnimationEffect(&target->node, fade)`. The name must be `fade`: the following `wlr_scene_node_set_animation` block auto-merged from their side already reads it.
- `src/view/view_animation.cpp`, the animation tick — keep `progressed = true` first (C6's lesson: the effect-sync gate reads it), take `animationEffect(fadeEvent())` for `m_customFade`, and keep **both** conditions in `builtInSlide`: `fadeEvent() == AnimationEvent::WindowsIn && !minimizeFadeActive()`.

Auto-merged and worth reading rather than assuming: `cancelFadeAnimation` gains `m_fadeEvent.reset()` after the C2 `wasAnimating` capture and after `m_fade.snap(1.0)`, and `syncAnimationEffects` gains the finished-override reset after its `target == nullptr` early return. `restoreView` also drops its `target = nullptr` default, so every caller must pass the transition; the four call sites are the same on both sides.

Falsification is two-sided, because either side of this union is load-bearing: drop `fadeEvent()` (take ours) and `animation/scratchpad_restore_fade` fails on its transparent start; drop the minimize branch (take theirs) and `animation/floating_minimize` fails. Owner: `feat/scratchpad-restore-fade`, fresh against upstream, so no report exists.

### C11 — 20 × 15, `src/workspace/scratchpad.cpp`, `refreshOutputGeometry` and `syncPads` (standing resolution, owned by this branch)

Row 20's second commit routes "the pointer owns this view" through one predicate, `isCarried()`, which is `Cursor::isDraggingView()` behind a null check. Row 15 (`feat/resize-physics`) had taught the same two predicates to spare a **resize grab** as well, through `cursor->isResizingView()`. Neither branch ever had the other's condition, so this is a union of two accepted changes and not a disagreement about which one is right: a dragged view must not be reparented, and a resizing view must not have its box remapped underneath the grab.

- `refreshOutputGeometry` — union, and restore the `Cursor* cursor` local the incoming commit deleted, because the resize half needs it:

```cpp
        if (entry.scratchpad != name || entry.view == nullptr || isCarried(entry.view)
            || (cursor != nullptr && cursor->isResizingView(entry.view))) {
```

- `syncPads`, when a pad definition is removed — take our structure (which is the branch's plus the resize condition; both need the cursor to call `resetMode()`):

```cpp
      if (Cursor* cursor = m_server->cursor(); cursor != nullptr) {
        const bool removesGrabbedView = std::ranges::any_of(views, [&](const View* view) {
          return isCarried(view) || cursor->isResizingView(view);
        });
        if (removesGrabbedView) {
          cursor->resetMode();
        }
      }
```

Do **not** widen `isCarried()` to cover resizing: it is also the admission and restore guard, where a resize grab is handled by cancelling the grab rather than by refusing the operation, which is the accepted row-15 policy.

Falsification, honestly reported: the drag half is pinned by row 20's own `scratchpad/drag_pad_actions`, but **both resize halves are unobserved**. Dropping the hunk-1 clause leaves all 28 of `scratchpad/` green, and so does dropping the hunk-2 clause; only `-Werror` notices the orphaned `cursor` local. A usable-area change or a pad-definition reload during a resize grab is not covered anywhere. The follow-up belongs on `feat/resize-physics`: drive either case from a harness check. Owner: `feat/scratchpad-drop-adopt` for the drag half, `feat/resize-physics` for the resize half; both are fresh against upstream, so no report exists.

## Rules

- Fork-only. Never pushed upstream, never proposed.
- Member branches are the source of truth. A fix goes on the member branch; this branch carries merges and, only by recorded fallback, `resolve:` commits.
- A conflict pauses the rebuild. Write the report, leave the branch at the last clean merge, push nothing.
- Never `git add -A`. Never rewrite a member branch from here. One writer per checkout: `nightly` lives in its own worktree.
- Rebuild on `upstream/main`, never rebase onto `upstream-rejected`.
- A force-pushed member costs nothing: that is what the rebuild lifecycle is for.
- `Owner` names the thread that maintains the branch, not a person. The standing ownership contract — surface, gate, conflict shape, decision log — is `docs/branch-ownership.md`, committed beside this file by the same bookkeeping commit, because a rebuild starts from `upstream/main` and neither file exists there.
- A member that lands upstream is deleted from this table outright; do not keep its row as history.
- A row stacked on another must follow it: row 20 is cut on row 18, so merging it after row 18 keeps its merge base inside this branch and only the C10 and C11 hunks can collide.
- A collision is judged against `upstream/main`, not against this branch. Merge the member into `upstream/main` with `git merge-tree --write-tree`; a clean result makes the branch fresh and the collision here ours to union, and a colliding result makes it stale and sends the fix to its owner.

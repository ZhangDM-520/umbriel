# Resize lag

Dragging a window edge moves two things that can diverge if presentation waits for client redraws: the box the compositor has decided the window should occupy, and the box it draws. Keeping both compositor-owned during an interactive grab ensures the drawn edge tracks the pointer at compositor frame cadence rather than stalling behind slow or unresponsive clients.

## What each grab presents

When `View::sizeGrabActive` holds (and `View::tiledResizeWaitsForClient` is false), `View::presentedWidth` and `View::presentedHeight` return the compositor's target box, and `View::applyPresentation` scales the latest committed client buffer into that box through `View::applyPresentedCrop`. For floating pointer resizes, `View::resizeFloating` applies the target box directly (`m_presentation.setRegion`, `setPosition`, `presentBox`) and schedules an output frame, while `m_presentedCropActive` ensures `View::resetPresentedSurface` restores 1:1 presentation when the grab ends and the client settles. After release, `FloatingGeometry::pendingSize` holds the pointer-requested box until `View::retireFloatingSizeRequest` observes a usable client response, and `View::syncFloatingResizePosition` pins the opposite edges against `View::floatingSize`.

`View::sizeGrabTracksPointer` limits the workspace-wide `Cursor::isResizingWorkspace` hold to tiled windows (`m_tiled`) so an unrelated settling floating peer still retires its own size request while a tiled drag is held.

The `windows_resize` timeline does not enter pointer resizes. A pointer resize arranges with `windows_move` suppressed (`Cursor::isResizingWorkspace`) and `View::beginResizeAnimation` disabled (`sizeGrabTracksPointer`). The spring only governs reflows that are not driven by a pointer grab.

## Configures in flight

`View::requestFloatingSize` sends at most one configure while a pointer resize has one outstanding (`FloatingSizeConfigure::throttled`), and `View::commitFloatingSize` flushes the newest pending target once `FloatingSizeConfigure::releasesThrottle` observes a settled configure serial with either a usable size change, a newly attached buffer (`supplied`), or a native Wayland surface commit acknowledging that serial (`ackedCommit`). Allowing a bufferless Wayland commit to release the active-drag throttle prevents a deadlock when a cell-snapped terminal or size-constrained client acknowledges a configure without changing dimensions or attaching a new buffer, while keeping `FloatingSizeConfigure::settled` strict so ownership handoff still waits for a drawn frame.

## Tiled resizes

A tiled grab applies the pointer delta to the layout through `ResizeGrab::applyDelta` and schedules an arrange on the next output frame, so the drawn box stretches through `View::applyPresentedCrop` toward `Workspace::presentedTiledBox` and restores 1:1 sampling on release in `Cursor::resetMode`. Setting `[animation.windows_resize] wait_for_redraw = true` (`View::tiledResizeWaitsForClient`) opts tiled drags into unstretched held switches capped by `kRedrawWaitMs` instead.

## Measuring it

The `harness` option compiles the trace described in [Resize lag trace](README.md#resize-lag-trace): per step, the pointer, the drawn box, the compositor's target box, and the two lags. Tiled steps record through `Cursor::traceTiledResizeStep` at the end of `Workspace::arrange` so `drawn` reflects the newly presented box rather than the pre-arrange frame. The lag arithmetic lives in `umbriel_pure` (`src/view/resize_lag.cpp`) so a unit test covers the edge selection. A check opts in with `# harness: resize-trace=true`; without it no call site writes anything.

`tests/harness/clients/unmap_client.cpp` drives delayed, non-redrawing, and quantized configures with `RESIZE_DELAY_MS`, `RESIZE_ON_STDIN`, and `RESIZE_STEP` (acknowledging unchanged quantized configures without attaching a buffer, and logging outcomes under `LOG_RESIZES`).

`tests/harness/checks/animation/resize_lag.sh` verifies five paths in one run: instant, 40 ms delayed, and non-redrawing floating sweeps (all maintaining `<= 2 px` target and drawn lag plus pixel-probed held width), a `RESIZE_STEP=50` sub-step ack unlocking the next configure before release plus pointer-resizing a `floatingMaximized` snapped window clearing maximize and settling, and a workspace-2 pass checking a two-window non-redrawing `dwindle` drag (zero gap, post-arrange `drawn == target`, settled client commit traces, and a `300 px` stepped commit on a floating peer settling cleanly during the held tiled drag).

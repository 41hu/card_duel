# Audit Progress

## 2026-09-10
- Read current project settings and enumerated source/test files.
- Verified clean git status and no AGENTS.md at workspace/ancestor locations.
- Read planning-with-files-zh skill and initialized audit records.
- The available code-review skill targets revision diffs, so its fixed-point
  workflow is not applicable to this whole-project behavior audit.
- Inspected battle state refresh/popups, InfoPanel/status slots, server protocol,
  deck validation, and local match lifecycle. Ran existing panel baseline (PASS).
- Started the full AI deck suite, session 59539; legality for all 289 pairings passed.
- Identified concrete candidate regressions and recorded source evidence.
- Added core_audit_test and mobile_audit_test scenes/scripts for reproducible checks.
- Implemented first core/server fixes. Core regression suite now passes 21 checks.
- Ran rendered mobile baseline at 1280x720, captured screenshots under user://.
- One multi-file patch failed exact-context matching; verified no partial changes,
  corrected the context, and reapplied successfully.
- UI fixes pass the expanded 28-check audit at 960x540, including board drag
  cancellation, settlement identity after disconnect, and export-notice expiry.
- Removed strong core backreference cycles; core audit exits without leak warnings.
- Added and passed a real two-client WebSocket integration test on a random local port.
- Rendered test exposed delayed label-capture errors; changed hint callback to
  WeakRef. A stale settlement scene resource UID was removed (path is unchanged).

## Hand Interaction (2026-09-11)
- Added UID-reused fan cards, focus animations, artwork slots, long-press details,
  swipe browsing, staged board targeting and explicit response confirmation.
- Preserved the user's category colors, cost badges, new-card flash and fan pose.
- Fixed redraw flash tracking, viewpoint-change ghosts, selection cleanup,
  duplicate submission and tutorial response selection restrictions.
- Final rendered hand suite: 44 checks, zero failures at both 960x540 and
  1920x1080, including an actual texture pixel check and local-engine submission.
- Core audit: 26 passes; mobile audit: 28 passes; two-client online audit: PASS.
  Online audit covers match setup, not full networked hand UI interaction.
- Playable hand_preview.tscn starts successfully at 1280x720 (120-frame smoke).
- Art mapping and dimensions are documented in art/cards/README.md.
- Physical Android/multitouch testing and drag-to-submit are not included.

## Review Fixes and AP Artwork (2026-09-11)
- Fixed the reviewed blank-space hit target, instantaneous hover jump, and
  new-card animation masking selected/discard borders. Added regressions.
- Shared sword/winged-boot/crystal SVGs now appear on cards and player panels.
  Card labels show base cost; panels show remaining / turn-start grant.
- Turn-start budgets are serialized for local and network clients; spending
  preserves denominators and warlock/debuff budgets are covered.
- Final hand suite: 56 checks, zero failures at 960x540 and 1920x1080.
  Mobile audit: 28 passes including badge bounds. Core audit: 26 passes.
  Real two-client online audit passes and verifies budget fields in both views.
- Refined number bounds after screenshot inspection. No physical phone testing
  or deployment performed; update the server alongside the client for budgets.

## Insufficient-AP Dimming (2026-09-11)
- Shared the ordinary-play AP gate with authoritative private hand metadata.
  Preserved existing sharpshooter pre-deduction gating and all spending rules.
- Dimmed cards remain inspectable; responses and discard ignore play costs.
  Refreshes restore brightness, and new-card glow cannot override dimming.
- Added per-pool, character exception, unlimited-mode, snapshot isolation and
  real local acknowledgement/reset regressions. Online audit checks metadata
  delivery while continuing to verify opponent hand privacy.

## Wiki Mobile Scroll Fix (2026-09-13)
- Root cause: wiki list/detail used plain ScrollContainer while rows are full-width
  Buttons — touch drags started on a row were swallowed by the Button, so the list
  did not scroll and the release was treated as an entry tap.
- Switched wiki's `_list_scroll`/`_detail_scroll` to `drag_scroll.gd`, the same
  drag component BP and settlement already use.
- Hardened `drag_scroll.gd`:
  - Drag guard now recursively disables the whole content subtree (previously only
    the direct content container, so deep Buttons stayed clickable mid-drag).
  - Content is cached lazily so runtime-built UI (wiki builds controls in code)
    works; `_ready` deferral covers scene-file usage.
  - The `_process` fallback is no longer short-circuited forever by one gui press:
    it yields only while `_gui_input` is actually scrolling, so drags that pass
    over Buttons (which eat motion) keep scrolling instead of stalling.
- Added 4 regression checks to `wiki_ui_test.gd`: light tap still opens an entry;
  drag does not open an entry; drag scrolls the list; rows are clickable again
  after the drag ends. Wiki 19/19, pregame 24/24, ui_panel ALL PASS.
- Note: tests must run in rendered mode (Input.warp_mouse drives the pointer;
  headless keeps the pointer at (0,0)). Physical-device touch verification is
  still recommended before release.

## 2026-09-13 (续) — 除根范围收窄为相邻格
- 用户确认意图：近战/重击只能除根「所在格/相邻格」（distance≤0）的蔓生种子。
- 修改 4 处 `distance <= 1` → `distance <= 0`：match_state._handle_vine_remove /
  can_remove_vine_seed、battle_ui._has_removable_seed、ai_player 除根判定；
  修正 match_state 除根注释（「1层」→「1/2层一次全清」）。
- 新增 2 个边界用例（core_audit_test）：相邻格可除根、隔一格拒绝（种子保留、
  卡不消耗）。CORE AUDIT 57/57、hand_interaction 224/224 全过。

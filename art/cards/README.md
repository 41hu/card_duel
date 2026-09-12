# Card Illustrations

Card art is optional. A missing image leaves the existing type-colored placeholder.
Names, costs, selection borders, effects and rules text remain live Godot controls;
do not bake them into the illustration.

## Default Mapping

Place an illustration at `res://art/cards/<type_id>.png`, for example:

- `near.png`: normal melee attack
- `heavy.png`: heavy attack
- `move.png`: movement
- `magic.png`: normal magic attack
- `near_armor.png`: melee armor card
- `item.png`: generic item card

Character-specific item art can override `item.png`:
`item_hunter.png`, `item_miko.png`, `item_vine_ent.png`, etc.
The suffix is the character ID from `scripts/data/character_data.gd`.

Alternatively add an `art` resource path to the relevant entry in
`scripts/data/card_data.gd`, or call `CardWidget.set_art(Texture2D)` for a
runtime-provided texture. Local asset paths are not sent over the network.

## Framing

The card has a fixed logical size of 180 x 264. The illustration window is
160 x 112 (10:7), independently of the title, cost badge and rules area.
A 640 x 448 PNG is a suitable starting size. Other sizes are supported:
the image preserves its aspect ratio and is center-cropped to fill the window.
Keep important subjects away from the edges. No artwork is required to run.

Godot imports these textures normally. Existing export presets include all
resources. Reopen the project in the editor after adding images, then rebuild
the client export. Art changes do not require server changes.

## Interaction

- Hover previews an enlarged, upright card; click or tap selects it.
- Long press opens complete card text; release does not play the card.
- Swipe horizontally or use the scrollbar/wheel to browse large hands.
- Targeted cards stage a choice on the board, then require confirmation.
- Non-targeted cards use the existing confirmation/choice flow.
- Responses select from the same hand, then require confirmation.
- Discard selection is separate and supports multiple cards.
- Card removal animates only after an authoritative hand update.

Cost badges currently show the card's base cost from CARD_DB. Character and
room-rule exceptions are still applied by the game engine; the detail popup
explicitly labels the base cost. Do not interpret a badge as a legality check.

## Action Point Icons

Cards and player panels share `action_point_badge.gd` and `art/ui/ap_*.svg`:
attack uses a red sword, movement a blue winged boot, function a green crystal,
and free cards a neutral outline. Numbers are live labels, not baked into art.
The card shows its base cost; the player panel shows remaining / turn-start grant.
Click a player-panel badge for its type and full numeric details.

The authoritative turn-start hook records `ap_attack_max`, `ap_move_max` and
`ap_function_max` in state snapshots. Spending never changes these denominators.
Warlock's function budget and turn-start attack penalties are included. Bonus
points granted later (including tutorial overrides) may exceed the turn-start
grant; the UI does not clamp them. Older servers lacking these fields fall back
to base budgets, so update both client and server for accurate modified budgets.

New-card animation pulses the shadow only, preserving selection/discard borders
and illustration colors. Card roots remain stable while their faces animate.

## Insufficient AP

Cards dim to 62% brightness when their required action-point pool is insufficient.
They remain selectable and inspectable; details explain the AP shortage.
This is an AP-only cue, not a guarantee about targets, range or other play rules.
Response and discard selection ignore ordinary-play AP dimming.

The match's `has_card_ap` function is shared by ordinary play validation and
the private hand snapshot's `ap_affordable` boolean. Character cost overrides,
rogue's free seize and unlimited play follow the engine's existing rules.
Snapshot cards are deep-copied so UI metadata never enters the core deck.
Older servers without this metadata leave cards at normal brightness; update
both server and client to enable authoritative online dimming.

`res://scenes/hand_preview.tscn` starts a local sandbox match for visual review.
`res://scenes/test_hand_interaction.tscn` runs interaction regressions and saves
rendered screenshots under Godot's `user://` directory when run graphically.

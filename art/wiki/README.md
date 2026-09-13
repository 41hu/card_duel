# Encyclopedia Images

Optional PNG paths, relative to this directory:

- Portraits: `portraits/<character_id>.png`
- Skill icons: `skills/<character_id>/<skill_name>.png`
- Special items: `items/<item_type>.png`

Examples: `portraits/vine_ent.png`, `skills/vine_ent/蔓延.png`,
`items/vine_seed.png`, `items/snare.png`, `items/torii.png`.

Use square images with transparent backgrounds. The UI preserves aspect ratio
and reserves fixed-size slots even when images are missing.
Skill filenames use the displayed skill name in `wiki_catalog.gd`.

# rules/ - the three rulebooks

Static JSON. No egress, no dependencies, stdlib-readable. Each file is one
body of design law a hook can whisper at the moment Claude's own writing
touches the class it governs.

## The shape

Each file: `class` (`ui`, `schema`, or `memory`), `heading` (a case-
insensitive regex the stamp detector looks for, like `# Laws of UX`),
`read_on` (the date the source was actually read, not recalled), and
`laws[]`. Each law: `id`, `name`, `aliases[]` (own name lowercased first),
`family`, `url`, `ask` (Maude's own question, always ending `?`). Codd adds a
top-level `floor` (3) and per-law `schema_touching` or `floor`. Memory adds a
top-level `status: "draft"` and per-law `source`.

## The family vocabulary

One key crosses all three rulebooks, so a check can ask whether any family
reaches a UI law, a schema law, and a memory law, and get a real answer:

- `cue`: is the thing findable under the name it will be asked for.
- `overload`: how many things sit in front of someone at once.
- `chunk`: how much a person, a cell, or a window has to hold as one piece.
- `order`: first, last, and the middle nobody remembers.
- `reuse`: what earns staying resident, on what measured schedule.
- `consolidate`: does the newest thing get time before it is trusted.
- `distinct`: does the one thing that must differ actually differ.
- `provenance`: does a fact carry where it came from.
- `one-place`: is a fact, a copy, or a constraint kept in one place.
- `grouping`: do things that belong together read as together.
- `reach`: is the target big enough, and close enough, to hit.
- `pace`: does feedback keep up with the action.
- `expectation`: does it accept what is plausible, promise only what it means.
- `simplicity`: what could be removed with nothing lost.
- `closure`: is unfinished work visibly unfinished.
- `perception`: what will someone see, or miss, at a glance.
- `system`: laws about the database engine itself, not any one schema.

## Two rules

The descriptions on lawsofux.com are their authors' text. None of it ships
here, only a law's name, its canonical URL, and Maude's own `ask`.

`"status": "draft"` on `laws-of-memory.json` means John has not cut the list
yet. Nothing may treat it as settled the way the UX list and Codd floor are.

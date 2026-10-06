---
name: changed-objects
description: "List changed 1C metadata objects from a git diff and modification markers. Use with the slash commands /changed-objects and /changed-objects-grouped."
---

# Changed objects

The slash commands own the output format. This skill ships the script they run.

- `/changed-objects` — numbered qualified names of objects, attributes and routines.
- `/changed-objects-grouped` — the same changes grouped by metadata type, down to the module. Routines are omitted.

Run from the repository root:

```powershell
powershell.exe -NoProfile -File content/skills/changed-objects/scripts/list-changed-objects.ps1
```

`folder-type-map.json` sits next to the script. The installer rewrites the `content/skills/` prefix to the active tool's skills directory.

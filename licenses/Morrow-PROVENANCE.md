# Morrow components

Source: https://github.com/StarrySky7D4/morrow

Revision: `4de7fe2dbc2504e8342598fabea37ae41fa3d583` (retrieved 2026-11-02).

Copied presentation components:

- `lib/liquid_glass.dart` → `ui/lib/morrow/liquid_glass.dart`
- `shaders/liquid_glass.frag` → `ui/shaders/liquid_glass.frag`

Shader blob: `cf437512d2e3ecd7393eeb5fb43e72f24031c5f5`.

Copyright 2026 StarrySky7D4 and Morrow contributors. AGPL-3.0-only.
See Morrow-LICENSE and Morrow-NOTICE. CPV's new Rust/Flutter application is
distributed under AGPL-3.0-only. Existing upstream notices are retained.
Local adaptations isolate each material's background from foreground siblings,
keep the app gradient aligned during scrolling, and preserve Morrow's rim and
interaction optics. Qt sources and binaries are not included in this repository.

The sidebar, spacing, pastel atmosphere and rounded presentation reference
Morrow's public gallery; CPV implements its own planet/effect workflow.

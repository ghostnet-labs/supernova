# GitHub Octicons

These are unmodified 16px SVGs from https://github.com/primer/octicons at the
commit in `REVISION`. GitHub's MIT license is included in `LICENSE`.

GitHub Activity, Agent Control Center, and Worktree Manager compile
`Octicons.swift`, generated vector PDFs embedded in each binary, and copy
`LICENSE` into their bundles as `Contents/Resources/Octicons-LICENSE`.
Images are decoded once and cached at their native 16px size. The apps draw
them at 12pt beside caption text and 16pt in sidebar and repository headings.
Branch labels share `apps/lib/BranchRef.swift`. There are no
runtime asset downloads or extra installation dependencies.

To regenerate after updating the vendored SVGs, install `svglib==1.5.1` and
`reportlab==4.4.10` in a temporary Python environment, then run
`python apps/lib/octicons/generate-octicons.py`. The output is deterministic.

Status icons and colors follow https://primer.style/octicons/usage-guidelines/
and https://primer.style/product/components/state-label/. Routine repository
and branch icons use the muted foreground color, and merged states are purple.
Controls that aren't GitHub concepts, such as refresh, keep SF Symbols.

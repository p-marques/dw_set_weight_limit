# Delivery requirements

- Run `format.ps1 -Check` with the versions pinned in `.format.json` before delivery, committing, or packaging work. Fix formatting differences first. If a required formatter is unavailable, report the exact blocked check; do not claim it passed.
- Run `format.ps1` to apply formatting. Keep `.format.json` file lists current when adding or removing implementation, configuration, or documentation files. Exclude dependencies, generated output and diagnostic evidence.
- Preserve runtime behavior, release versions, installation paths and SDK/ABI pins during formatting work. Run relevant diagnostic checks after formatting runtime sources.
- Keep tools and validation artifacts outside this repository in the diagnostic workspace. Ask before installing tools; never install globally or change persistent PATH.
- Packaging uses its explicit release allowlist and does not install or invoke formatters.
- No game launch, deployment, commit or push is implied by a formatting request.

- Behavior changes require a version bump. Assess major, minor or patch case by case; do not automatically use one level for every change. Documentation/tooling-only changes do not inherently require a runtime version bump.

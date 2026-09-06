# SetWeightLimit

Set your character's **base carry capacity**, defaulting to **400**. Trait bonuses are added separately: a base of 400 with a 90-point bonus gives a total capacity of 490.

Works with community RC5 UE4SS on its own, using `config.lua`. Optionally install ModSettings to change capacity live through **Settings → Mods → Set Weight Limit**, with a slider from **20–2000** in steps of **20**.

## Settings source

The source is selected once at startup:

- If the ModSettings API is absent, SetWeightLimit reads local `config.lua`. This includes an API that is unavailable because its declaration was missing or rejected.
- If the API exists, local config is completely ignored. ModSettings supplies startup defaults and live changes. An incompatible API or failed connection, read or subscription logs an error rather than switching to local config.

Restart after editing configuration, declarations or the installed framework. There is no automatic switching during a running session. ModSettings values last only for the session; restarting restores its declaration defaults.

## Installation and upgrades

1. Install community **RC5 UE4SS**. For optional in-game controls, also install both **ModSettings** and **ModSettingsBridge**.
2. Disable other carry-capacity mods, including CarryWeightMultiplier and mods that replace the player Blueprint to change capacity.
3. Close the game and extract `SetWeightLimit-<version>.zip` beside `Dawnwalker.exe`, normally in `Dawnwalker/Binaries/Win64`.
4. Keep the included `scripts/config.lua` for standalone operation. Back up any local edits before extracting an update, which may overwrite its defaults.

The archive installs the Lua mod and its declaration at `ue4ss/Mods/ModSettings/definitions/SetWeightLimit.json`. It includes no UE4SS binaries or shared mod lists. The declaration alone does not install ModSettings or its native bridge. Without its API, local config is used. Invalid or unreadable local config produces a logged error and no capacity writes.

## Using the controls

With the optional framework installed, open **Settings → Mods → Set Weight Limit** from the title screen or pause menu. Standalone operation does not add a settings menu.

| Control          | Behavior                                                                          |
| ---------------- | --------------------------------------------------------------------------------- |
| **Enable**       | On by default. Turns the capacity override on or off.                             |
| **Weight Limit** | Sets base capacity. Disabled while Enable is off; its selected value is retained. |

Disabling restores the recorded original base only if no external change has replaced the value managed by SetWeightLimit. Re-enabling reapplies the selected weight through the same safeguards.

Changes made at the title screen apply when your character becomes available. Closing and reopening Settings retains the current session values. Encumbrance may need a pickup, drop or item transfer to refresh after a capacity change.

## Changing startup defaults

For standalone operation, close the game and edit `ue4ss/Mods/SetWeightLimit/scripts/config.lua`:

```lua
return {
    enabled = true,
    weight_limit = 400,
}
```

`enabled` must be a boolean. `weight_limit` must be a positive finite number that remains positive and finite when stored as float32; it may be rounded to that representation. The local file is not restricted to the menu's range or step grid. Both fields must be valid, including when disabled. Restart to apply edits. Setting `enabled = false` prevents the override on that run.

When using ModSettings, edit `ue4ss/Mods/ModSettings/definitions/SetWeightLimit.json` instead:

- In the setting with `"id": "enabled"`, set `"default"` to `true` or `false` without quotes.
- In the setting with `"id": "weight_limit"`, set `"default"` to a number from **20 to 2000**, in multiples of **20**, such as `400` or `600`.

Keep the setting IDs, types, range and step unchanged, and preserve valid JSON syntax. Restart the game to load the edited defaults. Editing these defaults is separate from saving in-game changes; automatic persistence is not implemented.

## Removal

Close the game and remove only:

- `ue4ss/Mods/SetWeightLimit`
- `ue4ss/Mods/ModSettings/definitions/SetWeightLimit.json`

Leave ModSettings and ModSettingsBridge installed for other mods that need them.

## Compatibility and safeguards

Targets game build **25129649**, Unreal Engine **5.5.4**, with community **RC5**. The mod resolves a unique `WeightLimit` FloatProperty by name through the component class hierarchy, without requiring a fixed memory offset. This tolerates property layout changes, but changes to its gameplay meaning or other game interfaces can still require an update. Unexpected existing capacity values are left unchanged. If another system changes a capacity value that SetWeightLimit manages, the mod stops managing that component instead of overwriting the external change.

Capacity changes are checked against the game's reported result. Restoration and rollback require continued ownership of the value. A requested setting can therefore differ from the successfully applied capacity; application failures appear in the UE4SS log.

Integration was **tested with ModSettings 0.1.0**; this identifies the tested version, not an exact-version requirement. Testing confirmed standalone capacity 400 from local config and live ModSettings changes, including 600 → disabled/200 → re-enabled/600. Integration testing also verified title-screen and pause-menu controls, reopening and session retention. Additive-bonus arithmetic passed offline checks, but no nonzero trait bonus was observed during live testing. Controller input remains untested.

## Development and packaging

The source layout separates implementation from installed paths:

| Source                                                                     | Responsibility                                                                                         |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| [src/lua/main.lua](src/lua/main.lua)                                       | Selects local config or ModSettings, subscribes when available and handles the UE4SS/player lifecycle. |
| [src/lua/capacity.lua](src/lua/capacity.lua)                               | Validates requested capacity values and manages safe application, ownership, restoration and rollback. |
| [src/definitions/SetWeightLimit.json](src/definitions/SetWeightLimit.json) | Declares controls, defaults, numeric bounds and the Enable dependency.                                 |
| [src/lua/config.lua](src/lua/config.lua)                                   | Standalone startup defaults; ignored when the ModSettings API is present.                              |

Run `.\package.ps1` to create `dist/SetWeightLimit-<version>.zip`. The explicit five-file allowlist maps the three Lua files and declaration to their installation paths and generates an empty activation file. The README is not included in the archive. Packaging does not install the mod or launch the game.

Generated output in `.build` and `dist` is ignored by Git. Tests, captures and diagnostic tools remain outside this repository.

## Automated releases

`VERSION` is the authoritative packaging/release version, using `major.minor.patch` without a `v` prefix or leading zeroes. Update it when preparing a new release. Packaging reads this file to name `SetWeightLimit-<version>.zip`; release tooling is excluded from the ZIP.

The **Release** GitHub Actions workflow runs on every push to `main`, or manually through **Actions → Release → Run workflow** with `main` selected. Other branches are skipped. It packages the triggering commit and publishes tag `v<version>`, title `SetWeightLimit <version>`, generated release notes and the installable ZIP. It uses the repository's automatic `GITHUB_TOKEN` with `contents: write`; no additional secret is required.

If that tag already has a release, including a draft, the run succeeds without modifying the release or its assets. Runs are serialized without cancelling an active publication. A tag without a release can be reused only when it resolves to the triggering commit; conflicting tags are never moved.

New releases stay in draft until the ZIP upload succeeds. If a run fails after draft creation, inspect the draft and workflow log manually. Later runs skip that draft rather than repairing it. After verifying a draft's tag and complete asset, publish it manually; otherwise remove the incomplete draft before retrying the same commit. API/permission failures fail the workflow rather than being treated as an absent release. Repository tag rules and Actions permissions must allow release creation.

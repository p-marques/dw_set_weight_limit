# SetWeightLimit 0.2.0

Set your character's **base carry capacity** through **Settings → Mods → Set Weight Limit**. The default is **400**, adjustable from **20–2000** in steps of **20**. Trait bonuses are added separately: a base of 400 with a 90-point bonus gives a total capacity of 490.

Settings last for the current game session. Restarting the game restores the declaration defaults; in-game changes are not saved between sessions.

## Installation and upgrades

1. Install community **RC5 UE4SS** and [**ModSettings 0.1.0**](https://github.com/p-marques/dawnwalker_mod_settings). Both framework components, **ModSettings** and **ModSettingsBridge**, are required.
2. Disable other carry-capacity mods, including CarryWeightMultiplier and mods that replace the player Blueprint to change capacity.
3. Close the game and extract `SetWeightLimit-0.2.0.zip` beside `Dawnwalker.exe`, normally in `Dawnwalker/Binaries/Win64`.
4. If upgrading from 0.1.0, remove `ue4ss/Mods/SetWeightLimit/scripts/config.lua`. Version 0.2.0 never reads this obsolete file.

The archive installs the Lua mod and its declaration at `ue4ss/Mods/ModSettings/definitions/SetWeightLimit.json`. It includes no UE4SS binaries or shared mod lists. If ModSettings is unavailable or the declaration is missing or invalid, SetWeightLimit logs an error and makes no capacity changes.

## Using the controls

Open **Settings → Mods → Set Weight Limit** from the title screen or pause menu.

| Control | Behavior |
| --- | --- |
| **Enable** | On by default. Turns the capacity override on or off. |
| **Weight Limit** | Sets base capacity. Disabled while Enable is off; its selected value is retained. |

Disabling restores the recorded original base only if no external change has replaced the value managed by SetWeightLimit. Re-enabling reapplies the selected weight through the same safeguards.

Changes made at the title screen apply when your character becomes available. Closing and reopening Settings retains the current session values. Encumbrance may need a pickup, drop or item transfer to refresh after a capacity change.

## Changing startup defaults

With the game closed, edit `ue4ss/Mods/ModSettings/definitions/SetWeightLimit.json`:

- In the setting with `"id": "enabled"`, set `"default"` to `true` or `false` without quotes.
- In the setting with `"id": "weight_limit"`, set `"default"` to a number from **20 to 2000**, in multiples of **20**, such as `400` or `600`.

Keep the setting IDs, types, range and step unchanged, and preserve valid JSON syntax. Restart the game to load the edited defaults. Editing these defaults is separate from saving in-game changes; automatic persistence is not implemented.

## Removal

Close the game and remove only:

- `ue4ss/Mods/SetWeightLimit`
- `ue4ss/Mods/ModSettings/definitions/SetWeightLimit.json`

Leave ModSettings and ModSettingsBridge installed for other mods that need them.

## Compatibility and safeguards

Targets game build **25129649**, Unreal Engine **5.5.4**, with community **RC5**. Unexpected existing capacity values are left unchanged. If another system changes a capacity value that SetWeightLimit manages, the mod stops managing that component instead of overwriting the external change.

Capacity changes are checked against the game's reported result. Restoration and rollback require continued ownership of the value. A requested setting can therefore differ from the successfully applied capacity; application failures appear in the UE4SS log.

Diagnostic testing verified title-screen and pause-menu controls, reopening, session retention, and live capacity changes, including disabling and re-enabling. Additive-bonus arithmetic passed offline checks, but no nonzero trait bonus was observed during live testing. Controller input remains untested.

## Development and packaging

The source layout separates implementation from installed paths:

| Source | Responsibility |
| --- | --- |
| [src/lua/main.lua](src/lua/main.lua) | Connects to ModSettings, subscribes to changes and handles the UE4SS/player lifecycle. |
| [src/lua/capacity.lua](src/lua/capacity.lua) | Validates requested capacity values and manages safe application, ownership, restoration and rollback. |
| [src/definitions/SetWeightLimit.json](src/definitions/SetWeightLimit.json) | Declares controls, defaults, numeric bounds and the Enable dependency. |

Run `.\package.ps1` to create `dist/SetWeightLimit-0.2.0.zip`. The explicit four-file allowlist maps the Lua files and declaration to their installation paths and generates an empty activation file. The README is not included in the archive. Packaging does not install the mod or launch the game.

Generated output in `.build` and `dist` is ignored by Git. Tests, captures and diagnostic tools remain outside this repository.

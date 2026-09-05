# Set Weight Limit

SetWeightLimit 0.1.0 is a UE4SS Lua mod for **The Blood of Dawnwalker**. It sets the active local player's base carrying capacity to a configured value, default **400**. Trait bonuses remain additive: a +90 bonus gives a total of **490**.

## Install and configure

1. Install the compatible Dawnwalker UE4SS **1.0.1-rc4** package separately. UE4SS must already use the `ue4ss/Mods` layout beside the game executable.
2. Disable CarryWeightMultiplier and other mods that change carrying capacity, including player Blueprint capacity replacements.
3. Extract `SetWeightLimit-0.1.0.zip` into the folder containing the actual game executable (normally `Dawnwalker/Binaries/Win64`). This creates `ue4ss/Mods/SetWeightLimit`; its empty `enabled.txt` activates the mod without replacing shared UE4SS files.
4. With the game closed, edit `ue4ss/Mods/SetWeightLimit/scripts/config.lua`:

```lua
return {
    enabled = true,
    weight_limit = 400,
}
```

Restart the game after changing configuration. `weight_limit` must be a positive finite number within the float32 range (approximately `1.4013e-45` to `3.4028e38`); decimal settings are rounded to float32 storage precision. Invalid configuration makes no changes. Setting `enabled = false` registers no callbacks.

The mod changes the authoritative base property used by native encumbrance calculations. Encumbrance may refresh on the next pickup, drop, or transfer. The configured value sets the base, so bonuses can increase the displayed total.

To uninstall, close the game and remove only `ue4ss/Mods/SetWeightLimit`. To disable temporarily, set `enabled = false`. The underlying property write was observed to reset on restart and not serialize into saves in the original mod's validation.

## Compatibility

This version targets Steam build **25129649** (UE **5.5.4**) with the community RC4 UE4SS setup used by CarryWeightMultiplier 0.2.0. The new mod has **not yet been validated in the game**; the original implementation's successful runtime tests are evidence for the inherited approach, not a new runtime acceptance result.

Only the active local `BP_PlayerCharacter_C` inventory is eligible. The mod requires exactly one `WeightLimit` `FloatProperty` at offset `0x158`, starting at `200 +/- 0.01`. Unexpected values are left unchanged. After application, a detected reset to the original value is reapplied; another detected value stops management of that component.

Property writes use reflected `SetPropertyValue`, followed by property readback and native getter validation. Failed validation attempts restore the previous base. The mod uses construction notifications, up to eight component attempts 250 ms apart, one startup scan after five seconds, and LoadMap validation. There is no recurring scan. Startup, successful applications, and a bounded number of errors appear in the UE4SS log.

## Build a release

From this repository, run `powershell -NoProfile -ExecutionPolicy Bypass -File .\package.ps1`. The execution-policy override applies only to that process. The script creates `dist/SetWeightLimit-0.1.0.zip` and prints its size and SHA-256. The ZIP contains exactly:

```text
ue4ss/Mods/SetWeightLimit/enabled.txt
ue4ss/Mods/SetWeightLimit/scripts/main.lua
ue4ss/Mods/SetWeightLimit/scripts/config.lua
```

The package script uses an explicit allowlist. Documentation, build tools, UE4SS, game assets, and diagnostic files are excluded. Building a release does not install the mod or launch the game.

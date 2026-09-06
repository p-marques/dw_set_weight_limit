local errors = 0
local function log(s)
    print("[SetWeightLimit] " .. s .. "\n")
end
local function problem(s)
    if errors >= 8 then
        return
    end
    errors = errors + 1
    log("ERROR " .. tostring(s))
    if errors == 8 then
        log("Further errors suppressed.")
    end
end
local settings, local_config
if ModSettings == nil then
    log("Settings source: config.lua (ModSettings API absent).")
    local loaded, result = pcall(require, "config")
    if not loaded or type(result) ~= "table" then
        problem("Cannot load config.lua: " .. tostring(result) .. "; no capacity writes.")
        return
    end
    local_config = result
else
    log("Settings source: ModSettings; config.lua ignored.")
    if type(ModSettings) ~= "table" or ModSettings.api_version ~= 1 or type(ModSettings.connect) ~= "function" then
        problem("Incompatible ModSettings API; no capacity writes.")
        return
    end
    local connected, result, err = pcall(ModSettings.connect, "SetWeightLimit")
    if not connected or not result then
        problem(err or result or "ModSettings connection failed")
        return
    end
    settings = result
end
local UEHelpers = require("UEHelpers")
local Capacity = require("capacity")
local function valid(o)
    return o ~= nil and o:IsValid()
end
local function player()
    local p = UEHelpers.GetPlayer()
    if not valid(p) then
        return
    end
    local name = p:GetFullName()
    if name:find("BP_PlayerCharacter_C", 1, true) and not name:find("Default__", 1, true) then
        return p
    end
end
local function owner(c)
    local result
    pcall(function()
        result = c:GetOwner()
    end)
    if not valid(result) then
        pcall(function()
            result = c:GetOuter()
        end)
    end
    return result
end
local function eligible(c)
    if not valid(c) then
        return false, "invalid-component"
    end
    local own = owner(c)
    if not valid(own) then
        return false, "retry"
    end
    local name = own:GetFullName()
    if not name:find("BP_PlayerCharacter_C", 1, true) or name:find("Default__", 1, true) then
        return false, "not-player"
    end
    local active = player()
    if not active or active:GetFullName() ~= name then
        return false, "retry"
    end
    return true
end
local function read(c)
    local count, compatible = 0, false
    local class = c:GetClass()
    while valid(class) do
        class:ForEachProperty(function(property)
            if property:GetFName():ToString() == "WeightLimit" then
                count = count + 1
                compatible = property:GetClass():GetFName():ToString() == "FloatProperty"
            end
        end)
        class = class:GetSuperStruct()
    end
    assert(count > 0, "WeightLimit property not found in component class hierarchy")
    assert(count == 1, "Ambiguous WeightLimit property: multiple matches in component class hierarchy")
    assert(compatible, "Expected WeightLimit property to be a FloatProperty")
    return c:GetPropertyValue("WeightLimit")
end
local state = Capacity.new({
    eligible = eligible,
    read = read,
    same = function(a, b)
        return valid(a) and valid(b) and a:GetFullName() == b:GetFullName()
    end,
    total = function(c)
        return c:GetWeightLimit()
    end,
    write = function(c, n)
        c:SetPropertyValue("WeightLimit", n)
    end,
    applied = function(base, total, enabled)
        log(string.format("Applied base=%g; total=%g; enabled=%s.", base, total, tostring(enabled)))
    end,
})
local function configure()
    local read_ok, enabled, weight = pcall(function()
        if not settings then
            return local_config.enabled, local_config.weight_limit
        end
        local enabled, enabled_err = settings:get("enabled")
        local weight, weight_err = settings:get("weight_limit")
        if enabled == nil or weight == nil then
            error(enabled_err or weight_err or "ModSettings initial/current value unavailable")
        end
        return enabled, weight
    end)
    if not read_ok then
        return false, enabled
    end
    return state:configure(enabled, weight)
end
local ok, why = configure()
if not ok then
    problem(why)
    return
end
local pending, requested = {}, false
local function guarded(f)
    local worked, message = pcall(f)
    if not worked then
        problem(message)
    end
end
local function schedule(c)
    if not valid(c) then
        return
    end
    local key = c:GetFullName()
    if pending[key] then
        return
    end
    pending[key] = true
    local attempts = 0
    local attempt
    attempt = function()
        ExecuteInGameThreadWithDelay(attempts == 0 and 0 or 250, function()
            attempts = attempts + 1
            local worked, result, reason = pcall(state.reconcile, state, c)
            if worked and not result and reason == "retry" and attempts < 8 then
                attempt()
                return
            end
            pending[key] = nil
            if not worked then
                problem(result)
            elseif not result and reason ~= "not-player" and reason ~= "invalid-component" and reason ~= "retry" then
                problem(reason)
            end
        end)
    end
    attempt()
end
local function change()
    local accepted, reason = configure()
    if not accepted then
        problem(reason)
        return
    end
    if requested then
        return
    end
    requested = true
    ExecuteInGameThread(function()
        requested = false
        guarded(function()
            if state.managed and valid(state.managed.component) then
                schedule(state.managed.component)
            end
        end)
    end)
end
if settings then
    local subscriptions = {}
    local subscribed, subscribe_err = pcall(function()
        for _, id in ipairs({ "enabled", "weight_limit" }) do
            local unsubscribe, err = settings:subscribe(id, change)
            if type(unsubscribe) ~= "function" then
                error(err or "ModSettings subscription failed")
            end
            subscriptions[#subscriptions + 1] = unsubscribe
        end
    end)
    if not subscribed then
        for _, unsubscribe in ipairs(subscriptions) do
            local cleaned, cleanup_err = pcall(unsubscribe)
            if not cleaned then
                problem(cleanup_err)
            end
        end
        problem(subscribe_err)
        return
    end
end
local notified, notify_err = pcall(NotifyOnNewObject, "/Script/DogwoodInventory.InventoryComponent", function(c)
    guarded(function()
        schedule(c)
    end)
    return false
end)
if not notified then
    problem(notify_err)
end
local hooked, hook_err = pcall(RegisterLoadMapPostHook, function()
    guarded(function()
        if state.managed and valid(state.managed.component) then
            schedule(state.managed.component)
        elseif state.managed then
            state.managed = nil
        end
    end)
end)
if not hooked then
    problem(hook_err)
end
ExecuteInGameThreadWithDelay(5000, function()
    guarded(function()
        local p = player()
        if not p then
            return
        end
        local objects = FindAllOf("InventoryComponent")
        if type(objects) ~= "table" then
            return
        end
        local selected, matches = nil, 0
        for _, c in ipairs(objects) do
            if valid(c) then
                local own = owner(c)
                if valid(own) and own:GetFullName() == p:GetFullName() then
                    selected = c
                    matches = matches + 1
                end
            end
        end
        if matches == 1 then
            schedule(selected)
        end
    end)
end)
log(
    string.format(
        "Ready; enabled=%s; base=%g; settings source fixed until restart.",
        tostring(state.enabled),
        state.target
    )
)

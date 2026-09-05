local MOD_NAME = "SetWeightLimit"
local INVENTORY_CLASS = "/Script/DogwoodInventory.InventoryComponent"
local PROPERTY_NAME = "WeightLimit"
local PROPERTY_TYPE = "FloatProperty"
local PROPERTY_OFFSET = 0x158
local EXPECTED_BASE = 200.0
local EPSILON = 0.01
local MIN_FLOAT32 = 2 ^ -149
local MAX_FLOAT32 = (2 - 2 ^ -23) * 2 ^ 127
local COMPONENT_RETRY_MS = 250
local MAX_COMPONENT_ATTEMPTS = 8
local STARTUP_FALLBACK_MS = 5000
local MAX_ERROR_LOGS = 8

local error_logs = 0
local managed = nil
local pending_components = {}
local startup_fallback_used = false

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function log_error(message)
    if error_logs >= MAX_ERROR_LOGS then return end
    error_logs = error_logs + 1
    log("ERROR " .. tostring(message))
    if error_logs == MAX_ERROR_LOGS then log("Further errors will be suppressed.") end
end

local function is_finite_number(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local config_ok, config = pcall(require, "config")
if not config_ok then
    log_error("Unable to load config.lua: " .. tostring(config))
    return
end
if type(config) ~= "table" or type(config.enabled) ~= "boolean"
    or not is_finite_number(config.weight_limit)
    or config.weight_limit < MIN_FLOAT32 or config.weight_limit > MAX_FLOAT32 then
    log_error("Invalid config: enabled must be boolean; weight_limit must be a positive finite float32-range number.")
    return
end
if not config.enabled then
    log("Disabled by configuration.")
    return
end

-- Match the property's storage precision, including ordinary decimal settings.
local target_ok, target = pcall(function()
    return string.unpack("f", string.pack("f", config.weight_limit))
end)
if not target_ok or not is_finite_number(target) or target <= 0 then
    log_error("weight_limit could not be converted to a positive finite float32.")
    return
end

local helpers_ok, UEHelpers = pcall(require, "UEHelpers")
if not helpers_ok then
    log_error("Unable to load UEHelpers: " .. tostring(UEHelpers))
    return
end

local function is_valid(object)
    return object ~= nil and object:IsValid()
end

local function approximately_equal(left, right)
    return is_finite_number(left) and is_finite_number(right)
        and math.abs(left - right) <= EPSILON
end

local function get_active_player()
    local player = UEHelpers.GetPlayer()
    if not is_valid(player) then return nil end
    local name = player:GetFullName()
    if not name:find("BP_PlayerCharacter_C", 1, true)
        or name:find("Default__", 1, true) then return nil end
    return player
end

local function get_component_owner(component)
    local owner = nil
    pcall(function() owner = component:GetOwner() end)
    if not is_valid(owner) then pcall(function() owner = component:GetOuter() end) end
    return owner
end

local function resolve_weight_limit(component)
    local matches = {}
    local class = component:GetClass()
    while is_valid(class) do
        class:ForEachProperty(function(property)
            if property:GetFName():ToString() == PROPERTY_NAME then
                table.insert(matches, {
                    kind = property:GetClass():GetFName():ToString(),
                    offset = property:GetOffset_Internal(),
                })
            end
        end)
        class = class:GetSuperStruct()
    end
    if #matches ~= 1 or matches[1].kind ~= PROPERTY_TYPE
        or matches[1].offset ~= PROPERTY_OFFSET then
        return nil, "Expected exactly one WeightLimit FloatProperty at 0x158."
    end
    local value = component:GetPropertyValue(PROPERTY_NAME)
    if not is_finite_number(value) then return nil, "WeightLimit is not finite." end
    return value
end

local function read_total(component)
    local ok, value = pcall(function() return component:GetWeightLimit() end)
    if not ok or not is_finite_number(value) then return nil end
    return value
end

local function rollback(component, original)
    local ok = pcall(function() component:SetPropertyValue(PROPERTY_NAME, original) end)
    if not ok then return false end
    local read_ok, value = pcall(function() return component:GetPropertyValue(PROPERTY_NAME) end)
    return read_ok and approximately_equal(value, original)
end

local function write_and_validate(component, player, original)
    local total_before = read_total(component)
    if total_before == nil then
        log_error("GetWeightLimit did not return a finite number.")
        return false
    end
    local modifier = total_before - original
    local expected_total = target + modifier
    if not is_finite_number(modifier) or not is_finite_number(expected_total)
        or math.abs(expected_total) > MAX_FLOAT32 then
        log_error("Resulting capacity is outside the finite float32 range.")
        return false
    end

    local write_ok, write_error = pcall(function()
        component:SetPropertyValue(PROPERTY_NAME, target)
    end)
    if not write_ok then
        local restored = rollback(component, original)
        log_error("Property write failed: " .. tostring(write_error) .. "; rollback=" .. tostring(restored))
        return false
    end
    local read_ok, readback = pcall(function() return component:GetPropertyValue(PROPERTY_NAME) end)
    if not read_ok or readback ~= target then
        local restored = rollback(component, original)
        log_error("Property readback failed; rollback=" .. tostring(restored))
        return false
    end
    local total_after = read_total(component)
    -- Keep the original tolerance, allowing float32 rounding at large capacities.
    local tolerance = math.max(EPSILON, math.abs(expected_total) * 2 ^ -23)
    if total_after == nil or math.abs(total_after - expected_total) > tolerance then
        local restored = rollback(component, original)
        log_error("Getter validation failed; rollback=" .. tostring(restored))
        return false
    end

    managed = {
        component = component,
        component_name = component:GetFullName(),
        player = player,
        player_name = player:GetFullName(),
        original = original,
        conflict = false,
    }
    log(string.format("Applied base=%g; total=%g (including bonuses).", target, total_after))
    return true
end

local function reconcile_component(component)
    if not is_valid(component) then return "finished" end
    local owner = get_component_owner(component)
    if not is_valid(owner) then return "retry" end
    local owner_name = owner:GetFullName()
    if not owner_name:find("BP_PlayerCharacter_C", 1, true)
        or owner_name:find("Default__", 1, true) then return "finished" end
    local player = get_active_player()
    if not is_valid(player) or owner_name ~= player:GetFullName() then return "retry" end

    local value, property_error = resolve_weight_limit(component)
    if value == nil then
        log_error(property_error)
        return "finished"
    end
    local same_component = managed ~= nil
        and is_valid(managed.component) and is_valid(managed.player)
        and managed.component_name == component:GetFullName()
        and managed.player_name == player:GetFullName()
    if not same_component then
        managed = nil
        if not approximately_equal(value, EXPECTED_BASE) then
            log_error(string.format("Unexpected base %g; expected 200. Capacity left unchanged.", value))
            return "finished"
        end
        write_and_validate(component, player, value)
        return "finished"
    end

    if managed.conflict or value == target then return "finished" end
    if approximately_equal(value, managed.original) then
        write_and_validate(component, player, value)
        return "finished"
    end
    managed.conflict = true
    log_error(string.format("External capacity change to %g; management stopped for this component.", value))
    return "finished"
end

local function schedule_component(component)
    if not is_valid(component) then return end
    local key_ok, key = pcall(function() return component:GetFullName() end)
    if not key_ok or pending_components[key] then return end
    pending_components[key] = true
    local attempt = 0
    local attempt_component
    attempt_component = function()
        ExecuteWithDelay(attempt == 0 and 0 or COMPONENT_RETRY_MS, function()
            ExecuteInGameThread(function()
                attempt = attempt + 1
                local ok, status = pcall(reconcile_component, component)
                if not ok then
                    pending_components[key] = nil
                    log_error("Component reconciliation failed: " .. tostring(status))
                    return
                end
                if status == "retry" and attempt < MAX_COMPONENT_ATTEMPTS then
                    attempt_component()
                    return
                end
                pending_components[key] = nil
            end)
        end)
    end
    attempt_component()
end

local function one_shot_startup_fallback()
    if startup_fallback_used then return end
    startup_fallback_used = true
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local player = get_active_player()
            if not is_valid(player) then return end
            local player_name = player:GetFullName()
            local components = FindAllOf("InventoryComponent")
            if type(components) ~= "table" then return end
            local selected = nil
            local matches = 0
            for _, component in ipairs(components) do
                if is_valid(component) then
                    local owner = get_component_owner(component)
                    if is_valid(owner) and owner:GetFullName() == player_name then
                        matches = matches + 1
                        selected = component
                    end
                end
            end
            if matches == 1 then schedule_component(selected) end
        end)
        if not ok then log_error("Startup scan failed: " .. tostring(err)) end
    end)
end

local notify_ok, notify_error = pcall(NotifyOnNewObject, INVENTORY_CLASS, function(component)
    schedule_component(component)
    return false
end)
if not notify_ok then log_error("NotifyOnNewObject registration failed: " .. tostring(notify_error)) end

local load_ok, load_error = pcall(RegisterLoadMapPostHook, function()
    if managed ~= nil and is_valid(managed.component) then
        schedule_component(managed.component)
    elseif managed ~= nil then
        managed = nil
    end
end)
if not load_ok then log_error("LoadMap registration failed: " .. tostring(load_error)) end

ExecuteWithDelay(STARTUP_FALLBACK_MS, one_shot_startup_fallback)
log(string.format("Ready; base capacity=%g. Bonuses remain additive.", target))

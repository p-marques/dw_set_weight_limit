-- Guarded capacity state, independent of UE4SS. The adapter owns object checks.
local Capacity = {}
local function finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end
local function close(a, b)
    return finite(a) and finite(b) and math.abs(a - b) <= 0.01
end
function Capacity.new(api)
    local self = { enabled = true, target = 400, managed = nil }
    function self:configure(enabled, value)
        if type(enabled) ~= "boolean" or not finite(value) or value <= 0 or value > (2 - 2 ^ -23) * 2 ^ 127 then
            return false, "invalid settings"
        end
        local ok, target = pcall(function()
            return string.unpack("f", string.pack("f", value))
        end)
        if not ok or not finite(target) or target <= 0 then
            return false, "invalid float32"
        end
        self.enabled, self.target = enabled, target
        return true
    end
    function self:reconcile(component)
        local eligible, why = api.eligible(component)
        if not eligible then
            return false, why
        end
        local current = api.read(component) -- also verifies the unique property/type/offset
        if not finite(current) then
            return false, "nonfinite base"
        end
        local m = self.managed
        if not m or not api.same(m.component, component) then
            if not close(current, 200) then
                return false, "unexpected original base; unchanged"
            end
            m = { component = component, original = current, last = current, conflict = false }
            self.managed = m
        end
        if m.conflict then
            return false, "component ownership lost"
        end
        if current ~= m.last then
            m.conflict = true
            return false, "external capacity change; unchanged"
        end
        local target = self.enabled and self.target or m.original
        if current == target then
            return true, "unchanged"
        end
        local total = api.total(component)
        if not finite(total) then
            return false, "invalid native getter before write"
        end
        local expected = target + (total - current)
        if not finite(expected) or math.abs(expected) > (2 - 2 ^ -23) * 2 ^ 127 then
            return false, "total outside float32 range"
        end
        local function rollback()
            local read_ok, actual = pcall(api.read, component)
            if not read_ok or actual ~= target then
                if not read_ok or actual ~= current then
                    m.conflict = true
                end
                return false
            end
            local restore_ok = pcall(api.write, component, current)
            local verify_ok, restored = pcall(api.read, component)
            if not restore_ok or not verify_ok or restored ~= current then
                m.conflict = true
                return false
            end
            local getter_ok, restored_total = pcall(api.total, component)
            return getter_ok
                and finite(restored_total)
                and math.abs(restored_total - total) <= math.max(0.01, math.abs(total) * 2 ^ -23)
        end
        local wrote, err = pcall(api.write, component, target)
        local read_ok, actual = pcall(api.read, component)
        local getter_ok, after = pcall(api.total, component)
        if
            not wrote
            or not read_ok
            or actual ~= target
            or not getter_ok
            or not finite(after)
            or math.abs(after - expected) > math.max(0.01, math.abs(expected) * 2 ^ -23)
        then
            local restored = rollback()
            return false,
                "write validation failed; rollback="
                    .. tostring(restored)
                    .. (not wrote and ("; " .. tostring(err)) or "")
        end
        m.last = target
        api.applied(target, after, self.enabled)
        return true, "applied"
    end
    return self
end
return Capacity

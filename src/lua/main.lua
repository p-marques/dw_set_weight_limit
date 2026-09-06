local errors=0
local function log(s) print('[SetWeightLimit] '..s..'\n') end
local function problem(s)
    if errors>=8 then return end
    errors=errors+1;log('ERROR '..tostring(s))
    if errors==8 then log('Further errors suppressed.') end
end
if type(ModSettings)~='table' or ModSettings.api_version~=1 then problem('ModSettings v1 is required; no capacity writes.');return end
local settings,err=ModSettings.connect('SetWeightLimit')
if not settings then problem(err);return end
local UEHelpers=require('UEHelpers')
local Capacity=require('capacity')
local function valid(o) return o~=nil and o:IsValid() end
local function player()
    local p=UEHelpers.GetPlayer()
    if not valid(p) then return end
    local name=p:GetFullName()
    if name:find('BP_PlayerCharacter_C',1,true) and not name:find('Default__',1,true) then return p end
end
local function owner(c)
    local result
    pcall(function() result=c:GetOwner() end)
    if not valid(result) then pcall(function() result=c:GetOuter() end) end
    return result
end
local function eligible(c)
    if not valid(c) then return false,'invalid-component' end
    local own=owner(c)
    if not valid(own) then return false,'retry' end
    local name=own:GetFullName()
    if not name:find('BP_PlayerCharacter_C',1,true) or name:find('Default__',1,true) then return false,'not-player' end
    local active=player()
    if not active or active:GetFullName()~=name then return false,'retry' end
    return true
end
local function read(c)
    local count,compatible=0,false
    local class=c:GetClass()
    while valid(class) do
        class:ForEachProperty(function(property)
            if property:GetFName():ToString()=='WeightLimit' then
                count=count+1
                compatible=property:GetClass():GetFName():ToString()=='FloatProperty'
            end
        end)
        class=class:GetSuperStruct()
    end
    assert(count>0,'WeightLimit property not found in component class hierarchy')
    assert(count==1,'Ambiguous WeightLimit property: multiple matches in component class hierarchy')
    assert(compatible,'Expected WeightLimit property to be a FloatProperty')
    return c:GetPropertyValue('WeightLimit')
end
local state=Capacity.new({eligible=eligible,read=read,
    same=function(a,b) return valid(a) and valid(b) and a:GetFullName()==b:GetFullName() end,
    total=function(c) return c:GetWeightLimit() end,
    write=function(c,n) c:SetPropertyValue('WeightLimit',n) end,
    applied=function(base,total,enabled) log(string.format('Applied base=%g; total=%g; enabled=%s.',base,total,tostring(enabled))) end})
local ok,why=state:configure(settings:get('enabled'),settings:get('weight_limit'))
if not ok then problem(why);return end
local pending,requested={},false
local function guarded(f)
    local worked,message=pcall(f)
    if not worked then problem(message) end
end
local function schedule(c)
    if not valid(c) then return end
    local key=c:GetFullName()
    if pending[key] then return end
    pending[key]=true
    local attempts=0
    local attempt
    attempt=function()
        ExecuteInGameThreadWithDelay(attempts==0 and 0 or 250,function()
                attempts=attempts+1
                local worked,result,reason=pcall(state.reconcile,state,c)
                if worked and not result and reason=='retry' and attempts<8 then attempt();return end
                pending[key]=nil
                if not worked then problem(result)
                elseif not result and reason~='not-player' and reason~='invalid-component' and reason~='retry' then problem(reason) end
        end)
    end
    attempt()
end
local function change()
    local accepted,reason=state:configure(settings:get('enabled'),settings:get('weight_limit'))
    if not accepted then problem(reason);return end
    if requested then return end
    requested=true
    ExecuteInGameThread(function()
        requested=false
        guarded(function()
            if state.managed and valid(state.managed.component) then schedule(state.managed.component) end
        end)
    end)
end
local unsub_enabled,e1=settings:subscribe('enabled',change)
local unsub_weight,e2=settings:subscribe('weight_limit',change)
if not unsub_enabled or not unsub_weight then
    if unsub_enabled then unsub_enabled() end
    if unsub_weight then unsub_weight() end
    problem(e1 or e2 or 'subscription failed');return
end
local notified,notify_err=pcall(NotifyOnNewObject,'/Script/DogwoodInventory.InventoryComponent',function(c) guarded(function() schedule(c) end);return false end)
if not notified then problem(notify_err) end
local hooked,hook_err=pcall(RegisterLoadMapPostHook,function()
    guarded(function()
        if state.managed and valid(state.managed.component) then schedule(state.managed.component)
        elseif state.managed then state.managed=nil end
    end)
end)
if not hooked then problem(hook_err) end
ExecuteInGameThreadWithDelay(5000,function()
        guarded(function()
            local p=player();if not p then return end
            local objects=FindAllOf('InventoryComponent')
            if type(objects)~='table' then return end
            local selected,matches=nil,0
            for _,c in ipairs(objects) do
                if valid(c) then local own=owner(c);if valid(own) and own:GetFullName()==p:GetFullName() then selected=c;matches=matches+1 end end
            end
            if matches==1 then schedule(selected) end
        end)
end)
log(string.format('Ready; enabled=%s; base=%g; values are session-only.',tostring(state.enabled),state.target))

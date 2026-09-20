local buffs = {};
buffs.__index = buffs;

function buffs.new(overlays)
    local byStatus, byAbility, bySpell, byProc, procs, durations = {}, {}, {}, {}, {}, {};
    for _, rule in pairs(overlays.buffs) do
        local rules = byStatus[rule.status] or {};
        rules[#rules + 1] = rule;
        byStatus[rule.status] = rules;
        durations[rule.status] = math.max(durations[rule.status] or 0, rule.duration);
        for _, ability in ipairs(rule.abilities or {}) do
            byAbility[ability] = rule.status;
        end
        for _, spell in ipairs(rule.spells or {}) do
            bySpell[spell] = rule.status;
        end
        if rule.proc ~= nil then
            byProc[rule.proc] = rule.status;
            procs[#procs + 1] = rule.status;
        end
    end
    return setmetatable({
        rules = overlays.buffs,
        byStatus = byStatus,
        byAbility = byAbility,
        bySpell = bySpell,
        byProc = byProc,
        procs = procs,
        durations = durations,
        windows = {},
    }, buffs);
end

local function fits(rule, member)
    if rule.mainJob ~= nil and (member == nil or member.mainJob ~= rule.mainJob) then
        return false;
    end
    if rule.subJob ~= nil and (member == nil or member.subJob ~= rule.subJob) then
        return false;
    end
    return true;
end

local function open(self, id, status, now)
    local windows = self.windows[id];
    if windows == nil then
        windows = {};
        self.windows[id] = windows;
    end
    windows[status] = { ends = now + self.durations[status], confirmed = false };
end

function buffs:seen(id, abilityId, now)
    local status = self.byAbility[abilityId];
    if status ~= nil then
        open(self, id, status, now);
    end
end

function buffs:seenSpell(id, spellId, now)
    local status = self.bySpell[spellId];
    if status ~= nil then
        open(self, id, status, now);
    end
end

local function close(self, id, status)
    self.windows[id][status] = nil;
    if next(self.windows[id]) == nil then
        self.windows[id] = nil;
    end
end

function buffs:struck(id, kind, now)
    local status = self.byProc[kind];
    if status == nil then
        return false;
    end
    open(self, id, status, now);
    return true;
end

function buffs:unlit(id, now)
    local windows = self.windows[id];
    if windows == nil then
        return;
    end
    for _, status in ipairs(self.procs) do
        if windows[status] ~= nil then
            close(self, id, status);
        end
    end
end

function buffs:wear(id)
    self.windows[id] = nil;
end

function buffs:export(now)
    local out = {};
    for id, windows in pairs(self.windows) do
        local kept = {};
        for status, w in pairs(windows) do
            kept[status] = { left = w.ends - now, confirmed = w.confirmed };
        end
        out[id] = kept;
    end
    return out;
end

function buffs:import(saved, now)
    for id, windows in pairs(saved or {}) do
        local kept = {};
        for status, w in pairs(windows) do
            if type(status) == 'number' and type(w) == 'table' and type(w.left) == 'number' then
                kept[status] = { ends = now + w.left, confirmed = w.confirmed == true };
            end
        end
        if next(kept) ~= nil then
            self.windows[id] = kept;
        end
    end
end

-- hasBuff returns nil when the member's buffs can't be read; nil must not close the window.
function buffs:active(world, id, status, now)
    local reading = world:hasBuff(id, status);
    local window = self.windows[id] and self.windows[id][status];
    if window ~= nil and now >= window.ends then
        close(self, id, status);
        window = nil;
    end
    if reading == true then
        if window ~= nil then
            window.confirmed = true;
        end
        return true;
    elseif window == nil then
        return false;
    elseif reading == false and window.confirmed then
        close(self, id, status);
        return false;
    end
    return true;
end

function buffs:sample(world, now)
    for id, windows in pairs(self.windows) do
        for status in pairs(windows) do
            self:active(world, id, status, now);
        end
    end
end

function buffs:holds(world, id, member, key, now)
    local rule = self.rules[key];
    return fits(rule, member) and self:active(world, id, rule.status, now);
end

local function sum(self, world, id, member, now, field)
    local total = 0;
    for status, rules in pairs(self.byStatus) do
        local active = nil;
        for _, rule in ipairs(rules) do
            if rule[field] ~= nil and fits(rule, member) then
                if active == nil then
                    active = self:active(world, id, status, now);
                end
                if active then
                    total = total + rule[field];
                end
            end
        end
    end
    return total;
end

function buffs:enmity(world, id, member, now)
    return sum(self, world, id, member, now, 'enmity');
end

function buffs:lossReduction(world, id, member, now)
    return sum(self, world, id, member, now, 'lossReduction');
end

return buffs;

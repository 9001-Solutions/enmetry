-- Keep float32 intermediates, expression order and truncation toward zero: a double-precision port drifts and the drift compounds.

local ffi = require('ffi');

local hatelist = {};
hatelist.__index = hatelist;

hatelist.CAP = 10000;

hatelist.SLOTS = 18;

-- Per DecayEnmity: (int)(60 / kLogicUpdateRate) a tick, at 2.5 ticks a second.
hatelist.DECAY_PER_TICK = 24;
hatelist.TICK = 0.4;

-- UpdateEnmity's bonus for opening a list with no active entries.
local ENGAGE_CE, ENGAGE_VE = 200, 900;

local SINGLE = { lanes = 1, capacity = 1 };

local f32buf = ffi.new('float[1]');

local function f32(x)
    f32buf[0] = x;
    return f32buf[0];
end

local function int(x)
    if x < 0 then
        return math.ceil(x);
    end
    return math.floor(x);
end

local function clamp(v, lo, hi)
    if v < lo then
        return lo;
    elseif v > hi then
        return hi;
    end
    return v;
end

-- GetEnmityModDamage.
function hatelist.damageDivisor(level)
    return math.floor(level * 31 / 50) + 6;
end

-- GetEnmityModCure; the last branch is double arithmetic cast to int16.
function hatelist.cureDivisor(level)
    if level <= 10 then
        return level + 10;
    elseif level <= 50 then
        return 20 + math.floor((level - 10) / 2);
    end
    return int(40 + (level - 50) * 0.6);
end

-- CalculateEnmityBonus.
local function bonus(mod)
    return f32((100 + clamp(mod, -50, 100)) / 100);
end

local function modAt(mod, lane)
    if type(mod) == 'number' then
        return mod;
    end
    return mod[lane];
end

function hatelist.new(cap, bank)
    bank = bank or SINGLE;
    return setmetatable({
        cap = cap or hatelist.CAP,
        bank = bank,
        entries = {},
        order = {},
        others = {},
        claimed = false,
        slots = hatelist.SLOTS,
        used = 0,
        free = {},
        v = ffi.new('int32_t[?]', bank.capacity * hatelist.SLOTS * 2),
        version = 0,
    }, hatelist);
end

local function grow(self)
    local old, slots = self.v, self.slots;
    local wider = slots * 2;
    local v = ffi.new('int32_t[?]', self.bank.capacity * wider * 2);
    for lane = 0, self.bank.capacity - 1 do
        ffi.copy(v + lane * wider * 2, old + lane * slots * 2, slots * 2 * ffi.sizeof('int32_t'));
    end
    self.v, self.slots = v, wider;
end

local function insert(self, id)
    local slot = table.remove(self.free);
    if slot == nil then
        if self.used == self.slots then
            grow(self);
        end
        slot = self.used;
        self.used = slot + 1;
    end
    local v, slots = self.v, self.slots;
    for lane = 0, self.bank.lanes - 1 do
        local i = (lane * slots + slot) * 2;
        v[i], v[i + 1] = 0, 0;
    end
    local e = { slot = slot, active = true };
    self.entries[id] = e;
    self.order[#self.order + 1] = id;
    self.version = self.version + 1;
    return e;
end

local function empty(self)
    if next(self.others) ~= nil then
        return false;
    end
    for _, e in pairs(self.entries) do
        if e.active then
            return false;
        end
    end
    return true;
end

function hatelist:add(id, ce, ve, mod, inRange)
    if not inRange then
        ce, ve = 0, 0;
    end

    local e = self.entries[id];
    if e == nil then
        if ce < 0 or ve < 0 then
            return;
        end
        if empty(self) then
            ce, ve = ce + ENGAGE_CE, ve + ENGAGE_VE;
        end
        e = insert(self, id);
    elseif ce >= 0 and ve >= 0 then
        e.active = true;
    end

    local v, slots, cap = self.v, self.slots, self.cap;
    for lane = 0, self.bank.lanes - 1 do
        local i = (lane * slots + e.slot) * 2;
        local b = bonus(modAt(mod, lane));
        -- The server's conditional has a float and an int branch, so both come out float.
        local dce = ce > 0 and f32(ce * b) or ce;
        local dve = ve > 0 and f32(ve * b) or ve;
        v[i] = clamp(int(f32(v[i] + dce)), 0, cap);
        v[i + 1] = clamp(int(f32(v[i + 1] + dve)), 0, cap);
    end
    self.version = self.version + 1;
end

function hatelist:damage(id, damage, mobLevel, mod, inRange)
    local ce, ve = hatelist.damageEnmity(damage, mobLevel);
    self:add(id, ce, ve, mod, inRange);
    self.claimed = true;
end

function hatelist.damageEnmity(damage, mobLevel)
    if damage < 1 then
        damage = 1;
    end
    local divisor = hatelist.damageDivisor(mobLevel);
    return int(f32(f32(80 / divisor) * damage)), int(f32(f32(240 / divisor) * damage));
end

function hatelist:claim(id, mod, inRange)
    self:add(id, 0, 0, mod, inRange);
    self.claimed = true;
end

-- Cure enmity applies the bonus before truncation, unlike UpdateEnmity.
local function addCure(self, id, ce, ve, mod)
    local e = self.entries[id];
    if e == nil then
        e = insert(self, id);
    end
    e.active = true;
    local v, slots, cap = self.v, self.slots, self.cap;
    for lane = 0, self.bank.lanes - 1 do
        local i = (lane * slots + e.slot) * 2;
        local b = bonus(modAt(mod, lane));
        v[i] = clamp(v[i] + int(f32(ce * b)), 0, cap);
        v[i + 1] = clamp(v[i + 1] + int(f32(ve * b)), 0, cap);
    end
    self.version = self.version + 1;
end

function hatelist:cure(id, targetLevel, amount, mod, inRange)
    if not inRange then
        return;
    end
    if amount < 1 then
        amount = 1;
    end
    local divisor = hatelist.cureDivisor(targetLevel);
    -- Tranquil Heart's reduction multiplies in last; it is 1.0 here.
    addCure(self, id, f32(f32(40 / divisor) * amount), f32(f32(240 / divisor) * amount), mod);
end

function hatelist:cureFixed(id, ce, ve, mod, inRange)
    if not inRange then
        return;
    end
    addCure(self, id, ce, ve, mod);
end

function hatelist:attacked(id, damage, maxHP, lossReduction)
    local e = self.entries[id];
    if e == nil then
        return;
    end
    local reduction = f32((100 - math.min(lossReduction, 100)) / 100);
    local ce = int(f32(f32(f32(-1800 * damage) / maxHP) * reduction));
    local v, slots, cap = self.v, self.slots, self.cap;
    for lane = 0, self.bank.lanes - 1 do
        local i = (lane * slots + e.slot) * 2;
        v[i] = clamp(v[i] + ce, 0, cap);
    end
    self.version = self.version + 1;
end

function hatelist:base(id)
    if self.entries[id] == nil then
        insert(self, id);
    end
end

function hatelist:lowerByPercent(id, percent)
    local e = self.entries[id];
    if e == nil then
        return;
    end
    local mod = f32(percent / 100);
    local v, slots = self.v, self.slots;
    for lane = 0, self.bank.lanes - 1 do
        local i = (lane * slots + e.slot) * 2;
        v[i] = v[i] - math.max(int(f32(v[i] * mod)), 0);
        v[i + 1] = v[i + 1] - math.max(int(f32(v[i + 1] * mod)), 0);
    end
    self.version = self.version + 1;
end

function hatelist:transfer(from, to, percent, mod, inRange)
    local giver = self.entries[from];
    if giver == nil then
        return false;
    end
    local receiver = self.entries[to];
    local initial = false;
    if receiver == nil then
        initial = empty(self);
        receiver = insert(self, to);
    end
    local m = f32(percent / 100);
    local v, slots, cap = self.v, self.slots, self.cap;
    for lane = 0, self.bank.lanes - 1 do
        local gi = (lane * slots + giver.slot) * 2;
        local ri = (lane * slots + receiver.slot) * 2;
        local ce = math.max(int(f32(v[gi] * m)), 0);
        local ve = math.max(int(f32(v[gi + 1] * m)), 0);
        v[gi], v[gi + 1] = v[gi] - ce, v[gi + 1] - ve;
        if inRange then
            if initial then
                ce, ve = ce + ENGAGE_CE, ve + ENGAGE_VE;
            end
            local b = bonus(modAt(mod, lane));
            v[ri] = clamp(v[ri] + int(f32(ce * b)), 0, cap);
            v[ri + 1] = clamp(v[ri + 1] + int(f32(ve * b)), 0, cap);
        end
    end
    receiver.active = true;
    self.version = self.version + 1;
    return true;
end

function hatelist:set(id, ce, ve)
    local e = self.entries[id];
    if e == nil then
        return;
    end
    local v, slots, cap = self.v, self.slots, self.cap;
    ce, ve = clamp(ce, 0, cap), clamp(ve, 0, cap);
    for lane = 0, self.bank.lanes - 1 do
        local i = (lane * slots + e.slot) * 2;
        v[i], v[i + 1] = ce, ve;
    end
    self.version = self.version + 1;
end

function hatelist:cover(target, coverer)
    local e = self.entries[coverer];
    if e == nil then
        e = insert(self, coverer);
    end
    local v, slots, cap = self.v, self.slots, self.cap;
    for lane = 0, self.bank.lanes - 1 do
        local i = (lane * slots + e.slot) * 2;
        v[i] = math.min(v[i] + 200, cap);
    end
    self.version = self.version + 1;
    self:lowerByPercent(target, 10);
end

function hatelist:clear(id)
    local e = self.entries[id];
    if e == nil then
        return;
    end
    self.entries[id] = nil;
    self.free[#self.free + 1] = e.slot;
    for i, listed in ipairs(self.order) do
        if listed == id then
            table.remove(self.order, i);
            break;
        end
    end
    self.version = self.version + 1;
end

function hatelist:occupy(id, claims)
    self.others[id] = true;
    if claims then
        self.claimed = true;
    end
end

function hatelist:decay(ticks)
    local amount = hatelist.DECAY_PER_TICK * ticks;
    local v, slots = self.v, self.slots;
    for _, e in pairs(self.entries) do
        for lane = 0, self.bank.lanes - 1 do
            local i = (lane * slots + e.slot) * 2 + 1;
            v[i] = v[i] > amount and v[i] - amount or 0;
        end
    end
    self.version = self.version + 1;
end

function hatelist:anchor(id)
    local e = self.entries[id];
    if e == nil then
        return 0;
    end
    local v, slots, cap = self.v, self.slots, self.cap;
    local raised = 0;
    for lane = 0, self.bank.lanes - 1 do
        local base = lane * slots;
        local best = 0;
        for _, other in ipairs(self.order) do
            local o = self.entries[other];
            if other ~= id and o.active then
                local i = (base + o.slot) * 2;
                local total = v[i] + v[i + 1];
                if total > best then
                    best = total;
                end
            end
        end
        local i = (base + e.slot) * 2;
        local ce, ve = v[i], v[i + 1];
        if ce + ve <= best then
            local need = best + 1 - ce - ve;
            local more = math.min(need, cap - ce);
            ce, need = ce + more, need - more;
            ve = math.min(cap, ve + need);
            v[i], v[i + 1] = ce, ve;
            raised = raised + 1;
        end
    end
    if raised > 0 then
        self.version = self.version + 1;
    end
    return raised;
end

function hatelist:setActive(id, active)
    local e = self.entries[id];
    if e ~= nil then
        e.active = active;
        self.version = self.version + 1;
    end
end

-- The server walks an unordered_map, so an exact tie is unobservable unless one is the current target; insertion order stands in.
function hatelist:highest(current, lane)
    local v, base = self.v, (lane or 0) * self.slots;
    local best, bestTotal = nil, 0;
    for _, id in ipairs(self.order) do
        local e = self.entries[id];
        local i = (base + e.slot) * 2;
        local total = v[i] + v[i + 1];
        if e.active and total >= bestTotal then
            if not (total == bestTotal and best ~= nil and best == current) then
                best, bestTotal = id, total;
            end
        end
    end
    return best;
end

function hatelist.leader(v, base, slots, n, held)
    local best, bestTotal = -1, 0;
    for k = 0, n - 1 do
        local slot = slots[k];
        if slot >= 0 then
            local i = (base + slot) * 2;
            local total = v[i] + v[i + 1];
            if total >= bestTotal and not (total == bestTotal and best ~= -1 and best == held) then
                best, bestTotal = k, total;
            end
        end
    end
    return best, bestTotal;
end

function hatelist:get(id)
    local e = self.entries[id];
    if e == nil then
        return;
    end
    local i = e.slot * 2;
    return self.v[i], self.v[i + 1], e.active;
end

function hatelist:value(id, lane)
    local e = self.entries[id];
    if e == nil then
        return;
    end
    local i = (lane * self.slots + e.slot) * 2;
    return self.v[i], self.v[i + 1];
end

function hatelist:stride()
    return self.slots * 2;
end

function hatelist:permute(src, count, scratch)
    local v, stride = self.v, self.slots * 2;
    for i = 1, count do
        local to, from = i * stride, src[i] * stride;
        for k = 0, stride - 1 do
            scratch[to + k] = v[from + k];
        end
    end
    for k = stride, (count + 1) * stride - 1 do
        v[k] = scratch[k];
    end
    self.version = self.version + 1;
end

function hatelist:export()
    local entries, others = {}, {};
    for _, id in ipairs(self.order) do
        local ce, ve, active = self:get(id);
        entries[#entries + 1] = { id, ce, ve, active };
    end
    for id in pairs(self.others) do
        others[#others + 1] = id;
    end
    table.sort(others);
    return { claimed = self.claimed, entries = entries, others = others };
end

function hatelist:import(saved)
    for _, e in ipairs(saved.entries or {}) do
        local id = e[1];
        if type(id) == 'number' and type(e[2]) == 'number' and type(e[3]) == 'number' then
            self:base(id);
            self:set(id, e[2], e[3]);
            self:setActive(id, e[4] ~= false);
        end
    end
    for _, id in ipairs(saved.others or {}) do
        if type(id) == 'number' then
            self:occupy(id, false);
        end
    end
    self.claimed = saved.claimed == true;
end

function hatelist:has(id)
    return self.entries[id] ~= nil;
end

function hatelist:count()
    return #self.order;
end

function hatelist:idAt(i)
    return self.order[i];
end

return hatelist;

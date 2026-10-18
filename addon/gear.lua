local gear = {};
gear.__index = gear;

gear.SLOTS = 16;

local HISTORY = 128;

function gear.new(items)
    local changes = {};
    for i = 1, HISTORY do
        changes[i] = { at = 0, slot = 0, was = 0 };
    end
    return setmetatable({
        items = items,
        worn = {},
        changes = changes,
        head = 0,
        count = 0,
        known = false,
    }, gear);
end

function gear:read(inventory, now)
    if inventory == nil then
        return;
    end
    for slot = 0, gear.SLOTS - 1 do
        local equipped = inventory:GetEquippedItem(slot);
        local index = equipped and equipped.Index or 0;
        local id = 0;
        if index % 256 ~= 0 then
            local item = inventory:GetContainerItem(math.floor(index / 256), index % 256);
            id = item and item.Id or 0;
        end
        self:equip(slot, id, now);
    end
    self.known = true;
end

function gear:equip(slot, id, now)
    local was = self.worn[slot] or 0;
    if was == id then
        return false;
    end
    self.worn[slot] = id;
    self.head = self.head % HISTORY + 1;
    local c = self.changes[self.head];
    c.at, c.slot, c.was = now, slot, was;
    if self.count < HISTORY then
        self.count = self.count + 1;
    end
    return true;
end

local function valueOf(items, id, subJob)
    local e = id ~= 0 and items[id] or nil;
    if e == nil then
        return 0;
    end
    local total = e.enmity or 0;
    if e.subJob ~= nil and e.subJob == subJob then
        total = total + (e.latentEnmity or 0);
    end
    return total;
end

-- An `at` older than the ring reads as the oldest change kept, not as unknown.
local function wornAt(self, slot, at)
    local id = self.worn[slot] or 0;
    if at == nil then
        return id;
    end
    local i = self.head;
    for _ = 1, self.count do
        local c = self.changes[i];
        if c.at <= at then
            break;
        end
        if c.slot == slot then
            id = c.was;
        end
        i = i - 1;
        if i < 1 then
            i = HISTORY;
        end
    end
    return id;
end

function gear:enmity(subJob, at)
    local total = 0;
    for slot = 0, gear.SLOTS - 1 do
        total = total + valueOf(self.items, wornAt(self, slot, at), subJob);
    end
    return total;
end

function gear:breakdown(subJob, at)
    local out = {};
    for slot = 0, gear.SLOTS - 1 do
        local id = wornAt(self, slot, at);
        local value = valueOf(self.items, id, subJob);
        if value ~= 0 then
            out[#out + 1] = { id = id, name = self.items[id].name, value = value };
        end
    end
    return out;
end

function gear:carrying(subJob)
    local out = {};
    for slot = 0, gear.SLOTS - 1 do
        local id = self.worn[slot] or 0;
        if id ~= 0 and valueOf(self.items, id, subJob) ~= 0 then
            out[#out + 1] = id;
        end
    end
    table.sort(out);
    return out;
end

return gear;

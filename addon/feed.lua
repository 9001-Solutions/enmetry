local feed = {};
feed.__index = feed;

-- 0x028 command numbers, per atom0s' actionparse and XiPackets.
local CATEGORIES = {
    [1] = 'melee',
    [2] = 'ranged',
    [3] = 'weaponskill',
    [4] = 'magic',
    [5] = 'item',
    [6] = 'ability',
    [7] = 'skill start',
    [8] = 'cast start',
    [9] = 'item start',
    [10] = 'ability start',
    [11] = 'mobskill',
    [12] = 'ranged start',
    [13] = 'pet ability',
    [14] = 'dance',
    [15] = 'rune',
};

-- The 3-bit reaction field LSB calls ActionResolution; 0 is a hit.
local REACTIONS = {
    [1] = 'miss',
    [2] = 'guard',
    [3] = 'parry',
    [4] = 'block',
};

local function name(resolver, id)
    local r = resolver:resolve(id);
    if r == nil or r.name == nil or r.name == '' then
        return ('0x%08X'):format(id);
    end
    local m = r.member;
    if m ~= nil and m.mainJob ~= nil then
        if m.subJob ~= nil then
            return ('%s %s/%s'):format(r.name, m.mainJob, m.subJob);
        end
        return ('%s %s'):format(r.name, m.mainJob);
    end
    return r.name;
end

-- Job ability damage and miss message ids; an action carrying one in the weaponskill category is really an ability.
local ABILITY_MESSAGES = { [110] = true, [158] = true, [317] = true, [324] = true };

local function describeAction(e, resolver)
    local verb = CATEGORIES[e.category] or ('cat %d'):format(e.category);
    local result = e.targets[1] and e.targets[1].results[1];
    if e.category == 3 and result ~= nil and ABILITY_MESSAGES[result.message] then
        verb = CATEGORIES[6];
    end
    if e.param ~= 0 then
        verb = ('%s #%d'):format(verb, e.param);
    end

    local line = ('%s  %s'):format(name(resolver, e.actorId), verb);

    local first = e.targets[1];
    if first == nil then
        return line;
    end
    line = ('%s > %s'):format(line, name(resolver, first.id));
    if #e.targets > 1 then
        line = ('%s +%d'):format(line, #e.targets - 1);
    end

    local parts = {};
    for i, r in ipairs(first.results) do
        parts[i] = REACTIONS[r.reaction] or tostring(r.param);
    end
    if #parts > 0 then
        line = line .. '  ' .. table.concat(parts, ' ');
    end
    return line;
end

function feed.describe(event, resolver)
    if event.kind == 'message' then
        return ('%s  msg %d > %s  %d %d'):format(
            name(resolver, event.actorId), event.message,
            name(resolver, event.targetId), event.param, event.value);
    end
    return describeAction(event, resolver);
end

function feed.new(capacity)
    return setmetatable({
        capacity = capacity,
        texts = {},
        stamps = {},
        head = 0,
        count = 0,
        total = 0,
    }, feed);
end

function feed:push(text, stamp)
    self.head = self.head % self.capacity + 1;
    self.texts[self.head] = text;
    self.stamps[self.head] = stamp;
    if self.count < self.capacity then
        self.count = self.count + 1;
    end
    self.total = self.total + 1;
end

function feed:size()
    return self.count;
end

function feed:at(n)
    if n < 1 or n > self.count then
        return nil;
    end
    local slot = (self.head - n) % self.capacity + 1;
    return self.texts[slot], self.stamps[slot];
end

function feed:clear()
    self.count = 0;
end

return feed;

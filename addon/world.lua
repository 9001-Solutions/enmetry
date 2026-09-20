local world = {};
world.__index = world;

world.ALLIANCE_SLOTS = 18;

-- Entity array bound, per zone_entities.cpp: static 0x000-0x3FF, players 0x400-0x6FF, dynamic 0x700-0x8FF.
local ENTITY_MAX = 0x8FF;

-- SpawnFlags, per timers/enums.lua and metrics/ashita/mob.lua.
local FLAG_PLAYER = 0x0001;
local FLAG_MOB    = 0x0010;
local FLAG_PET    = 0x0100;
local FLAG_TRUST  = 0x1000;
-- Entity status while resting: xi.animation.HEALING.
local STATUS_RESTING = 33;

world.JOBS = {
    'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG',
    'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO', 'RUN',
};

local function hasFlag(flags, flag)
    return flags % (flag * 2) >= flag;
end

local function classify(flags)
    if hasFlag(flags, FLAG_TRUST) then
        return 'trust';
    elseif hasFlag(flags, FLAG_PET) then
        return 'pet';
    elseif hasFlag(flags, FLAG_MOB) then
        return 'mob';
    elseif hasFlag(flags, FLAG_PLAYER) then
        return 'player';
    end
    return 'npc';
end

-- Horizon's HP% rounding is unverified, so a reading is trusted only to within one.
local function maxHPBounds(hp, hpp, previous)
    if hp <= 0 or hpp <= 1 then
        -- Dead, or 1%, which the server reports for anything below 2%: no ceiling.
        return previous;
    end
    local lo = math.max(hp, math.floor(hp * 100 / (hpp + 1)) + 1);
    local hi = math.ceil(hp * 100 / (hpp - 1)) - 1;
    local full = hpp >= 100;

    if previous ~= nil and previous[1] <= hi and previous[2] >= lo then
        lo, hi = math.max(lo, previous[1]), math.min(hi, previous[2]);
        full = full or previous[3];
    end
    return { lo, hi, full };
end

function world.new(party, entity, player, target, inventory)
    return setmetatable({
        party = party,
        entity = entity,
        player = player,
        targetManager = target,
        inventory = inventory,
        selfId = nil,
        members = {},
        ids = {},
        byServerId = {},
        hpBounds = {},
        down = {},
        rests = {},
        buffs = {},
        count = 0,
        indexCache = {},
        misses = {},
        cached = 0,
    }, world);
end

local STATUS_ENTRIES = 5;
local NO_STATUS = 255;
local EXACT_DOUBLE = 2 ^ 53;

-- The 64-bit mask arrives as a double, so bits are read arithmetically and a mask past 2^53 is unreliable.
local function readBuffs(self)
    local out = {};
    if self.player ~= nil and self.selfId ~= nil and self.selfId ~= 0 then
        local set = {};
        local ids = self.player:GetBuffs();
        for i = 1, 32 do
            local id = ids[i];
            if id ~= nil and id >= 0 and id ~= NO_STATUS then
                set[id] = true;
            end
        end
        out[self.selfId] = set;
    end

    local party = self.party;
    for i = 0, STATUS_ENTRIES - 1 do
        local serverId = party:GetStatusIconsServerId(i);
        local mask = serverId ~= 0 and party:GetStatusIconsBitMask(i) or 0;
        if serverId ~= 0 and self.byServerId[serverId] ~= nil and mask < EXACT_DOUBLE then
            local set = {};
            local low = party:GetStatusIcons(i);
            for b = 0, 31 do
                local id = low[b + 1] + 256 * (math.floor(mask / 4 ^ b) % 4);
                if id ~= NO_STATUS then
                    set[id] = true;
                end
            end
            out[serverId] = set;
        end
    end
    return out;
end

function world:refresh()
    local party = self.party;
    local members, byServerId, ids, count = {}, {}, {}, 0;
    local hpBounds, down, resting = {}, {}, {};
    local zone = party:GetMemberZone(0);

    for slot = 0, world.ALLIANCE_SLOTS - 1 do
        if party:GetMemberIsActive(slot) ~= 0 then
            local m = {
                slot = slot,
                name = party:GetMemberName(slot),
                serverId = party:GetMemberServerId(slot),
                index = party:GetMemberTargetIndex(slot),
                mainJob = world.JOBS[party:GetMemberMainJob(slot)],
                subJob = world.JOBS[party:GetMemberSubJob(slot)],
                mainLevel = party:GetMemberMainJobLevel(slot),
                subLevel = party:GetMemberSubJobLevel(slot),
            };
            -- With no party update for a solo player slot 0's jobs are unset.
            if slot == 0 and m.mainJob == nil and self.player ~= nil then
                m.mainJob = world.JOBS[self.player:GetMainJob()];
                m.subJob = world.JOBS[self.player:GetSubJob()];
                m.mainLevel = self.player:GetMainJobLevel();
                m.subLevel = self.player:GetSubJobLevel();
            end
            if m.index ~= 0 and m.serverId ~= 0 and self.entity:GetServerId(m.index) == m.serverId
                and hasFlag(self.entity:GetSpawnFlags(m.index), FLAG_TRUST) then
                m.trust = true;
            end
            members[slot] = m;
            if m.serverId ~= 0 then
                byServerId[m.serverId] = m;
                ids[#ids + 1] = m.serverId;
                hpBounds[m.serverId] = maxHPBounds(party:GetMemberHP(slot), party:GetMemberHPPercent(slot),
                    self.hpBounds[m.serverId]);
                -- Only skip when both zones are known and differ; a false wipe mid-fight costs more than a missed one.
                local memberZone = party:GetMemberZone(slot);
                if memberZone == 0 or zone == 0 or memberZone == zone then
                    down[m.serverId] = party:GetMemberHPPercent(slot) == 0;
                end
                local render = m.index ~= 0 and self.entity:GetRenderFlags0(m.index) or nil;
                if render ~= nil and hasFlag(render, 0x200) then
                    resting[m.serverId] = self.entity:GetStatus(m.index) == STATUS_RESTING;
                end
            end
            count = count + 1;
        end
    end

    self.members, self.byServerId, self.ids, self.count, self.hpBounds = members, byServerId, ids, count, hpBounds;
    self.down = down;
    self.rests = resting;
    self.selfId = members[0] and members[0].serverId;
    self.buffs = readBuffs(self);

    self.misses = {};
    if self.cached > 1024 then
        self.indexCache, self.cached = {}, 0;
    end
end

function world:member(slot)
    return self.members[slot];
end

function world:memberCount()
    return self.count;
end

function world:allianceMember(serverId)
    return self.byServerId[serverId];
end

-- Shared table; do not modify.
function world:alliance()
    return self.ids;
end

function world:maxHP(serverId)
    if serverId == self.selfId and self.player ~= nil then
        local exact = self.player:GetHPMax();
        if exact > 0 then
            return exact;
        end
    end

    local bounds = self.hpBounds[serverId];
    if bounds == nil then
        return nil;
    elseif bounds[3] then
        return bounds[1];
    end
    return math.floor((bounds[1] + bounds[2]) / 2);
end

function world:downed(serverId)
    return self.down[serverId];
end

function world:resting(serverId)
    return self.rests[serverId];
end

function world:hasBuff(serverId, status)
    local set = self.buffs[serverId];
    if set == nil then
        return nil;
    end
    return set[status] == true;
end

local EQUIPMENT_SLOTS = 16;

function world:wearing(serverId, itemId)
    if self.inventory == nil or serverId ~= self.selfId then
        return nil;
    end
    local inventory = self.inventory;
    for slot = 0, EQUIPMENT_SLOTS - 1 do
        local equipped = inventory:GetEquippedItem(slot);
        local index = equipped and equipped.Index or 0;
        if index % 256 ~= 0 then
            local item = inventory:GetContainerItem(math.floor(index / 256), index % 256);
            if item ~= nil and item.Id == itemId then
                return true;
            end
        end
    end
    return false;
end

-- Render flag 0x200 is set once an entity is drawn, as enmetry.lua's inWorld.
local function rendered(self, index)
    return hasFlag(self.entity:GetRenderFlags0(index), 0x200);
end

local function holds(self, index, serverId)
    return index ~= nil and index > 0 and self.entity:GetServerId(index) == serverId;
end

local function findIndex(self, serverId, member)
    local cached = self.indexCache[serverId];
    if holds(self, cached, serverId) then
        return cached;
    end
    if member ~= nil and holds(self, member.index, serverId) then
        return member.index;
    end

    -- Zone entities encode their index in the low 12 bits of the id.
    local encoded = serverId % 0x1000;
    if encoded <= ENTITY_MAX and holds(self, encoded, serverId) then
        return encoded;
    end

    -- A full scan is ~2300 reads; an id that failed one waits for the next refresh.
    if self.misses[serverId] then
        return nil;
    end
    for index = 1, ENTITY_MAX do
        if self.entity:GetServerId(index) == serverId then
            return index;
        end
    end
    self.misses[serverId] = true;
    return nil;
end

function world:resolve(serverId)
    if serverId == nil or serverId == 0 then
        return nil;
    end

    local member = self.byServerId[serverId];
    local index = findIndex(self, serverId, member);

    if index == nil then
        if member ~= nil then
            return { index = member.index, name = member.name, kind = 'alliance', member = member };
        end
        return nil;
    end

    if self.indexCache[serverId] == nil then
        self.cached = self.cached + 1;
    end
    self.indexCache[serverId] = index;
    local name = self.entity:GetName(index);
    if member ~= nil then
        return { index = index, name = name, kind = 'alliance', member = member };
    end
    return { index = index, name = name, kind = classify(self.entity:GetSpawnFlags(index)) };
end

function world:petOwner(serverId)
    if serverId == nil or serverId == 0 then
        return nil;
    end
    local index = findIndex(self, serverId, nil);
    if index == nil then
        return nil;
    end
    local entity = self.entity;
    for _, id in ipairs(self.ids) do
        local m = self.byServerId[id];
        if m.index ~= nil and m.index > 0 and entity:GetPetTargetIndex(m.index) == index then
            return id;
        end
    end
    return nil;
end

function world:zone()
    local zone = self.party:GetMemberZone(0);
    if zone == nil or zone == 0 then
        return nil;
    end
    return zone;
end

function world:entityAt(index)
    if index == nil or index == 0 then
        return nil;
    end
    local id = self.entity:GetServerId(index);
    if id == 0 then
        return nil;
    end
    return id, self.entity:GetName(index);
end

-- While a sub-target cursor is up the main target moves to slot 1, as Ashita's mobdb reads it.
function world:target()
    local targets = self.targetManager;
    if targets == nil then
        return nil;
    end
    local index = targets:GetTargetIndex(targets:GetIsSubTargetActive());
    if index == nil or index == 0 then
        return nil;
    end
    local id = self.entity:GetServerId(index);
    if id == 0 then
        return nil;
    end
    return id;
end

-- Status 1 is engaged, per the animation LSB sends in 0x00E.
function world:inCombat(serverId)
    local index = findIndex(self, serverId, self.byServerId[serverId]);
    if index == nil or not rendered(self, index) then
        return nil;
    end
    return self.entity:GetStatus(index) == 1;
end

function world:distance(a, b)
    local ia = findIndex(self, a, self.byServerId[a]);
    local ib = findIndex(self, b, self.byServerId[b]);
    if ia == nil or ib == nil or not rendered(self, ia) or not rendered(self, ib) then
        return nil;
    end
    local e = self.entity;
    local dx = e:GetLocalPositionX(ia) - e:GetLocalPositionX(ib);
    local dy = e:GetLocalPositionY(ia) - e:GetLocalPositionY(ib);
    local dz = e:GetLocalPositionZ(ia) - e:GetLocalPositionZ(ib);
    return math.sqrt(dx * dx + dy * dy + dz * dz);
end

-- Ashita's X and Y are the ground plane and Z the height; LandSandBoat's plane is x and z.
function world:position(serverId)
    local index = findIndex(self, serverId, self.byServerId[serverId]);
    if index == nil or not rendered(self, index) then
        return;
    end
    return self.entity:GetLocalPositionX(index), self.entity:GetLocalPositionY(index);
end

return world;

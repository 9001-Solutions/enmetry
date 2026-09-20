--[[
* Entity resolution and the alliance roster, against fakes of Ashita's party
* and entity memory managers.
*
* Run: luajit tests/test_world.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local world = require('world');

--[[
* Fake IParty.  `members` maps slot (0-17) to a member record; anything absent
* is an empty slot, reported the way the client reports one.
--]]
local function fakeParty(members)
    local function field(name, empty)
        return function (_, slot)
            local m = members[slot];
            if m == nil or m[name] == nil then
                return empty;
            end
            return m[name];
        end
    end
    return {
        GetMemberIsActive = function (_, slot) return members[slot] and 1 or 0; end,
        GetMemberName = field('name', ''),
        GetMemberServerId = field('serverId', 0),
        GetMemberTargetIndex = field('index', 0),
        GetMemberMainJob = field('main', 0),
        GetMemberSubJob = field('sub', 0),
        GetMemberMainJobLevel = field('mainLevel', 0),
        GetMemberSubJobLevel = field('subLevel', 0),
        GetMemberHP = field('hp', 0),
        GetMemberHPPercent = field('hpp', 0),
        GetMemberZone = field('zone', 0),
        -- No status icon entries in use.
        GetStatusIconsServerId = function () return 0; end,
    };
end

-- Fake IEntity.  `entities` maps index to { serverId, name, flags, render, x, y, z }.
-- The read counter comes back as `reads` on the fake, so passing the fake on
-- carries nothing extra into another parameter.
local function fakeEntities(entities)
    local reads = { count = 0 };
    local function field(name, empty)
        return function (_, index)
            reads.count = reads.count + 1;
            local e = entities[index];
            if e == nil then
                return empty;
            end
            return e[name];
        end
    end
    return {
        GetServerId = field('serverId', 0),
        GetName = field('name', ''),
        GetSpawnFlags = field('flags', 0),
        GetRenderFlags0 = field('render', 0),
        GetStatus = field('status', 0),
        GetLocalPositionX = field('x', 0),
        GetLocalPositionY = field('y', 0),
        GetLocalPositionZ = field('z', 0),
        GetPetTargetIndex = field('pet', 0),
        reads = reads,
    };
end

t.test('roster reads name, ids, jobs and levels for every alliance slot', function ()
    local w = world.new(fakeParty({
        [0] = { name = 'Hanayaka', serverId = 0x0001E240, index = 0x405, main = 1, sub = 13, mainLevel = 75, subLevel = 37 },
        [17] = { name = 'Tail', serverId = 0x0001E2FF, index = 0x4FF, main = 3, sub = 0, mainLevel = 75, subLevel = 0 },
    }), fakeEntities({}));

    w:refresh();

    t.eq(w:member(0), {
        slot = 0, name = 'Hanayaka', serverId = 0x0001E240, index = 0x405,
        mainJob = 'WAR', subJob = 'NIN', mainLevel = 75, subLevel = 37,
    });
    -- No subjob unlocked: the client reports job 0.
    t.eq(w:member(17), {
        slot = 17, name = 'Tail', serverId = 0x0001E2FF, index = 0x4FF,
        mainJob = 'WHM', mainLevel = 75, subLevel = 0,
    });
    for slot = 1, 16 do
        t.eq(w:member(slot), nil, 'slot ' .. slot);
    end
    t.eq(w:memberCount(), 2);
end);

t.test('with no party update for a solo player, slot 0 takes its jobs from the player\'s own record', function ()
    local player = {
        GetMainJob = function () return 7; end,
        GetSubJob = function () return 3; end,
        GetMainJobLevel = function () return 75; end,
        GetSubJobLevel = function () return 37; end,
        GetHPMax = function () return 1369; end,
        GetBuffs = function () return {}; end,
    };
    local w = world.new(fakeParty({
        [0] = { name = 'Hanayaka', serverId = 1, index = 0x400, main = 0, sub = 0, mainLevel = 0, subLevel = 0 },
        [1] = { name = 'Tail', serverId = 2, index = 0x401, main = 0, sub = 0, mainLevel = 0, subLevel = 0 },
    }), fakeEntities({}), player);
    w:refresh();
    t.eq({ w:member(0).mainJob, w:member(0).subJob, w:member(0).mainLevel, w:member(0).subLevel }, { 'PLD', 'WHM', 75, 37 });
    t.eq({ w:member(1).mainJob, w:member(1).mainLevel }, { nil, 0 }, 'only the player has a record of their own');
end);

t.test('a trust in a party slot is marked as one', function ()
    local w = world.new(fakeParty({
        [0] = { name = 'Hanayaka', serverId = 0x0001E240, index = 0x405, main = 1 },
        [1] = { name = 'Kupipi', serverId = 0x01002701, index = 0x701, main = 3 },
    }), fakeEntities({
        [0x405] = { serverId = 0x0001E240, flags = 0x0D },
        [0x701] = { serverId = 0x01002701, flags = 0x1000 },
    }));
    w:refresh();
    t.eq(w:member(1).trust, true);
    t.eq(w:member(0).trust, nil);
end);

t.test('alliance membership is looked up by server id', function ()
    local w = world.new(fakeParty({
        [7] = { name = 'Other', serverId = 0x0001E250, index = 0x410, main = 5, sub = 4, mainLevel = 75, subLevel = 37 },
    }), fakeEntities({}));
    w:refresh();

    t.eq(w:allianceMember(0x0001E250).name, 'Other');
    t.eq(w:allianceMember(0x0001E250).slot, 7);
    t.eq(w:allianceMember(0x0001E251), nil);
end);

t.test('roster follows the party as it changes', function ()
    local members = { [0] = { name = 'Hanayaka', serverId = 1, index = 0x405, main = 1, sub = 0, mainLevel = 1, subLevel = 0 } };
    local w = world.new(fakeParty(members), fakeEntities({}));
    w:refresh();
    members[0] = nil;
    w:refresh();

    t.eq(w:member(0), nil);
    t.eq(w:allianceMember(1), nil);
    t.eq(w:memberCount(), 0);
end);

t.test('a mob resolves to its name and kind', function ()
    local entities = fakeEntities({
        [0x012] = { serverId = 0x0100A012, name = 'Goblin Thug', flags = 0x10 },
    });
    local w = world.new(fakeParty({}), entities);
    w:refresh();

    t.eq(w:resolve(0x0100A012), { index = 0x012, name = 'Goblin Thug', kind = 'mob' });
end);

t.test('players, pets, trusts and npcs are told apart by spawn flags', function ()
    local w = world.new(fakeParty({}), fakeEntities({
        [0x420] = { serverId = 0x0001E260, name = 'Stranger', flags = 0x01 },
        [0x701] = { serverId = 0x0100A701, name = 'Ifrit', flags = 0x110 },
        [0x702] = { serverId = 0x0100A702, name = 'Shantotto', flags = 0x1010 },
        [0x050] = { serverId = 0x0100A050, name = 'Door', flags = 0x02 },
    }));
    w:refresh();

    t.eq(w:resolve(0x0001E260), { index = 0x420, name = 'Stranger', kind = 'player' });
    t.eq(w:resolve(0x0100A701), { index = 0x701, name = 'Ifrit', kind = 'pet' });
    t.eq(w:resolve(0x0100A702), { index = 0x702, name = 'Shantotto', kind = 'trust' });
    t.eq(w:resolve(0x0100A050), { index = 0x050, name = 'Door', kind = 'npc' });
end);

t.test('an alliance member resolves as alliance and carries the member', function ()
    local w = world.new(fakeParty({
        [0] = { name = 'Hanayaka', serverId = 0x0001E240, index = 0x405, main = 1, sub = 13, mainLevel = 75, subLevel = 37 },
    }), fakeEntities({
        [0x405] = { serverId = 0x0001E240, name = 'Hanayaka', flags = 0x0D },
    }));
    w:refresh();

    local r = w:resolve(0x0001E240);
    t.eq(r.kind, 'alliance');
    t.eq(r.name, 'Hanayaka');
    t.eq(r.index, 0x405);
    t.eq(r.member.mainJob, 'WAR');
end);

t.test('an alliance member out of render range still resolves by roster name', function ()
    local w = world.new(fakeParty({
        [3] = { name = 'Faraway', serverId = 0x0001E270, index = 0, main = 4, sub = 5, mainLevel = 75, subLevel = 37 },
    }), fakeEntities({}));
    w:refresh();

    local r = w:resolve(0x0001E270);
    t.eq(r.kind, 'alliance');
    t.eq(r.name, 'Faraway');
end);

t.test('an id nobody holds resolves to nothing', function ()
    local w = world.new(fakeParty({}), fakeEntities({}));
    w:refresh();
    t.eq(w:resolve(0x0100AFFF), nil);
    t.eq(w:resolve(0), nil);
end);

t.test('a reused entity index is not served stale from cache', function ()
    local entities = {
        [0x420] = { serverId = 0x0001E260, name = 'First', flags = 0x01 },
    };
    local w = world.new(fakeParty({}), fakeEntities(entities));
    w:refresh();
    t.eq(w:resolve(0x0001E260).name, 'First');

    entities[0x420] = { serverId = 0x0001E999, name = 'Second', flags = 0x01 };
    entities[0x421] = { serverId = 0x0001E260, name = 'First', flags = 0x01 };

    t.eq(w:resolve(0x0001E260), { index = 0x421, name = 'First', kind = 'player' });
    t.eq(w:resolve(0x0001E999), { index = 0x420, name = 'Second', kind = 'player' });
end);

t.test('a repeat lookup does not rescan the entity array', function ()
    local mgr = fakeEntities({
        [0x8F0] = { serverId = 0x0001E260, name = 'Late', flags = 0x01 },
    });
    local w = world.new(fakeParty({}), mgr);
    w:refresh();
    w:resolve(0x0001E260);
    local before = mgr.reads.count;
    w:resolve(0x0001E260);
    t.truthy(mgr.reads.count - before < 10, 'reads on cached lookup: ' .. (mgr.reads.count - before));
end);

t.test('an id nobody holds is not rescanned for every packet until the next refresh', function ()
    local entities = {};
    local mgr = fakeEntities(entities);
    local w = world.new(fakeParty({}), mgr);
    w:refresh();

    t.eq(w:resolve(0x0001E777), nil);
    local before = mgr.reads.count;
    t.eq(w:resolve(0x0001E777), nil);
    t.truthy(mgr.reads.count - before < 10, 'reads on repeated miss: ' .. (mgr.reads.count - before));

    -- It spawns; a refresh lets the lookup try again.
    entities[0x430] = { serverId = 0x0001E777, name = 'Arrived', flags = 0x01 };
    w:refresh();
    t.eq(w:resolve(0x0001E777), { index = 0x430, name = 'Arrived', kind = 'player' });
end);

--[[
* A world of one member, at slot 1 so the local player's exact max HP (slot 0)
* stays out of it.  Returns the world and the member to move HP on.
--]]
local function oneMember(hp, hpp)
    local members = {
        [1] = { name = 'Tank', serverId = 1, index = 0x405, main = 1, mainLevel = 75, hp = hp, hpp = hpp },
    };
    local w = world.new(fakeParty(members), fakeEntities({}));
    w:refresh();
    return w, members[1];
end

local function reading(w, member, hp, hpp)
    member.hp, member.hpp = hp, hpp;
    w:refresh();
    return w:maxHP(1);
end

t.test('one reading bounds max HP whether the server floors, rounds or ceils HP%', function ()
    -- 50% is a true 49..51 exclusive, so max is in (75000/51, 75000/49) = 1471..1530.
    local w = oneMember(750, 50);
    t.eq(w:maxHP(1), 1500);
    t.eq(w:maxHP(99), nil);

    -- Dead says nothing.
    t.eq(oneMember(0, 0):maxHP(1), nil);
end);

t.test('max HP narrows across readings', function ()
    local w, m = oneMember(750, 50);          -- 1471..1530
    t.eq(reading(w, m, 1300, 87), 1494);      -- 1478..1511 within it
end);

t.test('once seen at 100%, max HP is the least the range allows, and partial readings do not loosen it', function ()
    local w, m = oneMember(750, 50);
    -- Rounded up, 1495 of 1500 also reads 100%, so 100% alone is 1495..1510.
    t.eq(reading(w, m, 1495, 100), 1495);
    t.eq(reading(w, m, 1500, 100), 1500);
    t.eq(reading(w, m, 700, 46), 1500);
end);

t.test('readings under any rounding of one max HP never start the range over', function ()
    -- Max 1500 throughout.  Ceiling: 1486 reads 100, 1051 reads 71.  Nearest:
    -- 1492 reads 99.  Floor: 1051 reads 70.
    local w, m = oneMember(1486, 100);          -- 1486..1501
    t.eq(reading(w, m, 1051, 71), 1486);        -- 1460..1501
    -- 1492 at 99% proves max is at least 1493: the floor of the range rises.
    t.eq(reading(w, m, 1492, 99), 1493);        -- 1493..1522
    t.eq(reading(w, m, 1051, 70), 1493);        -- 1481..1523
    t.eq(reading(w, m, 1500, 100), 1500);       -- 1500..1515
end);

t.test('max HP starts over when a reading cannot be the same max', function ()
    local w, m = oneMember(1500, 100);       -- 1500..1515
    t.eq(reading(w, m, 900, 100), 900);      -- 900..909: disjoint
    t.eq(reading(w, m, 1600, 100), 1600);
end);

t.test('a reading of 1% bounds max HP from below only, so it is ignored', function ()
    t.eq(oneMember(5, 1):maxHP(1), nil);
    local w, m = oneMember(1200, 100);
    t.eq(reading(w, m, 5, 1), 1200);
end);

t.test('a member at zero HP keeps the last estimate', function ()
    local w, m = oneMember(1200, 100);
    t.eq(reading(w, m, 0, 0), 1200);
end);

t.test('a member is down at 0% HP, up above it, and unknown in another zone', function ()
    local members = {
        [0] = { name = 'Hanayaka', serverId = 7, index = 0x405, main = 1, hp = 0, hpp = 0, zone = 102 },
        [1] = { name = 'Tail', serverId = 8, index = 0x406, main = 3, hp = 5, hpp = 1, zone = 102 },
        [6] = { name = 'Far', serverId = 9, index = 0x407, main = 3, hp = 0, hpp = 0, zone = 230 },
    };
    local w = world.new(fakeParty(members), fakeEntities({}));
    w:refresh();
    t.eq({ w:downed(7), w:downed(8), w:downed(9), w:downed(99) }, { true, false, nil, nil });

    members[1].hp, members[1].hpp = 0, 0;
    members[6].zone = 102;
    w:refresh();
    t.eq({ w:downed(8), w:downed(9) }, { true, true });

    -- A zone not read yet is no proof of being elsewhere: better a wipe missed
    -- than one called while someone is still fighting.
    members[6].zone, members[6].hp, members[6].hpp = 0, 900, 60;
    w:refresh();
    t.eq(w:downed(9), false);
end);

t.test('the local player\'s max HP is read exactly, not estimated', function ()
    local members = {
        [0] = { name = 'Hanayaka', serverId = 7, index = 0x405, main = 1, mainLevel = 75, hp = 750, hpp = 50 },
    };
    local player = { hpMax = 1523 };
    function player:GetHPMax() return self.hpMax; end
    function player:GetBuffs() return {}; end
    local w = world.new(fakeParty(members), fakeEntities({}), player);
    w:refresh();
    t.eq(w:maxHP(7), 1523);

    -- Zoning reads zero; fall back to the estimate.
    player.hpMax = 0;
    t.eq(w:maxHP(7), 1500);
end);

--[[
* Buffs and gear.  The player's own buffs come from IPlayer, the other five
* party members' from IParty's status icons: a byte per icon, with two more
* bits per icon in a 64-bit mask.  No one else's can be read.
--]]
local ROSTER = {
    [0] = { name = 'Hanayaka', serverId = 7, index = 0x405, main = 7, mainLevel = 75 },
    [1] = { name = 'Ninja', serverId = 8, index = 0x406, main = 13, mainLevel = 75 },
    [6] = { name = 'Elsewhere', serverId = 9, index = 0x407, main = 1, mainLevel = 75 },
};

local function iconsOf(ids)
    local icons = {};
    for i = 1, 32 do
        icons[i] = ids[i] or 255;
    end
    return icons;
end

t.test('buffs are read for the player and the rest of their party, and unknown for anyone else', function ()
    local player = { buffs = { 62, 57 } };
    function player:GetBuffs()
        local out = {};
        for i = 1, 32 do
            out[i] = self.buffs[i] or -1;
        end
        return out;
    end
    local party = fakeParty(ROSTER);
    -- Yonin (420) in the second icon: its low byte, and 1 in that icon's pair of mask bits.
    local icons = { serverId = { [0] = 0, [3] = 8 }, low = { [3] = iconsOf({ 57, 164 }) }, mask = { [3] = 4 } };
    party.GetStatusIconsServerId = function (_, i) return icons.serverId[i] or 0; end;
    party.GetStatusIcons = function (_, i) return icons.low[i] or iconsOf({}); end;
    party.GetStatusIconsBitMask = function (_, i) return icons.mask[i] or 0; end;

    local w = world.new(party, fakeEntities({}), player);
    w:refresh();
    t.eq({ w:hasBuff(7, 62), w:hasBuff(7, 57), w:hasBuff(7, 420) }, { true, true, false });
    t.eq({ w:hasBuff(8, 420), w:hasBuff(8, 57), w:hasBuff(8, 164), w:hasBuff(8, 62) }, { true, true, false, false });
    t.eq(w:hasBuff(9, 57), nil);
    t.eq(w:hasBuff(99, 57), nil);

    -- A mask past 2^53 reaches Lua rounded, so no icon's high bits can be trusted.
    icons.mask[3] = 2 ^ 62 + 4;
    w:refresh();
    t.eq(w:hasBuff(8, 420), nil);
    icons.mask[3] = 4;

    -- Readings are taken at each refresh.
    player.buffs = {};
    icons.low[3] = iconsOf({});
    w:refresh();
    t.eq({ w:hasBuff(7, 62), w:hasBuff(8, 420) }, { false, false });
end);

t.test('the player\'s own equipment can be checked for an item; anyone else\'s is unknown', function ()
    -- Earring in inventory (container 0) slot 5, ring in wardrobe (container 8) slot 2.
    local equipped = { [11] = 5, [13] = 8 * 256 + 2 };
    local items = { [0] = { [5] = 13437 }, [8] = { [2] = 15544 } };
    local inventory = {
        GetEquippedItem = function (_, slot) return { Index = equipped[slot] or 0 }; end,
        GetContainerItem = function (_, container, index)
            return { Id = items[container] and items[container][index] or 0 };
        end,
    };
    local w = world.new(fakeParty(ROSTER), fakeEntities({}), nil, nil, inventory);
    w:refresh();
    t.eq({ w:wearing(7, 13437), w:wearing(7, 15544), w:wearing(7, 15273) }, { true, true, false });
    t.eq(w:wearing(8, 13437), nil);

    equipped[13] = nil;
    t.eq(w:wearing(7, 15544), false, 'read as it is now');
end);

t.test('distance is measured between two rendered entities in three dimensions', function ()
    local w = world.new(fakeParty({}), fakeEntities({
        [0x405] = { serverId = 0x0001E240, name = 'Hanayaka', flags = 0x0D, render = 0x200, x = 10, y = 20, z = 1 },
        [0x012] = { serverId = 0x0100A012, name = 'Goblin', flags = 0x10, render = 0x200, x = 13, y = 24, z = 13 },
        [0x013] = { serverId = 0x0100A013, name = 'Hidden', flags = 0x10, render = 0, x = 10, y = 20, z = 1 },
    }));
    w:refresh();

    t.eq(w:distance(0x0001E240, 0x0100A012), 13);
    t.eq(w:distance(0x0001E240, 0x0100A013), nil, 'unrendered');
    t.eq(w:distance(0x0001E240, 0x0100AFFF), nil, 'unknown');
end);

t.test('a position is the ground plane, X and Y, of a rendered entity', function ()
    local w = world.new(fakeParty({}), fakeEntities({
        [0x012] = { serverId = 0x0100A012, name = 'Goblin', flags = 0x10, render = 0x200, x = 13, y = 24, z = 13 },
        [0x013] = { serverId = 0x0100A013, name = 'Hidden', flags = 0x10, render = 0, x = 10, y = 20, z = 1 },
    }));
    w:refresh();

    t.eq({ w:position(0x0100A012) }, { 13, 24 });
    t.eq({ w:position(0x0100A013) }, {}, 'unrendered');
    t.eq({ w:position(0x0100AFFF) }, {}, 'unknown');
end);

t.test('the alliance lists every member\'s server id, slot order', function ()
    local w = world.new(fakeParty({
        [9] = { name = 'Nine', serverId = 0x0001E249, index = 0x409 },
        [0] = { name = 'Hanayaka', serverId = 0x0001E240, index = 0x405 },
        [3] = { name = 'Zoning', serverId = 0, index = 0 },
    }), fakeEntities({}));
    w:refresh();
    t.eq(w:alliance(), { 0x0001E240, 0x0001E249 });
end);

t.test('a pet\'s owner is the alliance member whose entity names its index; anyone else\'s pet has none', function ()
    local w = world.new(fakeParty({
        [0] = { name = 'Hanayaka', serverId = 0x0001E240, index = 0x405 },
        [1] = { name = 'Tail', serverId = 0x0001E241, index = 0x406 },
    }), fakeEntities({
        [0x405] = { serverId = 0x0001E240, name = 'Hanayaka', flags = 0x0D, render = 0x200, pet = 0 },
        [0x406] = { serverId = 0x0001E241, name = 'Tail', flags = 0x0D, render = 0x200, pet = 0x030 },
        [0x030] = { serverId = 0x0100A030, name = 'Carbuncle', flags = 0x100, render = 0x200 },
        [0x031] = { serverId = 0x0100A031, name = 'Fenrir', flags = 0x100, render = 0x200 },
        [0x420] = { serverId = 0x0001E999, name = 'Stranger', flags = 0x01, render = 0x200, pet = 0x031 },
    }));
    w:refresh();
    t.eq(w:petOwner(0x0100A030), 0x0001E241);
    t.eq(w:petOwner(0x0100A031), nil, 'a stranger\'s pet');
    t.eq(w:petOwner(0x0100A032), nil, 'nobody holds it');
    t.eq(w:petOwner(nil), nil);
end);

-- Fake ITarget: slot 0 holds the sub-target while one is up, pushing the main target to slot 1.
local function fakeTarget(main, sub)
    return {
        GetIsSubTargetActive = function () return sub and 1 or 0; end,
        GetTargetIndex = function (_, slot)
            if sub ~= nil then
                return slot == 0 and sub or main;
            end
            return slot == 0 and main or 0;
        end,
    };
end

local TARGET_ENTITIES = {
    [0x012] = { serverId = 0x0100A012, name = 'Goblin', flags = 0x10, render = 0x200 },
    [0x405] = { serverId = 0x0001E240, name = 'Hanayaka', flags = 0x0D, render = 0x200 },
};

t.test('the player\'s target is read as a server id, the main one even while sub-targeting', function ()
    local w = world.new(fakeParty({}), fakeEntities(TARGET_ENTITIES), nil, fakeTarget(0x012));
    t.eq(w:target(), 0x0100A012);

    w = world.new(fakeParty({}), fakeEntities(TARGET_ENTITIES), nil, fakeTarget(0x012, 0x405));
    t.eq(w:target(), 0x0100A012);

    w = world.new(fakeParty({}), fakeEntities(TARGET_ENTITIES), nil, fakeTarget(0));
    t.eq(w:target(), nil);

    -- An index nobody holds.
    w = world.new(fakeParty({}), fakeEntities(TARGET_ENTITIES), nil, fakeTarget(0x099));
    t.eq(w:target(), nil);
end);

t.test('the zone comes from the party data, and an index names its entity', function ()
    local w = world.new(fakeParty({ [0] = { name = 'Hanayaka', serverId = 0x0001E240, index = 0x405, zone = 110 } }), fakeEntities({
        [0x012] = { serverId = 0x0100A012, name = 'Teratornis', flags = 0x10, render = 0x200 },
    }));
    t.eq(w:zone(), 110);
    t.eq({ w:entityAt(0x012) }, { 0x0100A012, 'Teratornis' });
    t.eq({ w:entityAt(0x013) }, {});
    t.eq({ w:entityAt(0) }, {});
    t.eq({ w:entityAt(nil) }, {});
    local unzoned = world.new(fakeParty({}), fakeEntities({}));
    t.eq(unzoned:zone(), nil);
end);

t.test('a rendered member reads as resting by entity status; one out of sight is unknown', function ()
    local w = world.new(fakeParty({
        [0] = { name = 'Hanayaka', serverId = 0x0001E240, index = 0x405 },
        [1] = { name = 'Tail', serverId = 0x0001E241, index = 0x406 },
        [2] = { name = 'Far', serverId = 0x0001E242, index = 0x407 },
    }), fakeEntities({
        [0x405] = { serverId = 0x0001E240, name = 'Hanayaka', flags = 0x0D, render = 0x200, status = 33 },
        [0x406] = { serverId = 0x0001E241, name = 'Tail', flags = 0x0D, render = 0x200, status = 0 },
        [0x407] = { serverId = 0x0001E242, name = 'Far', flags = 0x0D, render = 0, status = 33 },
    }));
    w:refresh();
    t.eq(w:resting(0x0001E240), true);
    t.eq(w:resting(0x0001E241), false);
    t.eq(w:resting(0x0001E242), nil);
    t.eq(w:resting(0x0001E999), nil);
end);

t.test('a rendered mob reads as engaged or not; one out of sight is unknown', function ()
    local w = world.new(fakeParty({}), fakeEntities({
        [0x012] = { serverId = 0x0100A012, name = 'Fighting', flags = 0x10, render = 0x200, status = 1 },
        [0x013] = { serverId = 0x0100A013, name = 'Idle', flags = 0x10, render = 0x200, status = 0 },
        [0x014] = { serverId = 0x0100A014, name = 'Hidden', flags = 0x10, render = 0, status = 1 },
    }));
    w:refresh();
    t.eq(w:inCombat(0x0100A012), true);
    t.eq(w:inCombat(0x0100A013), false);
    t.eq(w:inCombat(0x0100A014), nil);
    t.eq(w:inCombat(0x0100AFFF), nil);
end);

return t.done();

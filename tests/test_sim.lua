--[[
* The deterministic sim: parsed packets in, per-mob hate lists out, against a
* fake world.  Hate list arithmetic itself is covered by test_hatelist; these
* check which observations reach which list, and with what inputs.
*
* Run: luajit tests/test_sim.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local sim = require('sim');

local TANK, HEALER, DD = 0x0001E240, 0x0001E241, 0x0001E242;
local STRANGER = 0x0001E999;
local MOB, MOB2 = 0x0100A012, 0x0100A013;

--[[
* A world with a PLD/WAR tank (75), a WHM/BLM healer (75), a NIN/WAR DD (30),
* a stranger and two mobs.
* distances[id] is that actor's distance from every mob; absent is unknown.
* engagedIds[id] is whether a mob shows as in combat: absent is not, and
* 'unknown' is a mob not rendered.
* buffReadings[id][status] is what the party's buff icons show: absent is
* unreadable.  worn[id][item] is the same for equipment.
* positions[id] is { x, y } on the ground plane: absent is not rendered.  Two
* actors both placed are as far apart as their positions say.
--]]
local function fakeWorld()
    local w = {
        maxHPs = { [TANK] = 1500, [HEALER] = 900, [DD] = 600 },
        zoneId = 110,   -- Rolanberry Fields: a Signet region
        distances = {},
        engagedIds = {},
        buffReadings = {},
        worn = {},
        positions = {},
        downs = {},     -- id -> what the roster reads: down, up, or nil for no reading
        ids = {
            [TANK] = { kind = 'alliance', name = 'Tank', member = { mainJob = 'PLD', subJob = 'WAR', mainLevel = 75 } },
            [HEALER] = { kind = 'alliance', name = 'Healer', member = { mainJob = 'WHM', subJob = 'BLM', mainLevel = 75 } },
            [DD] = { kind = 'alliance', name = 'Dd', member = { mainJob = 'NIN', subJob = 'WAR', mainLevel = 30 } },
            [STRANGER] = { kind = 'player', name = 'Stranger' },
            [MOB] = { kind = 'mob', name = 'Goblin' },
            [MOB2] = { kind = 'mob', name = 'Bat' },
        },
    };
    function w:resolve(id) return self.ids[id]; end
    function w:zone() return self.zoneId; end
    function w:maxHP(id) return self.maxHPs[id]; end
    function w:distance(a, b)
        local pa, pb = self.positions[a], self.positions[b];
        if pa ~= nil and pb ~= nil then
            return math.sqrt((pa[1] - pb[1]) ^ 2 + (pa[2] - pb[2]) ^ 2);
        end
        return self.distances[a];
    end
    function w:position(id)
        local p = self.positions[id];
        if p ~= nil then
            return p[1], p[2];
        end
    end
    -- One table, refilled, as the real roster's is shared: asking allocates nothing.
    local out = {};
    function w:alliance()
        for i = #out, 1, -1 do
            out[i] = nil;
        end
        for id, r in pairs(self.ids) do
            if r.kind == 'alliance' then
                out[#out + 1] = id;
            end
        end
        table.sort(out);
        return out;
    end
    -- Nil when the member's icons can't be read, as the roster's is; false when read and absent.
    function w:hasBuff(id, status)
        local readings = self.buffReadings[id];
        if readings == nil then
            return nil;
        end
        return readings[status] == true;
    end
    function w:downed(id) return self.downs[id]; end
    function w:wearing(id, item) return self.worn[id] and self.worn[id][item]; end
    function w:inCombat(id)
        local engaged = self.engagedIds[id];
        if engaged == 'unknown' then
            return nil;
        end
        return engaged or false;
    end
    return w;
end

-- Every mob is level 74-76, sampled at 75: damage divisor 52.
local function levels()
    return 74, 76;
end

local function noLevels()
    return nil;
end

local function new(w)
    return sim.new(w or fakeWorld(), { levelRange = levels });
end

local function action(actor, category, param, targets)
    local out = { kind = 'action', actorId = actor, category = category, param = param, targets = {} };
    for i, tg in ipairs(targets) do
        local results = {};
        for j, r in ipairs(tg[2]) do
            results[j] = { message = r[1], param = r[2], reaction = 0 };
            if r[3] ~= nil then
                results[j].addEffect = { message = r[3][1], param = r[3][2], kind = r[3][3] };
            end
            if r[4] ~= nil then
                results[j].spikes = { message = r[4][1], param = r[4][2] };
            end
        end
        out.targets[i] = { id = tg[1], results = results };
    end
    return out;
end

local function values(s, mob, id)
    local list = s:list(mob);
    if list == nil then
        return nil;
    end
    return { list:get(id) };
end

t.test('a melee round accrues per hit, misses add nothing, and the opener gets the bonus', function ()
    local s = new();
    -- 34: 52/156 (+200/900); 20: 30/92; 15 is a miss.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 34 }, { 15, 0 }, { 67, 20 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 282, 1148, true });
end);

t.test('a missed opening swing still claims the mob: the swinger opens the list and cures count', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 15, 0 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 200, 900, true });

    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(s, MOB, DD), { 153, 461, true });

    s:observe(action(HEALER, 4, 1, { { TANK, { { 7, 300 } } } }), 0);
    t.eq(values(s, MOB, HEALER), { 218, 1309, true });
end);

t.test('an offensive spell or an ability with table enmity adds it and claims the mob, landing or not', function ()
    local s = new();
    -- Paralyze (spell 58, 1/320) resisted: message 85.
    s:observe(action(HEALER, 4, 58, { { MOB, { { 85, 0 } } } }), 0);
    t.eq(values(s, MOB, HEALER), { 201, 1220, true });
    t.eq(s:list(MOB).claimed, true);

    -- Provoke (ability 35, 1/1800) on a fresh mob.
    s:observe(action(TANK, 6, 35, { { MOB2, { { 100, 0 } } } }), 0);
    t.eq(values(s, MOB2, TANK), { 201, 2700, true });

    -- Gauge (ability 53) carries no enmity and claims nothing.
    local s2 = new();
    s2:observe(action(DD, 6, 53, { { MOB, { { 100, 0 } } } }), 0);
    t.eq(s2:list(MOB), nil);
end);

t.test('a spell the mob\'s shadows absorb adds none of its table enmity, but still claims', function ()
    local s = new();
    -- Paralyze (spell 58) on a mob, message 31: ShadowAbsorb.
    s:observe(action(HEALER, 4, 58, { { MOB, { { 31, 1 } } } }), 0);
    t.eq(values(s, MOB, HEALER), { 200, 900, true });
    t.eq(s:track(MOB).trust[HEALER], nil);
end);

t.test('an outsider\'s missed swing occupies and claims the list', function ()
    local s = new();
    s:observe(action(STRANGER, 1, 0, { { MOB, { { 15, 0 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 153, 461, true });
    t.eq(s:list(MOB).claimed, true);
end);

t.test('skillchain damage accrues to the actor that closed it, absorbed or not', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 1 } } } }), 0); -- 201 / 904
    -- Weaponskill 100 (153/461) closing Light (288) for 200 (307/923).
    s:observe(action(TANK, 3, 17, { { MOB, { { 185, 100, { 288, 200 } } } } }), 0);
    t.eq(values(s, MOB, TANK), { 661, 2288, true });
    -- Absorbed Fragmentation (388) for 50: still 76/230.
    s:observe(action(TANK, 3, 17, { { MOB, { { 188, 0, { 388, 50 } } } } }), 0);
    t.eq(values(s, MOB, TANK), { 738, 2522, true });
end);

t.test('a hit for zero and a missed weaponskill still count as one damage; a resisted nuke does not', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0); -- 353 / 1361
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 0 } } } }), 0);   -- +1 / +4
    s:observe(action(TANK, 3, 17, { { MOB, { { 188, 0 } } } }), 0); -- +1 / +4
    s:observe(action(TANK, 4, 144, { { MOB, { { 2, 0 } } } }), 0);  -- nothing
    t.eq(values(s, MOB, TANK), { 355, 1369, true });
end);

t.test('a member whose level cannot be read takes the alliance\'s highest, for damage on a mob without a range and for cures', function ()
    -- Jobs hidden from the party list read as no job and level 0.
    local w = fakeWorld();
    w.ids[DD].member.mainLevel = 0;
    local s = sim.new(w, { levelRange = noLevels });
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    -- The tank's 75, divisor 52, not level 1's 6.
    t.eq(values(s, MOB, DD), { 353, 1361, true });

    local known = sim.new(fakeWorld(), { levelRange = noLevels });
    known.world.ids[DD].member.mainLevel = 75;
    known:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(known, MOB, DD), values(s, MOB, DD));
    s:observe(action(HEALER, 4, 4, { { DD, { { 7, 500 } } } }), 0);
    known:observe(action(HEALER, 4, 4, { { DD, { { 7, 500 } } } }), 0);
    t.eq(values(s, MOB, HEALER), values(known, MOB, HEALER));
    t.truthy(values(s, MOB, HEALER)[1] > 0, 'the cure counted');
end);

t.test('weaponskill, ranged, magic and ability damage all accrue', function ()
    local s = new();
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 1 } } } }), 0);
    local before = values(s, MOB, DD);
    s:observe(action(DD, 3, 17, { { MOB, { { 185, 100 } } } }), 0);
    s:observe(action(DD, 2, 0, { { MOB, { { 352, 100 } } } }), 0);
    s:observe(action(DD, 4, 144, { { MOB, { { 252, 100 } } } }), 0);
    -- Shield Bash (ability 46) adds its 450/900 on top.
    s:observe(action(DD, 6, 46, { { MOB, { { 110, 100 } } } }), 0);
    t.eq(values(s, MOB, DD), { before[1] + 4 * 153 + 450, before[2] + 4 * 461 + 900, true });
end);

t.test('a damaging ability sent in the weaponskill category is known by its message, and counts as the ability', function ()
    -- The server puts Shield Bash, Weapon Bash and the Jumps in category 3 with
    -- the job ability messages; 46 there is Shield Bash, not a weaponskill.
    local s = new();
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 1 } } } }), 0);
    local before = values(s, MOB, DD);
    s:observe(action(DD, 3, 46, { { MOB, { { 110, 100 } } } }), 0);
    t.eq(values(s, MOB, DD), { before[1] + 153 + 450, before[2] + 461 + 900, true });
    -- A miss still carries the ability's own enmity, with no damage.
    s:observe(action(DD, 3, 46, { { MOB, { { 158, 0 } } } }), 0);
    t.eq(values(s, MOB, DD), { before[1] + 153 + 900, before[2] + 461 + 1800, true });
    -- A real weaponskill with the same id is still a weaponskill.
    local s2 = new();
    s2:observe(action(DD, 1, 0, { { MOB, { { 1, 1 } } } }), 0);
    local before2 = values(s2, MOB, DD);
    s2:observe(action(DD, 3, 46, { { MOB, { { 185, 100 } } } }), 0);
    t.eq(values(s2, MOB, DD), { before2[1] + 153, before2[2] + 461, true });
end);

t.test('the mob-level divisor uses the midpoint of the level range, or the attacker\'s level without one', function ()
    local s = sim.new(fakeWorld(), { levelRange = function (id) if id == MOB then return 10, 13; end end });
    -- 10-13 -> 11: divisor 12.  80/12*12 = 80, 240/12*12 = 240.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 12 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 280, 1140, true });

    -- No range: the DD's level 30, divisor 24.  80/24*24 = 80, 240/24*24 = 240.
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 24 } } } }), 0);
    t.eq(values(s, MOB2, DD), { 280, 1140, true });
end);

t.test('damage taken lowers CE by damage over the target\'s max HP', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0); -- 815 / 2746
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 150 }, { 15, 0 } } } }), 0); -- 1800*150/1500 = 180
    t.eq(values(s, MOB, TANK), { 635, 2746, true });
    -- A mob's weaponskill and spell take CE too.
    s:observe(action(MOB, 11, 1, { { TANK, { { 185, 75 } } } }), 0);  -- 90
    s:observe(action(MOB, 4, 144, { { TANK, { { 2, 75 } } } }), 0);   -- 90
    t.eq(values(s, MOB, TANK), { 455, 2746, true });
end);

t.test('damage taken without a max HP to divide by is skipped', function ()
    local w = fakeWorld();
    w.maxHPs[TANK] = nil;
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 150 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 815, 2746, true });
end);

t.test('a mob swinging at someone puts them on its list, so the next actor does not open it', function ()
    local s = new();
    s:observe(action(MOB, 1, 0, { { TANK, { { 15, 0 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 0, 0, true });
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(s, MOB, DD), { 153, 461, true });
end);

t.test('a mob\'s area move does not put everyone it hits on its list', function ()
    local s = new();
    s:observe(action(MOB, 11, 1, { { TANK, { { 185, 50 } } } }), 0);
    t.eq(values(s, MOB, TANK), nil);
end);

--[[
* Mob TP moves that reset or lower hate, as the mobskill table has them.
--]]

local RESETS, RESETS_IF_LANDED, LOWERS, LOWERS_IF_LANDED, NOTHING, UNKNOWN = 900, 901, 902, 903, 904, 905;
local SKILLS = {
    [RESETS] = { name = 'death_trap', effect = 'reset', conditional = false, trust = 'lsb' },
    [RESETS_IF_LANDED] = { name = 'hydro_shot', effect = 'reset', conditional = true, trust = 'lsb' },
    [LOWERS] = { name = 'horrid_roar_1', effect = 'reduce', percent = 25, conditional = false, trust = 'lsb' },
    [LOWERS_IF_LANDED] = { name = 'snort', effect = 'reduce', percent = 25, conditional = true, trust = 'lsb' },
    [NOTHING] = { name = 'combo', effect = 'none', trust = 'lsb' },
    [UNKNOWN] = { name = 'sentinel', effect = 'none', trust = 'unknown' },
};

local function skilled(w, opts)
    opts = opts or {};
    opts.levelRange, opts.mobskills = levels, SKILLS;
    return sim.new(w or fakeWorld(), opts);
end

t.test('a mobskill that resets hate zeroes the CE and VE of each member it reaches, landed or not', function ()
    local s = skilled();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353 / 1361
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);              -- 153 / 461
    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100 } } } }), 0);          -- 153 / 461
    s:observe(action(MOB, 11, RESETS, { { TANK, { { 189, 0 } } }, { DD, { { 242, 10 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 0, 0, true }, 'no effect still resets');
    t.eq(values(s, MOB, DD), { 0, 0, true }, 'and keeps its place on the list');
    t.eq(values(s, MOB, HEALER), { 153, 461, true }, 'out of its reach');
end);

t.test('a conditional reset happens only where the move landed, after the CE its damage takes', function ()
    local s = skilled();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353 / 1361
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);              -- 153 / 461
    for _, missed in ipairs({ 15, 30, 31, 85, 188, 189, 282, 284, 324, 354, 655 }) do
        s:observe(action(MOB, 11, RESETS_IF_LANDED, { { TANK, { { missed, 0 } } } }), 0);
    end
    t.eq(values(s, MOB, TANK), { 353, 1361, true }, 'missed, evaded, absorbed, resisted, no effect');
    s:observe(action(MOB, 11, RESETS_IF_LANDED, { { TANK, { { 185, 30 } } }, { DD, { { 242, 4 } } } }), 0);
    t.eq({ values(s, MOB, TANK), values(s, MOB, DD) }, { { 0, 0, true }, { 0, 0, true } });
end);

t.test('a mobskill that lowers hate takes its percent of both CE and VE, landed where it must', function ()
    local s = skilled();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353 / 1361
    s:observe(action(MOB, 11, LOWERS, { { TANK, { { 189, 0 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 265, 1021, true });
    s:observe(action(MOB, 11, LOWERS_IF_LANDED, { { TANK, { { 188, 0 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 265, 1021, true });
    -- 1800 * 75 / 1500 = 90 first: 175, then a quarter of each.
    s:observe(action(MOB, 11, LOWERS_IF_LANDED, { { TANK, { { 185, 75 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 132, 766, true });
end);

t.test('a mobskill with no effect, unknown, or not in the table leaves hate alone', function ()
    local s = skilled();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353 / 1361
    for _, skill in ipairs({ NOTHING, UNKNOWN, 777 }) do
        s:observe(action(MOB, 11, skill, { { TANK, { { 185, 0 } } } }), 0);
    end
    t.eq(values(s, MOB, TANK), { 353, 1361, true });
end);

t.test('a hate reset lands in every particle', function ()
    local f = require('filter').new({ max = 8, jitter = 0 });
    local s = skilled(nil, { filter = f });
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(MOB, 11, RESETS, { { TANK, { { 185, 0 } } } }), 0);
    for lane = 0, f.count do
        t.eq({ s:list(MOB):value(TANK, lane) }, { 0, 0 }, 'lane ' .. lane);
    end
end);

t.test('an outsider opening the list denies the alliance the first-engage bonus', function ()
    local s = new();
    s:observe(action(STRANGER, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 153, 461, true });
    t.eq(values(s, MOB, STRANGER), {}, 'outsiders get no simulated entry');

    local s2 = new();
    s2:observe(action(MOB, 1, 0, { { STRANGER, { { 1, 30 } } } }), 0);
    s2:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(s2, MOB, TANK), { 153, 461, true });
end);

t.test('cure enmity uses the cure target\'s level and lands on every hit mob hating the target', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);

    -- Cure (spell 1) on the tank, level 75: 40/55*300 = 218, 240/55*300 = 1309.
    s:observe(action(HEALER, 4, 1, { { TANK, { { 7, 300 } } } }), 0);
    t.eq(values(s, MOB, HEALER), { 218, 1309, true });
    t.eq(values(s, MOB2, HEALER), { 218, 1309, true });

    -- Cure on the DD, level 30 (the healer is 75): 40/30*90 = 120, 240/30*90 = 720.  Only MOB2 hates the DD.
    s:observe(action(HEALER, 4, 1, { { DD, { { 7, 90 } } } }), 0);
    t.eq(values(s, MOB, HEALER), { 218, 1309, true });
    t.eq(values(s, MOB2, HEALER), { 338, 2029, true });
end);

t.test('an area cure credits each patient\'s healing on the mobs hating that patient', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    -- Curaga (spell 7): the tank for 300 (218/1309), the DD for 90 (120/720).
    s:observe(action(HEALER, 4, 7, { { TANK, { { 7, 300 } } }, { DD, { { 367, 90 } } } }), 0);
    t.eq(values(s, MOB, HEALER), { 218, 1309, true });
    t.eq(values(s, MOB2, HEALER), { 120, 720, true });

    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(HEALER, 4, 7, { { TANK, { { 7, 300 } } }, { DD, { { 367, 90 } } } }), 0);
    t.eq(values(s, MOB, HEALER), { 436, 2618, true });
    t.eq(values(s, MOB2, HEALER), { 458, 2749, true });
end);

t.test('a fixed cure applies its table CE and VE per target healed', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    -- Cure V (spell 5) is fixed at 400/600.
    s:observe(action(HEALER, 4, 5, { { TANK, { { 7, 900 } } } }), 0);
    t.eq(values(s, MOB, HEALER), { 400, 600, true });
end);

t.test('the values setting picks LandSandBoat\'s numbers where the era table differs, at lsb trust', function ()
    -- Rampart (ability 92): era 1/300, LandSandBoat 320/320.  Cure V (spell 5):
    -- era 400/600, LandSandBoat 300/600.  Provoke (35) agrees at 1/1800.
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    local before = values(s, MOB, TANK);
    s:observe(action(TANK, 6, 92, { { TANK, { { 100, 0 } } } }), 0);
    t.eq(values(s, MOB, TANK), { before[1] + 1, before[2] + 300, true });

    local s2 = sim.new(fakeWorld(), { levelRange = levels, values = 'lsb' });
    t.eq(s2.values, 'lsb');
    s2:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s2:observe(action(TANK, 6, 92, { { TANK, { { 100, 0 } } } }), 0);
    t.eq(values(s2, MOB, TANK), { before[1] + 320, before[2] + 320, true });
    s2:observe(action(TANK, 6, 35, { { MOB, { { 100, 0 } } } }), 0);
    t.eq(values(s2, MOB, TANK), { before[1] + 321, before[2] + 2120, true });
    s2:observe(action(HEALER, 4, 5, { { TANK, { { 7, 900 } } } }), 0);
    t.eq(values(s2, MOB, HEALER), { 300, 600, true });
    t.eq(s2:track(MOB).trust[TANK], { ce = { era = 1, lsb = 1, unknown = 0 }, ve = { era = 1, lsb = 1, unknown = 0 } });
    t.eq(s2:track(MOB).trust[HEALER], { ce = { era = 0, lsb = 1, unknown = 0 }, ve = { era = 0, lsb = 1, unknown = 0 } });

    -- It switches mid-session, and anything else reads as era.
    s2:setValues('era');
    s2:observe(action(TANK, 6, 92, { { TANK, { { 100, 0 } } } }), 0);
    t.eq(values(s2, MOB, TANK), { before[1] + 322, before[2] + 2420, true });
    s2:setValues('nonsense');
    t.eq(s2.values, 'era');
    s2:setValues('lsb');
    t.eq(s2.values, 'lsb');
end);

t.test('resting ticks every ten seconds from the sit, the first idle, each after it a cure on every claimed list holding the rester', function ()
    local w = fakeWorld();
    w.buffReadings[TANK] = {};
    local s = sim.new(w, { levelRange = levels, values = 'lsb' });
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0); -- 353 / 1361
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observeRest(TANK, true, 10);
    s:advance(29.9);
    t.eq(values(s, MOB, TANK)[1], 353);
    s:advance(30);
    -- 10 HP at level 75, cure divisor 55: 40/55 and 240/55 of it, once decay has taken all the VE.
    t.eq(values(s, MOB, TANK), { 360, 43, true });
    t.eq(s:list(MOB2):has(TANK), false, 'only lists holding the rester');
    s:advance(40);
    -- 11 HP the tick after.
    t.eq(values(s, MOB, TANK), { 368, 48, true });
    s:observeRest(TANK, false, 45);
    s:advance(60);
    t.eq(values(s, MOB, TANK), { 368, 0, true });
    -- Sitting again starts the clock again.
    s:observeRest(TANK, true, 60);
    s:advance(79.9);
    t.eq(values(s, MOB, TANK)[1], 368);
    s:advance(80);
    t.eq(values(s, MOB, TANK)[1], 375);
end);

t.test('under Signet or Sigil a resting tick heals by level and max HP, as read when the rester sat', function ()
    local w = fakeWorld();
    w.buffReadings[TANK] = { [253] = true };
    local s = sim.new(w, { levelRange = levels, values = 'lsb' });
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observeRest(TANK, true, 0);
    s:advance(20);
    -- 10 + 3 * 7 + 0 * (1 + 1500 / 300) = 31 HP: 22 / 135, on the 161 VE decay left.
    t.eq(values(s, MOB, TANK), { 375, 296, true });
    s:advance(30);
    -- 37 HP: 26 / 161.
    t.eq(values(s, MOB, TANK), { 401, 161, true });
end);

t.test('on Horizon a resting tick heals the measured 35 + 4 a tick, or 48 + 6 under Signet', function ()
    local w = fakeWorld();
    w.buffReadings[TANK] = { [253] = true };
    w.buffReadings[DD] = {};
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observeRest(TANK, true, 0);
    s:observeRest(DD, true, 0);
    s:advance(20);
    -- The tank under Signet: 48 HP, then 6 a tick.  The ninja, level 30 and
    -- second onto the list, without: 35 HP, then 4 a tick, on its own
    -- level's divisor of 30.
    t.eq(values(s, MOB, TANK), { 353 + 34, 161 + 209, true });
    t.eq(values(s, MOB, DD), { 153 + 46, 280, true });
    s:advance(30);
    t.eq(values(s, MOB, TANK), { 353 + 34 + 39, 235, true });
    t.eq(values(s, MOB, DD), { 153 + 46 + 52, 312, true });
end);

t.test('Signet is assumed in its regions when icons can\'t be read, Sigil in the fronts, and neither elsewhere', function ()
    local function restAt(zone, readings)
        local w = fakeWorld();
        w.zoneId = zone;
        w.buffReadings[TANK] = readings;
        local s = sim.new(w, { levelRange = levels, values = 'lsb' });
        s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
        s:observeRest(TANK, true, 0);
        s:advance(20);
        return values(s, MOB, TANK)[1] - 353;
    end
    -- Rolanberry Fields, icons unreadable: Signet's 31 HP, 22 CE.
    t.eq(restAt(110, nil), 22);
    -- Readable and showing Signet, or Sigil in Rolanberry Fields [S].
    t.eq(restAt(110, { [253] = true }), 22);
    t.eq(restAt(91, { [268] = true }), 22);
    t.eq(restAt(91, nil), 22);
    -- Readable and showing neither, or the wrong one for the region: 10 HP, 7 CE.
    t.eq(restAt(110, {}), 7);
    t.eq(restAt(110, { [268] = true }), 7);
    t.eq(restAt(91, { [253] = true }), 7);
    -- Al Zahbi: Aht Urhgan is Sanction's, which adds nothing, Signet icon or not.
    t.eq(restAt(48, { [253] = true }), 7);
    t.eq(restAt(48, nil), 7);
    -- A zone the table lacks: no bonus.
    t.eq(restAt(9999, nil), 7);
end);

t.test('a resting tick counts nothing out of range, or for someone on no list', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    w.distances[TANK] = 30;
    s:observeRest(TANK, true, 0);
    s:observeRest(DD, true, 0);
    s:advance(20);
    t.eq(values(s, MOB, TANK)[1], 353);
    t.eq(s:list(MOB):has(DD), false);
end);

t.test('an ability that heals by formula generates cure enmity', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    -- Curing Waltz (ability 190) on the tank.
    s:observe(action(DD, 14, 190, { { TANK, { { 102, 300 } } } }), 0);
    t.eq(values(s, MOB, DD), { 218, 1309, true });
end);

t.test('a cure generates nothing on a mob that has not been damaged', function ()
    local s = new();
    s:observe(action(MOB, 1, 0, { { TANK, { { 15, 0 } } } }), 0);
    s:observe(action(HEALER, 4, 1, { { TANK, { { 7, 300 } } } }), 0);
    t.eq(values(s, MOB, HEALER), {});
end);

t.test('a spell that is not a cure heals no enmity here', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    -- Regen (spell 108) reports no heal message on cast, but guard against any.
    s:observe(action(HEALER, 4, 108, { { TANK, { { 7, 300 } } } }), 0);
    t.eq(values(s, MOB, HEALER), {});
end);

t.test('an action on allies credits the actor, once per ally, on every claimed mob already hating them', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);   -- 353 / 1361
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);  -- 353 / 1361
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);    -- 153 / 461

    -- Warcry (ability 32, 1/300) on the tank and the DD.
    s:observe(action(TANK, 6, 32, { { TANK, { { 100, 0 } } }, { DD, { { 100, 0 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 355, 1961, true });
    t.eq(values(s, MOB2, TANK), { 355, 1961, true });
    t.eq(values(s, MOB2, DD), { 153, 461, true }, 'the allies it lands on gain nothing');

    -- Protect (spell 43, 1/80) from a healer no mob hates.
    s:observe(action(HEALER, 4, 43, { { TANK, { { 230, 20 } } } }), 0);
    t.eq({ values(s, MOB, HEALER), values(s, MOB2, HEALER) }, { {}, {} });

    -- Haste (spell 57, 1/300) from the DD, on only the mob hating the DD.
    s:observe(action(DD, 4, 57, { { TANK, { { 230, 33 } } } }), 0);
    t.eq(values(s, MOB2, DD), { 154, 761, true });
    t.eq(values(s, MOB, DD), {});
end);

t.test('an action on allies does nothing on a mob that has only swung at the actor', function ()
    local s = new();
    s:observe(action(MOB, 1, 0, { { DD, { { 15, 0 } } } }), 0);
    s:observe(action(DD, 6, 32, { { DD, { { 100, 0 } } } }), 0);
    t.eq(values(s, MOB, DD), { 0, 0, true });
end);

--[[
* Horizon's buff overlays.  CE never decays, so these check CE alone.
--]]

local SENTINEL, DEFENDER, YONIN = 62, 57, 420;

local function ce(s, mob, id)
    return (s:list(mob):get(id));
end

t.test('Sentinel seen in use doubles the paladin\'s gains for 30 seconds, its own enmity included', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353
    -- Sentinel's 1/900, doubled: VE 1361 less two ticks' decay, plus 1800.
    s:observe(action(TANK, 6, 48, { { TANK, { { 100, 0 } } } }), 1);
    t.eq(values(s, MOB, TANK), { 355, 3113, true });
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 2);            -- 153 x 2
    t.eq(ce(s, MOB, TANK), 661);
    s:observe(action(TANK, 6, 35, { { MOB, { { 100, 0 } } } }), 30.9);        -- Provoke 1 x 2
    t.eq(ce(s, MOB, TANK), 663);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 31.1);         -- worn off: 153
    t.eq(ce(s, MOB, TANK), 816);
end);

t.test('Enlight gives a paladin +10, counting on its own cast, and its light damage on each landed swing says whether it is still up', function ()
    local w = fakeWorld();
    local s = new(w);
    local LIT = { 163, 20, 7 };   -- added effect: 20 light damage, kind 7
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353 / 1361
    -- Seen engaged, the mob's list lasts the minutes this takes.
    s:observeEntity(MOB, 1, false, 0.5);
    -- Enlight's 44/132 at +10: 48/145, on 1361 less two ticks.
    s:observe(action(TANK, 4, 310, { { TANK, { { 230, 0 } } } }), 1);
    t.eq(values(s, MOB, TANK), { 401, 1361 - 48 + 145, true });
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100, LIT } } } }), 2);       -- 153 x 1.1 = 168
    t.eq(ce(s, MOB, TANK), 569);
    -- Swings a minute apart, each carrying the light, keep it up past the 180 s the cast alone would give.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100, LIT } } } }), 60);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100, LIT } } } }), 120);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100, LIT } } } }), 175);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100, LIT } } } }), 230);
    t.eq(ce(s, MOB, TANK), 569 + 4 * 168);
    -- A landed swing without it: the effect ran out of damage.  That swing was
    -- still judged at +10; the next is not.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 240);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 241);
    t.eq(ce(s, MOB, TANK), 569 + 5 * 168 + 153);
    -- A miss says nothing either way.
    s:observe(action(TANK, 4, 310, { { TANK, { { 230, 0 } } } }), 242);
    s:observe(action(TANK, 1, 0, { { MOB, { { 15, 0 } } } }), 243);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 244);
    t.eq(ce(s, MOB, TANK), 569 + 5 * 168 + 153 + 48 + 168);
    -- A recast never seen shows in the swings: the lit swing itself was judged without it, the next with.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 250);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100, LIT } } } }), 260);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100, LIT } } } }), 261);
    t.eq(ce(s, MOB, TANK), 569 + 5 * 168 + 153 + 48 + 168 + 153 + 153 + 168);
    -- Light on a swing from anyone but a paladin main is not Enlight's, and adds nothing.
    w.ids[HEALER].member.mainJob, w.ids[HEALER].member.subJob = 'RDM', 'WHM';
    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100, LIT } } } }), 300);
    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100, LIT } } } }), 301);
    t.eq(ce(s, MOB, HEALER), 306);
end);

t.test('a buff the party icons show applies without its use being seen, and stops when they stop', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353
    w.buffReadings[TANK] = { [SENTINEL] = true };
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 1);            -- 306
    t.eq(ce(s, MOB, TANK), 659);
    w.buffReadings[TANK] = { [SENTINEL] = false };
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 2);            -- 153
    t.eq(ce(s, MOB, TANK), 812);
end);

t.test('a buff seen used outlasts icons that trail it, and ends early once they have shown it and lost it', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353
    w.buffReadings[TANK] = { [SENTINEL] = false };
    s:observe(action(TANK, 6, 48, { { TANK, { { 100, 0 } } } }), 1);          -- 2
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 1.5);          -- not showing yet: 306
    t.eq(ce(s, MOB, TANK), 661);

    -- Shown, then gone between the paladin's actions: dispelled.
    w.buffReadings[TANK][SENTINEL] = true;
    s:advance(2);
    w.buffReadings[TANK][SENTINEL] = false;
    s:advance(3);
    w.buffReadings[TANK] = nil;
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 4);            -- 153
    t.eq(ce(s, MOB, TANK), 814);
end);

t.test('a buff adds only for the jobs it applies to, and never scales a loss', function ()
    local w = fakeWorld();
    local s = new(w);
    -- The healer's WHM/BLM gets nothing from Sentinel.
    w.buffReadings[HEALER] = { [SENTINEL] = true };
    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(ce(s, MOB, HEALER), 353);

    -- Yonin is +10 for a NIN main: 353 x 1.1.
    w.buffReadings[DD] = { [YONIN] = true };
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    t.eq(ce(s, MOB2, DD), 388);
    w.ids[TANK].member.subJob = 'NIN';
    w.buffReadings[TANK] = { [YONIN] = true };
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    t.eq(ce(s, MOB2, TANK), 153);

    -- Sentinel is +50 for a PLD sub: 153 x 1.5.  Release's -10 stays -10.
    w.ids[HEALER].member.mainJob, w.ids[HEALER].member.subJob = 'BST', 'PLD';
    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(ce(s, MOB, HEALER), 582);
    s:observe(action(HEALER, 6, 90, { { HEALER, { { 100, 0 } } } }), 0);
    t.eq(ce(s, MOB, HEALER), 572);
end);

t.test('Defender cuts the CE its user loses to damage by a quarter while it lasts', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);            -- 815
    s:observeEntity(MOB, 1, false, 0);
    s:observe(action(TANK, 6, 33, { { TANK, { { 100, 0 } } } }), 0);          -- Defender 1: 816
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 150 } } } }), 1);            -- 180 x 0.75
    t.eq(ce(s, MOB, TANK), 681);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 150 } } } }), 181);          -- worn off: 180
    t.eq(ce(s, MOB, TANK), 501);
end);

t.test('Provoke under Defender gains 250 CE for a warrior main and 180 for a warrior sub', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353
    s:observe(action(TANK, 6, 33, { { TANK, { { 100, 0 } } } }), 0);          -- 1 / 80
    s:observe(action(TANK, 6, 35, { { MOB, { { 100, 0 } } } }), 0);           -- PLD/WAR: 1 + 180 / 1800
    t.eq(values(s, MOB, TANK), { 535, 3241, true });
    w.ids[TANK].member.mainJob, w.ids[TANK].member.subJob = 'WAR', 'PLD';
    s:observe(action(TANK, 6, 35, { { MOB, { { 100, 0 } } } }), 0);           -- WAR/PLD: 1 + 250
    t.eq(ce(s, MOB, TANK), 786);

    -- No Defender, no bonus.
    s:observe(action(DD, 6, 35, { { MOB, { { 100, 0 } } } }), 0);
    t.eq(values(s, MOB, DD), { 1, 1800, true });
end);

t.test('Utsusemi under Yonin is 160 CE and 480 VE instead of its own values', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 353 / 1361
    s:observe(action(DD, 6, 248, { { DD, { { 100, 0 } } } }), 0);            -- Yonin 1 / 600, x 1.1
    s:observe(action(DD, 4, 338, { { DD, { { 230, 3 } } } }), 0);            -- 160 / 480, x 1.1
    t.eq(values(s, MOB, DD), { 530, 2549, true });

    -- Utsusemi: Ni (spell 339) without Yonin keeps its 1/300.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);           -- 153 / 461
    s:observe(action(TANK, 4, 339, { { TANK, { { 230, 3 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 154, 761, true });
end);

t.test('enmity gear the world can see is applied, conditional gear only for its support job', function ()
    local w = fakeWorld();
    local s = new(w);
    local SATTVA_RING, HEALERS_EARRING, MACE_BELT = 15544, 13437, 15273;

    -- Healer's Earring does nothing for a WHM/BLM.
    w.worn[HEALER] = { [HEALERS_EARRING] = true };
    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(ce(s, MOB, HEALER), 353);

    -- Sattva Ring is +5 for anyone.  The swing's claim opens the list first:
    -- 200 x 1.05 truncates to 209, then 153 x 1.05 adds 160.65.
    w.worn[DD] = { [SATTVA_RING] = true, [HEALERS_EARRING] = false };
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    t.eq(ce(s, MOB2, DD), 369);

    -- Earring and belt on a PLD/WHM, -2 each: 153 x 0.96.
    w.ids[TANK].member.subJob = 'WHM';
    w.worn[TANK] = { [HEALERS_EARRING] = true, [MACE_BELT] = true };
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(ce(s, MOB, TANK), 146);
end);

t.test('each list counts the trust tier of every table CE and VE applied to each actor', function ()
    local w = fakeWorld();
    local s = new(w);
    local function tiers(era, lsb, unknown)
        return { era = era, lsb = lsb, unknown = unknown };
    end

    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(s:track(MOB).trust[TANK], nil, 'damage is formula, not table');

    -- Shadowbind (ability 57): CE era, VE lsb.  Hide (ability 43) on self: unknown 0/0.
    s:observe(action(TANK, 6, 57, { { MOB, { { 100, 0 } } } }), 0);
    s:observe(action(TANK, 6, 43, { { TANK, { { 100, 0 } } } }), 0);
    t.eq(s:track(MOB).trust[TANK], { ce = tiers(1, 0, 1), ve = tiers(0, 1, 1) });

    -- Cure V (spell 5) is a fixed cure at era trust, counted once per mob it lands on.
    s:observe(action(HEALER, 4, 5, { { TANK, { { 7, 900 } } } }), 0);
    t.eq(s:track(MOB).trust[HEALER], { ce = tiers(1, 0, 0), ve = tiers(1, 0, 0) });

    -- Utsusemi under Yonin takes the overlay's lsb trust.
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 6, 248, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(DD, 4, 338, { { DD, { { 230, 3 } } } }), 0);
    t.eq(s:track(MOB).trust[DD], { ce = tiers(0, 2, 0), ve = tiers(0, 2, 0) });

    -- Nothing applied from out of range, nothing counted.
    w.distances[TANK] = 33;
    s:observe(action(TANK, 6, 43, { { TANK, { { 100, 0 } } } }), 0);
    t.eq(s:track(MOB).trust[TANK], { ce = tiers(1, 0, 1), ve = tiers(0, 1, 1) });
end);

t.test("a mob's hitbox widens its enmity range: the server measures centre to centre and adds both models", function ()
    local w = fakeWorld();
    w.distances[DD] = 0;     -- opens the list from on top of it
    w.distances[TANK] = 29.0; -- outside a flat 28, inside 28 + 1.6

    -- Without a hitbox the flat 28 applies: the swing claims but adds nothing.
    local s = new(w);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 0, 0, true }, 'on the list, but its damage was dropped');

    -- Jailer of Love ships hitbox 16 in its 0x00E: 1.6 yalms, so its reach is
    -- 29.6 and the same swing counts.
    local s2 = new(w);
    s2:observeEntity(MOB, 0, false, 0, nil, 1.6);
    s2:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s2:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    local ce, ve = s2:list(MOB):get(TANK);
    t.truthy(ce > 0 and ve > 0, 'inside 28 + 1.6, so the damage counted: ' .. ce .. '/' .. ve);

    -- Still bounded: far enough out and the hitbox does not save it.
    w.distances[HEALER] = 40;
    s2:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(s2, MOB, HEALER), { 0, 0, true }, 'beyond 28 + 1.6');

    -- The actor's own hitbox counts too: the server adds both models.
    local s3 = new(w);
    s3:observeHitbox(MOB, 1.6);
    w.distances[TANK] = 30.5;
    s3:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s3:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(s3, MOB, TANK), { 0, 0, true }, 'beyond 28 + 1.6 on the mob alone');

    local s4 = new(w);
    s4:observeHitbox(MOB, 1.6);
    s4:observeHitbox(TANK, 1.0);
    s4:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s4:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    local ce = s4:list(MOB):get(TANK);
    t.truthy(ce > 0, 'inside 28 + 1.6 + 1.0, so the damage counted: ' .. ce);
end);

t.test('actions from beyond enmity range contribute nothing; unknown distance counts', function ()
    local w = fakeWorld();
    w.distances[TANK] = 33;
    w.distances[HEALER] = 28.5;
    w.distances[DD] = 28;
    local s = new(w);

    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 200, 900, true });

    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(s, MOB, DD), { 153, 461, true });

    s:observe(action(HEALER, 4, 1, { { TANK, { { 7, 300 } } } }), 0);
    t.eq(values(s, MOB, HEALER), {});

    w.distances[HEALER] = nil;
    s:observe(action(HEALER, 4, 1, { { TANK, { { 7, 300 } } } }), 0);
    t.eq(values(s, MOB, HEALER), { 218, 1309, true });
end);

t.test('VE decays on the 2.5 Hz tick clock between observations', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0.1); -- 353 / 1361
    s:advance(1.1);  -- ticks at 0.4 and 0.8
    t.eq(values(s, MOB, TANK), { 353, 1313, true });
    -- Decay is applied before the action it precedes: 1313 - 24 (at 1.2) + 461.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 1.3);
    t.eq(values(s, MOB, TANK), { 506, 1750, true });
    s:observeEntity(MOB, 1, false, 1.3);
    -- Floored at zero well within the time a quiet list lasts.
    s:advance(100);
    t.eq(values(s, MOB, TANK), { 506, 0, true });
end);

t.test('a defeated mob\'s list is dropped', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe({ kind = 'message', actorId = TANK, targetId = MOB2, message = 6, param = 0, value = 0 }, 0);
    t.eq(s:list(MOB2), nil);
    t.eq(s:track(MOB2), nil);
    s:observe({ kind = 'message', actorId = MOB, targetId = MOB, message = 20, param = 0, value = 0 }, 0);
    t.eq(s:list(MOB), nil);
end);

t.test('each mob keeps its own list, all of them updated and decayed together', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0.1);  -- 353 / 1361
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 0.1);   -- 353 / 1361
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0.1); -- 153 / 461
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 150 } } } }), 0.1);  -- -180 CE on MOB only
    s:advance(0.5);
    t.eq(values(s, MOB, TANK), { 173, 1337, true });
    t.eq(values(s, MOB, DD), {});
    t.eq(values(s, MOB2, DD), { 353, 1337, true });
    t.eq(values(s, MOB2, TANK), { 153, 437, true });
end);

t.test('the mobs with lists can be listed', function ()
    local s = new();
    t.eq(s:mobs(), {});
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(s:mobs(), { MOB, MOB2 });
end);

t.test('a mob is engaged while its list holds a modelled actor', function ()
    local s = new();
    s:observe(action(STRANGER, 1, 0, { { MOB, { { 1, 10 } } } }), 0);
    t.eq(s:engaged(MOB), false);
    s:observe(action(MOB2, 1, 0, { { DD, { { 15, 0 } } } }), 0);
    t.eq(s:engaged(MOB2), true);
    t.eq(s:engaged(0x0100AFFF), false);
end);

t.test('acting counts the alliance members whose latest offensive action was on each mob', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 10 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 10 } } } }), 0);
    s:observe(action(STRANGER, 1, 0, { { MOB2, { { 1, 10 } } } }), 0);
    t.eq({ s:track(MOB).acting, s:track(MOB2).acting }, { 2, 0 });

    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 10 } } } }), 0);
    t.eq({ s:track(MOB).acting, s:track(MOB2).acting }, { 1, 1 });

    -- Being hit is not acting; nor is healing someone the mob hates.
    s:observe(action(MOB2, 1, 0, { { HEALER, { { 1, 10 } } } }), 0);
    s:observe(action(HEALER, 4, 1, { { TANK, { { 7, 100 } } } }), 0);
    t.eq({ s:track(MOB).acting, s:track(MOB2).acting }, { 1, 1 });

    -- A mob that goes away takes its actors with it.
    s:observe({ kind = 'message', actorId = DD, targetId = MOB2, message = 6, param = 0, value = 0 }, 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 10 } } } }), 0);
    t.eq(s:track(MOB).acting, 2);
end);

t.test('a track remembers when its list last saw an action', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 10 } } } }), 1);
    t.eq(s:track(MOB).lastAction, 1);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 2);
    t.eq(s:track(MOB).lastAction, 2);
    s:advance(3);
    t.eq(s:track(MOB).lastAction, 2);
end);

--[[
* Integrity tiers.  A list is clean when the engage was watched from empty:
* the mob was not already fighting when the list opened, or it was seen idle
* before it started.
--]]

t.test('a list opened on a mob that was not fighting is clean', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(s:track(MOB).clean, true);
end);

t.test('a mob already fighting when first seen is ordering-only, and nobody gets the opening bonus', function ()
    local w = fakeWorld();
    w.engagedIds[MOB] = true;
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(s:track(MOB).clean, false);
    t.eq(values(s, MOB, TANK), { 153, 461, true });
end);

t.test('a mob seen idle and then engaging opens a clean list, but one someone is already on', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observeEntity(MOB, 0, false, 0);
    s:observeEntity(MOB, 1, false, 1);
    w.engagedIds[MOB] = true;
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 1.2);
    t.eq(s:track(MOB).clean, true);
    t.eq(values(s, MOB, TANK), { 153, 461, true });
end);

t.test('a mob leaving view keeps its list, which can no longer be vouched for', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observeEntity(MOB, 0, false, 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observeEntity(MOB, 1, false, 0.4);
    -- LSB sends the same despawn when a mob only leaves the spawn range.
    s:observeEntity(MOB, nil, true, 1);
    t.eq(values(s, MOB, TANK), { 353, 1313, true });
    t.eq(s:track(MOB).clean, false);

    -- Back in view, still fighting: the list carries on as it was.
    s:observeEntity(MOB, 1, false, 30);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 30);
    t.eq(s:track(MOB).clean, false);

    -- Gone and quiet for good: dropped once stale.
    s:observeEntity(MOB, nil, true, 31);
    s:advance(30 + sim.STALE + 1);
    t.eq(s:list(MOB), nil);
end);

t.test('a mob not rendered when its list opens is ordering-only unless its updates say it was idle', function ()
    local w = fakeWorld();
    w.engagedIds[MOB] = 'unknown';
    w.engagedIds[MOB2] = 'unknown';
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(s:track(MOB).clean, false);

    s:observeEntity(MOB2, 0, false, 0);
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    t.eq(s:track(MOB2).clean, true);
    t.eq(values(s, MOB2, TANK), { 353, 1361, true });
end);

t.test('a mob shown dead drops its list', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observeEntity(MOB, 3, false, 1);
    s:observeEntity(MOB2, 2, false, 1);
    t.eq({ s:list(MOB), s:list(MOB2) }, {});
end);

t.test('a mob gone idle drops its list once nothing has happened on it for the grace period', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    -- The engaged update can trail the action that opened the list.
    s:observeEntity(MOB, 0, false, 0.1);
    s:advance(sim.GRACE - 0.5);
    t.truthy(s:list(MOB), 'kept inside the grace period');
    s:observeEntity(MOB, 1, false, sim.GRACE - 0.4);
    s:advance(sim.GRACE + 10);
    t.truthy(s:list(MOB), 'kept while engaged');

    -- A list opened on an idle mob that never engages lasts a grace period
    -- past the later of going idle and the last action.
    local s2 = new();
    s2:observeEntity(MOB, 0, false, 19);
    s2:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 20);
    s2:advance(20 + sim.GRACE - 0.5);
    t.truthy(s2:list(MOB), 'an action after going idle restarts the wait');
    s2:advance(20 + sim.GRACE + 0.5);
    t.eq(s2:list(MOB), nil);
    t.eq(s2:track(MOB), nil);
end);

t.test('a mob going from engaged to idle drops its list at once, as the server clears it', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observeEntity(MOB, 1, false, 0.4);
    s:observeEntity(MOB, 0, false, 10);
    t.eq(s:list(MOB), nil);

    -- Pulled again straight away: a fresh list, opening bonus and all.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 10.2);
    t.eq(values(s, MOB, TANK), { 353, 1361, true });
    t.eq(s:track(MOB).clean, true);
end);

t.test('a list whose mob never reported a status is dropped after a long quiet', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:advance(sim.STALE - 1);
    t.truthy(s:list(MOB), 'kept');
    s:advance(sim.STALE + 1);
    t.eq(s:list(MOB), nil);
end);

t.test('the hate holder is whoever the mob last swung at, and whether the model tracks them', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(s:track(MOB).holder, nil);

    s:observe(action(MOB, 1, 0, { { STRANGER, { { 1, 10 } } } }), 0);
    t.eq({ s:track(MOB).holder, s:track(MOB).holderModelled }, { STRANGER, false });

    -- An area move hits bystanders; it does not say who holds hate.
    s:observe(action(MOB, 11, 1, { { DD, { { 185, 10 } } } }), 0);
    t.eq(s:track(MOB).holder, STRANGER);

    s:observe(action(MOB, 1, 0, { { TANK, { { 15, 0 } } } }), 0);
    t.eq({ s:track(MOB).holder, s:track(MOB).holderModelled }, { TANK, true });

    -- A mob's single-target spell goes to its battle target; an area spell proves nothing.
    s:observe(action(MOB, 4, 144, { { STRANGER, { { 2, 10 } } } }), 0);
    t.eq({ s:track(MOB).holder, s:track(MOB).holderModelled }, { STRANGER, false });
    s:observe(action(MOB, 4, 174, { { TANK, { { 2, 10 } } }, { DD, { { 2, 10 } } } }), 0);
    t.eq(s:track(MOB).holder, STRANGER);
    s:observe(action(MOB, 4, 144, { { TANK, { { 2, 10 } } } }), 0);
    t.eq({ s:track(MOB).holder, s:track(MOB).holderModelled }, { TANK, true });

    s:observe(action(MOB, 1, 0, { { STRANGER, { { 1, 10 } } } }), 0);
    s:observe({ kind = 'message', actorId = MOB, targetId = STRANGER, message = 6, param = 0, value = 0 }, 0);
    t.eq(s:track(MOB).holder, nil);
end);

t.test('names are remembered from when the actor was seen', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 10 } } } }), 0);
    w.ids[TANK] = nil;
    t.eq(s:name(TANK), 'Tank');
    t.eq(s:name(MOB), 'Goblin');
end);

t.test('clearing forgets every list', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 10 } } } }), 0);
    s:observeEntity(MOB2, 0, false, 0);
    s:clear();
    t.eq(s:list(MOB), nil);
    t.eq(s:track(MOB), nil);

    -- Seen idle in the old zone means nothing in the new one.
    local w = fakeWorld();
    w.engagedIds[MOB2] = true;
    s.world = w;
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 10 } } } }), 0);
    t.eq(s:track(MOB2).clean, false);
end);

--[[
* Edge mechanics: the ways enmity moves outside the main formulas.
--]]

local COVER, ISSEKIGAN, TRICK_ATTACK = 79, 291, 76;
local UTSUSEMI_ICHI, UTSUSEMI_NI, BLINK = 338, 339, 53;
local STATUS_COVER, STATUS_COPY_IMAGE_4 = 114, 446;

local function defeated(actor, target)
    return { kind = 'message', actorId = actor, targetId = target, message = actor == target and 20 or 97, param = 0, value = 0 };
end

t.test('a round Cover takes for the paladin adds them 200 CE a hit and a tenth off the covered, with no CE lost to it', function ()
    local s = new();
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 353 / 1361
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);           -- 153 / 461
    s:observe(action(TANK, 6, COVER, { { DD, { { 100, 0 } } } }), 0);        -- 1 / 0
    -- The mob is on the DD, and the paladin takes its round.  A miss moves nothing.
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 150 }, { 15, 0 }, { 1, 60 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 554, 461, true });
    t.eq(values(s, MOB, DD), { 287, 1103, true });
    t.eq({ s:track(MOB).holder, s:track(MOB).holderModelled }, { DD, true });
end);

t.test('a round on the paladin is their own while they top the list, or once Cover has worn off', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);           -- 815 / 2746
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 153 / 461
    s:observe(action(TANK, 6, COVER, { { DD, { { 100, 0 } } } }), 0);        -- 816
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 150 } } } }), 0);           -- -180
    t.eq(values(s, MOB, TANK), { 636, 2746, true });
    t.eq(values(s, MOB, DD), { 153, 461, true });

    -- Cover lasts 50 seconds at the most.  By then VE has decayed away.
    local s2 = new();
    s2:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353
    s2:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);          -- 153
    s2:observe(action(TANK, 6, COVER, { { DD, { { 100, 0 } } } }), 0);       -- 154
    s2:observe(action(MOB, 1, 0, { { TANK, { { 1, 50 } } } }), 51);          -- -60
    t.eq(values(s2, MOB, TANK), { 94, 0, true });
    t.eq(values(s2, MOB, DD), { 353, 0, true });

    -- The party's icons end it sooner.
    local w = fakeWorld();
    local s3 = new(w);
    s3:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353 / 1361
    s3:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);          -- 153 / 461
    s3:observe(action(TANK, 6, COVER, { { DD, { { 100, 0 } } } }), 0);       -- 154
    w.buffReadings[TANK] = { [STATUS_COVER] = true };
    s3:advance(1);
    w.buffReadings[TANK] = { [STATUS_COVER] = false };
    s3:observe(action(MOB, 1, 0, { { TANK, { { 1, 50 } } } }), 2);           -- -60
    t.eq(values(s3, MOB, TANK), { 94, 341, true });
end);

t.test('each parry under Issekigan adds 300 CE on the parrier\'s Enmity, for its 60 seconds', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);           -- 353
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 153
    s:observe(action(DD, 6, ISSEKIGAN, { { DD, { { 100, 0 } } } }), 0);      -- 1 / 0
    -- Two parries and a hit for 30 of the DD's 600 HP: +600, -90.
    s:observe(action(MOB, 1, 0, { { DD, { { 70, 0 }, { 70, 0 }, { 1, 30 } } } }), 0);
    t.eq(ce(s, MOB, DD), 664);

    -- Yonin's +10 scales it.
    w.buffReadings[DD] = { [YONIN] = true };
    s:observe(action(MOB, 1, 0, { { DD, { { 70, 0 } } } }), 1);
    t.eq(ce(s, MOB, DD), 994);

    -- A parry without it adds nothing.
    s:observe(action(MOB, 1, 0, { { TANK, { { 70, 0 } } } }), 1);
    t.eq(ce(s, MOB, TANK), 353);
    s:observe(action(MOB, 1, 0, { { DD, { { 70, 0 } } } }), 60.5);
    t.eq(ce(s, MOB, DD), 994);
end);

t.test('under the LSB rule every Utsusemi shadow absorbed costs 25 CE, the last one too; Blink\'s cost nothing', function ()
    local s = new();
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 353 / 1361
    s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 0); -- 1 / 300
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 }, { 31, 1 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 } } } }), 0);
    t.eq(values(s, MOB, DD), { 279, 1661, true });

    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100 } } } }), 0);         -- 153
    s:observe(action(HEALER, 4, BLINK, { { HEALER, { { 230, 36 } } } }), 0); -- 154
    s:observe(action(MOB, 1, 0, { { HEALER, { { 31, 1 } } } }), 0);
    t.eq(ce(s, MOB, HEALER), 154);

    -- A mob skill's shadows go through script, which takes no CE.
    s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 0); -- 280
    s:observe(action(MOB, 11, 1, { { DD, { { 31, 2 } } } }), 0);
    t.eq(ce(s, MOB, DD), 280);

    -- A single-target spell into a shadow costs it; so does a counter to the DD's own swing.
    s:observe(action(MOB, 4, 144, { { DD, { { 31, 1 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 }, { 0, 0, nil, { 14, 1 } } } } }), 0);
    t.eq(ce(s, MOB, DD), 383);

    -- The loss is the era table's, counted like any table value: two casts and five paid absorbs.
    t.eq(s:track(MOB).trust[DD].ce, { era = 7, lsb = 0, unknown = 0 });
end);

t.test('under the era rule only an absorb that leaves shadows costs CE, counting them from the cast', function ()
    local w = fakeWorld();
    local s = sim.new(w, { levelRange = levels, shadowRule = 'era' });
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 353
    s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 0); -- 354: three
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 }, { 31, 1 }, { 31, 1 } } } }), 0);
    t.eq(ce(s, MOB, DD), 304);

    -- Ni is four on a ninja main: a mob skill takes two, then one leaves one, then the last.
    s:observe(action(DD, 4, UTSUSEMI_NI, { { DD, { { 230, 66 } } } }), 0);   -- 305
    s:observe(action(MOB, 11, 1, { { DD, { { 31, 2 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 } } } }), 0);
    t.eq(ce(s, MOB, DD), 280);

    -- Three on anyone else.
    w.ids[TANK].member.subJob = 'NIN';
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);           -- 153
    s:observe(action(TANK, 4, UTSUSEMI_NI, { { TANK, { { 230, 66 } } } }), 0); -- 154
    s:observe(action(MOB, 1, 0, { { TANK, { { 31, 1 }, { 31, 1 }, { 31, 1 } } } }), 0);
    t.eq(ce(s, MOB, TANK), 104);

    -- Shadows not seen cast: taken to remain.
    s:observe(action(MOB, 1, 0, { { TANK, { { 31, 1 } } } }), 0);
    t.eq(ce(s, MOB, TANK), 79);
end);

t.test('shadows not seen cast are Utsusemi on a ninja, or when the icons show Copy Image, and Blink otherwise', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);           -- 353, PLD/WAR
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 153, NIN/WAR
    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100 } } } }), 0);         -- 153, WHM/BLM
    s:observe(action(MOB, 1, 0, { { TANK, { { 31, 1 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { HEALER, { { 31, 1 } } } }), 0);
    t.eq({ ce(s, MOB, TANK), ce(s, MOB, DD), ce(s, MOB, HEALER) }, { 353, 128, 153 });

    w.ids[TANK].member.subJob = 'NIN';
    w.buffReadings[HEALER] = { [STATUS_COPY_IMAGE_4] = true };
    s:observe(action(MOB, 1, 0, { { TANK, { { 31, 1 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { HEALER, { { 31, 1 } } } }), 0);
    t.eq({ ce(s, MOB, TANK), ce(s, MOB, HEALER) }, { 328, 128 });

    -- Blink seen cast outranks the ninja's job.
    s:observe(action(DD, 4, BLINK, { { DD, { { 230, 36 } } } }), 0);         -- 129
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 } } } }), 0);
    t.eq(ce(s, MOB, DD), 129);
end);

t.test('the mob\'s hate holder dying is cleared from its list; anyone else dying is only deactivated', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);           -- 815 / 2746
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 153 / 461
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 400 } } } }), 0);            -- 815 / 2746
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);          -- 153 / 461

    s:observe(defeated(MOB, TANK), 0);
    t.eq(values(s, MOB, TANK), {});
    t.eq(values(s, MOB2, TANK), { 153, 461, false });

    -- Falling with nobody else active leaves the list open for a new first engage.
    s:observe(defeated(DD, DD), 0);
    t.eq({ values(s, MOB, DD), values(s, MOB2, DD) }, { {}, {} });
    s:observe(action(HEALER, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    t.eq(values(s, MOB2, HEALER), { 353, 1361, true });
end);

t.test('an inactive entry is passed over for hate, and comes back when the mob hits them alive or they act', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);           -- 815 / 2746
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);           -- 1430 / 4592
    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 400 } } } }), 0);         -- 615 / 1846
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 153 / 461
    s:observe(defeated(HEALER, HEALER), 0);
    s:observe(defeated(MOB, TANK), 0);
    t.eq(values(s, MOB, HEALER), { 615, 1846, false });
    t.eq(s:list(MOB):highest(), DD);

    -- Raised and caught in an area move: 10 damage takes 20 CE of 900 HP.
    s:observe(action(MOB, 11, 1, { { DD, { { 185, 10 } } }, { HEALER, { { 185, 10 } } } }), 0);
    t.eq(values(s, MOB, HEALER), { 595, 1846, true });
    t.eq(s:list(MOB):highest(), HEALER);

    s:observe(defeated(DD, DD), 0);
    t.eq(values(s, MOB, DD), { 123, 461, false });
    s:observe(action(DD, 4, 57, { { TANK, { { 230, 33 } } } }), 0);          -- Haste on an ally: 1 / 300
    t.eq(values(s, MOB, DD), { 124, 761, true });
end);

--[[
* Wipes: once nobody in the alliance is left standing, every mob drops them,
* and the next pull starts from nothing.
--]]

-- Everyone engaged on both mobs, then all three killed; readings as given.
local function wipe(w, s, readings)
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(HEALER, 4, 1, { { TANK, { { 7, 300 } } } }), 0);
    for _, id in ipairs({ TANK, HEALER, DD }) do
        s:observe(defeated(MOB, id), 0.1);
    end
    for id, down in pairs(readings) do
        w.downs[id] = down;
    end
end

t.test('when everyone in the alliance is down, every list is reset at the next tick, once', function ()
    local w = fakeWorld();
    local s = new(w);
    wipe(w, s, { [TANK] = true, [HEALER] = true, [DD] = true });
    t.truthy(s:list(MOB) ~= nil and s:list(MOB2) ~= nil, 'kept until a tick has read the roster');
    s:advance(0.5);
    t.eq({ s:list(MOB), s:list(MOB2), s:track(MOB), s.wipes }, { nil, nil, nil, 1 });
    s:advance(5);
    t.eq(s.wipes, 1, 'lying there is not another wipe');

    -- Raised, pulled again and wiped again.
    w.downs[DD] = false;
    s:advance(6);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 6);
    w.downs[DD] = true;
    s:advance(7);
    t.eq({ s:list(MOB), s.wipes }, { nil, 2 });
end);

t.test('anyone left standing is no wipe; a member with no reading counts only by a death seen', function ()
    local w = fakeWorld();
    local s = new(w);
    wipe(w, s, { [TANK] = true, [HEALER] = true, [DD] = false });
    s:advance(0.5);
    t.truthy(s:list(MOB) ~= nil, 'the ninja is up');

    -- A reading says up even though a death was seen: raised.
    s:advance(1);
    t.eq(s.wipes, 0);

    -- No reading for anyone, as when the roster can't be read: the deaths seen decide.
    w.downs = {};
    s:advance(1.5);
    t.eq({ s:list(MOB), s.wipes }, { nil, 1 });
end);

t.test('a member in another zone neither stands for the alliance nor blocks a wipe', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    -- The ninja is elsewhere: no reading, never seen to die.
    w.downs = { [TANK] = true, [HEALER] = true };
    s:advance(0.5);
    t.eq({ s:list(MOB), s.wipes }, { nil, 1 });
end);

t.test('nothing to reset is no wipe', function ()
    local w = fakeWorld();
    local s = new(w);
    w.downs = { [TANK] = true, [HEALER] = true, [DD] = true };
    s:advance(0);
    s:advance(1);
    t.eq(s.wipes, 0);
end);

t.test('after a wipe the next pull opens a clean list with the first-engage bonus', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observeEntity(MOB, 0, false, 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    s:observeEntity(MOB, 1, false, 0.1);
    -- The mob walks off out of view with everyone dead: no idle update ever comes.
    s:observe(defeated(MOB, TANK), 0.2);
    s:observeEntity(MOB, nil, true, 0.3);
    w.downs = { [TANK] = true, [HEALER] = true, [DD] = true };
    s:advance(1);
    t.eq(s.wipes, 1);

    w.downs = { [TANK] = false, [HEALER] = false, [DD] = false };
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 20);
    t.eq(values(s, MOB, TANK), { 353, 1361, true });
    t.eq(s:track(MOB).clean, true);
end);

t.test('a list three minutes without combat with the alliance is reset, but that is no wipe', function ()
    local w = fakeWorld();
    -- A wipe, but the healer reraised: someone reads up, so no wipe by deaths.
    w.downs = { [TANK] = true, [HEALER] = false, [DD] = true };
    local s = new(w);
    s:observeEntity(MOB, 0, false, 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    s:observeEntity(MOB, 1, false, 0.1);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 50 } } } }), 10);
    s:observe(defeated(MOB, TANK), 10);
    -- It goes on to fight an outsider, which is no combat with the alliance.
    s:observe(action(MOB, 1, 0, { { STRANGER, { { 1, 50 } } } }), 150);
    s:advance(189.9);
    t.truthy(s:list(MOB) ~= nil, 'not yet three minutes');
    s:advance(190.5);
    t.eq({ s:list(MOB), s:track(MOB), s.wipes }, { nil, nil, 0 },
        'the list goes, but nobody died, so it is not counted as a wipe');
    s:advance(400);
    t.eq(s.wipes, 0);

    -- The mob reset at home, its updates long gone: the next pull is clean.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 400);
    t.eq(values(s, MOB, TANK), { 353, 1361, true });
    t.eq(s:track(MOB).clean, true);
end);

t.test('the alliance hitting a mob, or being hit by it, keeps its list; a quiet one goes alone beside a live fight', function ()
    local w = fakeWorld();
    w.downs = { [TANK] = false, [HEALER] = false, [DD] = false };
    local s = new(w);
    -- Both reported engaged, so neither goes for its status being unknown.
    s:observeEntity(MOB, 1, false, 0);
    s:observeEntity(MOB2, 1, false, 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 100);          -- MOB hits the tank
    for at = 30, 270, 30 do
        s:observe(action(DD, 1, 0, { { MOB2, { { 1, 10 } } } }), at);         -- MOB2 fought throughout
        s:advance(at + 1);
    end
    t.truthy(s:list(MOB) ~= nil, 'kept past three minutes from the pull by being hit');
    s:advance(281);
    t.eq({ s:list(MOB), s:list(MOB2) ~= nil, s.wipes }, { nil, true, 0 });
end);

t.test('dying wears off the buffs a member was seen to use', function ()
    local w = fakeWorld();
    w.downs = { [HEALER] = false, [DD] = false };   -- the others stand: no wipe
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353
    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    s:observe(action(TANK, 6, 48, { { TANK, { { 100, 0 } } } }), 1);          -- Sentinel
    s:observe(defeated(MOB, TANK), 2);
    -- Raised within Sentinel's 30 seconds: the hit is no longer doubled.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 10);
    t.eq(ce(s, MOB, TANK), 153);
end);

t.test('a reset forgets every list and what each mob was doing', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observeEntity(MOB, 0, false, 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observeEntity(MOB, 1, false, 0.1);
    s:observe(action(TANK, 6, 48, { { TANK, { { 100, 0 } } } }), 1);          -- Sentinel
    s:reset();
    t.eq({ s:list(MOB), s:track(MOB) }, { nil, nil });

    -- Still fighting: what came before the reset is gone, so it can't be vouched for.
    w.engagedIds[MOB] = true;
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 2);
    t.eq(s:track(MOB).clean, false);
    t.eq(ce(s, MOB, TANK), 306, 'Sentinel is still up');
end);

t.test('a melee round under Trick Attack sends its damage enmity to the ally in line in front, and spends it', function ()
    local w = fakeWorld();
    -- The healer is nearer but off the line; the tank is in it, 2 world-angle units off of the 8 allowed.
    w.positions = { [MOB] = { 0, 0 }, [HEALER] = { 1, 1 }, [TANK] = { 2, 0 }, [DD] = { 5, 0.3 } };
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);           -- 353 / 1361
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 153 / 461
    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);   -- 1 / 0
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 }, { 1, 100 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 659, 2283, true });
    t.eq(values(s, MOB, DD), { 154, 461, true });

    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(s, MOB, DD), { 307, 922, true });
end);

--[[
* A THF main with Assassin behind the tank on a clean list.  The server only
* credits a partner it finds in its narrow line; the client's positions are
* coarser, so the round itself says whether one was found.
--]]
local function thief(positions)
    local w = fakeWorld();
    w.ids[DD].member = { mainJob = 'THF', subJob = 'NIN', mainLevel = 75 };
    w.positions = positions or { [MOB] = { 0, 0 }, [TANK] = { 2, 0.9 }, [DD] = { 5, 0 } };
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    return s, w;
end

-- What a round of `results` adds to the dealer, with nobody to hand it to.
local function gainOf(results, category, param)
    local s = thief({});
    local before = values(s, MOB, DD);
    s:observe(action(DD, category or 1, param or 0, { { MOB, results } }), 0);
    local after = values(s, MOB, DD);
    return { after[1] - before[1], after[2] - before[2] };
end

local function gained(s, id, before)
    local after = values(s, MOB, id);
    return { after[1] - before[1], after[2] - before[2] };
end

t.test('a Trick Attack round that crits goes to the best-aligned ally nearer the mob, though off the exact line', function ()
    local s = thief();
    local tank, dd = values(s, MOB, TANK), values(s, MOB, DD);
    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);
    local ta = gained(s, DD, dd);
    s:observe(action(DD, 1, 0, { { MOB, { { 67, 100 }, { 67, 100 } } } }), 0);
    t.eq(gained(s, TANK, tank), gainOf({ { 67, 100 }, { 67, 100 } }));
    t.eq(gained(s, DD, dd), ta, 'the thief keeps only the ability\'s own');
end);

t.test('a Trick Attack round that hits without a crit, or misses, found no partner, whatever the positions say', function ()
    local s = thief({ [MOB] = { 0, 0 }, [TANK] = { 2, 0 }, [DD] = { 5, 0 } });
    local tank = values(s, MOB, TANK);
    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 67, 100 }, { 1, 100 } } } }), 0);
    t.eq(gained(s, TANK, tank), { 0, 0 }, 'a plain hit in the round');
    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 15, 0 }, { 67, 100 } } } }), 0);
    t.eq(gained(s, TANK, tank), { 0, 0 }, 'a miss in the round');
end);

t.test('under Sneak Attack a crit proves nothing and a plain hit no longer rules a partner out; a miss still does', function ()
    local s = thief({ [MOB] = { 0, 0 }, [TANK] = { 2, 0 }, [DD] = { 5, 0 } });
    local tank = values(s, MOB, TANK);
    s:observe(action(DD, 6, 44, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(gained(s, TANK, tank), gainOf({ { 1, 100 } }), 'in line: the hit is the tank\'s');
    tank = values(s, MOB, TANK);
    s:observe(action(DD, 6, 44, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 15, 0 }, { 67, 100 } } } }), 0);
    t.eq(gained(s, TANK, tank), { 0, 0 });
end);

t.test('a weaponskill under Trick Attack, which shows no crit, falls back to an ally near the line, and hands its skillchain over too', function ()
    local results = { { 185, 100, { 288, 200 } } };
    local s = thief();
    local tank, dd = values(s, MOB, TANK), values(s, MOB, DD);
    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);
    local ta = gained(s, DD, dd);
    s:observe(action(DD, 3, 17, { { MOB, results } }), 0);
    t.eq(gained(s, TANK, tank), gainOf(results, 3, 17));
    t.eq(gained(s, DD, dd), ta);

    -- 45 degrees off: too far to guess without a crit.
    s = thief({ [MOB] = { 0, 0 }, [TANK] = { 2, 2 }, [DD] = { 5, 0 } });
    tank = values(s, MOB, TANK);
    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(DD, 3, 17, { { MOB, results } }), 0);
    t.eq(gained(s, TANK, tank), { 0, 0 });
end);

t.test('Sneak Attack is kept across a reload and spent with the round', function ()
    local s = thief({ [MOB] = { 0, 0 }, [TANK] = { 2, 0 }, [DD] = { 5, 0 } });
    s:observe(action(DD, 6, 44, { { DD, { { 100, 0 } } } }), 3);
    t.truthy(s.sneaks[DD] ~= nil);
    t.truthy(s:export().sneaks[DD] ~= nil);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 4);
    t.eq(s.sneaks[DD], nil);
end);

t.test('Trick Attack\'s partner gains on their own Enmity, and takes a weaponskill\'s skillchain too', function ()
    local w = fakeWorld();
    w.positions = { [MOB] = { 0, 0 }, [TANK] = { 2, 0 }, [DD] = { 5, 0.3 } };
    w.buffReadings[TANK] = { [SENTINEL] = true };
    local s = new(w);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 353 / 1361
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);           -- 306 / 922
    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);   -- 354
    -- Weaponskill 100 (153/461) closing Light for 200 (307/923), both doubled.
    s:observe(action(DD, 3, 17, { { MOB, { { 185, 100, { 288, 200 } } } } }), 0);
    t.eq(values(s, MOB, TANK), { 1226, 3690, true });
    t.eq(values(s, MOB, DD), { 354, 1361, true });
end);

t.test('Trick Attack finds no partner too close to the mob, dead, off the line or unplaced, and is spent anyway', function ()
    local w = fakeWorld();
    w.positions = { [MOB] = { 0, 0 }, [HEALER] = { 0.3, 0 }, [TANK] = { 2, 0 }, [DD] = { 0.4, -5 } };
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);           -- 353 / 1361
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 153 / 461
    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);   -- 154
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- off the line: 307
    w.positions[DD] = { 5, 0.3 };
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- spent: 460
    t.eq(values(s, MOB, DD), { 460, 1383, true });

    -- The healer is in line but within half a yalm of the mob; the tank has fallen.
    s:observe(defeated(TANK, TANK), 0);
    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);   -- 461
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 614
    t.eq(ce(s, MOB, DD), 614);

    w.positions[DD] = nil;
    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);   -- 615
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 768
    t.eq(ce(s, MOB, DD), 768);
    t.eq(values(s, MOB, HEALER), {});
end);

--[[
* The particle filter behind the sim: every particle replays each action with
* its own bonuses, and whom a mob attacks reweights them.
--]]

local filter = require('filter');
local CLASS = filter.CLASS;

local function filtered(w, opts)
    math.randomseed(3);
    local f = filter.new(opts or { max = 8, jitter = 0 });
    return sim.new(w or fakeWorld(), { levelRange = levels, filter = f }), f;
end

-- Sets one player's bonus in every particle: `value` in `class`, 0 in the rest.
local function pin(f, id, class, value)
    f:fill(f:row(), id, CLASS.melee, 0);
    local player = f.players[id];
    for lane = 1, f.count do
        for c = 0, filter.CLASSES - 1 do
            f.bonus[(lane * filter.PLAYERS + player) * filter.SLOTS + c] = c == class and value or 0;
        end
    end
end

-- How far particle 1 sits from the neutral replay, CE and VE.
local function gap(s, mob, id)
    local list = s:list(mob);
    if list == nil or not list:has(id) then
        return { 0, 0 };
    end
    local ce0, ve0 = list:value(id, 0);
    local ce1, ve1 = list:value(id, 1);
    return { ce1 - ce0, ve1 - ve0 };
end

--[[
* Which classes of `id`'s bonus change what `act` does to their entry on MOB,
* after `setup`.
--]]
local function classesUsed(id, setup, act, world)
    local used = {};
    for class = 0, filter.CLASSES - 1 do
        local s, f = filtered(world and world());
        -- A refit would redraw the pinned player: this asks about the replay alone.
        s.opts.refit = false;
        pin(f, id, class, 100);
        for _, e in ipairs(setup) do
            s:observe(e, 0);
        end
        local before = gap(s, MOB, id);
        for _, e in ipairs(act) do
            s:observe(e, 0);
        end
        local after = gap(s, MOB, id);
        if after[1] ~= before[1] or after[2] ~= before[2] then
            used[#used + 1] = class;
        end
    end
    return used;
end

t.test('each action is replayed in every particle on that particle\'s bonus for the action\'s class', function ()
    local swing = action(TANK, 1, 0, { { MOB, { { 1, 100 } } } });
    t.eq(classesUsed(TANK, {}, { swing }), { CLASS.melee }, 'melee');
    t.eq(classesUsed(TANK, { swing }, { action(TANK, 3, 17, { { MOB, { { 185, 100, { 288, 200 } } } } }) }),
        { CLASS.weaponskill }, 'weaponskill and its skillchain');
    t.eq(classesUsed(TANK, { swing }, { action(TANK, 2, 0, { { MOB, { { 352, 100 } } } }) }), { CLASS.other }, 'ranged');
    t.eq(classesUsed(TANK, { swing }, { action(TANK, 6, 35, { { MOB, { { 100, 0 } } } }) }), { CLASS.ability }, 'Provoke');
    t.eq(classesUsed(HEALER, { swing }, { action(HEALER, 4, 58, { { MOB, { { 85, 0 } } } }) }), { CLASS.magic }, 'Paralyze');
    t.eq(classesUsed(HEALER, { swing }, { action(HEALER, 4, 1, { { TANK, { { 7, 300 } } } }) }), { CLASS.cure }, 'Cure');
    t.eq(classesUsed(HEALER, { swing, action(MOB, 1, 0, { { HEALER, { { 15, 0 } } } }) },
        { action(HEALER, 4, 57, { { TANK, { { 230, 33 } } } }) }), { CLASS.other }, 'Haste on an ally');
    t.eq(classesUsed(DD, { swing, action(DD, 1, 0, { { MOB, { { 1, 400 } } } }), action(DD, 6, ISSEKIGAN, { { DD, { { 100, 0 } } } }) },
        { action(MOB, 1, 0, { { DD, { { 70, 0 } } } }) }), { CLASS.melee }, 'a parry under Issekigan');

    local function inLine()
        local w = fakeWorld();
        w.positions = { [MOB] = { 0, 0 }, [TANK] = { 2, 0 }, [DD] = { 5, 0.3 } };
        return w;
    end
    t.eq(classesUsed(TANK, { swing, action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }) },
        { action(DD, 1, 0, { { MOB, { { 1, 100 } } } }) }, inLine), { CLASS.melee }, 'Trick Attack\'s partner');
end);

t.test('neutral values stay in the list; the view shows the posterior median', function ()
    local s, f = filtered();
    pin(f, TANK, CLASS.melee, 100);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 353, 1361, true });
    t.eq({ s:view(MOB):get(TANK) }, { 706, 2722, true });
    t.eq(s:view(MOB2), nil);

    local plain = new();
    plain:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(plain:view(MOB), plain:list(MOB));
end);

t.test('a mob attacking an alliance member reweights the particles; a switch counts in full', function ()
    local s, f = filtered();
    local seen = {};
    f.observe = function (self, list, target, switch)
        seen[#seen + 1] = { target, switch };
        return filter.observe(self, list, target, switch);
    end
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    local generation = f.generation;

    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 15, 0 } } } }), 0);
    s:observe(action(MOB, 4, 144, { { DD, { { 2, 10 } } } }), 0);
    -- Neither an area move nor a swing at an outsider says anything about the alliance.
    s:observe(action(MOB, 11, 1, { { TANK, { { 185, 10 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { STRANGER, { { 1, 10 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 0);
    t.eq(seen, { { TANK, false }, { TANK, false }, { DD, true }, { DD, false } });
    t.truthy(f.generation > generation, 'the weights moved');
end);

t.test('attacks on a list that can\'t be vouched for, or that Cover took, are not used', function ()
    local w = fakeWorld();
    w.engagedIds[MOB2] = true;
    local s, f = filtered(w);
    local seen = 0;
    f.observe = function (self, ...)
        seen = seen + 1;
        return filter.observe(self, ...);
    end
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(MOB2, 1, 0, { { DD, { { 1, 10 } } } }), 0);
    t.eq(seen, 0, 'ordering-only');

    pin(f, DD, CLASS.melee, 0);
    pin(f, TANK, CLASS.melee, 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 10 } } } }), 0);
    s:observe(action(TANK, 6, COVER, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 50 } } } }), 0);
    t.eq(seen, 0, 'a covered round');
end);

--[[
* A tank far ahead of the ninja on a clean list, in every particle, and the
* mob on the tank.
--]]
local function tanked(logger)
    local s, f = filtered(nil, { max = 8, jitter = 0 });
    s.mobskills, s.log = SKILLS, logger;
    pin(f, TANK, CLASS.melee, 0);
    pin(f, DD, CLASS.melee, 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);   -- 815 / 2746
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 10 } } } }), 0);      -- 15 / 46
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 1);
    return s, f;
end

local function weightsOf(f)
    local out = {};
    for lane = 1, f.count do
        out[lane] = f.weights[lane];
    end
    return out;
end

t.test('a mob switching to someone the clamp can put ahead refits: the two are redrawn across it, the fight replays, and the list stays clean', function ()
    local s, f = filtered(nil, { max = 1024, jitter = 0 });
    local lines = {};
    s.log = { cost = 0, write = function (_, kind, fields) lines[#lines + 1] = { kind = kind, fields = fields }; end, charge = function () end };
    pin(f, TANK, CLASS.melee, 0);
    pin(f, DD, CLASS.melee, 0);
    -- The tank holds 3000 to the ninja's 1765: neutral, the ninja is 1235 behind,
    -- a surprise; the ninja at +40 against the tank at -18 puts them ahead.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 309 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 287 } } } }), 0);
    local before = s:list(MOB);
    local tankCe, tankVe = before:get(TANK);
    t.eq(s.history.count, 2);

    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 1);
    t.eq(s.refits, 1);
    local list, track = s:list(MOB), s:track(MOB);
    t.eq({ track.clean, track.anchored, track.holder }, { true, 0, DD }, 'explained without anchoring');
    t.truthy(list ~= before, 'the list was rebuilt');
    t.eq({ list:get(TANK) }, { tankCe, tankVe - 48, true }, 'the neutral replay came out the same, two ticks on');
    t.eq(s.history.count, 3, 'the event is in the history for the next refit');

    local distinct = {};
    for lane = 1, f.count do
        distinct[(list:value(TANK, lane))] = true;
    end
    local n = 0;
    for _ in pairs(distinct) do
        n = n + 1;
    end
    t.truthy(n > 8, 'the tank was redrawn across the range: ' .. n .. ' values');
    t.truthy(f:ess() < f.count, 'the replay weighed the attack');

    local refitLine = nil;
    for _, line in ipairs(lines) do
        if line.kind == 'refit' then
            refitLine = line.fields;
        end
        t.truthy(line.kind ~= 'discontinuity', 'nothing was anchored');
    end
    t.eq({ refitLine.mob, refitLine.target, refitLine.leader, refitLine.widened, refitLine.events, refitLine.explained, refitLine.anchored },
        { MOB, DD, TANK, { DD, TANK }, 3, true, 0 });
end);

t.test('a mob first seen engaged at full HP and fought within ten seconds was just pulled: its list is clean, its target at 0/0, and nobody gets the engage bonus', function ()
    local s = new();
    s:observeEntity(MOB, 1, false, 0, 100);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 6);
    t.eq(s:track(MOB).clean, true);
    t.eq(values(s, MOB, TANK), { 0, 0, true });
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 6);
    t.eq(values(s, MOB, DD), { 153, 461, true });

    -- Too long engaged, or hurt already, or never seen with an HP reading: someone else's fight.
    local late = new();
    late:observeEntity(MOB, 1, false, 0, 100);
    late:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 11);
    t.eq(late:track(MOB).clean, false);
    local hurt = new();
    hurt:observeEntity(MOB, 1, false, 0, 97);
    hurt:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 2);
    t.eq(hurt:track(MOB).clean, false);
    local blind = new();
    blind:observeEntity(MOB, 1, false, 0);
    blind:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 2);
    t.eq(blind:track(MOB).clean, false);
end);

t.test('a mob\'s single-target spell on a member opens its list, as its swing does', function ()
    local s = new();
    s:observeEntity(MOB, 1, false, 0, 100);
    s:observe(action(MOB, 4, 144, { { TANK, { { 2, 50 } } } }), 3);
    t.eq(s:list(MOB) ~= nil, true);
    t.eq(s:track(MOB).clean, true);
    t.eq(s:track(MOB).holder, TANK);
    t.eq(values(s, MOB, TANK), { 0, 0, true });
    -- An area spell says nothing and opens nothing.
    local s2 = new();
    s2:observe(action(MOB, 4, 174, { { TANK, { { 2, 50 } } }, { DD, { { 2, 50 } } } }), 0);
    t.eq(s2:list(MOB), nil);
end);

t.test('a refit replaying a full history leaves the ring as it was, and a mob seen idle before its list is idle again for the replay', function ()
    local s, f = filtered(nil, { max = 1024, jitter = 0 });
    pin(f, TANK, CLASS.melee, 0);
    pin(f, DD, CLASS.melee, 0);
    -- The idle update falls out of the history, which starts with the first
    -- action; the replay must still open the list from idle, with the bonus.
    s:observeEntity(MOB, 0, false, 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 309 } } } }), 0);
    s:observeEntity(MOB, 1, false, 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 287 } } } }), 0);
    local tankCe, tankVe = s:list(MOB):get(TANK);
    -- Starts that move nothing, up to one short of a full ring.
    for _ = s.history.count + 1, 8191 do
        s:observe(action(TANK, 7, 0, { { MOB, {} } }), 0.5);
    end
    t.eq(s.history.count, 8191);

    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 1);
    t.eq(s.refits, 1);
    t.eq(s.history.count, 8192);
    t.eq({ s:track(MOB).clean, s:track(MOB).anchored }, { true, 0 });
    t.eq({ s:list(MOB):get(TANK) }, { tankCe, tankVe - 48, true });
    for k = 0, s.history.count - 1 do
        local i = (s.history.first + k - 1) % 8192 + 1;
        t.truthy(type(s.history.events[i]) == 'table', 'slot ' .. i .. ' holds an event');
    end
    collectgarbage();
end);

t.test('a refit does not trim the ring it is replaying: the fresh sim shares it, and its tracks start empty', function ()
    local s = filtered(nil, { max = 1024, jitter = 0 });
    s:observeEntity(MOB, 0, false, 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 309 } } } }), 0);
    local first, count = s.history.first, s.history.count;
    t.truthy(count > 0, 'the ring holds the fight');

    -- What a refit's replay looks like from the ring's side: the fresh sim is
    -- handed this very ring and starts with no tracks, so every observe it
    -- replays ends in a trim that would reset the ring out from under the
    -- loop reading it.  Slots it has not written yet still hold `false`, and
    -- indexing one is the crash.
    s.refitting = true;
    s.lists, s.tracks = {}, {};
    s:observeEntity(STRANGER, 0, false, 1);
    t.eq({ s.history.first, s.history.count }, { first, count },
        'the ring is untouched while refitting');
end);

t.test('a switch not even the clamp explains refits first, then the replayed sim re-anchors them above the leader', function ()
    local s, f = tanked();
    t.eq({ s:track(MOB).clean, s:track(MOB).anchored }, { true, 0 });
    local before = s:list(MOB);
    local tankCe = before:get(TANK);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 2);
    t.eq({ s.refits, s:track(MOB).clean, s:track(MOB).anchored }, { 1, true, 1 });
    local list = s:list(MOB);
    t.truthy(list ~= before, 'the list was rebuilt');
    -- The ninja sits one above the tank in every lane, CE first, the swing's
    -- own damage already taken; the tank is as they were.
    for lane = 0, f.count do
        local tce, tve = list:value(TANK, lane);
        local dce, dve = list:value(DD, lane);
        t.eq(dce + dve, tce + tve + 1, 'lane ' .. lane);
        t.eq(dve, 0, 'VE untouched in lane ' .. lane);
    end
    t.eq((list:get(TANK)), tankCe);
    t.eq(s:track(MOB).holder, DD);
    for lane = 1, f.count do
        t.truthy(math.abs(f.weights[lane] - 1 / f.count) < 1e-6, 'weights reset for the replay');
    end

    local seen = 0;
    f.observe = function (self, ...)
        seen = seen + 1;
        return filter.observe(self, ...);
    end
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 3);
    t.eq(seen, 1, 'attacks on it are evidence again');
    t.eq({ s.refits, s:track(MOB).anchored }, { 1, 1 }, 'and the one-point lead made that no surprise');
    t.eq(s.gaps, {}, 'no mobskill came before it');
end);

t.test('no refit for a list picked up from a reload, or with refits turned off: the anchor alone', function ()
    local s = tanked();
    local saved = s:export();
    local s2, f2 = filtered(nil, { max = 8, jitter = 0 });
    s2.mobskills = SKILLS;
    pin(f2, TANK, CLASS.melee, 0);
    pin(f2, DD, CLASS.melee, 0);
    s2:import(saved, 1, 0);
    s2:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 2);
    t.eq({ s2.refits, s2:track(MOB).anchored }, { 0, 1 });

    local s3 = tanked();
    s3.opts.refit = false;
    s3:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 2);
    t.eq({ s3.refits, s3:track(MOB).anchored }, { 0, 1 });
end);

t.test('the history follows the open lists: kept from two minutes before the oldest, gone with the last', function ()
    local s = tanked();
    t.eq(s.history.count, 3);
    s:observe({ kind = 'message', actorId = TANK, targetId = MOB, message = 6, param = 0, value = 0 }, 5);
    t.eq(s.history.count, 0);
    t.eq(s.historyFrom, 5);
    -- Opened at 300, the list keeps what happened from 180 on.
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 100);
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 200);
    s:observe({ kind = 'message', actorId = TANK, targetId = MOB2, message = 6, param = 0, value = 0 }, 250);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 300);
    t.eq(s.history.count, 1);
end);

t.test('a switch a hate reset in the table explains is no surprise', function ()
    local s = tanked();
    s:observe(action(MOB, 11, RESETS, { { TANK, { { 185, 10 } } } }), 2);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 3);
    t.eq({ s:track(MOB).clean, s:track(MOB).anchored }, { true, 0 });
end);

t.test('an unexplained switch right after a mobskill missing from the table is logged as a table gap', function ()
    local s = tanked();
    s:observe(action(MOB, 11, 777, { { TANK, { { 185, 10 } } } }), 2);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 3);
    t.eq(s:track(MOB).anchored, 1);
    t.eq(s.gaps, { { skill = 777, mob = MOB, name = 'Goblin', zone = 10 } });

    -- Nor on a mob whose own script resets hate, which the table can't hold.
    s = tanked();
    s.scriptedMobs = { [10] = { Goblin = true } };
    s:observe(action(MOB, 11, 777, { { TANK, { { 185, 10 } } } }), 2);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 3);
    t.eq({ s:track(MOB).anchored, s.gaps }, { 1, {} });

    -- Nor after the mob has done something else since, even an area spell.
    s = tanked();
    s:observe(action(MOB, 11, 777, { { TANK, { { 185, 10 } } } }), 2);
    s:observe(action(MOB, 4, 144, { { TANK, { { 2, 10 } } }, { DD, { { 2, 10 } } } }), 2);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 3);
    t.eq({ s:track(MOB).anchored, s.gaps }, { 1, {} });

    -- A skill the table has, even one it can't vouch for, is no gap.
    s = tanked();
    s:observe(action(MOB, 11, UNKNOWN, { { TANK, { { 185, 10 } } } }), 2);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 3);
    t.eq({ s:track(MOB).anchored, s.gaps }, { 1, {} });

    -- Nor is one the mob swung after: the switch no longer follows it.
    s = tanked();
    s:observe(action(MOB, 11, 777, { { TANK, { { 185, 10 } } } }), 2);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 3);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 4);
    t.eq({ s:track(MOB).anchored, s.gaps }, { 1, {} });

    -- Nor a missing skill before a switch that was expected.
    s = tanked();
    s:observe(action(MOB, 11, 777, { { TANK, { { 185, 10 } } } }), 2);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 2000 } } } }), 2);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 3);
    t.eq({ s:track(MOB).anchored, s.gaps }, { 0, {} });
end);

t.test('every attack the filter weighs is scored for calibration first, a surprise included', function ()
    t.eq(new().calibration, nil, 'nothing to score without a filter');

    local s, f = tanked();
    t.eq(s.calibration.level, filter.CREDIBLE);
    -- The tank tops every particle: the swing at them earns the set's level.
    t.eq({ s.calibration.attacks, s.calibration.credit, s.calibration.contested }, { 1, 0.8, 0 });

    local scoredFirst = nil;
    f.observe = function (self, ...)
        scoredFirst = s.calibration.attacks == 3;
        return filter.observe(self, ...);
    end
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 2);
    t.eq(s.calibration.attacks, 2);
    -- The ninja tops none: a surprise, and outside the set.
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 3);
    t.eq({ scoredFirst, s.calibration.attacks }, { true, 3 });
    t.truthy(math.abs(s.calibration.credit - 1.6) < 1e-9, 'credit ' .. s.calibration.credit);

    -- Re-anchored, the list is still clean: the next attack is scored too.
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 4);
    t.eq(s.calibration.attacks, 4);
    -- Nor is anything a reset or a zone forgets.
    s:reset();
    t.eq(s.calibration.attacks, 4);
end);

t.test('attacks the filter doesn\'t weigh are not scored', function ()
    local w = fakeWorld();
    w.engagedIds[MOB2] = true;
    local s, f = filtered(w);
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(MOB2, 1, 0, { { DD, { { 1, 10 } } } }), 0);
    t.eq(s.calibration.attacks, 0, 'ordering-only');

    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 10 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 0);
    t.eq(s.calibration.attacks, 0, 'no rival');
    s:observe(action(MOB, 1, 0, { { STRANGER, { { 1, 10 } } } }), 0);
    t.eq(s.calibration.attacks, 0, 'an outsider');

    pin(f, DD, CLASS.melee, 0);
    pin(f, TANK, CLASS.melee, 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 0);
    t.eq(s.calibration.attacks, 1, 'weighed');
    s:observe(action(TANK, 6, COVER, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 50 } } } }), 0);
    t.eq(s.calibration.attacks, 1, 'a covered round');
end);

t.test('the sim\'s own calls on who holds hate follow the posterior', function ()
    local s, f = filtered();
    pin(f, TANK, CLASS.melee, -50);
    pin(f, DD, CLASS.melee, 100);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);   -- neutral 815 / 2746
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 300 } } } }), 0);     -- neutral 461 / 1384
    s:observe(defeated(DD, DD), 0);
    -- The neutral replay has the tank on top, but every particle has the DD.
    t.eq(values(s, MOB, DD), {});
end);

t.test('a list that ends leaves the filter', function ()
    local s, f = filtered();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe({ kind = 'message', actorId = TANK, targetId = MOB2, message = 6, param = 0, value = 0 }, 0);
    local n = 0;
    for _ in pairs(f.lists) do
        n = n + 1;
    end
    t.eq(n, 1);
    s:clear();
    t.eq(next(f.lists), nil);
end);

t.test('the particle count settles where an 18-member fight fits the frame budget', function ()
    local w = fakeWorld();
    local members = { TANK, HEALER, DD };
    for i = 1, 15 do
        local id = 0x0001F000 + i;
        w.ids[id] = { kind = 'alliance', name = 'Member' .. i, member = { mainJob = 'WAR', subJob = 'NIN', mainLevel = 75 } };
        w.maxHPs[id] = 1200;
        members[#members + 1] = id;
    end
    -- The clock moves 50 ns a particle each time it is read, so each call
    -- into the sim, read before and after, costs that.
    local s, f;
    local elapsed = 0;
    s, f = filtered(w, { max = 1024, clock = function ()
        elapsed = elapsed + f.count * 5e-8;
        return elapsed;
    end });
    local now = 0;
    local function fight(actors)
        for frame = 1, 300 do
            now = now + 1 / 60;
            for i = 1, actors do
                s:observe(action(members[(frame + i) % #members + 1], 1, 0, { { MOB, { { 1, 20 } } } }), now);
            end
            s:observe(action(MOB, 1, 0, { { members[frame % 3 + 1], { { 1, 30 } } } }), now);
            s:advance(now);
            f:frame();
        end
    end

    fight(18);
    local perFrame = 20 * f.count * 5e-8;
    t.truthy(perFrame <= filter.BUDGET, ('%d particles cost %.2f ms a frame'):format(f.count, perFrame * 1000));
    t.truthy(perFrame >= filter.BUDGET * 0.4, ('%d particles is not starved'):format(f.count));

    fight(1);
    t.eq(f.count, 1024, 'a quiet fight has room for them all again');
end);

t.test('time spent is reported to the filter, but not for a frame that crosses no tick', function ()
    local s, f;
    local elapsed = 0;
    s, f = filtered(nil, { max = 8, clock = function ()
        elapsed = elapsed + 0.001;
        return elapsed;
    end });
    s:advance(0.1);
    s:advance(0.2);
    t.eq(f.spent, 0);
    s:advance(0.5);
    t.truthy(math.abs(f.spent - 0.001) < 1e-9, 'a tick');
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0.6);
    s:observeEntity(MOB, 1, false, 0.7);
    t.truthy(math.abs(f.spent - 0.003) < 1e-9, 'an action and an entity update');
end);

t.test('a repeated action allocates nothing once warm', function ()
    local s, f = filtered(nil, { max = 32 });
    local now = 0;
    local tank = action(TANK, 1, 0, { { MOB, { { 1, 5 } } } });
    local dd = action(DD, 1, 0, { { MOB, { { 1, 5 } } } });
    -- Healing small enough that the healer never out-hates the two being
    -- swung at, so every swing is weighed rather than a surprise.
    local cure = action(HEALER, 4, 1, { { TANK, { { 7, 1 } } } });
    local swings = { action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), action(MOB, 1, 0, { { DD, { { 1, 10 } } } }) };
    local function round(i)
        now = now + 0.25;
        s:observe(tank, now);
        s:observe(dd, now);
        s:observe(cure, now);
        s:observe(swings[i % 2 + 1], now);
        s:advance(now);
        s:view(MOB):get(TANK);
        f:frame();
    end
    -- The ninja's opening hit matches the tank's first-engage bonus, so the
    -- two stay close enough for the mob to plausibly swing at either.
    s:observe(tank, 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 240 } } } }), 0);
    for i = 1, 200 do
        round(i);
    end
    t.eq(s:track(MOB).clean, true, 'no surprise');
    -- 2000 rounds allocating even one small table each would be 80 KB.
    local resamples = f.resamples;
    local grown = t.allocated(round, 2000);
    t.truthy(f.resamples > resamples, 'resampling was exercised');
    t.eq(s:track(MOB).clean, true, 'still no surprise');
    t.truthy(grown < 4, ('allocated %.1f KB'):format(grown));
end);

--[[
* The session log: what the sim saw and decided, written as it happens.
--]]

local function copy(v)
    if type(v) ~= 'table' then
        return v;
    end
    local out = {};
    for k, x in pairs(v) do
        out[k] = copy(x);
    end
    return out;
end

-- A log that keeps what is written, as tables copied when written, as encoding them would.
local function recorder()
    local r = { lines = {} };
    function r:write(kind, fields)
        self.lines[#self.lines + 1] = { kind = kind, fields = copy(fields or {}) };
    end
    function r:all(kind)
        local out = {};
        for _, line in ipairs(self.lines) do
            if line.kind == kind then
                out[#out + 1] = line.fields;
            end
        end
        return out;
    end
    function r:last(kind)
        local all = self:all(kind);
        return all[#all];
    end
    return r;
end

local function logged(w, opts)
    local r = recorder();
    opts = opts or {};
    opts.levelRange, opts.mobskills, opts.log = levels, SKILLS, r;
    return sim.new(w or fakeWorld(), opts), r;
end

t.test('a fight going quiet is not a wipe: nobody died, so nothing is announced', function ()
    local w = fakeWorld();
    local s, r = logged(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    t.truthy(s:list(MOB) ~= nil, 'the list opened');

    -- Everyone is alive and standing; the mob simply stops being fought.
    s:advance(sim.QUIET + 1);
    t.eq(s:list(MOB), nil, 'the quiet list was dropped');
    t.eq(s.wipes, 0, 'a quiet list is not a wipe, and must not be announced as one');
    t.eq(r:all('wipe'), {}, 'nor logged as one');
    t.eq(#r:all('quiet'), 1, 'it is logged as what it is');
end);

t.test('each alliance action logs what it applied, and the neutral enmity it moved on each list', function ()
    local w = fakeWorld();
    w.distances[TANK] = 4;
    local s, r = logged(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(r:last('list'), { mob = MOB, name = 'Goblin', clean = true, engaged = false, levels = { 74, 76 } });
    t.eq(r:last('action'), {
        actor = TANK, name = 'Tank', category = 1, param = 0, class = 'melee', mod = 0, buffs = {}, readable = false,
        targets = { { id = MOB, distance = 4, level = 75 } }, ce = 0, ve = 0,
    });
    t.eq(r:last('enmity'), { mob = MOB, actor = TANK, key = 'melee', changes = { { TANK, 353, 1361, 353, 1361, true } } });

    w.buffReadings[TANK] = { [0] = false };
    s:observe(action(TANK, 6, 48, { { TANK, { { 100, 0 } } } }), 0);          -- Sentinel
    s:observe(action(TANK, 6, 35, { { MOB, { { 100, 0 } } } }), 0);           -- Provoke
    t.eq(r:last('action'), {
        actor = TANK, name = 'Tank', category = 6, param = 35, class = 'ability', mod = 100, buffs = { 'sentinel' },
        readable = true, targets = { { id = MOB, distance = 4, level = 75 } },
        entry = 'provoke', ce = 1, ve = 1800, ceTrust = 'era', veTrust = 'era',
    });
    t.eq(r:last('enmity').changes, { { TANK, 2, 3600, 357, 6761, true } });
    t.eq(r:last('enmity').key, 'ability provoke');
end);

t.test('the seen gear behind an action\'s mod is logged by item', function ()
    local w = fakeWorld();
    local s, r = logged(w);
    w.worn[TANK] = { [15544] = true, [13437] = true };    -- Sattva Ring; Healer's Earring, but not on a WHM sub
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    local line = r:last('action');
    t.eq({ line.mod, line.gear, line.items }, { 5, 5, { 15544 } });
end);

t.test('damage taken logs the max HP it was divided by, and is filed under the mechanic', function ()
    local s, r = logged();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 150 } } } }), 0);
    t.eq(r:last('attacked'), { mob = MOB, id = TANK, damage = 150, maxHP = 1500, reduction = 0 });
    t.eq(r:last('enmity'), { mob = MOB, actor = MOB, key = 'melee', changes = { { TANK, -180, 0, 635, 2746, true } } });
    t.eq(s:track(MOB).ledger[TANK]['taken melee (damage)'], { n = 1, ce = -180, ve = 0 });
end);

t.test('Cover, Issekigan, shadows and Trick Attack each file their enmity under their own name', function ()
    local w = fakeWorld();
    w.positions = { [MOB] = { 0, 0 }, [TANK] = { 2, 0 }, [DD] = { 5, 0.3 } };
    local s, r = logged(w);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 6, COVER, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 150 } } } }), 0);
    local ledger = s:track(MOB).ledger;
    t.eq(ledger[TANK]['taken melee (cover)'], { n = 1, ce = 200, ve = 0 });
    t.eq(ledger[DD]['taken melee (covered)'].n, 1);
    t.eq(r:last('cover'), { mob = MOB, coverer = TANK, covered = DD });

    s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 } } } }), 0);
    t.eq(ledger[DD]['taken melee (shadow)'], { n = 1, ce = -25, ve = 0 });
    t.eq(r:last('shadow'), { mob = MOB, id = DD, shadows = 1, charged = true, utsusemi = true, paid = 1, left = 2, rule = 'lsb' });

    s:observe(action(DD, 6, ISSEKIGAN, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 70, 0 } } } }), 0);
    t.eq(ledger[DD]['taken melee (issekigan)'], { n = 1, ce = 300, ve = 0 });

    s:observe(action(DD, 6, TRICK_ATTACK, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(r:last('trick'), {
        thief = DD, mob = MOB, partner = TANK, how = 'line', reach = math.sqrt(5 * 5 + 0.3 * 0.3), nearer = { { TANK, 2, 2 } },
    });
    t.eq(ledger[TANK]['melee from Dd (trick attack)'], { n = 1, ce = 153, ve = 461 });
end);

t.test('a list that ends logs the fight, whose ledger adds up to the values it ended on', function ()
    local s, r = logged();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 150 } } } }), 0);
    s:observe(action(HEALER, 4, 1, { { TANK, { { 7, 300 } } } }), 0);
    s:observe({ kind = 'message', actorId = TANK, targetId = MOB, message = 6, param = 0, value = 0 }, 5);
    local fight = r:last('fight');
    t.eq({ fight.mob, fight.name, fight.reason, fight.clean, fight.anchored, fight.seconds },
        { MOB, 'Goblin', 'defeated', true, 0, 5 });
    t.eq(fight.names, { [TANK] = 'Tank', [HEALER] = 'Healer' });
    t.eq(fight.ledger[TANK], {
        melee = { n = 2, ce = 506, ve = 1822 },
        ['taken melee (damage)'] = { n = 1, ce = -180, ve = 0 },
        decay = { n = 1, ce = 0, ve = -288 },
    });
    t.eq(fight.ledger[HEALER], { ['spell cure'] = { n = 1, ce = 218, ve = 1309 }, decay = { n = 1, ce = 0, ve = -288 } });
    t.eq(fight.values, { { TANK, 326, 1534, true }, { HEALER, 218, 1021, true } });

    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 6);
    s:reset();
    t.eq(r:last('fight').reason, 'reset');
end);

t.test('a member cleared off a list files what they lost', function ()
    local s = logged();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 15, 0 } } } }), 0);
    local track = s:track(MOB);
    s:observe(defeated(MOB, TANK), 0);
    t.eq(track.ledger[TANK]['death (cleared)'], { n = 1, ce = -353, ve = -1361 });
end);

t.test('a mob\'s state changes are logged, and a list ending on one says which', function ()
    local s, r = logged();
    s:observeEntity(MOB, 0, false, 0);
    s:observeEntity(MOB, 0, false, 0.5);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 1);
    s:observeEntity(MOB, 1, false, 1.2);
    s:observeEntity(MOB, 0, false, 9);
    t.eq(r:all('mob'), {
        { mob = MOB, engaged = false },
        { mob = MOB, engaged = true },
        { mob = MOB, engaged = false },
    });
    t.eq(r:last('fight').reason, 'disengaged');
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 10);
    s:advance(80);
    t.eq(r:last('fight').reason, 'stale');
end);

t.test('an attack on a member logs the neutral margin; with a filter, what the particles made of it', function ()
    local r = recorder();
    local s, f = tanked(r);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 2);
    t.eq(r:last('target'), {
        mob = MOB, target = DD, modelled = true, switch = true, clean = true, holder = TANK,
        leader = TANK, margin = -3414,
    });
    local observed = r:last('observe');
    t.eq({ observed.mob, observed.target, observed.tier, observed.used, observed.surprised, observed.resampled, observed.count },
        { MOB, DD, 'clean', false, true, false, 8 });
    t.truthy(observed.predicted < filter.SURPRISE, 'predicted ' .. tostring(observed.predicted));
    t.eq({ observed.best, observed.worst, observed.essBefore, observed.essAfter }, { -3414, -3414, 8, 8 });

    local d = r:last('discontinuity');
    t.eq({ d.mob, d.target, d.switch, d.holder, d.leader }, { MOB, DD, true, TANK, TANK });
    t.eq(d.ledger[DD], { melee = { n = 1, ce = 15, ve = 46 }, decay = { n = 1, ce = 0, ve = -46 } });
    t.eq(d.ledger[TANK].melee, { n = 1, ce = 815, ve = 2746 });

    -- Raised after the swing's 10 damage took the ninja's 15 CE down to 0.
    local tce, tve = s:list(MOB):get(TANK);
    t.eq({ d.anchored, d.lanes, d.from }, { 1, 9, { 0, 0 } });
    t.eq(d.to, { tce + tve + 1, 0 }, 'one above the tank, CE first');

    -- Re-anchored one point ahead, the ninja is a coin toss against the tank: weighed, no surprise.
    local generation = f.generation;
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 3);
    local o = r:last('observe');
    t.eq({ o.tier, o.used, o.surprised }, { 'clean', true, false });
    t.truthy(f.generation > generation, 'the particles moved');
end);

t.test('each attack scored for calibration logs the chances it was scored on and the running coverage', function ()
    local r = recorder();
    local s = tanked(r);
    t.eq(r:last('calibration'), {
        mob = MOB, target = TANK, switch = false, chances = { { TANK, 1 }, { DD, 0 } }, level = 0.8,
        credit = 0.8, contested = false, attacks = 1, coverage = 0.8,
    });
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 2);
    local line = r:last('calibration');
    t.eq({ line.target, line.switch, line.holder, line.credit, line.attacks }, { DD, true, TANK, 0, 2 });
    t.truthy(math.abs(line.coverage - 0.4) < 1e-9, 'coverage ' .. line.coverage);
    t.eq(line.contestedCoverage, nil, 'nothing contested');
end);

t.test('a discontinuity with nobody holding hate before still logs the leader\'s ledger', function ()
    local r = recorder();
    local s, f = filtered(nil, { max = 8, jitter = 0 });
    s.log = r;
    pin(f, TANK, CLASS.melee, 0);
    pin(f, DD, CLASS.melee, 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 10 } } } }), 0);
    s:observe(action(MOB, 4, 144, { { DD, { { 2, 10 } } } }), 0);
    local d = r:last('discontinuity');
    t.eq({ d.holder, d.leader, d.switch }, { nil, TANK, false });
    t.truthy(d.ledger[TANK] ~= nil and d.ledger[DD] ~= nil, 'both ledgers');
end);

t.test('a charmed member is inactive on every list until they act or are reached again', function ()
    local s, r = logged();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 10 } } } }), 0);
    -- A mob's TP move that charms: "<target> is charmed", the status in the param.
    s:observe(action(MOB, 11, RESETS_IF_LANDED, { { TANK, { { 242, 14 } } } }), 1);
    t.eq({ s:list(MOB):get(TANK) }, { 0, 0, false }, 'reset by the table, and set aside');
    t.eq({ s:list(MOB2):get(TANK) }, { 353, 1313, false }, 'set aside there too');
    t.eq(r:last('charm'), { id = TANK, mobs = { MOB, MOB2 } });
    t.eq(s:list(MOB):highest(), DD);
    -- Freed, their first action puts them back.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 10 } } } }), 20);
    t.eq(select(3, s:list(MOB):get(TANK)), true);
    t.eq(select(3, s:list(MOB2):get(TANK)), false, 'only where they acted');
    -- Or the mob reaching them.
    s:observe(action(MOB2, 1, 0, { { TANK, { { 1, 10 } } } }), 21);
    t.eq(select(3, s:list(MOB2):get(TANK)), true);

    -- A spell that charms says so with its own message; a resisted one doesn't.
    s:observe(action(MOB, 4, 2, { { DD, { { 236, 14 } } } }), 22);
    t.eq(select(3, s:list(MOB):get(DD)), false);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 10 } } } }), 23);
    s:observe(action(MOB, 4, 2, { { DD, { { 85, 14 } } } }), 24);
    t.eq(select(3, s:list(MOB):get(DD)), true);
end);

t.test('an attack no hidden Enmity could explain is logged as impossible, with both sides\' ledgers, once', function ()
    local s, r = logged();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);   -- 815 / 2746: at least 407 / 1373
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);     -- 153 / 461: at most 306 / 922
    s:observe(action(MOB, 1, 0, { { TANK, { { 15, 0 } } } }), 0);
    t.eq(r:last('impossible'), nil, 'the tank beating the ninja is possible');
    s:observe(action(MOB, 1, 0, { { DD, { { 15, 0 } } } }), 0);
    local line = r:last('impossible');
    t.eq({ line.mob, line.target, line.rival, line.targetName, line.rivalName }, { MOB, DD, TANK, 'Dd', 'Tank' });
    t.eq({ line.most, line.least, line.short }, { 1228, 1780.5, 552.5 });
    t.eq(line.values, { { DD, 153, 461 }, { TANK, 815, 2746 } });
    t.eq(line.ledger[DD].melee, { n = 1, ce = 153, ve = 461 });
    t.eq(line.ledger[TANK].melee, { n = 1, ce = 815, ve = 2746 });
    s:observe(action(MOB, 1, 0, { { DD, { { 15, 0 } } } }), 0);
    t.eq(#r:all('impossible'), 1, 'once a fight for the pair');

    -- A known Enmity bonus widens what could have been: Sentinel's doubling leaves room.
    local s2, r2 = logged();
    s2:observe(action(TANK, 6, 48, { { TANK, { { 100, 0 } } } }), 0);
    s2:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s2:observe(action(TANK, 1, 0, { { MOB, { { 1, 150 } } } }), 0);
    s2:observe(action(MOB, 1, 0, { { DD, { { 15, 0 } } } }), 0);
    t.eq(r2:last('impossible'), nil);
end);

t.test('nothing is judged impossible on a list whose start was missed', function ()
    local w = fakeWorld();
    w.engagedIds[MOB] = true;
    local s, r = logged(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 15, 0 } } } }), 0);
    t.eq(r:last('impossible'), nil);
end);

t.test('a gap is logged with the skill and mob behind it', function ()
    local r = recorder();
    local s = tanked(r);
    s:observe(action(MOB, 11, 777, { { TANK, { { 185, 10 } } } }), 2);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 3);
    t.eq(r:last('gap'), { skill = 777, mob = MOB, name = 'Goblin', zone = 10 });
end);

t.test('every mobskill on a member logs what the table says and whether it was applied', function ()
    local s, r = logged();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(MOB, 11, RESETS_IF_LANDED, { { TANK, { { 188, 0 } } } }), 0);
    t.eq(r:last('mobskill'), {
        mob = MOB, skill = RESETS_IF_LANDED, target = TANK, known = true, entry = 'hydro_shot', effect = 'reset',
        conditional = true, trust = 'lsb', message = 188, landed = false, applied = false,
    });
    s:observe(action(MOB, 11, 777, { { TANK, { { 185, 10 } } } }), 0);
    t.eq(r:last('mobskill'), { mob = MOB, skill = 777, target = TANK, known = false, message = 185, landed = true, applied = false });
    s:observe(action(MOB, 11, RESETS, { { TANK, { { 185, 10 } } } }), 0);
    t.eq(r:last('mobskill').applied, true);
    t.eq(r:last('enmity').key, 'mobskill death_trap');
    t.eq(s:track(MOB).ledger[TANK]['taken mobskill death_trap (damage, reset)'].n, 1);
    t.eq(s:track(MOB).ledger[TANK]['taken mobskill #777 (damage)'].n, 1);
end);

t.test('deaths and out-of-range actions are logged, a range call once a packet', function ()
    local w = fakeWorld();
    local s, r = logged(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 400 } } } }), 0);
    w.distances[HEALER] = 30;
    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100 }, { 1, 50 } } } }), 0);
    t.eq(r:all('range'), { { id = HEALER, mob = MOB, distance = 30,
        limit = 28, base = 28, mobHitbox = 0, actorHitbox = 0 } },
        'every term of the decision, so a replay can take it again');

    s:observe(action(MOB, 1, 0, { { TANK, { { 15, 0 } } } }), 0);
    s:observe(defeated(MOB, HEALER), 1);
    s:observe(defeated(MOB, TANK), 1);
    t.eq(r:all('death'), { { id = HEALER, cleared = {}, inactive = { MOB } }, { id = TANK, cleared = { MOB }, inactive = {} } });
end);

t.test('a hitbox is logged the first time it is seen, and not again', function ()
    local w = fakeWorld();
    local s, r = logged(w);
    s:observeEntity(MOB, 0, false, 0, nil, 1.6);
    s:observeEntity(MOB, 1, false, 0, nil, 1.6);
    s:observeEntity(TANK, 0, false, 0, nil, 1.0);
    t.eq(r:all('hitbox'), { { id = MOB, hitbox = 1.6 }, { id = TANK, hitbox = 1.0 } });

    -- The widened gate it produces is logged with the exclusion.
    w.distances[HEALER] = 30;
    s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(r:all('range'), { { id = HEALER, mob = MOB, distance = 30,
        limit = 29.6, base = 28, mobHitbox = 1.6, actorHitbox = 0 } });
end);

t.test('the log\'s own work is kept out of the filter\'s frame budget', function ()
    local elapsed = 0;
    local r = recorder();
    r.cost = 0;
    -- Every line takes a second to write, and says so.
    local write = r.write;
    function r:write(kind, fields)
        elapsed = elapsed + 1;
        write(self, kind, fields);
    end
    function r:charge(seconds)
        self.cost = self.cost + seconds;
    end
    local s, f = filtered(nil, { max = 8, clock = function () return elapsed; end });
    s.log = r;
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 1);
    s:observe(defeated(MOB, DD), 2);
    s:observe({ kind = 'message', actorId = TANK, targetId = MOB, message = 6, param = 0, value = 0 }, 3);
    t.truthy(#r.lines > 10, 'lines were written');
    t.eq(f.spent, 0);
end);

--[[
* A reload: the fights exported and picked up by a fresh sim.
--]]

t.test('exported fights import into a fresh sim with their lists, tracks, buffs and shadows, and the time away decays them', function ()
    local w = fakeWorld();
    w.engagedIds[MOB2] = 'unknown';
    -- The tank reads as standing, so the healer's death alone is no wipe.
    w.downs[TANK] = false;
    local s = new(w);
    s:advance(10);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 10);          -- 353 / 1361
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 10);            -- 153 / 461
    s:observe(action(TANK, 6, 48, { { TANK, { { 100, 0 } } } }), 10);        -- Sentinel: +2 / +1800 on MOB, 30 s
    s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 10);
    s:observe(action(STRANGER, 1, 0, { { MOB2, { { 1, 100 } } } }), 10);
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 10);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 10);
    s:observe({ kind = 'message', message = 20, actorId = MOB, targetId = HEALER }, 10);
    s:observeEntity(MOB, 1, false, 10);
    local saved = s:export();
    t.eq(saved.lists[MOB].entries, { { TANK, 343, 3161, true }, { DD, 154, 761, true } });
    t.eq(saved.lists[MOB2].others, { STRANGER });
    t.eq(saved.tracks[MOB].holder, TANK);
    t.eq(saved.tracks[MOB2].clean, false);
    t.eq(saved.states[MOB], { engaged = true, since = 0, seenIdle = false });
    t.eq(saved.dead[HEALER], true);
    t.eq(saved.shadows[DD], { utsusemi = true, count = 3 });
    t.eq(saved.buffs[TANK][62].left, 30);

    -- Ten seconds later, on a clock that starts over.
    local fresh = new(w);
    t.eq(fresh:import(saved, 2, 10), 2);
    fresh:advance(2);
    t.eq(values(fresh, MOB, TANK), { 343, 3161 - 24 * 25, true }, 'decayed for the time away');
    t.eq(values(fresh, MOB, DD), { 154, 761 - 24 * 25, true });
    t.eq(fresh:list(MOB2).others[STRANGER], true);
    t.eq(fresh:track(MOB).holder, TANK);
    t.eq(fresh:track(MOB).clean, true);
    t.eq(fresh:track(MOB2).clean, false);
    t.eq(fresh:track(MOB).acting, 1);
    t.eq(fresh:track(MOB2).acting, 1);
    t.eq(fresh.dead[HEALER], true);
    t.eq(fresh:name(MOB), 'Goblin');
    -- Sentinel has 20 s left: Provoke is still doubled.
    fresh:observe(action(TANK, 6, 35, { { MOB, { { 100, 0 } } } }), 2);
    t.eq(values(fresh, MOB, TANK), { 343 + 2, 3161 - 600 + 3600, true });
    -- The DD's three shadows are still counted.
    fresh:observe(action(MOB, 1, 0, { { DD, { { 31, 1 }, { 31, 1 }, { 31, 1 } } } }), 2);
    t.eq(fresh.shadows[DD], nil, 'the last went');
    -- No newcomer bonus on the restored list; a mob whose list was restored still ends when it disengages.
    fresh:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100 } } } }), 2);
    t.eq(values(fresh, MOB, HEALER), { 153, 461, true });
    fresh:observeEntity(MOB, 0, false, 2);
    fresh:advance(2 + 5.1);
    t.eq(fresh:list(MOB), nil);
end);

t.test('with a filter, restored lists start every particle from the neutral values', function ()
    local s = new();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    local saved = s:export();
    local fresh, f = filtered();
    fresh:import(saved, 0, 0);
    local view = fresh:view(MOB);
    t.eq({ view:get(TANK) }, { 353, 1361, true });
    local lo, _, _, _, hi = view:band(TANK);
    t.eq({ lo, hi }, { 353 + 1361, 353 + 1361 }, 'no spread yet');
    t.eq(f.lists[fresh:list(MOB)], true, 'the filter knows the list');
end);

--[[
* Weaponskills with fixed enmity, and abilities that move their user's own.
--]]

local CORONACH, NAMAS_ARROW, HIGH_JUMP, SUPER_JUMP = 216, 200, 67, 68;

t.test('a weaponskill with fixed enmity adds it once when anything lands, scaled, in place of its damage', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353 / 1361
    -- Coronach for 2000: 80/240, not 3076/9230.
    s:observe(action(DD, 3, CORONACH, { { MOB, { { 185, 2000 } } } }), 0);
    t.eq(values(s, MOB, DD), { 80, 240, true });
    -- Two hits still add it once; a miss adds the damage path's 1, as before.
    s:observe(action(DD, 3, NAMAS_ARROW, { { MOB, { { 185, 500 }, { 185, 500 } } } }), 0);
    t.eq(values(s, MOB, DD), { 240, 720, true });
    s:observe(action(DD, 3, CORONACH, { { MOB, { { 188, 0 } } } }), 0);
    t.eq(values(s, MOB, DD), { 241, 724, true });
    -- Scaled by Enmity like any gain: Sentinel's +100 doubles it on a paladin main.
    s:observe(action(TANK, 6, 48, { { TANK, { { 100, 0 } } } }), 0);         -- Sentinel: 353 + 2 / 1361 + 1800
    s:observe(action(TANK, 3, CORONACH, { { MOB, { { 185, 100 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 355 + 160, 3161 + 480, true });
    -- A skillchain it closes is damage enmity still.
    s:observe(action(DD, 3, CORONACH, { { MOB, { { 185, 100, { 288, 52 } } } } }), 0);
    t.eq(values(s, MOB, DD), { 241 + 80 + 80, 724 + 240 + 240, true });
    -- Its trust is counted, and the ledger names it.
    t.eq(s:track(MOB).trust[DD].ce, { era = 0, lsb = 3, unknown = 0 });
    -- Opening a list with it gets the first-engage bonus on the fixed values.
    s:observe(action(DD, 3, NAMAS_ARROW, { { MOB2, { { 185, 900 } } } }), 0);
    t.eq(values(s, MOB2, DD), { 360, 1380, true });
end);

t.test('Trick Attack hands a fixed weaponskill\'s enmity to the partner, on their Enmity', function ()
    local w = fakeWorld();
    w.ids[DD].member.mainJob = 'THF';
    w.positions[MOB], w.positions[TANK], w.positions[DD] = { 0, 0 }, { 2, 0 }, { 4, 0 };
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);            -- 353 / 1361
    s:observe(action(DD, 6, 76, { { DD, { { 100, 0 } } } }), 0);
    s:observe(action(DD, 3, CORONACH, { { MOB, { { 185, 2000 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 433, 1601, true });
    t.eq(values(s, MOB, DD), { 0, 0, true }, 'the thief still claims');
end);

t.test('resting is logged: the sit with what was read, each healing tick as rest, and getting up', function ()
    local w = fakeWorld();
    w.buffReadings[TANK] = {};
    local s, r = logged(w, { values = 'lsb' });
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observeRest(TANK, true, 0);
    local sat = r:last('rest');
    t.eq({ sat.id, sat.resting, sat.signet, sat.maxHP }, { TANK, true, false, 1500 });
    s:advance(20);
    t.eq(r:last('enmity').key, 'rest');
    t.eq(r:last('enmity').changes, { { TANK, 7, 43, 360, 204, true } });
    t.eq(s:track(MOB).ledger[TANK].rest, { n = 1, ce = 7, ve = 43 });
    s:observeRest(TANK, false, 25);
    local rose = r:last('rest');
    t.eq({ rose.id, rose.resting, rose.ticks }, { TANK, false, 2 });
    t.eq(s.history.count, 3, 'the sit and the rise are in the history for a refit');
end);

t.test('a fixed weaponskill is logged under its name', function ()
    local s, r = logged();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 3, CORONACH, { { MOB, { { 185, 2000 } } } }), 0);
    t.eq(r:last('enmity').key, 'weaponskill coronach (fixed)');
    t.eq(r:last('enmity').changes, { { DD, 80, 240, 80, 240, true } });
    t.eq(s:track(MOB).ledger[DD]['weaponskill coronach (fixed)'], { n = 1, ce = 80, ve = 240 });
end);

t.test('a weaponskill that closes a skillchain is logged as one, its damage and the chain\'s together', function ()
    local s, r = logged();
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 3, 17, { { MOB, { { 185, 100, { 288, 200 } } } } }), 0);
    t.eq(r:last('enmity').key, 'weaponskill #17 (skillchain)');
    t.eq(r:last('enmity').changes, { { DD, 153 + 307, 461 + 923, 460, 1384, true } });
    t.eq(s:track(MOB).ledger[DD]['weaponskill #17 (skillchain)'], { n = 1, ce = 460, ve = 1384 });
end);

t.test('Accomplice moves half the target\'s CE and VE to the thief on every mob in the thief\'s reach', function ()
    local w = fakeWorld();
    local s, r = logged(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 1000 } } } }), 0);          -- 1738 / 5515
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 153 / 461
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);          -- 353 / 1361, the ninja absent
    s:observe(action(DD, 6, 84, { { TANK, { { 100, 0 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 869, 2758, true });
    t.eq(values(s, MOB, DD), { 153 + 869, 461 + 2757, true });
    -- The ninja had no entry on the bat: one is made, with no engage bonus while the tank is active on it.
    t.eq(values(s, MOB2, TANK), { 177, 681, true });
    t.eq(values(s, MOB2, DD), { 176, 680, true });
    local line = r:last('effect');
    t.eq({ line.id, line.to, line.rule, line.percent }, { TANK, DD, 'accomplice', 50 });
    t.eq(s:track(MOB).ledger[TANK]['ability accomplice from Dd (gave 50%)'], { n = 1, ce = -869, ve = -2757 });
    t.eq(s:track(MOB).ledger[DD]['ability accomplice (took 50%)'], { n = 1, ce = 869, ve = 2757 });
    -- A mob beyond the thief's 20.6 yalms is left alone.
    w.distances[DD] = 21;
    s:observe(action(DD, 6, 84, { { TANK, { { 100, 0 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 869, 2758, true });
    t.eq(values(s, MOB, DD), { 1022, 3218, true });
end);

t.test('Collaborator gives half the thief\'s enmity to the target on Horizon, and takes a quarter of the target\'s on LandSandBoat', function ()
    local w = fakeWorld();
    local s = new(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 1000 } } } }), 0);          -- 1738 / 5515
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);             -- 153 / 461
    s:observe(action(DD, 6, 236, { { TANK, { { 100, 0 } } } }), 0);
    t.eq(values(s, MOB, DD), { 77, 231, true });
    t.eq(values(s, MOB, TANK), { 1738 + 76, 5515 + 230, true });
    -- The target out of enmity range gains nothing; the thief still gives.
    w.distances[TANK] = 30;
    s:observe(action(DD, 6, 236, { { TANK, { { 100, 0 } } } }), 0);
    t.eq(values(s, MOB, DD), { 39, 116, true });
    t.eq(values(s, MOB, TANK), { 1738 + 76, 5515 + 230, true });

    local lsb = sim.new(fakeWorld(), { levelRange = levels, values = 'lsb' });
    lsb:observe(action(TANK, 1, 0, { { MOB, { { 1, 1000 } } } }), 0);
    lsb:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    lsb:observe(action(DD, 6, 236, { { TANK, { { 100, 0 } } } }), 0);
    t.eq(values(lsb, MOB, TANK), { 1738 - 434, 5515 - 1378, true });
    t.eq(values(lsb, MOB, DD), { 153 + 434, 461 + 1378, true });
end);

t.test('a transfer\'s receiver gains on their own Enmity, as the particles hold it', function ()
    local s, f = filtered(nil, { max = 4, jitter = 0 });
    pin(f, TANK, CLASS.melee, 100);
    pin(f, DD, CLASS.ability, 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 1000 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    -- Horizon's Collaborator: the ninja gives 76 / 230; the tank at +100 takes double.
    s:observe(action(DD, 6, 236, { { TANK, { { 100, 0 } } } }), 0);
    local list = s:list(MOB);
    t.eq({ list:value(TANK, 1) }, { 3476 + 152, 10000 });
    t.eq({ list:value(DD, 1) }, { 77, 231 });
end);

t.test('High Jump takes half its user\'s CE and VE on the mob, three tenths as a support job, after its damage', function ()
    local w = fakeWorld();
    w.ids[TANK].member.mainJob, w.ids[TANK].member.subJob = 'DRG', 'WAR';
    w.ids[DD].member.mainJob, w.ids[DD].member.subJob = 'WAR', 'DRG';
    local s, r = logged(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 1000 } } } }), 0);          -- 1738 / 5515
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 1000 } } } }), 0);            -- 1538 / 4615
    -- The jump's own 100 damage first: +153 / +461, then half.
    s:observe(action(TANK, 6, HIGH_JUMP, { { MOB, { { 110, 100 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 946, 2988, true });
    t.eq(r:last('effect'), { mob = MOB, id = TANK, rule = 'highJump', percent = 50 });
    t.eq(s:track(MOB).ledger[TANK]['ability high_jump (lowered 50%)'], { n = 1, ce = 946 - 1738, ve = 2988 - 5515 });
    s:observe(action(DD, 6, HIGH_JUMP, { { MOB, { { 158, 0 } } } }), 0);
    t.eq(values(s, MOB, DD), { 1077, 3231, true }, 'a miss still lowers');
    -- Someone with no entry on the mob is left alone; another mob's list is untouched.
    s:observe(action(HEALER, 6, HIGH_JUMP, { { MOB, { { 158, 0 } } } }), 0);
    t.eq(s:list(MOB):has(HEALER), false);
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 6, HIGH_JUMP, { { MOB, { { 158, 0 } } } }), 0);
    t.eq(values(s, MOB2, TANK), { 353, 1361, true });
    -- Without Dragoon as main or support, the ability's enmity is nothing more than its table row.
    w.ids[HEALER].member.subJob = 'BLM';
    s:observe(action(HEALER, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(HEALER, 6, HIGH_JUMP, { { MOB2, { { 110, 10 } } } }), 0);
    t.eq(values(s, MOB2, HEALER), { 153 + 15, 461 + 46, true });
end);

t.test('Super Jump sets its user to 1 CE and 0 VE on every mob within 75 yalms that lists them', function ()
    local w = fakeWorld();
    w.ids[TANK].member.mainJob = 'DRG';
    local s, r = logged(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 1000 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 1000 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 1000 } } } }), 0);
    w.positions[TANK], w.positions[MOB], w.positions[MOB2] = { 0, 0 }, { 10, 0 }, { 80, 0 };
    s:observe(action(TANK, 6, SUPER_JUMP, { { MOB, { { 100, 0 } } } }), 0);
    t.eq(values(s, MOB, TANK), { 1, 0, true });
    t.eq(values(s, MOB2, TANK), { 1738, 5515, true }, 'out of range');
    t.eq(values(s, MOB, DD), { 1538, 4615, true }, 'nobody else');
    t.eq(r:last('effect'), { mob = MOB, id = TANK, rule = 'superJump', ce = 1, ve = 0, distance = 10 });
    t.eq(s:track(MOB).ledger[TANK]['ability super_jump (set)'], { n = 1, ce = 1 - 1738, ve = -5515 });
    -- Unplaced, the mob counts as within reach.
    w.positions[MOB2] = nil;
    s:observe(action(TANK, 6, SUPER_JUMP, { { MOB, { { 100, 0 } } } }), 0);
    t.eq(values(s, MOB2, TANK), { 1, 0, true });
end);

--[[
* The research registry: what the sim hands it.  See test_research for what
* the registry does with an observation.
--]]

local SMN, AVATAR, WYVERN = 0x0001E243, 0x0100A030, 0x0100A031;

-- fakeWorld plus a summoner and their Carbuncle, and a wyvern belonging to the tank.
local function researchWorld()
    local w = fakeWorld();
    w.ids[SMN] = { kind = 'alliance', name = 'Summoner', member = { mainJob = 'SMN', subJob = 'WHM', mainLevel = 75 } };
    w.ids[AVATAR] = { kind = 'pet', name = 'Carbuncle' };
    w.ids[WYVERN] = { kind = 'pet', name = 'Wyvern' };
    w.pets = { [AVATAR] = SMN, [WYVERN] = TANK };
    function w:petOwner(id) return self.pets[id]; end
    return w;
end

-- A registry that keeps what it is offered.
local function fakeResearch()
    local r = { seen = {}, cost = 0, live = {} };
    function r:observe(obs) self.seen[#self.seen + 1] = copy(obs); return 0; end
    function r:charge(seconds) self.cost = self.cost + seconds; end
    function r:setLive(key, h) self.live[key] = h; self.told = { key, h }; end
    return r;
end

local function researched(w, opts)
    local r = fakeResearch();
    opts = opts or {};
    opts.levelRange, opts.research = levels, r;
    return sim.new(w or researchWorld(), opts), r;
end

t.test('every attack is offered to the registry with the active entries\' neutral totals, the tier, and Cover\'s call', function ()
    local w = researchWorld();
    local s, r = researched(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);     -- 353 / 1361
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);       -- 153 / 461
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 0);
    t.eq(r.seen[1], {
        mob = MOB, target = TANK, switch = false, clean = true, covered = false, rule = 'lsb', loss = 25,
        rows = { { id = TANK, total = 1714, last = 0 }, { id = DD, total = 614, last = 0 } }, avatars = {},
    });
    -- The totals are taken before the swing's damage lowers the target's CE.
    t.eq(ce(s, MOB, TANK), 341);

    -- A single-target spell too, and a switch is marked.
    s:observe(action(MOB, 4, 144, { { DD, { { 2, 10 } } } }), 0);
    t.eq({ r.seen[2].target, r.seen[2].switch }, { DD, true });
    -- An inactive entry is left out of the rows.
    s:observe({ kind = 'message', message = 20, actorId = MOB, targetId = DD }, 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 0);
    t.eq(r.seen[3].rows, { { id = TANK, total = 1702, last = 0 } });

    -- A round Cover took is offered as such.
    w.ids[TANK].member.mainJob = 'PLD';
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 1000 } } } }), 0);
    s:observe(action(TANK, 6, 79, { { DD, { { 230, 114 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 0);
    t.eq(r.seen[#r.seen].covered, true);

    -- An outsider's swing goes through with no entry; an area spell says nothing.
    s:observe(action(MOB, 1, 0, { { STRANGER, { { 1, 10 } } } }), 0);
    t.eq(r.seen[#r.seen].target, STRANGER);
    local before = #r.seen;
    s:observe(action(MOB, 4, 176, { { TANK, { { 2, 10 } } }, { DD, { { 2, 10 } } } }), 0);
    t.eq(#r.seen, before);
end);

t.test('a list joined mid-fight is offered as not clean', function ()
    local w = researchWorld();
    w.engagedIds[MOB] = true;
    local s, r = researched(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 0);
    t.eq(r.seen[1].clean, false);
end);

t.test('the shadow rule can change mid-session, and the registry is told what the sim now runs', function ()
    local s, r = researched(nil, { shadowRule = 'lsb' });
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 }, { 31, 1 } } } }), 0);
    local ce = s:list(MOB):get(DD);
    s:setShadowRule('era');
    t.eq(s.shadowRule, 'era');
    t.eq(r.told, { 'shadowAbsorb', 'era' });
    -- The last shadow goes free under the era rule.
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 } } } }), 0);
    t.eq((s:list(MOB):get(DD)), ce);
    s:setShadowRule('nonsense');
    t.eq(s.shadowRule, 'lsb');
    t.eq(r.told, { 'shadowAbsorb', 'lsb' });
    -- Under LSB's rule the next absorb pays, after the cast's own 1 CE.
    s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 } } } }), 0);
    t.eq((s:list(MOB):get(DD)), ce + 1 - 25);
end);

t.test('the registry and the log can be attached and detached with lists already open', function ()
    local s = new();
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(s:track(MOB).lastShadows, nil);
    local r = fakeResearch();
    s:setResearch(r);
    t.eq(s.research, r);
    t.eq(s:track(MOB).lastShadows, {});
    t.eq(s:track(MOB).avatars, {});
    -- The list was open before the registry heard anything: its counts are short, so it's not offered.
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 0);
    t.eq(#r.seen, 0, 'a list open before the registry is not offered');
    -- A list opened since is.
    s:observe(action(DD, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB2, { { 1, 100 } } } }), 0);
    s:observe(action(MOB2, 1, 0, { { DD, { { 1, 10 } } } }), 0);
    t.eq(#r.seen, 1, 'attacks on a list opened since reach it');
    -- Changing the shadow rule closes the open lists to the registry too.
    s:setShadowRule('era');
    s:observe(action(MOB2, 1, 0, { { DD, { { 1, 10 } } } }), 0);
    t.eq(#r.seen, 1, 'not after the rule changed under it');
    s:setResearch(nil);
    s:observe(action(MOB2, 1, 0, { { DD, { { 1, 10 } } } }), 0);
    t.eq(#r.seen, 1);

    local written = {};
    local log = { cost = 0 };
    function log:write(kind, fields) written[#written + 1] = kind; end
    function log:charge() end
    t.eq(s:track(MOB).ledger, nil);
    s:setLog(log);
    t.eq(s.log, log);
    t.eq({ s:track(MOB).ledger, s:track(MOB).bounds, s:track(MOB).impossible }, { {}, {}, {} });
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 0);
    t.truthy(#written > 0, 'the log now hears the sim');
    s:setLog(nil);
    local n = #written;
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 0);
    t.eq(#written, n);
end);

t.test('the last shadow a member loses is counted for the registry under either rule, only when the count is known', function ()
    for _, rule in ipairs({ 'lsb', 'era' }) do
        local s, r = researched(nil, { shadowRule = rule });
        s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
        s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
        -- Three shadows from Ichi: two absorbs leave one, the third takes the last.
        s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 0);
        s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 }, { 31, 1 } } } }), 0);
        t.eq(s:track(MOB).lastShadows[DD], nil, rule .. ': shadows remain');
        s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 } } } }), 0);
        t.eq(s:track(MOB).lastShadows[DD], 1, rule .. ': the last went');
        -- Unseen shadows: the count is unknown, so both rules charge and nothing is counted.
        s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 } } } }), 0);
        t.eq(s:track(MOB).lastShadows[DD], 1, rule .. ': unknown count');
        -- A mob skill's shadows cost nothing under either rule.
        s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 0);
        s:observe(action(MOB, 11, 1, { { DD, { { 31, 3 } } } }), 0);
        t.eq(s:track(MOB).lastShadows[DD], 1, rule .. ': a mob skill');
        -- Blink's shadows neither.
        s:observe(action(HEALER, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
        s:observe(action(HEALER, 4, BLINK, { { HEALER, { { 230, 36 } } } }), 0);
        s:observe(action(MOB, 1, 0, { { HEALER, { { 31, 1 } } } }), 0);
        t.eq(s:track(MOB).lastShadows[HEALER], nil, rule .. ': Blink');
        -- The next attack carries the counts, under the rule that was run.
        s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 0);
        local last = r.seen[#r.seen];
        t.eq(last.rule, rule);
        t.eq(last.rows[1].id, DD);
        t.eq(last.rows[1].last, 1);
        t.eq(last.rows[2].last, 0);
        -- Ichi's 1 CE twice; under LSB the last shadow cost 25 CE that era spared.
        t.eq(ce(s, MOB, DD), rule == 'lsb' and 353 + 2 - 25 * 4 or 353 + 2 - 25 * 3, rule);
    end
end);

t.test('a summoner\'s avatar builds up the neutral enmity it generates on each mob, by source, decaying like a list', function ()
    local w = researchWorld();
    local s, r = researched(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    -- A Blood Pact for 260 at divisor 52: 400 CE, 1200 VE, then its table 1/60.  The avatar occupies the list.
    s:observe(action(AVATAR, 13, 585, { { MOB, { { 317, 260 } } } }), 0);
    t.eq(s:list(MOB).others[AVATAR], true);
    t.eq(s:list(MOB):has(AVATAR), false, 'not modelled');
    -- Its melee: two hits for 26, a miss.
    s:observe(action(AVATAR, 1, 0, { { MOB, { { 1, 26 }, { 15, 0 }, { 67, 26 } } } }), 0);
    t.eq(s:track(MOB).avatars[SMN], { pet = AVATAR, pactCe = 401, pactVe = 1260, otherCe = 80, otherVe = 240 });

    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 0);
    t.eq(r.seen[1].avatars, { { pet = AVATAR, master = SMN, pactCe = 401, pactVe = 1260, otherCe = 80, otherVe = 240 } });
    t.eq(r.seen[1].rows, { { id = TANK, total = 1714, last = 0 } }, 'the summoner has no entry until they act');

    -- The mob on the avatar itself is offered too.
    s:observe(action(MOB, 1, 0, { { AVATAR, { { 1, 10 } } } }), 0);
    t.eq(r.seen[2].target, AVATAR);

    -- VE decays as one entry's would, shared between the sources in proportion, and floors at zero; CE stays.
    s:advance(0.4 * 5 + 0.01);
    local a = s:track(MOB).avatars[SMN];
    t.eq({ a.pactCe, a.otherCe, a.pactVe + a.otherVe }, { 401, 80, 1500 - 24 * 5 });
    t.truthy(math.abs(a.pactVe / a.otherVe - 1260 / 240) < 1e-9, 'in proportion');
    s:advance(0.4 * 70);
    t.eq(s:track(MOB).avatars[SMN], { pet = AVATAR, pactCe = 401, pactVe = 0, otherCe = 80, otherVe = 0 });

    -- Another mob keeps its own count, and a released avatar's replacement carries on the summoner's.
    s:observe(action(AVATAR, 13, 585, { { MOB2, { { 317, 26 } } } }), 30.01);
    t.eq(s:track(MOB2).avatars[SMN], { pet = AVATAR, pactCe = 41, pactVe = 180, otherCe = 0, otherVe = 0 });
    w.ids[AVATAR + 2] = { kind = 'pet', name = 'Fenrir' };
    w.pets[AVATAR + 2] = SMN;
    s:observe(action(AVATAR + 2, 13, 600, { { MOB, { { 317, 26 } } } }), 30.01);
    t.eq(s:track(MOB).avatars[SMN], { pet = AVATAR + 2, pactCe = 442, pactVe = 180, otherCe = 80, otherVe = 0 });

    -- A ward on the party is in-range enmity on every mob this avatar has acted on, once an ally: not
    -- on the mob only its predecessor fought.
    s:observe(action(AVATAR + 2, 13, 514, { { SMN, { { 230, 0 } } }, { TANK, { { 230, 0 } } } }), 30.01);
    t.eq(s:track(MOB).avatars[SMN], { pet = AVATAR + 2, pactCe = 444, pactVe = 300, otherCe = 80, otherVe = 0 });
    t.eq(s:track(MOB2).avatars[SMN], { pet = AVATAR, pactCe = 41, pactVe = 180, otherCe = 0, otherVe = 0 });

    -- CE and VE each cap across both sources.
    s:observe(action(AVATAR + 2, 13, 600, { { MOB, { { 317, 20000 } } } }), 30.01);
    t.eq(s:track(MOB).avatars[SMN], { pet = AVATAR + 2, pactCe = 10000 - 80, pactVe = 10000, otherCe = 80, otherVe = 0 });
end);

t.test('a hate reset lowers the last shadows counted on a member, or an avatar\'s generated enmity, and a death as holder clears them', function ()
    local w = researchWorld();
    local s = researched(w, { mobskills = SKILLS });
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 }, { 31, 1 }, { 31, 1 } } } }), 0);
    t.eq(s:track(MOB).lastShadows[DD], 1);
    -- A mob skill that lowers hate by a quarter leaves three quarters of it.
    s:observe(action(MOB, 11, LOWERS, { { DD, { { 185, 10 } } } }), 0);
    t.eq(s:track(MOB).lastShadows[DD], 0.75);
    -- A reset leaves none.
    s:observe(action(MOB, 11, RESETS, { { DD, { { 185, 10 } } } }), 0);
    t.eq(s:track(MOB).lastShadows[DD], 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 } } } }), 0);
    s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 }, { 31, 1 }, { 31, 1 } } } }), 0);
    t.eq(s:track(MOB).lastShadows[DD], 1);
    -- Dying while holding hate clears the entry, and the count with it.
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 1000 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 0);
    s:observe({ kind = 'message', message = 20, actorId = MOB, targetId = DD }, 0);
    t.eq(s:list(MOB):has(DD), false);
    t.eq(s:track(MOB).lastShadows[DD], nil);

    -- The avatar's generated enmity goes with a reset that lands on it, not with a miss.
    s:observe(action(AVATAR, 13, 585, { { MOB, { { 317, 260 } } } }), 0);
    s:observe(action(MOB, 11, RESETS_IF_LANDED, { { AVATAR, { { 15, 0 } } } }), 0);
    t.eq(s:track(MOB).avatars[SMN], { pet = AVATAR, pactCe = 401, pactVe = 1260, otherCe = 0, otherVe = 0 });
    s:observe(action(MOB, 11, LOWERS, { { AVATAR, { { 185, 10 } } } }), 0);
    t.eq(s:track(MOB).avatars[SMN], { pet = AVATAR, pactCe = 300.75, pactVe = 945, otherCe = 0, otherVe = 0 });
    s:observe(action(MOB, 11, RESETS_IF_LANDED, { { AVATAR, { { 185, 10 } } } }), 0);
    t.eq(s:track(MOB).avatars[SMN], { pet = AVATAR, pactCe = 0, pactVe = 0, otherCe = 0, otherVe = 0 });
end);

t.test('a pet that isn\'t a summoner\'s avatar, or nobody\'s, generates nothing for the registry', function ()
    local w = researchWorld();
    w.ids[AVATAR + 5] = { kind = 'pet', name = 'Stray' };
    local s, r = researched(w);
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(WYVERN, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(AVATAR + 5, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    t.eq(s:track(MOB).avatars, {});
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 0);
    t.eq(r.seen[1].avatars, {});
    -- Nor is anything kept without a registry.
    local plain = new(researchWorld());
    plain:observe(action(AVATAR, 13, 585, { { MOB, { { 317, 260 } } } }), 0);
    plain:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 0);
    t.eq(plain:track(MOB).avatars, nil);
    t.eq(plain:track(MOB).lastShadows, nil);
end);

t.test('the registry\'s work is charged to it and left out of the filter\'s frame budget', function ()
    local f = filter.new({ max = 64, jitter = 0, clock = os.clock });
    local s, r = researched(nil, { filter = f });
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    local spent = f.spent;
    local quick = r.observe;
    r.observe = function (self, obs)
        local deadline = os.clock() + 0.01;
        while os.clock() < deadline do end
        return quick(self, obs);
    end;
    s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), 0.5);
    t.truthy(r.cost >= 0.009, ('charged %.4f'):format(r.cost));
    t.truthy(f.spent - spent < 0.01, ('the frame was charged %.4f'):format(f.spent - spent));
end);

t.test('the jumps lower the last shadows counted for the registry with the enmity', function ()
    local w = researchWorld();
    w.ids[DD].member.mainJob, w.ids[DD].member.subJob = 'DRG', 'NIN';
    local s = researched(w);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 }, { 31, 1 }, { 31, 1 } } } }), 0);
    t.eq(s:track(MOB).lastShadows[DD], 1);
    s:observe(action(DD, 6, HIGH_JUMP, { { MOB, { { 158, 0 } } } }), 0);
    t.eq(s:track(MOB).lastShadows[DD], 0.5);
    s:observe(action(DD, 6, SUPER_JUMP, { { MOB, { { 100, 0 } } } }), 0);
    t.eq(s:track(MOB).lastShadows[DD], 0);
end);

t.test('a restore is logged, and research counts come back with the lists', function ()
    local w = researchWorld();
    local s = researched(w);
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    s:observe(action(DD, 4, UTSUSEMI_ICHI, { { DD, { { 230, 66 } } } }), 0);
    s:observe(action(MOB, 1, 0, { { DD, { { 31, 1 }, { 31, 1 }, { 31, 1 } } } }), 0);
    s:observe(action(AVATAR, 13, 585, { { MOB, { { 317, 260 } } } }), 0);
    local saved = s:export();
    local fresh, r = researched(w);
    fresh.log = recorder();
    fresh:import(saved, 5, 1);
    t.eq(fresh:track(MOB).lastShadows[DD], 1);
    t.eq(fresh:track(MOB).avatars[SMN].pactCe, 401);
    t.eq(fresh.log:last('restore'), { lists = 1, elapsed = 1, mobs = { MOB } });
    fresh:observe(action(MOB, 1, 0, { { DD, { { 1, 10 } } } }), 5);
    t.eq(r.seen[1].rows[1].last, 1);
end);

local priors = require('priors');

local function darkKnight()
    local w = fakeWorld();
    w.ids[DD].member = { mainJob = 'DRK', subJob = 'WAR', mainLevel = 75 };
    w.distances[TANK], w.distances[DD] = 3, 3;
    return w;
end

local function byJob(id)
    return priors.forJob(id == DD and 'DRK' or 'PLD');
end

local function rankOf(f, id, lane)
    return f.bonus[(lane * filter.PLAYERS + f.players[id]) * filter.SLOTS + filter.MUTED];
end

t.test('a dark knight main under Souleater gains on each particle\'s Muted Soul rank; a sub, or without it, gains as one', function ()
    local w = darkKnight();
    math.randomseed(5);
    local f = filter.new({ max = 64, jitter = 0, prior = byJob });
    local r = recorder();
    local s = sim.new(w, { levelRange = levels, filter = f, log = r });
    pin(f, DD, CLASS.melee, 0);
    local ranked = 0;
    for lane = 1, f.count do
        if rankOf(f, DD, lane) == 50 then
            ranked = ranked + 1;
        end
    end
    t.truthy(ranked >= 8, ('some particles carry five merits: %d'):format(ranked));

    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 0);
    local list = s:list(MOB);
    local ce0 = list:value(DD, 0);
    for lane = 1, f.count do
        t.eq((list:value(DD, lane)), ce0, 'without Souleater, lane ' .. lane);
    end
    t.eq(r:last('action').muted, nil);

    s:observe(action(DD, 6, 49, { { DD, { { 100, 0 } } } }), 1);
    local before = {};
    for lane = 0, f.count do
        before[lane] = list:value(DD, lane);
    end
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 1);
    t.eq(r:last('action').muted, true);
    local gained0 = list:value(DD, 0) - before[0];
    t.truthy(gained0 > 100, ('the neutral replay gained %d'):format(gained0));
    for lane = 1, f.count do
        local rank, gained = rankOf(f, DD, lane), list:value(DD, lane) - before[lane];
        if rank == 0 then
            t.eq(gained, gained0, 'no merits, lane ' .. lane);
        else
            t.truthy(gained < gained0 and gained >= gained0 * (100 - rank) / 100 - 2,
                ('rank %d gained %d of %d, lane %d'):format(rank / 10, gained, gained0, lane));
        end
    end

    w.ids[DD].member = { mainJob = 'WAR', subJob = 'DRK', mainLevel = 75 };
    for lane = 0, f.count do
        before[lane] = list:value(DD, lane);
    end
    s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), 2);
    t.eq(r:last('action').muted, nil);
    gained0 = list:value(DD, 0) - before[0];
    for lane = 1, f.count do
        t.eq(list:value(DD, lane) - before[lane], gained0, 'a sub has no merits, lane ' .. lane);
    end
end);

t.test('a mob staying on the tank through a dark knight\'s Souleater is read as Muted Soul merits', function ()
    local w = darkKnight();
    math.randomseed(5);
    local f = filter.new({ max = 256, jitter = 0, prior = byJob });
    local s = sim.new(w, { levelRange = levels, filter = f });
    pin(f, TANK, CLASS.melee, 0);
    pin(f, DD, CLASS.melee, 0);
    local before = f:posterior(DD).muted[5];
    s:observe(action(TANK, 1, 0, { { MOB, { { 1, 600 } } } }), 0);
    s:observe(action(DD, 6, 49, { { DD, { { 100, 0 } } } }), 0);
    -- At neutral the dark knight passes the tank on the eighth swing; at five merits, never.
    for i = 1, 14 do
        s:observe(action(DD, 1, 0, { { MOB, { { 1, 100 } } } }), i);
        s:observe(action(MOB, 1, 0, { { TANK, { { 1, 10 } } } }), i);
    end
    local list = s:list(MOB);
    local tce, tve = list:value(TANK, 0);
    local dce, dve = list:value(DD, 0);
    t.truthy(dce + dve > tce + tve, 'at neutral the dark knight has passed the tank');
    local after = f:posterior(DD).muted[5];
    t.truthy(after > before + 0.3, ('five merits went from %.2f to %.2f'):format(before, after));
    t.truthy(f:posterior(DD).muted[0] < 0.2, ('no merits fell to %.2f'):format(f:posterior(DD).muted[0]));
end);

return t.done();

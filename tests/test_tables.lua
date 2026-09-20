--[[
* The vendored enmity tables: known entries hold their values, every entry is
* well formed, and regenerating from the pinned sources reproduces the files
* byte for byte.
*
* The regeneration test needs a LandSandBoat checkout holding the pinned
* commit (../LandSandBoat, or $ENMETRY_LSB) and skips without one.
*
* Run: luajit tests/test_tables.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local tables = require('tables');

local TRUST = { era = true, lsb = true, unknown = true };

local function pick(e, fields)
    local out = {};
    for i, f in ipairs(fields) do
        out[i] = e[f] == nil and 'nil' or e[f];
    end
    return out;
end

local ACTION = { 'name', 'ce', 've', 'ceTrust', 'veTrust' };

t.test('known abilities keep their values and trust', function ()
    local a = tables.actions.abilities;
    t.eq(pick(a[35], ACTION), { 'provoke', 1, 1800, 'era', 'era' });
    t.eq(pick(a[32], { 'name', 've', 'perTarget' }), { 'warcry', 300, true });
    -- The era table verified Sentinel's VE at twice LSB's.
    -- The era table's 1800 VE is 900 under Sentinel's own +100.
    t.eq(pick(a[48], ACTION), { 'sentinel', 1, 900, 'era', 'era' });
    t.eq({ a[48].lsb, a[48].lsbCe, a[48].lsbVe }, { nil, nil, nil }, 'values that agree carry no second copy');
    -- Where the era table and LandSandBoat differ, both are data: the values setting picks.
    t.eq(pick(a[92], { 'name', 'ce', 've', 'lsbCe', 'lsbVe' }), { 'rampart', 1, 300, 320, 320 });
    t.eq(pick(a[16], ACTION), { 'mighty_strikes', 1, 300, 'lsb', 'lsb' });
    t.eq(pick(a[66], ACTION), { 'jump', 0, 0, 'unknown', 'unknown' });
    t.eq(pick(a[18], { 'name', 'cure', 'ceTrust' }), { 'benediction', 'formula', 'lsb' });
    t.eq(pick(a[190], { 'name', 'cure' }), { 'curing_waltz', 'formula' });
end);

t.test('known spells keep their values, trust and cure kind', function ()
    local s = tables.actions.spells;
    t.eq(pick(s[112], ACTION), { 'flash', 180, 1280, 'era', 'era' });
    t.eq(pick(s[1], { 'name', 'cure', 'ce', 've' }), { 'cure', 'formula', 0, 0 });
    t.eq(pick(s[5], { 'name', 'cure', 'ce', 've', 'ceTrust' }), { 'cure_v', 'fixed', 400, 600, 'era' });
    t.eq(pick(s[645], { 'name', 'cure', 'ce', 've' }), { 'exuviation', 'fixed', 640, 640 });
end);

t.test('Horizon deltas are applied over the era values', function ()
    local s = tables.actions.spells;
    t.eq(pick(s[345], ACTION), { 'hojo_ni', 40, 450, 'era', 'era' });
    t.eq(pick(s[348], ACTION), { 'kurayami_ni', 40, 450, 'era', 'era' });
    t.eq(pick(s[344], ACTION), { 'hojo_ichi', 80, 240, 'era', 'era' });
end);

t.test('the model constants from the era table are present', function ()
    local m = tables.actions.misc;
    t.eq(m.firstEngage, { ce = 200, ve = 900, trust = 'era' });
    t.eq(m.shadowAbsorb, { ce = -25, ve = 0, trust = 'era' });
end);

t.test('the weaponskills with fixed enmity keep it, and nothing else is listed', function ()
    local w = tables.actions.weaponskills;
    t.eq(pick(w[216], ACTION), { 'coronach', 80, 240, 'lsb', 'lsb' });
    t.eq(pick(w[200], ACTION), { 'namas_arrow', 160, 480, 'lsb', 'lsb' });
    local count = 0;
    for _ in pairs(w) do
        count = count + 1;
    end
    t.eq(count, 2);
end);

t.test('every action entry is well formed', function ()
    for _, kind in ipairs({ 'abilities', 'spells', 'weaponskills' }) do
        for id, e in pairs(tables.actions[kind]) do
            local where = ('%s[%d]'):format(kind, id);
            t.truthy(type(e.name) == 'string', where .. '.name');
            t.truthy(type(e.ce) == 'number' and e.ce == math.floor(e.ce), where .. '.ce');
            t.truthy(type(e.ve) == 'number' and e.ve == math.floor(e.ve), where .. '.ve');
            t.truthy(TRUST[e.ceTrust] and TRUST[e.veTrust], where .. ' trust');
            t.truthy(e.cure == nil or e.cure == 'formula' or e.cure == 'fixed', where .. '.cure');
        end
    end
end);

t.test('known mobskills keep their hate effect', function ()
    local m = tables.mobskills;
    local FIELDS = { 'name', 'effect', 'percent', 'conditional', 'trust' };
    t.eq(pick(m[1], FIELDS), { 'combo', 'none', 'nil', 'nil', 'lsb' });
    t.eq(pick(m[2060], FIELDS), { 'brainjack', 'reset', 'nil', true, 'lsb' });
    t.eq(pick(m[2221], FIELDS), { 'hell_scissors', 'reset', 'nil', false, 'lsb' });
    t.eq(pick(m[1046], FIELDS), { 'horrid_roar_2', 'reduce', 45, false, 'lsb' });
    t.eq(pick(m[1945], FIELDS), { 'provoke', 'none', 'nil', 'nil', 'unknown' });
    -- Purson resets on Great Whirlwind from its own script.
    t.eq(pick(m[803], FIELDS), { 'great_whirlwind', 'none', 'nil', 'nil', 'unknown' });
    t.eq(tables.scriptedMobs[168]['Purson'], true);
    t.eq(tables.scriptedMobs[24]['Flockbock'], true);
end);

t.test('every mobskill effect is one of the three, reductions carry a percent', function ()
    local resets = {};
    for id, s in pairs(tables.mobskills) do
        local where = ('mobskills[%d]'):format(id);
        t.truthy(s.effect == 'reset' or s.effect == 'reduce' or s.effect == 'none', where .. '.effect');
        t.truthy((s.effect == 'reduce') == (s.percent ~= nil), where .. '.percent');
        t.truthy(TRUST[s.trust], where .. '.trust');
        if s.effect == 'reset' then
            resets[s.name] = true;
        end
    end
    local count = 0;
    for _ in pairs(resets) do
        count = count + 1;
    end
    -- DESIGN.md section 7: 25 scripts are exactly mob:resetEnmity(target).
    t.eq(count, 25);
end);

t.test('level ranges resolve by server id', function ()
    -- West Ronfaure (100): a Wild Rabbit, and a Wayward Worm placeholder with no level.
    t.eq({ tables.levelRange(0x01064006) }, { 1, 1 });
    t.eq({ tables.levelRange(17186822) }, { 1, 1 });
    t.eq({ tables.levelRange(17187301) }, {});
    t.eq({ tables.levelRange(0x0100FFFF) }, {});
    t.eq({ tables.levelRange(0x00012345) }, {}, 'a player id');
end);

t.test('every zone\'s runs are sorted, disjoint and sane', function ()
    for zone, runs in pairs(tables.moblevels) do
        t.truthy(#runs > 0 and #runs % 4 == 0, ('zone %d length'):format(zone));
        local last = -1;
        for i = 1, #runs, 4 do
            local first, final, lo, hi = runs[i], runs[i + 1], runs[i + 2], runs[i + 3];
            local where = ('zone %d run at %d'):format(zone, i);
            t.truthy(first > last and final >= first and final < 4096, where .. ' order');
            t.truthy(lo >= 1 and hi >= lo and hi <= 255, where .. ' levels');
            last = final;
        end
    end
end);

t.test('every run is found by the lookup at both ends', function ()
    for zone, runs in pairs(tables.moblevels) do
        for i = 1, #runs, 4 do
            local base = 0x01000000 + zone * 4096;
            t.eq({ tables.levelRange(base + runs[i]) }, { runs[i + 2], runs[i + 3] });
            t.eq({ tables.levelRange(base + runs[i + 1]) }, { runs[i + 2], runs[i + 3] });
        end
    end
end);

t.test('Horizon overlays keep their values', function ()
    local o = tables.overlays;
    t.eq(o.buffs.sentinel, { status = 62, abilities = { 48 }, mainJob = 'PLD', enmity = 100, duration = 30, trust = 'era' });
    t.eq(o.buffs.sentinelSub, { status = 62, abilities = { 48 }, subJob = 'PLD', enmity = 50, duration = 30, trust = 'unknown' });
    t.eq(o.conditional.collaborator, { abilities = { 236 }, transfer = 50, trust = 'era' });
    t.eq(o.avatarGear[15366], { name = 'evokers_pigaches_+1', avatarEnmity = -4, trust = 'era' });
    t.eq(o.avatarGear[15679], { name = 'summoners_pigaches_+1', avatarEnmity = 2, trust = 'era' });
    t.eq(o.buffs.yonin, { status = 420, abilities = { 248 }, mainJob = 'NIN', enmity = 10, duration = 300, trust = 'era' });
    t.eq(o.buffs.defender, { status = 57, abilities = { 33 }, lossReduction = 25, duration = 180, trust = 'era' });
    t.eq(o.buffs.souleater, { status = 63, abilities = { 49 }, duration = 60, trust = 'era' });
    t.eq(o.conditional.provokeDefender,
        { abilities = { 35 }, requires = 'defender', job = 'WAR', ceMain = 250, ceSub = 180, trust = 'era' });
    t.eq(o.conditional.utsusemiYonin,
        { spells = { 338, 339, 340 }, requires = 'yonin', ce = 160, ve = 480, trust = 'lsb' });
    t.eq(o.gear[15544], { name = 'sattva_ring', enmity = 5, trust = 'era' });
    t.eq(o.gear[13437], { name = 'healers_earring', enmity = -2, subJob = 'WHM', trust = 'era' });
    t.eq(o.effects.highJump, { abilities = { 67 }, job = 'DRG', lowerMain = 50, lowerSub = 30, trust = 'lsb' });
    t.eq(o.effects.superJump, { abilities = { 68 }, setCe = 1, setVe = 0, range = 75, trust = 'lsb' });
end);

--[[
* Regeneration.  Output goes to a scratch directory and is compared with the
* vendored files, ignoring CRs a Windows checkout may have added.
--]]
local WINDOWS = package.config:sub(1, 1) == '\\';

local function read(path)
    local f = io.open(path, 'rb');
    if f == nil then
        return nil;
    end
    local text = f:read('*a');
    f:close();
    return (text:gsub('\r\n', '\n'));
end

local scratch = os.tmpname();
os.remove(scratch);
os.execute(('mkdir "%s"'):format(scratch));

local interpreter = arg[-1] or 'luajit';
local command = ('"%s" tools/gentables.lua --out "%s" 2>&1'):format(interpreter, scratch);
-- cmd.exe strips the outermost quotes of a line holding more than two.
local p = io.popen(WINDOWS and ('"%s"'):format(command) or command);
local output = p:read('*a');
p:close();

-- LuaJIT's pclose doesn't report the exit status, so go by what it printed.
if output:find('not found in', 1, true) then
    print('SKIP  regeneration: ' .. output:match('[^\n]*'));
else
    t.test('regenerating from the pinned sources reproduces every vendored file', function ()
        for _, name in ipairs({ 'actions.lua', 'mobskills.lua', 'moblevels.lua', 'overlays.lua' }) do
            local fresh = read(scratch .. '/' .. name);
            local vendored = read('addon/data/' .. name);
            t.truthy(fresh ~= nil, name .. ' was generated:\n' .. output);
            t.truthy(fresh == vendored, name .. ' differs from its regeneration');
        end
    end);
end

os.execute(WINDOWS and ('rmdir /s /q "%s"'):format(scratch) or ('rm -rf "%s"'):format(scratch));

t.test('Enlight is a buff overlay granted by its spell, shown by its light on each swing, for a paladin main', function ()
    local e = tables.overlays.buffs.enlight;
    t.eq({ e.status, e.spells, e.proc, e.mainJob, e.enmity, e.duration }, { 274, { 310 }, 7, 'PLD', 10, 180 });
end);

t.test('the region table follows LandSandBoat\'s zone switch', function ()
    local r = tables.regions;
    t.eq({ r[110], r[48], r[91], r[33], r[130] }, { 4, 28, 36, 26, 16 });
    local count = 0;
    for zone, region in pairs(r) do
        t.truthy(type(zone) == 'number' and type(region) == 'number' and region >= 0 and region <= 45, tostring(zone));
        count = count + 1;
    end
    t.truthy(count > 200, 'zones mapped: ' .. count);
end);

t.test('Horizon\'s level table has its custom mobs by zone and name, job variants folded into one', function ()
    local h = tables.horizonlevels;
    t.eq(h[110]['Teratornis'], { 88, 88 });
    t.eq(h[154]['Fafnir'], { 90, 90 });
    t.eq(h[33]["Ul'aern"], { 70, 73 });
    t.eq(h[33]["Ul'aern (WAR)"], nil);
    for zone, mobs in pairs(h) do
        t.truthy(type(zone) == 'number', 'zone ids are numbers');
        for name, range in pairs(mobs) do
            t.truthy(type(name) == 'string' and range[1] >= 1 and range[1] <= range[2] and range[2] <= 200, name);
        end
    end
end);

t.done();

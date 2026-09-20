--[[
* One mob's hate list, against LandSandBoat's CEnmityContainer.
*
* Golden values that depend on float truncation were computed independently
* in Python with struct-packed float32, following the C++ expression order in
* enmity_container.cpp.  Where float32 and double disagree the test says so.
*
* Run: luajit tests/test_hatelist.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local hatelist = require('hatelist');

local A, B, C = 0x0001E240, 0x0001E241, 0x0001E242;

local function values(h, id)
    local ce, ve, active = h:get(id);
    return { ce, ve, active };
end

t.test('the mob-level divisors match battleutils', function ()
    -- level * 31 / 50 + 6, integer division
    t.eq(hatelist.damageDivisor(75), 52);
    t.eq(hatelist.damageDivisor(10), 12);
    t.eq(hatelist.damageDivisor(1), 6);
    -- level + 10 to 10, 20 + (level - 10) / 2 to 50, then (int16)(40 + (level - 50) * 0.6)
    t.eq(hatelist.cureDivisor(5), 15);
    t.eq(hatelist.cureDivisor(30), 30);
    t.eq(hatelist.cureDivisor(55), 43);
    t.eq(hatelist.cureDivisor(75), 55);
end);

t.test('damage dealt accrues on the mob-level divisor, with the first-engage bonus once', function ()
    local h = hatelist.new();
    -- 80/52*100 = 153, 240/52*100 = 461, plus 200/900 for opening an empty list.
    h:damage(A, 100, 75, 0, true);
    t.eq(values(h, A), { 353, 1361, true });

    h:damage(A, 100, 75, 0, true);
    t.eq(values(h, A), { 506, 1822, true });

    -- A second actor joins a list that is no longer empty.
    h:damage(B, 100, 75, 0, true);
    t.eq(values(h, B), { 153, 461, true });
end);

t.test('damage truncates through float32, not double', function ()
    local h = hatelist.new();
    h:damage(A, 1, 75, 0, true);
    local ce, ve = h:get(A);
    -- level 75, 13 damage: float32 gives VE 60 where double would give 59.
    h:damage(A, 13, 75, 0, true);
    t.eq({ h:get(A) }, { ce + 20, ve + 60, true });

    -- level 60 (divisor 43), 43 damage: float32 gives VE 239 where double gives 240.
    h:damage(B, 43, 60, 0, true);
    t.eq(values(h, B), { 80, 239, true });
end);

t.test('damage below one counts as one', function ()
    local h = hatelist.new();
    h:damage(A, 5, 75, 0, true);
    local ce, ve = h:get(A);
    h:damage(A, 0, 75, 0, true);
    -- 80/52 = 1, 240/52 = 4
    t.eq({ h:get(A) }, { ce + 1, ve + 4, true });
end);

t.test('the enmity bonus scales positive gains and is clamped to 0.5x..2x', function ()
    local h = hatelist.new();
    h:damage(A, 100, 75, 0, true);
    -- 353 + (float)153 * 1.5 = 582.5 -> 582
    h:damage(A, 100, 75, 50, true);
    t.eq(h:get(A), 582);

    -- +300 clamps to +100: 153 * 2, 461 * 2, and no bonus on an occupied list.
    h:damage(B, 100, 75, 300, true);
    t.eq(values(h, B), { 306, 922, true });

    -- -80 clamps to -50.
    h:damage(C, 100, 75, -80, true);
    t.eq(values(h, C), { 76, 230, true });
end);

t.test('an action from beyond enmity range contributes nothing but still opens the list', function ()
    local h = hatelist.new();
    -- UpdateEnmity zeroes the action, then adds the first-engage bonus regardless.
    h:damage(A, 100, 75, 0, false);
    t.eq(values(h, A), { 200, 900, true });

    h:damage(A, 100, 75, 0, false);
    t.eq(values(h, A), { 200, 900, true });

    h:damage(B, 100, 75, 0, false);
    t.eq(values(h, B), { 0, 0, true });
end);

t.test('cure enmity uses the level it is given, gets no first-engage bonus, and scales before truncating', function ()
    local h = hatelist.new();
    -- Cure target level 75: 40/55*300 = 218, 240/55*300 = 1309.
    h:cure(A, 75, 300, 0, true);
    t.eq(values(h, A), { 218, 1309, true });

    -- Level 30 target, divisor 30: 40/30*90 = 120, 240/30*90 = 720.
    h:cure(B, 30, 90, 0, true);
    t.eq(values(h, B), { 120, 720, true });

    -- float32: level 75, 55 healed gives VE 240 where double gives 239.
    h:cure(C, 75, 55, 0, true);
    t.eq(values(h, C), { 40, 240, true });
end);

t.test('a cure healing nothing counts as one HP; out of range it does nothing at all', function ()
    local h = hatelist.new();
    h:cure(A, 1, 0, 0, true);
    -- divisor 11: 40/11 = 3, 240/11 = 21
    t.eq(values(h, A), { 3, 21, true });

    h:cure(B, 75, 300, 0, false);
    t.eq(h:has(B), false);
end);

t.test('a fixed cure applies its own CE and VE times the bonus', function ()
    local h = hatelist.new();
    h:cureFixed(A, 400, 600, 0, true);
    t.eq(values(h, A), { 400, 600, true });
    h:cureFixed(A, 400, 600, 100, true);
    t.eq(values(h, A), { 1200, 1800, true });
end);

t.test('damage taken lowers CE by 1800 x damage / max HP, never VE', function ()
    local h = hatelist.new();
    h:damage(A, 400, 75, 0, true);   -- 815 / 2746
    h:attacked(A, 150, 1500, 0);     -- -180
    t.eq(values(h, A), { 635, 2746, true });

    -- 25% loss reduction: -135
    h:attacked(A, 150, 1500, 25);
    t.eq(values(h, A), { 500, 2746, true });

    -- Floors at zero.
    h:attacked(A, 1500, 1500, 0);
    t.eq(values(h, A), { 0, 2746, true });
end);

t.test('damage taken by someone not on the list changes nothing', function ()
    local h = hatelist.new();
    h:attacked(A, 150, 1500, 0);
    t.eq(h:has(A), false);
end);

t.test('VE decays 24 a tick, 60 a second at 2.5 Hz, and floors at zero; CE never decays', function ()
    local h = hatelist.new();
    h:damage(A, 100, 75, 0, true); -- 353 / 1361
    h:decay(1);
    t.eq(values(h, A), { 353, 1337, true });
    h:decay(5);
    t.eq(values(h, A), { 353, 1217, true });
    h:decay(1000);
    t.eq(values(h, A), { 353, 0, true });
end);

t.test('CE and VE are each capped independently', function ()
    local h = hatelist.new(10000);
    h:cureFixed(A, 9900, 10, 0, true);
    h:damage(A, 100, 75, 0, true);
    t.eq(values(h, A), { 10000, 471, true });

    local small = hatelist.new(500);
    small:damage(B, 1000, 75, 0, true);
    t.eq(values(small, B), { 500, 500, true });
end);

t.test('the highest active total holds hate, ties going to the current target', function ()
    local h = hatelist.new();
    t.eq(h:highest(), nil);

    h:cureFixed(A, 100, 100, 0, true);
    h:cureFixed(B, 150, 100, 0, true);
    t.eq(h:highest(), B);

    h:cureFixed(A, 50, 0, 0, true);
    -- Exact tie at 250: the mob stays on whoever it is already on.
    t.eq(h:highest(A), A);
    t.eq(h:highest(B), B);

    h:setActive(B, false);
    t.eq(h:highest(), A);
end);

t.test('an actor the model does not track still occupies the list for the first-engage check', function ()
    local h = hatelist.new();
    h:occupy(0x0001E999, false);
    t.eq(h.claimed, false);
    h:damage(A, 100, 75, 0, true);
    t.eq(values(h, A), { 153, 461, true });

    local claimedByOutsider = hatelist.new();
    claimedByOutsider:occupy(0x0001E999, true);
    t.eq(claimedByOutsider.claimed, true);
end);

t.test('a claim puts the actor on the list at 0/0, opening it with the bonus, and marks the mob claimed', function ()
    local h = hatelist.new();
    t.eq(h.claimed, false);
    -- ClaimMob: UpdateEnmity(original, 0, 0), before the swing is even rolled.
    h:claim(A, 0, true);
    t.eq(values(h, A), { 200, 900, true });
    t.eq(h.claimed, true);

    -- Out of range still opens the list: the action is zeroed, not the bonus.
    local far = hatelist.new();
    far:claim(A, 0, false);
    t.eq(values(far, A), { 200, 900, true });

    h:claim(B, 0, true);
    t.eq(values(h, B), { 0, 0, true });
    h:claim(A, 0, true);
    t.eq(values(h, A), { 200, 900, true });
end);

t.test('damage marks the mob claimed', function ()
    local h = hatelist.new();
    h:damage(A, 1, 75, 0, true);
    t.eq(h.claimed, true);
end);

t.test('a base entry puts an actor on the list at zero and closes it to the first-engage bonus', function ()
    local h = hatelist.new();
    h:base(A);
    t.eq(values(h, A), { 0, 0, true });
    h:damage(B, 100, 75, 0, true);
    t.eq(values(h, B), { 153, 461, true });

    -- An existing entry is left as it is.
    h:damage(A, 100, 75, 0, true);
    h:base(A);
    t.eq(values(h, A), { 153, 461, true });
end);

t.test('set replaces an entry\'s CE and VE outright, held to the cap, and leaves anyone off the list off it', function ()
    local h = hatelist.new();
    h:cureFixed(A, 1234, 3113, 0, true);
    h:cureFixed(B, 90, 90, 0, true);
    h:set(A, 1, 0);
    t.eq(values(h, A), { 1, 0, true });
    t.eq(values(h, B), { 90, 90, true });
    h:set(B, 20000, -5);
    t.eq(values(h, B), { 10000, 0, true });
    h:set(C, 1, 0);
    t.eq(h:has(C), false);
end);

t.test('anchor raises a trailing entry to one above the best other active entry, in each lane that trails, CE first', function ()
    local f = require('filter').new({ max = 4, jitter = 0 });
    local h = f:newList(10000);
    h:cureFixed(A, 1000, 500, 0, true);
    h:cureFixed(B, 100, 50, 0, true);
    h:cureFixed(C, 9000, 9000, 0, true);
    h:setActive(C, false);
    -- Lane 2 alone already has B ahead.
    h:set(B, 100, 50);
    local i = (2 * h.slots + h.entries[B].slot) * 2;
    h.v[i], h.v[i + 1] = 2000, 0;
    local version = h.version;
    t.eq(h:anchor(B), 4, 'every lane but the one already ahead');
    t.eq({ h:value(B, 0) }, { 1451, 50 });
    t.eq({ h:value(B, 1) }, { 1451, 50 });
    t.eq({ h:value(B, 2) }, { 2000, 0 }, 'left alone');
    t.eq({ h:value(B, 4) }, { 1451, 50 });
    t.eq({ h:value(A, 0) }, { 1000, 500 }, 'the leader is untouched');
    t.truthy(h.version > version, 'the estimate is stale');
    t.eq(h:anchor(B), 0, 'nothing more to raise');
    t.eq(h:anchor(0x0001E999), 0, 'nobody off the list');

    -- Past CE's cap the rise goes to VE.
    h:set(A, 10000, 5000);
    h:set(B, 9990, 0);
    h:anchor(B);
    t.eq({ h:value(B, 0) }, { 10000, 5001 });
    -- A tie is a trail: the mob keeps its current target on a tie.
    h:set(A, 100, 100);
    h:set(B, 150, 50);
    t.eq(h:anchor(B), 5);
    t.eq({ h:value(B, 0) }, { 151, 50 });
end);

t.test('a list exports as plain data and imports into an empty one, every lane alike, with no engage bonus', function ()
    local f = require('filter').new({ max = 4, jitter = 0 });
    local h = f:newList();
    h:damage(A, 100, 75, 0, true);
    h:damage(B, 100, 75, 20, true);
    h:setActive(B, false);
    h:occupy(C, true);
    local saved = h:export();
    t.eq(saved, { claimed = true, entries = { { A, 353, 1361, true }, { B, 183, 553, false } }, others = { C } });

    local g = f:newList();
    g:import(saved);
    t.eq(values(g, A), { 353, 1361, true });
    t.eq(values(g, B), { 183, 553, false });
    t.eq({ g:value(A, 3) }, { 353, 1361 }, 'every lane');
    t.eq(g.others[C], true);
    t.eq(g.claimed, true);
    t.eq(g.order, { A, B });
    -- The next newcomer gets no bonus: the list wasn't empty.
    g:damage(C, 100, 75, 0, true);
    t.eq(values(g, C), { 153, 461, true });

    local empty = hatelist.new();
    empty:import({ claimed = false, entries = { { 'bad' }, { A, 5, 6 } }, others = {} });
    t.eq(values(empty, A), { 5, 6, true });
    t.eq(empty:count(), 1);
end);

t.test('lowering by a percent takes that share of CE and VE through float32, and moves nobody else', function ()
    local h = hatelist.new();
    h:cureFixed(A, 1234, 3113, 0, true);
    h:cureFixed(B, 90, 90, 0, true);
    h:lowerByPercent(A, 10);
    t.eq(values(h, A), { 1111, 2802, true });

    -- float32: 70% of 90 is 63 where double gives 62.
    h:lowerByPercent(B, 70);
    t.eq(values(h, B), { 27, 27, true });

    h:lowerByPercent(C, 50);
    t.eq(h:has(C), false);

    -- A reset leaves the entry at zero, still on the list and still active.
    h:lowerByPercent(A, 100);
    t.eq(values(h, A), { 0, 0, true });
end);

t.test('clearing an entry takes it off the list entirely, so the next actor can open it again', function ()
    local h = hatelist.new();
    h:damage(A, 100, 75, 0, true);
    h:base(B);
    h:clear(A);
    t.eq({ h:has(A), h:count(), h:idAt(1) }, { false, 1, B });

    h:clear(B);
    h:damage(C, 100, 75, 0, true);
    t.eq(values(h, C), { 353, 1361, true });
    h:clear(A);
end);

t.test('cover adds 200 CE to the coverer, unscaled and capped, and takes 10% of the covered target\'s CE and VE', function ()
    local h = hatelist.new(1000);
    h:cureFixed(A, 500, 900, 0, true);
    -- UpdateEnmityFromCover: SetCE on a coverer not yet listed adds them first.
    h:cover(A, B);
    t.eq(values(h, A), { 450, 810, true });
    t.eq(values(h, B), { 200, 0, true });

    h:cureFixed(B, 700, 0, 0, true);
    h:cover(A, B);
    t.eq(values(h, B), { 1000, 0, true });
    t.eq(values(h, A), { 405, 729, true });
end);

t.test('entries iterate in insertion order', function ()
    local h = hatelist.new();
    h:base(C);
    h:base(A);
    h:base(B);
    local seen = {};
    for i = 1, h:count() do
        seen[i] = h:idAt(i);
    end
    t.eq(seen, { C, A, B });
end);

--[[
* A list can carry several lanes: the same entries, each lane with its own
* CE and VE and its own Enmity.  Every lane must replay exactly what a list of
* its own would, given that lane's modifier.
--]]
local ffi = require('ffi');

local function script(h, mod)
    h:claim(A, mod, true);
    h:damage(A, 137, 75, mod, true);
    h:base(B);
    h:damage(B, 43, 60, mod, true);
    h:cure(C, 75, 55, mod, true);
    h:cureFixed(A, 400, 600, mod, true);
    h:attacked(A, 150, 1500, 25);
    h:add(B, 1, 1800, mod, true);
    h:add(C, -25, 0, mod, true);
    h:decay(7);
    h:lowerByPercent(B, 70);
    h:cover(A, C);
    h:add(A, 900, 0, mod, false);
    h:cureFixed(C, 9900, 9900, mod, true);
end

t.test('each lane replays the operations exactly as a list of its own with that lane\'s Enmity', function ()
    local mods = { 0, 50, -30, 250 };
    local bank = { lanes = #mods, capacity = #mods + 2 };
    local row = ffi.new('int32_t[?]', bank.capacity);
    for i, m in ipairs(mods) do
        row[i - 1] = m;
    end
    local laned = hatelist.new(3000, bank);
    script(laned, row);
    for lane, m in ipairs(mods) do
        local single = hatelist.new(3000);
        script(single, m);
        for _, id in ipairs({ A, B, C }) do
            local ce, ve = single:get(id);
            t.eq({ laned:value(id, lane - 1) }, { ce, ve }, ('lane %d id %X'):format(lane - 1, id));
        end
    end
    -- Lane 0 is what get reads.
    local single = hatelist.new(3000);
    script(single, 0);
    t.eq({ laned:get(A) }, { single:get(A) });
end);

t.test('the holder is judged per lane', function ()
    local bank = { lanes = 2, capacity = 2 };
    local row = ffi.new('int32_t[2]', { 0, 100 });
    local h = hatelist.new(10000, bank);
    h:cureFixed(A, 100, 100, 0, true);
    h:cureFixed(B, 150, 0, row, true);
    t.eq({ h:highest(nil, 0), h:highest(nil, 1) }, { A, B });
end);

t.test('permuting copies each lane from its ancestor and leaves lane 0 alone', function ()
    local bank = { lanes = 4, capacity = 4 };
    local row = ffi.new('int32_t[4]', { 0, -50, 0, 100 });
    local h = hatelist.new(10000, bank);
    h:cureFixed(A, 100, 200, row, true);
    h:cureFixed(B, 10, 20, 0, true);
    local src = ffi.new('int32_t[4]', { 0, 3, 3, 1 });
    local scratch = ffi.new('int32_t[?]', 4 * h:stride());
    h:permute(src, 3, scratch);
    t.eq({ h:value(A, 0) }, { 100, 200 });
    t.eq({ h:value(A, 1) }, { 200, 400 });
    t.eq({ h:value(A, 2) }, { 200, 400 });
    t.eq({ h:value(A, 3) }, { 50, 100 });
    t.eq({ h:value(B, 3) }, { 10, 20 });
end);

t.test('a list grows past its initial slots without losing any lane\'s values', function ()
    local bank = { lanes = 2, capacity = 3 };
    local row = ffi.new('int32_t[3]', { 0, 100, 0 });
    local h = hatelist.new(10000, bank);
    local ids = {};
    for i = 1, hatelist.SLOTS * 2 + 3 do
        ids[i] = 0x100 + i;
        h:cureFixed(ids[i], i, i * 2, row, true);
    end
    t.eq(h:count(), #ids);
    for i, id in ipairs(ids) do
        t.eq({ h:value(id, 0) }, { i, i * 2 });
        t.eq({ h:value(id, 1) }, { i * 2, i * 4 });
    end
end);

t.test('a cleared entry\'s slot comes back empty for whoever takes it next', function ()
    local h = hatelist.new();
    h:cureFixed(A, 500, 500, 0, true);
    h:clear(A);
    h:base(B);
    t.eq(values(h, B), { 0, 0, true });
end);

t.test('every change moves the version, so estimates know when to refresh', function ()
    local h = hatelist.new();
    local v = h.version;
    h:base(A);
    t.truthy(h.version > v, 'base');
    v = h.version;
    h:decay(1);
    t.truthy(h.version > v, 'decay');
end);

return t.done();

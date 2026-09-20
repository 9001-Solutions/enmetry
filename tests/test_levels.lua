--[[
* Mob levels: what the server stated for a mob, the highest seen for its
* name in its zone, Horizon's table, then LandSandBoat's; and the file the
* seen levels live in between sessions.
*
* Run: luajit tests/test_levels.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local levels = require('levels');
local store = require('store');

local SCRATCH = os.getenv('TEMP') or '.';
local path = SCRATCH .. '/enmetry_levels_test.lua';

local HORIZON = {
    [110] = { ['Teratornis'] = { 88, 88 }, ['Simurgh'] = { 58, 58 } },
};

local function fallback(id)
    if id == 0x0100A012 then
        return 38, 40;
    end
end

local function new()
    return levels.new(path, 'play.horizonxi.com', HORIZON, fallback);
end

t.test('sources are tried in order: stated, seen, Horizon, LandSandBoat, nothing', function ()
    local l = new();
    t.eq({ l:rangeFor(0x0100A012, 110, 'Goblin') }, { 38, 40, 'table' });
    t.eq({ l:rangeFor(0x0100A012, 110, 'Teratornis') }, { 88, 88, 'horizon' });
    t.eq({ l:rangeFor(0x0100A999, 110, 'Teratornis') }, { 88, 88, 'horizon' });
    t.eq({ l:rangeFor(0x0100A999, 110, 'Nobody') }, {});
    t.eq({ l:rangeFor(0x0100A999, nil, nil) }, {});

    t.eq(l:learn(nil, 110, 'Teratornis', 90), true);
    t.eq({ l:rangeFor(0x0100A999, 110, 'Teratornis') }, { 90, 90, 'seen' });
    -- A lower level seen later is kept, but the highest stands.
    t.eq(l:learn(nil, 110, 'Teratornis', 88), true);
    t.eq({ l:rangeFor(0x0100A999, 110, 'Teratornis') }, { 90, 90, 'seen' });
    t.eq(l:learn(nil, 110, 'Teratornis', 88), false, 'nothing new');

    -- What the server said about this very mob beats every other source.
    t.eq(l:learn(0x0100A999, 110, 'Teratornis', 89), true);
    t.eq({ l:rangeFor(0x0100A999, 110, 'Teratornis') }, { 89, 89, 'stated' });
    t.eq({ l:rangeFor(0x0100A998, 110, 'Teratornis') }, { 90, 90, 'seen' });
    l:clear();
    t.eq({ l:rangeFor(0x0100A999, 110, 'Teratornis') }, { 90, 90, 'seen' }, 'a zone change forgets the mob, not the name');
end);

t.test('a level the game could not have stated teaches nothing', function ()
    local l = new();
    t.eq(l:learn(0x0100A012, 110, 'Goblin', 0), false);
    t.eq(l:learn(0x0100A012, 110, 'Goblin', 4294967295), false);
    t.eq(l:learn(0x0100A012, 110, 'Goblin', 201), false);
    t.eq(l:learn(0x0100A012, 110, 'Goblin', 38.5), false);
    t.eq(l:learn(0x0100A012, nil, 'Goblin', 40), true, 'the mob alone is still worth knowing');
    t.eq({ l:rangeFor(0x0100A012, 110, 'Goblin') }, { 40, 40, 'stated' });
    t.eq(l:highestSeen(110, 'Goblin'), nil);
end);

t.test('seen levels persist per server, ascending and distinct, and a corrupt file reads as empty', function ()
    os.remove(path);
    local l = new();
    l:load();
    t.eq(l:save(), false, 'nothing to save');
    l:learn(nil, 110, 'Teratornis', 90);
    l:learn(nil, 110, 'Teratornis', 88);
    l:learn(nil, 110, 'Kelenken', 88);
    t.eq(l:save(), true);
    t.eq(l:save(), false, 'saved already');
    t.eq(store.read(path), { ['play.horizonxi.com'] = { [110] = { Teratornis = { 88, 90 }, Kelenken = { 88 } } } });

    local again = new();
    again:load();
    t.eq({ again:rangeFor(0x0100A999, 110, 'Teratornis') }, { 90, 90, 'seen' });
    local elsewhere = levels.new(path, 'other.server', HORIZON, fallback);
    elsewhere:load();
    t.eq({ elsewhere:rangeFor(0x0100A999, 110, 'Teratornis') }, { 88, 88, 'horizon' }, 'another server\'s mobs are its own');

    store.write(path, { ['play.horizonxi.com'] = { [110] = { Teratornis = { 'ninety', 0, 300, 91 } }, bad = 1 }, [5] = {} });
    local sane = new();
    sane:load();
    t.eq({ sane:rangeFor(0x0100A999, 110, 'Teratornis') }, { 91, 91, 'seen' }, 'only the plausible level survives');
    local fh = io.open(path, 'wb');
    fh:write('return nonsense(');
    fh:close();
    local broken = new();
    broken:load();
    t.eq({ broken:rangeFor(0x0100A999, 110, 'Teratornis') }, { 88, 88, 'horizon' });
    os.remove(path);
end);

return t.done();

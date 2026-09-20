--[[
* The live action feed: one readable line per observed event, kept in a
* bounded buffer of the most recent.
*
* Run: luajit tests/test_feed.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local feed = require('feed');

-- Resolver stand-in with the world:resolve contract.
local known = {
    [0x0001E240] = { index = 0x405, name = 'Hanayaka', kind = 'alliance', member = { mainJob = 'WAR', subJob = 'NIN' } },
    [0x0001E241] = { index = 0x406, name = 'Solo', kind = 'alliance', member = { mainJob = 'WHM' } },
    [0x0001E260] = { index = 0x420, name = 'Stranger', kind = 'player' },
    [0x0100A012] = { index = 0x012, name = 'Goblin Thug', kind = 'mob' },
    [0x0100A013] = { index = 0x013, name = 'Goblin Mugger', kind = 'mob' },
};
local resolver = { resolve = function (_, id) return known[id]; end };

local function hit(param) return { reaction = 0, param = param, message = 1 }; end

t.test('a melee round names actor with jobs, target, and each swing', function ()
    local line = feed.describe({
        kind = 'action', actorId = 0x0001E240, category = 1, param = 0,
        targets = { { id = 0x0100A012, results = { hit(34), { reaction = 1, param = 0, message = 15 } } } },
    }, resolver);
    t.eq(line, 'Hanayaka WAR/NIN  melee > Goblin Thug  34 miss');
end);

t.test('an action with an id shows it, and extra targets are counted', function ()
    local line = feed.describe({
        kind = 'action', actorId = 0x0001E241, category = 4, param = 7,
        targets = {
            { id = 0x0001E240, results = { hit(90) } },
            { id = 0x0001E260, results = { hit(88) } },
        },
    }, resolver);
    t.eq(line, 'Solo WHM  magic #7 > Hanayaka WAR/NIN +1  90');
end);

t.test('an ability the server sends in the weaponskill category is named as an ability', function ()
    local line = feed.describe({
        kind = 'action', actorId = 0x0001E240, category = 3, param = 46,
        targets = { { id = 0x0100A012, results = { { message = 110, param = 231, reaction = 0 } } } },
    }, resolver);
    t.eq(line, 'Hanayaka WAR/NIN  ability #46 > Goblin Thug  231');
end);

t.test('mobs and outsiders are named without jobs; unknown ids show in hex', function ()
    local line = feed.describe({
        kind = 'action', actorId = 0x0100A012, category = 11, param = 256,
        targets = { { id = 0x0001E999, results = { { reaction = 0, param = 120, message = 185 } } } },
    }, resolver);
    t.eq(line, 'Goblin Thug  mobskill #256 > 0x0001E999  120');
end);

t.test('every non-hit reaction is spelled out', function ()
    local results = {};
    for _, r in ipairs({ 1, 2, 3, 4 }) do
        results[#results + 1] = { reaction = r, param = 0, message = 15 };
    end
    local line = feed.describe({
        kind = 'action', actorId = 0x0001E260, category = 2, param = 0,
        targets = { { id = 0x0100A013, results = results } },
    }, resolver);
    t.eq(line, 'Stranger  ranged > Goblin Mugger  miss guard parry block');
end);

t.test('an unnamed category shows its number', function ()
    local line = feed.describe({
        kind = 'action', actorId = 0x0100A012, category = 0, param = 0,
        targets = { { id = 0x0100A012, results = {} } },
    }, resolver);
    t.eq(line, 'Goblin Thug  cat 0 > Goblin Thug');
end);

t.test('a battle message names both sides, the message id and its values', function ()
    local line = feed.describe({
        kind = 'message', actorId = 0x0001E240, targetId = 0x0100A012,
        param = 0, value = 0, actorIndex = 0x405, targetIndex = 0x012, message = 6,
    }, resolver);
    t.eq(line, 'Hanayaka WAR/NIN  msg 6 > Goblin Thug  0 0');
end);

t.test('the buffer keeps only the most recent lines, newest first', function ()
    local f = feed.new(3);
    for i = 1, 5 do
        f:push('line ' .. i, i);
    end

    t.eq({ f:at(1) }, { 'line 5', 5 });
    t.eq({ f:at(2) }, { 'line 4', 4 });
    t.eq({ f:at(3) }, { 'line 3', 3 });
    t.eq(f:at(4), nil);
    t.eq(f:size(), 3);
    t.eq(f.total, 5);
end);

t.test('lines can be read by recency without a callback', function ()
    local f = feed.new(3);
    for i = 1, 4 do
        f:push('line ' .. i, i);
    end
    t.eq({ f:at(1) }, { 'line 4', 4 });
    t.eq({ f:at(3) }, { 'line 2', 2 });
    t.eq(f:at(4), nil);
    t.eq(f:at(0), nil);
end);

t.test('clearing empties the buffer but keeps the running total', function ()
    local f = feed.new(3);
    f:push('a', 1);
    f:push('b', 2);
    f:clear();
    t.eq(f:at(1), nil);
    t.eq(f:size(), 0);
    t.eq(f.total, 2);
    f:push('c', 3);
    t.eq({ f:at(1) }, { 'c', 3 });
    t.eq(f:at(2), nil);
end);

return t.done();

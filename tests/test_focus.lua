--[[
* Display focus: which tracked mob the panel shows.
*
* Run: luajit tests/test_focus.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local focus = require('focus');

local MOB, MOB2, MOB3 = 0x0100A012, 0x0100A013, 0x0100A014;

--[[
* A sim holding tracks for the given mobs.  Each spec is { acting, lastAction },
* plus engaged = false for a list with no modelled actor on it.
--]]
local function fakeSim(specs)
    local s = { tracks = {} };
    for mob, spec in pairs(specs) do
        s.tracks[mob] = { acting = spec[1], lastAction = spec[2], engaged = spec.engaged ~= false };
    end
    function s:engaged(mob)
        local track = self.tracks[mob];
        return track ~= nil and track.engaged;
    end
    return s;
end

t.test('focus follows the player\'s target when it is an engaged mob', function ()
    local f = focus.new();
    local s = fakeSim({ [MOB] = { 3, 10 }, [MOB2] = { 0, 1 } });
    t.eq(f:update(s, MOB2), MOB2);
    t.eq(f.mob, MOB2);
    t.eq(f:update(s, MOB), MOB);
end);

t.test('with no engaged target, focus falls back to the mob most alliance members are acting on', function ()
    local f = focus.new();
    local s = fakeSim({ [MOB] = { 1, 10 }, [MOB2] = { 3, 5 }, [MOB3] = { 4, 20, engaged = false } });
    t.eq(f:update(s, nil), MOB2);
    -- Targeting something that is not fighting the alliance falls back too.
    t.eq(f:update(s, 0x0001E240), MOB2);
    t.eq(f:update(s, MOB3), MOB2);
end);

t.test('a fallback tie goes to the mob with the most recent action', function ()
    local f = focus.new();
    t.eq(f:update(fakeSim({ [MOB] = { 2, 10 }, [MOB2] = { 2, 12 } }), nil), MOB2);
    -- Nobody acting at all, as when a mob aggroes: still the latest.
    t.eq(f:update(fakeSim({ [MOB] = { 0, 30 }, [MOB2] = { 0, 12 } }), nil), MOB);
end);

t.test('with nothing engaged there is no focus', function ()
    local f = focus.new();
    t.eq(f:update(fakeSim({}), MOB), nil);
    t.eq(f:update(fakeSim({ [MOB] = { 1, 1, engaged = false } }), nil), nil);
    t.eq(f.mob, nil);
end);

t.test('a pin locks focus until it is released', function ()
    local f = focus.new();
    local s = fakeSim({ [MOB] = { 3, 10 }, [MOB2] = { 0, 1 } });
    f:update(s, MOB2);
    t.eq(f:pin(), MOB2);
    t.eq(f:update(s, MOB), MOB2);
    t.eq(f:update(s, nil), MOB2);

    t.eq(f:unpin(), MOB2);
    t.eq(f:update(s, nil), MOB);
    t.eq(f:unpin(), nil);
end);

t.test('there is nothing to pin without a focus', function ()
    local f = focus.new();
    f:update(fakeSim({}), nil);
    t.eq(f:pin(), nil);
    t.eq(f.pinned, nil);
end);

t.test('a pinned mob that stops fighting releases the pin', function ()
    local f = focus.new();
    local s = fakeSim({ [MOB] = { 3, 10 }, [MOB2] = { 0, 1 } });
    f:update(s, MOB2);
    f:pin();
    s.tracks[MOB2] = nil;
    t.eq(f:update(s, nil), MOB);
    t.eq(f.pinned, nil);
end);

return t.done();

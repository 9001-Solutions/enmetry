--[[
* The session log: JSON encoding, line shape and buffering.
*
* Run: luajit tests/test_log.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local log = require('log');

t.test('values encode as JSON: whole numbers plainly, fractions exactly enough, strings escaped', function ()
    t.eq(log.encode(12), '12');
    t.eq(log.encode(-3), '-3');
    t.eq(log.encode(0.25), '0.25');
    t.eq(log.encode(1 / 3), '0.3333333333');
    t.eq(log.encode(0 / 0), 'null');
    t.eq(log.encode(math.huge), 'null');
    t.eq(log.encode(true), 'true');
    t.eq(log.encode(nil), 'null');
    t.eq(log.encode('a "b" \\ c\n\t\1'), '"a \\"b\\" \\\\ c\\n\\t\\u0001"');
    t.eq(log.encode('caf\233'), '"caf\\u00e9"', 'bytes past ASCII stay readable JSON');
end);

t.test('tables encode as arrays or as objects with sorted keys', function ()
    t.eq(log.encode({ 1, 'two', { 3 } }), '[1,"two",[3]]');
    t.eq(log.encode({ b = 1, a = { y = 2, x = 1 }, [7] = 'n' }), '{"7":"n","a":{"x":1,"y":2},"b":1}');
    t.eq(log.encode({}), '[]');
    t.eq(log.encode({ 1, nil, 3 }), '{"1":1,"3":3}', 'an array with a hole is an object');
end);

t.test('a line leads with the time and the kind, then the fields', function ()
    local out = {};
    local l = log.new({ sink = function (text) out[#out + 1] = text; end, clock = function () return 12.3456; end });
    l:write('mark', { text = 'here', a = 1 });
    l:write('tick');
    l:flush();
    t.eq(out, { '{"t":12.346,"k":"mark","a":1,"text":"here"}\n{"t":12.346,"k":"tick"}\n' });
    t.eq(l.lines, 2);
end);

t.test('lines are held until flushed, or until enough have gathered', function ()
    local out = {};
    local l = log.new({ sink = function (text) out[#out + 1] = text; end, clock = function () return 0; end, limit = 3 });
    l:write('a');
    l:write('b');
    l:flush();
    l:flush();
    t.eq(#out, 1, 'nothing to flush sends nothing');
    l:write('c');
    l:write('d');
    t.eq(#out, 1);
    l:write('e');
    t.eq(#out, 2, 'the limit flushes');
    t.eq(out[2], '{"t":0,"k":"c"}\n{"t":0,"k":"d"}\n{"t":0,"k":"e"}\n');
end);

t.test('work done for the log is counted as its own', function ()
    local l = log.new({ sink = function () end });
    t.eq(l.cost, 0);
    l:charge(0.25);
    l:charge(1);
    t.eq(l.cost, 1.25);
end);

return t.done();

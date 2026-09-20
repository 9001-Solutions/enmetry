--[[
* Global settings persistence: canvas position and the debug flag, stored once
* for the install rather than per character.
*
* Run: luajit tests/test_store.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local store = require('store');

local SCRATCH = os.getenv('TEMP') or os.getenv('TMPDIR') or '.';
local path = SCRATCH .. '/enmetry_store_test.lua';

local DEFAULTS = { x = 100, y = 120, debug = true };

local function write(text)
    local fh = assert(io.open(path, 'wb'));
    fh:write(text);
    fh:close();
end

local function cleanup()
    os.remove(path);
end

t.test('a missing file loads the defaults', function ()
    cleanup();
    t.eq(store.load(path, DEFAULTS), { x = 100, y = 120, debug = true });
end);

t.test('saved values load back', function ()
    cleanup();
    t.truthy(store.write(path, { x = 812.5, y = -40, debug = false }));
    t.eq(store.load(path, DEFAULTS), { x = 812.5, y = -40, debug = false });
    cleanup();
end);

t.test('the file is plaintext a person can read and edit', function ()
    cleanup();
    store.write(path, { x = 5, y = 6, debug = true });
    local fh = assert(io.open(path, 'rb'));
    local text = fh:read('*a');
    fh:close();
    t.truthy(text:find('x = 5', 1, true), 'x in ' .. text);
    t.truthy(text:find('debug = true', 1, true), 'debug in ' .. text);

    write(text:gsub('x = 5', 'x = 640'));
    t.eq(store.load(path, DEFAULTS).x, 640);
    cleanup();
end);

t.test('keys missing from the file fall back to defaults individually', function ()
    write('return { x = 1 }\n');
    t.eq(store.load(path, DEFAULTS), { x = 1, y = 120, debug = true });
    cleanup();
end);

t.test('a value of the wrong type is replaced by its default', function ()
    write('return { x = "left", y = 7, debug = 1 }\n');
    t.eq(store.load(path, DEFAULTS), { x = 100, y = 7, debug = true });
    cleanup();
end);

t.test('a corrupt file loads the defaults', function ()
    write('return { x = ');
    t.eq(store.load(path, DEFAULTS), { x = 100, y = 120, debug = true });
    write('return 42');
    t.eq(store.load(path, DEFAULTS), { x = 100, y = 120, debug = true });
    cleanup();
end);

t.test('the file cannot reach globals when loaded', function ()
    write('os.exit(3) return { x = 1 }');
    t.eq(store.load(path, DEFAULTS), { x = 100, y = 120, debug = true });
    cleanup();
end);

t.test('non-finite numbers are never written', function ()
    cleanup();
    store.write(path, { x = 0 / 0, y = math.huge, debug = true });
    t.eq(store.load(path, DEFAULTS), { x = 100, y = 120, debug = true });
    cleanup();
end);

t.test('a table value loads when the default is one, and a colour reads as it was typed', function ()
    write('return { x = 1, color = { 0.86, 0.45, 0.22, 1 }, debug = { 1 } }\n');
    local loaded = store.load(path, { x = 0, color = { 0, 0, 0, 0 }, debug = true });
    t.eq(loaded, { x = 1, color = { 0.86, 0.45, 0.22, 1 }, debug = true });
    cleanup();
end);

t.test('numbers are written as short as reads back exactly', function ()
    t.eq(store.serialize({ 0.86, 0.1, 1 / 3, 640, 1e21, -2.5 }),
        '{\n    [1] = 0.86,\n    [2] = 0.1,\n    [3] = 0.3333333333333333,\n    [4] = 640,\n    [5] = 1e+21,\n    [6] = -2.5,\n}');
    for _, v in ipairs({ 0.86, 1 / 3, 2 ^ 53 + 2, 1e-300, 123456789.125 }) do
        t.eq(tonumber(store.serialize(v)), v, tostring(v));
    end
end);

t.test('a nested value writes as plaintext Lua that reads back, in a fixed order, leaving out what has no place', function ()
    cleanup();
    local value = {
        version = 1, name = 'a "b"\n', ok = true, none = 0 / 0, fn = print,
        list = { 3, 1, { x = 2.5 } }, byId = { [0x0100A012] = { ce = 1, ve = 0 }, [7] = 'seven' },
        ['odd key'] = 1, [true] = 'yes',
    };
    t.truthy(store.write(path, value));
    local back = store.read(path);
    t.eq(back, {
        version = 1, name = 'a "b"\n', ok = true, list = { 3, 1, { x = 2.5 } },
        byId = { [0x0100A012] = { ce = 1, ve = 0 }, [7] = 'seven' }, ['odd key'] = 1, [true] = 'yes',
    });
    local text = store.serialize(value);
    t.eq(text, store.serialize(back), 'stable');
    t.truthy(text:find('\n    byId = {\n        [7] = "seven",\n        [16818194] = {', 1, true), text);
    t.eq(store.serialize({}), '{}');
    cleanup();
end);

return t.done();

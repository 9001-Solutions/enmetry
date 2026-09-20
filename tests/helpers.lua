--[[
* Minimal test harness.  Runs under bare LuaJIT with no Ashita present.
*
*   local t = require('helpers');
*   t.test('name', function () t.eq(actual, expected) end);
*   t.done();
--]]


local t = { passed = 0, failed = 0 };

local function describe(v)
    if type(v) == 'string' then
        return ('%q'):format(v);
    end
    return tostring(v);
end

--[[
* Structural equality.  Returns nil when equal, otherwise a path and the two
* differing values, so a failure in a deep event table says where it differs.
--]]
local function diff(a, b, path)
    if type(a) ~= 'table' or type(b) ~= 'table' then
        if a == b then
            return nil;
        end
        return ('%s: expected %s, got %s'):format(path, describe(b), describe(a));
    end
    for k, v in pairs(b) do
        local d = diff(a[k], v, path .. '.' .. tostring(k));
        if d ~= nil then
            return d;
        end
    end
    for k, v in pairs(a) do
        if b[k] == nil then
            return ('%s.%s: unexpected %s'):format(path, tostring(k), describe(v));
        end
    end
    return nil;
end

function t.eq(actual, expected, label)
    local d = diff(actual, expected, label or 'value');
    if d ~= nil then
        error(d, 2);
    end
end

function t.truthy(v, label)
    if not v then
        error((label or 'value') .. ': expected truthy, got ' .. describe(v), 2);
    end
end

function t.test(name, fn)
    local ok, err = pcall(fn);
    if ok then
        t.passed = t.passed + 1;
    else
        t.failed = t.failed + 1;
        print(('FAIL  %s\n      %s'):format(name, tostring(err)));
    end
end

--[[
* Kilobytes of garbage-collected memory `fn` allocates over `times` calls.
* Measured with the JIT off: compiling traces takes memory of its own, which
* says nothing about what the code allocates.
--]]
function t.allocated(fn, times)
    jit.off();
    -- Traces compiled by earlier tests still run under jit.off and make the count flaky without this.
    jit.flush();
    collectgarbage('collect');
    collectgarbage('stop');
    local before = collectgarbage('count');
    for i = 1, times do
        fn(i);
    end
    local grown = collectgarbage('count') - before;
    collectgarbage('restart');
    jit.on();
    return grown;
end

function t.hex(s)
    return (s:gsub('%s+', ''):gsub('(%x%x)', function (x) return string.char(tonumber(x, 16)); end));
end

--[[
* Ends a file.  When run through tests/run.lua the totals are aggregated there;
* when a file is run directly it exits with its own status.
--]]
function t.done()
    if _G.ENMETRY_TEST_RUNNER then
        return t.passed, t.failed;
    end
    print(('%d passed, %d failed'):format(t.passed, t.failed));
    os.exit(t.failed == 0 and 0 or 1);
end

return t;

--[[
* The live calibration readout: each attack's credit against the posterior's
* credible set of who holds hate, and the coverage it adds up to.
*
* Run: luajit tests/test_calibration.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local ffi = require('ffi');
local calibration = require('calibration');

-- Chances as the filter hands them over: a double array from 0.
local function chances(ps)
    local out = ffi.new('double[?]', #ps);
    for i, p in ipairs(ps) do
        out[i - 1] = p;
    end
    return out, #ps;
end

local function near(actual, expected, label)
    t.truthy(math.abs(actual - expected) < 1e-9, ('%s: expected %s, got %s'):format(label or 'value', expected, actual));
end

local function credit(ps, at, level)
    local c, n = chances(ps);
    return calibration.credit(c, n, at, level or 0.8);
end

t.test('an entry the set holds whole earns full credit, one outside it none', function ()
    near(credit({ 0.5, 0.2, 0.2, 0.1 }, 0), 1, 'the likeliest');
    near(credit({ 0.5, 0.2, 0.2, 0.1 }, 3), 0, 'past the level');
    near(credit({ 0, 1 }, 0), 0, 'no chance at all');
end);

t.test('the entry the set ends on earns the share of it the set needs', function ()
    -- 0.5 is in; 0.3 more of the 0.4 left is needed.
    near(credit({ 0.5, 0.4, 0.1 }, 1), 0.75);
    -- One entry the posterior is sure of still only needs 0.8 of it.
    near(credit({ 1 }, 0), 0.8, 'certain');
    near(credit({ 0.9, 0.1 }, 0), 0.8 / 0.9, 'likely');
    near(credit({ 0.9, 0.1 }, 1), 0, 'unlikely');
end);

t.test('entries with the same chance share the set\'s edge between them', function ()
    -- 0.4 is in; the two at 0.25 share the 0.4 the level still needs of their 0.5.
    near(credit({ 0.25, 0.4, 0.25, 0.1 }, 0), 0.8);
    near(credit({ 0.25, 0.4, 0.25, 0.1 }, 2), 0.8);
    near(credit({ 0.25, 0.4, 0.25, 0.1 }, 3), 0, 'the lower chance is past the edge');
    -- Tied inside the set, both whole.
    near(credit({ 0.35, 0.2, 0.35, 0.1 }, 2), 1, 'tied inside');
    near(credit({ 0.35, 0.2, 0.35, 0.1 }, 1), 0.5, 'the edge below them');
end);

t.test('a posterior that is right as often as it says earns the level on average', function ()
    for _, ps in ipairs({ { 1 }, { 0.9, 0.1 }, { 0.5, 0.4, 0.1 }, { 0.35, 0.2, 0.35, 0.1 }, { 0.25, 0.4, 0.25, 0.1 } }) do
        for _, level in ipairs({ 0.8, 0.5 }) do
            local expected = 0;
            for i, p in ipairs(ps) do
                expected = expected + p * credit(ps, i - 1, level);
            end
            near(expected, level, table.concat(ps, ',') .. ' at ' .. level);
        end
    end
end);

t.test('scoring adds up coverage, overall and where nobody was likely enough to hold hate', function ()
    local cal = calibration.new(0.8);
    t.eq({ cal:coverage() }, {}, 'nothing scored');

    local c, n = chances({ 1, 0 });
    t.eq({ cal:score(c, n, 0) }, { 0.8, false });
    c, n = chances({ 0.5, 0.4, 0.1 });
    local got, contested = cal:score(c, n, 1);
    near(got, 0.75);
    t.eq(contested, true);
    c, n = chances({ 0.5, 0.4, 0.1 });
    cal:score(c, n, 2);

    t.eq({ cal.attacks, cal.contested }, { 3, 2 });
    local overall, tight = cal:coverage();
    near(overall, 1.55 / 3, 'overall');
    near(tight, 0.75 / 2, 'contested');
end);

t.test('the readout says how often the mob\'s target was in the set, against its level', function ()
    local cal = calibration.new(0.8);
    t.eq(cal:readout(), { 'calibration: nothing scored yet this session' });

    local sure, sureN = chances({ 1, 0 });
    for _ = 1, 3 do
        cal:score(sure, sureN, 0);
    end
    t.eq(cal:readout(), {
        'calibration: 80% of attacks inside the 80% credible set of who holds hate, over 3',
        'contested: none yet',
    });
    -- 0.7 is in; a third of the 0.3 is still needed.
    local split, splitN = chances({ 0.7, 0.3 });
    cal:score(split, splitN, 1);
    t.eq(cal:readout(), {
        'calibration: 68% of attacks inside the 80% credible set of who holds hate, over 4',
        'contested: 33% over 1, where nobody was 80% likely to hold hate',
    });
end);

t.test('scoring allocates nothing', function ()
    local cal = calibration.new(0.8);
    local c, n = chances({ 0.35, 0.2, 0.35, 0.1 });
    local grown = t.allocated(function (i)
        cal:score(c, n, i % n);
    end, 2000);
    t.truthy(grown < 4, ('allocated %.1f KB'):format(grown));
end);

return t.done();

--[[
* Bar layout: a hate list in, rows of CE and VE segment widths on the
* absolute-to-cap scale out.
*
* Run: luajit tests/test_bars.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local bars = require('bars');
local hatelist = require('hatelist');

local NAMES = { [1] = 'Tank', [2] = 'Healer', [3] = 'Dd', [9] = 'Stranger' };
local function nameOf(id) return NAMES[id]; end

local function row(r)
    return { r.id, r.name, r.ce, r.ve, r.ceWidth, r.veWidth };
end

t.test('rows are ordered by total, with CE and VE widths on a 2x cap scale and a marker at the leader', function ()
    local list = hatelist.new(10000);
    list:cureFixed(2, 1000, 3000, 0, true);
    list:cureFixed(1, 5000, 1000, 0, true);
    list:cureFixed(3, 0, 0, 0, true);

    local layout = bars.new(18);
    bars.layout(layout, list, nameOf, 400);

    t.eq(layout.count, 3);
    -- 400 px spans 20000: 50 enmity a pixel.
    t.eq(row(layout.rows[1]), { 1, 'Tank', 5000, 1000, 100, 20 });
    t.eq(row(layout.rows[2]), { 2, 'Healer', 1000, 3000, 20, 60 });
    t.eq(row(layout.rows[3]), { 3, 'Dd', 0, 0, 0, 0 });
    t.eq(layout.marker, 120);
    t.eq(layout.capX, 200);
    t.eq(layout.rows[2].label, '1000 / 3000');
end);

t.test('the marker sits at the highest active total, and inactive rows still show', function ()
    local list = hatelist.new(10000);
    list:cureFixed(1, 5000, 1000, 0, true);
    list:cureFixed(2, 1000, 3000, 0, true);
    list:setActive(1, false);

    local layout = bars.new(18);
    bars.layout(layout, list, nameOf, 400);
    t.eq(layout.count, 2);
    t.eq(layout.marker, 80);
end);

t.test('rows past the limit are left out', function ()
    local list = hatelist.new(10000);
    list:cureFixed(1, 100, 0, 0, true);
    list:cureFixed(2, 300, 0, 0, true);
    list:cureFixed(3, 200, 0, 0, true);

    local layout = bars.new(2);
    bars.layout(layout, list, nameOf, 400);
    t.eq(layout.count, 2);
    t.eq({ layout.rows[1].id, layout.rows[2].id }, { 2, 3 });
end);

t.test('an unnamed actor is shown by id', function ()
    local list = hatelist.new(10000);
    list:cureFixed(0x0001E240, 100, 0, 0, true);
    local layout = bars.new(4);
    bars.layout(layout, list, nameOf, 400);
    t.eq(layout.rows[1].name, '0x0001E240');
end);

t.test('no list lays out nothing', function ()
    local layout = bars.new(4);
    bars.layout(layout, nil, nameOf, 400);
    t.eq(layout.count, 0);
    t.eq(layout.marker, nil);
end);

t.test('laying out again reuses the same rows', function ()
    local list = hatelist.new(10000);
    list:cureFixed(1, 100, 0, 0, true);
    list:cureFixed(2, 300, 0, 0, true);
    local layout = bars.new(4);
    bars.layout(layout, list, nameOf, 400);
    local first, second = layout.rows[1], layout.rows[2];

    list:cureFixed(1, 500, 0, 0, true);
    bars.layout(layout, list, nameOf, 400);
    t.eq(layout.rows[1].id, 1);
    t.truthy(layout.rows[1] == first or layout.rows[1] == second, 'row reused');
    t.truthy(layout.rows[2] == first or layout.rows[2] == second, 'row reused');
end);

local function track(fields)
    local out = { clean = true, holder = nil, holderModelled = false, acting = 0, lastAction = 0 };
    for k, v in pairs(fields) do
        out[k] = v;
    end
    return out;
end

local function threeRows()
    local list = hatelist.new(10000);
    list:cureFixed(1, 5000, 1000, 0, true);
    list:cureFixed(2, 1000, 3000, 0, true);
    return list;
end

t.test('a clean track lays out absolute values, as with no track at all', function ()
    local layout = bars.new(18);
    bars.layout(layout, threeRows(), nameOf, 400, track({ holder = 1, holderModelled = true }));
    t.eq(layout.clean, true);
    t.eq(layout.holder, nil);
    t.eq(row(layout.rows[1]), { 1, 'Tank', 5000, 1000, 100, 20 });
    t.eq({ layout.marker, layout.capX }, { 120, 200 });
end);

t.test('an ordering-only track scales rows to the leader, with signed deltas and no cap or marker', function ()
    local layout = bars.new(18);
    bars.layout(layout, threeRows(), nameOf, 400, track({ clean = false }));
    t.eq(layout.clean, false);
    -- The leader's 6000 spans the width.
    t.eq(row(layout.rows[1]), { 1, 'Tank', 5000, 1000, 5000 / 15, 1000 / 15 });
    t.eq(row(layout.rows[2]), { 2, 'Healer', 1000, 3000, 1000 / 15, 3000 / 15 });
    t.eq({ layout.marker, layout.capX }, { nil, nil });
    t.eq(layout.rows[1].label, '+5000 / +1000');

    -- Back to clean: the label is rebuilt even though the values did not move.
    bars.layout(layout, threeRows(), nameOf, 400, track({}));
    t.eq(layout.rows[1].label, '5000 / 1000');
end);

t.test('a list an entry was re-anchored on says so, and stays absolute', function ()
    local layout = bars.new(18);
    bars.layout(layout, threeRows(), nameOf, 400, track({ clean = false }));
    t.eq({ layout.clean, layout.anchored }, { false, 0 }, 'joined mid-fight');
    bars.layout(layout, threeRows(), nameOf, 400, track({ clean = true, anchored = 2 }));
    t.eq({ layout.clean, layout.anchored }, { true, 2 });
    t.eq({ layout.marker, layout.capX, layout.rows[1].label }, { 120, 200, '5000 / 1000' });
    bars.layout(layout, threeRows(), nameOf, 400);
    t.eq(layout.anchored, 0);
end);

t.test('an ordering-only list where nobody has gained anything draws empty bars', function ()
    local list = hatelist.new(10000);
    list:base(1);
    local layout = bars.new(18);
    bars.layout(layout, list, nameOf, 400, track({ clean = false }));
    t.eq(row(layout.rows[1]), { 1, 'Tank', 0, 0, 0, 0 });
end);

t.test('an unmodelled hate holder is named above the bars and hides the leader marker', function ()
    local layout = bars.new(18);
    bars.layout(layout, threeRows(), nameOf, 400, track({ holder = 9, holderModelled = false }));
    t.eq(layout.holder, 'Stranger');
    t.eq(layout.marker, nil);
    t.eq(layout.count, 2);

    bars.layout(layout, threeRows(), nameOf, 400, track({ holder = 0x0100A0FF, holderModelled = false }));
    t.eq(layout.holder, '0x0100A0FF');
end);

--[[
* A list as the filter's view shows it: medians, and a band of five totals
* from the credible interval's lower bound to its upper.
--]]
local function banded(rows, cap)
    local ids = {};
    for i, r in ipairs(rows) do
        ids[i] = r[1];
    end
    local byId = {};
    for _, r in ipairs(rows) do
        byId[r[1]] = r;
    end
    return {
        cap = cap or 10000,
        count = function () return #ids; end,
        idAt = function (_, i) return ids[i]; end,
        get = function (_, id)
            local r = byId[id];
            return r[2], r[3], r[5] ~= false;
        end,
        band = function (_, id)
            return unpack(byId[id][4]);
        end,
    };
end

local function pieces(r)
    local out = {};
    for i = 1, r.pieceCount do
        local p = r.pieces[i];
        out[i] = { p.x1, p.x2, p.a1, p.a2, p.ve and 've' or 'ce' };
    end
    return out;
end

t.test('a plain list draws opaque CE and VE pieces with no band or median tick', function ()
    local layout = bars.new(18);
    bars.layout(layout, threeRows(), nameOf, 400);
    local tank = layout.rows[1];
    t.eq(pieces(tank), { { 0, 100, 1, 1, 'ce' }, { 100, 120, 1, 1, 've' } });
    t.eq({ tank.lowerX, tank.upperX, tank.tick }, { 120, 120, nil });
end);

t.test('a band is opaque to its lower bound and fades through its quantiles to nothing at the upper', function ()
    local layout = bars.new(18);
    -- 400 px spans 20000: 50 enmity a pixel.
    local view = banded({ { 1, 1000, 3000, { 2000, 3000, 4000, 5000, 6000 } } });
    bars.layout(layout, view, nameOf, 400);
    local r = layout.rows[1];
    t.eq({ r.ceWidth, r.veWidth, r.lowerX, r.upperX, r.tick }, { 20, 60, 40, 120, 80 });
    t.eq(pieces(r), {
        { 0, 20, 1, 1, 'ce' },
        { 20, 40, 1, 1, 've' },
        { 40, 60, 1, 0.75, 've' },
        { 60, 80, 0.75, 0.5, 've' },
        { 80, 100, 0.5, 0.25, 've' },
        { 100, 120, 0.25, 0, 've' },
    });
    t.eq(layout.marker, 80, 'the leader marker stays at the median');
    t.eq(r.label, '1000 / 3000');
end);

t.test('CE past the lower bound fades with the rest, and splits the piece it ends in', function ()
    local layout = bars.new(18);
    local view = banded({ { 1, 2500, 1500, { 2000, 3000, 4000, 5000, 6000 } } });
    bars.layout(layout, view, nameOf, 400);
    t.eq(pieces(layout.rows[1]), {
        { 0, 40, 1, 1, 'ce' },
        { 40, 50, 1, 0.875, 'ce' },
        { 50, 60, 0.875, 0.75, 've' },
        { 60, 80, 0.75, 0.5, 've' },
        { 80, 100, 0.5, 0.25, 've' },
        { 100, 120, 0.25, 0, 've' },
    });
end);

t.test('with no VE at the median the tail beyond it is CE', function ()
    local layout = bars.new(18);
    local view = banded({ { 1, 4000, 0, { 2000, 3000, 4000, 5000, 6000 } } });
    bars.layout(layout, view, nameOf, 400);
    local kinds = {};
    for i, p in ipairs(pieces(layout.rows[1])) do
        kinds[i] = p[5];
    end
    t.eq(kinds, { 'ce', 'ce', 'ce', 'ce', 'ce' });
end);

t.test('quantiles that coincide leave no empty pieces, and a collapsed band keeps its tick', function ()
    local layout = bars.new(18);
    local view = banded({
        { 1, 1000, 3000, { 4000, 4000, 4000, 6000, 6000 } },
        { 2, 1000, 1000, { 2000, 2000, 2000, 2000, 2000 } },
    });
    bars.layout(layout, view, nameOf, 400);
    local r = layout.rows[1];
    t.eq(pieces(r), {
        { 0, 20, 1, 1, 'ce' },
        { 20, 80, 1, 1, 've' },
        { 80, 120, 0.5, 0.25, 've' },
    });
    t.eq(r.tick, 80);
    t.eq(pieces(layout.rows[2]), { { 0, 20, 1, 1, 'ce' }, { 20, 40, 1, 1, 've' } });
    t.eq(layout.rows[2].tick, 40);
end);

t.test('one alpha for each of the filter\'s quantiles', function ()
    t.eq(#bars.ALPHAS, require('filter').STOPS);
end);

t.test('a narrower band leaves less of the bar translucent', function ()
    local function translucent(band)
        local layout = bars.new(18);
        bars.layout(layout, banded({ { 1, 1000, 3000, band } }), nameOf, 400);
        local r = layout.rows[1];
        return r.upperX - r.lowerX;
    end
    t.eq(translucent({ 2000, 3000, 4000, 5000, 6000 }), 80);
    t.eq(translucent({ 3800, 3900, 4000, 4100, 4200 }), 8);
end);

t.test('an ordering-only band is scaled so the highest upper bound spans the width', function ()
    local layout = bars.new(18);
    local view = banded({
        { 1, 3000, 1000, { 3000, 3500, 4000, 4500, 5000 } },
        { 2, 1000, 1000, { 1000, 1500, 2000, 3000, 8000 } },
    });
    bars.layout(layout, view, nameOf, 400, track({ clean = false }));
    t.eq({ layout.rows[1].id, layout.rows[1].upperX, layout.rows[2].upperX }, { 1, 250, 400 });
    t.eq({ layout.rows[1].ceWidth, layout.rows[1].tick }, { 150, 200 });
end);

t.test('laying out a band again allocates nothing', function ()
    local layout = bars.new(18);
    local view = banded({
        { 1, 2500, 1500, { 2000, 3000, 4000, 5000, 6000 } },
        { 2, 1000, 1000, { 1000, 1500, 2000, 3000, 8000 } },
    });
    bars.layout(layout, view, nameOf, 400);
    local grown = t.allocated(function () bars.layout(layout, view, nameOf, 400); end, 2000);
    t.truthy(grown < 4, ('allocated %.1f KB'):format(grown));
end);

t.test('the limit can change between layouts', function ()
    local layout = bars.new(18);
    layout.limit = 1;
    bars.layout(layout, threeRows(), nameOf, 400);
    t.eq(layout.count, 1);
    t.eq(layout.rows[2], nil);
    layout.limit = 5;
    bars.layout(layout, threeRows(), nameOf, 400);
    t.eq(layout.count, 2);
end);

return t.done();

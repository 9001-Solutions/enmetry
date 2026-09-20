--[[
* The particle filter: bonus vectors drawn per player per action class, target
* observations reweighting the particles, resampling, the posterior median
* and the frame budget.
*
* Run: luajit tests/test_filter.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local ffi = require('ffi');
local filter = require('filter');

local A, B, C = 0x0001E240, 0x0001E241, 0x0001E242;
local CLASS = filter.CLASS;

local function new(opts)
    math.randomseed(7);
    opts = opts or {};
    opts.random = opts.random or math.random;
    return filter.new(opts);
end

-- A double through a C float, as the hate list's arithmetic does.
local function f32(x)
    return tonumber(ffi.new('float', x));
end

local function correlation(xs, ys)
    local n = #xs;
    local mx, my = 0, 0;
    for i = 1, n do
        mx, my = mx + xs[i] / n, my + ys[i] / n;
    end
    local sxy, sxx, syy = 0, 0, 0;
    for i = 1, n do
        sxy = sxy + (xs[i] - mx) * (ys[i] - my);
        sxx = sxx + (xs[i] - mx) ^ 2;
        syy = syy + (ys[i] - my) ^ 2;
    end
    return sxy / math.sqrt(sxx * syy);
end

local function bonuses(f, id, class)
    local row = f:row();
    f:fill(row, id, class, 0);
    local out = {};
    for lane = 1, f.count do
        out[lane] = row[lane];
    end
    return out;
end

-- Sets the weights directly, then normalizes them.
local function weigh(f, ws)
    local sum = 0;
    for _, w in ipairs(ws) do
        sum = sum + w;
    end
    for lane, w in ipairs(ws) do
        f.weights[lane] = w / sum;
    end
    f.generation = f.generation + 1;
end

--[[
* A list where A holds `lead` more enmity than B in odd lanes and `lead` less
* in even ones.
--]]
local function split(f, lead)
    local list = f:newList(10000);
    local row = f:row();
    for lane = 0, f.count do
        row[lane] = lane % 2 == 1 and 100 or 0;
    end
    list:cureFixed(A, lead, 0, row, true);
    list:cureFixed(B, lead * 1.5, 0, 0, true);
    return list;
end

--[[
* A list where A's CE runs from 500 in the first particle to 2000 in the last,
* against B's 1500 in every one.
--]]
local function graded(f)
    local list = f:newList(10000);
    local row = f:row();
    row[0] = 0;
    for lane = 1, f.count do
        row[lane] = math.floor(-50 + 150 * (lane - 1) / (f.count - 1));
    end
    list:cureFixed(A, 1000, 0, row, true);
    list:cureFixed(B, 1500, 0, 0, true);
    return list;
end

t.test('each particle draws a bonus per player per class, the classes sharing the player\'s prior', function ()
    local f = new({ max = 1024 });
    local row = f:row();
    f:fill(row, A, CLASS.melee, 7);
    t.eq(row[0], 7, 'lane 0 is the known modifier alone');

    local melee, ability = bonuses(f, A, CLASS.melee), bonuses(f, A, CLASS.ability);
    local other = bonuses(f, B, CLASS.melee);
    local lo, hi, distinct = 0, 0, {};
    for lane = 1, f.count do
        lo, hi = math.min(lo, melee[lane]), math.max(hi, melee[lane]);
        distinct[melee[lane]] = true;
    end
    t.truthy(lo >= -50 and hi <= 100, ('bonuses within the Enmity clamp: %d..%d'):format(lo, hi));
    t.truthy(lo < -10 and hi > 10, ('bonuses spread: %d..%d'):format(lo, hi));
    t.truthy(correlation(melee, ability) > 0.6, 'one player\'s classes move together');
    t.truthy(math.abs(correlation(melee, other)) < 0.15, 'players are independent');
    t.eq(bonuses(f, A, CLASS.melee), melee, 'a player keeps their draws');
end);

local function mean(xs)
    local sum = 0;
    for _, x in ipairs(xs) do
        sum = sum + x;
    end
    return sum / #xs;
end

local function sd(xs)
    local m, sum = mean(xs), 0;
    for _, x in ipairs(xs) do
        sum = sum + (x - m) ^ 2;
    end
    return math.sqrt(sum / #xs);
end

t.test('each player\'s bonuses are drawn from the prior given for them', function ()
    local priors = {
        [A] = { mean = 30, sd = 5, classes = {} },
        [B] = { mean = -10, sd = 15, classes = {} },
    };
    for class = 0, filter.CLASSES - 1 do
        priors[A].classes[class] = { mean = class == CLASS.cure and -20 or 0, sd = 2 };
        priors[B].classes[class] = { mean = 0, sd = 10 };
    end
    local asked = {};
    local f = new({ max = 1024, prior = function (id)
        asked[#asked + 1] = id;
        return priors[id];
    end });

    local melee, cure = bonuses(f, A, CLASS.melee), bonuses(f, A, CLASS.cure);
    t.truthy(math.abs(mean(melee) - 30) < 1, ('A\'s melee centres on 30: %g'):format(mean(melee)));
    t.truthy(math.abs(mean(cure) - 10) < 1, ('A\'s cure sits 20 below: %g'):format(mean(cure)));
    t.truthy(math.abs(sd(melee) - math.sqrt(29)) < 0.6, ('A\'s spread: %g'):format(sd(melee)));
    local other = bonuses(f, B, CLASS.ability);
    t.truthy(math.abs(mean(other) + 10) < 1.5, ('B centres on -10: %g'):format(mean(other)));
    t.truthy(math.abs(sd(other) - math.sqrt(325)) < 1.2, ('B\'s spread: %g'):format(sd(other)));
    t.eq(asked, { A, B }, 'the prior is asked once, on first sight');
end);

t.test('a player\'s posterior is summarized as a prior, which draws back into the same belief', function ()
    local prior = { mean = 25, sd = 12, classes = {} };
    for class = 0, filter.CLASSES - 1 do
        -- Offsets summing to zero: whatever they share belongs to the centre.
        prior.classes[class] = { mean = (class - 2.5) * 4, sd = 3 + class };
    end
    local f = new({ max = 1024, prior = function () return prior; end });
    t.eq(f:posterior(A), nil, 'nothing for a player never seen');
    bonuses(f, A, CLASS.melee);

    local summary = f:posterior(A);
    t.truthy(math.abs(summary.mean - 25) < 1.5, ('centre %g'):format(summary.mean));
    t.truthy(math.abs(summary.sd - 12) < 1.5, ('centre spread %g'):format(summary.sd));
    for class = 0, filter.CLASSES - 1 do
        local c = summary.classes[class];
        t.truthy(math.abs(c.mean - prior.classes[class].mean) < 1,
            ('class %d offset %g'):format(class, c.mean));
        t.truthy(math.abs(c.sd - prior.classes[class].sd) < 1,
            ('class %d spread %g'):format(class, c.sd));
    end

    -- Weight moved onto the particles with the highest melee bonus moves the summary.
    local melee = bonuses(f, A, CLASS.melee);
    local ws = {};
    for lane = 1, f.count do
        ws[lane] = melee[lane] > 30 and 1 or 1e-9;
    end
    weigh(f, ws);
    t.truthy(f:posterior(A).mean > 30, ('weighted centre %g'):format(f:posterior(A).mean));
end);

t.test('a forgotten player is drawn afresh from their prior when next seen', function ()
    local centre = 40;
    local f = new({ max = 256, prior = function ()
        local p = { mean = centre, sd = 5, classes = {} };
        for class = 0, filter.CLASSES - 1 do
            p.classes[class] = { mean = 0, sd = 2 };
        end
        return p;
    end });
    t.truthy(mean(bonuses(f, A, CLASS.melee)) > 35);
    centre = -30;
    t.truthy(mean(bonuses(f, A, CLASS.melee)) > 35, 'kept until forgotten');
    f:forget(A);
    t.eq(f:posterior(A), nil);
    t.truthy(mean(bonuses(f, A, CLASS.melee)) < -25, 'redrawn');
    f:forget(C);
end);

t.test('a player about to lose their slot to a newcomer is handed over first', function ()
    local retired = {};
    local f;
    f = new({ max = 8, retire = function (id)
        retired[#retired + 1] = { id, f:posterior(id) ~= nil };
    end });
    for id = 1, filter.PLAYERS do
        bonuses(f, id, CLASS.melee);
    end
    t.eq(retired, {});
    bonuses(f, 1000, CLASS.melee);
    t.eq(retired, { { 1, true } }, 'the oldest, while their bonuses are still readable');
end);

t.test('a filled row is the known modifier plus each particle\'s bonus', function ()
    local f = new({ max = 16 });
    local melee = bonuses(f, A, CLASS.melee);
    local row = f:row();
    f:fill(row, A, CLASS.melee, 25);
    for lane = 1, f.count do
        t.eq(row[lane], 25 + melee[lane]);
    end
end);

t.test('a target observation favours the particles that put the target on top', function ()
    local f = new({ max = 8 });
    local list = split(f, 1000);
    t.truthy(f:observe(list, A, false), 'used');
    t.truthy(f.weights[1] > f.weights[2], 'A leads in lane 1 and trails in lane 2');
    local sum = 0;
    for lane = 1, f.count do
        sum = sum + f.weights[lane];
    end
    t.truthy(math.abs(sum - 1) < 1e-9, 'weights stay normalized');
end);

t.test('one surprising observation cannot collapse the filter', function ()
    local f = new({ max = 8 });
    -- A trails by 2000 in half the particles: a flat contradiction for them.
    local list = split(f, 4000);
    f:observe(list, A, true);
    local ratio = f.weights[2] / f.weights[1];
    t.truthy(ratio >= filter.FLOOR, ('contradicted particles keep a floor of weight: %g'):format(ratio));
    t.truthy(f:ess() >= f.count * filter.RESAMPLE, ('no resample: ess %g'):format(f:ess()));
end);

t.test('an observation essentially every particle contradicts is a surprise, and moves nothing', function ()
    local f = new({ max = 64 });
    local list = f:newList(10000);
    list:cureFixed(A, 1000, 0, 0, true);
    list:cureFixed(B, 3000, 0, 0, true);
    local generation = f.generation;
    t.eq({ f:observe(list, A, true) }, { false, true });
    t.eq({ f.resamples, f.generation }, { 0, generation }, 'no resample, no reweighting');
    for lane = 1, f.count do
        t.eq(f.weights[lane], 1 / f.count);
    end
    t.eq({ f:observe(list, B, true) }, { true, false }, 'the expected target is no surprise');
end);

t.test('an observation can be scored without moving the particles', function ()
    local f = new({ max = 8 });
    local list = split(f, 1000);
    local generation = f.generation;
    local predicted = f:predict(list, A);
    t.truthy(predicted > 0.4 and predicted < 0.6, 'half the particles have A ahead: ' .. predicted);
    t.eq({ f.best, f.worst }, { 500, -500 });
    t.eq(f.generation, generation);
    t.eq(f:predict(list, C), nil, 'nothing to score');
    t.eq({ f.predicted, f.best, f.worst }, { nil, nil, nil });
end);

t.test('the classes have names', function ()
    for name, class in pairs(filter.CLASS) do
        t.eq(filter.CLASS_NAMES[class], name);
    end
end);

t.test('a surprise for most particles is no surprise when a few percent of the weight explains it', function ()
    local f = new({ max = 64, jitter = 0 });
    local list = f:newList(10000);
    local row = f:row();
    row[0] = 0;
    -- A leads by 1000 in four particles and trails by 1000 in the other sixty.
    for lane = 1, f.count do
        row[lane] = lane <= 4 and 100 or 0;
    end
    list:cureFixed(A, 2000, 0, row, true);
    list:cureFixed(B, 3000, 0, 0, true);
    t.eq({ f:observe(list, A, true) }, { true, false });
    -- They took most of the weight, and resampling copied them.
    local ahead = 0;
    for lane = 1, f.count do
        ahead = ahead + (list:value(A, lane) > list:value(B, lane) and 1 or 0);
    end
    t.eq(f.resamples, 1);
    t.truthy(ahead > f.count / 2, ('%d of %d particles have A ahead'):format(ahead, f.count));
end);

t.test('a switch instant weighs more than a steady-state observation', function ()
    local steady = new({ max = 8 });
    steady:observe(split(steady, 400), A, false);
    local switch = new({ max = 8 });
    switch:observe(split(switch, 400), A, true);
    t.truthy(switch.weights[1] / switch.weights[2] > steady.weights[1] / steady.weights[2] * 2,
        'the switch separates the particles further');
end);

t.test('an observation says nothing without a rival, or when its target is not on the list', function ()
    local f = new({ max = 8 });
    local list = f:newList(10000);
    list:cureFixed(A, 100, 0, 0, true);
    t.eq(f:observe(list, A, true), false);
    t.eq(f:observe(list, C, true), false);
    list:cureFixed(B, 100, 0, 0, true);
    list:setActive(B, false);
    t.eq(f:observe(list, A, true), false, 'an inactive rival is no rival');
    for lane = 1, f.count do
        t.eq(f.weights[lane], 1 / f.count);
    end
end);

t.test('resampling waits for the effective sample size to fall below its threshold', function ()
    local f = new({ max = 64, jitter = 0 });
    local list = graded(f);
    f:observe(list, A, false);
    t.eq(f.resamples, 0, 'a mild observation keeps the particles');

    for _ = 1, 20 do
        f:observe(list, A, true);
    end
    t.eq(f.resamples > 0, true, 'repeated evidence resamples');
    -- Resampling copies survivors: now nearly every particle has A ahead.
    local ahead = 0;
    for lane = 1, f.count do
        local a = list:value(A, lane);
        local b = list:value(B, lane);
        if a > b then
            ahead = ahead + 1;
        end
    end
    t.truthy(ahead >= f.count * 0.9, ('%d of %d particles have A ahead'):format(ahead, f.count));
end);

t.test('a resampled particle carries its bonus and its enmity state together', function ()
    local f = new({ max = 64, jitter = 0 });
    local row = f:row();
    f:fill(row, A, CLASS.cure, 0);
    local list = f:newList(10000);
    list:cureFixed(A, 1000, 0, row, true);
    list:cureFixed(B, 1100, 0, 0, true);
    for _ = 1, 20 do
        f:observe(list, A, true);
    end
    t.truthy(f.resamples > 0, 'resampled');
    f:fill(row, A, CLASS.cure, 0);
    for lane = 1, f.count do
        local ce = list:value(A, lane);
        local expected = math.floor(f32(1000 * f32((100 + row[lane]) / 100)));
        t.eq(ce, expected, 'lane ' .. lane);
    end
    t.eq(list:value(A, 0), 1000, 'lane 0 stays neutral');
end);

t.test('a belief never freezes: after many resamples the spread of a settled player stays above the nudge floor', function ()
    local f = new({ max = 256 });
    bonuses(f, A, CLASS.melee);
    local list = graded(f);
    -- Ten times, one particle takes all the weight and the rest become its copies.
    for _ = 1, 10 do
        for lane = 1, f.count do
            f.weights[lane] = lane == f.count and 1 or 0;
        end
        f:observe(list, A, true);
    end
    t.eq(f.resamples, 10);
    local p = f:posterior(A);
    t.truthy(p.sd >= 1.5, ('spread %.2f'):format(p.sd));
end);

t.test('the common level of everyone held follows the priors, since the mob only ever compares players', function ()
    local f = new({ max = 256 });
    bonuses(f, A, CLASS.melee);
    bonuses(f, B, CLASS.melee);
    -- Every particle has both at +40 in every class: a level no choice could tell from 0.
    for lane = 1, f.count do
        for _, id in ipairs({ A, B }) do
            local base = (lane * filter.PLAYERS + f.players[id]) * filter.SLOTS;
            for class = 0, filter.CLASSES - 1 do
                f.bonus[base + class] = 40;
            end
        end
    end
    -- One particle holds all the weight, so the next observation resamples onto copies of it.
    for lane = 1, f.count do
        f.weights[lane] = lane == f.count and 1 or 0;
    end
    f:observe(graded(f), A, true);
    t.eq(f.resamples, 1);
    local a, b = f:posterior(A), f:posterior(B);
    t.truthy(a.mean < 15 and b.mean < 15, ('the level came back toward the priors: %.1f, %.1f'):format(a.mean, b.mean));
    t.truthy(math.abs(a.mean - b.mean) < 6, ('the two stay together: %.1f, %.1f'):format(a.mean, b.mean));
end);

t.test('duplicated particles are jittered apart so resampling does not leave copies', function ()
    -- Lanes that match their neighbour in every class of A's bonus.
    local function copies(jitter)
        local f = new({ max = 256, jitter = jitter });
        bonuses(f, A, CLASS.melee);
        local list = graded(f);
        for _ = 1, 30 do
            f:observe(list, A, true);
        end
        t.truthy(f.resamples > 0, 'resampled');
        local rows = {};
        for class = 0, filter.CLASSES - 1 do
            rows[class] = bonuses(f, A, class);
        end
        local n = 0;
        for lane = 2, f.count do
            local same = true;
            for class = 0, filter.CLASSES - 1 do
                same = same and rows[class][lane] == rows[class][lane - 1];
            end
            n = n + (same and 1 or 0);
        end
        return n, f.count;
    end
    local exact, count = copies(0);
    local jittered = copies(nil);
    t.truthy(exact > count / 4, ('without jitter %d of %d are copies'):format(exact, count));
    t.truthy(jittered < exact / 3, ('with jitter %d are'):format(jittered));
end);

t.test('the view reads the weighted median of each entry\'s total', function ()
    local f = new({ max = 5 });
    local list = f:newList(10000);
    local row = f:row();
    local mods = { [0] = 0, -50, -25, 0, 25, 50 };
    for lane = 0, 5 do
        row[lane] = mods[lane];
    end
    list:cureFixed(A, 100, 200, row, true);
    list:cureFixed(B, 7, 0, 0, true);

    local view = f:view(list);
    t.eq({ view:count(), view:idAt(1), view.cap }, { 2, A, 10000 });
    -- Totals 150, 225, 300, 375, 450 at equal weight: the median is 300.
    t.eq({ view:get(A) }, { 100, 200, true });
    t.eq({ view:get(B) }, { 7, 0, true });

    weigh(f, { 0.1, 0.1, 0.1, 0.1, 0.6 });
    t.eq({ view:get(A) }, { 150, 300, true });
    weigh(f, { 0.3, 0.3, 0.1, 0.1, 0.2 });
    t.eq({ view:get(A) }, { 75, 150, true });

    list:setActive(A, false);
    t.eq({ view:get(A) }, { 75, 150, false });
    list:cureFixed(A, 100, 0, 0, true);
    t.eq({ view:get(A) }, { 175, 150, true }, 'a change to the list is seen');
    t.eq(view:get(C), nil);
end);

t.test('the band reads the weighted quantiles of each entry\'s total, the credible interval at its ends', function ()
    t.eq(filter.QUANTILES, { 0.1, 0.3, 0.5, 0.7, 0.9 });
    t.eq(filter.CREDIBLE, 0.8);
    local f = new({ max = 5 });
    local list = f:newList(10000);
    local row = f:row();
    local mods = { [0] = 0, -50, -25, 0, 25, 50 };
    for lane = 0, 5 do
        row[lane] = mods[lane];
    end
    list:cureFixed(A, 100, 200, row, true);
    list:cureFixed(B, 7, 0, 0, true);

    local view = f:view(list);
    -- Totals 150, 225, 300, 375, 450 at equal weight.
    t.eq({ view:band(A) }, { 150, 225, 300, 375, 450 });
    t.eq({ f:bounds(list, A) }, { 150, 450 });
    t.eq({ view:bounds(A) }, { 150, 450 });
    t.eq({ view:band(B) }, { 7, 7, 7, 7, 7 });

    -- Cumulative 0.05, 0.25, 0.35, 0.40, 1.
    weigh(f, { 0.05, 0.2, 0.1, 0.05, 0.6 });
    t.eq({ view:band(A) }, { 225, 300, 450, 450, 450 });
    t.eq({ view:get(A) }, { 150, 300, true }, 'the median is the band\'s middle');
    t.eq(view:band(C), nil);
end);

t.test('band quantiles agree with sorting, through ties and uneven weights', function ()
    local f = new({ max = 200 });
    local list = f:newList(10000);
    local row = f:row();
    math.randomseed(11);
    for trial = 1, 80 do
        local n = f.count;
        local ws = {};
        for lane = 1, n do
            -- Few distinct values, so ties are common; some near-zero weights.
            row[lane] = math.random(0, trial % 3 == 0 and 4 or 150) - 50;
            ws[lane] = math.random() ^ 3;
        end
        -- One particle holding most of the weight, so several quantiles share a total.
        if trial % 4 == 0 then
            ws[math.random(1, n)] = n * (0.2 + trial / 100);
        end
        row[0] = 0;
        list:clear(A);
        list:cureFixed(A, 1000, 0, row, true);
        weigh(f, ws);

        local sorted = {};
        for lane = 1, n do
            sorted[lane] = { list:value(A, lane), f.weights[lane] };
        end
        table.sort(sorted, function (a, b) return a[1] < b[1]; end);
        local expected = {};
        for k, q in ipairs(filter.QUANTILES) do
            local cumulative = 0;
            for i, p in ipairs(sorted) do
                cumulative = cumulative + p[2];
                -- The lowest total whose weight, with every tie, reaches q.
                if cumulative >= q and (sorted[i + 1] == nil or sorted[i + 1][1] ~= p[1]) then
                    expected[k] = p[1];
                    break;
                end
            end
        end
        t.eq({ f:band(list, A) }, expected, 'trial ' .. trial);
    end
end);

t.test('the band narrows as the posterior converges', function ()
    local f = new({ max = 512, prior = function () return { mean = 0, sd = 30, classes = (function ()
        local c = {};
        for class = 0, filter.CLASSES - 1 do c[class] = { mean = 0, sd = 0 }; end
        return c;
    end)() }; end });
    local list = f:newList(10000);
    local row = f:row();
    f:fill(row, A, CLASS.melee, 0);
    list:cureFixed(A, 1000, 1000, row, true);
    local lower, upper = f:bounds(list, A);
    local before = upper - lower;
    t.truthy(before > 400, ('a wide prior gives a wide band: %d'):format(before));

    -- B at A's neutral total: the mob keeps switching between them, so A is near neutral.
    list:cureFixed(B, 1000, 1000, 0, true);
    for i = 1, 30 do
        f:observe(list, i % 2 == 0 and A or B, true);
    end
    lower, upper = f:bounds(list, A);
    t.truthy(upper - lower < before / 2, ('narrowed from %d to %d'):format(before, upper - lower));
end);

t.test('the holder the sim acts on is the one most of the weight puts on top', function ()
    local f = new({ max = 4 });
    local list = f:newList(10000);
    local row = f:row();
    row[0], row[1], row[2], row[3], row[4] = 0, 100, 100, 0, 0;
    list:cureFixed(A, 100, 0, row, true);
    list:cureFixed(B, 150, 0, 0, true);
    t.eq(f:highest(list), A, 'a tie in weight goes to the first listed');
    weigh(f, { 0.2, 0.2, 0.3, 0.3 });
    t.eq(f:highest(list), B);
    weigh(f, { 0.3, 0.3, 0.2, 0.2 });
    t.eq(f:highest(list), A);
end);

t.test('each entry\'s chance of holding hate is the weight of the particles that put it on top', function ()
    local f = new({ max = 4 });
    local list = f:newList(10000);
    local row = f:row();
    -- A tops particles 1 and 2, B particle 3; in particle 4 A and B tie, and C trails everywhere.
    row[0], row[1], row[2], row[3], row[4] = 0, 100, 100, 0, 50;
    list:cureFixed(A, 100, 0, row, true);
    list:cureFixed(B, 150, 0, 0, true);
    list:cureFixed(C, 10, 0, 0, true);
    weigh(f, { 0.1, 0.2, 0.3, 0.4 });

    local function read(current, target)
        local chances, n, at = f:chances(list, current, target);
        local out = {};
        for k = 0, n - 1 do
            out[#out + 1] = math.floor(chances[k] * 1000 + 0.5);
        end
        return { out, at };
    end
    -- The later of a tie tops, as GetHighestEnmity's walk leaves it; unless the mob is on the other.
    t.eq(read(nil, A), { { 300, 700, 0 }, 0 });
    t.eq(read(A, C), { { 700, 300, 0 }, 2 }, 'the current target keeps a tie');
    t.eq(read(B, B), { { 300, 700, 0 }, 1 });

    -- Order follows the list's, and every particle agrees with list:highest.
    for _, current in ipairs({ A, B, C }) do
        local chances = f:chances(list, current, A);
        local expected = { [A] = 0, [B] = 0, [C] = 0 };
        for lane = 1, f.count do
            local top = list:highest(current, lane);
            expected[top] = expected[top] + f.weights[lane];
        end
        for k, id in ipairs(list.order) do
            t.truthy(math.abs(chances[k - 1] - expected[id]) < 1e-12, ('%d on %d'):format(id, current));
        end
    end

    list:setActive(B, false);
    t.eq(read(nil, A), { { 1000, 0, 0 }, 0 }, 'an inactive entry tops nothing');
    t.eq(read(nil, B)[2], nil, 'nothing to score on an inactive target');
    list:setActive(C, false);
    t.eq(read(nil, A)[2], nil, 'nor without an active rival');
    t.eq(read(nil, 0x0001E999)[2], nil, 'nor on someone not on the list');
end);

t.test('the particle count shrinks to hold the frame budget and grows back when there is room', function ()
    local f = new({ max = 1024, min = 32 });
    local list = split(f, 300);
    local perParticle = 2e-6;
    for _ = 1, 3000 do
        f:spend(f.count * perParticle);
        f:frame();
    end
    t.truthy(f.count * perParticle <= filter.BUDGET, ('%d particles cost %g s'):format(f.count, f.count * perParticle));
    t.truthy(f.count * perParticle >= filter.BUDGET * 0.4, ('%d particles is not starved'):format(f.count));
    t.eq(f.lanes, f.count + 1);
    t.truthy(list:value(A, f.count) > 0, 'the list follows the new count');

    for _ = 1, 3000 do
        f:spend(f.count * 1e-8);
        f:frame();
    end
    t.eq(f.count, 1024);

    -- Frames with no work say nothing about the cost.
    for _ = 1, 3000 do
        f:frame();
    end
    t.eq(f.count, 1024);
end);

t.test('a ceiling below the capacity holds the count under it, and can be raised again', function ()
    local f = new({ max = 1024, min = 32 });
    split(f, 300);
    f:setCeiling(200);
    t.eq(f.count, 200, 'brought down at once');
    t.eq(f.lanes, 201);
    for _ = 1, 3000 do
        f:spend(f.count * 1e-8);
        f:frame();
    end
    t.eq(f.count, 200, 'room in the budget grows nothing past it');

    f:setCeiling(4096);
    t.eq(f.ceiling, 1024, 'held to the capacity');
    for _ = 1, 3000 do
        f:spend(f.count * 1e-8);
        f:frame();
    end
    t.eq(f.count, 1024);

    f:setCeiling(0);
    t.eq(f.count, 1, 'at least one particle');
    f:setCeiling(10);
    f:resize(500);
    t.eq(f.count, 10, 'a resize is held to it too');
end);

t.test('resizing keeps each list\'s particles with their bonuses', function ()
    local f = new({ max = 64, jitter = 0 });
    local row = f:row();
    f:fill(row, A, CLASS.melee, 0);
    local list = f:newList(10000);
    list:cureFixed(A, 1000, 0, row, true);
    f:resize(16);
    t.eq({ f.count, f.lanes }, { 16, 17 });
    f:fill(row, A, CLASS.melee, 0);
    for lane = 1, 16 do
        local expected = math.floor(f32(1000 * f32((100 + row[lane]) / 100)));
        t.eq(list:value(A, lane), expected);
    end
end);

t.test('a released list is no longer carried along', function ()
    local f = new({ max = 8, count = 4 });
    local list = f:newList(10000);
    list:cureFixed(A, 1000, 0, 0, true);
    f:view(list):get(A);
    f:release(list);
    local version = list.version;
    f:resize(8);
    t.eq(list.version, version);
    t.eq(f.estimated.list, nil, 'nor held by the estimate');
end);

t.test('resizing keeps the posterior without resampling it', function ()
    local f = new({ max = 8, count = 4, jitter = 0 });
    local list = graded(f);
    weigh(f, { 0.1, 0.2, 0.3, 0.4 });
    local median = { f:view(list):get(A) };

    f:resize(6);
    t.eq(f.resamples, 0);
    -- Particles 1 and 2 were copied onto 5 and 6, each copy taking half.
    t.eq({ list:value(A, 5), list:value(A, 6) }, { list:value(A, 1), list:value(A, 2) });
    local w = {};
    for lane = 1, 6 do
        w[lane] = math.floor(f.weights[lane] * 1000 + 0.5);
    end
    t.eq(w, { 50, 100, 300, 400, 50, 100 });
    t.eq({ f:view(list):get(A) }, median, 'the median holds');

    f:resize(4);
    t.eq({ f.count, f.resamples }, { 4, 0 });
    w = {};
    for lane = 1, 4 do
        w[lane] = math.floor(f.weights[lane] * 1000 + 0.5);
    end
    t.eq(w, { 59, 118, 353, 471 });

    -- What is left can be too lopsided to count as a sample.
    weigh(f, { 0.001, 0.001, 0.997, 0.001 });
    f:resize(3);
    t.eq(f.resamples, 1);
end);

t.test('one heavy frame among light ones is enough to shrink the count', function ()
    local f = new({ max = 1024, min = 32 });
    for frame = 1, 60 do
        f:spend(frame % 10 == 0 and 0.002 or 1e-6);
        f:frame();
    end
    t.truthy(f.count < 300, ('%d particles'):format(f.count));
end);

t.test('a player past the roster\'s room takes the slot of whoever was seen longest ago', function ()
    local f = new({ max = 8 });
    local first = bonuses(f, 1, CLASS.melee);
    for id = 2, filter.PLAYERS do
        bonuses(f, id, CLASS.melee);
    end
    bonuses(f, 1, CLASS.melee);   -- seen again: 2 is now the oldest
    bonuses(f, 1000, CLASS.melee);
    t.eq(bonuses(f, 1, CLASS.melee), first);
    t.eq(f.players[2], nil);
end);

t.test('observing, filling and reading the view allocate nothing once warm', function ()
    local f = new({ max = 32 });
    local row = f:row();
    local list = split(f, 300);
    local view = f:view(list);
    local function work()
        f:fill(row, A, CLASS.melee, 0);
        list:damage(A, 100, 75, row, true);
        list:lowerByPercent(A, 50);
        list:decay(1);
        f:observe(list, A, true);
        f:observe(list, A, true);
        f:observe(list, B, false);
        view:get(A);
        view:band(B);
        f:bounds(list, A);
        f:highest(list);
        f:chances(list, A, B);
    end
    for _ = 1, 200 do
        work();
    end
    -- 2000 calls allocating even one small table each would be 80 KB.
    local resamples = f.resamples;
    local grown = t.allocated(work, 2000);
    t.truthy(f.resamples > resamples, 'resampling was exercised');
    t.truthy(grown < 4, ('allocated %.1f KB'):format(grown));
end);

t.test('a Muted Soul rank is drawn per particle from the prior, and taken off the row only while asked', function ()
    local prior = { mean = 0, sd = 5, classes = {}, muted = { [0] = 0.5, 0, 0, 0, 0, 0.5 } };
    for class = 0, filter.CLASSES - 1 do
        prior.classes[class] = { mean = 0, sd = 1 };
    end
    local f = new({ max = 1024, prior = function () return prior; end });
    local plain, muted = f:row(), f:row();
    f:fill(plain, A, CLASS.melee, 10);
    f:fill(muted, A, CLASS.melee, 10, true);
    t.eq({ plain[0], muted[0] }, { 10, 10 }, 'the neutral replay has no merits');
    local fives, zeros = 0, 0;
    for lane = 1, f.count do
        local off = plain[lane] - muted[lane];
        if off == 50 then
            fives = fives + 1;
        elseif off == 0 then
            zeros = zeros + 1;
        else
            t.truthy(false, 'a rank of ' .. off);
        end
    end
    t.truthy(fives > 400 and zeros > 400, ('half and half: %d, %d'):format(fives, zeros));
    local p = f:posterior(A);
    t.truthy(math.abs(p.muted[5] - 0.5) < 0.05 and math.abs(p.muted[0] - 0.5) < 0.05, 'the posterior counts the ranks');

    local ws = {};
    for lane = 1, f.count do
        ws[lane] = plain[lane] - muted[lane] == 50 and 1 or 1e-9;
    end
    weigh(f, ws);
    t.truthy(f:posterior(A).muted[5] > 0.99, 'weight on the merited particles alone');
end);

t.test('a player who cannot have the merit draws none, and their other draws are as before', function ()
    local before = bonuses(new({ max = 64 }), A, CLASS.melee);
    local f = new({ max = 64 });
    local row = f:row();
    f:fill(row, A, CLASS.melee, 0, true);
    local out = {};
    for lane = 1, f.count do
        out[lane] = row[lane];
    end
    t.eq(out, before);
    t.eq(f:posterior(A).muted[0], 1);
end);

return t.done();

-- Lane 0 is no particle: the neutral replay with every hidden bonus at zero.

local bit = require('bit');
local ffi = require('ffi');
local hatelist = require('hatelist');
local priors = require('priors');

local filter = {};
filter.__index = filter;

filter.CLASS = priors.CLASS;
filter.CLASSES = priors.CLASSES;
-- Each player's block is one bonus a class, then their Muted Soul rank as Enmity (0..50), at MUTED.
filter.SLOTS = priors.CLASSES + 1;
filter.MUTED = priors.CLASSES;
filter.CLASS_NAMES = {};
for name, class in pairs(filter.CLASS) do
    filter.CLASS_NAMES[class] = name;
end

filter.PLAYERS = 32;

filter.MAX = 1024;
filter.MIN = 64;

filter.BUDGET = 0.0005;

-- Enmity's clamp, which every drawn bonus is held to.
local LOW, HIGH = -50, 100;

filter.WIDE = { mean = (LOW + HIGH) / 2, sd = (HIGH - LOW) / 4, classes = {}, muted = priors.ANY_RANK };
for class = 0, priors.CLASSES - 1 do
    filter.WIDE.classes[class] = { mean = 0, sd = 20 };
end

filter.FLOOR = 0.05;
filter.SCALE = 200;
filter.STEADY = 0.2;
filter.SWITCH = 1;

filter.SURPRISE = 0.01;

filter.QUANTILES = { 0.1, 0.3, 0.5, 0.7, 0.9 };
filter.STOPS = #filter.QUANTILES;
filter.CREDIBLE = filter.QUANTILES[filter.STOPS] - filter.QUANTILES[1];
local QUANTILES, STOPS, MEDIAN = filter.QUANTILES, filter.STOPS, (filter.STOPS + 1) / 2;

filter.RESAMPLE = 0.5;

local JITTER = 0.3;
local JITTER_FLOOR = 2;
local MUTATION = 0.02;

local WINDOW = 30;
local HEADROOM = 0.8;
local GROW_BELOW = 0.5;
local GROWTH = 1.25;

local function round(x)
    return math.floor(x + 0.5);
end

local function clamp(v, lo, hi)
    if v < lo then
        return lo;
    elseif v > hi then
        return hi;
    end
    return v;
end

function filter.new(opts)
    opts = opts or {};
    local max = opts.max or filter.MAX;
    local count = math.min(opts.count or max, max);
    local capacity = max + 1;
    local stride = filter.PLAYERS * filter.SLOTS;
    local self = setmetatable({
        max = max,
        ceiling = max,
        min = math.min(opts.min or filter.MIN, max),
        count = count,
        lanes = count + 1,
        capacity = capacity,
        random = opts.random or math.random,
        clock = opts.clock or os.clock,
        prior = opts.prior,
        retire = opts.retire,
        jitter = opts.jitter or JITTER,
        weights = ffi.new('double[?]', capacity),
        agree = ffi.new('double[?]', capacity),
        bonus = ffi.new('int16_t[?]', capacity * stride),
        spare = ffi.new('int16_t[?]', capacity * stride),
        ancestors = ffi.new('int32_t[?]', capacity),
        scratch = ffi.new('int32_t[?]', capacity * hatelist.SLOTS * 2),
        keys = ffi.new('int32_t[?]', capacity),
        order = ffi.new('int32_t[?]', capacity),
        spareOrder = ffi.new('int32_t[?]', capacity),
        counts = ffi.new('int32_t[256]'),
        rivals = ffi.new('int32_t[?]', hatelist.SLOTS),
        chanceOf = ffi.new('double[?]', hatelist.SLOTS),
        chanceSlots = ffi.new('int32_t[?]', hatelist.SLOTS),
        estimates = ffi.new('int32_t[?]', hatelist.SLOTS * 2),
        bands = ffi.new('int32_t[?]', hatelist.SLOTS * STOPS),
        stopLanes = ffi.new('int32_t[?]', STOPS + 1),
        players = {},
        owners = {},
        priorOf = {},
        spread = ffi.new('double[?]', filter.PLAYERS),
        commonMean = 0,
        commonSd = 0,
        seen = {},
        stamp = 0,
        lists = {},
        generation = 0,
        resamples = 0,
        estimated = { list = nil, version = -1, generation = -1 },
        spent = 0,
        peak = 0,
        busy = 0,
    }, filter);
    for lane = 1, count do
        self.weights[lane] = 1 / count;
    end
    self.viewer = setmetatable({ filter = self, list = nil, cap = 0 }, filter.View);
    return self;
end

local function gauss(random)
    return math.sqrt(-2 * math.log(1 - random())) * math.cos(2 * math.pi * random());
end

local function updateCommon(self)
    local n, mean, variance = 0, 0, 0;
    for player = 0, filter.PLAYERS - 1 do
        local prior = self.owners[player] ~= nil and self.priorOf[player] or nil;
        if prior ~= nil and prior.sd > 0 then
            n = n + 1;
            mean = mean + math.log(1 + prior.mean / 100);
            local s = prior.sd / (100 + prior.mean);
            variance = variance + s * s;
        end
    end
    if n > 0 then
        self.commonMean, self.commonSd = mean / n, math.sqrt(variance) / n;
    end
end

-- No random is spent on a player who can't have the merit, so their draws stay as they were.
local function drawRank(random, muted)
    if muted[0] >= 1 then
        return 0;
    end
    local u, cumulative = random(), 0;
    for rank = 0, priors.RANKS do
        cumulative = cumulative + muted[rank];
        if u < cumulative then
            return rank * priors.RANK_STEP;
        end
    end
    return priors.RANKS * priors.RANK_STEP;
end

local function draw(self, player, id, prior)
    if prior == nil then
        prior = self.prior and self.prior(id) or priors.NEUTRAL;
        self.priorOf[player] = prior;
        updateCommon(self);
    end
    local bonus, random, classes = self.bonus, self.random, filter.CLASSES;
    local muted = prior.muted or priors.NO_MERITS;
    for lane = 1, self.count do
        local centre = prior.mean + prior.sd * gauss(random);
        local base = (lane * filter.PLAYERS + player) * filter.SLOTS;
        for class = 0, classes - 1 do
            local c = prior.classes[class];
            bonus[base + class] = clamp(round(centre + c.mean + c.sd * gauss(random)), LOW, HIGH);
        end
        bonus[base + filter.MUTED] = drawRank(random, muted);
    end
end

local function playerOf(self, id)
    self.stamp = self.stamp + 1;
    local slot = self.players[id];
    if slot == nil then
        for s = 0, filter.PLAYERS - 1 do
            if self.owners[s] == nil then
                slot = s;
                break;
            elseif slot == nil or self.seen[s] < self.seen[slot] then
                slot = s;
            end
        end
        local previous = self.owners[slot];
        if previous ~= nil then
            if self.retire ~= nil then
                self.retire(previous);
            end
            self.players[previous] = nil;
        end
        self.players[id], self.owners[slot] = slot, id;
        draw(self, slot, id);
    end
    self.seen[slot] = self.stamp;
    return slot;
end

function filter:posterior(id)
    local slot = self.players[id];
    if slot == nil then
        return nil;
    end
    local K, w, bonus = filter.CLASSES, self.weights, self.bonus;
    local centre, centreSq = 0, 0;
    local offset, offsetSq = {}, {};
    for class = 0, K - 1 do
        offset[class], offsetSq[class] = 0, 0;
    end
    local muted = {};
    for rank = 0, priors.RANKS do
        muted[rank] = 0;
    end
    for lane = 1, self.count do
        local base = (lane * filter.PLAYERS + slot) * filter.SLOTS;
        local c = 0;
        for class = 0, K - 1 do
            c = c + bonus[base + class] / K;
        end
        local wl = w[lane];
        centre, centreSq = centre + wl * c, centreSq + wl * c * c;
        for class = 0, K - 1 do
            local d = bonus[base + class] - c;
            offset[class], offsetSq[class] = offset[class] + wl * d, offsetSq[class] + wl * d * d;
        end
        local rank = bonus[base + filter.MUTED] / priors.RANK_STEP;
        muted[rank] = muted[rank] + wl;
    end

    local variance, total = {}, 0;
    for class = 0, K - 1 do
        variance[class] = math.max(0, offsetSq[class] - offset[class] ^ 2);
        total = total + variance[class];
    end
    total = total * K / (K - 1);
    local classes = {};
    for class = 0, K - 1 do
        local t = math.max(0, (variance[class] - total / (K * K)) / (1 - 2 / K));
        classes[class] = { mean = offset[class], sd = math.sqrt(t) };
    end
    local spread = math.max(0, centreSq - centre * centre - total / (K * K));
    return { mean = centre, sd = math.sqrt(spread), classes = classes, muted = muted };
end

function filter:widen(id)
    local slot = self.players[id];
    if slot == nil then
        return false;
    end
    local prior = self.priorOf[slot];
    local wide = filter.WIDE;
    if prior == nil or prior.muted == nil or prior.muted[0] >= 1 then
        wide = { mean = wide.mean, sd = wide.sd, classes = wide.classes, muted = priors.NO_MERITS };
    end
    draw(self, slot, id, wide);
    self.generation = self.generation + 1;
    return true;
end

function filter:resetWeights()
    local w, count = self.weights, self.count;
    for lane = 1, count do
        w[lane] = 1 / count;
    end
    self.generation = self.generation + 1;
end

function filter:forget(id)
    local slot = self.players[id];
    if slot ~= nil then
        self.players[id], self.owners[slot], self.seen[slot], self.priorOf[slot] = nil, nil, nil, nil;
        updateCommon(self);
    end
end

function filter:row()
    return ffi.new('int32_t[?]', self.capacity);
end

function filter:fill(row, id, class, known, muted)
    local block = playerOf(self, id) * filter.SLOTS;
    local base, stride, bonus = block + class, filter.PLAYERS * filter.SLOTS, self.bonus;
    row[0] = known;
    if muted then
        local rank = block + filter.MUTED;
        for lane = 1, self.count do
            local at = lane * stride;
            row[lane] = known + bonus[at + base] - bonus[at + rank];
        end
    else
        for lane = 1, self.count do
            row[lane] = known + bonus[lane * stride + base];
        end
    end
    return row;
end

function filter:newList(cap)
    local list = hatelist.new(cap, self);
    self.lists[list] = true;
    return list;
end

function filter:release(list)
    self.lists[list] = nil;
    if self.estimated.list == list then
        self.estimated.list = nil;
    end
end

function filter:ess()
    local squares, w = 0, self.weights;
    for lane = 1, self.count do
        squares = squares + w[lane] * w[lane];
    end
    return 1 / squares;
end

local function spreads(self)
    local w, bonus, spread, classes = self.weights, self.bonus, self.spread, filter.CLASSES;
    for player = 0, filter.PLAYERS - 1 do
        if self.owners[player] ~= nil then
            local mean, square = 0, 0;
            for lane = 1, self.count do
                local base = (lane * filter.PLAYERS + player) * filter.SLOTS;
                local centre = 0;
                for class = 0, classes - 1 do
                    centre = centre + bonus[base + class];
                end
                centre = centre / classes;
                local wl = w[lane];
                mean, square = mean + wl * centre, square + wl * centre * centre;
            end
            spread[player] = math.sqrt(math.max(0, square - mean * mean));
        end
    end
end

-- The common level is redrawn from the priors after each nudge; without it the level walks off with every nudge.
local function jitter(self, lane)
    local scale, random, bonus, classes, spread = self.jitter, self.random, self.bonus, filter.CLASSES, self.spread;
    local n, sum = 0, 0;
    for player = 0, filter.PLAYERS - 1 do
        local prior = self.owners[player] ~= nil and self.priorOf[player] or nil;
        if prior ~= nil and prior.sd > 0 then
            local sd = math.max(JITTER_FLOOR, scale * spread[player]);
            local shift = gauss(random) * sd;
            local base = (lane * filter.PLAYERS + player) * filter.SLOTS;
            local centre = 0;
            for class = 0, classes - 1 do
                local v = clamp(round(bonus[base + class] + shift + gauss(random) * sd * 0.5), LOW, HIGH);
                bonus[base + class] = v;
                centre = centre + v;
            end
            if prior.muted ~= nil and prior.muted[0] < 1 and random() < MUTATION then
                bonus[base + filter.MUTED] = drawRank(random, prior.muted);
            end
            n = n + 1;
            sum = sum + math.log(1 + centre / classes / 100);
        end
    end
    if n == 0 then
        return;
    end
    local factor = math.exp(self.commonMean + self.commonSd * gauss(random) - sum / n);
    for player = 0, filter.PLAYERS - 1 do
        local prior = self.owners[player] ~= nil and self.priorOf[player] or nil;
        if prior ~= nil and prior.sd > 0 then
            local base = (lane * filter.PLAYERS + player) * filter.SLOTS;
            for class = 0, classes - 1 do
                bonus[base + class] = clamp(round(100 * ((1 + bonus[base + class] / 100) * factor - 1)), LOW, HIGH);
            end
        end
    end
end

local function permuteLists(self, n)
    for list in pairs(self.lists) do
        if ffi.sizeof(self.scratch) < self.capacity * list:stride() * ffi.sizeof('int32_t') then
            self.scratch = ffi.new('int32_t[?]', self.capacity * list:stride());
        end
        list:permute(self.ancestors, n, self.scratch);
    end
end

local function resample(self, n)
    local w, anc, count, random = self.weights, self.ancestors, self.count, self.random;
    local step = 1 / n;
    local u, j, cumulative = random() * step, 1, w[1];
    for i = 1, n do
        local point = u + (i - 1) * step;
        while point > cumulative and j < count do
            j = j + 1;
            cumulative = cumulative + w[j];
        end
        anc[i] = j;
    end

    if self.jitter > 0 then
        spreads(self);
    end
    local stride, bonus, spare = filter.PLAYERS * filter.SLOTS, self.bonus, self.spare;
    for i = 1, n do
        local to, from = i * stride, anc[i] * stride;
        for k = 0, stride - 1 do
            spare[to + k] = bonus[from + k];
        end
    end
    self.bonus, self.spare = spare, bonus;

    permuteLists(self, n);

    if self.jitter > 0 then
        for i = 2, n do
            if anc[i] == anc[i - 1] then
                jitter(self, i);
            end
        end
    end

    self.count, self.lanes = n, n + 1;
    for lane = 1, n do
        w[lane] = step;
    end
    self.generation = self.generation + 1;
    self.resamples = self.resamples + 1;
end

function filter:resize(n)
    n = clamp(n, 1, self.ceiling);
    local count, w = self.count, self.weights;
    if n < count then
        local kept = 0;
        for lane = 1, n do
            kept = kept + w[lane];
        end
        for lane = 1, n do
            w[lane] = w[lane] / kept;
        end
    elseif n > count then
        local anc, bonus, stride = self.ancestors, self.bonus, filter.PLAYERS * filter.SLOTS;
        for lane = 1, count do
            anc[lane] = lane;
        end
        for lane = count + 1, n do
            local original = (lane - count - 1) % count + 1;
            anc[lane] = original;
            for k = 0, stride - 1 do
                bonus[lane * stride + k] = bonus[original * stride + k];
            end
        end
        permuteLists(self, n);
        local extra = n - count;
        for lane = 1, count do
            local copies = 1 + math.floor(extra / count) + ((lane - 1) < extra % count and 1 or 0);
            w[lane] = w[lane] / copies;
        end
        for lane = count + 1, n do
            w[lane] = w[anc[lane]];
        end
    else
        return;
    end
    self.count, self.lanes = n, n + 1;
    self.generation = self.generation + 1;
    if self:ess() < n * filter.RESAMPLE then
        resample(self, n);
    end
end

local function logistic(x)
    return 1 / (1 + math.exp(-x));
end

local function score(self, list, target)
    self.predicted, self.best, self.worst = nil, nil, nil;
    local entry = list.entries[target];
    if entry == nil or not entry.active then
        return nil;
    end
    if list.slots * ffi.sizeof('int32_t') > ffi.sizeof(self.rivals) then
        self.rivals = ffi.new('int32_t[?]', list.slots);
    end
    local rivals, n = self.rivals, 0;
    for _, id in ipairs(list.order) do
        local e = list.entries[id];
        if id ~= target and e.active then
            rivals[n], n = e.slot, n + 1;
        end
    end
    if n == 0 then
        return nil;
    end

    local v, slots, w, agree = list.v, list.slots, self.weights, self.agree;
    local scale = filter.SCALE;
    local predicted, most, least = 0, -math.huge, math.huge;
    for lane = 1, self.count do
        local base = lane * slots;
        local i = (base + entry.slot) * 2;
        local total = v[i] + v[i + 1];
        local best = -1;
        for r = 0, n - 1 do
            local k = (base + rivals[r]) * 2;
            local rival = v[k] + v[k + 1];
            if rival > best then
                best = rival;
            end
        end
        local margin = total - best;
        if margin > most then
            most = margin;
        end
        if margin < least then
            least = margin;
        end
        local p = logistic(margin / scale);
        agree[lane] = p;
        predicted = predicted + w[lane] * p;
    end
    self.predicted, self.best, self.worst = predicted, most, least;
    return predicted;
end

function filter:predict(list, target)
    return score(self, list, target);
end

function filter:observe(list, target, switch)
    local predicted = score(self, list, target);
    if predicted == nil then
        return false;
    end
    if predicted < filter.SURPRISE then
        return false, true;
    end

    local w, agree = self.weights, self.agree;
    local power = switch and filter.SWITCH or filter.STEADY;
    local floor = filter.FLOOR;
    local sum = 0;
    for lane = 1, self.count do
        local weight = w[lane] * (floor + (1 - floor) * agree[lane]) ^ power;
        w[lane] = weight;
        sum = sum + weight;
    end
    for lane = 1, self.count do
        w[lane] = w[lane] / sum;
    end
    self.generation = self.generation + 1;

    if self:ess() < self.count * filter.RESAMPLE then
        resample(self, self.count);
    end
    return true, false;
end

function filter:highest(list, current)
    local chances, n = self:chances(list, current, nil);
    local best, most = nil, 0;
    for k = 0, n - 1 do
        if chances[k] > most then
            best, most = list.order[k + 1], chances[k];
        end
    end
    return best;
end

-- The returned chances buffer is reused: valid only until the next call.
function filter:chances(list, current, target)
    local order, entries = list.order, list.entries;
    local n = #order;
    if n * ffi.sizeof('double') > ffi.sizeof(self.chanceOf) then
        self.chanceOf = ffi.new('double[?]', n);
        self.chanceSlots = ffi.new('int32_t[?]', n);
    end
    local chances, slots = self.chanceOf, self.chanceSlots;
    local held, at, active = -1, nil, 0;
    for k = 0, n - 1 do
        local id = order[k + 1];
        local e = entries[id];
        chances[k] = 0;
        slots[k] = e.active and e.slot or -1;
        if e.active then
            active = active + 1;
            if id == target then
                at = k;
            end
        end
        if id == current then
            held = k;
        end
    end

    local v, stride, w, leader = list.v, list.slots, self.weights, hatelist.leader;
    for lane = 1, self.count do
        local best = leader(v, lane * stride, slots, n, held);
        if best ~= -1 then
            chances[best] = chances[best] + w[lane];
        end
    end
    if active < 2 then
        at = nil;
    end
    return chances, n, at;
end

local function sortLanes(keys, order, spare, counts, count, highest)
    local src, dst = order, spare;
    for lane = 1, count do
        src[lane] = lane;
    end
    local shift = 0;
    repeat
        for d = 0, 255 do
            counts[d] = 0;
        end
        for i = 1, count do
            local d = bit.band(bit.rshift(keys[src[i]], shift), 255);
            counts[d] = counts[d] + 1;
        end
        local at = 1;
        for d = 0, 255 do
            at, counts[d] = at + counts[d], at;
        end
        for i = 1, count do
            local lane = src[i];
            local d = bit.band(bit.rshift(keys[lane], shift), 255);
            dst[counts[d]] = lane;
            counts[d] = counts[d] + 1;
        end
        src, dst = dst, src;
        shift = shift + 8;
    until bit.rshift(highest, shift) == 0;
    return src;
end

local function estimate(self, list)
    local cache = self.estimated;
    if cache.list == list and cache.version == list.version and cache.generation == self.generation then
        return;
    end
    local since = self.clock();
    cache.list, cache.version, cache.generation = list, list.version, self.generation;
    if ffi.sizeof(self.estimates) < list.slots * 2 * ffi.sizeof('int32_t') then
        self.estimates = ffi.new('int32_t[?]', list.slots * 2);
        self.bands = ffi.new('int32_t[?]', list.slots * STOPS);
    end

    local v, slots, keys, w, count = list.v, list.slots, self.keys, self.weights, self.count;
    local out, bands, lanes = self.estimates, self.bands, self.stopLanes;
    for _, id in ipairs(list.order) do
        local slot = list.entries[id].slot;
        local highest = 0;
        for lane = 1, count do
            local i = (lane * slots + slot) * 2;
            local total = v[i] + v[i + 1];
            keys[lane] = total;
            if total > highest then
                highest = total;
            end
        end
        local sorted = sortLanes(keys, self.order, self.spareOrder, self.counts, count, highest);
        local k, cumulative = 1, 0;
        for i = 1, count do
            local lane = sorted[i];
            cumulative = cumulative + w[lane];
            while k <= STOPS and cumulative >= QUANTILES[k] do
                lanes[k], k = lane, k + 1;
            end
            if k > STOPS then
                break;
            end
        end
        -- Weights summing a hair short of a quantile.
        for rest = k, STOPS do
            lanes[rest] = sorted[count];
        end
        for q = 1, STOPS do
            bands[slot * STOPS + q - 1] = keys[lanes[q]];
        end
        local i = (lanes[MEDIAN] * slots + slot) * 2;
        out[slot * 2], out[slot * 2 + 1] = v[i], v[i + 1];
    end
    self:spend(self.clock() - since);
end

function filter:median(list, id)
    local e = list.entries[id];
    if e == nil then
        return;
    end
    estimate(self, list);
    return self.estimates[e.slot * 2], self.estimates[e.slot * 2 + 1], e.active;
end

function filter:band(list, id)
    local e = list.entries[id];
    if e == nil then
        return;
    end
    estimate(self, list);
    local b, base = self.bands, e.slot * STOPS;
    return b[base], b[base + 1], b[base + 2], b[base + 3], b[base + 4];
end

function filter:bounds(list, id)
    if list.entries[id] == nil then
        return;
    end
    local lower, _, _, _, upper = self:band(list, id);
    return lower, upper;
end

filter.View = {};
filter.View.__index = filter.View;

function filter:view(list)
    local view = self.viewer;
    view.list, view.cap = list, list.cap;
    return view;
end

function filter.View:count()
    return self.list:count();
end

function filter.View:idAt(i)
    return self.list:idAt(i);
end

function filter.View:get(id)
    return self.filter:median(self.list, id);
end

function filter.View:band(id)
    return self.filter:band(self.list, id);
end

function filter.View:bounds(id)
    return self.filter:bounds(self.list, id);
end

function filter:spend(seconds)
    self.spent = self.spent + seconds;
end

function filter:frame()
    local spent = self.spent;
    self.spent = 0;
    if spent <= 0 then
        return;
    end
    self.peak = math.max(self.peak, spent);
    self.busy = self.busy + 1;
    if self.busy < WINDOW then
        return;
    end
    local peak, count = self.peak, self.count;
    self.busy, self.peak = 0, 0;

    if peak > filter.BUDGET then
        self:resize(math.max(self.min, math.floor(count * filter.BUDGET / peak * HEADROOM)));
    elseif peak < filter.BUDGET * GROW_BELOW then
        self:resize(math.min(self.ceiling, math.ceil(count * GROWTH)));
    end
end

function filter:setCeiling(n)
    self.ceiling = clamp(math.floor(n), 1, self.max);
    if self.count > self.ceiling then
        self:resize(self.ceiling);
    end
end

return filter;

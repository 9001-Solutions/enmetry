--[[
* Lines a session log up against the server's own enmity log, written by
* the enmetry_enmity_log module on a LandSandBoat server, and reports how
* far the addon's values sat from what the server held.
*
* Run from the repo root:
*   luajit tools/compare.lua <path/to/enmetry-*.jsonl> <path/to/enmity-*.jsonl> [--mob <id>]
*
* The addon's snapshots come once a second on its own clock; the session
* line's wall time pins that clock to the server's, to the second, and the
* constant offset between the two clocks is then fitted: the one, within a
* second and a half, under which the most server entries equal the neutral
* replay's CE.  Ticks an older server log stamped to the whole second are
* spread evenly across it first.  Each server tick is matched to the
* addon's nearest snapshot of the same mob within a second and a half, and
* every entry the two share is compared: the neutral replay and the
* posterior median against the server's CE and VE, and whoever each has on
* top against the server's own top.  Each player's true Enmity, as the
* server applied it, is set beside what the filter concluded.
--]]

package.path = './addon/?.lua;./tools/?.lua;' .. package.path;

local json = require('json');

local WITHIN = 1.5;
local OFFSET_STEP = 0.05;
-- One combat tick of VE decay: a VE within it is the same value a tick apart.
local DECAY = 24;

local function readLines(path)
    local fh = assert(io.open(path, 'rb'), 'cannot read ' .. path);
    local lines = {};
    for line in fh:lines() do
        if line:find('%S') then
            local ok, v = pcall(json.decode, line);
            if ok and type(v) == 'table' then
                lines[#lines + 1] = v;
            end
        end
    end
    fh:close();
    return lines;
end

local function parseArgs(argv)
    local out = {};
    local i = 1;
    while i <= #argv do
        if argv[i] == '--mob' then
            out.mob = tonumber(argv[i + 1]);
            i = i + 2;
        elseif out.client == nil then
            out.client = argv[i];
            i = i + 1;
        else
            out.server = argv[i];
            i = i + 1;
        end
    end
    assert(out.client and out.server, 'which logs? <client> <server>');
    return out;
end

-- The addon's snapshots by mob, each with its wall time, in order.
local function clientSnapshots(lines)
    local wall0, t0, names, posterior = nil, nil, {}, nil;
    local byMob = {};
    for _, v in ipairs(lines) do
        if v.k == 'session' then
            wall0, t0 = v.wall, v.t;
        elseif v.k == 'roster' then
            for _, m in ipairs(v.members) do
                names[m.id] = m.name;
            end
        elseif v.k == 'posterior' then
            posterior = v;
        elseif v.k == 'snapshot' and wall0 ~= nil then
            for _, m in ipairs(v.mobs) do
                local list = byMob[m.mob] or {};
                byMob[m.mob] = list;
                local rows = {};
                for _, r in ipairs(m.rows) do
                    rows[r[1]] = r;
                end
                list[#list + 1] = { wall = wall0 + (v.t - t0), rows = rows, clean = m.clean, name = m.name };
            end
        end
    end
    return byMob, names, posterior;
end

-- The snapshot of `mob` nearest `wall`, within WITHIN seconds, or nil.
-- Snapshots are in time order, so the search is binary.
local function nearest(snapshots, wall)
    local lo, hi = 1, #snapshots;
    while lo < hi do
        local mid = math.floor((lo + hi) / 2);
        if snapshots[mid].wall < wall then
            lo = mid + 1;
        else
            hi = mid;
        end
    end
    local best, bestGap = nil, WITHIN;
    for i = math.max(1, lo - 1), math.min(#snapshots, lo) do
        local gap = math.abs(snapshots[i].wall - wall);
        if gap <= bestGap then
            best, bestGap = snapshots[i], gap;
        end
    end
    return best;
end

--[[
* Server ticks stamped to the whole second are spread evenly across it, in
* the order they were written; stamps with a fraction are left alone.
--]]
local function spreadStamps(server)
    for _, line in ipairs(server) do
        if line.wall ~= math.floor(line.wall) then
            return;
        end
    end
    local i = 1;
    while i <= #server do
        local j = i;
        while j < #server and server[j + 1].wall == server[i].wall do
            j = j + 1;
        end
        local count = j - i + 1;
        for k = i, j do
            server[k].wall = server[k].wall + (k - i) / count;
        end
        i = j + 1;
    end
end

-- How many server entries equal the neutral replay's CE with the client's clock moved by `offset`.
local function agreement(server, snapshots, mob, offset)
    local hits = 0;
    for _, line in ipairs(server) do
        if line.k == 'tick' and (mob == nil or line.mob == mob) and snapshots[line.mob] ~= nil then
            local snap = nearest(snapshots[line.mob], line.wall + offset);
            if snap ~= nil then
                for _, e in ipairs(line.entries) do
                    local r = snap.rows[e[1]];
                    if r ~= nil and r[2] == e[3] then
                        hits = hits + 1;
                    end
                end
            end
        end
    end
    return hits;
end

-- The clock offset, within WITHIN, under which the most entries agree exactly.
local function fitOffset(server, snapshots, mob)
    local best, bestHits = 0, -1;
    local steps = math.floor(WITHIN / OFFSET_STEP);
    for i = -steps, steps do
        local offset = i * OFFSET_STEP;
        local hits = agreement(server, snapshots, mob, offset);
        if hits > bestHits then
            best, bestHits = offset, hits;
        end
    end
    return best, bestHits;
end

local function topOf(entries, ce, ve, active)
    local best, bestTotal = nil, -1;
    for _, e in ipairs(entries) do
        if active(e) then
            local total = ce(e) + ve(e);
            if total > bestTotal then
                best, bestTotal = e, total;
            end
        end
    end
    return best;
end

local function main(argv)
    local args = parseArgs(argv);
    local client = readLines(args.client);
    local server = readLines(args.server);
    local snapshots, names, posterior = clientSnapshots(client);
    spreadStamps(server);
    local offset = fitOffset(server, snapshots, args.mob);

    local perMob = {};
    local truth = {};   -- player id -> { name, mods = { [value] = ticks } }
    local matched, unmatched = 0, 0;
    for _, line in ipairs(server) do
        if (line.k == 'tick' or line.k == 'dump') and (args.mob == nil or line.mob == args.mob) then
            for _, e in ipairs(line.entries) do
                local id = e[1];
                local t = truth[id] or { name = e[2], mods = {} };
                truth[id] = t;
                local bonus = e[6] + e[7] - e[8];
                t.mods[bonus] = (t.mods[bonus] or 0) + 1;
            end
            local snap = snapshots[line.mob] and nearest(snapshots[line.mob], line.wall + offset);
            if snap == nil then
                unmatched = unmatched + 1;
            else
                matched = matched + 1;
                local stats = perMob[line.mob] or {
                    name = line.name, ticks = 0, entries = 0, neutralCe = 0, neutralVe = 0, medianCe = 0, medianVe = 0,
                    topNeutral = 0, topMedian = 0, clean = 0, exactCe = 0, exactVe = 0,
                };
                perMob[line.mob] = stats;
                stats.ticks = stats.ticks + 1;
                if snap.clean then
                    stats.clean = stats.clean + 1;
                end
                for _, e in ipairs(line.entries) do
                    local r = snap.rows[e[1]];
                    if r ~= nil then
                        stats.entries = stats.entries + 1;
                        if r[2] == e[3] then
                            stats.exactCe = stats.exactCe + 1;
                        end
                        if math.abs(r[3] - e[4]) <= DECAY then
                            stats.exactVe = stats.exactVe + 1;
                        end
                        stats.neutralCe = stats.neutralCe + math.abs(r[2] - e[3]);
                        stats.neutralVe = stats.neutralVe + math.abs(r[3] - e[4]);
                        stats.medianCe = stats.medianCe + math.abs(r[4] - e[3]);
                        stats.medianVe = stats.medianVe + math.abs(r[5] - e[4]);
                    end
                end
                local serverTop = topOf(line.entries, function (e) return e[3]; end, function (e) return e[4]; end,
                    function (e) return e[5]; end);
                local shared = {};
                for _, e in ipairs(line.entries) do
                    if snap.rows[e[1]] ~= nil then
                        shared[#shared + 1] = snap.rows[e[1]];
                    end
                end
                local neutralTop = topOf(shared, function (r) return r[2]; end, function (r) return r[3]; end, function (r) return r[6]; end);
                local medianTop = topOf(shared, function (r) return r[4]; end, function (r) return r[5]; end, function (r) return r[6]; end);
                if serverTop ~= nil and neutralTop ~= nil and neutralTop[1] == serverTop[1] then
                    stats.topNeutral = stats.topNeutral + 1;
                end
                if serverTop ~= nil and medianTop ~= nil and medianTop[1] == serverTop[1] then
                    stats.topMedian = stats.topMedian + 1;
                end
            end
        end
    end

    print(('%d server ticks matched to a snapshot, %d not (no snapshot of that mob within %gs); clocks fitted %+.2fs apart'):format(
        matched, unmatched, WITHIN, offset));
    local mobs = {};
    for mob in pairs(perMob) do
        mobs[#mobs + 1] = mob;
    end
    table.sort(mobs, function (a, b) return perMob[a].ticks > perMob[b].ticks; end);
    for _, mob in ipairs(mobs) do
        local s = perMob[mob];
        local n = math.max(1, s.entries);
        print(('\n%s (%d): %d ticks, %d clean, %d entry comparisons'):format(s.name or mob, mob, s.ticks, s.clean, s.entries));
        print(('  neutral replay: mean |CE error| %.0f, |VE error| %.0f; on top as the server had it %.0f%% of ticks'):format(
            s.neutralCe / n, s.neutralVe / n, 100 * s.topNeutral / s.ticks));
        print(('  neutral replay: CE exact on %.0f%% of entries, VE within one decay step on %.0f%%'):format(
            100 * s.exactCe / n, 100 * s.exactVe / n));
        print(('  posterior median: mean |CE error| %.0f, |VE error| %.0f; on top as the server had it %.0f%% of ticks'):format(
            s.medianCe / n, s.medianVe / n, 100 * s.topMedian / s.ticks));
    end

    print('\nplayers: the Enmity the server applied (value: ticks) against the filter\'s last posterior');
    local ids = {};
    for id in pairs(truth) do
        ids[#ids + 1] = id;
    end
    table.sort(ids);
    local believed = {};
    if posterior ~= nil then
        for _, p in ipairs(posterior.players) do
            believed[p.id] = p;
        end
    end
    for _, id in ipairs(ids) do
        local t = truth[id];
        local values = {};
        for v in pairs(t.mods) do
            values[#values + 1] = v;
        end
        table.sort(values);
        local parts = {};
        for _, v in ipairs(values) do
            parts[#parts + 1] = ('%+d: %d'):format(v, t.mods[v]);
        end
        local p = believed[id];
        local belief = p and ('centre %+.0f (sd %.0f)'):format(p.mean, p.sd) or 'not held';
        if p ~= nil then
            local classes = {};
            for class, c in pairs(p.classes) do
                classes[#classes + 1] = ('%s %+.0f'):format(class, p.mean + c.mean);
            end
            table.sort(classes);
            belief = belief .. ' ' .. table.concat(classes, ' ');
        end
        print(('  %-14s server %s | filter %s'):format(names[id] or t.name or id, table.concat(parts, ', '), belief));
    end
end

main(arg);

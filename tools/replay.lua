--[[
* Replays a session log's packets through the sim, with no filter, and
* counts how often the neutral replay's leader is whom the mob attacked.
* For trying a model change against real fights.
*
* Run from the repo root:
*   luajit tools/replay.lua <path/to/enmetry-*.jsonl> [--cap N]... [--mob <id>] [--assume Name=+100,Other=-50] [--filter N]
*       [--values lsb] [--no-refit] [--refit-scope list] [--refit-run N/P] [--show list,mob,fight,refit,...]
*
* --show prints the sim's log lines of those kinds as the replay writes
* them, scalar fields only, for watching a fight go by.
*
* Each --cap runs the whole log again under that cap; 10000 alone without
* any.  --mob narrows the count to one mob's attacks.  --assume replays with
* one particle holding the named players at those Enmity values, everyone
* else at zero, to ask whether gear like that would explain the fight.
* --filter runs the addon's own particle filter, N particles (1024 without),
* drawn from the job priors and refitting as it would in game, and reports
* how it did beside the neutral count; --no-refit holds it to re-anchoring
* alone, as it was before refits.  Only attacks on a
* clean list at the time count, as the sim judges them.  The world the sim
* asks about is rebuilt from the log's roster lines; distances come from the
* action lines, and anything the log lacks reads as unknown.
--]]

package.path = './addon/?.lua;./tools/?.lua;' .. package.path;

local filter = require('filter');
local json = require('json');
local levels = require('levels');
local packets = require('packets');
local priors = require('priors');
local sim = require('sim');
local tables = require('tables');

local MOB_BIT = 0x01000000;

local function hexToBytes(hex)
    return (hex:gsub('%x%x', function (x) return string.char(tonumber(x, 16)); end));
end

local function parseArgs(argv)
    local out = { caps = {}, mob = nil, path = nil, assume = nil, particles = nil };
    local i = 1;
    while i <= #argv do
        local a = argv[i];
        if a == '--cap' then
            out.caps[#out.caps + 1] = assert(tonumber(argv[i + 1]), '--cap needs a number');
            i = i + 2;
        elseif a == '--assume' then
            out.assume = out.assume or {};
            for name, value in argv[i + 1]:gmatch('(%a+)=([-+]?%d+)') do
                out.assume[name] = tonumber(value);
            end
            i = i + 2;
        elseif a == '--filter' then
            out.particles = tonumber(argv[i + 1]) or 1024;
            i = i + (tonumber(argv[i + 1]) and 2 or 1);
        elseif a == '--no-refit' then
            out.refit = false;
            i = i + 1;
        elseif a == '--values' then
            out.values = argv[i + 1];
            i = i + 2;
        elseif a == '--show' then
            out.show = {};
            for kind in argv[i + 1]:gmatch('[%w_]+') do
                out.show[kind] = true;
            end
            i = i + 2;
        elseif a == '--refit-scope' then
            out.refitScope = argv[i + 1];
            i = i + 2;
        elseif a == '--refit-run' then
            local count, below = argv[i + 1]:match('^(%d+)/([%d.]+)$');
            out.refitRun = { count = assert(tonumber(count), '--refit-run needs N/P'), below = tonumber(below) };
            i = i + 2;
        elseif a == '--mob' then
            out.mob = assert(tonumber(argv[i + 1]), '--mob needs an id');
            i = i + 2;
        else
            out.path = a;
            i = i + 1;
        end
    end
    if #out.caps == 0 then
        out.caps[1] = 10000;
    end
    return out;
end

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

-- The world as the log describes it, updated as the replay passes roster lines.
local function newWorld()
    local w = { ids = {}, maxHPs = {}, downs = {}, buffs = {}, states = {}, distances = {}, members = {} };
    function w:zone() return self.zoneId; end
    function w:roster(line)
        self.zoneId = line.zone or self.zoneId;
        self.members = {};
        for _, m in ipairs(line.members) do
            self.members[#self.members + 1] = m.id;
            self.ids[m.id] = {
                kind = 'alliance', name = m.name,
                member = { mainJob = m.mainJob, subJob = m.subJob, mainLevel = m.mainLevel, subLevel = m.subLevel, trust = m.trust },
            };
            self.maxHPs[m.id] = m.maxHP;
            self.downs[m.id] = m.down;
            self.buffs[m.id] = m.buffs;
        end
    end
    function w:name(id, name)
        if self.ids[id] == nil then
            self.ids[id] = { kind = id >= MOB_BIT and 'mob' or 'player', name = name };
        elseif name ~= nil and self.ids[id].name == nil then
            self.ids[id].name = name;
        end
    end
    function w:resolve(id)
        local r = self.ids[id];
        if r == nil and id >= MOB_BIT then
            r = { kind = 'mob' };
            self.ids[id] = r;
        end
        return r;
    end
    function w:maxHP(id) return self.maxHPs[id]; end
    function w:distance(a, b) return self.distances[a] or self.distances[b]; end
    function w:position() return nil; end
    function w:alliance() return self.members; end
    function w:hasBuff(id, status)
        local b = self.buffs[id];
        if b == nil then
            return nil;
        end
        return b[tostring(status)];
    end
    function w:downed(id) return self.downs[id]; end
    function w:wearing() return false; end
    function w:inCombat(id)
        local s = self.states[id];
        if s == nil then
            return nil;
        end
        return s;
    end
    function w:petOwner() return nil; end
    return w;
end

local function recorder(show)
    local r = { now = 0, cost = 0, targets = {}, observes = {} };
    function r:write(kind, fields)
        if show ~= nil and show[kind] then
            local parts = {};
            for key, value in pairs(fields) do
                if type(value) ~= 'table' then
                    parts[#parts + 1] = key .. '=' .. tostring(value);
                end
            end
            table.sort(parts);
            print(('  %10.1f %-14s %s'):format(self.now, kind, table.concat(parts, ' ')));
        end
        if kind == 'target' then
            fields.t = self.now;
            self.targets[#self.targets + 1] = fields;
        elseif kind == 'observe' then
            fields.t = self.now;
            self.observes[#self.observes + 1] = fields;
        end
    end
    function r:charge() end
    return r;
end

--[[
* One pass over the log under `cap`.
*
* @return {table} Every 'target' line the sim wrote, with the mob's names.
--]]
--[[
* With --assume, one particle whose Enmity for each named player is fixed at
* the value given, every class alike, and zero for everyone else: the sim
* replayed as if that were everyone's gear.
--]]
local function assumed(w, assume)
    local function exact(value)
        local p = { mean = value, sd = 0, classes = {} };
        for class = 0, priors.CLASSES - 1 do
            p.classes[class] = { mean = 0, sd = 0 };
        end
        return p;
    end
    return filter.new({
        max = 1, count = 1, jitter = 0,
        prior = function (id)
            local r = w.ids[id];
            return exact(r and r.name and assume[r.name] or 0);
        end,
    });
end

-- The addon's own filter, each player drawn from their main job's prior.
local function live(w, particles)
    math.randomseed(7);
    return filter.new({
        max = particles,
        prior = function (id)
            local r = w.ids[id];
            return priors.forJob(r and r.member and r.member.mainJob);
        end,
    });
end

local function replay(lines, cap, args)
    local w = newWorld();
    local log = recorder(args.show);
    local f = args.assume and assumed(w, args.assume) or args.particles and live(w, args.particles) or nil;
    local known = levels.new(nil, 'replay', tables.horizonlevels, tables.levelRange);
    local s = sim.new(w, {
        cap = cap, log = log, filter = f, values = args.values,
        refit = args.refit, refitScope = args.refitScope, refitRun = args.refitRun,
        levelRange = function (mob)
            local r = w:resolve(mob);
            return known:rangeFor(mob, w:zone(), r and r.name);
        end,
    });
    -- Names first: live, the world has a mob's name the moment its list
    -- opens, while the log's list line trails the packet that opened it.
    for _, v in ipairs(lines) do
        if v.k == 'list' and v.name ~= nil then
            w:name(v.mob, v.name);
        end
    end
    for _, v in ipairs(lines) do
        local k = v.k;
        log.now = v.t or log.now;
        if k == 'roster' then
            w:roster(v);
        elseif k == 'list' then
            w:name(v.mob, v.name);
        elseif k == 'level' then
            known:learn(v.mob, v.zone, v.name, v.level);
        elseif k == 'rest' and v.id ~= nil then
            s:observeRest(v.id, v.resting, v.t, { signet = v.signet, maxHP = v.maxHP });
        elseif k == 'action' then
            -- Distances for the packet that produced this line, which came just before.
            w.distances = {};
            for _, tg in ipairs(v.targets or {}) do
                if tg.distance ~= nil then
                    w.distances[tg.id] = tg.distance;
                end
            end
            if v.name ~= nil then
                w:name(v.actor, v.name);
            end
        elseif k == 'packet' and v.hex ~= nil and v.parsed ~= false then
            local data = hexToBytes(v.hex);
            local event = nil;
            if v.id == 0x028 then
                event = packets.parseAction(data);
            elseif v.id == 0x029 then
                event = packets.parseMessage(data);
            end
            if event ~= nil then
                s:observe(event, v.t);
            end
        elseif k == 'mob' then
            if v.dead then
                s:observeEntity(v.mob, 3, false, v.t);
                w.states[v.mob] = nil;
            elseif v.despawned then
                s:observeEntity(v.mob, nil, true, v.t);
                w.states[v.mob] = nil;
            elseif v.engaged ~= nil then
                w.states[v.mob] = v.engaged;
                s:observeEntity(v.mob, v.engaged and 1 or 0, false, v.t, v.hpp);
            end
        elseif k == 'zone' then
            s:clear();
        end
    end
    return log.targets, s, log.observes;
end

local function main(argv)
    local args = parseArgs(argv);
    assert(args.path, 'which log?');
    local lines = readLines(args.path);
    print(('%d lines'):format(#lines));
    for _, cap in ipairs(args.caps) do
        local targets, s, observes = replay(lines, cap, args);
        local judged, hits, byTarget = 0, 0, {};
        local misses = {};
        -- With a particle, the particle's own margin says whether it had the target ahead.
        local byTime = {};
        for _, o in ipairs(observes) do
            if o.used then
                byTime[o.t .. ':' .. o.mob .. ':' .. o.target] = o;
            end
        end
        for _, tg in ipairs(targets) do
            if tg.modelled and tg.clean and not tg.covered and (args.mob == nil or tg.mob == args.mob) and tg.margin ~= nil then
                judged = judged + 1;
                local hit = tg.leader == tg.target;
                local o = args.assume and byTime[tg.t .. ':' .. tg.mob .. ':' .. tg.target];
                if o ~= nil then
                    hit = o.best > 0 or (o.best == 0 and not tg.switch);
                    tg.margin = o.best;
                end
                if hit then
                    hits = hits + 1;
                else
                    misses[#misses + 1] = tg;
                end
                local name = s:name(tg.target) or tostring(tg.target);
                local row = byTarget[name] or { n = 0, hits = 0 };
                row.n, row.hits = row.n + 1, row.hits + (hit and 1 or 0);
                byTarget[name] = row;
            end
        end
        print(('\ncap %d%s: leader was the target in %d of %d clean attacks (%.0f%%)'):format(
            cap, args.assume and ' with the assumed Enmity' or '', hits, judged, judged > 0 and 100 * hits / judged or 0));
        if args.particles then
            local weighed, surprises, sum, low = 0, 0, 0, 0;
            for _, o in ipairs(observes) do
                if (o.used or o.surprised) and (args.mob == nil or o.mob == args.mob) then
                    weighed = weighed + 1;
                    sum = sum + (o.predicted or 0);
                    if o.surprised then
                        surprises = surprises + 1;
                    end
                    if (o.predicted or 0) < 0.5 then
                        low = low + 1;
                    end
                end
            end
            print(('  filter, %d particles: %d attacks weighed, the target given %.0f%% on average, %d under 50%%, %d surprises, %d refits'):format(
                s.filter.count, weighed, weighed > 0 and 100 * sum / weighed or 0, low, surprises, s.refits));
            for _, line in ipairs(s.calibration:readout()) do
                print('  ' .. line);
            end
            -- Where the filter ended up on everyone it holds: centre and spread.
            local held = {};
            for id in pairs(s.filter.players) do
                held[#held + 1] = id;
            end
            table.sort(held, function (a, b) return (s:name(a) or '') < (s:name(b) or ''); end);
            for _, id in ipairs(held) do
                local p = s.filter:posterior(id);
                if p ~= nil then
                    print(('  posterior %-14s centre %+5.1f sd %4.1f'):format(s:name(id) or tostring(id), p.mean, p.sd));
                end
            end
        end
        local names = {};
        for name in pairs(byTarget) do
            names[#names + 1] = name;
        end
        table.sort(names);
        for _, name in ipairs(names) do
            local row = byTarget[name];
            print(('  %-12s %3d attacks, leader %3d (%.0f%%)'):format(name, row.n, row.hits, 100 * row.hits / row.n));
        end
        table.sort(misses, function (a, b) return (a.margin or 0) < (b.margin or 0); end);
        for i = 1, math.min(8, #misses) do
            local m = misses[i];
            print(('  miss t=%.1f %s hit %s, leader %s, margin %d'):format(
                m.t or 0, s:name(m.mob) or m.mob, s:name(m.target) or m.target, s:name(m.leader) or tostring(m.leader), m.margin));
        end
    end
end

main(arg);

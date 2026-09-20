addon.name    = 'enmetry';
addon.author  = 'Hanayaka';
addon.version = '1.0.0';
addon.desc    = 'Passive enmity tracker.';

require('common');

-- Rewritten by tools/deploy.py with the deployed commit; nil from the source tree.
local build = nil;
do
    local ok, stamped = pcall(require, 'build');
    if ok and type(stamped) == 'string' then
        build = stamped;
    end
end

local chat     = require('chat');
local bars     = require('bars');
local canvas   = require('canvas');
local commands = require('commands');
local feed     = require('feed');
local filter   = require('filter');
local focus    = require('focus');
local levels   = require('levels');
local log      = require('log');
local options  = require('options');
local packets  = require('packets');
local priors   = require('priors');
local profiles = require('profiles');
local research = require('research');
local sim      = require('sim');
local store    = require('store');
local tables   = require('tables');
local world    = require('world');

local ffi = require('ffi');

-- os.clock is millisecond-coarse on Windows and ashita.time.qpc allocates a table per call.
ffi.cdef([[
    typedef struct { uint32_t low; uint32_t high; } enmetry_counter;
    int QueryPerformanceCounter(enmetry_counter* count);
    int QueryPerformanceFrequency(enmetry_counter* frequency);
]]);
-- Read as two 32-bit halves: an int64 would be boxed on every read.
local counter = ffi.new('enmetry_counter');
ffi.C.QueryPerformanceFrequency(counter);
local COUNTER_PERIOD = 1 / (counter.high * 4294967296 + counter.low);

local function preciseClock()
    ffi.C.QueryPerformanceCounter(counter);
    return (counter.high * 4294967296 + counter.low) * COUNTER_PERIOD;
end

local ROSTER_INTERVAL = 0.5;
local FEED_CAPACITY = 64;
local BAR_ROWS = world.ALLIANCE_SLOTS;

local PACKET_ZONE_IN = 0x00A;
local PACKET_CHAR_UPDATE = 0x00D;
local PACKET_ENTITY_UPDATE = 0x00E;
local PACKET_WIDESCAN = 0x0F4;

local LOG_FLUSH = 1;
local LOG_SNAPSHOT = 1;
local LOG_POSTERIOR = 60;
local LOG_PERF = 10;

local ERROR_REPEAT = 100;
local ERROR_KINDS = 64;
local LOG_KEEP = 50;

-- Signature for the interface-hidden flag, as other addons read it.
local INTERFACE_HIDDEN = ashita.memory.find('FFXiMain.dll', 0, '8B4424046A016A0050B9????????E8????????F6D81BC040C3', 0, 0);

local function interfaceHidden()
    if INTERFACE_HIDDEN == 0 then
        return false;
    end
    local ptr = ashita.memory.read_uint32(INTERFACE_HIDDEN + 10);
    return ptr ~= 0 and ashita.memory.read_uint8(ptr + 0xB4) == 1;
end

local configDir = ('%sconfig\\addons\\%s\\'):fmt(AshitaCore:GetInstallPath(), addon.name);
local configFile = configDir .. 'settings.lua';
local profilesFile = configDir .. 'profiles.lua';
local levelsFile = configDir .. 'levels.lua';
local gapsFile = configDir .. 'gaps.log';
local logsDir = configDir .. 'logs\\';
local researchFile = configDir .. 'research.jsonl';
local posteriorFile = configDir .. 'research.lua';
local stateFile = configDir .. 'state.lua';

local RESTORE_WITHIN = 120;
local STATE_VERSION = 1;

local state = {
    settings = nil,
    panel = options.panel(),
    seed = nil,
    server = nil,
    world = nil,
    feed = feed.new(FEED_CAPACITY),
    filter = nil,
    profiles = nil,
    sim = nil,
    focus = focus.new(),
    bars = bars.new(BAR_ROWS),
    lastRoster = 0,
    wipes = 0,
    gaps = 0,
    log = nil,
    logFile = nil,
    logHandle = nil,
    logged = nil,
    research = nil,
    researchHandle = nil,
};

local function freshLogged()
    return {
        flush = 0, snapshot = 0, posterior = 0, roster = nil, particles = nil,
        perf = { since = nil, frames = 0, busy = 0, total = 0, peak = 0, logCost = 0 },
        errors = {},
        errorKinds = 0,
        players = {},
    };
end
state.logged = freshLogged();

local function nameOf(id)
    return state.sim:name(id);
end

local function ensureConfigDir()
    if not ashita.fs.exists(configDir) then
        ashita.fs.create_dir(configDir);
    end
end

local function save()
    if state.settings == nil then
        return;
    end
    ensureConfigDir();
    state.settings.x, state.settings.y = canvas.x, canvas.y;
    store.write(configFile, state.settings);
end

local function saveProfiles()
    if state.profiles == nil then
        return;
    end
    ensureConfigDir();
    state.profiles:save(state.filter);
end

local function priorOf(id)
    local member = state.world:allianceMember(id);
    local prior = state.profiles:prior(id, member);
    if state.log ~= nil then
        local since = preciseClock();
        local job = member and member.mainJob and priors.forJob(member.mainJob);
        state.log:write('prior', {
            id = id, name = member and member.name or state.sim and state.sim:name(id), mainJob = member and member.mainJob,
            trust = member and member.trust, mean = prior.mean, sd = prior.sd,
            jobMean = job and job.mean, jobSd = job and job.sd,
        });
        state.log:charge(preciseClock() - since);
    end
    return prior;
end

local function retire(id)
    if state.log ~= nil then
        state.log:write('released', { id = id, name = state.sim:name(id), reason = 'slot' });
    end
    state.profiles:retire(id, state.filter);
end

local function pruneLogs()
    local names = ashita.fs.get_directory(logsDir, '.*');
    if names == nil then
        return;
    end
    local logs = {};
    for _, name in ipairs(names) do
        if name:match('^enmetry%-%d+%-%d+.*%.jsonl$') then
            logs[#logs + 1] = name;
        end
    end
    table.sort(logs);
    for i = 1, #logs - (LOG_KEEP - 1) do
        ashita.fs.remove(logsDir .. logs[i]);
    end
end

local function openLog()
    ensureConfigDir();
    if not ashita.fs.exists(logsDir) then
        ashita.fs.create_dir(logsDir);
    end
    pruneLogs();
    local stem = logsDir .. os.date('enmetry-%Y%m%d-%H%M%S');
    local path, n = stem .. '.jsonl', 1;
    while ashita.fs.exists(path) do
        n = n + 1;
        path = ('%s-%d.jsonl'):fmt(stem, n);
    end
    local fh = io.open(path, 'ab');
    if fh == nil then
        print(chat.header(addon.name):append(chat.message('session log off -- cannot write ' .. path)));
        return;
    end
    state.logFile, state.logHandle = path, fh;
    state.log = log.new({
        sink = function (text)
            fh:write(text);
            fh:flush();
        end,
        clock = function () return os.clock(); end,
    });
end

local function logSession(server)
    local party = state.world.party;
    state.log:write('session', {
        logVersion = log.VERSION, version = addon.version, build = build, date = os.date('%Y-%m-%d %H:%M:%S'), wall = os.time(),
        server = server, character = party:GetMemberName(0), settings = state.settings, seed = state.seed,
        particles = state.filter and state.filter.count or 0, budgetMs = filter.BUDGET * 1000,
        surprise = filter.SURPRISE, scale = filter.SCALE, floor = filter.FLOOR,
    });
    state.log:flush();
end

local logPosteriors;

local function closeLog()
    if state.log == nil then
        return;
    end
    logPosteriors();
    state.log:write('end', { lines = state.log.lines + 1 });
    state.log:flush();
    state.logHandle:close();
    state.log, state.logHandle = nil, nil;
end

local function openResearch(server)
    ensureConfigDir();
    local fh = io.open(researchFile, 'ab');
    if fh == nil then
        print(chat.header(addon.name):append(chat.message('research log off -- cannot write ' .. researchFile)));
        return;
    end
    state.researchHandle = fh;
    state.research = research.new({
        sink = function (text)
            fh:write(text);
            fh:flush();
        end,
        clock = function () return os.clock(); end,
        live = { shadowAbsorb = state.settings.shadowAbsorb == 'era' and 'era' or 'lsb' },
    });
    state.research:session({
        version = addon.version, build = build, date = os.date('%Y-%m-%d %H:%M:%S'), wall = os.time(), server = server,
        character = state.world.party:GetMemberName(0), rule = state.settings.shadowAbsorb,
    });
end

local function closeResearch()
    if state.research == nil then
        return;
    end
    state.research:flush();
    state.researchHandle:close();
    state.research, state.researchHandle = nil, nil;
end

local function saveState(server)
    if state.world == nil then
        return;
    end
    ensureConfigDir();
    if state.sim == nil or next(state.sim.lists) == nil then
        os.remove(stateFile);
        return;
    end
    local party = state.world.party;
    store.write(stateFile, {
        version = STATE_VERSION, wall = os.time(), server = server, character = party:GetMemberName(0),
        zone = party:GetMemberZone(0), sim = state.sim:export(),
    });
end

local function restore(server, now)
    local saved = store.read(stateFile);
    os.remove(stateFile);
    if saved == nil then
        return nil, 'missing';
    end
    if saved.version ~= STATE_VERSION or type(saved.sim) ~= 'table' then
        return nil, 'version';
    end
    local party = state.world.party;
    local elapsed = os.time() - (tonumber(saved.wall) or 0);
    if elapsed < 0 or elapsed > RESTORE_WITHIN then
        return nil, 'stale';
    elseif saved.server ~= server then
        return nil, 'server';
    elseif saved.character ~= party:GetMemberName(0) then
        return nil, 'character';
    elseif saved.zone ~= party:GetMemberZone(0) then
        return nil, 'zone';
    end
    local count = state.sim:import(saved.sim, now, elapsed);
    if count == 0 then
        return nil, 'empty';
    end
    return count, elapsed;
end

local function hex(data)
    return ('%02x'):rep(#data):format(data:byte(1, -1));
end

local function logRoster()
    local w = state.world;
    local members, parts = {}, {};
    local zone = w.party:GetMemberZone(0);
    local statuses = {};
    for status in pairs(state.sim.buffs.byStatus) do
        statuses[#statuses + 1] = status;
    end
    table.sort(statuses);
    for slot = 0, world.ALLIANCE_SLOTS - 1 do
        local m = w:member(slot);
        if m ~= nil then
            local down, maxHP = w:downed(m.serverId), w:maxHP(m.serverId);
            local buffs, up = nil, {};
            for _, status in ipairs(statuses) do
                local reading = w:hasBuff(m.serverId, status);
                if reading ~= nil then
                    buffs = buffs or {};
                    buffs[tostring(status)] = reading;
                    up[#up + 1] = reading and status or nil;
                end
            end
            members[#members + 1] = {
                slot = slot, id = m.serverId, name = m.name, mainJob = m.mainJob, subJob = m.subJob,
                mainLevel = m.mainLevel, subLevel = m.subLevel, trust = m.trust, down = down,
                maxHP = maxHP, buffs = buffs,
            };
            parts[#parts + 1] = ('%d:%d:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s'):fmt(slot, m.serverId, m.name,
                tostring(m.mainJob), tostring(m.subJob), tostring(m.mainLevel), tostring(m.subLevel), tostring(m.trust),
                tostring(down), tostring(maxHP), tostring(buffs ~= nil), table.concat(up, ','));
        end
    end
    local key = zone .. '|' .. table.concat(parts, '|');
    if key ~= state.logged.roster then
        state.logged.roster = key;
        state.log:write('roster', { zone = zone, self = w.selfId, members = members });
    end
end

local function logReleased()
    local f, logged = state.filter, state.logged;
    if f == nil then
        return;
    end
    for id in pairs(logged.players) do
        if f.players[id] == nil then
            state.log:write('released', { id = id, name = state.sim:name(id), reason = 'job' });
        end
    end
    local held = {};
    for id in pairs(f.players) do
        held[id] = true;
    end
    logged.players = held;
end

local function logSnapshot(now, focused)
    local sim, f = state.sim, state.filter;
    local mobs = {};
    for _, mob in ipairs(sim:mobs()) do
        local list, view, track = sim:list(mob), sim:view(mob), sim:track(mob);
        local rows = {};
        for i = 1, list:count() do
            local id = list:idAt(i);
            local ce, ve, active = list:get(id);
            local medianCe, medianVe = view:get(id);
            local band = nil;
            if view.band ~= nil then
                band = { view:band(id) };
            end
            rows[#rows + 1] = { id, ce, ve, medianCe, medianVe, active, band };
        end
        mobs[#mobs + 1] = {
            mob = mob, name = sim:name(mob), clean = track.clean, anchored = track.anchored,
            holder = track.holder, holderModelled = track.holderModelled, acting = track.acting, rows = rows,
        };
    end
    if #mobs > 0 then
        state.log:write('snapshot', {
            focus = focused, target = state.world:target(), particles = f and f.count or 0, ess = f and f:ess(),
            mobs = mobs,
        });
    end
end

function logPosteriors()
    local f = state.filter;
    if state.log == nil or f == nil then
        return;
    end
    local players = {};
    for id in pairs(f.players) do
        local p = f:posterior(id);
        local m = state.world:allianceMember(id);
        local classes = {};
        for class, c in pairs(p.classes) do
            classes[filter.CLASS_NAMES[class]] = { mean = c.mean, sd = c.sd };
        end
        local muted = nil;
        if p.muted[0] < 1 then
            muted = {};
            for rank = 0, priors.RANKS do
                muted[rank + 1] = p.muted[rank];
            end
        end
        players[#players + 1] = {
            id = id, name = m and m.name or state.sim:name(id), mainJob = m and m.mainJob,
            mean = p.mean, sd = p.sd, classes = classes, muted = muted,
        };
    end
    state.log:write('posterior', { particles = f.count, resamples = f.resamples, players = players });
end

local function logFrame(now, spent)
    local perf, logged = state.logged.perf, state.logged;
    perf.since = perf.since or now;
    perf.frames = perf.frames + 1;
    if spent > 0 then
        perf.busy, perf.total, perf.peak = perf.busy + 1, perf.total + spent, math.max(perf.peak, spent);
    end
    if now - perf.since >= LOG_PERF then
        state.log:write('perf', {
            seconds = now - perf.since, frames = perf.frames, busy = perf.busy, peakMs = perf.peak * 1000,
            meanMs = perf.busy > 0 and perf.total / perf.busy * 1000 or 0, budgetMs = filter.BUDGET * 1000,
            logMs = (state.log.cost - perf.logCost) * 1000, particles = state.filter and state.filter.count or 0,
        });
        perf.since, perf.frames, perf.busy, perf.total, perf.peak = now, 0, 0, 0, 0;
        perf.logCost = state.log.cost;
    end
    local count = state.filter and state.filter.count;
    if count ~= logged.particles then
        if logged.particles ~= nil then
            state.log:write('particles', { from = logged.particles, count = count });
        end
        logged.particles = count;
    end
end

local function guarded(where, fn)
    return function (...)
        local ok, err = xpcall(fn, debug.traceback, ...);
        if not ok then
            if state.log ~= nil then
                local logged = state.logged;
                if logged.errors[err] == nil then
                    if logged.errorKinds >= ERROR_KINDS then
                        logged.errors, logged.errorKinds = {}, 0;
                    end
                    logged.errorKinds = logged.errorKinds + 1;
                end
                local count = (logged.errors[err] or 0) + 1;
                logged.errors[err] = count;
                if count == 1 or count % ERROR_REPEAT == 0 then
                    state.log:write('error', { where = where, message = err, count = count });
                    state.log:flush();
                end
            end
            error(err, 0);
        end
    end;
end

-- Render flags as in era-plus-sniffer: 0x200 is set once the player is drawn, 0x4000 while hidden.
local function inWorld()
    local party, entity = state.world.party, state.world.entity;
    if party:GetMemberIsActive(0) == 0 or party:GetMemberServerId(0) == 0 then
        return false;
    end
    local index = party:GetMemberTargetIndex(0);
    if index == 0 then
        return false;
    end
    local flags = entity:GetRenderFlags0(index);
    return bit.band(flags, 0x200) == 0x200 and bit.band(flags, 0x4000) == 0;
end

local function apply(key)
    local s = state.settings;
    -- Before the change, so turning the log off is the last thing it hears.
    if state.log ~= nil and (key == 'log' or key == 'research' or key == 'shadowAbsorb' or key == 'values') then
        state.log:write('setting', { key = key, value = s[key] });
    end
    if key == 'shadowAbsorb' then
        state.sim:setShadowRule(s.shadowAbsorb);
    elseif key == 'values' then
        state.sim:setValues(s.values);
    elseif key == 'particles' then
        if state.filter ~= nil and s.particles > 0 then
            state.filter:setCeiling(s.particles);
        end
    elseif key == 'log' then
        if s.log and state.log == nil then
            state.logged = freshLogged();
            openLog();
            if state.log ~= nil then
                logSession(state.server);
            end
        elseif not s.log then
            closeLog();
        end
        state.sim:setLog(state.log);
    elseif key == 'research' then
        if s.research and state.research == nil then
            openResearch(state.server);
        elseif not s.research then
            closeResearch();
        end
        state.sim:setResearch(state.research);
    elseif key == 'ceColor' or key == 'veColor' or key == 'panelColor' then
        canvas.recolor();
    end
end

local function saveChanged(keys, count)
    save();
    if state.log == nil then
        return;
    end
    for i = 1, count do
        local key = keys[i];
        if key ~= 'log' and key ~= 'research' and key ~= 'shadowAbsorb' and key ~= 'values' then
            state.log:write('setting', { key = key, value = state.settings[key] });
        end
    end
end

local hooks = { change = apply, save = saveChanged };

ashita.events.register('load', 'enmetry_load', guarded('load', function ()
    state.settings = options.sanitize(store.load(configFile, options.defaults()));
    canvas.place(state.settings.x, state.settings.y);
    canvas.onMove = save;
    canvas.palette({ ce = state.settings.ceColor, ve = state.settings.veColor, panel = state.settings.panelColor });

    local memory = AshitaCore:GetMemoryManager();
    state.world = world.new(memory:GetParty(), memory:GetEntity(), memory:GetPlayer(), memory:GetTarget(),
        memory:GetInventory());
    state.world:refresh();
    local server = profiles.serverOf(AshitaCore:GetConfigurationManager():GetString('boot', 'ashita.boot', 'command'));
    state.profiles = profiles.new(profilesFile, server);
    state.profiles:load();
    state.levels = levels.new(levelsFile, server, tables.horizonlevels, tables.levelRange);
    state.levels:load();
    state.seed = os.time();
    math.randomseed(state.seed);
    state.logged = freshLogged();
    if state.settings.log then
        openLog();
    end
    local particles = state.settings.particles;
    state.filter = particles > 0 and filter.new({
        max = filter.MAX, count = particles, clock = preciseClock, prior = priorOf, retire = retire,
    }) or nil;
    if state.filter ~= nil then
        state.filter:setCeiling(particles);
    end
    if state.log ~= nil then
        logSession(server);
    end
    if state.settings.research then
        openResearch(server);
    end
    state.sim = sim.new(state.world, {
        shadowRule = state.settings.shadowAbsorb, values = state.settings.values,
        filter = state.filter, log = state.log, research = state.research,
        levelRange = function (mob)
            local r = state.world:resolve(mob);
            return state.levels:rangeFor(mob, state.world:zone(), r and r.name);
        end,
    });
    state.wipes = 0;
    state.gaps = 0;
    state.resting = {};
    state.server = server;
    local restored, elapsed = restore(server, os.clock());
    if restored ~= nil then
        state.wipes = state.sim.wipes;
        print(chat.header(addon.name):append(chat.message(
            ('picked up %d hate list%s from %ds ago'):fmt(restored, restored == 1 and '' or 's', elapsed))));
    elseif elapsed ~= 'missing' and state.log ~= nil then
        state.log:write('restore', { failed = elapsed });
    end
end));

ashita.events.register('unload', 'enmetry_unload', guarded('unload', function ()
    save();
    saveProfiles();
    if state.levels ~= nil then
        state.levels:save();
    end
    saveState(state.server);
    closeLog();
    closeResearch();
end));

local function learnLevel(mob, level, source, name)
    local r = mob and state.world:resolve(mob);
    name = name or (r and r.name);
    if name == '' then
        name = nil;
    end
    local zone = state.world:zone();
    if state.levels:learn(mob, zone, name, level) and state.log ~= nil then
        state.log:write('level', { mob = mob, name = name, zone = zone, level = level, source = source });
    end
end

ashita.events.register('command', 'enmetry_command', guarded('command', function (e)
    local out = commands.handle(e.command, {
        version = addon.version,
        settings = state.settings,
        panel = state.panel,
        feed = state.feed,
        filter = state.filter,
        world = state.world,
        focus = state.focus,
        sim = state.sim,
        nameOf = nameOf,
        save = save,
        profiles = state.profiles,
        saveProfiles = saveProfiles,
        log = state.log,
        logFile = state.logFile,
        research = state.research,
        researchFile = researchFile,
        researchPosterior = function () return store.read(posteriorFile); end,
    });
    if out == nil then
        return;
    end
    e.blocked = true;
    if state.log ~= nil then
        state.log:write('command', { text = e.command, out = out });
    end
    for _, line in ipairs(out) do
        print(chat.header(addon.name):append(chat.message(line)));
    end
end));

local function logGaps()
    ensureConfigDir();
    local fh = io.open(gapsFile, 'ab');
    local gaps = state.sim.gaps;
    for i = state.gaps + 1, #gaps do
        local gap = gaps[i];
        local name = gap.name or ('0x%08X'):fmt(gap.mob);
        print(chat.header(addon.name):append(chat.message(
            ('table gap -- %s used mobskill %d before a switch nothing explains'):fmt(name, gap.skill))));
        if fh ~= nil then
            fh:write(('%s\tmobskill %d\tzone %d\t%s\n'):fmt(os.date('%Y-%m-%d %H:%M:%S'), gap.skill, gap.zone, name));
        end
    end
    if fh ~= nil then
        fh:close();
    end
    state.gaps = #gaps;
end

ashita.events.register('packet_in', 'enmetry_packet_in', guarded('packet_in', function (e)
    if e.injected then
        return;
    end
    if e.id == PACKET_ZONE_IN then
        if state.log ~= nil then
            logPosteriors();
            state.log:write('zone', { hex = hex(e.data) });
        end
        state.sim:clear();
        state.levels:clear();
        state.resting = {};
        saveProfiles();
        state.levels:save();
        if state.log ~= nil then
            state.log:flush();
        end
        if state.research ~= nil then
            state.research:flush();
        end
        return;
    end
    if e.id == PACKET_CHAR_UPDATE then
        local id, hitbox = packets.parseCharUpdate(e.data);
        if id ~= nil then
            state.sim:observeHitbox(id, hitbox);
        end
        return;
    end
    if e.id == PACKET_ENTITY_UPDATE then
        local id, animation, despawned, hpp, hitbox = packets.parseEntityUpdate(e.data);
        if id ~= nil then
            state.sim:observeEntity(id, animation, despawned, os.clock(), hpp, hitbox);
        end
        return;
    end
    if e.id == PACKET_WIDESCAN then
        local index, level, name = packets.parseWidescan(e.data);
        if index ~= nil and name ~= '' then
            learnLevel(state.world:entityAt(index), level, 'widescan', name);
        end
        return;
    end

    local event = nil;
    if e.id == 0x028 then
        event = packets.parseAction(e.data);
    elseif e.id == 0x029 then
        event = packets.parseMessage(e.data);
    end
    if event == nil then
        if state.log ~= nil and (e.id == 0x028 or e.id == 0x029) then
            state.log:write('packet', { id = e.id, hex = hex(e.data), parsed = false });
        end
        return;
    end
    if event.kind == 'message' then
        local level = packets.checkedLevel(event);
        if level ~= nil then
            learnLevel(event.targetId, level, 'check');
        end
    end
    local text = feed.describe(event, state.world);
    state.feed:push(text, os.date('%H:%M:%S'));
    if state.log ~= nil then
        local since = preciseClock();
        state.log:write('packet', { id = e.id, hex = hex(e.data), text = text });
        state.log:charge(preciseClock() - since);
    end
    state.sim:observe(event, os.clock());
    if #state.sim.gaps ~= state.gaps then
        logGaps();
    end
end));

local function endFrame(now, focused)
    local spent = state.filter and state.filter.spent or 0;
    if state.filter ~= nil then
        state.filter:frame();
    end
    if state.log == nil then
        return;
    end
    logFrame(now, spent);
    local logged = state.logged;
    local spentBefore = state.filter and state.filter.spent;
    local since = preciseClock();
    if now - logged.snapshot >= LOG_SNAPSHOT then
        logged.snapshot = now;
        logSnapshot(now, focused);
    end
    if now - logged.posterior >= LOG_POSTERIOR then
        logged.posterior = now;
        logPosteriors();
    end
    state.log:charge(preciseClock() - since);
    if spentBefore ~= nil then
        state.filter.spent = spentBefore;
    end
end

ashita.events.register('d3d_present', 'enmetry_present', guarded('d3d_present', function ()
    local now = os.clock();
    if now - state.logged.flush >= LOG_FLUSH then
        state.logged.flush = now;
        if state.log ~= nil then
            state.log:flush();
        end
        if state.research ~= nil then
            state.research:flush();
        end
    end
    local hidden = interfaceHidden();
    if not hidden and state.settings ~= nil then
        options.render(state.panel, state.settings, hooks);
    end
    if not inWorld() then
        return;
    end

    if now - state.lastRoster >= ROSTER_INTERVAL then
        state.lastRoster = now;
        state.world:refresh();
        for _, id in ipairs(state.world:alliance()) do
            local resting = state.world:resting(id);
            if resting ~= nil and resting ~= (state.resting[id] == true) then
                state.resting[id] = resting;
                state.sim:observeRest(id, resting, now);
            end
        end
        if state.filter ~= nil then
            state.profiles:reconcile(state.world, state.filter);
        end
        if state.log ~= nil then
            logRoster();
            logReleased();
        end
    end
    state.sim:advance(now);
    if state.sim.wipes ~= state.wipes then
        state.wipes = state.sim.wipes;
        print(chat.header(addon.name):append(chat.message('wipe -- every hate list reset')));
    end

    local mob = state.focus:update(state.sim, state.world:target());
    local settings = state.settings;
    local debug = settings.debug;
    if mob == nil and not debug then
        endFrame(now, mob);
        return;
    end
    state.bars.limit, state.bars.me = settings.rows, state.world.selfId;
    canvas.rescale(settings.fontScale, settings.compact);
    bars.layout(state.bars, mob and state.sim:view(mob), nameOf, canvas.barWidth, mob and state.sim:track(mob));
    -- After the layout, whose medians count against this frame's budget.
    endFrame(now, mob);
    if hidden then
        return;
    end

    canvas.render(debug and state.feed or nil, mob and state.sim:name(mob), state.bars);
end));

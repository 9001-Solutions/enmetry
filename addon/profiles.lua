local priors = require('priors');
local store = require('store');

local profiles = {};
profiles.__index = profiles;

local CLASS_NAMES = {};
for name, class in pairs(priors.CLASS) do
    CLASS_NAMES[class] = name;
end

local PRUNE_AFTER_HALF_LIVES = 6;

local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge;
end

function profiles.new(path, server, clock)
    return setmetatable({
        path = path,
        server = server,
        clock = clock or os.time,
        data = {},
        drawn = {},
    }, profiles);
end

local function readNormal(v)
    if type(v) ~= 'table' or not finite(v.mean) or not finite(v.sd) or v.sd < 0 then
        return nil;
    end
    return { mean = v.mean, sd = v.sd };
end

local function readEntry(v, now)
    local centre = readNormal(v);
    if centre == nil or not finite(v.seen) then
        return nil;
    end
    local entry = { mean = centre.mean, sd = centre.sd, seen = math.floor(math.min(v.seen, now)), classes = {} };
    for class = 0, priors.CLASSES - 1 do
        local c = readNormal(v[CLASS_NAMES[class]]);
        if c == nil then
            return nil;
        end
        entry.classes[class] = c;
    end
    if v.muted ~= nil then
        if type(v.muted) ~= 'table' then
            return nil;
        end
        local muted, total = {}, 0;
        for rank = 0, priors.RANKS do
            local m = v.muted[rank + 1];
            if not finite(m) or m < 0 then
                return nil;
            end
            muted[rank], total = m, total + m;
        end
        if total <= 0 then
            return nil;
        end
        for rank = 0, priors.RANKS do
            muted[rank] = muted[rank] / total;
        end
        entry.muted = muted;
    end
    return entry;
end

function profiles:load()
    self.data = {};
    local loaded = store.read(self.path);
    if loaded == nil then
        return;
    end
    local now = self.clock();
    for server, characters in pairs(loaded) do
        if type(server) == 'string' and type(characters) == 'table' then
            for name, jobs in pairs(characters) do
                if type(name) == 'string' and type(jobs) == 'table' then
                    for job, v in pairs(jobs) do
                        local entry = type(job) == 'string' and readEntry(v, now);
                        if entry then
                            self.data[server] = self.data[server] or {};
                            self.data[server][name] = self.data[server][name] or {};
                            self.data[server][name][job] = entry;
                        end
                    end
                end
            end
        end
    end
end

function profiles:prior(id, member)
    if member == nil or member.name == nil or member.name == '' then
        return priors.NEUTRAL;
    elseif member.trust then
        return priors.TRUST;
    end
    self.drawn[id] = { name = member.name, job = member.mainJob, seen = self.clock() };
    local prior = priors.forJob(member.mainJob);
    local characters = self.data[self.server];
    local entry = member.mainJob and characters and characters[member.name] and characters[member.name][member.mainJob];
    if entry == nil then
        return prior;
    end
    return priors.fade(entry, prior, self.clock() - entry.seen);
end

local function record(self, id, f)
    local who = self.drawn[id];
    local posterior = f:posterior(id);
    if who == nil or who.job == nil or posterior == nil then
        return;
    end
    local characters = self.data[self.server] or {};
    self.data[self.server] = characters;
    characters[who.name] = characters[who.name] or {};
    posterior.seen = who.seen;
    characters[who.name][who.job] = posterior;
end

local function release(self, id, f)
    if f ~= nil then
        f:forget(id);
    end
    self.drawn[id] = nil;
end

function profiles:retire(id, f)
    record(self, id, f);
    self.drawn[id] = nil;
end

function profiles:reconcile(world, f)
    local now = nil;
    for id, who in pairs(self.drawn) do
        local member = world:allianceMember(id);
        if member ~= nil and member.mainJob ~= who.job then
            record(self, id, f);
            release(self, id, f);
        elseif member ~= nil then
            now = now or self.clock();
            who.seen = now;
        end
    end
end

function profiles:forget(name, f)
    local wanted, found = name:lower(), nil;
    local characters = self.data[self.server] or {};
    for kept in pairs(characters) do
        if kept:lower() == wanted then
            characters[kept], found = nil, kept;
        end
    end
    for id, who in pairs(self.drawn) do
        if who.name:lower() == wanted then
            release(self, id, f);
            found = found or who.name;
        end
    end
    return found;
end

function profiles:purge(f)
    local count = 0;
    for _, characters in pairs(self.data) do
        for _ in pairs(characters) do
            count = count + 1;
        end
    end
    local here, counted = self.data[self.server] or {}, {};
    for _, who in pairs(self.drawn) do
        if here[who.name] == nil and not counted[who.name] then
            counted[who.name], count = true, count + 1;
        end
    end
    self.data = {};
    for id in pairs(self.drawn) do
        release(self, id, f);
    end
    return count;
end

function profiles.serverOf(command)
    local host = command and command:match('%-%-server[=%s]+([^%s]+)');
    return host and host:lower() or 'default';
end

local function sortedKeys(t)
    local keys = {};
    for k in pairs(t) do
        keys[#keys + 1] = k;
    end
    table.sort(keys);
    return keys;
end

local function normal(v)
    return ('mean = %.2f, sd = %.2f'):format(v.mean, v.sd);
end

function profiles:save(f)
    if f ~= nil then
        for id in pairs(self.drawn) do
            record(self, id, f);
        end
    end
    local now = self.clock();
    for server, characters in pairs(self.data) do
        for name, jobs in pairs(characters) do
            for job, entry in pairs(jobs) do
                if now - entry.seen > PRUNE_AFTER_HALF_LIVES * priors.HALF_LIFE then
                    jobs[job] = nil;
                end
            end
            if next(jobs) == nil then
                characters[name] = nil;
            end
        end
        if next(characters) == nil then
            self.data[server] = nil;
        end
    end

    local lines = { 'return {' };
    for _, server in ipairs(sortedKeys(self.data)) do
        lines[#lines + 1] = ('    [%q] = {'):format(server);
        local characters = self.data[server];
        for _, name in ipairs(sortedKeys(characters)) do
            lines[#lines + 1] = ('        [%q] = {'):format(name);
            local jobs = characters[name];
            for _, job in ipairs(sortedKeys(jobs)) do
                local entry = jobs[job];
                lines[#lines + 1] = ('            [%q] = {'):format(job);
                lines[#lines + 1] = ('                seen = %d, %s,'):format(entry.seen, normal(entry));
                for class = 0, priors.CLASSES - 1 do
                    lines[#lines + 1] = ('                %s = { %s },'):format(CLASS_NAMES[class],
                        normal(entry.classes[class]));
                end
                if entry.muted ~= nil and priors.forJob(job).muted[0] < 1 then
                    local ranks = {};
                    for rank = 0, priors.RANKS do
                        ranks[#ranks + 1] = ('%.3f'):format(entry.muted[rank]);
                    end
                    lines[#lines + 1] = ('                muted = { %s },'):format(table.concat(ranks, ', '));
                end
                lines[#lines + 1] = '            },';
            end
            lines[#lines + 1] = '        },';
        end
        lines[#lines + 1] = '    },';
    end
    lines[#lines + 1] = '}\n';

    local fh = io.open(self.path, 'wb');
    if fh == nil then
        return false;
    end
    fh:write(table.concat(lines, '\n'));
    fh:close();
    return true;
end

return profiles;

local store = require('store');

local levels = {};
levels.__index = levels;

local function plausible(level)
    return type(level) == 'number' and level == math.floor(level) and level > 0 and level <= 200;
end

function levels.new(path, server, horizon, fallback)
    return setmetatable({
        path = path,
        server = server,
        horizon = horizon or {},
        fallback = fallback or function () return nil; end,
        seen = {},
        exact = {},
        dirty = false,
    }, levels);
end

local function sane(seen)
    if type(seen) ~= 'table' then
        return {};
    end
    local out = {};
    for server, zones in pairs(seen) do
        if type(server) == 'string' and type(zones) == 'table' then
            out[server] = {};
            for zone, mobs in pairs(zones) do
                if type(zone) == 'number' and type(mobs) == 'table' then
                    out[server][zone] = {};
                    for name, list in pairs(mobs) do
                        if type(name) == 'string' and type(list) == 'table' then
                            local kept = {};
                            for _, level in ipairs(list) do
                                if plausible(level) then
                                    kept[#kept + 1] = level;
                                end
                            end
                            table.sort(kept);
                            if #kept > 0 then
                                out[server][zone][name] = kept;
                            end
                        end
                    end
                end
            end
        end
    end
    return out;
end

function levels:load()
    self.seen = sane(store.read(self.path));
    self.dirty = false;
end

function levels:save()
    if not self.dirty then
        return false;
    end
    if store.write(self.path, self.seen) then
        self.dirty = false;
        return true;
    end
    return false;
end

local function insertSorted(list, level)
    for i, v in ipairs(list) do
        if v == level then
            return false;
        elseif v > level then
            table.insert(list, i, level);
            return true;
        end
    end
    list[#list + 1] = level;
    return true;
end

function levels:learn(serverId, zone, name, level)
    if not plausible(level) then
        return false;
    end
    local new = false;
    if serverId ~= nil and serverId ~= 0 and self.exact[serverId] ~= level then
        self.exact[serverId] = level;
        new = true;
    end
    if zone ~= nil and zone ~= 0 and name ~= nil and name ~= '' then
        local zones = self.seen[self.server] or {};
        self.seen[self.server] = zones;
        local mobs = zones[zone] or {};
        zones[zone] = mobs;
        local list = mobs[name] or {};
        mobs[name] = list;
        if insertSorted(list, level) then
            self.dirty = true;
            new = true;
        end
    end
    return new;
end

function levels:highestSeen(zone, name)
    local zones = self.seen[self.server];
    local mobs = zones and zones[zone];
    local list = mobs and mobs[name];
    return list and list[#list] or nil;
end

function levels:rangeFor(serverId, zone, name)
    local exact = serverId and self.exact[serverId];
    if exact ~= nil then
        return exact, exact, 'stated';
    end
    if zone ~= nil and name ~= nil then
        local seen = self:highestSeen(zone, name);
        if seen ~= nil then
            return seen, seen, 'seen';
        end
        local mobs = self.horizon[zone];
        local range = mobs and mobs[name];
        if range ~= nil then
            return range[1], range[2], 'horizon';
        end
    end
    local lo, hi = self.fallback(serverId);
    if lo ~= nil then
        return lo, hi, 'table';
    end
    return nil;
end

function levels:clear()
    self.exact = {};
end

return levels;

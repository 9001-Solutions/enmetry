--[[
* Mob level ranges from LandSandBoat's per-zone mobs.yaml.
*
* Spawns are keyed by server id, which already encodes the zone:
* 0x01000000 | zone << 12 | index.  Only the spawns: section is read, and
* only the level at its fixed four-space indent, so template stats and
* per-spawn attribute overrides deeper down can't be mistaken for it.
* Spawns without a level are script-driven placeholders and are skipped.
--]]

local moblevels = {};

--[[
* @param {string} text - One zone's mobs.yaml.
* @return {table, table, number} Sequences of { id, min, max } in file order:
*   the spawns, and those rejected for a zero or inverted range; then how
*   many spawns had no level at all.
--]]
function moblevels.spawns(text)
    local out, invalid, keys = {}, {}, 0;
    local inSpawns, id = false, nil;
    for line in (text .. '\n'):gmatch('(.-)\r?\n') do
        if line:match('^%S') then
            inSpawns = line:match('^spawns:') ~= nil;
            id = nil;
        elseif inSpawns then
            local key = line:match('^  (%d+):');
            if key ~= nil then
                id = tonumber(key);
                keys = keys + 1;
            elseif id ~= nil then
                local lo, hi = line:match('^    level:%s*%[%s*(%d+)%s*,%s*(%d+)%s*%]');
                if lo ~= nil then
                    local s = { id = id, min = tonumber(lo), max = tonumber(hi) };
                    local list = (s.min >= 1 and s.max >= s.min) and out or invalid;
                    list[#list + 1] = s;
                    id = nil;
                end
            end
        end
    end
    return out, invalid, keys - #out - #invalid;
end

--[[
* The zone a server id belongs to.
--]]
function moblevels.zone(id)
    return math.floor(id / 4096) % 4096;
end

--[[
* @param {table} spawns - { id, min, max } from any number of zones.
* @return {table} [zone] = sequence of { firstIndex, lastIndex, min, max },
*   sorted by index, one run per stretch of consecutive indices whose ranges
*   are identical.
--]]
function moblevels.runs(spawns)
    local sorted = {};
    for i, s in ipairs(spawns) do
        sorted[i] = s;
    end
    table.sort(sorted, function (a, b) return a.id < b.id; end);

    local zones = {};
    for _, s in ipairs(sorted) do
        local zone, index = moblevels.zone(s.id), s.id % 4096;
        local runs = zones[zone];
        if runs == nil then
            runs = {};
            zones[zone] = runs;
        end
        local last = runs[#runs];
        if last ~= nil and last[2] + 1 == index and last[3] == s.min and last[4] == s.max then
            last[2] = index;
        else
            runs[#runs + 1] = { index, index, s.min, s.max };
        end
    end
    return zones;
end

return moblevels;

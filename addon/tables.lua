local mobskills = require('data.mobskills');

local tables = {
    actions = require('data.actions'),
    mobskills = mobskills.skills,
    scriptedMobs = mobskills.mobs,
    moblevels = require('data.moblevels'),
    horizonlevels = require('data.horizonlevels'),
    regions = require('data.regions'),
    overlays = require('data.overlays'),
};

local MOB_BASE = 0x01000000;

function tables.levelRange(serverId)
    if serverId < MOB_BASE then
        return;
    end
    local rest = serverId - MOB_BASE;
    local runs = tables.moblevels[math.floor(rest / 4096)];
    if runs == nil then
        return;
    end
    local index = rest % 4096;

    -- Runs of four: first, last, min, max.
    local lo, hi = 0, #runs / 4 - 1;
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2);
        local at = mid * 4;
        if index < runs[at + 1] then
            hi = mid - 1;
        elseif index > runs[at + 2] then
            lo = mid + 1;
        else
            return runs[at + 3], runs[at + 4];
        end
    end
end

return tables;

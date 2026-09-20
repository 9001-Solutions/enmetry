local focus = {};
focus.__index = focus;

function focus.new()
    return setmetatable({
        mob = nil,
        pinned = nil,
    }, focus);
end

local function busiest(sim)
    local best, bestTrack = nil, nil;
    for mob, track in pairs(sim.tracks) do
        if sim:engaged(mob) and (bestTrack == nil or track.acting > bestTrack.acting
                or (track.acting == bestTrack.acting and track.lastAction > bestTrack.lastAction)) then
            best, bestTrack = mob, track;
        end
    end
    return best;
end

function focus:update(sim, target)
    if self.pinned ~= nil and not sim:engaged(self.pinned) then
        self.pinned = nil;
    end
    if self.pinned ~= nil then
        self.mob = self.pinned;
    elseif target ~= nil and sim:engaged(target) then
        self.mob = target;
    else
        self.mob = busiest(sim);
    end
    return self.mob;
end

function focus:pin()
    self.pinned = self.mob;
    return self.pinned;
end

function focus:unpin()
    local was = self.pinned;
    self.pinned = nil;
    return was;
end

return focus;

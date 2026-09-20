local calibration = {};
calibration.__index = calibration;

-- chances is 0-indexed cdata.
function calibration.credit(chances, n, at, level)
    local p = chances[at];
    local above, same, top = 0, 0, 0;
    for k = 0, n - 1 do
        local c = chances[k];
        if c > p then
            above = above + c;
        elseif c == p then
            same = same + c;
        end
        if c > top then
            top = c;
        end
    end
    if same <= 0 then
        return 0, top;
    end
    return math.max(0, math.min(1, (level - above) / same)), top;
end

function calibration.new(level)
    return setmetatable({
        level = level,
        attacks = 0,
        credit = 0,
        contested = 0,
        contestedCredit = 0,
    }, calibration);
end

function calibration:score(chances, n, at)
    local credit, top = calibration.credit(chances, n, at, self.level);
    local contested = top < self.level;
    self.attacks, self.credit = self.attacks + 1, self.credit + credit;
    if contested then
        self.contested, self.contestedCredit = self.contested + 1, self.contestedCredit + credit;
    end
    return credit, contested;
end

function calibration:coverage()
    if self.attacks == 0 then
        return;
    end
    return self.credit / self.attacks, self.contested > 0 and self.contestedCredit / self.contested or nil;
end

local function percent(x)
    return math.floor(x * 100 + 0.5);
end

function calibration:readout()
    local overall, contested = self:coverage();
    if overall == nil then
        return { 'calibration: nothing scored yet this session' };
    end
    local level = percent(self.level);
    return {
        ('calibration: %d%% of attacks inside the %d%% credible set of who holds hate, over %d'):format(
            percent(overall), level, self.attacks),
        contested == nil and 'contested: none yet'
            or ('contested: %d%% over %d, where nobody was %d%% likely to hold hate'):format(
                percent(contested), self.contested, level),
    };
end

return calibration;

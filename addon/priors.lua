local priors = {};

priors.CLASS = { melee = 0, weaponskill = 1, ability = 2, magic = 3, cure = 4, other = 5 };
priors.CLASSES = 6;

-- Muted Soul: Enmity -10 a merit rank while Souleater is up, on a DRK main; enmity_container.cpp CalculateEnmityBonus.
priors.RANKS = 5;
priors.RANK_STEP = 10;
-- A rank's remembered probability never falls below this, so a merit taken later can still be found.
priors.MIN_MASS = 0.02;

local function ranks(...)
    local out = {};
    for rank = 0, priors.RANKS do
        out[rank] = select(rank + 1, ...);
    end
    return out;
end

priors.NO_MERITS = ranks(1, 0, 0, 0, 0, 0);
priors.MUTED_SOUL = ranks(0.5, 0.05, 0.05, 0.05, 0.05, 0.3);
priors.ANY_RANK = ranks(1 / 6, 1 / 6, 1 / 6, 1 / 6, 1 / 6, 1 / 6);

local PLAYER_SPREAD = 20;
local CLASS_SPREAD = 10;

local function prior(mean, muted)
    local classes = {};
    for class = 0, priors.CLASSES - 1 do
        classes[class] = { mean = 0, sd = CLASS_SPREAD };
    end
    return { mean = mean, sd = PLAYER_SPREAD, classes = classes, muted = muted or priors.NO_MERITS };
end

priors.NEUTRAL = prior(0);

priors.TRUST = { mean = 0, sd = 0, classes = {}, muted = priors.NO_MERITS };
for class = 0, priors.CLASSES - 1 do
    priors.TRUST.classes[class] = { mean = 0, sd = 0 };
end

local CENTRES = {
    PLD = 20, NIN = 15, RUN = 20,
    WAR = 5, DRK = 0,
    WHM = -10, BLM = -10, SCH = -10,
    RDM = -5, BRD = -5, SMN = -5, GEO = -5,
};

local BY_JOB = {};
for job, centre in pairs(CENTRES) do
    BY_JOB[job] = prior(centre, job == 'DRK' and priors.MUTED_SOUL or nil);
end

priors.HALF_LIFE = 30 * 86400;

-- Below this, particles drawn from a remembered belief collapse and evidence can't move them.
priors.MIN_SPREAD = 2;

local function mix(remembered, prior, keep)
    local mean = keep * remembered.mean + (1 - keep) * prior.mean;
    local variance = keep * remembered.sd ^ 2 + (1 - keep) * prior.sd ^ 2
        + keep * (1 - keep) * (remembered.mean - prior.mean) ^ 2;
    return mean, math.max(priors.MIN_SPREAD, math.sqrt(variance));
end

function priors.mixRanks(remembered, prior, keep)
    local out, total = {}, 0;
    for rank = 0, priors.RANKS do
        out[rank] = keep * remembered[rank] + (1 - keep) * prior[rank];
        total = total + out[rank];
    end
    local room = 1 - (priors.RANKS + 1) * priors.MIN_MASS;
    for rank = 0, priors.RANKS do
        out[rank] = priors.MIN_MASS + room * out[rank] / total;
    end
    return out;
end

function priors.fade(remembered, prior, age)
    local keep = 0.5 ^ (math.max(0, age) / priors.HALF_LIFE);
    local out = { classes = {} };
    out.mean, out.sd = mix(remembered, prior, keep);
    for class = 0, priors.CLASSES - 1 do
        local c = {};
        c.mean, c.sd = mix(remembered.classes[class], prior.classes[class], keep);
        out.classes[class] = c;
    end
    local muted = prior.muted or priors.NO_MERITS;
    if remembered.muted == nil or muted[0] >= 1 then
        out.muted = muted;
    else
        out.muted = priors.mixRanks(remembered.muted, muted, keep);
    end
    return out;
end

function priors.forJob(job)
    return BY_JOB[job] or priors.NEUTRAL;
end

return priors;

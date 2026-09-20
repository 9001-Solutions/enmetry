--[[
* Priors: what a player's main job implies about their hidden Enmity, and a
* remembered posterior fading back to it.
*
* Run: luajit tests/test_priors.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local priors = require('priors');

local DAY = 86400;

-- A prior built from a centre and spreads, the class offsets as listed.
local function belief(mean, sd, offsets, classSd)
    local p = { mean = mean, sd = sd, classes = {} };
    for class = 0, priors.CLASSES - 1 do
        p.classes[class] = { mean = offsets and offsets[class + 1] or 0, sd = classSd };
    end
    return p;
end

t.test('tanks lean positive, mages negative, and damage dealers sit near zero', function ()
    local pld, nin, war = priors.forJob('PLD'), priors.forJob('NIN'), priors.forJob('WAR');
    local drk, thf = priors.forJob('DRK'), priors.forJob('THF');
    local whm, blm = priors.forJob('WHM'), priors.forJob('BLM');
    t.truthy(pld.mean >= 15 and nin.mean >= 10, ('tanks %g, %g'):format(pld.mean, nin.mean));
    t.truthy(whm.mean <= -5 and blm.mean <= -5, ('mages %g, %g'):format(whm.mean, blm.mean));
    t.truthy(math.abs(drk.mean) <= 5 and math.abs(thf.mean) <= 5 and math.abs(war.mean) <= 5, 'damage dealers');
    t.truthy(pld.mean > war.mean and war.mean > whm.mean, 'ordered');
    t.eq(priors.forJob(nil), priors.NEUTRAL, 'no job known');
    t.eq(priors.forJob('XYZ'), priors.NEUTRAL, 'a job with no prior');
    for _, p in ipairs({ pld, whm, drk }) do
        t.eq(#p.classes, priors.CLASSES - 1, 'a class for every action class');
        t.truthy(p.sd > 0 and p.classes[0].sd > 0, 'spread');
    end
end);

t.test('a remembered posterior fades back toward the job prior with time since last seen', function ()
    local job = priors.forJob('PLD');
    local stored = belief(45, 3, { 6, -2, 0, 0, -4, 0 }, 2);

    local fresh = priors.fade(stored, job, 0);
    t.eq({ fresh.mean, fresh.sd, fresh.classes[0].mean, fresh.classes[4].mean }, { 45, 3, 6, -4 }, 'just seen');

    local half = priors.fade(stored, job, priors.HALF_LIFE);
    t.truthy(math.abs(half.mean - (45 + 20) / 2) < 1e-9, ('a half-life brings it halfway: %g'):format(half.mean));
    t.truthy(math.abs(half.classes[0].mean - 3) < 1e-9, 'offsets too');
    t.truthy(half.sd > stored.sd and half.sd < job.sd + 25 / 2 + 1, ('spread widens: %g'):format(half.sd));
    t.truthy(half.classes[0].sd > stored.classes[0].sd and half.classes[0].sd <= job.classes[0].sd + 3,
        ('class spread widens: %g'):format(half.classes[0].sd));

    local later = priors.fade(stored, job, 2 * priors.HALF_LIFE);
    t.truthy(math.abs(later.mean - (20 + 25 / 4)) < 1e-9, ('two bring it three quarters: %g'):format(later.mean));
    local year = priors.fade(stored, job, 365 * DAY);
    t.truthy(math.abs(year.mean - 20) < 0.5 and math.abs(year.sd - job.sd) < 1, ('a year on it is the job\'s: %g, %g')
        :format(year.mean, year.sd));
    t.eq(priors.fade(stored, job, -DAY).mean, 45, 'a clock set back counts as just seen');
end);

t.test('a remembered spread never narrows to nothing', function ()
    local stored = belief(10, 0, nil, 0);
    local p = priors.fade(stored, priors.NEUTRAL, 0);
    t.truthy(p.sd >= priors.MIN_SPREAD and p.classes[3].sd >= priors.MIN_SPREAD, 'floored');
end);

t.test('a dark knight may have Muted Soul merits; nobody else can', function ()
    local drk, pld = priors.forJob('DRK'), priors.forJob('PLD');
    local total = 0;
    for rank = 0, priors.RANKS do
        total = total + drk.muted[rank];
    end
    t.truthy(math.abs(total - 1) < 1e-9, 'a distribution over the ranks');
    t.truthy(drk.muted[0] >= 0.4 and drk.muted[5] >= 0.2, 'most take none or all five');
    t.eq(pld.muted, priors.NO_MERITS);
    t.eq(priors.NEUTRAL.muted, priors.NO_MERITS);
    t.eq(priors.TRUST.muted, priors.NO_MERITS);
end);

t.test('a remembered Muted Soul belief fades toward the job prior and never rules a rank out', function ()
    local job = priors.forJob('DRK');
    local stored = belief(0, 5, nil, 2);
    stored.muted = { [0] = 0, 0, 0, 0, 0, 1 };
    local fresh = priors.fade(stored, job, 0);
    t.truthy(fresh.muted[5] > 0.85 and fresh.muted[0] >= priors.MIN_MASS,
        ('just seen: %g, %g'):format(fresh.muted[5], fresh.muted[0]));
    local half = priors.fade(stored, job, priors.HALF_LIFE);
    local room = 1 - (priors.RANKS + 1) * priors.MIN_MASS;
    t.truthy(math.abs(half.muted[5] - (priors.MIN_MASS + room * (1 + job.muted[5]) / 2)) < 1e-9,
        ('halfway: %g'):format(half.muted[5]));
    local none = priors.fade(belief(0, 5, nil, 2), job, 0);
    t.eq(none.muted, job.muted, 'nothing remembered takes the job prior');
    local pld = priors.fade(stored, priors.forJob('PLD'), 0);
    t.eq(pld.muted, priors.NO_MERITS, 'a job that cannot have the merit keeps none, whatever the file says');
end);

return t.done();

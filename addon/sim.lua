local buffs = require('buffs');
local calibration = require('calibration');
local filter = require('filter');
local hatelist = require('hatelist');
local tables = require('tables');

local sim = {};
sim.__index = sim;

local CLASS = filter.CLASS;
local CLASS_NAMES = filter.CLASS_NAMES;

-- IsWithinEnmityRange: 25 yalms, 28 for NMs.  NM status can't be observed, so
-- every mob is taken as notorious and given 28.  The error is deliberately
-- one-sided: crediting a normal mob's 25-28 band costs a little enmity that
-- wasn't earned, while dropping an NM's earns a player the model believes is
-- at zero, and the mob attacking them is then an event no gear can explain.
--
-- Both hitboxes are added on top.  Every range check on the server adds the
-- two entities' modelHitboxSize and measures centre to centre, so a big mob is
-- reachable from well past the flat figure; 0x00E carries the mob's and 0x00D
-- the actor's, each in tenths of a yalm.
sim.RANGE = 28.0;

-- True when a hit for zero still counts (C++ physical path); false when it goes through updateEnmityFromDamage in Lua, which skips zero.
local DAMAGE = {
    [1] = true,     -- AttackHits
    [67] = true,    -- AttackCrit
    [352] = true,   -- RangedAttackHit
    [353] = true,   -- RangedAttackCrit
    [576] = true,   -- RangedAttackSquarely
    [577] = true,   -- RangedAttackPummels
    [157] = true,   -- UsesBarrageTakesDamage
    [77] = true,    -- UsesSangeTakesDamage
    [185] = true,   -- UsesSkillTakesDamage (weaponskills; mob skills taken)
    [2] = false,    -- MagicDamage
    [252] = false,  -- MagicBurstDamage
    [264] = false,  -- TargetTakesDamage (area secondary targets)
    [110] = false,  -- UsesAbilityTakesDamage
    [317] = false,  -- UsesJobAbilityTakeDamage
};

-- A spell the target's shadows take passes 0/0 to ApplyEnmity (OnCastFinished).
local SHADOW_ABSORB = 31;

-- UsesSkillMisses: TakeWeaponskillDamage still credits the attacker with 1.
local WEAPONSKILL_MISS = 188;
local CATEGORY_MELEE = 1;
local CATEGORY_RANGED = 2;
local CATEGORY_WEAPONSKILL = 3;
local CATEGORY_MAGIC = 4;

local HEALED = {
    [7] = true,     -- MagicRecoversHP
    [24] = true,    -- TargetRecoversHPSimple
    [102] = true,   -- UsesRecoversHP
    [103] = true,   -- SkillRecoversHP
    [238] = true,   -- UsesSkillRecoversHPAreaOfEffect
    [263] = true,   -- TargetRecoversHP2
    [367] = true,   -- TargetRecoversHP
};

local ABILITY_CATEGORIES = { [6] = true, [13] = true, [14] = true, [15] = true };

-- Shield Bash, Weapon Bash and the Jumps arrive in the weaponskill category with one of these, and their param is then an ability id.
local ABILITY_MESSAGES = { [110] = true, [158] = true, [317] = true, [324] = true };

local function abilityLike(event)
    if ABILITY_CATEGORIES[event.category] then
        return true;
    end
    if event.category ~= 3 then
        return false;
    end
    local target = event.targets[1];
    local result = target and target.results[1];
    return result ~= nil and ABILITY_MESSAGES[result.message] == true;
end

-- Melee, ranged and weaponskills ClaimMob before their damage lands, so even a miss claims; spells and enmity-carrying abilities claim after.
local CLAIM_FIRST, CLAIM_AFTER = 1, 2;
local CLAIMS_FIRST = { [1] = true, [2] = true, [3] = true };
local CLAIMING_ABILITY_CATEGORIES = { [6] = true, [14] = true, [15] = true };

-- action_result_t::recordSkillchain: 287 + chain, or 384 + chain when absorbed, chains 1-16.
local SKILLCHAIN_FIRST, SKILLCHAIN_LAST = 288, 303;
local SKILLCHAIN_ABSORBED_FIRST, SKILLCHAIN_ABSORBED_LAST = 385, 400;

local PLAYER_SIDE = { alliance = true, player = true, pet = true, trust = true };

local DEFEATED = {
    [6] = true,     -- DefeatsTarget
    [20] = true,    -- FallsToGround
};

-- xi::Animation: Attack while engaged, then the death ones.
local ANIMATION_ENGAGED = 1;
local ANIMATION_DEAD = { [2] = true, [3] = true };

-- The action that opens a list reaches the client before the mob's engaged update, so idle updates right behind it are expected.
sim.GRACE = 5;

sim.STALE = 60;

sim.QUIET = 180;

-- No server id is zero.
local UNSEEN = 0;

local FRESH_ENGAGE = 10;

local DEFAULT_LEVEL = 75;

-- scripts/effects/healing.lua and map.HEALING_TICK_DELAY: the first tick heals nothing, each after heals REST_BASE_HP plus one a tick.
local REST_TICK = 10;
local REST_BASE_HP = 10;
local SIGNET, SIGIL = 253, 268;
-- Region ranges per healing.lua; Sanction's Aht Urhgan adds nothing to a tick.
local REGION_LIMBUS = 27;
local REGION_FIRST_FRONT, REGION_LAST_FRONT = 33, 40;
-- Measured on Horizon 2026-09-13 (75 RDM, 1223 max HP): 35 + 4 a tick without Signet, 48 + 6 under it; scaling with level or max HP is unknown.
local HORIZON_REST = { base = 35, step = 4 };
local HORIZON_REST_SIGNET = { base = 48, step = 6 };

-- Durations from paladin.lua useCover (15 s plus up to 15 from VIT and MND plus 4 a merit rank, the longest taken) and ninja.lua (60 s).
local MECHANICS = {
    cover = { status = 114, abilities = { 79 }, duration = 50 },
    issekigan = { status = 484, abilities = { 291 }, duration = 60 },
};
local COVER = MECHANICS.cover.abilities[1];

-- thief.lua transferEnmity: 20.6 yalms, Accomplice 50%, Collaborator 25%; Horizon's Collaborator runs thief to target via the overlay rule.
local ACCOMPLICE, COLLABORATOR = 84, 236;
local TRANSFERS = {
    [ACCOMPLICE] = { percent = 50, key = 'accomplice' },
    [COLLABORATOR] = { percent = 25, key = 'collaborator', values = 'lsb' },
};
local TRANSFER_RANGE = 20.6;

-- HandleIssekiganEnmityBonus: UpdateEnmity(parrier, 300, 0) on each parry.
local PARRY = 70;
local ISSEKIGAN_CE = 300;

-- thief.lua: Trick Attack lasts a minute and its flag drops on the thief's next melee round or weaponskill.
local TRICK_ATTACK = 76;
local TRICK_ATTACK_DURATION = 60;
local SPENDS_TRICK_ATTACK = { [1] = true, [3] = true };

-- getAvailableTrickAttackChar / areInLine (battleutils.cpp).
local LINE_MIN_DISTANCE = 0.5;
local LINE_MAX_DEVIANCE = 8;
-- Client positions are too coarse for that line, so a failed exact check falls back to the best-aligned ally at most this far off.
local GUESS_MAX_DEVIANCE = 24;
local GUESS_DISTANCE_SLACK = 1;

-- GetHitRateEx / GetCritHitRate: a THF main with Assassin whose Trick Attack finds a partner never misses and always crits, unless Sneak Attack is up.
local ASSASSIN_LEVEL = 60;
local SNEAK_ATTACK = 44;
local SNEAK_ATTACK_DURATION = 60;
local ATTACK_HIT, ATTACK_CRIT, ATTACK_MISS = 1, 67, 15;

-- enhancing_ninjutsu.lua: Utsusemi's count is the spell's power, one less for Ni off a ninja main.
local UTSUSEMI = { [338] = 3, [339] = 4, [340] = 5 };
local UTSUSEMI_NI = 339;
local BLINK = 53;
local GAINS_EFFECT = 230;
local STATUS_BLINK = 36;
local STATUS_COPY_IMAGE = { 66, 444, 445, 446 };

-- Only these go through IsAbsorbByShadow, which charges CE; mob skills take shadows in script for free.
local SHADOWS_CHARGED = { [1] = true, [2] = true, [4] = true };

-- A mob's TP move finishing: its param is the mobskill id (mobskill_state.cpp).
local CATEGORY_MOBSKILL = 11;
-- MAGIC_ENFEEB_IS, SKILL_ENFEEB_IS, IS_EFFECT: the result's param is the status.
local ENFEEB_IS = { [236] = true, [242] = true, [277] = true };
-- CHARM_I and CHARM_II.
local CHARM = { [14] = true, [17] = true };

local CATEGORY_PET_ABILITY = 13;

local CATEGORY_NAMES = {
    [1] = 'melee', [2] = 'ranged', [3] = 'weaponskill', [4] = 'spell', [5] = 'item', [6] = 'ability',
    [11] = 'mobskill', [13] = 'pet ability', [14] = 'dance', [15] = 'rune',
};

-- A conditional reset or reduction sits under processDamage's hitsLanded, so none happens on these.
local SKILL_MISSED = {
    [15] = true,    -- HIT_MISS
    [30] = true,    -- ANTICIPATE
    [31] = true,    -- SHADOW_ABSORB
    [32] = true,    -- the same as 31
    [85] = true,    -- MAGIC_RESIST
    [158] = true,   -- JA_MISS
    [188] = true,   -- SKILL_MISS
    [189] = true,   -- SKILL_NO_EFFECT
    [282] = true,   -- EVADES
    [284] = true,   -- MAGIC_RESIST_2
    [324] = true,   -- JA_MISS_2
    [354] = true,   -- RANGED_ATTACK_MISS
    [655] = true,   -- MAGIC_COMPLETE_RESIST
};

-- CounterAbsByShadow: a counter to the actor's own swing, into their shadow.
local COUNTER_ABSORBED = 14;

local PLAYER_DEFEATED = {
    [20] = true,    -- FallsToGround
    [97] = true,    -- PlayerDefeatedBy
};

local function conditionals(overlays)
    local out, keys = { abilities = {}, spells = {} }, {};
    for key, rule in pairs(overlays.conditional) do
        if rule.requires ~= nil and (rule.ce ~= nil or rule.ceMain ~= nil) then
            keys[rule] = key;
            for kind, ids in pairs(out) do
                for _, id in ipairs(rule[kind] or {}) do
                    ids[id] = rule;
                end
            end
        end
    end
    return out, keys;
end

local function effectsOf(overlays)
    local out = {};
    for key, rule in pairs(overlays.effects or {}) do
        for _, id in ipairs(rule.abilities or {}) do
            out[id] = { key = key, rule = rule };
        end
    end
    for key, rule in pairs(overlays.conditional or {}) do
        if rule.transfer ~= nil then
            for _, id in ipairs(rule.abilities or {}) do
                out[id] = { key = key, rule = rule };
            end
        end
    end
    return out;
end

local HISTORY = 8192;
local HISTORY_MARGIN = 120;

local function newHistory()
    local events, times = {}, {};
    for i = 1, HISTORY do
        events[i], times[i] = false, 0;
    end
    return { events = events, times = times, first = 1, count = 0 };
end

function sim.new(world, opts)
    opts = opts or {};
    local overlays = opts.overlays or tables.overlays;
    local timed = {};
    for key, rule in pairs(overlays.buffs) do
        timed[key] = rule;
    end
    for key, rule in pairs(MECHANICS) do
        timed[key] = rule;
    end
    local f = opts.filter;
    local conditional, ruleKeys = conditionals(overlays);
    return setmetatable({
        world = world,
        opts = opts,
        filter = f,
        log = opts.log,
        research = opts.research,
        history = newHistory(),
        historyFrom = 0,
        hitboxes = {},
        refitting = false,
        pendingRefit = nil,
        refits = 0,
        rows = f and { actor = f:row(), dealer = f:row(), passive = f:row() },
        cap = opts.cap,
        levelRange = opts.levelRange or tables.levelRange,
        regions = opts.regions or tables.regions,
        actions = opts.actions or tables.actions,
        mobskills = opts.mobskills or tables.mobskills,
        scriptedMobs = opts.scriptedMobs or tables.scriptedMobs,
        buffs = buffs.new({ buffs = timed }),
        shadowRule = opts.shadowRule == 'era' and 'era' or 'lsb',
        values = opts.values == 'lsb' and 'lsb' or 'era',
        conditional = conditional,
        ruleKeys = ruleKeys,
        effects = effectsOf(overlays),
        gear = overlays.gear,
        applying = {
            entry = nil, ce = 0, ve = 0, ceTrust = nil, veTrust = nil, class = 0, mod = 0, mods = 0,
            dealer = nil, dealerMod = 0, dealerMods = 0, actorKind = nil,
        },
        lists = {},
        tracks = {},
        states = {},
        acting = {},
        covers = {},
        tricks = {},
        sneaks = {},
        rests = {},
        shadows = {},
        dead = {},
        names = {},
        causes = nil,
        ranged = nil,
        gaps = {},
        calibration = f and calibration.new(filter.CREDIBLE),
        wipes = 0,
        downed = false,
        tick = nil,
        now = 0,
    }, sim);
end

local function resolve(self, id)
    local r = self.world:resolve(id);
    if r ~= nil and r.name ~= nil and r.name ~= '' then
        self.names[id] = r.name;
    end
    return r;
end

local function logClock(self)
    return self.filter and self.filter.clock();
end

local function charge(self, since)
    if since and self.log and self.log.charge then
        self.log:charge(self.filter.clock() - since);
    end
end

local function note(self, kind, fields)
    local since = logClock(self);
    self.log:write(kind, fields);
    charge(self, since);
end

local function cause(self, id, name, mod)
    local causes = self.causes;
    if causes == nil then
        return;
    end
    local c = causes[id];
    if c == nil then
        c = {};
        causes[id] = c;
    end
    c[#c + 1] = name;
    if mod ~= nil then
        c.mod = mod;
    end
end

local function listFor(self, mob)
    local list = self.lists[mob];
    if list == nil then
        list = self.filter and self.filter:newList(self.cap) or hatelist.new(self.cap);
        local state = self.states[mob];
        local engaged;
        if state ~= nil then
            engaged = state.engaged;
        else
            engaged = self.world:inCombat(mob);
        end
        local clean = engaged == false;
        local fresh = false;
        if engaged then
            list:occupy(UNSEEN, false);
            fresh = state ~= nil and not state.seenIdle and state.hpp == 100 and self.now - state.since <= FRESH_ENGAGE;
            clean = (state ~= nil and state.seenIdle) or fresh;
        end
        self.lists[mob] = list;
        self.tracks[mob] = {
            clean = clean, anchored = 0, unlikely = 0, skill = nil,
            holder = nil, holderModelled = false, acting = 0, lastAction = self.now,
            lastCombat = self.now, trust = {}, opened = self.now, complete = clean,
            ledger = self.log and {}, bounds = self.log and {}, impossible = self.log and {},
            lastShadows = self.research and {}, avatars = self.research and {}, researched = self.research ~= nil,
        };
        if self.log then
            local lo, hi, source = self.levelRange(mob);
            note(self, 'list', {
                mob = mob, name = self.names[mob], clean = clean, engaged = engaged, fresh = fresh or nil,
                hpp = state and state.hpp, engagedFor = state and engaged and (self.now - state.since) or nil,
                levels = lo and { lo, hi }, levelSource = source,
            });
        end
    end
    self.tracks[mob].lastAction = self.now;
    return list;
end

local function fought(self, mob)
    self.tracks[mob].lastCombat = self.now;
end

local function touch(self, mob)
    local list = self.lists[mob];
    if list ~= nil then
        self.tracks[mob].lastAction = self.now;
    end
    return list;
end

local function setActing(self, id, mob)
    local previous = self.acting[id];
    if previous == mob then
        return;
    end
    if previous ~= nil then
        local track = self.tracks[previous];
        track.acting = track.acting - 1;
    end
    self.acting[id] = mob;
    self.tracks[mob].acting = self.tracks[mob].acting + 1;
end

local function setHolder(track, id, modelled)
    track.holder, track.holderModelled = id, modelled;
end

local function logFight(self, mob, reason)
    local list, track = self.lists[mob], self.tracks[mob];
    local values, names = {}, {};
    for _, id in ipairs(list.order) do
        local ce, ve, active = list:get(id);
        values[#values + 1] = { id, ce, ve, active };
    end
    for id in pairs(track.ledger or {}) do
        names[id] = self.names[id];
    end
    note(self, 'fight', {
        mob = mob, name = self.names[mob], reason = reason, clean = track.clean,
        anchored = track.anchored, seconds = self.now - track.opened, values = values,
        names = names, ledger = track.ledger, trust = track.trust,
    });
end

local function drop(self, mob, reason)
    local list = self.lists[mob];
    if list == nil then
        return;
    end
    if self.log then
        logFight(self, mob, reason);
    end
    if self.filter ~= nil then
        self.filter:release(list);
    end
    self.lists[mob] = nil;
    self.tracks[mob] = nil;
    for id, target in pairs(self.acting) do
        if target == mob then
            self.acting[id] = nil;
        end
    end
end

local function inRange(self, id, mob)
    local d = self.world:distance(id, mob);
    local mobBox, actorBox = self.hitboxes[mob] or 0, self.hitboxes[id] or 0;
    local limit = sim.RANGE + mobBox + actorBox;
    if d == nil or d <= limit then
        return true;
    end
    local ranged = self.ranged;
    if ranged ~= nil and not (ranged[id] and ranged[id][mob]) then
        ranged[id] = ranged[id] or {};
        ranged[id][mob] = true;
        -- Every term of the decision, so a replay can take it again: without
        -- the hitboxes and the limit a log says only that something was
        -- dropped, never whether it should have been.
        note(self, 'range', {
            id = id, mob = mob, distance = d, limit = limit,
            base = sim.RANGE, mobHitbox = mobBox, actorHitbox = actorBox,
        });
    end
    return false;
end

local function levelOf(member)
    local level = member.mainLevel;
    if level == nil or level <= 0 then
        return nil;
    end
    return level;
end

local function allianceLevel(self)
    local best = nil;
    for _, id in ipairs(self.world:alliance()) do
        local r = resolve(self, id);
        local level = r ~= nil and r.member ~= nil and levelOf(r.member) or nil;
        if level ~= nil and (best == nil or level > best) then
            best = level;
        end
    end
    return best;
end

local function memberLevel(self, member)
    return levelOf(member) or allianceLevel(self);
end

local function mobLevel(self, mob, member)
    local lo, hi = self.levelRange(mob);
    if lo ~= nil then
        return math.floor((lo + hi) / 2);
    end
    return memberLevel(self, member) or DEFAULT_LEVEL;
end

local function damageOf(category, result)
    local floorsAtOne = DAMAGE[result.message];
    if floorsAtOne == nil then
        if category == CATEGORY_WEAPONSKILL and result.message == WEAPONSKILL_MISS then
            return 1;
        end
        return nil;
    end
    if result.param > 0 then
        return result.param;
    end
    return floorsAtOne and 1 or nil;
end

local function skillchainDamageOf(result)
    local effect = result.addEffect;
    if effect == nil then
        return nil;
    end
    local m = effect.message;
    if (m >= SKILLCHAIN_FIRST and m <= SKILLCHAIN_LAST) or (m >= SKILLCHAIN_ABSORBED_FIRST and m <= SKILLCHAIN_ABSORBED_LAST) then
        return effect.param;
    end
    return nil;
end

local function entryOf(self, event)
    if event.category == CATEGORY_MAGIC then
        return self.actions.spells[event.param];
    elseif abilityLike(event) then
        return self.actions.abilities[event.param];
    end
end

local function valuesOf(self, entry)
    if self.values == 'lsb' and entry.lsbCe ~= nil then
        return entry.lsbCe, entry.lsbVe, 'lsb', 'lsb';
    end
    return entry.ce, entry.ve, entry.ceTrust, entry.veTrust;
end

local function baseOf(self, entry)
    if entry == nil or entry.cure == 'fixed' then
        return 0, 0;
    end
    return valuesOf(self, entry);
end

local function claimOrder(self, event, entry)
    if CLAIMING_ABILITY_CATEGORIES[event.category] or (event.category == CATEGORY_WEAPONSKILL and abilityLike(event)) then
        if entry ~= nil then
            local ce, ve = valuesOf(self, entry);
            if ce ~= 0 or ve ~= 0 then
                return CLAIM_AFTER;
            end
        end
        return nil;
    elseif CLAIMS_FIRST[event.category] then
        return CLAIM_FIRST;
    elseif event.category == CATEGORY_MAGIC then
        return CLAIM_AFTER;
    end
    return nil;
end

local TRUST_RANK = { era = 1, lsb = 2, unknown = 3 };

local function worse(a, b)
    return TRUST_RANK[b] > TRUST_RANK[a] and b or a;
end

local function gearOf(self, id, member)
    local total = 0;
    for item, rule in pairs(self.gear) do
        if (rule.subJob == nil or member.subJob == rule.subJob) and self.world:wearing(id, item) then
            total = total + rule.enmity;
        end
    end
    return total;
end

local function enmityOf(self, id, member)
    return self.buffs:enmity(self.world, id, member, self.now) + gearOf(self, id, member);
end

local function mutedSoul(self, id, member)
    return member ~= nil and member.mainJob == 'DRK' and self.buffs.rules.souleater ~= nil
        and self.buffs:holds(self.world, id, member, 'souleater', self.now);
end

local function modsFor(self, row, id, member, class, known)
    if self.filter == nil then
        return known;
    end
    return self.filter:fill(row, id, class, known, mutedSoul(self, id, member));
end

local function classOf(self, event, entry)
    local category = event.category;
    if entry ~= nil and entry.cure ~= nil then
        return CLASS.cure;
    elseif category == CATEGORY_MELEE then
        return CLASS.melee;
    elseif category == CATEGORY_WEAPONSKILL then
        return abilityLike(event) and CLASS.ability or CLASS.weaponskill;
    elseif CLAIMING_ABILITY_CATEGORIES[category] then
        return CLASS.ability;
    elseif category == CATEGORY_MAGIC then
        for _, target in ipairs(event.targets) do
            local r = self.world:resolve(target.id);
            if r ~= nil and r.kind == 'mob' then
                return CLASS.magic;
            end
        end
    end
    return CLASS.other;
end

local function logAction(self, event, id, member, rule)
    local since = logClock(self);
    local a, world = self.applying, self.world;
    local held = {};
    for key in pairs(self.buffs.rules) do
        if self.buffs:holds(world, id, member, key, self.now) then
            held[#held + 1] = key;
        end
    end
    table.sort(held);
    local items, gear = {}, 0;
    for item, g in pairs(self.gear) do
        if (g.subJob == nil or member.subJob == g.subJob) and world:wearing(id, item) then
            items[#items + 1] = item;
            gear = gear + g.enmity;
        end
    end
    table.sort(items);
    local targets = {};
    for _, target in ipairs(event.targets) do
        local r = world:resolve(target.id);
        if r ~= nil and r.kind == 'mob' then
            targets[#targets + 1] = {
                id = target.id, distance = world:distance(id, target.id), level = mobLevel(self, target.id, member),
            };
        end
    end
    local entry = a.entry;
    charge(self, since);
    note(self, 'action', {
        actor = id, name = self.names[id], category = event.category, param = event.param,
        class = CLASS_NAMES[a.class], mod = a.mod, buffs = held, readable = world:hasBuff(id, 0) ~= nil,
        muted = mutedSoul(self, id, member) or nil,
        gear = gear ~= 0 and gear or nil, items = #items > 0 and items or nil, targets = targets,
        entry = entry and entry.name, cure = entry and entry.cure, ce = a.ce, ve = a.ve,
        ceTrust = a.ceTrust, veTrust = a.veTrust, rule = rule and self.ruleKeys[rule],
    });
end

local function prepare(self, event, actor)
    local a = self.applying;
    a.entry, a.ce, a.ve, a.ceTrust, a.veTrust, a.class, a.mod, a.mods = nil, 0, 0, nil, nil, CLASS.other, 0, 0;
    a.dealer, a.dealerMod, a.dealerMods, a.actorKind = event.actorId, 0, 0, actor.kind;
    if actor.kind ~= 'alliance' then
        return a;
    end
    local id, member = event.actorId, actor.member;
    local entry = entryOf(self, event);
    local isAbility = abilityLike(event);
    if entry ~= nil and isAbility then
        -- OnUseAbility applies the buff before ApplyEnmity, so it counts on itself.
        self.buffs:seen(id, event.param, self.now);
    elseif entry ~= nil and event.category == CATEGORY_MAGIC then
        -- OnCastFinished runs the spell before ApplyEnmity, the same way.
        self.buffs:seenSpell(id, event.param, self.now);
    end
    a.entry = entry;
    a.class = classOf(self, event, entry);
    a.mod = enmityOf(self, id, member);
    a.mods = modsFor(self, self.rows and self.rows.actor, id, member, a.class, a.mod);
    a.dealerMod, a.dealerMods = a.mod, a.mods;
    a.ce, a.ve = baseOf(self, entry);
    local applied = nil;
    if entry ~= nil and entry.cure ~= 'fixed' then
        local _, _, ceTrust, veTrust = valuesOf(self, entry);
        a.ceTrust, a.veTrust = ceTrust, veTrust;
        local rule = self.conditional[isAbility and 'abilities' or 'spells'][event.param];
        if rule ~= nil and self.buffs:holds(self.world, id, member, rule.requires, self.now) then
            if rule.ce ~= nil then
                a.ce, a.ve = rule.ce, rule.ve;
                a.ceTrust, a.veTrust = rule.trust, rule.trust;
                applied = rule;
            elseif member.mainJob == rule.job or member.subJob == rule.job then
                a.ce = a.ce + (member.mainJob == rule.job and rule.ceMain or rule.ceSub);
                a.ceTrust = worse(a.ceTrust, rule.trust);
                applied = rule;
            end
        end
    end
    if self.log then
        logAction(self, event, id, member, applied);
    end
    return a;
end

local function tally(self, mob, id, near, ceTrust, veTrust)
    if not near or ceTrust == nil then
        return;
    end
    local trust = self.tracks[mob].trust;
    local counts = trust[id];
    if counts == nil then
        counts = { ce = { era = 0, lsb = 0, unknown = 0 }, ve = { era = 0, lsb = 0, unknown = 0 } };
        trust[id] = counts;
    end
    counts.ce[ceTrust] = counts.ce[ceTrust] + 1;
    counts.ve[veTrust] = counts.ve[veTrust] + 1;
end

local function credit(self, list, event, actor, mob, damage, own)
    if actor.kind ~= 'alliance' then
        list:occupy(event.actorId, true);
        return;
    end
    local a = self.applying;
    if damage ~= nil then
        list:damage(a.dealer, damage, mobLevel(self, mob, actor.member), a.dealerMods, inRange(self, a.dealer, mob));
        return;
    end
    local near = inRange(self, event.actorId, mob);
    if own and (a.ce ~= 0 or a.ve ~= 0) then
        list:add(event.actorId, a.ce, a.ve, a.mods, near);
    end
    if own then
        tally(self, mob, event.actorId, near, a.ceTrust, a.veTrust);
    end
    list:claim(event.actorId, a.mods, near);
end

-- worldAngle (utils.cpp): the bearing from A to B in 256ths of a turn.
local function worldAngle(ax, ay, bx, by)
    local raw = math.atan2(by - ay, bx - ax) * -(128 / math.pi);
    raw = raw < 0 and math.ceil(raw) or math.floor(raw);
    return raw % 256;
end

-- angleDifference (utils.cpp): signed, wrapped into -128..128.
local function angleDifference(a, b)
    local d = a - b;
    if d > 128 then
        d = d - 256;
    elseif d < -128 then
        d = d + 256;
    end
    return d;
end

local function trickEvidence(self, event, target, member)
    if event.category ~= CATEGORY_MELEE or member == nil or member.mainJob ~= 'THF'
            or (member.mainLevel ~= nil and member.mainLevel < ASSASSIN_LEVEL) then
        return nil;
    end
    local sneak = (self.sneaks[event.actorId] or 0) > self.now;
    local crit = false;
    for _, result in ipairs(target.results) do
        local message = result.message;
        if message == ATTACK_MISS or (message == ATTACK_HIT and not sneak) then
            return 'none';
        elseif message == ATTACK_CRIT then
            crit = true;
        end
    end
    return crit and not sneak and 'crit' or nil;
end

local function partnerOf(self, thief, mob, evidence, seen)
    local world = self.world;
    local mx, my = world:position(mob);
    local tx, ty = world:position(thief);
    local reach = world:distance(thief, mob);
    if mx == nil or tx == nil or reach == nil then
        return nil, 'unplaced';
    end
    local line = worldAngle(mx, my, tx, ty);
    local cap = evidence == 'crit' and 128 or GUESS_MAX_DEVIANCE;
    local best, bestDistance = nil, reach;
    local guess, guessDeviance, guessDistance = nil, cap + 1, nil;
    for _, id in ipairs(world:alliance()) do
        if id ~= thief and not self.dead[id] then
            local d = world:distance(id, mob);
            local x, y = world:position(id);
            if d ~= nil and x ~= nil and d >= LINE_MIN_DISTANCE and d < reach + GUESS_DISTANCE_SLACK then
                local deviance = math.abs(angleDifference(line, worldAngle(mx, my, x, y)));
                if seen ~= nil then
                    seen[#seen + 1] = { id, d, deviance };
                end
                if d < bestDistance and deviance <= LINE_MAX_DEVIANCE then
                    best, bestDistance = id, d;
                end
                if deviance < guessDeviance or (deviance == guessDeviance and d < guessDistance) then
                    guess, guessDeviance, guessDistance = id, deviance, d;
                end
            end
        end
    end
    if evidence == 'none' then
        return nil, 'none';
    elseif best ~= nil then
        return best, 'line';
    end
    return guess, guess and 'guess' or 'none';
end

local function utsusemiUp(self, id, member)
    local state = self.shadows[id];
    if state ~= nil and state.utsusemi then
        return true;
    end
    for _, status in ipairs(STATUS_COPY_IMAGE) do
        if self.world:hasBuff(id, status) then
            return true;
        end
    end
    if state ~= nil or self.world:hasBuff(id, STATUS_BLINK) then
        return false;
    end
    return member.mainJob == 'NIN' or member.subJob == 'NIN';
end

local function absorb(self, list, mob, id, member, shadows, charged)
    local state = self.shadows[id];
    local count = state and state.count;
    local loss = self.actions.misc.shadowAbsorb;
    local pays = charged and utsusemiUp(self, id, member);
    local near = inRange(self, id, mob);
    local paid, last = 0, 0;
    for _ = 1, math.max(shadows, 1) do
        if count ~= nil then
            count = count - 1;
        end
        if pays and (self.shadowRule == 'lsb' or count == nil or (count >= 1 and count <= 3)) then
            list:add(id, loss.ce, loss.ve, 0, near);
            tally(self, mob, id, near, loss.trust, loss.trust);
            paid = paid + 1;
        end
        if pays and count == 0 then
            last = last + 1;
        end
    end
    if paid > 0 then
        cause(self, id, 'shadow');
    end
    if last > 0 and self.research then
        local shadowsLost = self.tracks[mob].lastShadows;
        shadowsLost[id] = (shadowsLost[id] or 0) + last;
    end
    if self.log then
        note(self, 'shadow', {
            mob = mob, id = id, shadows = shadows, charged = charged == true, utsusemi = pays or nil, paid = paid,
            left = count, rule = self.shadowRule,
        });
    end
    if count ~= nil then
        state.count = count;
        if count <= 0 then
            self.shadows[id] = nil;
        end
    end
end

local function castShadows(self, event, member)
    local count = UTSUSEMI[event.param];
    if count == nil and event.param ~= BLINK then
        return;
    end
    for _, target in ipairs(event.targets) do
        local result = target.results[1];
        if target.id == event.actorId and result ~= nil and result.message == GAINS_EFFECT then
            if count == nil then
                self.shadows[event.actorId] = { utsusemi = false };
            else
                if event.param == UTSUSEMI_NI and member.mainJob ~= 'NIN' then
                    count = count - 1;
                end
                self.shadows[event.actorId] = { utsusemi = true, count = count };
            end
        end
    end
end

local function avatarMaster(self, pet)
    local master = self.world:petOwner(pet);
    local r = master and resolve(self, master);
    if r == nil or r.kind ~= 'alliance' or r.member.mainJob ~= 'SMN' then
        return nil;
    end
    return master, r.member;
end

local function avatarGain(self, mob, pet, master, category, ce, ve)
    local avatars = self.tracks[mob].avatars;
    local a = avatars[master];
    if a == nil then
        a = { pet = pet, pactCe = 0, pactVe = 0, otherCe = 0, otherVe = 0 };
        avatars[master] = a;
    end
    a.pet = pet;
    local cap = self.cap or hatelist.CAP;
    ce = math.max(0, math.min(ce, cap - a.pactCe - a.otherCe));
    ve = math.max(0, math.min(ve, cap - a.pactVe - a.otherVe));
    if category == CATEGORY_PET_ABILITY then
        a.pactCe, a.pactVe = a.pactCe + ce, a.pactVe + ve;
    else
        a.otherCe, a.otherVe = a.otherCe + ce, a.otherVe + ve;
    end
end

local function avatarDealt(self, event, mob, damage)
    local master, member = avatarMaster(self, event.actorId);
    if master == nil then
        return;
    end
    local ce, ve = hatelist.damageEnmity(damage, mobLevel(self, mob, member));
    avatarGain(self, mob, event.actorId, master, event.category, ce, ve);
end

local function avatarPact(self, event)
    local entry = self.actions.abilities[event.param];
    if entry == nil then
        return;
    end
    local ce, ve = valuesOf(self, entry);
    if ce == 0 and ve == 0 then
        return;
    end
    local master = avatarMaster(self, event.actorId);
    if master == nil then
        return;
    end
    for _, target in ipairs(event.targets) do
        local r = resolve(self, target.id);
        if r ~= nil and r.kind == 'mob' then
            if self.lists[target.id] ~= nil then
                avatarGain(self, target.id, event.actorId, master, event.category, ce, ve);
            end
        elseif r ~= nil and PLAYER_SIDE[r.kind] then
            for mob, list in pairs(self.lists) do
                if list.claimed and list.others[event.actorId] then
                    avatarGain(self, mob, event.actorId, master, event.category, ce, ve);
                end
            end
        end
    end
end

local function researchLowered(self, track, id, percent)
    local keep = (100 - percent) / 100;
    if track.lastShadows[id] ~= nil then
        track.lastShadows[id] = track.lastShadows[id] * keep;
    end
    for _, a in pairs(track.avatars) do
        if a.pet == id then
            a.pactCe, a.pactVe, a.otherCe, a.otherVe = a.pactCe * keep, a.pactVe * keep, a.otherCe * keep, a.otherVe * keep;
        end
    end
end

local function dealt(self, event, actor, target)
    local mob = target.id;
    local order = claimOrder(self, event, self.applying.entry);
    local list = touch(self, mob);

    if actor.kind == 'alliance' and event.category == CATEGORY_MELEE then
        local landed, lit = false, false;
        for _, result in ipairs(target.results) do
            if DAMAGE[result.message] ~= nil then
                landed = true;
                local effect = result.addEffect;
                if effect ~= nil and self.buffs:struck(event.actorId, effect.kind, self.now) then
                    lit = true;
                end
            end
        end
        if landed and not lit then
            self.buffs:unlit(event.actorId, self.now);
        end
    end

    local a = self.applying;
    if actor.kind == 'alliance' and SPENDS_TRICK_ATTACK[event.category] and (self.tricks[event.actorId] or 0) > self.now then
        local evidence = trickEvidence(self, event, target, actor.member);
        local seen = self.log and {};
        local partner, how = partnerOf(self, event.actorId, mob, evidence, seen);
        if self.log then
            note(self, 'trick', {
                thief = event.actorId, mob = mob, partner = partner, how = how, evidence = evidence,
                reach = self.world:distance(event.actorId, mob), nearer = #seen > 0 and seen or nil,
            });
        end
        local r = partner and resolve(self, partner);
        if r ~= nil and r.member ~= nil then
            a.dealer, a.dealerMod = partner, enmityOf(self, partner, r.member);
            a.dealerMods = modsFor(self, self.rows and self.rows.dealer, partner, r.member, CLASS.melee, a.dealerMod);
            cause(self, partner, 'trick attack', a.dealerMod);
        end
    end

    if order == CLAIM_FIRST then
        list = list or listFor(self, mob);
        credit(self, list, event, actor, mob, nil, false);
    end
    local override = event.category == CATEGORY_WEAPONSKILL and actor.kind == 'alliance' and not abilityLike(event)
        and self.actions.weaponskills[event.param];
    local landed = false;
    local absorbed = false;
    for _, result in ipairs(target.results) do
        absorbed = absorbed or result.message == SHADOW_ABSORB;
        local spikes = result.spikes;
        if spikes ~= nil and spikes.message == COUNTER_ABSORBED and list ~= nil and actor.kind == 'alliance' then
            absorb(self, list, mob, event.actorId, actor.member, spikes.param, true);
        end
        local damage = damageOf(event.category, result);
        if damage ~= nil and override and result.message ~= WEAPONSKILL_MISS then
            landed = true;
        elseif damage ~= nil then
            list = list or listFor(self, mob);
            credit(self, list, event, actor, mob, damage);
        end
        local skillchain = skillchainDamageOf(result);
        if skillchain ~= nil then
            list = list or listFor(self, mob);
            cause(self, a.dealer, 'skillchain');
            credit(self, list, event, actor, mob, skillchain);
        end
        if self.research and actor.kind == 'pet' then
            if damage ~= nil then
                avatarDealt(self, event, mob, damage);
            end
            if skillchain ~= nil then
                avatarDealt(self, event, mob, skillchain);
            end
        end
    end
    if landed then
        list = list or listFor(self, mob);
        local near = inRange(self, a.dealer, mob);
        list:add(a.dealer, override.ce, override.ve, a.dealerMods, near);
        tally(self, mob, a.dealer, near, override.ceTrust, override.veTrust);
        cause(self, a.dealer, 'fixed');
    end
    if order == CLAIM_AFTER then
        list = list or listFor(self, mob);
        credit(self, list, event, actor, mob, nil, not absorbed);
    end

    if list ~= nil and actor.kind == 'alliance' then
        setActing(self, event.actorId, mob);
        fought(self, mob);
    end
end

local function transferHate(self, event, giver, receiver, percent, key)
    local who = resolve(self, receiver);
    if who == nil or who.kind ~= 'alliance' then
        return;
    end
    local thief = event.actorId;
    local class = receiver == thief and CLASS.ability or CLASS.melee;
    local row = self.rows and (receiver == thief and self.rows.actor or self.rows.passive);
    local mods = modsFor(self, row, receiver, who.member, class, enmityOf(self, receiver, who.member));
    local moved = false;
    for mob, list in pairs(self.lists) do
        local d = self.world:distance(thief, mob);
        if list:has(giver) and (d == nil or d <= TRANSFER_RANGE) then
            list:transfer(giver, receiver, percent, mods, inRange(self, receiver, mob));
            moved = true;
            if self.research then
                researchLowered(self, self.tracks[mob], giver, percent);
            end
            if self.log then
                note(self, 'effect', { mob = mob, id = giver, to = receiver, rule = key, percent = percent, distance = d });
            end
        end
    end
    if moved then
        cause(self, giver, ('gave %d%%'):format(percent));
        cause(self, receiver, ('took %d%%'):format(percent));
    end
end

local function applyEffect(self, event, actor)
    local transfer = TRANSFERS[event.param];
    if transfer ~= nil and (transfer.values == nil or transfer.values == self.values) then
        local target = event.targets[1];
        if target ~= nil then
            transferHate(self, event, target.id, event.actorId, transfer.percent, transfer.key);
        end
        return;
    end
    local effect = self.effects[event.param];
    if effect == nil then
        return;
    end
    local id, rule, member = event.actorId, effect.rule, actor.member;
    if rule.transfer ~= nil then
        local target = event.targets[1];
        if target ~= nil and self.values ~= 'lsb' then
            transferHate(self, event, id, target.id, rule.transfer, effect.key);
        end
    elseif rule.lowerMain ~= nil then
        if rule.job ~= nil and member.mainJob ~= rule.job and member.subJob ~= rule.job then
            return;
        end
        local percent = member.mainJob == rule.job and rule.lowerMain or rule.lowerSub;
        for _, target in ipairs(event.targets) do
            local list = self.lists[target.id];
            local r = resolve(self, target.id);
            if list ~= nil and r ~= nil and r.kind == 'mob' and list:has(id) then
                list:lowerByPercent(id, percent);
                cause(self, id, ('lowered %d%%'):format(percent));
                if self.research then
                    researchLowered(self, self.tracks[target.id], id, percent);
                end
                if self.log then
                    note(self, 'effect', { mob = target.id, id = id, rule = effect.key, percent = percent });
                end
            end
        end
    elseif rule.setCe ~= nil then
        for mob, list in pairs(self.lists) do
            local d = self.world:distance(id, mob);
            if list:has(id) and (d == nil or d <= rule.range) then
                list:set(id, rule.setCe, rule.setVe);
                cause(self, id, 'set');
                if self.research then
                    researchLowered(self, self.tracks[mob], id, 100);
                end
                if self.log then
                    note(self, 'effect', { mob = mob, id = id, rule = effect.key, ce = rule.setCe, ve = rule.setVe, distance = d });
                end
            end
        end
    end
end

local function holderOf(self, list, mob)
    local current = self.tracks[mob].holder;
    if self.filter ~= nil then
        return self.filter:highest(list, current);
    end
    return list:highest(current);
end

local function switches(track, id)
    return track.holderModelled and track.holder ~= nil and track.holder ~= id;
end

-- The zone in a mob's server id: 0x01000000 | zone << 12 | index.
local function zoneOf(mob)
    return math.floor((mob - 0x01000000) / 4096);
end

local function range(list, b)
    local cap = list.cap;
    local function held(v)
        return math.max(0, math.min(cap, v));
    end
    return held(b.ceLo) + held(b.veLo), held(b.ceHi) + held(b.veHi);
end

local function checkPossible(self, list, track, mob, id)
    if not track.complete or track.bounds == nil then
        return;
    end
    local since = logClock(self);
    local mine = track.bounds[id];
    local _, most = range(list, mine or { ceLo = 0, ceHi = 0, veLo = 0, veHi = 0 });
    local rival, least = nil, most;
    for _, other in ipairs(list.order) do
        local b = track.bounds[other];
        if other ~= id and b ~= nil and list.entries[other].active then
            local lo = range(list, b);
            if lo > least then
                rival, least = other, lo;
            end
        end
    end
    charge(self, since);
    local pair = rival and ('%d:%d'):format(id, rival);
    if rival == nil or track.impossible[pair] then
        return;
    end
    track.impossible[pair] = true;
    local ce, ve = list:get(id);
    local rivalCe, rivalVe = list:get(rival);
    note(self, 'impossible', {
        mob = mob, name = self.names[mob], target = id, targetName = self.names[id], rival = rival,
        rivalName = self.names[rival], most = most, least = least, short = least - most,
        values = { { id, ce, ve }, { rival, rivalCe, rivalVe } },
        ledger = { [id] = track.ledger[id], [rival] = track.ledger[rival] },
    });
end

local function calibrate(self, list, mob, id, switch, previous)
    local cal = self.calibration;
    local chances, n, at = self.filter:chances(list, previous, id);
    if at == nil then
        return;
    end
    local credit, contested = cal:score(chances, n, at);
    if not self.log then
        return;
    end
    local since = logClock(self);
    local each = {};
    for k = 1, n do
        each[k] = { list.order[k], chances[k - 1] };
    end
    local coverage, contestedCoverage = cal:coverage();
    charge(self, since);
    note(self, 'calibration', {
        mob = mob, target = id, switch = switch, holder = previous, chances = each, level = cal.level,
        credit = credit, contested = contested, attacks = cal.attacks, coverage = coverage, contestedCoverage = contestedCoverage,
    });
end

local function refittable(self)
    if self.filter == nil or self.opts.refit == false then
        return false;
    end
    for _, track in pairs(self.tracks) do
        if track.opened < self.historyFrom then
            return false;
        end
    end
    return true;
end

local function witness(self, list, mob, id, switch, previous)
    local track, f, log = self.tracks[mob], self.filter, self.log;
    if log then
        checkPossible(self, list, track, mob, id);
    end
    if f == nil then
        return false;
    end
    if not track.clean then
        if log then
            local since = logClock(self);
            f:predict(list, id);
            charge(self, since);
            note(self, 'observe', {
                mob = mob, target = id, switch = switch, tier = 'ordering',
                used = false, predicted = f.predicted, best = f.best, worst = f.worst, count = f.count,
            });
        end
        return false;
    end
    calibrate(self, list, mob, id, switch, previous);
    local since = logClock(self);
    local essBefore, resamples = log and f:ess(), f.resamples;
    charge(self, since);
    local used, surprised = f:observe(list, id, switch);
    local run = self.opts.refitRun;
    if run ~= nil and used and not surprised then
        if f.predicted < run.below then
            track.unlikely = track.unlikely + 1;
            if track.unlikely >= run.count and not self.refitting and refittable(self) then
                track.unlikely = 0;
                self.pendingRefit = { mob = mob, target = id, leader = list:highest(previous), switch = switch, run = true };
            end
        else
            track.unlikely = 0;
        end
    end
    if log then
        since = logClock(self);
        local essAfter = f:ess();
        charge(self, since);
        note(self, 'observe', {
            mob = mob, target = id, switch = switch, tier = 'clean', used = used, surprised = surprised,
            predicted = f.predicted, best = f.best, worst = f.worst, essBefore = essBefore, essAfter = essAfter,
            resampled = f.resamples ~= resamples, count = f.count,
        });
    end
    if not surprised then
        return false;
    end
    if not self.refitting and refittable(self) then
        self.pendingRefit = { mob = mob, target = id, leader = list:highest(previous), switch = switch };
        return false;
    end
    if switch and track.skill ~= nil and self.mobskills[track.skill] == nil then
        local zone, name = zoneOf(mob), self.names[mob];
        local scripted = self.scriptedMobs[zone];
        if scripted == nil or name == nil or not scripted[name] then
            local gap = { skill = track.skill, mob = mob, name = name, zone = zone };
            self.gaps[#self.gaps + 1] = gap;
            if log then
                note(self, 'gap', gap);
            end
        end
    end
    return true;
end

local function reanchor(self, list, mob, id, switch, previous)
    local track = self.tracks[mob];
    local leader = list:highest(previous);
    local fromCe, fromVe = list:get(id);
    local lanes = list:anchor(id);
    track.anchored = track.anchored + 1;
    if self.log then
        local ledgers, ledger = track.ledger or {}, {};
        ledger[id] = ledgers[id];
        if previous ~= nil then
            ledger[previous] = ledgers[previous];
        end
        if leader ~= nil then
            ledger[leader] = ledgers[leader];
        end
        local toCe, toVe = list:get(id);
        note(self, 'discontinuity', {
            mob = mob, name = self.names[mob], target = id, switch = switch, holder = previous, leader = leader,
            skill = track.skill, ledger = ledger, anchored = track.anchored, lanes = lanes,
            from = { fromCe, fromVe }, to = { toCe, toVe },
        });
    end
end

local function logTarget(self, list, mob, id, modelled, switch, covered, previous)
    local since = logClock(self);
    local margin = nil;
    if list.entries[id] ~= nil then
        local ce, ve = list:get(id);
        local best = nil;
        for _, other in ipairs(list.order) do
            local oce, ove, active = list:get(other);
            if other ~= id and active and (best == nil or oce + ove > best) then
                best = oce + ove;
            end
        end
        margin = best and ce + ve - best;
    end
    local leader = list:highest(previous);
    charge(self, since);
    note(self, 'target', {
        mob = mob, target = id, modelled = modelled, switch = switch, covered = covered or nil,
        clean = self.tracks[mob].clean, holder = previous, leader = leader, margin = margin,
    });
end

local function researchObserve(self, list, mob, id, switch, covered)
    local track = self.tracks[mob];
    if not track.researched then
        return;
    end
    local f = self.filter;
    local since = f and f.clock();
    local rows = {};
    for _, other in ipairs(list.order) do
        local ce, ve, active = list:get(other);
        if active then
            rows[#rows + 1] = { id = other, total = ce + ve, last = track.lastShadows[other] or 0 };
        end
    end
    local avatars = {};
    for master, a in pairs(track.avatars) do
        avatars[#avatars + 1] = {
            pet = a.pet, master = master, pactCe = a.pactCe, pactVe = a.pactVe, otherCe = a.otherCe, otherVe = a.otherVe,
        };
    end
    table.sort(avatars, function (a, b) return a.master < b.master; end);
    self.research:observe({
        mob = mob, target = id, switch = switch, clean = track.clean, covered = covered ~= nil, rule = self.shadowRule,
        loss = -self.actions.misc.shadowAbsorb.ce, rows = rows, avatars = avatars,
    });
    if since then
        self.research:charge(f.clock() - since);
    end
end

local function coveredBy(self, list, mob, coverer, member)
    local covered = self.covers[coverer];
    if covered == nil or not self.buffs:holds(self.world, coverer, member, 'cover', self.now) then
        return nil;
    end
    if holderOf(self, list, mob) ~= covered then
        return nil;
    end
    return covered;
end

local function lowered(self, list, mob, skill, target)
    local entry = self.mobskills[skill];
    local result = target.results[1];
    local landed = result ~= nil and not SKILL_MISSED[result.message];
    local applies = entry ~= nil and entry.effect ~= 'none' and (landed or not entry.conditional);
    if applies then
        list:lowerByPercent(target.id, entry.effect == 'reset' and 100 or entry.percent);
        cause(self, target.id, entry.effect == 'reset' and 'reset' or ('lowered %d%%'):format(entry.percent));
        if self.research then
            researchLowered(self, self.tracks[mob], target.id, entry.effect == 'reset' and 100 or entry.percent);
        end
    end
    if self.log then
        note(self, 'mobskill', {
            mob = mob, skill = skill, target = target.id, known = entry ~= nil, entry = entry and entry.name,
            effect = entry and entry.effect, percent = entry and entry.percent, conditional = entry and entry.conditional,
            trust = entry and entry.trust, message = result and result.message, landed = landed, applied = applies,
        });
    end
end

local function charmedBy(target)
    for _, result in ipairs(target.results) do
        if ENFEEB_IS[result.message] and CHARM[result.param] then
            return true;
        end
    end
    return false;
end

local function charmed(self, id)
    local mobs = self.log and {};
    for mob, list in pairs(self.lists) do
        if list:has(id) then
            list:setActive(id, false);
            if mobs then
                mobs[#mobs + 1] = mob;
            end
        end
    end
    if self.log then
        table.sort(mobs);
        note(self, 'charm', { id = id, mobs = mobs });
    end
end

local function taken(self, event, target, victim)
    local mob = event.actorId;
    local list = touch(self, mob);
    local modelled = victim.kind == 'alliance';

    if list ~= nil and modelled then
        list:setActive(target.id, true);
    end
    if modelled and charmedBy(target) then
        charmed(self, target.id);
    end

    local covered = nil;
    local surprised, switch, previous = false, false, nil;
    if event.category == CATEGORY_MELEE then
        list = list or listFor(self, mob);
        local track = self.tracks[mob];
        switch = switches(track, target.id);
        previous = track.holder;
        covered = modelled and coveredBy(self, list, mob, target.id, victim.member);
        if modelled and not covered then
            list:base(target.id);
        end
        if self.log then
            logTarget(self, list, mob, target.id, modelled, switch, covered, previous);
        end
        if self.research then
            researchObserve(self, list, mob, target.id, switch, covered);
        end
        if covered then
            setHolder(track, covered, true);
            if self.log then
                note(self, 'cover', { mob = mob, coverer = target.id, covered = covered });
            end
        elseif modelled then
            setHolder(track, target.id, true);
            surprised = witness(self, list, mob, target.id, switch, previous);
        else
            list:occupy(target.id, false);
            setHolder(track, target.id, false);
        end
    elseif event.category == CATEGORY_MAGIC and #event.targets == 1 then
        list = list or listFor(self, mob);
        local track = self.tracks[mob];
        switch = switches(track, target.id);
        previous = track.holder;
        if modelled then
            list:base(target.id);
        end
        if self.log then
            logTarget(self, list, mob, target.id, modelled, switch, nil, previous);
        end
        if self.research then
            researchObserve(self, list, mob, target.id, switch, nil);
        end
        setHolder(track, target.id, modelled);
        if modelled then
            surprised = witness(self, list, mob, target.id, switch, previous);
        end
    end
    if list ~= nil and not modelled and self.research and event.category == CATEGORY_MOBSKILL then
        local entry = self.mobskills[event.param];
        local result = target.results[1];
        if entry ~= nil and entry.effect ~= 'none' and ((result ~= nil and not SKILL_MISSED[result.message]) or not entry.conditional) then
            researchLowered(self, self.tracks[mob], target.id, entry.effect == 'reset' and 100 or entry.percent);
        end
    end
    if list == nil or not modelled then
        return;
    end
    fought(self, mob);

    local id, member = target.id, victim.member;
    local maxHP = self.world:maxHP(id);
    local reduction = nil;
    for _, result in ipairs(target.results) do
        local message = result.message;
        if DAMAGE[message] ~= nil and result.param > 0 then
            if covered then
                list:cover(covered, id);
                cause(self, id, 'cover', false);
                cause(self, covered, 'covered');
            elseif maxHP ~= nil and maxHP > 0 then
                reduction = reduction or self.buffs:lossReduction(self.world, id, member, self.now);
                list:attacked(id, result.param, maxHP, reduction);
                cause(self, id, 'damage');
                if self.log then
                    note(self, 'attacked', { mob = mob, id = id, damage = result.param, maxHP = maxHP, reduction = reduction });
                end
            elseif self.log then
                note(self, 'attacked', { mob = mob, id = id, damage = result.param, skipped = true });
            end
        elseif message == PARRY and self.buffs:holds(self.world, id, member, 'issekigan', self.now) then
            local mod = enmityOf(self, id, member);
            local mods = modsFor(self, self.rows and self.rows.passive, id, member, CLASS.melee, mod);
            list:add(id, ISSEKIGAN_CE, 0, mods, inRange(self, id, mob));
            cause(self, id, 'issekigan', mod);
            if self.log then
                note(self, 'parry', { mob = mob, id = id });
            end
        elseif message == SHADOW_ABSORB then
            absorb(self, list, mob, id, member, result.param, SHADOWS_CHARGED[event.category]);
        end
    end
    if event.category == CATEGORY_MOBSKILL then
        lowered(self, list, mob, event.param, target);
    end
    if surprised then
        reanchor(self, list, mob, id, switch, previous);
    end
end

local function healed(self, event, target, patient)
    local entry, mods = self.applying.entry, self.applying.mods;
    local level = memberLevel(self, patient.member) or DEFAULT_LEVEL;
    for _, result in ipairs(target.results) do
        if HEALED[result.message] then
            for mob, list in pairs(self.lists) do
                if list.claimed and list:has(target.id) then
                    touch(self, mob);
                    fought(self, mob);
                    local near = inRange(self, event.actorId, mob);
                    if entry.cure == 'fixed' then
                        local ce, ve, ceTrust, veTrust = valuesOf(self, entry);
                        list:cureFixed(event.actorId, ce, ve, mods, near);
                        tally(self, mob, event.actorId, near, ceTrust, veTrust);
                    else
                        list:cure(event.actorId, level, result.param, mods, near);
                    end
                end
            end
        end
    end
end

local function supported(self, event)
    local a = self.applying;
    for mob, list in pairs(self.lists) do
        if list.claimed and list:has(event.actorId) then
            touch(self, mob);
            fought(self, mob);
            local near = inRange(self, event.actorId, mob);
            list:add(event.actorId, a.ce, a.ve, a.mods, near);
            tally(self, mob, event.actorId, near, a.ceTrust, a.veTrust);
        end
    end
end

local function observeAction(self, event)
    local actor = resolve(self, event.actorId);
    if actor == nil then
        return;
    end

    local entry = prepare(self, event, actor).entry;
    local track = actor.kind == 'mob' and self.tracks[event.actorId];
    if track and event.category == CATEGORY_MOBSKILL then
        track.skill = event.param;
    end
    if actor.kind == 'alliance' then
        local id = event.actorId;
        self.dead[id] = nil;
        if abilityLike(event) and event.param == COVER and event.targets[1] ~= nil then
            self.covers[id] = event.targets[1].id;
        elseif abilityLike(event) and event.param == TRICK_ATTACK then
            self.tricks[id] = self.now + TRICK_ATTACK_DURATION;
        elseif abilityLike(event) and event.param == SNEAK_ATTACK then
            self.sneaks[id] = self.now + SNEAK_ATTACK_DURATION;
        elseif event.category == CATEGORY_MAGIC then
            castShadows(self, event, actor.member);
        end
    end

    for _, target in ipairs(event.targets) do
        local r = resolve(self, target.id);
        if r ~= nil then
            if r.kind == 'mob' and PLAYER_SIDE[actor.kind] then
                dealt(self, event, actor, target);
            elseif actor.kind == 'mob' and PLAYER_SIDE[r.kind] then
                taken(self, event, target, r);
            elseif entry ~= nil and PLAYER_SIDE[r.kind] then
                if entry.cure ~= nil and r.kind == 'alliance' then
                    healed(self, event, target, r);
                end
                supported(self, event);
            end
        end
    end

    if self.research and actor.kind == 'pet' and event.category == CATEGORY_PET_ABILITY then
        avatarPact(self, event);
    end
    if actor.kind == 'alliance' and abilityLike(event) then
        applyEffect(self, event, actor);
    end

    if SPENDS_TRICK_ATTACK[event.category] then
        self.tricks[event.actorId], self.sneaks[event.actorId] = nil, nil;
    end
    -- Taken from the track as it stands now: the action may have dropped the list.
    track = actor.kind == 'mob' and self.tracks[event.actorId];
    if track and event.category ~= CATEGORY_MOBSKILL then
        track.skill = nil;
    end
end

local function died(self, id)
    local r = resolve(self, id);
    if r == nil or r.kind ~= 'alliance' then
        return;
    end
    self.dead[id] = true;
    self.buffs:wear(id);
    self.shadows[id], self.covers[id], self.tricks[id], self.sneaks[id] = nil, nil, nil, nil;
    local cleared, inactive = self.log and {}, self.log and {};
    for mob, list in pairs(self.lists) do
        if list:has(id) then
            if holderOf(self, list, mob) == id then
                list:clear(id);
                if self.research then
                    self.tracks[mob].lastShadows[id] = nil;
                end
                if cleared then
                    cleared[#cleared + 1] = mob;
                end
            else
                list:setActive(id, false);
                if inactive then
                    inactive[#inactive + 1] = mob;
                end
            end
        end
    end
    if self.log then
        note(self, 'death', { id = id, cleared = cleared, inactive = inactive });
    end
end

local function observeMessage(self, event)
    local id = event.targetId;
    local mobDefeated, memberDied = DEFEATED[event.message], PLAYER_DEFEATED[event.message];
    if memberDied then
        died(self, id);
    end
    if mobDefeated then
        drop(self, id, 'defeated');
    end
    if not (mobDefeated or memberDied) then
        return;
    end
    for _, track in pairs(self.tracks) do
        if track.holder == id then
            setHolder(track, nil, false);
        end
    end
end

local function over(self, mob, track)
    local state = self.states[mob];
    if state == nil then
        return self.now - track.lastAction >= sim.STALE and 'stale' or nil;
    end
    return not state.engaged and self.now - math.max(state.since, track.lastAction) >= sim.GRACE and 'idle' or nil;
end

local function allDown(self)
    local world, any = self.world, false;
    for _, id in ipairs(world:alliance()) do
        local down = world:downed(id);
        if down == nil then
            down = self.dead[id] and true or nil;
        end
        if down == false then
            return false;
        end
        any = any or down == true;
    end
    return any;
end

local function dropLists(self, reason)
    if self.log then
        for mob in pairs(self.lists) do
            logFight(self, mob, reason);
        end
    end
    if self.filter ~= nil then
        for _, list in pairs(self.lists) do
            self.filter:release(list);
        end
    end
    self.lists = {};
    self.tracks = {};
    self.acting = {};
end

local function listCount(self)
    local n = 0;
    for _ in pairs(self.lists) do
        n = n + 1;
    end
    return n;
end

local function checkWipe(self)
    if not allDown(self) then
        self.downed = false;
    elseif not self.downed and next(self.lists) ~= nil then
        self.downed = true;
        self.wipes = self.wipes + 1;
        if self.log then
            note(self, 'wipe', { lists = listCount(self) });
        end
        dropLists(self, 'wipe');
    end
end

local function checkQuiet(self)
    local dropped = false;
    for mob, track in pairs(self.tracks) do
        if self.now - track.lastCombat > sim.QUIET then
            drop(self, mob, 'quiet');
            self.states[mob] = nil;
            dropped = true;
        end
    end
    -- Not a wipe: everyone is alive, the fighting just stopped.  It shares
    -- nothing with checkWipe's counter, which drives a chat line telling you
    -- the alliance is down.
    if dropped and next(self.lists) == nil and self.log then
        note(self, 'quiet', { lists = 0 });
    end
end

local decayLogged;
local restTicks;

local function decayAvatars(track, ticks)
    local amount = hatelist.DECAY_PER_TICK * ticks;
    for _, a in pairs(track.avatars) do
        local total = a.pactVe + a.otherVe;
        if total > 0 then
            local keep = math.max(0, total - amount) / total;
            a.pactVe, a.otherVe = a.pactVe * keep, a.otherVe * keep;
        end
    end
end

local function advance(self, now)
    local tick = math.floor(now / hatelist.TICK);
    if now > self.now then
        self.now = now;
    end
    if self.tick ~= nil and tick > self.tick then
        self.buffs:sample(self.world, self.now);
        checkWipe(self);
        checkQuiet(self);
        local ticks = tick - self.tick;
        for mob, list in pairs(self.lists) do
            local ended = over(self, mob, self.tracks[mob]);
            if ended then
                drop(self, mob, ended);
            else
                if self.log then
                    decayLogged(self, mob, list, ticks);
                else
                    list:decay(ticks);
                end
                if self.research then
                    decayAvatars(self.tracks[mob], ticks);
                end
            end
        end
    end
    local ticked = self.tick ~= nil and tick > self.tick;
    if self.tick == nil or tick > self.tick then
        self.tick = tick;
    end
    restTicks(self);
    return ticked;
end

local function snapshot(self)
    local out = {};
    for mob, list in pairs(self.lists) do
        local was = { version = list.version, values = {} };
        for _, id in ipairs(list.order) do
            local ce, ve, active = list:get(id);
            was.values[id] = { ce, ve, active };
        end
        out[mob] = was;
    end
    return out;
end

local function multiplier(mod)
    return (100 + math.max(-50, math.min(100, mod))) / 100;
end

local function file(track, id, key, dce, dve, mod)
    if track.ledger == nil then
        return;
    end
    local byKey = track.ledger[id];
    if byKey == nil then
        byKey = {};
        track.ledger[id] = byKey;
    end
    local sum = byKey[key];
    if sum == nil then
        sum = { n = 0, ce = 0, ve = 0 };
        byKey[key] = sum;
    end
    sum.n, sum.ce, sum.ve = sum.n + 1, sum.ce + dce, sum.ve + dve;

    local b = track.bounds[id];
    if b == nil then
        b = { ceLo = 0, ceHi = 0, veLo = 0, veHi = 0 };
        track.bounds[id] = b;
    end
    local scaled = mod and multiplier(mod) or 1;
    local lo, hi = mod and 0.5 / scaled or 1, mod and 2 / scaled or 1;
    b.ceLo = b.ceLo + (dce > 0 and dce * lo or dce);
    b.ceHi = b.ceHi + (dce > 0 and dce * hi or dce);
    b.veLo = b.veLo + (dve > 0 and dve * lo or dve);
    b.veHi = b.veHi + (dve > 0 and dve * hi or dve);
end

local function keyOf(self, event, id)
    if event.kind == 'rest' then
        return 'rest';
    elseif event.kind ~= 'action' then
        return PLAYER_DEFEATED[event.message] and 'death' or ('message %d'):format(event.message);
    end
    local category = event.category;
    local key = CATEGORY_NAMES[category] or ('category %d'):format(category);
    local entry = nil;
    if category == CATEGORY_MAGIC then
        entry = self.actions.spells[event.param];
    elseif abilityLike(event) then
        key = CATEGORY_NAMES[6];
        entry = self.actions.abilities[event.param];
    elseif category == CATEGORY_WEAPONSKILL then
        entry = self.actions.weaponskills[event.param];
    elseif category == CATEGORY_MOBSKILL then
        entry = self.mobskills[event.param];
    end
    if entry ~= nil then
        key = key .. ' ' .. entry.name;
    elseif category ~= CATEGORY_MELEE and category ~= CATEGORY_RANGED then
        key = ('%s #%d'):format(key, event.param);
    end
    if id ~= event.actorId then
        if self.applying.actorKind == 'mob' then
            key = 'taken ' .. key;
        else
            key = ('%s from %s'):format(key, self.names[event.actorId] or ('0x%08X'):format(event.actorId));
        end
    end
    local causes = self.causes and self.causes[id];
    if causes ~= nil and #causes > 0 then
        key = ('%s (%s)'):format(key, table.concat(causes, ', '));
    end
    return key;
end

local function modOf(self, event, id)
    local c = self.causes and self.causes[id];
    if c ~= nil and c.mod ~= nil then
        return c.mod;
    end
    if event.kind == 'rest' then
        return event.mod;
    end
    local a = self.applying;
    if event.kind == 'action' and id == event.actorId and a.actorKind == 'alliance' then
        return a.mod;
    end
    return false;
end

local function logChanges(self, before, event)
    local since = logClock(self);
    local lines = {};
    for mob, list in pairs(self.lists) do
        local was = before[mob];
        if was == nil or was.version ~= list.version then
            local track = self.tracks[mob];
            local changes, cleared = {}, nil;
            for _, id in ipairs(list.order) do
                local ce, ve, active = list:get(id);
                local old = was and was.values[id];
                local oldCe, oldVe = old and old[1] or 0, old and old[2] or 0;
                if old == nil or oldCe ~= ce or oldVe ~= ve or old[3] ~= active then
                    changes[#changes + 1] = { id, ce - oldCe, ve - oldVe, ce, ve, active };
                    file(track, id, keyOf(self, event, id), ce - oldCe, ve - oldVe, modOf(self, event, id));
                end
            end
            for id, old in pairs(was and was.values or {}) do
                if not list:has(id) then
                    cleared = cleared or {};
                    cleared[#cleared + 1] = id;
                    file(track, id, keyOf(self, event, id) .. ' (cleared)', -old[1], -old[2], false);
                    if track.bounds then
                        track.bounds[id] = nil;
                    end
                end
            end
            if #changes > 0 or cleared ~= nil then
                lines[#lines + 1] = {
                    mob = mob, actor = event.actorId, key = keyOf(self, event, event.actorId), changes = changes,
                    cleared = cleared,
                };
            end
        end
    end
    charge(self, since);
    for _, line in ipairs(lines) do
        note(self, 'enmity', line);
    end
end

local function restHeal(self, id, r)
    local who = resolve(self, id);
    if who == nil or who.kind ~= 'alliance' then
        self.rests[id] = nil;
        return;
    end
    local member = who.member;
    local level = memberLevel(self, member) or DEFAULT_LEVEL;
    local base, step = REST_BASE_HP, 1;
    if self.values ~= 'lsb' then
        local measured = r.signet and HORIZON_REST_SIGNET or HORIZON_REST;
        base, step = measured.base, measured.step;
    elseif r.signet then
        base, step = base + 3 * math.floor(level / 10), step + math.floor((r.maxHP or 0) / 300);
    end
    local hp = base + (r.ticks - 2) * step;
    local mod = enmityOf(self, id, member);
    local mods = modsFor(self, self.rows and self.rows.actor, id, member, CLASS.cure, mod);
    local before = nil;
    if self.log then
        local work = logClock(self);
        before = snapshot(self);
        self.causes = {};
        charge(self, work);
    end
    for mob, list in pairs(self.lists) do
        if list.claimed and list:has(id) then
            touch(self, mob);
            fought(self, mob);
            list:cure(id, level, hp, mods, inRange(self, id, mob));
        end
    end
    if before then
        logChanges(self, before, { kind = 'rest', actorId = id, mod = mod, tick = r.ticks, hp = hp });
        self.causes = nil;
    end
end

restTicks = function (self)
    for id, r in pairs(self.rests) do
        while self.rests[id] ~= nil and self.now - r.since >= REST_TICK * (r.ticks + 1) do
            r.ticks = r.ticks + 1;
            if r.ticks >= 2 then
                restHeal(self, id, r);
            end
        end
    end
end

decayLogged = function (self, mob, list, ticks)
    local since = logClock(self);
    local track, before = self.tracks[mob], {};
    for _, id in ipairs(list.order) do
        local _, ve = list:get(id);
        before[id] = ve;
    end
    list:decay(ticks);
    for _, id in ipairs(list.order) do
        local _, ve = list:get(id);
        if ve ~= before[id] then
            file(track, id, 'decay', 0, ve - before[id], false);
        end
    end
    charge(self, since);
end;

local function started(self)
    if self.filter == nil then
        return nil;
    end
    self.logCost = self.log and self.log.cost or 0;
    self.researchCost = self.research and self.research.cost or 0;
    return self.filter.clock();
end

local function finished(self, since)
    if since then
        local logged = self.log and (self.log.cost or 0) - self.logCost or 0;
        local researched = self.research and self.research.cost - self.researchCost or 0;
        self.filter:spend(self.filter.clock() - since - logged - researched);
    end
end

function sim:advance(now)
    local since = started(self);
    if advance(self, now) then
        finished(self, since);
    end
end

local function record(self, event, now)
    -- A refit's replay shares this ring and must not append to it: an entity update it records would evict what it has yet to replay.
    if self.refitting then
        return;
    end
    local h = self.history;
    if h.count == HISTORY then
        self.historyFrom = h.times[h.first];
        h.first = h.first % HISTORY + 1;
        h.count = h.count - 1;
    end
    local i = (h.first + h.count - 1) % HISTORY + 1;
    h.events[i], h.times[i] = event, now;
    h.count = h.count + 1;
end

local function trimHistory(self)
    -- A refit's replay shares this ring and must not trim it either: the
    -- fresh sim starts with no tracks, so a trim here would reset the ring
    -- the refit is still reading, and the loop would walk onto slots that
    -- were never written.
    if self.refitting then
        return;
    end
    local oldest = nil;
    for _, track in pairs(self.tracks) do
        if oldest == nil or track.opened < oldest then
            oldest = track.opened;
        end
    end
    local h = self.history;
    if oldest == nil then
        h.first, h.count = 1, 0;
        self.historyFrom = self.now;
        return;
    end
    local keepFrom = oldest - HISTORY_MARGIN;
    while h.count > 0 and h.times[h.first] < keepFrom do
        h.first = h.first % HISTORY + 1;
        h.count = h.count - 1;
    end
end

local function applyEntity(self, id, animation, despawned, hpp)
    if ANIMATION_DEAD[animation] then
        if self.states[id] or self.lists[id] then
            record(self, { entity = id, animation = animation, despawned = false }, self.now);
            if self.log then
                note(self, 'mob', { mob = id, dead = true });
            end
        end
        drop(self, id, 'dead');
        self.states[id] = nil;
        return;
    elseif despawned then
        if self.states[id] or self.lists[id] then
            record(self, { entity = id, animation = nil, despawned = true }, self.now);
            if self.log then
                note(self, 'mob', { mob = id, despawned = true });
            end
        end
        self.states[id] = nil;
        local track = self.tracks[id];
        if track ~= nil then
            track.clean, track.complete = false, false;
        end
        return;
    elseif animation == nil then
        return;
    end

    local engaged = animation == ANIMATION_ENGAGED;
    local state = self.states[id];
    if state == nil or state.engaged ~= engaged then
        record(self, { entity = id, animation = animation, despawned = false, hpp = hpp }, self.now);
        if self.log then
            note(self, 'mob', { mob = id, engaged = engaged, hpp = hpp });
        end
    end
    if state == nil then
        self.states[id] = { engaged = engaged, since = self.now, seenIdle = not engaged, hpp = hpp };
    elseif state.engaged ~= engaged then
        if not engaged then
            drop(self, id, 'disengaged');
        end
        state.engaged, state.since, state.hpp = engaged, self.now, hpp;
        state.seenIdle = state.seenIdle or not engaged;
    end
end

-- Static per-entity data, not an event: it never enters the history, and a
-- refit's fresh sim is handed the table wholesale.
function sim:observeHitbox(id, hitbox)
    if hitbox == nil or self.hitboxes[id] == hitbox then
        return;
    end
    self.hitboxes[id] = hitbox;
    if self.log then
        note(self, 'hitbox', { id = id, hitbox = hitbox });
    end
end

function sim:observeEntity(id, animation, despawned, now, hpp, hitbox)
    local since = started(self);
    advance(self, now);
    self:observeHitbox(id, hitbox);
    applyEntity(self, id, animation, despawned, hpp);
    finished(self, since);
    trimHistory(self);
end

local function replayWorld(world)
    return {
        resolve = function (_, id) return world:resolve(id); end,
        maxHP = function (_, id) return world:maxHP(id); end,
        alliance = function () return world:alliance(); end,
        zone = function () return world.zone and world:zone() or nil; end,
        wearing = function (_, id, item) return world:wearing(id, item); end,
        inCombat = function (_, id) return world:inCombat(id); end,
        petOwner = function (_, id) return world:petOwner(id); end,
        distance = function () return nil; end,
        position = function () return nil; end,
        hasBuff = function () return nil; end,
        downed = function () return nil; end,
    };
end

local function deepCopy(v)
    if type(v) ~= 'table' then
        return v;
    end
    local out = {};
    for k, x in pairs(v) do
        out[k] = deepCopy(x);
    end
    return out;
end

local function refit(self)
    local pending = self.pendingRefit;
    self.pendingRefit = nil;
    local f = self.filter;
    local since, spent = f.clock(), f.spent;
    local widened = { pending.target };
    f:widen(pending.target);
    if pending.leader ~= nil and pending.leader ~= pending.target and f:widen(pending.leader) then
        widened[#widened + 1] = pending.leader;
    end
    if self.opts.refitScope == 'list' then
        local list = self.lists[pending.mob];
        for _, id in ipairs(list and list.order or {}) do
            if id ~= pending.target and id ~= pending.leader and list.entries[id].active and f:widen(id) then
                widened[#widened + 1] = id;
            end
        end
    end
    f:resetWeights();
    for _, list in pairs(self.lists) do
        f:release(list);
    end

    local opts = {};
    for k, v in pairs(self.opts) do
        opts[k] = v;
    end
    local kept = {};
    opts.log = self.log and {
        cost = 0,
        write = function (_, kind, fields)
            if kind == 'discontinuity' or kind == 'gap' or kind == 'impossible' then
                kept[#kept + 1] = { kind, deepCopy(fields) };
            end
        end,
        charge = function () end,
    };
    opts.research, opts.shadowRule, opts.values = nil, self.shadowRule, self.values;
    local fresh = sim.new(replayWorld(self.world), opts);
    for _, field in ipairs({ 'cap', 'levelRange', 'regions', 'actions', 'mobskills', 'scriptedMobs', 'conditional', 'ruleKeys', 'effects', 'gear' }) do
        fresh[field] = self[field];
    end
    fresh.refitting = true;
    fresh.history = self.history;
    for id, hb in pairs(self.hitboxes) do
        fresh.hitboxes[id] = hb;
    end
    for id, r in pairs(self.rests) do
        fresh.rests[id] = { since = r.since, ticks = r.ticks, signet = r.signet, maxHP = r.maxHP };
    end
    for id, state in pairs(self.states) do
        -- Without this the replayed opener loses the first-engage bonus: the mob was idle when the replay starts.
        local list = self.lists[id];
        local engaged = state.engaged;
        if list ~= nil and not list.others[UNSEEN] then
            engaged = false;
        end
        fresh.states[id] = { engaged = engaged, since = state.since, seenIdle = state.seenIdle, hpp = state.hpp };
    end
    local h = self.history;
    local count = h.count;
    for k = 0, count - 1 do
        local i = (h.first + k - 1) % HISTORY + 1;
        local event, at = h.events[i], h.times[i];
        if event.entity ~= nil then
            fresh:observeEntity(event.entity, event.animation, event.despawned, at, event.hpp);
        elseif event.rest ~= nil then
            fresh:observeRest(event.rest, event.resting, at, { signet = event.signet, maxHP = event.maxHP });
        else
            fresh:observe(event, at);
        end
    end
    h.count = count;

    for _, field in ipairs({ 'lists', 'tracks', 'states', 'acting', 'covers', 'tricks', 'sneaks', 'shadows', 'dead', 'buffs', 'tick', 'now' }) do
        self[field] = fresh[field];
    end
    for id, name in pairs(fresh.names) do
        self.names[id] = name;
    end
    for _, gap in ipairs(fresh.gaps) do
        self.gaps[#self.gaps + 1] = gap;
    end
    self:setLog(self.log);
    self:setResearch(self.research);
    self.refits = self.refits + 1;
    f.spent = spent;
    if self.log then
        local track = self.tracks[pending.mob];
        note(self, 'refit', {
            mob = pending.mob, name = self.names[pending.mob], target = pending.target, leader = pending.leader,
            switch = pending.switch, run = pending.run, widened = widened, events = count, refits = self.refits,
            anchored = track and track.anchored, explained = track ~= nil and track.anchored == 0,
            ms = (f.clock() - since) * 1000,
        });
        for _, line in ipairs(kept) do
            note(self, line[1], line[2]);
        end
    end
end

function sim:observe(event, now)
    if not self.refitting then
        record(self, event, now);
    end
    local since = started(self);
    advance(self, now);
    local before = nil;
    if self.log then
        local work = logClock(self);
        before = snapshot(self);
        self.causes, self.ranged = {}, {};
        charge(self, work);
    end
    if event.kind == 'action' then
        observeAction(self, event);
    elseif event.kind == 'message' then
        observeMessage(self, event);
    end
    if before then
        logChanges(self, before, event);
        self.causes, self.ranged = nil, nil;
    end
    finished(self, since);
    if self.pendingRefit ~= nil then
        refit(self);
    end
    trimHistory(self);
end

local function signetFor(self, id)
    local world = self.world;
    local zone = world.zone and world:zone();
    local region = zone and self.regions[zone];
    if region == nil then
        return false;
    end
    local status = nil;
    if region <= REGION_LIMBUS then
        status = SIGNET;
    elseif region >= REGION_FIRST_FRONT and region <= REGION_LAST_FRONT then
        status = SIGIL;
    else
        return false;
    end
    local has = world:hasBuff(id, status);
    if has == nil then
        return true;
    end
    return has == true;
end

function sim:observeRest(id, resting, now, seen)
    if seen == nil then
        seen = { signet = signetFor(self, id), maxHP = self.world:maxHP(id) };
    end
    if not self.refitting then
        record(self, { rest = id, resting = resting, signet = seen.signet, maxHP = seen.maxHP }, now);
    end
    local since = started(self);
    advance(self, now);
    local r = self.rests[id];
    if resting and r == nil then
        self.rests[id] = { since = now, ticks = 0, signet = seen.signet, maxHP = seen.maxHP };
        if self.log then
            note(self, 'rest', { id = id, resting = true, signet = seen.signet, maxHP = seen.maxHP });
        end
    elseif not resting and r ~= nil then
        self.rests[id] = nil;
        if self.log then
            note(self, 'rest', { id = id, resting = false, ticks = r.ticks });
        end
    end
    finished(self, since);
    trimHistory(self);
end

function sim:list(mob)
    return self.lists[mob];
end

function sim:mobs()
    local out = {};
    for mob in pairs(self.lists) do
        out[#out + 1] = mob;
    end
    table.sort(out);
    return out;
end

function sim:view(mob)
    local list = self.lists[mob];
    if list == nil or self.filter == nil then
        return list;
    end
    return self.filter:view(list);
end

function sim:track(mob)
    return self.tracks[mob];
end

function sim:engaged(mob)
    local list = self.lists[mob];
    return list ~= nil and list:count() > 0;
end

function sim:name(id)
    return self.names[id];
end

local function forget(self, reason)
    dropLists(self, reason);
    self.states = {};
end

local function copyTable(t)
    local out = {};
    for k, v in pairs(t) do
        out[k] = v;
    end
    return out;
end

function sim:export()
    local now = self.now;
    local lists, tracks, states, tricks, sneaks = {}, {}, {}, {}, {};
    for mob, list in pairs(self.lists) do
        local t = self.tracks[mob];
        lists[mob] = list:export();
        tracks[mob] = {
            clean = t.clean, anchored = t.anchored, skill = t.skill, holder = t.holder,
            holderModelled = t.holderModelled, lastAction = now - t.lastAction, lastCombat = now - t.lastCombat,
            opened = now - t.opened, complete = t.complete, trust = t.trust, lastShadows = t.lastShadows,
            avatars = t.avatars, researched = t.researched,
        };
    end
    for mob, s in pairs(self.states) do
        states[mob] = { engaged = s.engaged, since = now - s.since, seenIdle = s.seenIdle, hpp = s.hpp };
    end
    for id, ends in pairs(self.tricks) do
        tricks[id] = ends - now;
    end
    for id, ends in pairs(self.sneaks) do
        sneaks[id] = ends - now;
    end
    return {
        lists = lists, tracks = tracks, states = states, tricks = tricks, sneaks = sneaks,
        acting = copyTable(self.acting), covers = copyTable(self.covers), shadows = self.shadows,
        dead = copyTable(self.dead), names = copyTable(self.names), buffs = self.buffs:export(now),
        wipes = self.wipes, downed = self.downed,
    };
end

function sim:import(saved, now, elapsed)
    local base = now - (elapsed or 0);
    self.now = base;
    self.tick = math.floor(base / hatelist.TICK);
    self.historyFrom = now;
    local count = 0;
    for mob, savedList in pairs(saved.lists or {}) do
        local t = (saved.tracks or {})[mob];
        if type(mob) == 'number' and type(savedList) == 'table' and type(t) == 'table' then
            local list = self.filter and self.filter:newList(self.cap) or hatelist.new(self.cap);
            list:import(savedList);
            self.lists[mob] = list;
            self.tracks[mob] = {
                clean = t.clean == true, anchored = tonumber(t.anchored) or 0, skill = t.skill, holder = t.holder,
                holderModelled = t.holderModelled == true, acting = 0,
                lastAction = base - (tonumber(t.lastAction) or 0), lastCombat = base - (tonumber(t.lastCombat) or 0),
                opened = base - (tonumber(t.opened) or 0), complete = t.complete == true, trust = t.trust or {},
                ledger = self.log and {}, bounds = self.log and {}, impossible = self.log and {},
                lastShadows = self.research and (t.lastShadows or {}), avatars = self.research and (t.avatars or {}),
                researched = self.research ~= nil and t.researched == true,
            };
            count = count + 1;
        end
    end
    for mob, s in pairs(saved.states or {}) do
        if type(mob) == 'number' and type(s) == 'table' then
            self.states[mob] = {
                engaged = s.engaged == true, since = base - (tonumber(s.since) or 0), seenIdle = s.seenIdle == true,
                hpp = tonumber(s.hpp),
            };
        end
    end
    for id, mob in pairs(saved.acting or {}) do
        if self.tracks[mob] ~= nil then
            self.acting[id] = mob;
            self.tracks[mob].acting = self.tracks[mob].acting + 1;
        end
    end
    for id, left in pairs(saved.tricks or {}) do
        if type(left) == 'number' then
            self.tricks[id] = base + left;
        end
    end
    for id, left in pairs(saved.sneaks or {}) do
        if type(left) == 'number' then
            self.sneaks[id] = base + left;
        end
    end
    for _, field in ipairs({ 'covers', 'shadows', 'dead', 'names' }) do
        for k, v in pairs(saved[field] or {}) do
            self[field][k] = v;
        end
    end
    self.buffs:import(saved.buffs, base);
    self.wipes = tonumber(saved.wipes) or 0;
    self.downed = saved.downed == true;
    if self.log then
        note(self, 'restore', { lists = count, elapsed = elapsed or 0, mobs = self:mobs() });
    end
    return count;
end

function sim:reset()
    forget(self, 'reset');
end

function sim:setShadowRule(rule)
    rule = rule == 'era' and 'era' or 'lsb';
    if rule == self.shadowRule then
        return;
    end
    self.shadowRule = rule;
    for _, track in pairs(self.tracks) do
        track.researched = false;
    end
    if self.research ~= nil then
        self.research:setLive('shadowAbsorb', rule);
    end
end

function sim:setValues(tier)
    self.values = tier == 'lsb' and 'lsb' or 'era';
end

function sim:setLog(log)
    self.log = log;
    for _, track in pairs(self.tracks) do
        track.ledger = log and (track.ledger or {}) or nil;
        track.bounds = log and (track.bounds or {}) or nil;
        track.impossible = log and (track.impossible or {}) or nil;
    end
end

function sim:setResearch(research)
    self.research = research;
    for _, track in pairs(self.tracks) do
        track.lastShadows = research and (track.lastShadows or {}) or nil;
        track.avatars = research and (track.avatars or {}) or nil;
        track.researched = false;
    end
end

function sim:clear()
    forget(self, 'zone');
    self.tricks = {};
    self.sneaks = {};
    self.dead = {};
    self.rests = {};
end

return sim;

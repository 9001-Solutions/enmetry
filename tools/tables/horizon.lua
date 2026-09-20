--[[
* Enmity rules curated by hand: Horizon's changes, and the few era or LSB
* facts the generated tables can't read off a column.
*
* Every entry cites its sources and quotes them.  Regeneration fails if a
* quote is no longer found in the vendored wiki snapshot or at the pinned
* LandSandBoat commit, so a source that stops saying something can't leave a
* stale number behind.  Quotes match the page's plain text or its raw
* wikitext, with whitespace collapsed.
*
*   sources = { { wiki = page, [section], quotes }, { lsb = path, quotes } }
*   trust   = era unless the source itself hedges
--]]

local CHANGES = 'Category:Horizon Changes';

return {
    -- Era table names whose cure enmity is fixed, whatever HP is healed, even
    -- where LSB runs them through the HP formula.
    fixedCures = {
        {
            key = 'fixedCures', names = { 'Cure V', 'Exuviation' },
            sources = { {
                wiki = 'Enmity Table',
                quotes = { 'Cure V and Exuviation are exceptions (HP cured does not affect enmity values)' },
            } },
        },
    },

    -- Unconditional replacements of an action's base CE/VE.
    actions = {
        {
            -- The era table measured 1800 VE: LSB's 900 doubled by Sentinel's own
            -- +100, which the server applies before the ability's enmity.  Kept as
            -- the base so a sub PLD's +50, or other Enmity, scales it correctly.
            kind = 'abilities', name = 'sentinel', ve = 900,
            sources = {
                { wiki = 'Sentinel', quotes = { 'This ability gives +100 equipment enmity for its duration' } },
                { lsb = 'sql/abilities.sql', quotes = { "(48,'sentinel',7,30,1,300,75,0,0,11,2000,0,6,0,0,0,1,900,772,0,NULL)" } },
                {
                    lsb = 'src/map/entities/char_entity.cpp',
                    quotes = { 'int32 value = luautils::OnUseAbility(this, PTarget, PAbility, &action);', 'state.ApplyEnmity();' },
                },
            },
        },
        {
            kind = 'spells', name = 'hojo_ni', ce = 40, ve = 450,
            sources = { {
                wiki = CHANGES, section = 'Hojo:Ni',
                quotes = { 'Hojo: Ni provides +40 cumulative enmity (CE) and +450 volatile enmity (VE).' },
            } },
        },
        {
            kind = 'spells', name = 'kurayami_ni', ce = 40, ve = 450,
            sources = { {
                wiki = CHANGES, section = 'Kurayami:Ni',
                quotes = { 'Kurayami: Ni provides +40 cumulative enmity (CE) and +450 volatile enmity (VE).' },
            } },
        },
    },

    -- Enmity-relevant status effects: the abilities that grant them, and their
    -- durations for when the buff itself can't be read.
    buffs = {
        {
            key = 'sentinel', status = 'sentinel', kind = 'abilities', names = { 'sentinel' }, mainJob = 'PLD', enmity = 100, duration = 30,
            sources = { {
                wiki = 'Sentinel',
                quotes = { 'This ability gives +100 equipment enmity for its duration', 'duration = 30 seconds' },
            } },
        },
        {
            -- Only a Paladin main can cast it.  It wears off by hits as well
            -- as time, so the hits themselves say whether it is up: each
            -- landed swing carries its light damage as an added effect of
            -- kind 7, LightDamage in LandSandBoat's proc_kind.h.
            key = 'enlight', status = 'enlight', kind = 'spells', names = { 'enlight' }, mainJob = 'PLD', enmity = 10, duration = 180, proc = 7,
            sources = { {
                wiki = 'Enlight',
                quotes = {
                    'Provides enmity +10.',
                    'base duration = 180 seconds',
                    'decreases by 1 damage per successful hit.  The effect expires automatically when the damage reaches zero.',
                },
            } },
        },
        {
            -- The wiki marks this {{verification}}.
            key = 'sentinelSub', status = 'sentinel', kind = 'abilities', names = { 'sentinel' }, subJob = 'PLD', enmity = 50, duration = 30, trust = 'unknown',
            sources = { { wiki = 'Sentinel', quotes = { '+50 enmity if Paladin is subjob.' } } },
        },
        {
            key = 'yonin', status = 'yonin', kind = 'abilities', names = { 'yonin' }, mainJob = 'NIN', enmity = 10, duration = 300,
            sources = {
                { wiki = CHANGES, section = 'Yonin', quotes = { 'increase enmity by 10' } },
                { wiki = 'Yonin', quotes = { 'duration = 5 minutes', 'Cannot be used with Ninja as a support job.' } },
            },
        },
        {
            key = 'defender', status = 'defender', kind = 'abilities', names = { 'defender' }, lossReduction = 25, duration = 180,
            sources = {
                {
                    wiki = CHANGES, section = 'Defender',
                    quotes = { 'Defender provides -25% enmity loss reduction when taking damage (works with WAR sub job).' },
                },
                { wiki = 'Defender', quotes = { 'duration = 3 minutes' } },
            },
        },
        {
            -- Carries no enmity of its own: the sim reads this key to apply a DRK main's Muted Soul rank while it is up.
            key = 'souleater', status = 'souleater', kind = 'abilities', names = { 'souleater' }, duration = 60,
            sources = {
                {
                    wiki = 'Souleater',
                    quotes = {
                        'duration = 1 minute',
                        'Each merit into Muted Soul will decrease the amount of enmity from, exclusively, Souleater damage by a -enmity value of 10.',
                    },
                },
                {
                    lsb = 'src/map/enmity_container.cpp',
                    quotes = {
                        'if (PChar->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::Souleater))',
                        'enmityBonus -= PChar->PMeritPoints->GetMeritValue(xi::Merit::MutedSoul, PChar);',
                        'float bonus = (100.0f + std::clamp(enmityBonus, -50, 100)) / 100.0f;',
                    },
                },
            },
        },
    },

    -- Changes to an action's enmity that hold only in some state.
    conditional = {
        {
            key = 'provokeDefender', kind = 'abilities', names = { 'provoke' }, requires = 'defender',
            job = 'WAR', ceMain = 250, ceSub = 180,
            sources = { {
                wiki = CHANGES, section = 'Provoke',
                quotes = {
                    'Provoke now receives an additional 250 cumulative enmity (CE) when Defender is active and Warrior is set as the main job.',
                    'This number is reduced to +180 when Warrior is set as the support job.',
                },
            } },
        },
        {
            -- LSB behaviour Horizon inherits: the base values are replaced, not added to.
            key = 'utsusemiYonin', kind = 'spells', names = { 'utsusemi_ichi', 'utsusemi_ni', 'utsusemi_san' },
            requires = 'yonin', ce = 160, ve = 480, trust = 'lsb',
            sources = { {
                lsb = 'src/map/ai/states/magic_state.cpp',
                quotes = { 'm_PSpell->getSpellFamily() == SPELLFAMILY_UTSUSEMI', 'ce = 160; ve = 480;' },
            } },
        },
        {
            key = 'rdmEnfeebling', mainJob = 'RDM', skill = 'enfeebling', percent = -30,
            sources = { {
                wiki = CHANGES,
                quotes = { '30% reduction in enmity gained from casting Enfeebling Magic while your main job is Red Mage.' },
            } },
        },
        {
            -- Moves enmity from the Thief to the target rather than scaling it.
            key = 'collaborator', kind = 'abilities', names = { 'collaborator' }, transfer = 50,
            sources = { {
                wiki = CHANGES, section = 'Collaborator',
                quotes = { "redirects 50% of the Thief's enmity to their chosen target" },
            } },
        },
    },

    -- Enmity gear whose value or condition Horizon changed.
    gear = {
        {
            item = 15544, name = 'sattva_ring', enmity = 5,
            sources = { {
                wiki = 'Sattva Ring',
                quotes = { '{{HorizonChangesBox|{{stat|Enmity|+5}} instead of {{stat|Enmity|+3}}' },
            } },
        },
        {
            item = 13437, name = 'healers_earring', enmity = -2, subJob = 'WHM',
            sources = {
                {
                    wiki = "Healer's Earring",
                    quotes = { '{{stat|Latent Effect:}}<br>{{stat|Enmity|-2}}', 'Active while White Mage is set as your Support Job.' },
                },
                { lsb = 'sql/item_latents.sql', quotes = { 'VALUES (13437,27,-1,8,3);' } },
            },
        },
        {
            -- Renamed Healer's Belt on Horizon; LSB still calls it mace_belt.
            item = 15273, name = 'mace_belt', enmity = -2, subJob = 'WHM',
            sources = {
                {
                    wiki = CHANGES,
                    quotes = { "Mace Belt has been renamed to Healer's Belt, and its latent effect was changed from Club Skill +5 to Enmity -2." },
                },
                { lsb = 'sql/item_latents.sql', quotes = { 'VALUES (15273,90,5,8,3);' } },
            },
        },
    },

    -- Avatar: Enmity gear.  It scales the avatar's own enmity, not the
    -- summoner's, which is what confounds the avatar share (DESIGN.md section 10).
    -- Evoker's Spats is left out: its page doesn't say whether its Enmity-2
    -- is the avatar's.
    avatarGear = {
        { item = 12520, name = 'evokers_horn', avatarEnmity = -3,
          sources = { { wiki = "Evoker's Horn", quotes = { '{{stat|avatar}} {{stat|Enmity|-3}}' } } } },
        { item = 12650, name = 'evokers_doublet', avatarEnmity = -2,
          sources = { { wiki = "Evoker's Doublet", quotes = { '{{stat|avatar}} {{stat|Enmity|-2}}' } } } },
        { item = 13975, name = 'evokers_bracers', avatarEnmity = -2,
          sources = { { wiki = "Evoker's Bracers", quotes = { '{{stat|avatar}} {{stat|Enmity|-2}}' } } } },
        { item = 14103, name = 'evokers_pigaches', avatarEnmity = -2,
          sources = { { wiki = "Evoker's Pigaches", quotes = { '{{stat|avatar}} {{stat|Enmity|-2}}' } } } },
        { item = 15239, name = 'evokers_horn_+1', avatarEnmity = -3,
          sources = { { wiki = "Evoker's Horn +1", quotes = { "'''[[Avatar]]:''' {{stat|Enmity|-3}}" } } } },
        { item = 14904, name = 'evokers_bracers_+1', avatarEnmity = -2,
          sources = { { wiki = "Evoker's Bracers +1", quotes = { '{{stat|Avatar}} {{stat|Enmity|-2}}' } } } },
        { item = 15366, name = 'evokers_pigaches_+1', avatarEnmity = -4,
          sources = { { wiki = "Evoker's Pigaches +1", quotes = { '{{stat|Avatar}} {{stat|Enmity|-4}}' } } } },
        { item = 15679, name = 'summoners_pigaches_+1', avatarEnmity = 2,
          sources = { { wiki = "Summoner's Pigaches +1", quotes = { '{{stat|Avatar}} {{stat|Enmity|+2}}' } } } },
        { item = 15594, name = 'summoners_spats_+1', avatarEnmity = 2,
          sources = { { wiki = "Summoner's Spats +1", quotes = { '{{stat|Avatar}}: {{stat|Enmity|+2}}' } } } },
    },

    -- Documented as changing enmity, with no number given.  Listed so they are
    -- known gaps rather than silent ones.
    -- What an ability does to its user's own enmity, beyond the base values
    -- an ability carries.  LSB behaviour Horizon inherits.
    effects = {
        {
            -- The gear modifier HIGH_JUMP_ENMITY_REDUCTION can't be seen and is left out.
            key = 'highJump', kind = 'abilities', names = { 'high_jump' }, job = 'DRG', lowerMain = 50, lowerSub = 30, trust = 'lsb',
            sources = { {
                lsb = 'scripts/globals/job_utils/dragoon.lua',
                quotes = {
                    'local enmityShed = 50',
                    'if player:getMainJob() ~= xi.job.DRG then enmityShed = 30',
                    'target:lowerEnmity(player, enmityShed + player:getMod(xi.mod.HIGH_JUMP_ENMITY_REDUCTION))',
                },
            } },
        },
        {
            -- Under Spirit Surge it also resets the closest party member behind
            -- the dragoon, which isn't modelled.
            key = 'superJump', kind = 'abilities', names = { 'super_jump' }, setCe = 1, setVe = 0, range = 75, trust = 'lsb',
            sources = { {
                lsb = 'scripts/globals/job_utils/dragoon.lua',
                quotes = {
                    'if mob:isMob() and mob:checkDistance(player) <= 75.0 then mob:setCE(player, 1) mob:setVE(player, 0)',
                },
            } },
        },
    },

    unquantified = {
        {
            key = 'magicBurst',
            sources = { {
                wiki = CHANGES, section = 'Magic Burst',
                quotes = { 'reduced enmity generation, except on notorious monsters.' },
            } },
        },
        {
            key = 'camouflage',
            sources = { {
                wiki = CHANGES, section = 'Camouflage',
                quotes = { 'Camouflage grants an enmity reduction on the next attack.' },
            } },
        },
    },
};

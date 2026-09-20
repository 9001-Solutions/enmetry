--[[
* Base CE/VE for every job ability and spell, merged from three sources in
* rising precedence:
*
*   lsb      abilities.sql / spell_list.sql columns, plus the fixed values a
*            spell script passes to updateEnmityFromCure
*   era      the HorizonXI wiki Enmity Table (Kaeko's era testing)
*   horizon  deltas from tools/tables/horizon.lua
*
* Trust is tracked per value, because the era table often verifies only one
* of CE and VE:
*
*   era      measured in era, or documented as Horizon's own value
*   lsb      LandSandBoat's value with nothing to corroborate it
*   unknown  LandSandBoat leaves both columns at their 0 default, which can't
*            be told apart from never having been filled in
--]]

local actions = {};

-- Column positions in the SQL rows.
local COLUMNS = {
    abilities = { ce = 17, ve = 18 },
    spells = { ce = 20, ve = 21 },
};

-- Misc. Actions rows are constants of the model, not abilities.
local MISC = {
    ['First Action (Pull)'] = 'firstEngage',
    ['Utsu Shadow Loss'] = 'shadowAbsorb',
    ['Blink Shadow Loss'] = 'blinkAbsorb',
    ['Using an Item'] = 'item',
    ['Evading an Attack'] = 'evade',
    ['Mob Aggro'] = 'aggro',
    ['/Heal Command'] = 'heal',
    ['/Sit Command'] = 'sit',
};

--[[
* Folds a display name or an LSB script name to the same key:
* "Hojo: Ni" and "hojo_ni" are both "hojoni".
--]]
function actions.normalize(name)
    return (name:lower():gsub('[^%w]', ''));
end

local function uncommented(text)
    return (text:gsub('%-%-[^\n]*', ''));
end

--[[
* The helper functions in a job_utils file whose bodies generate cure
* enmity.  An ability script that calls one is a cure, one call removed.
*
* @param {string} text - A scripts/globals file.
* @return {table} Fully qualified function names, in file order.
--]]
function actions.cureFunctions(text)
    local names, current, cures = {}, nil, false;
    local function flush()
        if current ~= nil and cures then
            names[#names + 1] = current;
        end
    end
    for line in (uncommented(text) .. '\n'):gmatch('(.-)\r?\n') do
        local name = line:match('^([%w_%.]+)%s*=%s*function') or line:match('^function%s+([%w_%.:]+)');
        if name ~= nil or line:match('^local%s+function') then
            flush();
            current, cures = name, false;
        elseif line:find('updateEnmityFromCure', 1, true) then
            cures = true;
        end
    end
    flush();
    return names;
end

--[[
* How a spell or ability script generates cure enmity, if it does.  Fixed
* values replace the HP-based formula entirely (enmity_container.cpp
* UpdateEnmityFromCure).
*
* @param {string} text - The script.
* @param {table|nil} helpers - Names from cureFunctions, any of which the
*   script may call instead.
* @return {table|nil} { formula = true }, { ce, ve }, or nil for a non-cure.
--]]
function actions.cure(text, helpers)
    local code = uncommented(text);
    local ce, ve = code:match('updateEnmityFromCure%s*%([^,]+,[^,]+,%s*(%d+)%s*,%s*(%d+)%s*%)');
    if ce ~= nil then
        return { ce = tonumber(ce), ve = tonumber(ve) };
    end
    if code:find('updateEnmityFromCure', 1, true) or code:find('useCuringSpell', 1, true) then
        return { formula = true };
    end
    for _, name in ipairs(helpers or {}) do
        if code:find(name .. '(', 1, true) then
            return { formula = true };
        end
    end
    return nil;
end

--[[
* The fixed enmity a weaponskill script passes in place of its damage's:
* params.overrideCE and params.overrideVE, which weaponskills.lua hands to
* addEnmity whenever a hit lands, instead of updateEnmityFromDamage.
*
* @param {string} text - A scripts/actions/weaponskills file.
* @return {table|nil} { ce, ve }, or nil for a weaponskill without both.
--]]
function actions.weaponskillOverride(text)
    local code = uncommented(text);
    local ce = code:match('params%.overrideCE%s*=%s*(%d+)');
    local ve = code:match('params%.overrideVE%s*=%s*(%d+)');
    if ce == nil or ve == nil then
        return nil;
    end
    return { ce = tonumber(ce), ve = tonumber(ve) };
end

--[[
* The id of the one action of a kind whose name normalises to the given
* name.  Curated rules name actions; this is how they become ids, and it
* errors rather than pick when zero or several match.
--]]
function actions.lookup(built, kind, name)
    local matches = built.index[kind] and built.index[kind][actions.normalize(name)];
    if matches == nil or #matches ~= 1 then
        error(('%s %q matches %d entries, expected exactly 1'):format(kind, name, matches and #matches or 0), 0);
    end
    return matches[1].id;
end

local function fromSql(kind, rows, cures)
    local entries, byKey = {}, {};
    local col = COLUMNS[kind];
    for _, row in ipairs(rows) do
        local id, name = row[1], row[2];
        local ce, ve = row[col.ce], row[col.ve];
        local e = { id = id, name = name };
        local cure = cures[name];
        if cure ~= nil and cure.formula then
            e.cure = 'formula';
        elseif cure ~= nil then
            e.cure = 'fixed';
            ce, ve = ce + cure.ce, ve + cure.ve;
        end
        e.ce, e.ve = ce, ve;
        e.lsb = { ce = ce, ve = ve };
        local trust = (ce == 0 and ve == 0 and e.cure == nil) and 'unknown' or 'lsb';
        e.ceTrust, e.veTrust = trust, trust;

        entries[id] = e;
        local key = actions.normalize(name);
        byKey[key] = byKey[key] or {};
        table.insert(byKey[key], e);
    end
    return entries, byKey;
end

--[[
* @param {table} input
*   abilities, spells  SQL rows
*   cures              [kind][script name] = { formula = true } or { ce, ve }
*   fixedByEra         era table names whose cure enmity ignores HP healed
*   era                wiki.enmityTable() result
*   aliases            [wiki name] = LSB name, for spellings normalising misses
*   deltas             { kind, name, [ce], [ve], [trust], source, ... }
*   weaponskills       weapon_skills SQL rows
*   overrides          [script name] = { ce, ve } from weaponskillOverride
* @return {table} { abilities, spells, weaponskills, misc, unmatched,
*   malformed, ambiguous, index }
--]]
function actions.build(input)
    local out = { misc = {}, unmatched = {}, malformed = input.era.malformed, ambiguous = {}, index = {} };
    local index = out.index;
    for _, kind in ipairs({ 'abilities', 'spells' }) do
        out[kind], index[kind] = fromSql(kind, input[kind], input.cures[kind] or {});
    end
    out.weaponskills = {};
    for _, row in ipairs(input.weaponskills or {}) do
        local id, name = row[1], row[2];
        local override = (input.overrides or {})[name];
        if override ~= nil then
            out.weaponskills[id] = {
                id = id, name = name, ce = override.ce, ve = override.ve, ceTrust = 'lsb', veTrust = 'lsb',
                lsb = { ce = override.ce, ve = override.ve },
            };
        end
    end
    local fixed = {};
    for _, name in ipairs(input.fixedByEra or {}) do
        fixed[name] = true;
    end

    for _, row in ipairs(input.era.rows) do
        local misc = MISC[row.name];
        if row.section == 'Misc. Actions' and misc ~= nil then
            out.misc[misc] = { ce = row.ce, ve = row.ve, trust = 'era', wiki = row.name };
        else
            local key = actions.normalize((input.aliases or {})[row.name] or row.name);
            -- The era table lists player actions.  A name that is also a
            -- spell is the spell: the ability sharing it is an avatar's or a
            -- jug pet's (Sleepga, Thunderstorm, Sheep Song).
            local matches = index.spells[key] or index.abilities[key] or {};
            if #matches == 0 then
                out.unmatched[#out.unmatched + 1] = row.name;
            elseif #matches > 1 then
                out.ambiguous[#out.ambiguous + 1] = row.name;
            end
            for _, e in ipairs(matches) do
                e.era = { ce = row.ce, ve = row.ve };
                e.wiki = row.name;
                if row.ce ~= nil then
                    e.ce, e.ceTrust = row.ce, 'era';
                end
                if row.ve ~= nil then
                    e.ve, e.veTrust = row.ve, 'era';
                end
                if row.section == 'Multiple Targets' then
                    e.perTarget = true;
                end
                if fixed[row.name] and e.cure ~= nil then
                    e.cure = 'fixed';
                end
            end
        end
    end

    for _, d in ipairs(input.deltas or {}) do
        local e = out[d.kind][actions.lookup(out, d.kind, d.name)];
        if d.ce ~= nil then
            e.ce, e.ceTrust = d.ce, d.trust or 'era';
        end
        if d.ve ~= nil then
            e.ve, e.veTrust = d.ve, d.trust or 'era';
        end
        e.delta = d;
    end

    for _, kind in ipairs({ 'abilities', 'spells' }) do
        for _, e in pairs(out[kind]) do
            if e.lsb.ce ~= e.ce or e.lsb.ve ~= e.ve then
                e.lsbCe, e.lsbVe = e.lsb.ce, e.lsb.ve;
            end
        end
    end

    return out;
end

return actions;

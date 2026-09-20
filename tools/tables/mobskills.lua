--[[
* Classifies LandSandBoat mobskill scripts by what they do to the hate list.
*
*   reset   mob:resetEnmity(target) -- LowerEnmityByPercent(target, 100), CE
*           and VE both zeroed for the player hit
*   reduce  mob:lowerEnmity(target, N) -- both lowered by N percent
*   none    the script never touches enmity
*
* Any other enmity call (addEnmity, updateEnmity, a reset on someone else's
* list) doesn't fit those three.  It is recorded as 'none' at trust 'unknown'
* with the call named, rather than guessed at.
*
* A call indented deeper than the function body sits under some condition,
* usually "if the move landed".  LSB's formatter enforces four-space indents,
* so indentation is a faithful read of nesting.
--]]

local mobskills = {};

local CALL = '([%w_%.]+):(%a*[Ee]nmity%a*)%s*%(([^)]*)%)';

--[[
* @param {string} text - One mobskill script.
* @return {table} { effect, trust, [percent], [conditional], [line], [call] }
--]]
function mobskills.classify(text)
    local calls, body = {}, nil;
    local n = 0;
    for line in (text .. '\n'):gmatch('(.-)\r?\n') do
        n = n + 1;
        local code = line:gsub('%-%-.*$', '');
        if body == nil and code:match('onMobWeaponSkill') then
            body = #code:match('^(%s*)') + 4;
        end
        for receiver, method, args in code:gmatch(CALL) do
            calls[#calls + 1] = {
                receiver = receiver, method = method, args = args, line = n,
                indent = #code:match('^(%s*)'),
            };
        end
    end

    if #calls == 0 then
        return { effect = 'none', trust = 'lsb' };
    end

    local first = calls[1];
    if #calls == 1 and first.receiver == 'mob' then
        local conditional = body ~= nil and first.indent > body;
        if first.method == 'resetEnmity' and first.args:match('^%s*target%s*$') then
            return { effect = 'reset', trust = 'lsb', conditional = conditional, line = first.line };
        end
        local percent = first.args:match('^%s*target%s*,%s*(%d+)%s*$');
        if first.method == 'lowerEnmity' and percent ~= nil then
            return {
                effect = 'reduce', percent = tonumber(percent), trust = 'lsb',
                conditional = conditional, line = first.line,
            };
        end
    end
    return {
        effect = 'none', trust = 'unknown',
        call = first.receiver .. ':' .. first.method, line = first.line,
    };
end

--[[
* @param {table} rows - mob_skills rows: id, animation id, script name, ...
* @param {table} scripts - Script text by script name.
* @return {table} { skills = { [id] = entry }, missing = { name } }
*   Ids with no script are left out: absent means unknown, never 'none'.
--]]
function mobskills.build(rows, scripts)
    local skills, missing, noted = {}, {}, {};
    for _, row in ipairs(rows) do
        local id, name = row[1], row[3];
        local text = scripts[name];
        if text == nil then
            if not noted[name] then
                noted[name] = true;
                missing[#missing + 1] = name;
            end
        else
            local entry = mobskills.classify(text);
            entry.id, entry.name = id, name;
            skills[id] = entry;
        end
    end
    return { skills = skills, missing = missing };
end

--[[
* Whether a zone mob script lowers enmity itself: some mobs reset hate from a
* WEAPONSKILL_USE listener or a timer rather than from the mobskill script
* (Flockbock's Petribreath, Purson's Great Whirlwind).
*
* @param {string} text - A scripts/zones/<zone>/mobs/<mob>.lua file.
* @param {table|nil} enum - skillEnum() result, for xi.mobSkill.NAME ids.
* @return {table|nil} { line, skills } with the first resetEnmity or
*   lowerEnmity call and every mobskill id the script compares getID() to,
*   or nil when it makes neither call.
--]]
function mobskills.mobScript(text, enum)
    local found, skills, n = nil, {}, 0;
    for line in (text .. '\n'):gmatch('(.-)\r?\n') do
        n = n + 1;
        local code = line:gsub('%-%-.*$', '');
        if found == nil and (code:match('[%w_]+:resetEnmity%s*%(') or code:match('[%w_]+:lowerEnmity%s*%(')) then
            found = n;
        end
        for id in code:gmatch('getID%(%)%s*==%s*(%d+)') do
            skills[#skills + 1] = tonumber(id);
        end
        for name in code:gmatch('getID%(%)%s*==%s*xi%.mobSkill%.([%w_]+)') do
            local id = (enum or {})[name];
            if id == nil then
                error(('xi.mobSkill.%s is not in the enum'):format(name), 0);
            end
            skills[#skills + 1] = id;
        end
    end
    if found == nil then
        return nil;
    end
    return { line = found, skills = skills };
end

--[[
* @param {string} text - scripts/enum/mob_skill.lua.
* @return {table} [NAME] = mobskill id.
--]]
function mobskills.skillEnum(text)
    local ids = {};
    for name, id in text:gmatch('\n%s+([%u%d_]+)%s*=%s*(%d+)') do
        ids[name] = tonumber(id);
    end
    return ids;
end

--[[
* Takes the confidence out of 'none' for every skill a mob script resets on.
* The skill may well do nothing in general; on that mob it doesn't.
*
* @param {table} built - mobskills.build() result, changed in place.
* @param {table} scripts - { mob, line, skills } per mob script.
--]]
function mobskills.applyMobScripts(built, scripts)
    for _, s in ipairs(scripts) do
        for _, id in ipairs(s.skills) do
            local entry = built.skills[id];
            if entry ~= nil and entry.effect == 'none' and entry.trust == 'lsb' then
                entry.trust = 'unknown';
                entry.call = ('%s.lua:%d resets on it'):format(s.mob, s.line);
            end
        end
    end
end

return mobskills;

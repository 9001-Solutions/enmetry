--[[
* Turns the curated rules in horizon.lua into the overlays.lua table: names
* become ids, every quote is checked, and each section's fields are listed
* once here for both resolving and writing.
--]]

local actions = require('tables.actions');
local cite = require('tables.cite');
local sql = require('tables.sql');

local overlays = {};

-- Sections in output order: the field each is keyed by, then its fields.
local SECTIONS = {
    { name = 'buffs', key = 'key', fields = { 'status', 'abilities', 'spells', 'proc', 'mainJob', 'subJob', 'enmity', 'lossReduction', 'duration' } },
    { name = 'conditional', key = 'key',
      fields = { 'abilities', 'spells', 'requires', 'mainJob', 'skill', 'ce', 've', 'job', 'ceMain', 'ceSub', 'percent', 'transfer' } },
    { name = 'gear', key = 'item', fields = { 'name', 'enmity', 'subJob' } },
    { name = 'avatarGear', key = 'item', fields = { 'name', 'avatarEnmity' } },
    { name = 'effects', key = 'key', fields = { 'abilities', 'job', 'lowerMain', 'lowerSub', 'setCe', 'setVe', 'range' } },
    { name = 'unquantified', key = 'key', fields = {} },
};
overlays.SECTIONS = SECTIONS;

local GROUPS = { 'actions', 'fixedCures' };
for _, s in ipairs(SECTIONS) do
    GROUPS[#GROUPS + 1] = s.name;
end

--[[
* A section's written fields, trust last.
--]]
function overlays.fields(name)
    for _, s in ipairs(SECTIONS) do
        if s.name == name then
            local fields = { unpack(s.fields) };
            fields[#fields + 1] = 'trust';
            return fields;
        end
    end
    error('no overlay section ' .. name, 2);
end

--[[
* @param {string} text - data/status_effects.yaml.
* @return {table} [name] = status effect id.
--]]
function overlays.statusIds(text)
    local ids, current = {}, nil;
    for line in text:gmatch('[^\r\n]+') do
        current = line:match('^  ([%w_]+):%s*$') or current;
        local id = line:match('^    id:%s*(%d+)');
        if id ~= nil and current ~= nil then
            ids[current] = tonumber(id);
        end
    end
    return ids;
end

--[[
* @param {string} text - sql/item_basic.sql.
* @return {table} [item id] = LSB item name.
--]]
function overlays.itemNames(text)
    local names = {};
    for _, row in ipairs(sql.rows(text, 'item_basic')) do
        names[row[1]] = row[3];
    end
    return names;
end

--[[
* Every wiki page and LSB file any curated rule cites.
*
* @return {table, table} Sorted unique wiki titles, sorted unique LSB paths.
--]]
function overlays.sources(rules)
    local seen, titles, paths = {}, {}, {};
    for _, group in ipairs(GROUPS) do
        for _, rule in ipairs(rules[group] or {}) do
            for _, source in ipairs(rule.sources) do
                local list, name = titles, source.wiki;
                if name == nil then
                    list, name = paths, source.lsb;
                end
                if not seen[list] then
                    seen[list] = {};
                end
                if not seen[list][name] then
                    seen[list][name] = true;
                    list[#list + 1] = name;
                end
            end
        end
    end
    table.sort(titles);
    table.sort(paths);
    return titles, paths;
end

local function fail(rule, message)
    error(('%s: %s'):format(rule.key or rule.name or '?', message), 0);
end

--[[
* @param {table} rules - horizon.lua.
* @param {table} ctx - { pages, files, actions (actions.build result),
*   statusIds, itemNames }
* @return {table} [section] = sequence of resolved rules, each carrying its
*   key, its fields, trust, and source (the curated rule, for citing).
--]]
function overlays.resolve(rules, ctx)
    local out = {};
    for _, section in ipairs(SECTIONS) do
        local list = {};
        for _, rule in ipairs(rules[section.name] or {}) do
            cite.verify(rule, ctx.pages, ctx.files);

            local key = rule[section.key];
            if type(key) == 'string' and not key:match('^[%a_][%w_]*$') then
                fail(rule, 'key is not a Lua identifier');
            end
            local r = { key = key, source = rule, trust = rule.trust or 'era' };
            for _, f in ipairs(section.fields) do
                r[f] = rule[f];
            end

            if rule.status ~= nil then
                r.status = ctx.statusIds[rule.status] or fail(rule, ('no status effect %q'):format(rule.status));
            end
            if rule.kind ~= nil then
                local ids = {};
                for _, name in ipairs(rule.names) do
                    ids[#ids + 1] = actions.lookup(ctx.actions, rule.kind, name);
                end
                r[rule.kind] = ids;
            end
            if section.key == 'item' and ctx.itemNames[rule.item] ~= rule.name then
                fail(rule, ('item %d is %s in LSB'):format(rule.item, tostring(ctx.itemNames[rule.item])));
            end
            list[#list + 1] = r;
        end
        out[section.name] = list;
    end
    return out;
end

return overlays;

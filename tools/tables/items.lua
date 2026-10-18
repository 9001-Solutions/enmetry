--[[
* Every item with an Enmity modifier, from LandSandBoat's item_mods and
* item_latents, with Horizon's curated gear rules written over the top.
--]]

local sql = require('tables.sql');

local items = {};

-- data/enums/mod.yaml: enmity 27.
items.ENMITY = 27;
-- data/enums/latent.yaml: subjob 8, the one latent condition the addon can read.
items.LATENT_SUBJOB = 8;

-- data/enums/job.yaml, by id.
items.JOBS = {
    'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG',
    'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO', 'RUN',
};

--[[
* @param {string} text - data/enums/latent.yaml.
* @return {table} [id] = latent name.
--]]
function items.latentNames(text)
    local names = {};
    for line in text:gmatch('[^\r\n]+') do
        local name, id = line:match('^  ([%w_]+):%s*(%d+)');
        if name ~= nil then
            names[tonumber(id)] = name;
        end
    end
    return names;
end

--[[
* @param {table} ctx - { itemMods, itemLatents (sql text), itemNames ([id] = name),
*   latentNames ([id] = name), gear (overlays.resolve's gear list) }
* @return {table} built - { byId = { [id] = { name, enmity, latentEnmity, subJob, trust, lsbEnmity, lsbLatentEnmity, horizon } },
*   skipped = { { id, name, enmity, latent, param } }, counts }
--]]
function items.build(ctx)
    local byId, skipped = {}, {};
    local function entry(id)
        local e = byId[id];
        if e == nil then
            e = { name = ctx.itemNames[id] or ('item_%d'):format(id), trust = 'lsb' };
            byId[id] = e;
        end
        return e;
    end
    for _, row in ipairs(sql.rows(ctx.itemMods, 'item_mods')) do
        if row[2] == items.ENMITY then
            local e = entry(row[1]);
            e.enmity = (e.enmity or 0) + row[3];
        end
    end
    for _, row in ipairs(sql.rows(ctx.itemLatents, 'item_latents')) do
        if row[2] == items.ENMITY then
            local id, value, latent, param = row[1], row[3], row[4], row[5];
            if latent == items.LATENT_SUBJOB and items.JOBS[param] ~= nil then
                local e = entry(id);
                e.latentEnmity, e.subJob = (e.latentEnmity or 0) + value, items.JOBS[param];
            else
                skipped[#skipped + 1] = {
                    id = id, name = ctx.itemNames[id] or ('item_%d'):format(id), enmity = value,
                    latent = ctx.latentNames[latent] or tostring(latent), param = param,
                };
            end
        end
    end
    local flat, latents = 0, 0;
    for _, e in pairs(byId) do
        e.lsbEnmity, e.lsbLatentEnmity = e.enmity, e.latentEnmity;
        if e.enmity ~= nil then
            flat = flat + 1;
        end
        if e.latentEnmity ~= nil then
            latents = latents + 1;
        end
    end
    for _, rule in ipairs(ctx.gear or {}) do
        local e = entry(rule.key);
        e.name, e.trust, e.horizon = rule.name, rule.trust, rule;
        if rule.subJob ~= nil then
            e.latentEnmity, e.subJob = rule.enmity, rule.subJob;
        else
            e.enmity = rule.enmity;
        end
    end
    table.sort(skipped, function (a, b) return a.id < b.id end);
    return { byId = byId, skipped = skipped, flat = flat, latents = latents };
end

return items;

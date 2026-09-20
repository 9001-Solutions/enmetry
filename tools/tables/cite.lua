--[[
* Checks that each curated rule's quotes are still in its sources.
--]]

local wiki = require('tables.wiki');

local cite = {};

local function squash(s)
    return (s:gsub('%s+', ' '));
end

local function fail(entry, message)
    error(('%s: %s'):format(entry.key or entry.name or '?', message), 0);
end

--[[
* @param {table} entry - A horizon.lua entry with sources.
* @param {table} pages - [title] = { text } wiki snapshots.
* @param {table} files - [path] = contents at the pinned LSB commit.
--]]
function cite.verify(entry, pages, files)
    if entry.sources == nil or #entry.sources == 0 then
        fail(entry, 'cites no source');
    end
    for _, source in ipairs(entry.sources) do
        local haystacks;
        if source.wiki ~= nil then
            local page = pages[source.wiki];
            if page == nil then
                fail(entry, ('no snapshot of wiki page %q'):format(source.wiki));
            end
            local text = page.text;
            if source.section ~= nil then
                text = wiki.section(text, source.section);
                if text == nil then
                    fail(entry, ('wiki page %q has no section %q'):format(source.wiki, source.section));
                end
            end
            haystacks = { squash(text), wiki.plain(text) };
        else
            local text = files[source.lsb];
            if text == nil then
                fail(entry, ('LSB file %s was not read'):format(source.lsb));
            end
            haystacks = { squash(text) };
        end

        for _, quote in ipairs(source.quotes) do
            local found = false;
            for _, h in ipairs(haystacks) do
                found = found or h:find(squash(quote), 1, true) ~= nil;
            end
            if not found then
                fail(entry, ('quote no longer in %s: %q'):format(source.wiki or source.lsb, quote));
            end
        end
    end
end

--[[
* One line naming where a source is, for comments in the generated files.
--]]
function cite.describe(source, pages)
    if source.lsb ~= nil then
        return 'LandSandBoat ' .. source.lsb;
    end
    local page = pages[source.wiki];
    local line = ('%s r%d'):format(page.url, page.revision);
    if source.section ~= nil then
        line = line .. ', section ' .. source.section;
    end
    return line;
end

return cite;

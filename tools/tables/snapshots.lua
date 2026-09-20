--[[
* Vendored HorizonXI wiki pages.
*
* The wiki is edited constantly, so regeneration never reads it live.  Pages
* are snapshotted at a known revision into tools/tables/sources/horizonwiki/
* with a manifest, and only --fetch-wiki ever replaces them.
--]]

local emit = require('tables.emit');

local snapshots = {};

snapshots.DIR = 'tools/tables/sources/horizonwiki/';
snapshots.MANIFEST = snapshots.DIR .. 'manifest.lua';
snapshots.SITE = 'https://horizonffxi.wiki';

local USER_AGENT = 'enmetry-gentables';

function snapshots.file(title)
    return (title:gsub('[:\'"%s]', '_')) .. '.wiki';
end

function snapshots.url(title)
    return snapshots.SITE .. '/' .. title:gsub(' ', '_');
end

local function readFile(path)
    local f = io.open(path, 'rb');
    if f == nil then
        return nil;
    end
    local text = f:read('*a');
    f:close();
    return text;
end

--[[
* @return {table} [title] = { file, revision, timestamp }
--]]
function snapshots.manifest()
    local text = readFile(snapshots.MANIFEST);
    if text == nil then
        return {};
    end
    return assert(loadstring(text, snapshots.MANIFEST))();
end

--[[
* @return {table} [title] = { text, revision, timestamp, url }.  Errors if a
*   title has no snapshot: run with --fetch-wiki.
--]]
function snapshots.load(titles)
    local manifest = snapshots.manifest();
    local pages = {};
    for _, title in ipairs(titles) do
        local m = manifest[title];
        local text = m and readFile(snapshots.DIR .. m.file);
        if text == nil then
            error(('no wiki snapshot of %q; run luajit tools/gentables.lua --fetch-wiki'):format(title), 0);
        end
        pages[title] = {
            text = text, revision = m.revision, timestamp = m.timestamp, url = snapshots.url(title),
        };
    end
    return pages;
end

local function curl(url)
    local p = assert(io.popen(('curl -sfL --compressed -A "%s" "%s"'):format(USER_AGENT, url), 'rb'));
    local body = p:read('*a');
    p:close();
    -- -f makes an HTTP error an empty body; pclose can't report it.
    if body == '' then
        error('fetch failed: ' .. url, 0);
    end
    return body;
end

local function query(title)
    return title:gsub('[^%w%-_%.~:]', function (c) return ('%%%02X'):format(c:byte()); end);
end

--[[
* Snapshots each title at its current revision and rewrites the manifest.
* The content is fetched by revision id, so it matches the revision recorded.
--]]
function snapshots.fetch(titles)
    local manifest = snapshots.manifest();
    for _, title in ipairs(titles) do
        local q = query(title);
        local meta = curl(snapshots.SITE .. '/w/api.php?action=query&prop=revisions&rvprop=ids%7Ctimestamp&format=json&titles=' .. q);
        local revision = meta:match('"revid"%s*:%s*(%d+)');
        local timestamp = meta:match('"timestamp"%s*:%s*"([^"]+)"');
        if revision == nil then
            error(('wiki has no page %q'):format(title), 0);
        end
        local text = curl(('%s/w/index.php?title=%s&action=raw&oldid=%s'):format(snapshots.SITE, q, revision));
        local file = snapshots.file(title);
        local f = assert(io.open(snapshots.DIR .. file, 'wb'));
        f:write(text);
        f:close();
        manifest[title] = { file = file, revision = tonumber(revision), timestamp = timestamp };
        print(('fetched %s r%s'):format(title, revision));
    end

    local sorted = {};
    for title in pairs(manifest) do
        sorted[#sorted + 1] = title;
    end
    table.sort(sorted);
    local out = {
        emit.header({
            'HorizonXI wiki snapshots, written by luajit tools/gentables.lua --fetch-wiki.',
            'Each page is the raw wikitext of the revision recorded here.',
        }),
        'return {',
    };
    for _, title in ipairs(sorted) do
        out[#out + 1] = ('    [%s] = %s,'):format(emit.string(title),
            emit.inline(manifest[title], { 'file', 'revision', 'timestamp' }));
    end
    out[#out + 1] = '};\n';
    local f = assert(io.open(snapshots.MANIFEST, 'wb'));
    f:write(table.concat(out, '\n'));
    f:close();
end

return snapshots;

--[[
* Scores the research registry's hypotheses against the attacks the addon
* logged to research.jsonl, and writes the posterior beside it as
* research.lua, which the addon's readout shows.  See addon/research.lua for
* the questions, the hypotheses and how an attack is scored.
*
* Run from the repo root:
*   luajit tools/research.lua <path/to/research.jsonl> [--server <name>] [--min-version <v>] [--no-write]
*
* Without a path, the log under $ENMETRY_ASHITA/config/addons/enmetry/ is
* read.  --server keeps only the sessions played on one server, since the
* answers may differ between them; --min-version leaves out sessions from
* addon versions before the one given, whose model may since have changed.
* Everything stays on this machine.
--]]

package.path = './addon/?.lua;./tools/?.lua;' .. package.path;

local json = require('json');
local research = require('research');

local tool = {};

--[[
* Reads a log.
*
* @param {string|nil} server - Keep only sessions on this server, as the
*   session lines name it.
* @param {string|nil} minVersion - Keep only sessions from this addon
*   version on, as "0.1.0"; an older addon's model may have been wrong in
*   ways since fixed.
* @return {table|nil, string|nil} events (entry key -> the fields of each
*   observation line), sessions, skipped (sessions left out), versions
*   (version -> sessions seen, before any filter), lines, and bad (lines
*   that couldn't be read); or nil and why.
--]]
function tool.read(path, server, minVersion)
    local fh = io.open(path, 'rb');
    if fh == nil then
        return nil, 'cannot read ' .. path;
    end
    local out = { events = {}, sessions = 0, skipped = 0, versions = {}, lines = 0, bad = 0 };
    for _, key in ipairs(research.ORDER) do
        out.events[key] = {};
    end
    local keep = server == nil and minVersion == nil;
    for line in fh:lines() do
        if line:find('%S') then
            out.lines = out.lines + 1;
            local ok, v = pcall(json.decode, line);
            if not ok or type(v) ~= 'table' then
                out.bad = out.bad + 1;
            elseif v.k == 'session' then
                local version = tostring(v.version);
                out.versions[version] = (out.versions[version] or 0) + 1;
                keep = (server == nil or v.server == server)
                    and (minVersion == nil or tool.compareVersions(version, minVersion) >= 0);
                if keep then
                    out.sessions = out.sessions + 1;
                else
                    out.skipped = out.skipped + 1;
                end
            elseif keep and v.k == 'observation' and out.events[v.entry] ~= nil then
                local events = out.events[v.entry];
                events[#events + 1] = v;
            end
        end
    end
    fh:close();
    return out;
end

--[[
* Orders dotted version strings by their numeric parts, so "0.10.0" is after
* "0.2.0"; anything without digits sorts before everything.
*
* @return {number} Negative, zero or positive as a is before, at or after b.
--]]
function tool.compareVersions(a, b)
    local function parts(v)
        local out = {};
        for n in tostring(v):gmatch('%d+') do
            out[#out + 1] = tonumber(n);
        end
        return out;
    end
    local pa, pb = parts(a), parts(b);
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0;
        if x ~= y then
            return x - y;
        end
    end
    return 0;
end

--[[
* Fits every entry and says how the hypotheses compare: the posterior, and
* each one's log likelihood against the hypothesis the addon runs.
*
* @return {table, table} The report's lines, and entry key -> fit.
--]]
function tool.report(path, read)
    local versions = {};
    for version in pairs(read.versions) do
        versions[#versions + 1] = version;
    end
    table.sort(versions, function (a, b) return tool.compareVersions(a, b) < 0; end);
    for i, version in ipairs(versions) do
        versions[i] = ('%s x%d'):format(version, read.versions[version]);
    end
    local out = {
        ('%s: %d lines, %d sessions%s%s'):format(path, read.lines, read.sessions,
            read.skipped > 0 and (', %d left out'):format(read.skipped) or '',
            read.bad > 0 and (', %d unreadable'):format(read.bad) or ''),
        ('  addon versions seen: %s'):format(#versions > 0 and table.concat(versions, ', ') or 'none'),
    };
    local fits = {};
    for _, key in ipairs(research.ORDER) do
        local entry = research.entries[key];
        local fit = research.fit(entry, read.events[key]);
        fits[key] = fit;
        out[#out + 1] = '';
        out[#out + 1] = ('%s -- %s'):format(key, entry.question);
        out[#out + 1] = ('  %d observations, %d of them switches; the addon runs %s by default'):format(fit.n, fit.switches, entry.live);
        if fit.n == 0 then
            out[#out + 1] = '  nothing to score yet';
        else
            out[#out + 1] = ('  posterior  log-lik vs %-5s hypothesis'):format(entry.live);
            for _, h in ipairs(research.ranked(entry, fit)) do
                out[#out + 1] = ('  %8.1f%%  %+15.2f  %s: %s%s'):format(fit.posterior[h] * 100,
                    fit.loglik[h] - fit.loglik[entry.live], h, entry.describe[h], h == entry.live and ' (default)' or '');
            end
        end
    end
    return out, fits;
end

-- research.lua beside the log.
function tool.posteriorPath(path)
    return (path:match('^(.*[/\\])') or '') .. 'research.lua';
end

local USAGE = 'usage: luajit tools/research.lua <research.jsonl> [--server <name>] [--min-version <v>] [--no-write]\n';

function tool.main(argv)
    local path, write, server, minVersion = nil, true, nil, nil;
    local i = 1;
    while i <= #argv do
        local a = argv[i];
        if a == '--no-write' then
            write = false;
        elseif a == '--server' and argv[i + 1] ~= nil then
            server = argv[i + 1];
            i = i + 1;
        elseif a == '--min-version' and argv[i + 1] ~= nil then
            minVersion = argv[i + 1];
            i = i + 1;
        elseif a:sub(1, 1) == '-' then
            io.stderr:write(USAGE);
            return 2;
        else
            path = a;
        end
        i = i + 1;
    end
    if path == nil then
        local ashita = os.getenv('ENMETRY_ASHITA');
        if ashita == nil then
            io.stderr:write(USAGE);
            return 2;
        end
        path = ashita:gsub('[/\\]$', '') .. '/config/addons/enmetry/research.jsonl';
    end
    local read, err = tool.read(path, server, minVersion);
    if read == nil then
        io.stderr:write(err .. '\n');
        return 1;
    end
    local lines, fits = tool.report(path, read);
    print(table.concat(lines, '\n'));
    if write then
        local out = tool.posteriorPath(path);
        local fh = io.open(out, 'wb');
        if fh == nil then
            io.stderr:write('cannot write ' .. out .. '\n');
            return 1;
        end
        fh:write(research.serialize(fits, os.time()));
        fh:close();
        print('');
        print('posterior written to ' .. out);
    end
    return 0;
end

if arg ~= nil and arg[0] ~= nil and arg[0]:find('tools[/\\]research%.lua$') then
    os.exit(tool.main(arg));
end

return tool;

--[[
* Reads files from a LandSandBoat checkout at one pinned commit, straight out
* of git's object store.  The working tree's branch, edits and untracked files
* never enter into it, so the same commit always yields the same bytes.
--]]

local lsb = {};
lsb.__index = lsb;

-- A command's whole output.  LuaJIT's pclose doesn't report the exit status,
-- so callers judge success by what came back.
local function run(command)
    local p = assert(io.popen(command, 'rb'));
    local out = p:read('*a');
    p:close();
    return out;
end

--[[
* @param {string} dir - The checkout.
* @param {string} commit - Full commit hash.
* @return {table|nil, string} A reader, or nil and why not.
--]]
function lsb.open(dir, commit)
    local self = setmetatable({ dir = dir, commit = commit }, lsb);
    local date = run(('git -C "%s" show -s --format=%%cs "%s^{commit}" 2>&1'):format(dir, commit));
    if not date:match('^%d%d%d%d%-%d%d%-%d%d') then
        return nil, ('commit %s not found in %s'):format(commit, dir);
    end
    self.date = date:match('^(%S+)');
    return self;
end

--[[
* Every file path under a directory at the commit, sorted.
--]]
function lsb:list(prefix)
    local out = run(('git -C "%s" ls-tree -r --name-only %s -- "%s"'):format(self.dir, self.commit, prefix));
    local paths = {};
    for path in out:gmatch('[^\n]+') do
        paths[#paths + 1] = path;
    end
    table.sort(paths);
    return paths;
end

--[[
* The contents of many files in one git process.
*
* @param {table} paths - Repo-relative paths.
* @return {table} [path] = contents.  Errors if any path is missing.
--]]
function lsb:read(paths)
    local list = os.tmpname();
    local f = assert(io.open(list, 'wb'));
    for _, path in ipairs(paths) do
        f:write(self.commit, ':', path, '\n');
    end
    f:close();

    local p = assert(io.popen(('git -C "%s" cat-file --batch < "%s"'):format(self.dir, list), 'rb'));
    local files = {};
    for _, path in ipairs(paths) do
        local header = p:read('*l') or '';
        local size = header:match('^%x+ blob (%d+)$');
        if size == nil then
            p:close();
            os.remove(list);
            error(('%s: %s'):format(path, header), 0);
        end
        files[path] = p:read(tonumber(size));
        p:read(1);
    end
    p:close();
    os.remove(list);
    return files;
end

return lsb;

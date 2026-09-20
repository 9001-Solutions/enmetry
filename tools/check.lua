--[[
* Compiles every Lua file without running it.  The nearest thing Lua has to a
* typecheck: catches syntax errors in modules no test happens to load.
*
* Run from the repo root: luajit tools/check.lua
--]]

local failures, count = 0, 0;

local listing = io.popen('git ls-files --cached --others --exclude-standard "*.lua"');
for path in listing:lines() do
    count = count + 1;
    local chunk, err = loadfile(path);
    if chunk == nil then
        failures = failures + 1;
        print('FAIL  ' .. err);
    end
end
listing:close();

print(('%d files compiled, %d failed'):format(count, failures));
os.exit(failures == 0 and 0 or 1);

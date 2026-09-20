--[[
* Runs every test file, each in its own interpreter so globals one file stubs
* (test_load stands up a fake Ashita) cannot leak into another.
*
* Run from the repo root: luajit tests/run.lua
--]]

local FILES = {
    'tests/test_log.lua',
    'tests/test_packets.lua',
    'tests/test_world.lua',
    'tests/test_feed.lua',
    'tests/test_hatelist.lua',
    'tests/test_filter.lua',
    'tests/test_calibration.lua',
    'tests/test_research.lua',
    'tests/test_options.lua',
    'tests/test_priors.lua',
    'tests/test_profiles.lua',
    'tests/test_levels.lua',
    'tests/test_sim.lua',
    'tests/test_focus.lua',
    'tests/test_bars.lua',
    'tests/test_commands.lua',
    'tests/test_store.lua',
    'tests/test_load.lua',
    'tests/test_gentables.lua',
    'tests/test_tables.lua',
};

local interpreter = arg[-1] or 'luajit';
local failures = 0;

for _, file in ipairs(FILES) do
    io.write(('%-28s '):format(file));
    io.flush();
    local ok = os.execute(('"%s" %s'):format(interpreter, file));
    -- LuaJIT returns the exit status as a number; 5.2+ returns a boolean.
    if not (ok == true or ok == 0) then
        failures = failures + 1;
    end
end

print(failures == 0 and '\nall test files passed' or ('\n%d test file(s) failed'):format(failures));
os.exit(failures == 0 and 0 or 1);

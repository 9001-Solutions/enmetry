--[[
* Whole-addon smoke test.
*
* Runs enmetry.lua the way Ashita does, with only the globals Ashita provides,
* then drives its events: load, command, packets, frames, a drag, unload.
* Most of it runs with the particle filter off, so the bars show the neutral
* replay's exact values; the filter gets its own run at the end.
* Catches what the module tests cannot -- a module reaching for a global that
* only exists in game, or a render branch that only runs with data present.
*
* Loads Ashita's real libs/imgui.lua so every ImGui* constant used is one the
* binding actually defines.  Only the native calls are stubbed.  Set
* ENMETRY_ASHITA to an Ashita game directory; without it the test skips.
*
* Run: luajit tests/test_load.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');

local ASHITA = os.getenv('ENMETRY_ASHITA');
if ASHITA == nil then
    print('SKIP  test_load: set ENMETRY_ASHITA to an Ashita game directory');
    return t.done();
end

local last = ASHITA:sub(-1);
if last ~= '/' and last ~= '\\' then
    ASHITA = ASHITA .. '/';
end

local imguiPath = ASHITA .. 'addons/libs/imgui.lua';
if io.open(imguiPath, 'rb') == nil then
    print('SKIP  test_load: no Ashita install at ' .. ASHITA);
    return t.done();
end

local INSTALL = (os.getenv('TEMP') or '.') .. '\\enmetry_load_test\\';
os.execute(('mkdir "%sconfig\\addons\\enmetry" 2>nul'):format(INSTALL));
do
    local fh = assert(io.open(INSTALL .. 'config\\addons\\enmetry\\settings.lua', 'wb'));
    fh:write('return { particles = 0 }\n');
    fh:close();
end

-- Ashita globals ----------------------------------------------------------

bit = require('bit');
addon = {};

-- The clock enmetry reads for decay, held still unless a test moves it.
local now = 0.1;
os.clock = function () return now; end;
getmetatable('').__index.fmt = string.format;
getmetatable('').__index.append = function (a, b) return a .. b; end;

local handlers = {};
-- The game's interface-hidden flag, as the test sets it.
local game = { hidden = false };
ashita = {
    events = { register = function (name, _, fn) handlers[name] = fn; end },
    fs = {
        exists = function (path)
            -- Files only; a directory reads as absent, so create_dir runs again.
            local fh = io.open(path, 'rb');
            if fh == nil then return false; end
            fh:close();
            return true;
        end,
        create_dir = function (path) os.execute(('mkdir "%s" 2>nul'):format(path)); end,
        -- File names in a directory, as Ashita gives them; the mask is ignored.
        get_directory = function (path)
            local names = {};
            local listing = io.popen(('dir /b "%s" 2>nul'):format(path));
            for name in listing:lines() do
                names[#names + 1] = name;
            end
            listing:close();
            return names;
        end,
        remove = function (path) return os.remove(path) ~= nil; end,
    },
    -- The interface-hidden signature is found, and points at a flag the test sets.
    memory = {
        find = function () return 0x1000; end,
        read_uint32 = function () return 0x2000; end,
        read_uint8 = function () return game.hidden and 1 or 0; end,
    },
};

-- slot -> name, server id, entity index.  Tail joins partway through.
local members = { [0] = { 'Hanayaka', 0x0001E240, 0x405 } };
local function memberField(n, empty)
    return function (_, slot) return members[slot] and members[slot][n] or empty; end;
end
local party = {
    GetMemberIsActive = function (_, slot) return members[slot] and 1 or 0; end,
    GetMemberName = memberField(1, ''),
    GetMemberServerId = memberField(2, 0),
    GetMemberTargetIndex = memberField(3, 0),
    GetMemberMainJob = function () return 1; end,
    GetMemberSubJob = function () return 13; end,
    GetMemberMainJobLevel = function () return 75; end,
    GetMemberSubJobLevel = function () return 37; end,
    GetMemberHP = function () return 1500; end,
    GetMemberHPPercent = function (_, slot) return members[slot] and (members[slot].hpp or 100) or 0; end,
    GetMemberZone = function () return 102; end,
    GetStatusIconsServerId = function () return 0; end,
};
local entities = {
    -- server id, name, spawn flags, render flags 0 (0x200: rendered), x, y, z, status (1: engaged)
    [0x405] = { 0x0001E240, 'Hanayaka', 0x0D, 0x200, 0, 0, 0, 0 },
    [0x406] = { 0x0001E241, 'Tail', 0x0D, 0x200, 1, 0, 0, 0 },
    [0x012] = { 0x0100A012, 'Goblin Thug', 0x10, 0x200, 3, 4, 0, 0 },
    -- Already fighting someone when the addon first sees it.
    [0x013] = { 0x0100A013, 'Goblin Mugger', 0x10, 0x200, 4, 3, 0, 1 },
    [0x420] = { 0x0001E999, 'Stranger', 0x01, 0x200, 5, 0, 0, 1 },
};
local player = {
    GetHPMax = function () return 1500; end,
    GetBuffs = function () return {}; end,
};
-- Equipment slot -> item id worn there.
local equipment = {};
local inventory = {
    GetEquippedItem = function (_, slot) return { Index = equipment[slot] and slot + 1 or 0 }; end,
    GetContainerItem = function (_, _, index) return { Id = equipment[index - 1] or 0 }; end,
};
local function entityField(n, empty)
    return function (_, i) return entities[i] and entities[i][n] or empty; end;
end
local entity = {
    GetServerId = entityField(1, 0),
    GetName = entityField(2, ''),
    GetSpawnFlags = entityField(3, 0),
    GetRenderFlags0 = entityField(4, 0),
    GetLocalPositionX = entityField(5, 0),
    GetLocalPositionY = entityField(6, 0),
    GetLocalPositionZ = entityField(7, 0),
    GetStatus = entityField(8, 0),
    GetPetTargetIndex = entityField(9, 0),
};
-- The player's target: an entity index, 0 for none.
local targetIndex = 0;
local target = {
    GetIsSubTargetActive = function () return 0; end,
    GetTargetIndex = function () return targetIndex; end,
};

-- Native ImGui stand-in: records draw calls and lets the test move the window.
local gui = {
    window = { 100, 100 }, mouseDown = false, texts = {}, textColors = {}, rects = 0, gradients = 0, begun = 0, placed = {},
    widgets = {},       -- the settings panel's widgets drawn, by the key after '##'
    acts = {},          -- key -> what the test sets that widget to this frame
    anyActive = false,  -- a widget is being held
    fontScale = nil,    -- the last SetWindowFontScale
    colorsResolved = 0, -- GetColorU32 calls
};

local function widgetKey(label)
    return label:match('##(.+)$');
end

-- A widget the test can act on: sets its buffer and reports a change once.
local function widget(label, buf)
    local key = widgetKey(label);
    gui.widgets[#gui.widgets + 1] = key;
    local to = gui.acts[key];
    if to == nil then
        return false;
    end
    if type(to) == 'table' then
        for i = 1, #to do
            buf[i] = to[i];
        end
    else
        buf[1] = to;
    end
    gui.acts[key] = nil;
    return true;
end

local function pressed(label)
    local key = widgetKey(label);
    gui.widgets[#gui.widgets + 1] = key;
    if gui.acts[key] then
        gui.acts[key] = nil;
        return true;
    end
    return false;
end
local drawList = {
    AddRectFilled = function () gui.rects = gui.rects + 1; end,
    AddRectFilledMultiColor = function (_, p1, p2, left, right, bottomRight, bottomLeft)
        assert(p2[1] > p1[1] and p2[2] > p1[2], 'a gradient with no area');
        assert(left == bottomLeft and right == bottomRight, 'a gradient that runs left to right');
        gui.gradients = gui.gradients + 1;
    end,
    AddText = function (_, _, color, s)
        gui.texts[#gui.texts + 1] = s;
        gui.textColors[#gui.texts] = color;
    end,
};
local guiManager = setmetatable({
    Begin = function (name, open)
        gui.begun = gui.begun + 1;
        if type(open) == 'table' and gui.acts.close then
            open[1] = false;
            gui.acts.close = nil;
        end
        return true;
    end,
    Checkbox = widget,
    SliderInt = widget,
    SliderFloat = widget,
    ColorEdit4 = widget,
    RadioButton = pressed,
    Button = pressed,
    IsAnyItemActive = function () return gui.anyActive; end,
    SetWindowFontScale = function (scale) gui.fontScale = scale; end,
    SetNextWindowSize = function (sz) gui.size = { sz[1], sz[2] }; end,
    GetTextLineHeight = function () return 13; end,
    -- As in ImGui, an Always placement moves the window before Begin reports it.
    SetNextWindowPos = function (p, cond)
        gui.placed[#gui.placed + 1] = { p[1], p[2], cond };
        if cond == ImGuiCond_Always then
            gui.window = { p[1], p[2] };
        end
    end,
    GetWindowPos = function () return gui.window[1], gui.window[2]; end,
    GetWindowDrawList = function () return drawList; end,
    IsMouseDown = function () return gui.mouseDown; end,
    GetTextLineHeightWithSpacing = function () return 17; end,
    CalcTextSize = function (s) return #s * 7, 13; end,
    GetColorU32 = function (c)
        gui.colorsResolved = gui.colorsResolved + 1;
        if type(c) ~= 'table' then
            return 0xFFFFFFFF;
        end
        local packed = 0;
        for i = 1, 4 do
            packed = packed * 256 + math.floor((c[i] or 1) * 255 + 0.5);
        end
        return packed;
    end,
}, { __index = function () return function () return 0, 0; end; end });

-- The boot configuration's command line, naming the server.
local configuration = {
    GetString = function (_, alias, section, key)
        if alias == 'boot' and section == 'ashita.boot' and key == 'command' then
            return '--server play.horizonxi.com';
        end
    end,
};

AshitaCore = {
    GetInstallPath = function () return INSTALL; end,
    GetConfigurationManager = function () return configuration; end,
    GetGuiManager = function () return guiManager; end,
    GetMemoryManager = function ()
        return {
            GetParty = function () return party; end,
            GetEntity = function () return entity; end,
            GetPlayer = function () return player; end,
            GetTarget = function () return target; end,
            GetInventory = function () return inventory; end,
        };
    end,
};

package.preload['common'] = function () return {}; end
package.preload['chat'] = function ()
    return { header = function (s) return '[' .. s .. '] '; end, message = function (s) return s; end };
end
package.preload['imgui'] = function () return assert(loadfile(imguiPath))(); end

-- Drive the addon -----------------------------------------------------------

local MELEE = t.hex('280000000040E20100010400000000000000800428408000000040044000000000004200000000E00100000000');

--[[
* Bit-packs fields least significant bit first, as 0x028 is.  Only for
* building scenario packets here; test_packets checks the reader against
* independently made bytes.
--]]
local function pack(fields)
    local bytes, pos = {}, 0;
    for _, f in ipairs(fields) do
        for i = 0, f[2] - 1 do
            local b = math.floor(pos / 8) + 1;
            bytes[b] = (bytes[b] or 0) + (math.floor(f[1] / 2 ^ i) % 2) * 2 ^ (pos % 8);
            pos = pos + 1;
        end
    end
    return string.char(unpack(bytes));
end

-- An action on one target with one result: `message` carrying `value`.
local function single(actor, category, param, targetId, message, value)
    return string.char(0x28, 0, 0, 0, 0) .. pack({
        { actor, 32 }, { 1, 6 }, { 0, 4 }, { category, 4 }, { param, 32 }, { 0, 32 },
        { targetId, 32 }, { 1, 4 },
        { 0, 3 }, { 0, 2 }, { 0, 12 }, { 0, 5 }, { 0, 5 }, { value, 17 }, { message, 10 }, { 0, 31 }, { 0, 1 }, { 0, 1 },
    });
end

-- A one-swing melee round that hits for `damage`.
local function melee(actor, targetId, damage)
    return single(actor, 1, 0, targetId, 1, damage);
end

-- An 0x00E update with the general flag (0x07) and an animation.
local function entityUpdate(id, flags, animation, hpp)
    local bytes = { 0x0E, 0x2C, 0, 0 };
    for i = 0, 3 do
        bytes[#bytes + 1] = math.floor(id / 2 ^ (8 * i)) % 256;
    end
    bytes[9], bytes[10], bytes[11] = 0, 0, flags;  -- ActIndex, SendFlg
    while #bytes < 0x1E do
        bytes[#bytes + 1] = 0;
    end
    bytes[#bytes + 1] = hpp or 0;
    bytes[#bytes + 1] = animation;
    while #bytes < 0x58 do
        bytes[#bytes + 1] = 0;
    end
    return string.char(unpack(bytes));
end

local HANAYAKA, TAIL, THUG, MUGGER, STRANGER = 0x0001E240, 0x0001E241, 0x0100A012, 0x0100A013, 0x0001E999;

local printed = {};

-- Chat output is captured only while the addon handles the command, so the
-- harness can still print its own results.
local function command(text)
    local e = { command = text, blocked = false };
    local realPrint = print;
    print = function (s) printed[#printed + 1] = s; end;
    local ok, err = pcall(handlers.command, e);
    print = realPrint;
    assert(ok, err);
    return e.blocked;
end

local SETTINGS = INSTALL .. 'config\\addons\\enmetry\\settings.lua';
local STATE = INSTALL .. 'config\\addons\\enmetry\\state.lua';
os.remove(STATE);
local PROFILES = INSTALL .. 'config\\addons\\enmetry\\profiles.lua';
os.remove(PROFILES);
local LEVELS = INSTALL .. 'config\\addons\\enmetry\\levels.lua';
os.remove(LEVELS);

local function savedText(file)
    local fh = io.open(file or SETTINGS, 'rb');
    if fh == nil then
        return '';
    end
    local text = fh:read('*a');
    fh:close();
    return text;
end

local function frame()
    gui.texts, gui.textColors = {}, {};
    gui.rects = 0;
    gui.gradients = 0;
    gui.begun = 0;
    gui.widgets = {};
    handlers.d3d_present();
end

local function drew(key)
    for _, k in ipairs(gui.widgets) do
        if k == key then
            return true;
        end
    end
    return false;
end

local function has(text)
    for _, s in ipairs(gui.texts) do
        if s == text then
            return true;
        end
    end
    return false;
end

t.test('the entry point runs and registers every event', function ()
    assert(loadfile('addon/enmetry.lua'))();
    for _, name in ipairs({ 'load', 'unload', 'command', 'packet_in', 'd3d_present' }) do
        t.truthy(handlers[name], 'handler ' .. name);
    end
    t.eq(addon.name, 'enmetry');
    handlers.load();
end);

t.test('the command answers with a status line and is blocked from the game', function ()
    printed = {};
    t.truthy(command('/enmetry'), 'blocked');
    t.eq(printed, { '[enmetry] v1.0.0 | debug feed off | 0 events seen | alliance 1/18 | particles off' });
    t.eq(command('/other'), false);
end);

t.test('the panel stays hidden while nothing is fighting the alliance', function ()
    frame();
    t.eq(gui.begun, 0);
end);

t.test('the debug feed shows observed packets, engaged or not', function ()
    command('/enmetry debug on');
    handlers.packet_in({ id = 0x029, data = string.rep('\0', 0x1C) });
    handlers.packet_in({ id = 0x0DF, data = string.rep('\0', 0x20) });
    frame();
    t.eq(gui.begun, 1);
    -- Header, then one stamped line: no bars.
    t.eq({ #gui.texts, gui.texts[1] }, { 3, 'enmetry' });

    handlers.packet_in({ id = 0x028, data = MELEE });
    frame();
    local joined = table.concat(gui.texts, '\n');
    t.truthy(joined:find('Hanayaka WAR/NIN  melee > Goblin Thug  34 miss', 1, true), joined);
end);

local function le(n, bytes)
    local out = {};
    for i = 1, bytes do
        out[i] = string.char(n % 256);
        n = math.floor(n / 256);
    end
    return table.concat(out);
end

-- A /check reply about a target: its level and difficulty band.
local function checkReply(targetId, level, band)
    return string.char(0x29, 0x0E, 0, 0) .. le(HANAYAKA, 4) .. le(targetId, 4) .. le(level, 4) .. le(band, 4)
        .. le(0x405, 2) .. le(0x012, 2) .. le(0xAA, 2) .. le(0, 2);
end

-- A widescan row for an entity index.
local function widescanRow(index, level, name)
    return string.char(0xF4, 0x0E, 0, 0) .. le(index, 2) .. string.char(level, 2) .. le(0, 2) .. le(0, 2)
        .. name .. string.rep('\0', 16 - #name);
end

t.test('a packet another addon injected is not the server\'s and is ignored', function ()
    local before = #gui.texts;
    handlers.packet_in({ id = 0x028, data = MELEE, injected = true });
    frame();
    t.eq(#gui.texts, before, 'nothing was added to the feed');
end);

t.test('turning the feed off leaves the header and the bars', function ()
    command('/enmetry debug off');
    frame();
    t.eq(#gui.texts, 4);
end);

t.test('the melee round shows as a bar on the mob it hit', function ()
    frame();
    -- Goblin Thug is level 38-40, sampled at 39: divisor 30.  34 damage is
    -- 90 CE / 272 VE, plus 200 / 900 for opening the list.
    t.eq({ gui.texts[2], gui.texts[3], gui.texts[4] }, { 'Goblin Thug', 'Hanayaka', '290 / 1172' });
    -- panel, rule, track, CE, VE, cap line, leader marker; no band, no tick
    t.eq({ gui.rects, gui.gradients }, { 7, 0 });
end);

t.test('compact drops the header, the rule and the numbers, narrows and shortens the panel, and toggles back', function ()
    frame();
    local wide, tall = gui.size[1], gui.size[2];
    command('/enmetry compact');
    frame();
    t.eq(gui.texts, { 'Goblin Thug', 'Hanayaka' });
    t.truthy(gui.size[1] < wide and gui.size[2] < tall, ('%gx%g from %gx%g'):format(gui.size[1], gui.size[2], wide, tall));
    -- panel, track, CE, VE, cap line, leader marker
    t.eq(gui.rects, 6);
    command('/enmetry compact off');
    frame();
    frame();
    t.eq({ gui.texts[1], gui.texts[2], gui.texts[3], gui.texts[4], #gui.texts }, { 'enmetry', 'Goblin Thug', 'Hanayaka', '290 / 1172', 4 });
    t.eq(gui.size, { wide, tall });
end);

t.test('VE decays on screen as time passes', function ()
    -- 0.1 to 1.1 crosses the ticks at 0.4 and 0.8.
    now = 1.1;
    frame();
    t.eq(gui.texts[4], '290 / 1124');
end);

t.test('with no target, focus goes where the alliance is acting; a mob met mid-fight shows deltas', function ()
    handlers.packet_in({ id = 0x00E, data = entityUpdate(THUG, 0x07, 1) });
    handlers.packet_in({ id = 0x028, data = melee(HANAYAKA, MUGGER, 34) });
    frame();
    -- No opening bonus: someone was already on the Mugger's list.
    t.eq(gui.texts, { 'enmetry', 'Goblin Mugger', 'ordering only', 'Hanayaka', '+90 / +272' });
    -- panel, rule, track, CE, VE: no cap line and no marker
    t.eq(gui.rects, 5);
end);

t.test('focus follows the player\'s target, and a pin holds it', function ()
    targetIndex = 0x012;
    frame();
    t.eq(gui.texts[2], 'Goblin Thug');

    printed = {};
    command('/enmetry pin');
    t.eq(printed, { '[enmetry] focus pinned to Goblin Thug' });
    targetIndex = 0x013;
    frame();
    t.eq(gui.texts[2], 'Goblin Thug');

    command('/enmetry unpin');
    frame();
    t.eq(gui.texts[2], 'Goblin Mugger');
end);

t.test('an outsider holding hate is named above the bars, and the leader marker goes', function ()
    targetIndex = 0x012;
    handlers.packet_in({ id = 0x028, data = melee(THUG, STRANGER, 12) });
    frame();
    t.eq({ gui.texts[2], gui.texts[3], gui.texts[4], gui.texts[5] }, { 'Goblin Thug', 'Stranger', 'holds hate', 'Hanayaka' });
    -- panel, rule, track, CE, VE, cap line
    t.eq(gui.rects, 6);
end);

t.test('the bar count setting is applied and persisted', function ()
    members[1] = { 'Tail', TAIL, 0x406 };
    now = 2;  -- past the roster refresh interval
    frame();
    handlers.packet_in({ id = 0x028, data = melee(TAIL, THUG, 34) });
    frame();
    t.truthy(has('Hanayaka') and has('Tail'), table.concat(gui.texts, ', '));

    command('/enmetry rows 1');
    t.truthy(savedText():find('rows = 1', 1, true), savedText());
    frame();
    t.truthy(has('Hanayaka') and not has('Tail'), table.concat(gui.texts, ', '));
end);

t.test('when every fight ends the panel hides itself', function ()
    handlers.packet_in({ id = 0x00E, data = entityUpdate(MUGGER, 0x07, 3) });
    frame();
    t.eq(gui.texts[2], 'Goblin Thug');

    handlers.packet_in({ id = 0x00E, data = entityUpdate(THUG, 0x07, 0) });
    frame();
    t.eq(gui.begun, 0);
end);

t.test('zoning forgets every hate list', function ()
    handlers.packet_in({ id = 0x028, data = MELEE });
    frame();
    t.eq(gui.begun, 1);
    handlers.packet_in({ id = 0x00A, data = string.rep('\0', 0x20) });
    frame();
    t.eq(gui.begun, 0);
end);

t.test('enmity gear the player is wearing shows in their bar', function ()
    -- Sattva Ring, Enmity+5.  The claim opens at 200 / 900 x 1.05 = 209 / 944,
    -- then 90 / 272 x 1.05 lands on top.
    equipment[13] = 15544;
    handlers.packet_in({ id = 0x028, data = MELEE });
    frame();
    t.eq({ gui.texts[2], gui.texts[3], gui.texts[4] }, { 'Goblin Thug', 'Hanayaka', '303 / 1229' });

    equipment[13] = nil;
    handlers.packet_in({ id = 0x00A, data = string.rep('\0', 0x20) });
end);

t.test('a drag is saved once released, globally, and survives a reload', function ()
    command('/enmetry debug on');
    gui.window = { 640, 360 };
    gui.mouseDown = true;
    frame();
    t.eq(savedText():find('x = 640', 1, true), nil, 'saved mid-drag');

    gui.mouseDown = false;
    frame();
    local text = savedText();
    t.truthy(text:find('x = 640', 1, true), text);
    t.truthy(text:find('y = 360', 1, true), text);
    t.truthy(text:find('debug = true', 1, true), text);

    -- A fresh load reads the position back.
    handlers.unload();
    gui.window = { 0, 0 };
    local canvas = require('canvas');
    canvas.x, canvas.y = 0, 0;
    handlers.load();
    t.eq({ canvas.x, canvas.y }, { 640, 360 });
end);

t.test('a hand-edited position wins over where ImGui last left the window', function ()
    -- ImGui keeps its window memory across an addon reload, so the file has to
    -- be applied unconditionally, not only on first use.
    handlers.unload();
    local fh = assert(io.open(SETTINGS, 'wb'));
    fh:write('return { x = 25, y = 30, debug = true, particles = 0 }\n');
    fh:close();
    handlers.load();

    gui.placed = {};
    frame();
    t.eq(gui.placed, { { 25, 30, ImGuiCond_Always } });

    handlers.unload();
    t.truthy(savedText():find('x = 25', 1, true), savedText());

    -- After the first frame the user owns the position again.
    gui.placed = {};
    frame();
    for _, p in ipairs(gui.placed) do
        t.truthy(p[3] ~= ImGuiCond_Always, 'a later frame forces the position');
    end
end);

t.test('the shadow absorb rule is read from the settings file', function ()
    handlers.unload();
    local fh = assert(io.open(SETTINGS, 'wb'));
    fh:write('return { shadowAbsorb = "era", particles = 0 }\n');
    fh:close();
    handlers.load();

    handlers.packet_in({ id = 0x028, data = MELEE });                           -- 290 / 1172
    -- Utsusemi: Ichi on himself: 1 / 300, and three shadows.
    handlers.packet_in({ id = 0x028, data = single(HANAYAKA, 4, 338, HANAYAKA, 230, 66) });
    for _ = 1, 3 do
        handlers.packet_in({ id = 0x028, data = single(THUG, 1, 0, HANAYAKA, 31, 1) });
    end
    frame();
    -- The era rule lets the last shadow go free; LSB's would take 75.
    t.eq({ gui.texts[2], gui.texts[3], gui.texts[4] }, { 'Goblin Thug', 'Hanayaka', '241 / 1472' });

    command('/enmetry reset');
    handlers.unload();
    t.truthy(savedText():find('shadowAbsorb = "era"', 1, true), savedText());
end);

-- The kinds of line a session log holds, in order, and its lines.
local function logLines(path)
    local lines, kinds = {}, {};
    for line in savedText(path):gmatch('[^\n]+') do
        lines[#lines + 1] = line;
        kinds[#kinds + 1] = line:match('^{"t":[%d.%-]+,"k":"([%w]+)"');
    end
    return lines, kinds;
end

local function findLine(lines, kind, needle)
    for _, line in ipairs(lines) do
        if line:find('"k":"' .. kind .. '"', 1, true) and (needle == nil or line:find(needle, 1, true)) then
            return line;
        end
    end
end

t.test('a reload picks the fights up where they were; a stale or foreign save, or a reset first, leaves nothing', function ()
    local fh = assert(io.open(SETTINGS, 'wb'));
    fh:write('return { particles = 0 }\n');
    fh:close();
    handlers.load();
    now = 80;
    frame();
    handlers.packet_in({ id = 0x028, data = MELEE });                   -- Hanayaka 290 / 1172
    handlers.packet_in({ id = 0x028, data = melee(TAIL, THUG, 34) });   -- Tail 90 / 272
    handlers.packet_in({ id = 0x028, data = melee(THUG, HANAYAKA, 10) });   -- Hanayaka 278, holding hate
    frame();
    t.eq({ gui.texts[3], gui.texts[4] }, { 'Hanayaka', '278 / 1172' });
    handlers.unload();
    local saved = savedText(STATE);
    t.truthy(saved:find('^return {'), saved);
    t.truthy(saved:find('zone = 102', 1, true) and saved:find('character = "Hanayaka"', 1, true), saved);
    t.truthy(saved:find(('[%d] = {'):format(THUG), 1, true), 'the list');

    printed = {};
    local realPrint = print;
    print = function (line) printed[#printed + 1] = line; end;
    local ok, err = pcall(handlers.load);
    print = realPrint;
    assert(ok, err);
    t.eq(printed, { '[enmetry] picked up 1 hate list from 0s ago' });
    t.eq(io.open(STATE, 'rb'), nil, 'good once');
    frame();
    t.eq({ gui.texts[2], gui.texts[3], gui.texts[4], gui.texts[5], gui.texts[6] }, { 'Goblin Thug', 'Hanayaka', '278 / 1172', 'Tail', '90 / 272' });
    t.truthy(gui.textColors[3] ~= gui.textColors[5], 'your own name stands out from the rest');
    t.eq(gui.textColors[3], 0x73D973FF, 'in green');
    t.eq(has('ordering only'), false, 'still clean');
    -- The mob keeps swinging at whom it held: no switch is judged.
    handlers.packet_in({ id = 0x028, data = melee(THUG, HANAYAKA, 10) });
    frame();
    t.eq(gui.texts[4], '266 / 1172');

    -- A save from another zone is left alone.
    handlers.unload();
    fh = assert(io.open(STATE, 'rb'));
    saved = fh:read('*a');
    fh:close();
    fh = assert(io.open(STATE, 'wb'));
    fh:write((saved:gsub('zone = 102', 'zone = 103')));
    fh:close();
    handlers.load();
    frame();
    t.eq(gui.begun, 0, 'no fight picked up');
    t.eq(io.open(STATE, 'rb'), nil, 'a foreign save goes too');

    -- So is one from too long ago.
    handlers.packet_in({ id = 0x028, data = MELEE });
    handlers.unload();
    fh = assert(io.open(STATE, 'rb'));
    saved = fh:read('*a');
    fh:close();
    fh = assert(io.open(STATE, 'wb'));
    fh:write((saved:gsub('wall = %d+', 'wall = 1000')));
    fh:close();
    handlers.load();
    frame();
    t.eq(gui.begun, 0, 'stale');

    -- A reset before unloading leaves nothing to pick up.
    handlers.packet_in({ id = 0x028, data = MELEE });
    command('/enmetry reset');
    handlers.unload();
    t.eq(io.open(STATE, 'rb'), nil, 'nothing saved');
    handlers.load();
    frame();
    t.eq(gui.begun, 0);
    handlers.unload();
end);

t.test('by default the particle filter runs, and the bars show its median', function ()
    local fh = assert(io.open(SETTINGS, 'wb'));
    fh:write('return {}\n');
    fh:close();
    handlers.load();
    printed = {};
    command('/enmetry');
    t.truthy(printed[1]:find('| 1024 particles', 1, true), printed[1]);

    handlers.packet_in({ id = 0x028, data = MELEE });                 -- Hanayaka, neutral 290 / 1172
    handlers.packet_in({ id = 0x028, data = melee(TAIL, THUG, 34) });
    -- On Hanayaka, far ahead: a swing at Tail would be a surprise for some draws,
    -- dropping the list to ordering-only.
    handlers.packet_in({ id = 0x028, data = melee(THUG, HANAYAKA, 12) });
    frame();
    local label = nil;
    for i, s in ipairs(gui.texts) do
        if s == 'Hanayaka' then
            label = gui.texts[i + 1];
        end
    end
    local ce, ve = tostring(label):match('^(%d+) / (%d+)$');
    ce, ve = tonumber(ce), tonumber(ve);
    -- Somewhere within what Enmity's 0.5x..2x allows around the neutral replay.
    t.truthy(ce ~= nil and ce >= 145 and ce <= 580 and ve >= 586 and ve <= 2344, table.concat(gui.texts, ', '));
    -- Nobody's gear is known yet: the bars fade out across a band, with a median tick.
    t.truthy(gui.gradients >= 4, ('%d gradients'):format(gui.gradients));
    -- panel, rule, two tracks, cap line, marker, and for each bar its opaque pieces and a tick
    t.truthy(gui.rects >= 8, ('%d rects'):format(gui.rects));

    -- The swing at Hanayaka was scored against who the posterior had holding hate.
    printed = {};
    command('/enmetry calibration');
    t.eq(#printed, 2, table.concat(printed, '\n'));
    t.truthy(printed[1]:match('^%[enmetry%] calibration: %d+%% of attacks inside the 80%% credible set of who holds hate, over 1$'),
        printed[1]);

    -- The particle ceiling moves from the panel, at once.
    command('/enmetry settings on');
    gui.acts.particles = 256;
    frame();
    printed = {};
    command('/enmetry');
    t.truthy(printed[1]:find('| 256 particles', 1, true), printed[1]);
    gui.acts.particles = 1024;
    frame();
    command('/enmetry settings off');

    command('/enmetry reset');
    handlers.unload();
    t.truthy(savedText():find('particles = 1024', 1, true), savedText());
end);

t.test('what the filter learned is kept per server and character, and can be forgotten', function ()
    local text = savedText(PROFILES);
    for _, needle in ipairs({ '["play.horizonxi.com"]', '["Hanayaka"]', '["Tail"]', '["WAR"]', 'melee = { mean = ' }) do
        t.truthy(text:find(needle, 1, true), needle .. ' in ' .. text);
    end

    handlers.load();
    printed = {};
    command('/enmetry calibration');
    t.eq(printed, { '[enmetry] calibration: nothing scored yet this session' }, 'a new session starts afresh');
    printed = {};
    command('/enmetry forget tail');
    t.eq(printed, { '[enmetry] forgot Tail' });
    text = savedText(PROFILES);
    t.eq(text:find('Tail', 1, true), nil, text);
    t.truthy(text:find('Hanayaka', 1, true), text);

    -- Zoning writes it too, with whoever has been drawn since.
    handlers.packet_in({ id = 0x028, data = melee(TAIL, THUG, 34) });
    handlers.packet_in({ id = 0x00A, data = string.rep('\0', 0x20) });
    t.truthy(savedText(PROFILES):find('Tail', 1, true), savedText(PROFILES));

    printed = {};
    command('/enmetry purge confirm');
    t.eq(printed, { '[enmetry] forgot 2 characters' });
    t.eq(savedText(PROFILES):find('Hanayaka', 1, true), nil, savedText(PROFILES));
    handlers.unload();
    t.eq(savedText(PROFILES):find('Hanayaka', 1, true), nil, 'unloading does not bring them back');
end);

t.test('a wipe resets every list, says so once, and so does the reset command', function ()
    handlers.load();
    now = 100;
    frame();
    handlers.packet_in({ id = 0x028, data = melee(HANAYAKA, THUG, 34) });
    handlers.packet_in({ id = 0x028, data = melee(TAIL, THUG, 34) });
    frame();
    t.eq(gui.begun, 1);

    members[0].hpp, members[1].hpp = 0, 0;
    now = 101;
    local realPrint = print;
    printed = {};
    print = function (line) printed[#printed + 1] = line; end;
    local ok, err = pcall(function ()
        frame();
        now = 102;
        frame();
    end);
    print = realPrint;
    assert(ok, err);
    t.eq(printed, { '[enmetry] wipe -- every hate list reset' });
    t.eq(gui.begun, 0, 'the panel hides');

    members[0].hpp, members[1].hpp = nil, nil;
    now = 103;
    frame();
    handlers.packet_in({ id = 0x028, data = melee(HANAYAKA, THUG, 34) });
    frame();
    t.eq(gui.begun, 1, 'the next pull shows');
    printed = {};
    command('/enmetry reset');
    t.eq(printed, { '[enmetry] every hate list reset' });
    frame();
    t.eq(gui.begun, 0);
    handlers.unload();
end);

local GAPS = INSTALL .. 'config\\addons\\enmetry\\gaps.log';
local RESEARCH = INSTALL .. 'config\\addons\\enmetry\\research.jsonl';
local POSTERIOR = INSTALL .. 'config\\addons\\enmetry\\research.lua';
os.remove(GAPS);

t.test('a switch no particle expected re-anchors the list, and a mobskill missing from the table before it is logged', function ()
    handlers.load();
    now = 200;
    handlers.packet_in({ id = 0x028, data = melee(HANAYAKA, THUG, 400) });
    handlers.packet_in({ id = 0x028, data = melee(TAIL, THUG, 1) });
    handlers.packet_in({ id = 0x028, data = melee(THUG, HANAYAKA, 10) });
    frame();
    t.eq(has('ordering only'), false);

    local realPrint = print;
    printed = {};
    print = function (line) printed[#printed + 1] = line; end;
    local ok, err = pcall(function ()
        -- Mobskill 9999 is in no table; it hits Hanayaka, and the mob turns on Tail.
        handlers.packet_in({ id = 0x028, data = single(THUG, 11, 9999, HANAYAKA, 185, 10) });
        handlers.packet_in({ id = 0x028, data = melee(THUG, TAIL, 10) });
        frame();
    end);
    print = realPrint;
    assert(ok, err);
    t.eq(printed, { '[enmetry] table gap -- Goblin Thug used mobskill 9999 before a switch nothing explains' });
    t.truthy(has('re-anchored') and not has('ordering only'), table.concat(gui.texts, ', '));
    t.truthy(savedText(GAPS):find('mobskill 9999\tzone 10\tGoblin Thug\n', 1, true), savedText(GAPS));
    -- Still learning: the next swing is weighed and scored.
    handlers.packet_in({ id = 0x028, data = melee(THUG, TAIL, 10) });
    printed = {};
    print = function (line) printed[#printed + 1] = line; end;
    ok, err = pcall(frame);
    print = realPrint;
    assert(ok, err);
    t.eq(printed, {});
    printed = {};
    command('/enmetry calibration');
    t.truthy(printed[1]:find('over 3$'), printed[1]);


    command('/enmetry reset');
    handlers.unload();
end);

t.test('a session log records the session, what came in, what the sim made of it, notes and errors', function ()
    local fh = assert(io.open(SETTINGS, 'wb'));
    fh:write('return {}\n');
    fh:close();
    handlers.load();
    printed = {};
    command('/enmetry log');
    local path = printed[1] and printed[1]:match('lines to (.+)$');
    t.truthy(path ~= nil and path:find('logs\\enmetry-', 1, true), tostring(printed[1]));

    now = 300;
    frame();
    handlers.packet_in({ id = 0x028, data = melee(HANAYAKA, THUG, 34) });
    handlers.packet_in({ id = 0x028, data = melee(THUG, HANAYAKA, 10) });
    now = 301.5;
    frame();
    command('/enmetry mark tank lost hate');
    handlers.packet_in({ id = 0x028, data = string.char(0x28, 0x10, 0, 0, 1, 2) });
    now = 312;
    frame();
    handlers.packet_in({ id = 0x00A, data = string.char(0x0A, 0x02, 0, 0) });

    -- An error is logged with where it happened, and still raised.
    local zone = party.GetMemberZone;
    party.GetMemberZone = function () error('boom'); end;
    now = 313;
    local ok = pcall(frame);
    party.GetMemberZone = zone;
    t.eq(ok, false, 'raised');
    handlers.unload();

    local lines, kinds = logLines(path);
    t.eq(kinds[1], 'session');
    t.eq(kinds[#kinds], 'end');
    for i, line in ipairs(lines) do
        t.truthy(kinds[i] ~= nil and line:sub(-1) == '}', 'line ' .. i .. ': ' .. line);
    end
    for _, needle in ipairs({ '"logVersion":1', '"server":"play.horizonxi.com"', '"version":"1.0.0"', '"particles":1024', '"seed":' }) do
        t.truthy(lines[1]:find(needle, 1, true), needle .. ' in ' .. lines[1]);
    end
    t.truthy(findLine(lines, 'roster', '"name":"Hanayaka"'), 'the roster');
    t.truthy(findLine(lines, 'packet', '"hex":"2800'), 'the raw packet');
    t.truthy(findLine(lines, 'packet', '"text":"Goblin Thug  melee > Hanayaka WAR/NIN  10"'), 'what it read as');
    t.truthy(findLine(lines, 'packet', '"hex":"281000000102","id":40,"parsed":false'), 'a packet that would not parse');
    t.truthy(findLine(lines, 'zone', '"hex":"0a020000"'), 'zoning, with its packet');
    t.truthy(findLine(lines, 'prior', '"name":"Hanayaka"'), 'the prior Hanayaka was drawn from');
    t.truthy(findLine(lines, 'perf', '"logMs":'), 'the frame cost, with the log\'s');
    for _, kind in ipairs({ 'list', 'action', 'enmity', 'target', 'observe', 'snapshot', 'posterior', 'command', 'fight' }) do
        t.truthy(findLine(lines, kind), kind .. ' in ' .. table.concat(kinds, ' '));
    end
    local snapshot = findLine(lines, 'snapshot', '"name":"Goblin Thug"');
    t.truthy(snapshot, 'a snapshot of the mob');
    -- Each row ends with the band its bar fades across, the median in its middle.
    local mCe, mVe, lower, middle, upper = snapshot:match('%[%d+,%d+,%d+,(%d+),(%d+),true,%[(%d+),%d+,(%d+),%d+,(%d+)%]%]');
    t.truthy(middle ~= nil and tonumber(middle) == mCe + mVe and tonumber(lower) <= tonumber(upper), snapshot);
    t.truthy(findLine(lines, 'mark', '"text":"tank lost hate"'), 'the note');
    local err = findLine(lines, 'error', 'boom');
    t.truthy(err and err:find('"where":"d3d_present"', 1, true) and err:find('traceback', 1, true), tostring(err));
end);

t.test('the research log accumulates across loads, with a session line each, and the readout names its file', function ()
    local fh = assert(io.open(SETTINGS, 'wb'));
    fh:write('return { particles = 0 }\n');
    fh:close();
    os.remove(RESEARCH);
    handlers.load();
    printed = {};
    command('/enmetry research');
    t.eq(printed[1], '[enmetry] research: 2 open questions, logged to ' .. RESEARCH);
    t.eq(#printed, 5);
    t.truthy(printed[3]:find('running lsb', 1, true) and printed[3]:find('0 logged this session', 1, true), printed[3]);
    t.truthy(printed[5]:find('not yet scored', 1, true), printed[5]);
    -- A ninja tank losing their last shadow, then the mob staying on them: an attack the shadow question turns on.
    now = 400;
    frame();
    handlers.packet_in({ id = 0x028, data = melee(HANAYAKA, THUG, 300) });
    handlers.packet_in({ id = 0x028, data = melee(TAIL, THUG, 250) });
    handlers.packet_in({ id = 0x028, data = single(HANAYAKA, 4, 338, HANAYAKA, 230, 66) });
    handlers.packet_in({ id = 0x028, data = single(THUG, 1, 0, HANAYAKA, 31, 1) });
    handlers.packet_in({ id = 0x028, data = single(THUG, 1, 0, HANAYAKA, 31, 1) });
    handlers.packet_in({ id = 0x028, data = single(THUG, 1, 0, HANAYAKA, 31, 1) });
    handlers.packet_in({ id = 0x028, data = melee(THUG, HANAYAKA, 10) });
    now = 401.5;
    frame();
    printed = {};
    command('/enmetry research');
    t.truthy(printed[3]:find('1 logged this session', 1, true), printed[3]);
    handlers.unload();

    local lines, kinds = logLines(RESEARCH);
    t.eq(kinds, { 'session', 'observation' });
    t.truthy(lines[1]:find('"live":{"avatarShare":"none","shadowAbsorb":"lsb"}', 1, true), lines[1]);
    t.truthy(lines[1]:find('"rule":"lsb"', 1, true) and lines[1]:find('"server":"play.horizonxi.com"', 1, true), lines[1]);
    t.truthy(lines[2]:find('"entry":"shadowAbsorb"', 1, true) and lines[2]:find('"wall":', 1, true), lines[2]);
    t.truthy(lines[2]:find(('"rows":%%[%%[%d,%%d+,1%%],%%[%d,%%d+,0%%]%%]'):format(HANAYAKA, TAIL)), lines[2]);

    -- The next load appends, and the readout shows a posterior the offline tool wrote.
    handlers.load();
    fh = assert(io.open(POSTERIOR, 'wb'));
    fh:write('return { version = 1, date = "2026-09-01 20:00:00", entries = { shadowAbsorb = { observations = 40, posterior = { era = 0.7, lsb = 0.3 } } } }\n');
    fh:close();
    printed = {};
    command('/enmetry research');
    t.truthy(printed[3]:find('scored 2026-09-01 20:00:00 over 40: era 70%, lsb 30%', 1, true), printed[3]);
    handlers.unload();
    lines, kinds = logLines(RESEARCH);
    t.eq(kinds, { 'session', 'observation', 'session' });
    os.remove(POSTERIOR);

    -- Turned off, nothing is written and the command says so.
    fh = assert(io.open(SETTINGS, 'wb'));
    fh:write('return { particles = 0, research = false }\n');
    fh:close();
    handlers.load();
    printed = {};
    command('/enmetry research');
    t.eq(printed, { '[enmetry] research log off -- turn it on in /enmetry settings' });
    handlers.unload();
    lines = logLines(RESEARCH);
    t.eq(#lines, 3);
end);

t.test('only the newest session logs are kept', function ()
    local dir = INSTALL .. 'config\\addons\\enmetry\\logs\\';
    for i = 0, 59 do
        local fh = assert(io.open(('%senmetry-20000101-0000%02d.jsonl'):format(dir, i), 'wb'));
        fh:close();
    end
    handlers.load();
    handlers.unload();
    local kept = 0;
    for _, name in ipairs(ashita.fs.get_directory(dir)) do
        kept = kept + (name:match('^enmetry%-.*%.jsonl$') and 1 or 0);
    end
    t.eq(kept, 50);
    t.eq(io.open(dir .. 'enmetry-20000101-000000.jsonl', 'rb'), nil, 'the oldest went');
end);

t.test('the settings panel opens on command with a widget for each setting, and a change shows at once and is saved', function ()
    local fh = assert(io.open(SETTINGS, 'wb'));
    fh:write('return { particles = 0 }\n');
    fh:close();
    handlers.load();
    now = 500;
    frame();
    t.eq(gui.begun, 0);
    printed = {};
    command('/enmetry settings');
    t.eq(printed, { '[enmetry] settings panel open' });
    frame();
    t.eq(gui.begun, 1, 'the panel alone');
    for _, key in ipairs({ 'rows', 'fontScale', 'ceColor', 'veColor', 'panelColor', 'debug', 'compact',
        'values.era', 'values.lsb', 'shadowAbsorb.lsb', 'shadowAbsorb.era', 'particles', 'log', 'research', 'defaults' }) do
        t.truthy(drew(key), key);
    end

    handlers.packet_in({ id = 0x028, data = MELEE });
    handlers.packet_in({ id = 0x028, data = melee(TAIL, THUG, 34) });
    frame();
    t.eq(gui.begun, 2, 'the panel and the bars');
    t.truthy(has('Hanayaka') and has('Tail'), table.concat(gui.texts, ', '));

    -- Dragging the rows slider applies at once but isn't written until it's let go.
    gui.acts.rows = 1;
    gui.anyActive = true;
    frame();
    t.truthy(has('Hanayaka') and not has('Tail'), table.concat(gui.texts, ', '));
    t.eq(savedText():find('rows = 1', 1, true), nil, 'still held');
    gui.anyActive = false;
    frame();
    t.truthy(savedText():find('rows = 1', 1, true), savedText());

    -- A colour lands in the file as a table, and the bars are recoloured.
    local resolved = gui.colorsResolved;
    gui.acts.ceColor = { 1, 0, 0, 1 };
    frame();
    t.truthy(gui.colorsResolved > resolved, 'colours resolved again');
    local text = savedText();
    t.truthy(text:find('ceColor = {\n        [1] = 1,\n        [2] = 0,\n        [3] = 0,\n        [4] = 1,\n    },', 1, true), text);
    local canvas = require('canvas');
    t.eq(canvas.colors.ce, { 1, 0, 0, 1 });

    -- The scale reaches the window's font and the panel's width.  The value
    -- column takes what the widest label measures when that beats its base:
    -- the fake's 7 a glyph makes '+00000 / +00000' 105 plus the pad, so at
    -- scale 1 the panel grows by 27 from 460, and at 2 the base 168 holds.
    gui.acts.fontScale = 2;
    frame();
    t.eq({ gui.fontScale, canvas.width, canvas.scale }, { 2, 920, 2 });
    gui.acts.fontScale = 1;
    frame();
    t.eq({ gui.fontScale, canvas.width }, { 1, 487 });

    -- The shadow rule switches mid-fight: the era rule lets the last shadow go free.
    gui.acts['shadowAbsorb.era'] = true;
    frame();
    handlers.packet_in({ id = 0x028, data = single(HANAYAKA, 4, 338, HANAYAKA, 230, 66) });
    for _ = 1, 3 do
        handlers.packet_in({ id = 0x028, data = single(THUG, 1, 0, HANAYAKA, 31, 1) });
    end
    frame();
    t.eq({ gui.texts[2], gui.texts[3], gui.texts[4] }, { 'Goblin Thug', 'Hanayaka', '241 / 1472' });
    t.truthy(savedText():find('shadowAbsorb = "era"', 1, true), savedText());

    -- The table values switch the same way: Rampart is 1/300 by the era table, 320/320 by LandSandBoat.
    gui.acts['values.lsb'] = true;
    frame();
    handlers.packet_in({ id = 0x028, data = single(HANAYAKA, 6, 92, HANAYAKA, 100, 0) });
    frame();
    t.eq({ gui.texts[3], gui.texts[4] }, { 'Hanayaka', '561 / 1792' });
    t.truthy(savedText():find('values = "lsb"', 1, true), savedText());

    -- Defaults puts everything back, and the file follows.
    gui.acts.defaults = true;
    frame();
    frame();
    t.truthy(has('Hanayaka') and has('Tail'), 'eight rows again');
    text = savedText();
    t.truthy(text:find('rows = 8', 1, true) and text:find('shadowAbsorb = "lsb"', 1, true), text);
    t.truthy(text:find('values = "era"', 1, true), text);
    t.truthy(text:find('[1] = 0.86,', 1, true), text);

    -- Closing the window's button stops drawing it; the command says so.
    gui.acts.close = true;
    frame();
    frame();
    t.eq(gui.begun, 1, 'the bars alone');
    printed = {};
    command('/enmetry settings off');
    t.eq(printed, { '[enmetry] settings panel closed' });
    command('/enmetry reset');
    handlers.unload();
end);

t.test('the session and research logs stop and start from the panel, closing and opening their files', function ()
    local fh = assert(io.open(SETTINGS, 'wb'));
    fh:write('return { particles = 0 }\n');
    fh:close();
    os.remove(RESEARCH);
    handlers.load();
    printed = {};
    command('/enmetry log');
    local first = printed[1]:match('lines to (.+)$');
    command('/enmetry settings on');
    now = 600;
    frame();
    handlers.packet_in({ id = 0x028, data = MELEE });
    frame();

    gui.acts.log = false;
    frame();
    printed = {};
    command('/enmetry log');
    t.eq(printed, { '[enmetry] session log off -- turn it on in /enmetry settings' });
    local lines, kinds = logLines(first);
    t.eq(kinds[#kinds], 'end', 'the first file was closed properly');
    t.truthy(findLine(lines, 'setting', '"key":"log"'), 'the change itself was logged first');
    -- Turning it off wrote the file; nothing more lands in it.
    handlers.packet_in({ id = 0x028, data = MELEE });
    frame();
    t.eq(#logLines(first), #lines);

    gui.acts.log = true;
    frame();
    printed = {};
    command('/enmetry log');
    local second = printed[1]:match('lines to (.+)$');
    t.truthy(second ~= nil and second ~= first, tostring(printed[1]));
    handlers.packet_in({ id = 0x028, data = melee(TAIL, THUG, 34) });
    frame();
    command('/enmetry mark after');
    local kinds2;
    lines, kinds2 = logLines(second);
    t.eq(kinds2[1], 'session');
    t.truthy(findLine(lines, 'action') and findLine(lines, 'mark', 'after'), 'the sim logs to the new file');

    gui.acts.research = false;
    frame();
    printed = {};
    command('/enmetry research');
    t.eq(printed, { '[enmetry] research log off -- turn it on in /enmetry settings' });
    lines = logLines(RESEARCH);
    local before = #lines;
    gui.acts.research = true;
    frame();
    printed = {};
    command('/enmetry research');
    t.truthy(printed[1]:find('2 open questions', 1, true), tostring(printed[1]));
    lines, kinds = logLines(RESEARCH);
    t.eq(#lines, before + 1);
    t.eq(kinds[#kinds], 'session', 'a new header');
    t.truthy(savedText():find('research = true', 1, true) and savedText():find('log = true', 1, true), savedText());
    command('/enmetry settings off');
    command('/enmetry reset');
    handlers.unload();
end);

t.test('the panel and the bars hide with the game\'s interface', function ()
    local fh = assert(io.open(SETTINGS, 'wb'));
    fh:write('return { particles = 0 }\n');
    fh:close();
    handlers.load();
    now = 700;
    frame();
    command('/enmetry settings on');
    handlers.packet_in({ id = 0x028, data = MELEE });
    frame();
    t.eq(gui.begun, 2);
    game.hidden = true;
    frame();
    t.eq(gui.begun, 0);
    -- The sim ran on regardless.
    now = 701;
    game.hidden = false;
    frame();
    t.eq(gui.begun, 2);
    t.eq(gui.texts[4], '290 / 1124');
    command('/enmetry settings off');
    command('/enmetry reset');
    handlers.unload();
end);

t.test('a /check reply and a widescan row teach the mob\'s level, which the list then divides by, and the levels are kept', function ()
    handlers.load();
    -- Goblin Thug's LandSandBoat range is 38-40; the server says 88.
    handlers.packet_in({ id = 0x029, data = checkReply(THUG, 88, 0x44) });
    handlers.packet_in({ id = 0x028, data = melee(HANAYAKA, THUG, 34) });
    frame();
    t.eq({ gui.texts[2], gui.texts[3], gui.texts[4] }, { 'Goblin Thug', 'Hanayaka', '245 / 1036' });

    -- Widescan then says 90 for the same entity: the mob's own level moves.
    command('/enmetry reset');
    handlers.packet_in({ id = 0x0F4, data = widescanRow(0x012, 90, 'Goblin Thug') });
    handlers.packet_in({ id = 0x028, data = melee(HANAYAKA, THUG, 34) });
    frame();
    t.eq(gui.texts[4], '244 / 1033');

    -- A row for something not in the entity table teaches its name and zone alone.
    handlers.packet_in({ id = 0x0F4, data = widescanRow(0x7FF, 77, 'Goblin Far') });

    -- Reset first, so the reload picks up no list: the values below are fresh.
    command('/enmetry reset');
    handlers.unload();
    local text = savedText(LEVELS);
    t.truthy(text:find('["Goblin Thug"] = {\n                [1] = 88,\n                [2] = 90,', 1, true), text);
    t.truthy(text:find('["Goblin Far"] = {\n                [1] = 77,', 1, true), text);
    t.truthy(text:find('[102] = {', 1, true), text);

    -- Loaded again, the file is what it knows: the highest seen for the name.
    handlers.load();
    handlers.packet_in({ id = 0x028, data = melee(HANAYAKA, THUG, 34) });
    frame();
    t.eq(gui.texts[4], '244 / 1033');
    command('/enmetry reset');
    handlers.unload();
    os.remove(LEVELS);
end);

t.test('a member seen resting generates cure enmity every ten seconds from twenty on, until they get up', function ()
    handlers.load();
    now = now + 1;
    handlers.packet_in({ id = 0x028, data = melee(HANAYAKA, THUG, 34) });
    frame();
    t.eq(gui.texts[4], '290 / 1172');
    entities[0x405][8] = 33;
    now = now + 1;
    frame();
    now = now + 19.9;
    frame();
    t.truthy(gui.texts[4]:find('^290 / ') ~= nil, gui.texts[4]);
    now = now + 0.2;
    frame();
    -- Horizon's 35 HP without Signet, at level 75: 25 CE.
    t.truthy(gui.texts[4]:find('^315 / ') ~= nil, gui.texts[4]);
    entities[0x405][8] = 0;
    now = now + 1;
    frame();
    now = now + 20;
    frame();
    t.truthy(gui.texts[4]:find('^315 / ') ~= nil, gui.texts[4]);
    command('/enmetry reset');
    handlers.unload();
end);

t.test('nothing is drawn while not in the world', function ()
    entities[0x405][4] = 0;
    frame();
    t.eq(gui.begun, 0);
end);

return t.done();

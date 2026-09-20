local filter = require('filter');
local world = require('world');

-- Requiring imgui needs a live ImGui context, so it happens at first render.
local imgui = nil;

local options = {};

options.FIELDS = {
    { key = 'rows', kind = 'int', label = 'Bars shown', min = 1, max = world.ALLIANCE_SLOTS, section = 'Panel' },
    { key = 'fontScale', kind = 'float', label = 'Scale', min = 0.5, max = 2.5, format = '%.2f' },
    { key = 'ceColor', kind = 'color', label = 'CE' },
    { key = 'veColor', kind = 'color', label = 'VE' },
    { key = 'panelColor', kind = 'color', label = 'Background' },
    { key = 'compact', kind = 'bool', label = 'Compact' },
    { key = 'debug', kind = 'bool', label = 'Show the action feed' },
    { key = 'values', kind = 'choice', label = 'Table values where era and LandSandBoat differ', choices = { 'era', 'lsb' },
        describe = { era = 'the era table', lsb = 'LandSandBoat' }, section = 'Model' },
    { key = 'shadowAbsorb', kind = 'choice', label = 'Utsusemi absorbs that cost CE', choices = { 'lsb', 'era' },
        describe = { lsb = 'every one', era = 'all but the last' } },
    { key = 'particles', kind = 'int', label = 'Particles', min = 0, max = filter.MAX, deferred = true,
        note = '0 turns the filter off; turning it off or on takes a reload' },
    { key = 'log', kind = 'bool', label = 'Session log', section = 'Logs' },
    { key = 'research', kind = 'bool', label = 'Research log' },
};

local DEFAULTS = {
    x = 100,
    y = 100,
    rows = 8,
    fontScale = 1,
    ceColor = { 0.86, 0.45, 0.22, 1 },
    veColor = { 0.36, 0.62, 0.90, 1 },
    panelColor = { 0.05, 0.06, 0.08, 0.78 },
    compact = false,
    debug = false,
    values = 'era',
    shadowAbsorb = 'lsb',
    particles = filter.MAX,
    log = true,
    research = true,
};

local byKey = {};
for _, f in ipairs(options.FIELDS) do
    byKey[f.key] = f;
end

local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge;
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v));
end

local function channel(v)
    return math.floor(clamp(v, 0, 1) * 1000 + 0.5) / 1000;
end

function options.field(key)
    return byKey[key];
end

function options.index(list, value)
    for i, v in ipairs(list) do
        if v == value then
            return i;
        end
    end
    return nil;
end

function options.defaults()
    local out = {};
    for k, v in pairs(DEFAULTS) do
        if type(v) == 'table' then
            out[k] = { v[1], v[2], v[3], v[4] };
        else
            out[k] = v;
        end
    end
    return out;
end

function options.set(s, key, value)
    local f = byKey[key];
    if f == nil then
        return false;
    end
    if f.kind == 'bool' then
        if type(value) ~= 'boolean' then
            return false;
        end
    elseif f.kind == 'int' or f.kind == 'float' then
        if not finite(value) or value < f.min or value > f.max or (f.kind == 'int' and value ~= math.floor(value)) then
            return false;
        end
    elseif f.kind == 'choice' then
        if options.index(f.choices, value) == nil then
            return false;
        end
    elseif f.kind == 'color' then
        if type(value) ~= 'table' or #value ~= 4 then
            return false;
        end
        for i = 1, 4 do
            if not finite(value[i]) then
                return false;
            end
        end
        local into = s[key];
        if type(into) ~= 'table' then
            into = {};
            s[key] = into;
        end
        for i = 1, 4 do
            into[i] = channel(value[i]);
        end
        return true;
    end
    s[key] = value;
    return true;
end

function options.sanitize(s)
    for _, f in ipairs(options.FIELDS) do
        local v, d = s[f.key], DEFAULTS[f.key];
        if f.kind == 'bool' then
            if type(v) ~= 'boolean' then
                s[f.key] = d;
            end
        elseif f.kind == 'int' or f.kind == 'float' then
            if not finite(v) then
                v = d;
            end
            v = clamp(v, f.min, f.max);
            if f.kind == 'int' then
                v = math.floor(v);
            end
            s[f.key] = v;
        elseif f.kind == 'choice' then
            if options.index(f.choices, v) == nil then
                s[f.key] = d;
            end
        elseif f.kind == 'color' then
            if not options.set(s, f.key, v) then
                options.set(s, f.key, d);
            end
        end
    end
    return s;
end

function options.panel()
    local buffers, labels, choiceLabels = {}, {}, {};
    for _, f in ipairs(options.FIELDS) do
        buffers[f.key] = f.kind == 'color' and { 0, 0, 0, 0 } or { false };
        labels[f.key] = f.label .. '##' .. f.key;
        if f.kind == 'choice' then
            local byChoice = {};
            for _, choice in ipairs(f.choices) do
                byChoice[choice] = choice .. '##' .. f.key .. '.' .. choice;
            end
            choiceLabels[f.key] = byChoice;
        end
    end
    return {
        open = { false },
        changed = {},
        changedCount = 0,
        pending = nil,
        buffers = buffers,
        labels = labels,
        choiceLabels = choiceLabels,
    };
end

local function changed(panel, hooks, key)
    local n = panel.changedCount + 1;
    panel.changed[n] = key;
    panel.changedCount = n;
    hooks.change(key);
end

local function drawField(panel, s, f, hooks)
    local buf, label = panel.buffers[f.key], panel.labels[f.key];
    local moved = false;
    if f.kind == 'bool' then
        buf[1] = s[f.key];
        if imgui.Checkbox(label, buf) and buf[1] ~= s[f.key] then
            s[f.key] = buf[1];
            moved = true;
        end
    elseif f.kind == 'int' then
        buf[1] = s[f.key];
        moved = imgui.SliderInt(label, buf, f.min, f.max, '%d', ImGuiSliderFlags_AlwaysClamp)
            and buf[1] ~= s[f.key] and options.set(s, f.key, buf[1]);
    elseif f.kind == 'float' then
        buf[1] = s[f.key];
        moved = imgui.SliderFloat(label, buf, f.min, f.max, f.format, ImGuiSliderFlags_AlwaysClamp)
            and buf[1] ~= s[f.key] and options.set(s, f.key, buf[1]);
    elseif f.kind == 'color' then
        local c = s[f.key];
        buf[1], buf[2], buf[3], buf[4] = c[1], c[2], c[3], c[4];
        moved = imgui.ColorEdit4(label, buf, bit.bor(ImGuiColorEditFlags_NoInputs or 0, ImGuiColorEditFlags_AlphaBar or 0))
            and options.set(s, f.key, buf);
    elseif f.kind == 'choice' then
        local byChoice = panel.choiceLabels[f.key];
        for i, choice in ipairs(f.choices) do
            if i > 1 then
                imgui.SameLine();
            end
            if imgui.RadioButton(byChoice[choice], s[f.key] == choice) and s[f.key] ~= choice then
                s[f.key] = choice;
                moved = true;
            end
        end
        imgui.SameLine();
        imgui.Text(f.label);
        if f.describe ~= nil then
            imgui.TextDisabled(f.describe[s[f.key]]);
        end
    end
    if moved then
        if f.deferred then
            panel.pending = f.key;
        else
            changed(panel, hooks, f.key);
        end
    end
    if f.note ~= nil then
        imgui.TextDisabled(f.note);
    end
end

local function restoreDefaults(panel, s, hooks)
    for _, f in ipairs(options.FIELDS) do
        local d = DEFAULTS[f.key];
        local moved;
        if f.kind == 'color' then
            local c = s[f.key];
            moved = c[1] ~= d[1] or c[2] ~= d[2] or c[3] ~= d[3] or c[4] ~= d[4];
        else
            moved = s[f.key] ~= d;
        end
        if moved then
            options.set(s, f.key, d);
            changed(panel, hooks, f.key);
        end
    end
end

local function settle(panel, hooks)
    if panel.pending ~= nil then
        changed(panel, hooks, panel.pending);
        panel.pending = nil;
    end
    if panel.changedCount > 0 then
        hooks.save(panel.changed, panel.changedCount);
        for i = panel.changedCount, 1, -1 do
            panel.changed[i] = nil;
        end
        panel.changedCount = 0;
    end
end

function options.render(panel, s, hooks)
    local open = panel.open;
    if not open[1] then
        settle(panel, hooks);
        return;
    end
    imgui = imgui or require('imgui');
    if imgui.Begin('enmetry settings', open, ImGuiWindowFlags_AlwaysAutoResize) then
        for _, f in ipairs(options.FIELDS) do
            if f.section ~= nil then
                imgui.Spacing();
                imgui.Text(f.section);
                imgui.Separator();
            end
            drawField(panel, s, f, hooks);
        end
        imgui.Spacing();
        imgui.Separator();
        if imgui.Button('Defaults##defaults') then
            restoreDefaults(panel, s, hooks);
        end
    end
    imgui.End();
    if not open[1] or not imgui.IsAnyItemActive() then
        settle(panel, hooks);
    end
end

return options;

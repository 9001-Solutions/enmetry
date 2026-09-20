--[[
* The settings: what can be set, its bounds, and the panel that sets it.
*
* The panel draws with a stand-in ImGui that records the widgets and lets a
* test act on one by name.
*
* Run: luajit tests/test_options.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');

-- What each widget is asked to become this frame, by the key after '##'.
local acts = {};
local drawn = {};
local ui = { anyActive = false, begun = 0, ended = 0, flags = nil };

local function keyOf(label)
    return label:match('##(.+)$');
end

local function scripted(label, buf)
    drawn[#drawn + 1] = label;
    local key = keyOf(label);
    local to = key and acts[key];
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
    acts[key] = nil;
    return true;
end

function ui.Begin(name, open, flags)
    ui.begun = ui.begun + 1;
    ui.flags = flags;
    if acts.close then
        open[1] = false;
        acts.close = nil;
    end
    return true;
end
function ui.End() ui.ended = ui.ended + 1; end
ui.Checkbox = scripted;
ui.SliderInt = scripted;
ui.SliderFloat = scripted;
ui.ColorEdit4 = scripted;
function ui.RadioButton(label, active)
    drawn[#drawn + 1] = label;
    local key = keyOf(label);
    if acts[key] then
        acts[key] = nil;
        return true;
    end
    return false;
end
function ui.Button(label)
    drawn[#drawn + 1] = label;
    local key = keyOf(label);
    if acts[key] then
        acts[key] = nil;
        return true;
    end
    return false;
end
function ui.Text(s) drawn[#drawn + 1] = s; end
function ui.TextDisabled(s) drawn[#drawn + 1] = s; end
function ui.SameLine() end
function ui.Separator() end
function ui.Spacing() end
function ui.IsAnyItemActive() return ui.anyActive; end
function ui.SetNextWindowSize() end

package.preload['imgui'] = function () return ui; end
local options = require('options');

local function hasDrawn(needle)
    for _, s in ipairs(drawn) do
        if s == needle or keyOf(s) == needle then
            return true;
        end
    end
    return false;
end

t.test('every field has a default of its kind, within its own bounds', function ()
    local d = options.defaults();
    local seen = {};
    for _, f in ipairs(options.FIELDS) do
        t.eq(seen[f.key], nil, 'twice: ' .. f.key);
        seen[f.key] = true;
        local v = d[f.key];
        if f.kind == 'bool' then
            t.eq(type(v), 'boolean', f.key);
        elseif f.kind == 'int' or f.kind == 'float' then
            t.eq(type(v), 'number', f.key);
            t.truthy(v >= f.min and v <= f.max, f.key);
            if f.kind == 'int' then
                t.eq(v, math.floor(v), f.key);
            end
        elseif f.kind == 'color' then
            t.eq(#v, 4, f.key);
        elseif f.kind == 'choice' then
            t.truthy(options.index(f.choices, v) ~= nil, f.key);
        else
            error('unknown kind ' .. tostring(f.kind));
        end
        t.truthy(type(f.label) == 'string' and #f.label > 0, f.key .. ' label');
    end
    t.eq(d.rows, 8);
    t.eq(d.particles, 1024);
    t.eq(d.shadowAbsorb, 'lsb');
    t.eq(d.values, 'era');
    t.eq(d.fontScale, 1);
    t.eq({ d.x, d.y }, { 100, 100 });
end);

t.test('defaults are fresh each time, colours included', function ()
    local a, b = options.defaults(), options.defaults();
    a.ceColor[1] = 0;
    t.eq(b.ceColor[1] ~= 0, true);
end);

t.test('set takes a value of the right kind within bounds and refuses the rest', function ()
    local s = options.defaults();
    t.eq(options.set(s, 'rows', 3), true);
    t.eq(s.rows, 3);
    t.eq(options.set(s, 'rows', 0), false);
    t.eq(options.set(s, 'rows', 2.5), false);
    t.eq(options.set(s, 'rows', '4'), false);
    t.eq(s.rows, 3);
    t.eq(options.set(s, 'fontScale', 2.5), true);
    t.eq(options.set(s, 'fontScale', 2.6), false);
    t.eq(options.set(s, 'debug', true), true);
    t.eq(options.set(s, 'debug', 0), false);
    t.eq(options.set(s, 'shadowAbsorb', 'era'), true);
    t.eq(options.set(s, 'shadowAbsorb', 'maybe'), false);
    t.eq(options.set(s, 'values', 'lsb'), true);
    t.eq(options.set(s, 'values', 'wiki'), false);
    t.eq(s.values, 'lsb');
    t.eq(options.set(s, 'nothing', 1), false);
    t.eq(s.nothing, nil);
end);

t.test('a colour is set in place, each channel rounded to a thousandth and held to 0..1', function ()
    local s = options.defaults();
    local before = s.ceColor;
    t.eq(options.set(s, 'ceColor', { 0.12345, 1.5, -1, 0.5 }), true);
    t.eq(s.ceColor, { 0.123, 1, 0, 0.5 });
    t.eq(s.ceColor == before, true, 'the same table');
    t.eq(options.set(s, 'ceColor', { 1, 1, 1 }), false);
    t.eq(options.set(s, 'ceColor', { 1, 1, 'x', 1 }), false);
    t.eq(options.set(s, 'ceColor', 'red'), false);
end);

t.test('sanitize holds a hand-edited file to what the fields allow, and repairs a broken colour', function ()
    local s = options.defaults();
    s.rows, s.particles, s.fontScale = 40, -5, 7;
    s.shadowAbsorb = 'ERA';
    s.ceColor = { 2, 'x' };
    s.veColor[2] = 3;
    s.x = 12;
    options.sanitize(s);
    t.eq({ s.rows, s.particles, s.fontScale }, { 18, 0, 2.5 });
    t.eq(s.shadowAbsorb, 'lsb');
    t.eq(s.ceColor, options.defaults().ceColor);
    t.eq(s.veColor[2], 1);
    t.eq(s.x, 12, 'keys that are not fields are left alone');
end);

local function panelContext()
    local s = options.defaults();
    local p = options.panel();
    local changed, saves = {}, 0;
    local hooks = {};
    hooks.change = function (key) changed[#changed + 1] = key; end;
    hooks.save = function (keys, count)
        saves = saves + 1;
        hooks.saved = {};
        for i = 1, count do
            hooks.saved[i] = keys[i];
        end
    end;
    drawn, acts = {}, {};
    return s, p, hooks, changed, function () return saves; end;
end

t.test('the panel draws nothing while closed, and a widget for every field once open', function ()
    local s, p, hooks = panelContext();
    options.render(p, s, hooks);
    t.eq({ ui.begun, #drawn }, { 0, 0 });

    ui.begun, ui.ended = 0, 0;
    p.open[1] = true;
    options.render(p, s, hooks);
    t.eq({ ui.begun, ui.ended }, { 1, 1 });
    for _, f in ipairs(options.FIELDS) do
        if f.kind == 'choice' then
            for _, c in ipairs(f.choices) do
                t.truthy(hasDrawn(f.key .. '.' .. c), f.key .. ' ' .. c);
            end
        else
            t.truthy(hasDrawn(f.key), f.key);
        end
    end
    t.truthy(hasDrawn('defaults'), 'a defaults button');
end);

t.test('a changed widget sets the value, reports the key, and is saved once the hand is off it', function ()
    local s, p, hooks, changed, saves = panelContext();
    p.open[1] = true;
    acts.rows = 3;
    acts.log = false;
    ui.anyActive = true;
    options.render(p, s, hooks);
    t.eq({ s.rows, s.log }, { 3, false });
    t.eq(changed, { 'rows', 'log' });
    t.eq(saves(), 0, 'still dragging');

    ui.anyActive = false;
    options.render(p, s, hooks);
    t.eq(saves(), 1);
    t.eq(hooks.saved, { 'rows', 'log' }, 'told what changed');
    options.render(p, s, hooks);
    t.eq(saves(), 1, 'once');
end);

t.test('a deferred field applies once the slider is let go, not on every frame of the drag', function ()
    local s, p, hooks, changed, saves = panelContext();
    p.open[1] = true;
    acts.particles = 300;
    ui.anyActive = true;
    options.render(p, s, hooks);
    t.eq(s.particles, 300, 'the value moves');
    t.eq(changed, {}, 'nothing told yet');
    acts.particles = 200;
    options.render(p, s, hooks);
    t.eq(changed, {});
    ui.anyActive = false;
    options.render(p, s, hooks);
    t.eq(changed, { 'particles' });
    t.eq({ saves(), hooks.saved[1] }, { 1, 'particles' });
end);

t.test('a colour edit lands in the settings rounded; a choice is picked by its button', function ()
    local s, p, hooks, changed = panelContext();
    p.open[1] = true;
    acts.veColor = { 0.5, 0.25, 0.125, 0.9999 };
    acts['shadowAbsorb.era'] = true;
    options.render(p, s, hooks);
    t.eq(s.veColor, { 0.5, 0.25, 0.125, 1 });
    t.eq(s.shadowAbsorb, 'era');
    t.eq(changed, { 'veColor', 'shadowAbsorb' });
    -- Picking the choice already set changes nothing.
    acts['shadowAbsorb.era'] = true;
    options.render(p, s, hooks);
    t.eq(#changed, 2);
end);

t.test('the defaults button puts every field back, reporting only those that moved', function ()
    local s, p, hooks, changed, saves = panelContext();
    p.open[1] = true;
    s.rows, s.shadowAbsorb = 2, 'era';
    s.ceColor[1] = 0.1;
    s.x = 640;
    acts.defaults = true;
    options.render(p, s, hooks);
    local d = options.defaults();
    t.eq({ s.rows, s.shadowAbsorb, s.ceColor[1], s.x }, { d.rows, d.shadowAbsorb, d.ceColor[1], 640 });
    table.sort(changed);
    t.eq(changed, { 'ceColor', 'rows', 'shadowAbsorb' });
    t.eq(saves(), 1);
end);

t.test('closing the window with its button saves and stops drawing', function ()
    local s, p, hooks, _, saves = panelContext();
    p.open[1] = true;
    acts.rows = 5;
    ui.anyActive = true;
    options.render(p, s, hooks);
    acts.close = true;
    options.render(p, s, hooks);
    t.eq(p.open[1], false);
    t.eq(saves(), 1);
    ui.anyActive = false;
    ui.begun = 0;
    options.render(p, s, hooks);
    t.eq(ui.begun, 0);
end);

t.test('a reload note is drawn for what only a reload applies', function ()
    local s, p, hooks = panelContext();
    p.open[1] = true;
    options.render(p, s, hooks);
    local noted = false;
    for _, f in ipairs(options.FIELDS) do
        if f.note ~= nil then
            noted = true;
            t.truthy(hasDrawn(f.note), f.note);
        end
    end
    t.truthy(noted, 'particles has one');
end);

t.test('an idle open panel allocates nothing', function ()
    local s, p, hooks = panelContext();
    p.open[1] = true;
    options.render(p, s, hooks);
    drawn = setmetatable({}, { __newindex = function () end });
    local grown = t.allocated(function () options.render(p, s, hooks); end, 200);
    t.truthy(grown < 1, ('%g KB'):format(grown));
end);

return t.done();

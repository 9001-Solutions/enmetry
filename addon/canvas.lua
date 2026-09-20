-- Must be required before WINDOW_FLAGS below: the ImGui* globals come from this module.
local imgui = require('imgui');

local canvas = {
    x = 100,
    y = 100,
    pending = true,
    width = 460,
    maxLines = 16,
    onMove = nil,
    scale = 1,
    compact = false,
    colors = nil,  -- palette must set this before the first render
};

local PAD = 6;
local PAD_RIGHT = 14;
local BASE_WIDTH = 460;
local BASE_NAME_WIDTH = 96;
local BASE_LABEL_WIDTH = 84;
local BASE_BAR_HEIGHT = 10;
local BASE_COMPACT_WIDTH = 260;
local BASE_COMPACT_NAME_WIDTH = 80;
local NAME_WIDTH, LABEL_WIDTH, BAR_HEIGHT = BASE_NAME_WIDTH, BASE_LABEL_WIDTH, BASE_BAR_HEIGHT;
local LABEL_PROBE = '+00000 / +00000';

canvas.barWidth = canvas.width - PAD - PAD_RIGHT - NAME_WIDTH - LABEL_WIDTH;

local HAS_FONT_SCALE = imgui.SetWindowFontScale ~= nil;

local WINDOW_FLAGS = bit.bor(
    ImGuiWindowFlags_NoDecoration,
    ImGuiWindowFlags_NoBackground,
    ImGuiWindowFlags_NoSavedSettings,
    ImGuiWindowFlags_NoFocusOnAppearing,
    ImGuiWindowFlags_NoNav);

local pos = { 0, 0 };
local size = { 0, 0 };
local zero = { 0, 0 };
local p1 = { 0, 0 };
local p2 = { 0, 0 };

local LEVELS = 64;

local ORDERING_ONLY = 'ordering only';
local ANCHORED = 're-anchored';
local HOLDS_HATE = 'holds hate';

-- Colours and text metrics need a live ImGui context, so they are resolved on first render.
local colors = nil;
local measuredScale = nil;
local stampWidth = 0;
local orderingWidth = 0;

local rgba = { 0, 0, 0, 0 };

local function ramp(into, c, alpha)
    rgba[1], rgba[2], rgba[3] = c[1], c[2], c[3];
    for level = 0, LEVELS do
        rgba[4] = c[4] * alpha * level / LEVELS;
        into[level] = imgui.GetColorU32(rgba);
    end
    return into;
end

local DELTA = 0.40;

local ramps = { ce = {}, ve = {}, ceDelta = {}, veDelta = {} };

local function resolveColors()
    local p = canvas.colors;
    return {
        panel = imgui.GetColorU32(p.panel),
        rule = imgui.GetColorU32({ 1.00, 1.00, 1.00, 0.10 }),
        title = imgui.GetColorU32({ 0.92, 0.80, 0.55, 1.00 }),
        status = imgui.GetColorU32({ 0.60, 0.62, 0.66, 1.00 }),
        stamp = imgui.GetColorU32({ 0.45, 0.47, 0.52, 1.00 }),
        line = imgui.GetColorU32({ 0.86, 0.88, 0.92, 1.00 }),
        me = imgui.GetColorU32({ 0.45, 0.85, 0.45, 1.00 }),
        mob = imgui.GetColorU32({ 0.92, 0.80, 0.55, 1.00 }),
        track = imgui.GetColorU32({ 1.00, 1.00, 1.00, 0.06 }),
        ce = ramp(ramps.ce, p.ce, 1),
        ve = ramp(ramps.ve, p.ve, 1),
        ceDelta = ramp(ramps.ceDelta, p.ce, DELTA),
        veDelta = ramp(ramps.veDelta, p.ve, DELTA),
        tick = imgui.GetColorU32({ 1.00, 1.00, 1.00, 0.95 }),
        holder = imgui.GetColorU32({ 0.95, 0.35, 0.35, 1.00 }),
        cap = imgui.GetColorU32({ 1.00, 1.00, 1.00, 0.22 }),
        marker = imgui.GetColorU32({ 1.00, 1.00, 1.00, 0.85 }),
    };
end

local function text(dl, x, y, color, s)
    p1[1], p1[2] = x, y;
    dl:AddText(p1, color, s);
end

local function rect(dl, x1, y1, x2, y2, color)
    p1[1], p1[2] = x1, y1;
    p2[1], p2[2] = x2, y2;
    dl:AddRectFilled(p1, p2, color, 0);
end

local function gradient(dl, x1, y1, x2, y2, left, right)
    p1[1], p1[2] = x1, y1;
    p2[1], p2[2] = x2, y2;
    dl:AddRectFilledMultiColor(p1, p2, left, right, right, left);
end

local function fade(shades, alpha)
    return shades[math.floor(alpha * LEVELS + 0.5)];
end

local function rule(dl, wx, y)
    rect(dl, wx + PAD, y + PAD / 2, wx + canvas.width - PAD_RIGHT, y + PAD / 2 + 1, colors.rule);
end

local function drawBars(dl, x, y, lineHeight, title, layout)
    text(dl, x, y, colors.mob, title);
    if layout.anchored > 0 then
        text(dl, x + imgui.CalcTextSize(title) + PAD, y, colors.status, ANCHORED);
    end
    if not layout.clean then
        text(dl, x + canvas.width - PAD - PAD_RIGHT - orderingWidth, y, colors.status, ORDERING_ONLY);
    end
    y = y + lineHeight;

    local barX = x + NAME_WIDTH;
    if layout.holder ~= nil then
        text(dl, x, y, colors.holder, layout.holder);
        text(dl, barX, y, colors.status, HOLDS_HATE);
        y = y + lineHeight;
    end

    local ceColors = layout.clean and colors.ce or colors.ceDelta;
    local veColors = layout.clean and colors.ve or colors.veDelta;
    local barTop = y;
    local inset = (lineHeight - BAR_HEIGHT) / 2;
    for i = 1, layout.count do
        local r = layout.rows[i];
        text(dl, x, y, r.id == layout.me and colors.me or colors.line, r.name);
        local top = y + inset;
        rect(dl, barX, top, barX + canvas.barWidth, top + BAR_HEIGHT, colors.track);
        local bottom = top + BAR_HEIGHT;
        for k = 1, r.pieceCount do
            local piece = r.pieces[k];
            local shades = piece.ve and veColors or ceColors;
            if piece.a1 >= 1 and piece.a2 >= 1 then
                rect(dl, barX + piece.x1, top, barX + piece.x2, bottom, shades[LEVELS]);
            else
                gradient(dl, barX + piece.x1, top, barX + piece.x2, bottom, fade(shades, piece.a1), fade(shades, piece.a2));
            end
        end
        if r.tick ~= nil then
            rect(dl, barX + r.tick, top, barX + r.tick + 1, bottom, colors.tick);
        end
        if not canvas.compact then
            text(dl, barX + canvas.barWidth + PAD, y, colors.status, r.label);
        end
        y = y + lineHeight;
    end

    if layout.capX ~= nil then
        rect(dl, barX + layout.capX, barTop, barX + layout.capX + 1, y, colors.cap);
    end
    if layout.marker ~= nil then
        rect(dl, barX + layout.marker, barTop, barX + layout.marker + 1, y, colors.marker);
    end
    return y;
end

-- The tables are kept, not copied; a change made in them shows after recolor.
function canvas.palette(p)
    canvas.colors = p;
    colors = nil;
end

function canvas.recolor()
    colors = nil;
end

function canvas.rescale(scale, compact)
    compact = compact == true;
    if scale == canvas.scale and compact == canvas.compact then
        return;
    end
    canvas.scale, canvas.compact = scale, compact;
    canvas.width = (compact and BASE_COMPACT_WIDTH or BASE_WIDTH) * scale;
    NAME_WIDTH = (compact and BASE_COMPACT_NAME_WIDTH or BASE_NAME_WIDTH) * scale;
    LABEL_WIDTH, BAR_HEIGHT = (compact and 0 or BASE_LABEL_WIDTH) * scale, BASE_BAR_HEIGHT * scale;
    canvas.barWidth = canvas.width - PAD - PAD_RIGHT - NAME_WIDTH - LABEL_WIDTH;
    measuredScale = nil;
end

local function pushFontScale(scale)
    if HAS_FONT_SCALE then
        imgui.SetWindowFontScale(scale);
        return false;
    end
    if scale == 1 then
        return false;
    end
    imgui.PushFont(imgui.GetFont(), imgui.GetFontSize() * scale);
    return true;
end

-- ImGui's window positions outlive an addon reload, so a position read from disk must be forced once.
function canvas.place(x, y)
    canvas.x, canvas.y = x, y;
    canvas.pending = true;
end

function canvas.render(recent, title, layout)
    if colors == nil then
        colors = resolveColors();
    end

    local scale = canvas.scale;
    local fontHeight = imgui.GetTextLineHeight();
    local lineHeight = fontHeight * scale + (imgui.GetTextLineHeightWithSpacing() - fontHeight);
    local shown = 0;
    if recent ~= nil then
        shown = math.min(recent:size(), canvas.maxLines);
    end
    local barRows = 0;
    if layout ~= nil and layout.count > 0 then
        barRows = 1 + (layout.holder ~= nil and 1 or 0) + layout.count;
    end
    local header = not (canvas.compact and barRows > 0);
    local height = PAD * 2 + lineHeight * ((header and 1 or 0) + barRows + shown)
        + (barRows > 0 and header and PAD or 0) + (shown > 0 and PAD or 0);

    pos[1], pos[2] = canvas.x, canvas.y;
    size[1], size[2] = canvas.width, height;
    imgui.SetNextWindowPos(pos, canvas.pending and ImGuiCond_Always or ImGuiCond_FirstUseEver);
    canvas.pending = false;
    imgui.SetNextWindowSize(size, ImGuiCond_Always);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, zero);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);

    if imgui.Begin('enmetry##canvas', true, WINDOW_FLAGS) then
        local pushed = pushFontScale(scale);
        if measuredScale ~= scale then
            measuredScale = scale;
            stampWidth = imgui.CalcTextSize('00:00:00  ');
            orderingWidth = imgui.CalcTextSize(ORDERING_ONLY);
            if not canvas.compact then
                local needed = imgui.CalcTextSize(LABEL_PROBE) + PAD;
                local base = BASE_LABEL_WIDTH * scale;
                LABEL_WIDTH = math.max(base, needed);
                canvas.width = BASE_WIDTH * scale + LABEL_WIDTH - base;
            end
        end
        local wx, wy = imgui.GetWindowPos();
        local dl = imgui.GetWindowDrawList();

        p1[1], p1[2] = wx, wy;
        p2[1], p2[2] = wx + canvas.width, wy + height;
        dl:AddRectFilled(p1, p2, colors.panel, 4);

        local top = wy + PAD;
        local y = top;
        if header then
            text(dl, wx + PAD, top, colors.title, 'enmetry');
            y = top + lineHeight;
        end
        if barRows > 0 then
            if header then
                rule(dl, wx, y);
                y = y + PAD;
            end
            y = drawBars(dl, wx + PAD, y, lineHeight, title or '', layout);
        end

        if shown > 0 then
            rule(dl, wx, y);
            y = y + PAD;
            for n = 1, shown do
                local line, stamp = recent:at(n);
                text(dl, wx + PAD, y, colors.stamp, stamp);
                text(dl, wx + PAD + stampWidth, y, colors.line, line);
                y = y + lineHeight;
            end
        end

        if (wx ~= canvas.x or wy ~= canvas.y) and not imgui.IsMouseDown(ImGuiMouseButton_Left) then
            canvas.x, canvas.y = wx, wy;
            if canvas.onMove ~= nil then
                canvas.onMove(wx, wy);
            end
        end
        if pushed then
            imgui.PopFont();
        end
    end
    imgui.End();
    imgui.PopStyleVar(2);
end

return canvas;

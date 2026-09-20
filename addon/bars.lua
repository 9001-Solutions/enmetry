local bars = {};

-- One per filter.QUANTILES entry; the two counts must match.
bars.ALPHAS = { 1, 0.75, 0.5, 0.25, 0 };
local STOPS = #bars.ALPHAS;

local PIECES = STOPS + 1;

local function newRow()
    local pieces = {};
    for i = 1, PIECES do
        pieces[i] = { x1 = 0, x2 = 0, a1 = 1, a2 = 1, ve = false };
    end
    return {
        id = 0, name = '', ce = 0, ve = 0, total = 0, order = 0, ceWidth = 0, veWidth = 0,
        label = '', labelCe = -1, labelVe = -1, labelClean = true,
        band = { 0, 0, 0, 0, 0 },
        lowerX = 0, upperX = 0,
        tick = nil,
        pieces = pieces,
        pieceCount = 0,
    };
end

function bars.new(limit)
    local rows = {};
    local pool = {};
    for i = 1, limit do
        pool[i] = newRow();
    end
    return {
        limit = limit,
        pool = pool,
        all = {},
        rows = rows,
        count = 0,
        clean = true,
        anchored = 0,
        holder = nil,
        marker = nil,
        capX = nil,
        fallback = {},
    };
end

local function byTotal(a, b)
    if a.total ~= b.total then
        return a.total > b.total;
    end
    return a.order < b.order;
end

local function nameFor(layout, id, nameOf)
    local name = nameOf(id);
    if name ~= nil then
        return name;
    end
    local cached = layout.fallback[id];
    if cached == nil then
        cached = ('0x%08X'):format(id);
        layout.fallback[id] = cached;
    end
    return cached;
end

local function piece(r, x1, x2, a1, a2, ve)
    if x2 <= x1 then
        return;
    end
    local n = r.pieceCount + 1;
    local p = r.pieces[n];
    p.x1, p.x2, p.a1, p.a2, p.ve = x1, x2, a1, a2, ve;
    r.pieceCount = n;
end

local function span(r, x1, x2, a1, a2, split)
    if x2 <= x1 then
        return;
    end
    if split <= x1 then
        piece(r, x1, x2, a1, a2, true);
    elseif split >= x2 then
        piece(r, x1, x2, a1, a2, false);
    else
        local a = a1 + (a2 - a1) * (split - x1) / (x2 - x1);
        piece(r, x1, split, a1, a, false);
        piece(r, split, x2, a, a2, true);
    end
end

local function place(r, scale, banded)
    local band, alphas = r.band, bars.ALPHAS;
    r.ceWidth, r.veWidth = r.ce * scale, r.ve * scale;
    r.lowerX, r.upperX = band[1] * scale, band[STOPS] * scale;
    r.tick = banded and r.upperX > 0 and band[(STOPS + 1) / 2] * scale or nil;
    local split = r.ve > 0 and r.ceWidth or r.upperX;
    r.pieceCount = 0;
    span(r, 0, r.lowerX, 1, 1, split);
    for k = 1, STOPS - 1 do
        span(r, band[k] * scale, band[k + 1] * scale, alphas[k], alphas[k + 1], split);
    end
end

local function label(r, clean)
    if r.labelCe == r.ce and r.labelVe == r.ve and r.labelClean == clean then
        return;
    end
    local format = clean and '%d / %d' or '+%d / +%d';
    r.label, r.labelCe, r.labelVe, r.labelClean = format:format(r.ce, r.ve), r.ce, r.ve, clean;
end

function bars.layout(layout, list, nameOf, width, track)
    local all, rows = layout.all, layout.rows;
    local clean = track == nil or track.clean;
    local n = 0;
    local leader, most = nil, 0;
    local banded = list ~= nil and list.band ~= nil;

    if list ~= nil then
        local count = list:count();
        for i = 1, count do
            local id = list:idAt(i);
            local ce, ve, active = list:get(id);
            local total = ce + ve;
            if active and (leader == nil or total > leader) then
                leader = total;
            end

            n = n + 1;
            local r = layout.pool[n];
            if r == nil then
                r = newRow();
                layout.pool[n] = r;
            end
            r.id, r.ce, r.ve, r.total, r.order = id, ce, ve, total, i;
            local band = r.band;
            if banded then
                band[1], band[2], band[3], band[4], band[5] = list:band(id);
            else
                band[1], band[2], band[3], band[4], band[5] = total, total, total, total, total;
            end
            if band[STOPS] > most then
                most = band[STOPS];
            end
            r.name = nameFor(layout, id, nameOf);
            label(r, clean);
            all[n] = r;
        end
    end

    layout.clean = clean;
    layout.anchored = track ~= nil and track.anchored or 0;
    layout.holder = nil;
    if track ~= nil and track.holder ~= nil and not track.holderModelled then
        layout.holder = nameFor(layout, track.holder, nameOf);
    end

    local scale;
    if clean then
        scale = list ~= nil and width / (2 * list.cap) or 0;
        layout.capX = list ~= nil and list.cap * scale or nil;
        layout.marker = leader ~= nil and layout.holder == nil and leader * scale or nil;
    else
        scale = most > 0 and width / most or 0;
        layout.capX, layout.marker = nil, nil;
    end
    for i = 1, n do
        place(all[i], scale, banded);
    end

    for i = n + 1, #all do
        all[i] = nil;
    end
    table.sort(all, byTotal);

    local shown = math.min(n, layout.limit);
    for i = 1, shown do
        rows[i] = all[i];
    end
    for i = shown + 1, #rows do
        rows[i] = nil;
    end
    layout.count = shown;
end

return bars;

local filter = require('filter');
local log = require('log');

local research = {};
research.__index = research;

-- Bumped whenever a line's shape changes, so old logs can still be read.
research.VERSION = 1;

local function logistic(x)
    return 1 / (1 + math.exp(-x));
end

function research.likelihood(margin, switch)
    local p = filter.FLOOR + (1 - filter.FLOOR) * logistic(margin / filter.SCALE);
    return p ^ (switch and filter.SWITCH or filter.STEADY);
end

local function marginOf(totals, target)
    local mine, best = nil, nil;
    for id, total in pairs(totals) do
        if id == target then
            mine = total;
        elseif best == nil or total > best then
            best = total;
        end
    end
    if mine == nil or best == nil then
        return nil;
    end
    return mine - best;
end

local shadowAbsorb = {
    key = 'shadowAbsorb',
    question = 'which Utsusemi absorbs cost CE?',
    hypotheses = { 'lsb', 'era' },
    describe = {
        lsb = 'every absorb, the last shadow included',
        era = 'only an absorb that leaves shadows: the last is free',
    },
    prior = { lsb = 0.5, era = 0.5 },
    live = 'lsb',
};

function shadowAbsorb.event(obs)
    if not obs.clean or obs.covered then
        return nil;
    end
    local rows, seen = {}, false;
    for _, row in ipairs(obs.rows) do
        rows[#rows + 1] = { row.id, row.total, row.last or 0 };
        seen = seen or row.id == obs.target;
    end
    if not seen then
        return nil;
    end
    return { mob = obs.mob, target = obs.target, switch = obs.switch, rule = obs.rule, loss = obs.loss, rows = rows };
end

function shadowAbsorb.margin(fields, hypothesis)
    local totals = {};
    for _, row in ipairs(fields.rows) do
        local total = row[2];
        if hypothesis ~= fields.rule then
            total = total + (hypothesis == 'era' and 1 or -1) * fields.loss * row[3];
        end
        totals[row[1]] = total;
    end
    return marginOf(totals, fields.target);
end

local avatarShare = {
    key = 'avatarShare',
    question = 'does a summoner share the enmity their avatar generates?',
    hypotheses = { 'none' },
    describe = { none = 'no share: the summoner gets only a 0/0 entry, as LandSandBoat' },
    params = {},
    prior = { none = 0.25 },
    live = 'none',
};

local FORMS = { ce = 'CE', ve = 'VE', both = 'CE and VE' };
local FORM_ORDER = { 'ce', 've', 'both' };
local SOURCES = { all = 'everything their avatar generates', pact = 'their avatar\'s Blood Pacts' };
local SOURCE_ORDER = { 'all', 'pact' };
local SHARES = { 25, 50, 75, 100 };

do
    local rest = #FORM_ORDER * #SOURCE_ORDER * #SHARES;
    for _, form in ipairs(FORM_ORDER) do
        for _, source in ipairs(SOURCE_ORDER) do
            for _, share in ipairs(SHARES) do
                local name = ('%s %s %d%%'):format(form, source, share);
                avatarShare.hypotheses[#avatarShare.hypotheses + 1] = name;
                avatarShare.describe[name] = ('the summoner gains %d%% of the %s of %s'):format(share, FORMS[form], SOURCES[source]);
                avatarShare.params[name] = { form = form, source = source, share = share };
                avatarShare.prior[name] = (1 - avatarShare.prior.none) / rest;
            end
        end
    end
end

function avatarShare.event(obs)
    if not obs.clean or obs.covered or #obs.avatars == 0 then
        return nil;
    end
    local rows, seen = {}, false;
    for _, row in ipairs(obs.rows) do
        rows[#rows + 1] = { row.id, row.total };
        seen = seen or row.id == obs.target;
    end
    local avatars = {};
    for _, a in ipairs(obs.avatars) do
        avatars[#avatars + 1] = { a.pet, a.master, a.pactCe, a.pactVe, a.otherCe, a.otherVe };
        seen = seen or a.pet == obs.target or a.master == obs.target;
    end
    if not seen then
        return nil;
    end
    return { mob = obs.mob, target = obs.target, switch = obs.switch, rows = rows, avatars = avatars };
end

local function avatarShares(a, p)
    local own = a[3] + a[4] + a[5] + a[6];
    if p == nil then
        return own, 0;
    end
    local ce, ve = a[3], a[4];
    if p.source == 'all' then
        ce, ve = ce + a[5], ve + a[6];
    end
    local shared = 0;
    if p.form ~= 've' then
        shared = shared + ce;
    end
    if p.form ~= 'ce' then
        shared = shared + ve;
    end
    return own, shared * p.share / 100;
end

function avatarShare.margin(fields, hypothesis)
    local p = avatarShare.params[hypothesis];
    local totals, handed = {}, {};
    for _, a in ipairs(fields.avatars) do
        local own, shared = avatarShares(a, p);
        totals[a[1]] = own;
        handed[a[2]] = (handed[a[2]] or 0) + shared;
    end
    for _, row in ipairs(fields.rows) do
        totals[row[1]] = row[2] + (handed[row[1]] or 0);
        handed[row[1]] = nil;
    end
    for master, shared in pairs(handed) do
        totals[master] = shared;
    end
    return marginOf(totals, fields.target);
end

research.entries = { shadowAbsorb = shadowAbsorb, avatarShare = avatarShare };
research.ORDER = { 'shadowAbsorb', 'avatarShare' };

function research.qualifies(entry, fields)
    local lo, hi = math.huge, -math.huge;
    for _, h in ipairs(entry.hypotheses) do
        local margin = entry.margin(fields, h);
        if margin == nil then
            return false;
        end
        lo, hi = math.min(lo, margin), math.max(hi, margin);
    end
    return hi > lo;
end

function research.fit(entry, events)
    local loglik, n, switches = {}, 0, 0;
    for _, h in ipairs(entry.hypotheses) do
        loglik[h] = 0;
    end
    for _, fields in ipairs(events) do
        local scorable = true;
        for _, h in ipairs(entry.hypotheses) do
            if entry.margin(fields, h) == nil then
                scorable = false;
            end
        end
        if scorable then
            n = n + 1;
            switches = switches + (fields.switch and 1 or 0);
            for _, h in ipairs(entry.hypotheses) do
                loglik[h] = loglik[h] + math.log(research.likelihood(entry.margin(fields, h), fields.switch));
            end
        end
    end
    local top = -math.huge;
    for _, h in ipairs(entry.hypotheses) do
        top = math.max(top, loglik[h] + math.log(entry.prior[h]));
    end
    local posterior, sum, best = {}, 0, nil;
    for _, h in ipairs(entry.hypotheses) do
        posterior[h] = math.exp(loglik[h] + math.log(entry.prior[h]) - top);
        sum = sum + posterior[h];
    end
    for _, h in ipairs(entry.hypotheses) do
        posterior[h] = posterior[h] / sum;
        if best == nil or posterior[h] > posterior[best] then
            best = h;
        end
    end
    return { n = n, switches = switches, loglik = loglik, posterior = posterior, best = best };
end

function research.ranked(entry, fit)
    local out = {};
    for i, h in ipairs(entry.hypotheses) do
        out[i] = h;
    end
    table.sort(out, function (a, b)
        if fit.posterior[a] ~= fit.posterior[b] then
            return fit.posterior[a] > fit.posterior[b];
        end
        return a < b;
    end);
    return out;
end

function research.serialize(fits, wall)
    local lines = { 'return {', ('    version = %d,'):format(research.VERSION), ('    scored = %d,'):format(wall),
        ('    date = %q,'):format(os.date('%Y-%m-%d %H:%M:%S', wall)), '    entries = {' };
    for _, key in ipairs(research.ORDER) do
        local fit = fits[key];
        if fit ~= nil then
            lines[#lines + 1] = ('        %s = {'):format(key);
            lines[#lines + 1] = ('            observations = %d,'):format(fit.n);
            lines[#lines + 1] = ('            switches = %d,'):format(fit.switches);
            lines[#lines + 1] = '            posterior = {';
            for _, h in ipairs(research.ranked(research.entries[key], fit)) do
                lines[#lines + 1] = ('                [%q] = %.6g,'):format(h, fit.posterior[h]);
            end
            lines[#lines + 1] = '            },';
            lines[#lines + 1] = '        },';
        end
    end
    lines[#lines + 1] = '    },';
    lines[#lines + 1] = '}';
    return table.concat(lines, '\n') .. '\n';
end

function research.new(opts)
    local live = {};
    for key, entry in pairs(research.entries) do
        live[key] = entry.live;
    end
    for key, h in pairs(opts.live or {}) do
        if research.entries[key] ~= nil and research.entries[key].describe[h] ~= nil then
            live[key] = h;
        end
    end
    return setmetatable({
        log = log.new({ sink = opts.sink, clock = opts.clock }),
        wall = opts.wall or os.time,
        live = live,
        counts = {},
        cost = 0,
    }, research);
end

function research:session(fields)
    fields.logVersion = research.VERSION;
    fields.live = self.live;
    self.log:write('session', fields);
    self.log:flush();
end

function research:observe(obs)
    local written = 0;
    for _, key in ipairs(research.ORDER) do
        local entry = research.entries[key];
        local fields = entry.event(obs);
        if fields ~= nil and research.qualifies(entry, fields) then
            fields.entry, fields.wall = key, self.wall();
            self.log:write('observation', fields);
            self.counts[key] = (self.counts[key] or 0) + 1;
            written = written + 1;
        end
    end
    return written;
end

function research:setLive(key, h)
    local entry = research.entries[key];
    if entry == nil or entry.describe[h] == nil or self.live[key] == h then
        return;
    end
    self.live[key] = h;
    self.log:write('live', { entry = key, hypothesis = h });
end

function research:charge(seconds)
    self.cost = self.cost + seconds;
end

function research:flush()
    self.log:flush();
end

function research:readout(persisted, path)
    local out = { ('research: %d open questions, logged to %s'):format(#research.ORDER, path) };
    for _, key in ipairs(research.ORDER) do
        local entry = research.entries[key];
        out[#out + 1] = ('%s -- %s'):format(key, entry.question);
        local count = self.counts[key] or 0;
        local kept = persisted and persisted.entries and persisted.entries[key];
        local scored;
        if type(kept) == 'table' and type(kept.posterior) == 'table' then
            local ranked = {};
            for _, h in ipairs(entry.hypotheses) do
                if type(kept.posterior[h]) == 'number' then
                    ranked[#ranked + 1] = h;
                end
            end
            table.sort(ranked, function (a, b) return kept.posterior[a] > kept.posterior[b]; end);
            local parts = {};
            for i = 1, math.min(3, #ranked) do
                parts[i] = ('%s %.0f%%'):format(ranked[i], kept.posterior[ranked[i]] * 100);
            end
            scored = ('scored %s over %d: %s'):format(tostring(persisted.date), tonumber(kept.observations) or 0,
                table.concat(parts, ', '));
        else
            scored = 'not yet scored: luajit tools/research.lua';
        end
        local live = self.live[key];
        out[#out + 1] = ('  running %s (%s) | %d logged this session | %s'):format(live, entry.describe[live], count, scored);
    end
    return out;
end

return research;

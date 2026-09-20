--[[
* The research registry: its entries, which attacks qualify for each, how
* the hypotheses score them, the live log, the persisted posterior, the JSON
* reader and the offline tool.
*
* Run: luajit tests/test_research.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;./tools/?.lua;' .. package.path;
local t = require('helpers');
local research = require('research');
local filter = require('filter');
local log = require('log');
local store = require('store');
local json = require('json');
local offline = assert(loadfile('tools/research.lua'))();

local TANK, NIN, SMN, AVATAR, MOB = 0x0001E240, 0x0001E241, 0x0001E242, 0x0100A030, 0x0100A012;

local function obs(over)
    local o = {
        mob = MOB, target = NIN, switch = false, clean = true, covered = false, rule = 'lsb', loss = 25,
        rows = { { id = TANK, total = 1000, last = 0 }, { id = NIN, total = 1010, last = 2 } },
        avatars = {},
    };
    for k, v in pairs(over or {}) do
        o[k] = v;
    end
    return o;
end

local shadow, avatar = research.entries.shadowAbsorb, research.entries.avatarShare;

t.test('every entry declares its hypotheses, a prior summing to one, and a live hypothesis among them', function ()
    t.eq(research.ORDER, { 'shadowAbsorb', 'avatarShare' });
    for _, key in ipairs(research.ORDER) do
        local entry = research.entries[key];
        t.eq(entry.key, key);
        t.truthy(#entry.hypotheses >= 2, key .. ' has hypotheses');
        local sum, live = 0, false;
        for _, h in ipairs(entry.hypotheses) do
            t.truthy(entry.prior[h] > 0, key .. ' prior ' .. h);
            t.truthy(entry.describe[h], key .. ' describes ' .. h);
            sum = sum + entry.prior[h];
            live = live or h == entry.live;
        end
        t.truthy(math.abs(sum - 1) < 1e-9, key .. ' prior sums to ' .. sum);
        t.truthy(live, key .. ' runs a hypothesis it holds');
    end
    t.eq(shadow.live, 'lsb');
    t.eq(avatar.live, 'none');
    t.eq(#avatar.hypotheses, 25);
    t.eq(avatar.params['both pact 50%'], { form = 'both', source = 'pact', share = 50 });
end);

t.test('an attack is scored as the filter weighs one: floored logistic, steady swings for a fraction', function ()
    t.eq(research.likelihood(0, true), 0.5 + filter.FLOOR / 2);
    t.truthy(research.likelihood(-10000, true) > filter.FLOOR * 0.999, 'floored');
    t.truthy(research.likelihood(400, true) > research.likelihood(200, true), 'rises with the margin');
    t.eq(research.likelihood(200, false), research.likelihood(200, true) ^ filter.STEADY);
end);

t.test('a shadow observation carries every active entry with its last shadows, and converts between rules', function ()
    local fields = shadow.event(obs());
    t.eq(fields, {
        mob = MOB, target = NIN, switch = false, rule = 'lsb', loss = 25, rows = { { TANK, 1000, 0 }, { NIN, 1010, 2 } },
    });
    -- Under LSB the ninja paid 50 CE that era would have spared.
    t.eq(shadow.margin(fields, 'lsb'), 10);
    t.eq(shadow.margin(fields, 'era'), 60);
    t.truthy(research.qualifies(shadow, fields), 'qualifies');

    local era = shadow.event(obs({ rule = 'era' }));
    t.eq(shadow.margin(era, 'era'), 10);
    t.eq(shadow.margin(era, 'lsb'), -40);
end);

t.test('a shadow observation is dropped off a clean list, under Cover, without a target entry, or with nothing to tell apart', function ()
    t.eq(shadow.event(obs({ clean = false })), nil);
    t.eq(shadow.event(obs({ covered = true })), nil);
    t.eq(shadow.event(obs({ target = 0x0001E999 })), nil);
    local same = shadow.event(obs({ rows = { { id = TANK, total = 1000, last = 0 }, { id = NIN, total = 1010, last = 0 } } }));
    t.eq(research.qualifies(shadow, same), false, 'nobody lost a last shadow');
    local alone = shadow.event(obs({ rows = { { id = NIN, total = 1010, last = 2 } } }));
    t.eq(research.qualifies(shadow, alone), false, 'no rival');
    -- A rival who lost last shadows tells them apart as well as the target.
    local rival = shadow.event(obs({ target = TANK, rows = { { id = TANK, total = 1000, last = 0 }, { id = NIN, total = 990, last = 1 } } }));
    t.truthy(research.qualifies(shadow, rival), 'the rival lost one');
    -- A third entry far behind changes nothing between the rules.
    local far = shadow.event(obs({ target = TANK, rows = {
        { id = TANK, total = 1000, last = 0 }, { id = NIN, total = 900, last = 0 }, { id = SMN, total = 100, last = 3 } } }));
    t.eq(research.qualifies(shadow, far), false, 'the loser is not the best rival either way');
end);

local function avatarObs(over)
    local o = obs({
        target = SMN, rows = { { id = TANK, total = 1000, last = 0 }, { id = SMN, total = 300, last = 0 } },
        avatars = { { pet = AVATAR, master = SMN, pactCe = 400, pactVe = 800, otherCe = 100, otherVe = 200 } },
    });
    for k, v in pairs(over or {}) do
        o[k] = v;
    end
    return o;
end

t.test('an avatar observation hands the summoner each hypothesis\'s share, and the avatar its own total', function ()
    local fields = avatar.event(avatarObs());
    t.eq(fields, {
        mob = MOB, target = SMN, switch = false, rows = { { TANK, 1000 }, { SMN, 300 } },
        avatars = { { AVATAR, SMN, 400, 800, 100, 200 } },
    });
    -- The avatar's own 1500 is the best rival under every hypothesis.
    t.eq(avatar.margin(fields, 'none'), 300 - 1500);
    t.eq(avatar.margin(fields, 'ce all 100%'), 300 + 500 - 1500);
    t.eq(avatar.margin(fields, 've pact 50%'), 300 + 400 - 1500);
    t.eq(avatar.margin(fields, 'both all 25%'), 300 + 375 - 1500);
    t.eq(avatar.margin(fields, 'both pact 100%'), 300 + 1200 - 1500);
    t.truthy(research.qualifies(avatar, fields), 'qualifies');

    -- The mob on the avatar: its own total against the summoner's, who leads under a large share.
    local onAvatar = avatar.event(avatarObs({ target = AVATAR }));
    t.eq(avatar.margin(onAvatar, 'none'), 1500 - 1000);
    t.eq(avatar.margin(onAvatar, 'both all 100%'), 1500 - 1800);
    t.truthy(research.qualifies(avatar, onAvatar), 'qualifies');

    -- The mob on the tank, whom only the biggest shares put the summoner ahead of.
    local onTank = avatar.event(avatarObs({ target = TANK }));
    t.eq(avatar.margin(onTank, 'none'), 1000 - 1500);
    t.eq(avatar.margin(onTank, 'both all 100%'), 1000 - 1800);
    t.truthy(research.qualifies(avatar, onTank), 'qualifies');
end);

t.test('an avatar observation is dropped without an avatar, off a clean list, under Cover, or on an outsider', function ()
    t.eq(avatar.event(avatarObs({ avatars = {} })), nil);
    t.eq(avatar.event(avatarObs({ clean = false })), nil);
    t.eq(avatar.event(avatarObs({ covered = true })), nil);
    t.eq(avatar.event(avatarObs({ target = 0x0001E999 })), nil);
    -- A summoner with no entry yet: attacked, they qualify, holding nothing but a share.
    local unlisted = avatar.event(avatarObs({ rows = { { id = TANK, total = 1000, last = 0 } } }));
    t.eq(unlisted.rows, { { TANK, 1000 } });
    t.eq(avatar.margin(unlisted, 'none'), 0 - 1500);
    t.eq(avatar.margin(unlisted, 'both all 100%'), 1500 - 1500);
    t.truthy(research.qualifies(avatar, unlisted), 'qualifies');
    -- Two summoners: each is handed their own avatar's share.
    local two = avatar.event(avatarObs({
        rows = { { id = TANK, total = 1000, last = 0 }, { id = SMN, total = 300, last = 0 }, { id = NIN, total = 200, last = 0 } },
        avatars = {
            { pet = AVATAR, master = SMN, pactCe = 400, pactVe = 800, otherCe = 100, otherVe = 200 },
            { pet = AVATAR + 1, master = NIN, pactCe = 0, pactVe = 0, otherCe = 3000, otherVe = 0 },
        },
    }));
    t.eq(avatar.margin(two, 'ce all 100%'), 800 - 3200);
    t.eq(avatar.margin(two, 'ce pact 100%'), 700 - 3000, 'the other avatar is the best rival');
end);

t.test('fitting favours the hypothesis the attacks agree with, and the prior alone without any', function ()
    local empty = research.fit(shadow, {});
    t.eq(empty.n, 0);
    t.eq(empty.posterior, { lsb = 0.5, era = 0.5 });
    -- The ninja with two last shadows lost keeps hate at a 10 margin under LSB, 60 under era: era fits better.
    local events = {};
    for i = 1, 40 do
        events[i] = shadow.event(obs({ switch = i % 10 == 0 }));
    end
    local fit = research.fit(shadow, events);
    t.eq(fit.n, 40);
    t.eq(fit.switches, 4);
    t.truthy(fit.posterior.era > fit.posterior.lsb, ('era %.3f lsb %.3f'):format(fit.posterior.era, fit.posterior.lsb));
    t.truthy(math.abs(fit.posterior.era + fit.posterior.lsb - 1) < 1e-9, 'sums to one');
    t.eq(fit.best, 'era');
    t.eq(research.ranked(shadow, fit), { 'era', 'lsb' });
    -- Steady swings count for a fifth of a switch each: their log-likelihood ratio is a fifth.
    local one = research.fit(shadow, { shadow.event(obs({ switch = true })) });
    local steady = research.fit(shadow, { shadow.event(obs({ switch = false })) });
    local ratio = function (f) return f.loglik.era - f.loglik.lsb; end;
    t.truthy(math.abs(ratio(steady) - ratio(one) * filter.STEADY) < 1e-9, 'steady is a fraction of a switch');
end);

t.test('the avatar fit picks out the share the attacks were made under', function ()
    -- The mob stays on the summoner while their own total trails the tank by 200: only a share explains it.
    local events = {};
    for i = 1, 30 do
        events[i] = avatar.event(avatarObs({
            switch = i == 1,
            rows = { { id = TANK, total = 1000, last = 0 }, { id = SMN, total = 800, last = 0 } },
            avatars = { { pet = AVATAR, master = SMN, pactCe = 600, pactVe = 0, otherCe = 0, otherVe = 0 } },
        }));
    end
    local fit = research.fit(avatar, events);
    t.truthy(fit.posterior['none'] < 0.01, ('none %.3f'):format(fit.posterior['none']));
    t.truthy(fit.posterior[fit.best] > fit.posterior['none'], 'a share leads');
    t.truthy(fit.best:find('100%%$'), fit.best);
end);

t.test('the posterior serializes to plaintext Lua that store.read loads back', function ()
    local fits = {
        shadowAbsorb = research.fit(shadow, { shadow.event(obs({ switch = true })) }),
        avatarShare = research.fit(avatar, {}),
    };
    local text = research.serialize(fits, 1000000000);
    t.truthy(text:find('^return {'), text);
    t.truthy(text:find('shadowAbsorb = {', 1, true), 'entry');
    t.truthy(text:find('observations = 1,', 1, true), 'count');
    local path = (os.getenv('TEMP') or '.') .. '/enmetry_research_posterior.lua';
    local fh = assert(io.open(path, 'wb'));
    fh:write(text);
    fh:close();
    local loaded = store.read(path);
    os.remove(path);
    t.eq(loaded.version, research.VERSION);
    t.eq(loaded.scored, 1000000000);
    t.eq(loaded.entries.shadowAbsorb.observations, 1);
    t.eq(loaded.entries.shadowAbsorb.switches, 1);
    t.truthy(math.abs(loaded.entries.shadowAbsorb.posterior.era + loaded.entries.shadowAbsorb.posterior.lsb - 1) < 1e-6, 'posterior');
    t.eq(loaded.entries.avatarShare.observations, 0);
    t.eq(loaded.entries.avatarShare.posterior['none'], 0.25);
end);

t.test('the live registry writes a session line, then one line per qualifying entry with its key and the wall clock', function ()
    local out = {};
    local r = research.new({
        sink = function (text) out[#out + 1] = text; end, clock = function () return 5; end, wall = function () return 1700000000; end,
    });
    r:session({ server = 'horizon', character = 'Hanayaka', rule = 'lsb' });
    t.eq(#out, 1);
    local session = json.decode(out[1]);
    t.eq(session, {
        t = 5, k = 'session', logVersion = research.VERSION, server = 'horizon', character = 'Hanayaka', rule = 'lsb',
        live = { shadowAbsorb = 'lsb', avatarShare = 'none' },
    });

    t.eq(r:observe(obs()), 1, 'the shadow entry alone');
    t.eq(r:observe(avatarObs({ rows = { { id = TANK, total = 1000, last = 0 }, { id = SMN, total = 300, last = 1 } } })), 2, 'both');
    t.eq(r:observe(obs({ clean = false })), 0);
    r:flush();
    t.eq(#out, 2);
    local lines = {};
    for line in out[2]:gmatch('[^\n]+') do
        lines[#lines + 1] = json.decode(line);
    end
    t.eq(#lines, 3);
    t.eq(lines[1].k, 'observation');
    t.eq(lines[1].entry, 'shadowAbsorb');
    t.eq(lines[1].wall, 1700000000);
    t.eq(lines[1].rows, { { TANK, 1000, 0 }, { NIN, 1010, 2 } });
    t.eq(lines[2].entry, 'shadowAbsorb');
    t.eq(lines[3].entry, 'avatarShare');
    t.eq(lines[3].avatars, { { AVATAR, SMN, 400, 800, 100, 200 } });
    t.eq(r.counts, { shadowAbsorb = 2, avatarShare = 1 });

    -- Lines read back score as they were written.
    t.eq(shadow.margin(lines[1], 'era'), 60);
    t.eq(avatar.margin(lines[3], 'both all 100%'), 300 + 1500 - 1500);
end);

t.test('the registry is told which hypothesis a setting picked, and says so; an unknown one is ignored', function ()
    local out = {};
    local r = research.new({
        sink = function (text) out[#out + 1] = text; end, clock = function () return 0; end,
        live = { shadowAbsorb = 'era', avatarShare = 'nonsense', bogus = 'x' },
    });
    t.eq(r.live, { shadowAbsorb = 'era', avatarShare = 'none' });
    r:session({});
    t.eq(json.decode(out[1]).live, { shadowAbsorb = 'era', avatarShare = 'none' });
    local lines = r:readout(nil, 'x');
    t.truthy(lines[3]:find('running era (only an absorb that leaves shadows: the last is free)', 1, true), lines[3]);
end);

t.test('the readout names each question, what runs, what was logged, and the last posterior', function ()
    local r = research.new({ sink = function () end, clock = function () return 0; end });
    r:observe(obs());
    local lines = r:readout(nil, 'C:/research.jsonl');
    t.eq(lines[1], 'research: 2 open questions, logged to C:/research.jsonl');
    t.eq(lines[2], 'shadowAbsorb -- which Utsusemi absorbs cost CE?');
    t.eq(lines[3], '  running lsb (every absorb, the last shadow included) | 1 logged this session | not yet scored: luajit tools/research.lua');
    t.eq(lines[4], 'avatarShare -- does a summoner share the enmity their avatar generates?');
    t.eq(lines[5], '  running none (no share: the summoner gets only a 0/0 entry, as LandSandBoat) | 0 logged this session | not yet scored: luajit tools/research.lua');

    local persisted = {
        version = 1, date = '2026-09-01 20:00:00',
        entries = { shadowAbsorb = { observations = 412, posterior = { era = 0.61, lsb = 0.39 } } },
    };
    lines = r:readout(persisted, 'C:/research.jsonl');
    t.eq(lines[3], '  running lsb (every absorb, the last shadow included) | 1 logged this session | scored 2026-09-01 20:00:00 over 412: era 61%, lsb 39%');
    t.truthy(lines[5]:find('not yet scored', 1, true), lines[5]);
    -- A hand-edited file missing pieces is shown as unscored rather than raising.
    lines = r:readout({ entries = { shadowAbsorb = { posterior = 'gone' } } }, 'x');
    t.truthy(lines[3]:find('not yet scored', 1, true), lines[3]);
end);

t.test('JSON written by the log reads back: numbers, strings with escapes, nested arrays and objects, null', function ()
    local value = { a = 1, b = -2.5, c = 'q"\\\n\t', d = { 1, 2, { e = true, f = false } }, g = {}, h = 'caf\233' };
    local back = json.decode(log.encode(value));
    t.eq(back.a, 1);
    t.eq(back.b, -2.5);
    t.eq(back.c, 'q"\\\n\t');
    t.eq(back.d, { 1, 2, { e = true, f = false } });
    t.eq(back.g, {});
    t.eq(back.h, 'caf\195\169', 'the byte the log wrote as a code point comes back as UTF-8');
    t.eq(json.decode(' {"x": null, "y": [ ], "z": 1e3, "w": "\\ud83d\\ude00"} '), { y = {}, z = 1000, w = '\240\159\152\128' });
    t.eq(json.decode('[1,[2,[3]]]'), { 1, { 2, { 3 } } });
    for _, bad in ipairs({ '', '{', '[1,]', '{"a" 1}', '"open', 'nul', '1 2', '{"a":1,}' }) do
        t.eq(pcall(json.decode, bad), false, 'rejects ' .. bad);
    end
end);

t.test('the offline tool reads a log, reports each entry\'s fit, and writes the posterior beside it', function ()
    local dir = (os.getenv('TEMP') or '.') .. '/';
    local path = dir .. 'enmetry_research_test.jsonl';
    local out = {};
    local r = research.new({ sink = function (text) out[#out + 1] = text; end, clock = function () return 0; end, wall = function () return 1; end });
    r:session({ server = 'horizon', character = 'Hanayaka', rule = 'lsb', version = '0.1.0' });
    for i = 1, 20 do
        r:observe(obs({ switch = i == 1 }));
    end
    r:flush();
    local fh = assert(io.open(path, 'wb'));
    fh:write(table.concat(out));
    fh:write('not json\n');
    fh:close();

    local read = assert(offline.read(path));
    t.eq({ read.lines, read.sessions, read.bad, #read.events.shadowAbsorb, #read.events.avatarShare }, { 22, 1, 1, 20, 0 });
    local lines, fits = offline.report(path, read);
    t.eq(lines[1], path .. ': 22 lines, 1 sessions, 1 unreadable');
    t.eq(lines[2], '  addon versions seen: 0.1.0 x1');
    t.eq(lines[4], 'shadowAbsorb -- which Utsusemi absorbs cost CE?');
    t.eq(lines[5], '  20 observations, 1 of them switches; the addon runs lsb by default');
    t.truthy(lines[7]:find('era: only an absorb that leaves shadows', 1, true), lines[7]);
    t.truthy(lines[8]:find('lsb: every absorb, the last shadow included (default)', 1, true), lines[8]);
    t.truthy(lines[8]:find('+0.00', 1, true), 'the default hypothesis is the reference');
    t.eq(lines[10], 'avatarShare -- does a summoner share the enmity their avatar generates?');
    t.eq(lines[12], '  nothing to score yet');
    t.eq(fits.shadowAbsorb.best, 'era');

    t.eq(offline.posteriorPath(path), dir .. 'research.lua');
    t.eq(offline.posteriorPath('research.jsonl'), 'research.lua');
    local posterior = dir .. 'research.lua';
    os.remove(posterior);
    local realPrint = print;
    local printed = {};
    print = function (s) printed[#printed + 1] = s; end;
    local code = offline.main({ path });
    print = realPrint;
    t.eq(code, 0);
    t.truthy(printed[#printed]:find('posterior written to ', 1, true), printed[#printed]);
    local loaded = store.read(posterior);
    t.eq(loaded.entries.shadowAbsorb.observations, 20);
    t.truthy(loaded.entries.shadowAbsorb.posterior.era > 0.5, 'era leads');
    os.remove(posterior);

    -- Sessions on another server can be left out.
    local fh2 = assert(io.open(path, 'ab'));
    fh2:write('{"t":0,"k":"session","server":"elsewhere"}\n');
    fh2:write(out[2]:match('^[^\n]+') .. '\n');
    fh2:close();
    read = assert(offline.read(path));
    t.eq({ read.sessions, #read.events.shadowAbsorb }, { 2, 21 });
    read = assert(offline.read(path, 'horizon'));
    t.eq({ read.sessions, #read.events.shadowAbsorb }, { 1, 20 });
    read = assert(offline.read(path, 'elsewhere'));
    t.eq({ read.sessions, #read.events.shadowAbsorb }, { 1, 1 });
    -- Sessions from older addon versions can be left out; versions are counted before the filter.
    t.eq(read.versions, { ['nil'] = 1, ['0.1.0'] = 1 });
    read = assert(offline.read(path, nil, '0.1.0'));
    t.eq({ read.sessions, read.skipped, #read.events.shadowAbsorb }, { 1, 1, 20 }, 'the session with no version is out');
    read = assert(offline.read(path, nil, '0.2'));
    t.eq({ read.sessions, read.skipped }, { 0, 2 });
    t.eq(offline.compareVersions('0.10.0', '0.2.0') > 0, true);
    t.eq(offline.compareVersions('1.0', '1.0.0'), 0);
    t.eq(offline.compareVersions('x', '0.0.1') < 0, true);
    local shown = offline.report(path, assert(offline.read(path)));
    t.truthy(shown[2]:find('addon versions seen: nil x1, 0.1.0 x1', 1, true), shown[2]);
    shown = offline.report(path, read);
    t.truthy(shown[1]:find(': 24 lines, 0 sessions, 2 left out', 1, true), shown[1]);

    printed = {};
    print = function (s) printed[#printed + 1] = s; end;
    code = offline.main({ path, '--server', 'horizon', '--no-write' });
    print = realPrint;
    t.truthy(printed[1]:find(': 24 lines, 1 sessions', 1, true), printed[1]);
    printed = {};
    print = function (s) printed[#printed + 1] = s; end;
    code = offline.main({ path, '--no-write' });
    print = realPrint;
    t.eq(code, 0);
    t.eq(io.open(posterior, 'rb'), nil, 'not written');
    local stderr = io.stderr;
    io.stderr = { write = function () end };
    t.eq(offline.main({ dir .. 'enmetry_research_missing.jsonl', '--no-write' }), 1);
    t.eq(offline.main({ '--help' }), 2);
    io.stderr = stderr;
    os.remove(path);
end);

return t.done();

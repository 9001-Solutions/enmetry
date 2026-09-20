--[[
* The /enmetry command.
*
* Run: luajit tests/test_commands.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local commands = require('commands');
local feed = require('feed');
local focus = require('focus');

local function context(members)
    local saves = 0;
    local f = feed.new(5);
    local ctx = {
        version = '0.1.0',
        settings = { debug = true, rows = 8 },
        feed = f,
        focus = focus.new(),
        nameOf = function (id) return ({ [0x0100A012] = 'Goblin Thug' })[id]; end,
        world = {
            memberCount = function () return #members; end,
            member = function (_, slot) return members[slot + 1]; end,
        },
        save = function () saves = saves + 1; end,
    };
    return ctx, function () return saves; end;
end

t.test('commands for other addons are left alone', function ()
    local ctx = context({});
    t.eq(commands.handle('/echo hi', ctx), nil);
    t.eq(commands.handle('/enmetryx', ctx), nil);
end);

t.test('the bare command answers with a status line', function ()
    local ctx = context({ {}, {}, {} });
    ctx.feed:push('a', 1);
    ctx.feed:push('b', 2);
    t.eq(commands.handle('/enmetry', ctx), { 'v0.1.0 | debug feed on | 2 events seen | alliance 3/18 | particles off' });
    ctx.filter = { count = 512 };
    t.eq(commands.handle('/ENMETRY status', ctx), { 'v0.1.0 | debug feed on | 2 events seen | alliance 3/18 | 512 particles' });
end);

t.test('debug toggles the feed view and persists the choice', function ()
    local ctx, saves = context({});
    t.eq(commands.handle('/enmetry debug', ctx), { 'debug feed off' });
    t.eq(ctx.settings.debug, false);
    t.eq(commands.handle('/enmetry debug', ctx), { 'debug feed on' });
    t.eq(ctx.settings.debug, true);
    t.eq(saves(), 2);
end);

t.test('compact toggles the compact panel, takes an explicit on or off, and persists it', function ()
    local ctx, saves = context({});
    t.eq(commands.handle('/enmetry compact', ctx), { 'compact panel on' });
    t.eq(ctx.settings.compact, true);
    t.eq(commands.handle('/enmetry compact on', ctx), { 'compact panel on' });
    t.eq(commands.handle('/enmetry compact', ctx), { 'compact panel off' });
    t.eq(commands.handle('/enmetry compact off', ctx), { 'compact panel off' });
    t.eq(ctx.settings.compact, false);
    t.eq(saves(), 4);
end);

t.test('debug accepts an explicit on or off', function ()
    local ctx = context({});
    commands.handle('/enmetry debug off', ctx);
    t.eq(ctx.settings.debug, false);
    commands.handle('/enmetry debug off', ctx);
    t.eq(ctx.settings.debug, false);
    commands.handle('/enmetry debug on', ctx);
    t.eq(ctx.settings.debug, true);
end);

t.test('clear empties the feed', function ()
    local ctx = context({});
    ctx.feed:push('a', 1);
    t.eq(commands.handle('/enmetry clear', ctx), { 'feed cleared' });
    t.eq(ctx.feed:size(), 0);
end);

t.test('alliance lists every occupied slot with jobs and levels', function ()
    local ctx = context({});
    ctx.world = {
        memberCount = function () return 2; end,
        member = function (_, slot)
            if slot == 0 then
                return { slot = 0, name = 'Hanayaka', mainJob = 'WAR', subJob = 'NIN', mainLevel = 75, subLevel = 37 };
            elseif slot == 17 then
                return { slot = 17, name = 'Tail', mainJob = 'WHM', mainLevel = 75, subLevel = 0 };
            end
        end,
    };
    t.eq(commands.handle('/enmetry alliance', ctx), {
        'alliance 2/18',
        '  0  Hanayaka  WAR75/NIN37',
        ' 17  Tail  WHM75',
    });
end);

t.test('help lists the commands, and an unknown one points at help', function ()
    local ctx = context({});
    local help = commands.handle('/enmetry help', ctx);
    t.truthy(#help >= 4, 'help lines');
    t.eq(commands.handle('/enmetry frobnicate', ctx), { "unknown command 'frobnicate' -- try /enmetry help" });
end);

t.test('pin locks focus on the mob shown, and unpin releases it', function ()
    local ctx = context({});
    t.eq(commands.handle('/enmetry pin', ctx), { 'nothing to pin' });

    ctx.focus.mob = 0x0100A012;
    t.eq(commands.handle('/enmetry pin', ctx), { 'focus pinned to Goblin Thug' });
    t.eq(ctx.focus.pinned, 0x0100A012);
    t.eq(commands.handle('/enmetry unpin', ctx), { 'focus follows your target' });
    t.eq(ctx.focus.pinned, nil);
    t.eq(commands.handle('/enmetry unpin', ctx), { 'focus was not pinned' });

    -- A mob never named is shown by id.
    ctx.focus.mob = 0x0100A0FF;
    t.eq(commands.handle('/enmetry pin', ctx), { 'focus pinned to 0x0100A0FF' });
end);

t.test('rows sets how many bars are shown, within an alliance, and persists it', function ()
    local ctx, saves = context({});
    t.eq(commands.handle('/enmetry rows', ctx), { 'showing up to 8 bars' });
    t.eq(commands.handle('/enmetry rows 3', ctx), { 'showing up to 3 bars' });
    t.eq(ctx.settings.rows, 3);
    t.eq(saves(), 1);
    t.eq(commands.handle('/enmetry rows 0', ctx), { 'rows must be a whole number from 1 to 18' });
    t.eq(commands.handle('/enmetry rows 19', ctx), { 'rows must be a whole number from 1 to 18' });
    t.eq(commands.handle('/enmetry rows 2.5', ctx), { 'rows must be a whole number from 1 to 18' });
    t.eq(commands.handle('/enmetry rows many', ctx), { 'rows must be a whole number from 1 to 18' });
    t.eq(ctx.settings.rows, 3);
    t.eq(saves(), 1);
end);

t.test('reset forgets every hate list and releases a pin', function ()
    local ctx = context({});
    local resets = 0;
    ctx.sim = { reset = function () resets = resets + 1; end };
    ctx.focus.mob = 0x0100A012;
    ctx.focus:pin();
    t.eq(commands.handle('/enmetry reset', ctx), { 'every hate list reset' });
    t.eq({ resets, ctx.focus.pinned }, { 1, nil });
end);

-- A store that records what it was asked, knowing only Hanayaka.
local function fakeProfiles(ctx)
    local calls = {};
    ctx.filter = { count = 64 };
    ctx.profiles = {
        forget = function (_, name, f)
            calls[#calls + 1] = { 'forget', name, f == ctx.filter };
            return name:lower() == 'hanayaka' and 'Hanayaka' or nil;
        end,
        purge = function (_, f)
            calls[#calls + 1] = { 'purge', f == ctx.filter };
            return 12;
        end,
    };
    local saved = 0;
    ctx.saveProfiles = function () saved = saved + 1; end;
    return calls, function () return saved; end;
end

t.test('forget drops what is kept on a character by name, and writes the file', function ()
    local ctx = context({});
    local calls, saved = fakeProfiles(ctx);
    t.eq(commands.handle('/enmetry forget HANAYAKA', ctx), { 'forgot Hanayaka' });
    t.eq(calls, { { 'forget', 'HANAYAKA', true } }, 'the name as typed, with the filter');
    t.eq(saved(), 1);
    t.eq(commands.handle('/enmetry forget Nobody', ctx), { 'nothing kept on Nobody' });
    t.eq(saved(), 1);
    t.eq(commands.handle('/enmetry forget', ctx), { 'forget whom? /enmetry forget <name>' });
    t.eq(#calls, 2);
end);

t.test('purge asks to be confirmed, then forgets everyone', function ()
    local ctx = context({});
    local calls, saved = fakeProfiles(ctx);
    t.eq(commands.handle('/enmetry purge', ctx),
        { 'this forgets every character on every server -- /enmetry purge confirm' });
    t.eq({ #calls, saved() }, { 0, 0 });
    t.eq(commands.handle('/enmetry purge CONFIRM', ctx), { 'forgot 12 characters' });
    t.eq(calls, { { 'purge', true } });
    t.eq(saved(), 1);
end);

-- A log that keeps what is written, and when it was flushed.
local function fakeLog(ctx)
    local written, flushes = {}, 0;
    ctx.log = {
        lines = 42,
        write = function (_, kind, fields) written[#written + 1] = { kind, fields }; end,
        flush = function () flushes = flushes + 1; end,
    };
    ctx.logFile = 'C:/Ashita/config/addons/enmetry/logs/enmetry-20260912-201500.jsonl';
    return written, function () return flushes; end;
end

t.test('log says where the session log is going', function ()
    local ctx = context({});
    t.eq(commands.handle('/enmetry log', ctx), { 'session log off -- turn it on in /enmetry settings' });
    fakeLog(ctx);
    t.eq(commands.handle('/enmetry log', ctx), {
        'session log: 42 lines to C:/Ashita/config/addons/enmetry/logs/enmetry-20260912-201500.jsonl',
    });
end);

t.test('mark writes a note into the log as typed, and flushes it', function ()
    local ctx = context({});
    t.eq(commands.handle('/enmetry mark tank lost hate', ctx), { 'session log off -- nothing to mark' });
    local written, flushes = fakeLog(ctx);
    t.eq(commands.handle('/enmetry mark  Tank lost hate HERE ', ctx), { 'marked: Tank lost hate HERE' });
    t.eq(written, { { 'mark', { text = 'Tank lost hate HERE' } } });
    t.eq(flushes(), 1);
    t.eq(commands.handle('/enmetry mark', ctx), { 'mark what? /enmetry mark <note>' });
    t.eq(#written, 1);
end);

t.test('research shows the open questions, what was logged and the last posterior on demand', function ()
    local ctx = context({});
    t.eq(commands.handle('/enmetry research', ctx), { 'research log off -- turn it on in /enmetry settings' });
    ctx.research = require('research').new({ sink = function () end, clock = function () return 0; end });
    ctx.researchFile = 'C:/research.jsonl';
    ctx.researchPosterior = function () return nil; end;
    local out = commands.handle('/enmetry RESEARCH', ctx);
    t.eq(out[1], 'research: 2 open questions, logged to C:/research.jsonl');
    t.eq(#out, 5);
    ctx.researchPosterior = function ()
        return { date = '2026-09-01 20:00:00', entries = { avatarShare = { observations = 9, posterior = { none = 0.9, ['ce all 25%'] = 0.1 } } } };
    end;
    out = commands.handle('/enmetry research', ctx);
    t.truthy(out[5]:find('scored 2026-09-01 20:00:00 over 9: none 90%, ce all 25% 10%', 1, true), out[5]);
end);

t.test('calibration shows the session\'s readout on demand', function ()
    local ctx = context({});
    ctx.sim = {};
    t.eq(commands.handle('/enmetry calibration', ctx), {
        'calibration off -- the particle filter is off, set particles above 0 in settings.lua and reload',
    });
    ctx.sim.calibration = require('calibration').new(0.8);
    t.eq(commands.handle('/enmetry CALIBRATION', ctx), { 'calibration: nothing scored yet this session' });
    local chances = require('ffi').new('double[2]', 1, 0);
    ctx.sim.calibration:score(chances, 2, 0);
    t.eq(commands.handle('/enmetry calibration', ctx), {
        'calibration: 80% of attacks inside the 80% credible set of who holds hate, over 1',
        'contested: none yet',
    });
end);

t.test('settings opens the panel and closes it again', function ()
    local ctx = context({});
    ctx.panel = { open = { false } };
    t.eq(commands.handle('/enmetry settings', ctx), { 'settings panel open' });
    t.eq(ctx.panel.open[1], true);
    t.eq(commands.handle('/enmetry settings', ctx), { 'settings panel closed' });
    t.eq(ctx.panel.open[1], false);
    t.eq(commands.handle('/enmetry settings on', ctx), { 'settings panel open' });
    t.eq(commands.handle('/enmetry settings on', ctx), { 'settings panel open' });
    t.eq(commands.handle('/enmetry settings off', ctx), { 'settings panel closed' });
end);

return t.done();

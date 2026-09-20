--[[
* Per-character memory: posteriors kept between sessions per server, character
* and job, in a plaintext file, and the commands' forget and purge.
*
* Run: luajit tests/test_profiles.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local filter = require('filter');
local priors = require('priors');
local profiles = require('profiles');

local SCRATCH = os.getenv('TEMP') or os.getenv('TMPDIR') or '.';
local path = SCRATCH .. '/enmetry_profiles_test.lua';

local HORIZON, OTHER = 'play.horizonxi.com', 'homepointxi.com';
local HANAYAKA, TAIL, BAT = 0x0001E240, 0x0001E241, 0x0001E242;
local MEMBERS = {
    [HANAYAKA] = { name = 'Hanayaka', mainJob = 'PLD' },
    [TAIL] = { name = 'Tail', mainJob = 'WHM' },
    [BAT] = { name = 'Bat', mainJob = 'DRK' },
};
local DAY = 86400;

local function read()
    local fh = io.open(path, 'rb');
    if fh == nil then
        return nil;
    end
    local text = fh:read('*a');
    fh:close();
    return text;
end

local function write(text)
    local fh = assert(io.open(path, 'wb'));
    fh:write(text);
    fh:close();
end

--[[
* A session: a store on `server` at `now`, loaded from the file, and a filter
* drawing from it.  Returns the store, the filter and a clock setter.
--]]
local function session(server, now, opts)
    local clock = { now = now };
    local store = profiles.new(path, server, function () return clock.now; end);
    store:load();
    math.randomseed(11);
    local f;
    f = filter.new({
        max = (opts and opts.max) or 512,
        prior = function (id) return store:prior(id, MEMBERS[id]); end,
        retire = function (id) store:retire(id, f); end,
    });
    return store, f, clock;
end

local function see(f, id)
    f:fill(f:row(), id, filter.CLASS.melee, 0);
end

-- Puts all the weight on the particles where `id`'s melee bonus is above `above`.
local function convince(f, id, above)
    local row = f:row();
    f:fill(row, id, filter.CLASS.melee, 0);
    local sum = 0;
    for lane = 1, f.count do
        f.weights[lane] = row[lane] > above and 1 or 1e-12;
        sum = sum + f.weights[lane];
    end
    for lane = 1, f.count do
        f.weights[lane] = f.weights[lane] / sum;
    end
end

t.test('a character never seen before starts from their main job\'s prior', function ()
    os.remove(path);
    local store = session(HORIZON, 1000);
    t.eq(store:prior(HANAYAKA, MEMBERS[HANAYAKA]), priors.forJob('PLD'));
    t.eq(store:prior(TAIL, MEMBERS[TAIL]), priors.forJob('WHM'));
    t.eq(store:prior(0x999, nil), priors.NEUTRAL, 'nobody known');
end);

t.test('a posterior saved in one session is where the next begins, faded by the time between', function ()
    os.remove(path);
    local store, f = session(HORIZON, 1000);
    see(f, HANAYAKA);
    convince(f, HANAYAKA, 40);
    local learned = f:posterior(HANAYAKA);
    t.truthy(learned.mean > 40, ('learned %g'):format(learned.mean));
    t.truthy(store:save(f), 'saved');

    local later = session(HORIZON, 1000);
    local p = later:prior(HANAYAKA, MEMBERS[HANAYAKA]);
    t.truthy(math.abs(p.mean - learned.mean) < 0.01, ('remembered %g of %g'):format(p.mean, learned.mean));
    t.truthy(math.abs(p.classes[3].sd - learned.classes[3].sd) < 0.01, 'class spreads too');

    local month = session(HORIZON, 1000 + priors.HALF_LIFE);
    local faded = month:prior(HANAYAKA, MEMBERS[HANAYAKA]);
    t.truthy(math.abs(faded.mean - (learned.mean + priors.forJob('PLD').mean) / 2) < 0.01,
        ('a half-life later %g'):format(faded.mean));
end);

t.test('memory is kept per server, and per job', function ()
    os.remove(path);
    local store, f = session(HORIZON, 1000);
    see(f, HANAYAKA);
    convince(f, HANAYAKA, 40);
    store:save(f);

    local elsewhere = session(OTHER, 1000);
    t.eq(elsewhere:prior(HANAYAKA, MEMBERS[HANAYAKA]), priors.forJob('PLD'), 'another server\'s Hanayaka is someone else');
    local home = session(HORIZON, 1000);
    t.eq(home:prior(HANAYAKA, { name = 'Hanayaka', mainJob = 'WAR' }), priors.forJob('WAR'), 'another job, other gear');
    t.truthy(home:prior(HANAYAKA, MEMBERS[HANAYAKA]).mean > 40);
end);

t.test('the file is plaintext a person can read and correct by hand', function ()
    os.remove(path);
    local store, f = session(HORIZON, 1789264000);
    see(f, HANAYAKA);
    see(f, TAIL);
    store:save(f);
    local text = read();
    for _, needle in ipairs({ '["play.horizonxi.com"]', '["Hanayaka"]', '["PLD"]', '["Tail"]', '["WHM"]',
        'seen = 1789264000', 'melee = { mean = ', 'cure = { mean = ' }) do
        t.truthy(text:find(needle, 1, true), needle .. ' in\n' .. text);
    end

    -- Somebody decides Hanayaka's centre is really 60.
    write((text:gsub('(%["Hanayaka"%] = {%s*%["PLD"%] = {%s*seen = %d+, mean = )[%-%d%.]+', '%160.00')));
    local edited = session(HORIZON, 1789264000);
    t.eq(edited:prior(HANAYAKA, MEMBERS[HANAYAKA]).mean, 60);
end);

t.test('a corrupt, hostile or malformed file remembers nothing it cannot trust', function ()
    write('return { ["x"] = ');
    t.eq(session(HORIZON, 0):prior(HANAYAKA, MEMBERS[HANAYAKA]), priors.forJob('PLD'), 'corrupt');
    write('os.exit(3) return {}');
    t.eq(session(HORIZON, 0):prior(HANAYAKA, MEMBERS[HANAYAKA]), priors.forJob('PLD'), 'reaching for globals');

    local classes = 'melee = { mean = 1, sd = 1 }, weaponskill = { mean = 1, sd = 1 }, ability = { mean = 1, sd = 1 },'
        .. ' magic = { mean = 1, sd = 1 }, cure = { mean = 1, sd = 1 }, other = { mean = 1, sd = 1 }';
    write(('return { [%q] = {\n'):format(HORIZON)
        .. ('  Hanayaka = { PLD = { seen = 0, mean = 50, sd = "wide", %s } },\n'):format(classes)
        .. '  Tail = { WHM = { seen = 0, mean = -30, sd = 4, melee = { mean = 1, sd = 1 } } },\n'
        .. ('  Bat = { DRK = { seen = 0, mean = 7, sd = 4, %s } },\n'):format(classes)
        .. '} }');
    local store = session(HORIZON, 0);
    t.eq(store:prior(HANAYAKA, MEMBERS[HANAYAKA]), priors.forJob('PLD'), 'a spread that is no number');
    t.eq(store:prior(TAIL, MEMBERS[TAIL]), priors.forJob('WHM'), 'classes missing');
    t.eq(store:prior(BAT, MEMBERS[BAT]).mean, 7, 'a good entry beside bad ones is kept');
end);

t.test('a character long enough gone to be only their job\'s prior again is dropped from the file', function ()
    os.remove(path);
    local store, f = session(HORIZON, 1000);
    see(f, HANAYAKA);
    store:save(f);
    local later, f2 = session(HORIZON, 1000 + 10 * priors.HALF_LIFE);
    see(f2, TAIL);
    later:save(f2);
    local text = read();
    t.truthy(text:find('Tail', 1, true), text);
    t.eq(text:find('Hanayaka', 1, true), nil, text);
end);

-- Two servers' worth of memory: Hanayaka and Tail here, Hanayaka elsewhere.
local function remember()
    os.remove(path);
    local away, fa = session(OTHER, 1000);
    see(fa, HANAYAKA);
    convince(fa, HANAYAKA, 40);
    away:save(fa);
    local store, f = session(HORIZON, 1000);
    see(f, HANAYAKA);
    see(f, TAIL);
    convince(f, HANAYAKA, 40);
    store:save(f);
end

t.test('forgetting a character by name drops everything kept on them here, and what the filter holds', function ()
    remember();
    local store, f = session(HORIZON, 2000);
    see(f, HANAYAKA);
    t.truthy(f:posterior(HANAYAKA).mean > 40, 'drawn from memory');

    t.eq(store:forget('hanayaka', f), 'Hanayaka', 'names are matched ignoring case');
    t.eq(f:posterior(HANAYAKA), nil, 'the filter lets go too');
    t.truthy(math.abs(store:prior(HANAYAKA, MEMBERS[HANAYAKA]).mean - priors.forJob('PLD').mean) < 1e-9, 'back to the job');
    see(f, HANAYAKA);
    store:save(f);

    local next = session(HORIZON, 2000);
    t.truthy(next:prior(HANAYAKA, MEMBERS[HANAYAKA]).mean < 35, 'the save did not bring the old belief back');
    t.truthy(next:prior(TAIL, MEMBERS[TAIL]) ~= priors.forJob('WHM'), 'Tail is still remembered');
    t.truthy(session(OTHER, 2000):prior(HANAYAKA, MEMBERS[HANAYAKA]).mean > 40, 'another server\'s Hanayaka is kept');
    t.eq(next:forget('Nobody', nil), nil, 'nothing kept on a stranger');
end);

t.test('a purge forgets every character on every server', function ()
    remember();
    local store, f = session(HORIZON, 2000);
    see(f, TAIL);
    t.eq(store:purge(f), 3, 'Hanayaka and Tail here, Hanayaka elsewhere');
    t.eq(f:posterior(TAIL), nil);
    store:save(f);
    t.eq(session(OTHER, 2000):prior(HANAYAKA, MEMBERS[HANAYAKA]), priors.forJob('PLD'));
    t.eq(session(HORIZON, 2000):prior(TAIL, MEMBERS[TAIL]), priors.forJob('WHM'));
    t.eq(store:purge(f), 0);
end);

t.test('a player pushed out of the filter by a newcomer is still remembered', function ()
    os.remove(path);
    local store, f = session(HORIZON, 1000, { max = 64 });
    see(f, HANAYAKA);
    convince(f, HANAYAKA, 40);
    for id = 1, filter.PLAYERS do
        see(f, 0x100 + id);
    end
    t.eq(f:posterior(HANAYAKA), nil, 'pushed out');
    store:save(f);
    -- Well above the paladin prior's 20, if short of 40 on 64 particles.
    t.truthy(session(HORIZON, 1000):prior(HANAYAKA, MEMBERS[HANAYAKA]).mean > 30);
end);

t.test('a player who changes job is kept as the job they were, and drawn afresh as the new one', function ()
    os.remove(path);
    local store, f = session(HORIZON, 1000);
    see(f, HANAYAKA);
    see(f, TAIL);
    convince(f, HANAYAKA, 40);
    local roster = { [HANAYAKA] = { name = 'Hanayaka', mainJob = 'PLD' }, [TAIL] = MEMBERS[TAIL] };
    local world = { allianceMember = function (_, id) return roster[id]; end };

    store:reconcile(world, f);
    t.truthy(f:posterior(HANAYAKA) ~= nil, 'no change, nothing let go');

    roster[HANAYAKA] = { name = 'Hanayaka', mainJob = 'WHM' };
    roster[TAIL] = nil;     -- left the alliance: still held
    store:reconcile(world, f);
    t.eq(f:posterior(HANAYAKA), nil, 'let go');
    t.truthy(f:posterior(TAIL) ~= nil, 'someone who left is kept');
    MEMBERS[HANAYAKA] = roster[HANAYAKA];
    see(f, HANAYAKA);
    store:save(f);
    MEMBERS[HANAYAKA] = { name = 'Hanayaka', mainJob = 'PLD' };

    local text = read();
    t.truthy(text:find('["PLD"]', 1, true) and text:find('["WHM"]', 1, true), text);
    t.truthy(session(HORIZON, 1000):prior(HANAYAKA, MEMBERS[HANAYAKA]).mean > 40, 'the paladin is remembered');
end);

t.test('a trust starts at a tight 1.0x and nothing is kept on it', function ()
    os.remove(path);
    local store = profiles.new(path, HORIZON, function () return 1000; end);
    local kupipi = { name = 'Kupipi', mainJob = 'WHM', trust = true };
    local p = store:prior(0x01002701, kupipi);
    t.eq(p, priors.TRUST);
    t.eq({ p.mean, p.sd, p.classes[0].mean, p.classes[5].sd }, { 0, 0, 0, 0 });
    local f = filter.new({ max = 64, prior = function (id) return store:prior(id, kupipi); end });
    f:fill(f:row(), 0x01002701, filter.CLASS.cure, 0);
    store:save(f);
    t.eq(read():find('Kupipi', 1, true), nil, read());
end);

t.test('a purge counts everyone forgotten, saved or not', function ()
    os.remove(path);
    local store, f = session(HORIZON, 1000);
    see(f, HANAYAKA);
    store:save(f);
    see(f, TAIL);
    t.eq(store:purge(f), 2, 'Hanayaka saved, Tail only drawn');
end);

t.test('a player is kept as last seen in the alliance, not as when the file was written', function ()
    os.remove(path);
    local store, f, clock = session(HORIZON, 1000);
    local roster = { [HANAYAKA] = MEMBERS[HANAYAKA], [TAIL] = MEMBERS[TAIL] };
    local world = { allianceMember = function (_, id) return roster[id]; end };
    see(f, HANAYAKA);
    see(f, TAIL);
    clock.now = 5000;
    store:reconcile(world, f);
    roster[TAIL] = nil;     -- Tail leaves
    clock.now = 9000;
    store:reconcile(world, f);
    clock.now = 20000;
    store:save(f);
    local text = read();
    t.truthy(text:find('%["Hanayaka"%] = {%s*%["PLD"%] = {%s*seen = 9000,'), text);
    t.truthy(text:find('%["Tail"%] = {%s*%["WHM"%] = {%s*seen = 5000,'), text);
end);

t.test('a seen time from the future or past what a number holds is taken as now', function ()
    local classes = 'melee = { mean = 1, sd = 1 }, weaponskill = { mean = 1, sd = 1 }, ability = { mean = 1, sd = 1 },'
        .. ' magic = { mean = 1, sd = 1 }, cure = { mean = 1, sd = 1 }, other = { mean = 1, sd = 1 }';
    write(('return { [%q] = {\n'):format(HORIZON)
        .. ('  Hanayaka = { PLD = { seen = 1e300, mean = 50, sd = 4, %s } },\n'):format(classes)
        .. ('  Tail = { WHM = { seen = 99999999, mean = -30, sd = 4, %s } },\n'):format(classes)
        .. '} }');
    local store = session(HORIZON, 5000);
    t.eq(store:prior(HANAYAKA, MEMBERS[HANAYAKA]).mean, 50);
    store:save(nil);
    local text = read();
    t.truthy(text:find('seen = 5000, mean = 50.00', 1, true) and text:find('seen = 5000, mean = -30.00', 1, true), text);
    t.eq(session(HORIZON, 5000 + priors.HALF_LIFE):prior(HANAYAKA, MEMBERS[HANAYAKA]).mean, (50 + 20) / 2, 'and fades from then');
end);

t.test('the server is the host the game was booted against', function ()
    t.eq(profiles.serverOf('--server play.horizonxi.com'), 'play.horizonxi.com');
    t.eq(profiles.serverOf('--hairpin --server  HomePointXI.com --port 54231'), 'homepointxi.com');
    t.eq(profiles.serverOf('--server=play.horizonxi.com'), 'play.horizonxi.com');
    t.eq(profiles.serverOf(''), 'default');
    t.eq(profiles.serverOf(nil), 'default');
end);

t.test('nothing in the addon can send anything anywhere', function ()
    local listing = io.popen('git ls-files --cached --others --exclude-standard "addon/*.lua"');
    local count = 0;
    for file in listing:lines() do
        -- The generated tables are data, their comments citing the wiki's URLs.
        if not file:find('^addon/data/') then
            count = count + 1;
            local fh = assert(io.open(file, 'rb'));
            local text = fh:read('*a');
            fh:close();
            for _, pattern in ipairs({ 'socket', 'http', 'AddOutgoingPacket', 'QueuePacket', 'QueueCommand',
                'popen', 'os%.execute', 'SendPacket' }) do
                t.eq(text:find(pattern), nil, ('%s in %s'):format(pattern, file));
            end
        end
    end
    listing:close();
    t.truthy(count >= 10, ('%d sources scanned'):format(count));
end);

t.test('a dark knight\'s Muted Soul belief is kept between sessions; nobody else\'s entry carries one', function ()
    os.remove(path);
    local store, f = session(HORIZON, 1000);
    see(f, HANAYAKA);
    see(f, BAT);
    local player, sum = f.players[BAT], 0;
    for lane = 1, f.count do
        local rank = f.bonus[(lane * filter.PLAYERS + player) * filter.SLOTS + filter.MUTED];
        f.weights[lane] = rank == 50 and 1 or 1e-12;
        sum = sum + f.weights[lane];
    end
    for lane = 1, f.count do
        f.weights[lane] = f.weights[lane] / sum;
    end
    t.truthy(f:posterior(BAT).muted[5] > 0.99);
    store:save(f);
    local text = read();
    t.truthy(text:find('muted = { 0.000, 0.000, 0.000, 0.000, 0.000, 1.000 },', 1, true), text);
    t.eq(select(2, text:gsub('muted = ', '')), 1, 'Hanayaka\'s entry has none');

    local later = session(HORIZON, 1000);
    local p = later:prior(BAT, MEMBERS[BAT]);
    t.truthy(p.muted[5] > 0.85 and p.muted[0] >= priors.MIN_MASS, ('remembered %g'):format(p.muted[5]));
    local month = session(HORIZON, 1000 + priors.HALF_LIFE);
    local faded = month:prior(BAT, MEMBERS[BAT]).muted[5];
    t.truthy(faded < p.muted[5] and faded > 0.5, ('faded %g'):format(faded));
end);

t.test('an entry without a Muted Soul line takes the job\'s; a malformed one is dropped', function ()
    os.remove(path);
    local store, f = session(HORIZON, 1000);
    see(f, BAT);
    store:save(f);
    local text = read();
    write((text:gsub('%s*muted = {[^}]*},', '')));
    local p = session(HORIZON, 1000):prior(BAT, MEMBERS[BAT]);
    t.truthy(math.abs(p.muted[5] - priors.forJob('DRK').muted[5]) < 0.01, 'the job prior');
    write((text:gsub('muted = {[^}]*}', 'muted = { 1, -1, 0, 0, 0, 0 }')));
    t.eq(session(HORIZON, 1000):prior(BAT, MEMBERS[BAT]), priors.forJob('DRK'), 'dropped');
end);

return t.done();

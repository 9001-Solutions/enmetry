local options = require('options');
local world = require('world');

local commands = {};

local HELP = {
    '/enmetry                  status line',
    '/enmetry compact [on|off] toggle the compact panel: no header, no numbers, narrower',
    '/enmetry debug [on|off]   toggle the live action feed',
    '/enmetry clear            empty the action feed',
    '/enmetry alliance         list alliance slots with jobs',
    '/enmetry pin              lock the panel on the mob shown',
    '/enmetry unpin            let the panel follow your target again',
    '/enmetry settings [on|off] open or close the settings panel',
    '/enmetry rows [n]         show up to n bars (1-18)',
    '/enmetry calibration      how often mobs attacked whom the filter expected, this session',
    '/enmetry research         the open questions about Horizon, what is logged for them, and the last scoring',
    '/enmetry reset            forget every hate list, as after a wipe',
    '/enmetry forget <name>    forget what was learned about a character',
    '/enmetry purge confirm    forget every character on every server',
    '/enmetry log              where the session log is going',
    '/enmetry mark <note>      write a note into the session log, e.g. what just went wrong',
    '/enmetry help             this list',
};

local function words(line)
    local out = {};
    for w in line:gmatch('%S+') do
        out[#out + 1] = w;
    end
    return out;
end

local function onOff(flag)
    return flag and 'on' or 'off';
end

local handlers = {};

function handlers.status(ctx)
    local particles = ctx.filter and ('%d particles'):format(ctx.filter.count) or 'particles off';
    return {
        ('v%s | debug feed %s | %d events seen | alliance %d/%d | %s'):format(
            ctx.version, onOff(ctx.settings.debug), ctx.feed.total, ctx.world:memberCount(), world.ALLIANCE_SLOTS,
            particles),
    };
end

function handlers.debug(ctx, arg)
    if arg == 'on' then
        ctx.settings.debug = true;
    elseif arg == 'off' then
        ctx.settings.debug = false;
    else
        ctx.settings.debug = not ctx.settings.debug;
    end
    ctx.save();
    return { 'debug feed ' .. onOff(ctx.settings.debug) };
end

function handlers.compact(ctx, arg)
    if arg == 'on' then
        ctx.settings.compact = true;
    elseif arg == 'off' then
        ctx.settings.compact = false;
    else
        ctx.settings.compact = not ctx.settings.compact;
    end
    ctx.save();
    return { 'compact panel ' .. onOff(ctx.settings.compact) };
end

function handlers.clear(ctx)
    ctx.feed:clear();
    return { 'feed cleared' };
end

function handlers.alliance(ctx)
    local out = { ('alliance %d/%d'):format(ctx.world:memberCount(), world.ALLIANCE_SLOTS) };
    for slot = 0, world.ALLIANCE_SLOTS - 1 do
        local m = ctx.world:member(slot);
        if m ~= nil then
            local jobs = ('%s%d'):format(m.mainJob or '?', m.mainLevel or 0);
            if m.subJob ~= nil then
                jobs = ('%s/%s%d'):format(jobs, m.subJob, m.subLevel or 0);
            end
            out[#out + 1] = ('%3d  %s  %s'):format(slot, m.name, jobs);
        end
    end
    return out;
end

function handlers.pin(ctx)
    local mob = ctx.focus:pin();
    if mob == nil then
        return { 'nothing to pin' };
    end
    return { 'focus pinned to ' .. (ctx.nameOf(mob) or ('0x%08X'):format(mob)) };
end

function handlers.unpin(ctx)
    if ctx.focus:unpin() == nil then
        return { 'focus was not pinned' };
    end
    return { 'focus follows your target' };
end

function handlers.settings(ctx, arg)
    local open = ctx.panel.open;
    if arg == 'on' then
        open[1] = true;
    elseif arg == 'off' then
        open[1] = false;
    else
        open[1] = not open[1];
    end
    return { open[1] and 'settings panel open' or 'settings panel closed' };
end

function handlers.rows(ctx, arg)
    if arg ~= nil then
        local rows = options.field('rows');
        if not options.set(ctx.settings, 'rows', tonumber(arg)) then
            return { ('rows must be a whole number from %d to %d'):format(rows.min, rows.max) };
        end
        ctx.save();
    end
    return { ('showing up to %d bars'):format(ctx.settings.rows) };
end

function handlers.calibration(ctx)
    local cal = ctx.sim.calibration;
    if cal == nil then
        return { 'calibration off -- the particle filter is off, set particles above 0 in settings.lua and reload' };
    end
    return cal:readout();
end

function handlers.research(ctx)
    if ctx.research == nil then
        return { 'research log off -- turn it on in /enmetry settings' };
    end
    return ctx.research:readout(ctx.researchPosterior(), ctx.researchFile);
end

function handlers.reset(ctx)
    ctx.sim:reset();
    ctx.focus:unpin();
    return { 'every hate list reset' };
end

function handlers.forget(ctx, _, name)
    if name == nil then
        return { 'forget whom? /enmetry forget <name>' };
    end
    local kept = ctx.profiles:forget(name, ctx.filter);
    if kept == nil then
        return { ('nothing kept on %s'):format(name) };
    end
    ctx.saveProfiles();
    return { 'forgot ' .. kept };
end

function handlers.purge(ctx, arg)
    if arg ~= 'confirm' then
        return { 'this forgets every character on every server -- /enmetry purge confirm' };
    end
    local count = ctx.profiles:purge(ctx.filter);
    ctx.saveProfiles();
    return { ('forgot %d characters'):format(count) };
end

function handlers.log(ctx)
    if ctx.log == nil then
        return { 'session log off -- turn it on in /enmetry settings' };
    end
    return { ('session log: %d lines to %s'):format(ctx.log.lines, ctx.logFile) };
end

function handlers.mark(ctx, _, _, rest)
    if ctx.log == nil then
        return { 'session log off -- nothing to mark' };
    end
    if rest == '' then
        return { 'mark what? /enmetry mark <note>' };
    end
    ctx.log:write('mark', { text = rest });
    ctx.log:flush();
    return { 'marked: ' .. rest };
end

function handlers.help()
    return HELP;
end

function commands.handle(line, ctx)
    local args = words(line);
    if args[1] == nil or args[1]:lower() ~= '/enmetry' then
        return nil;
    end

    local name = (args[2] or 'status'):lower();
    local handler = handlers[name];
    if handler == nil then
        return { ("unknown command '%s' -- try /enmetry help"):format(args[2]) };
    end
    local rest = line:match('^%s*%S+%s+%S+%s*(.-)%s*$') or '';
    return handler(ctx, args[3] and args[3]:lower(), args[3], rest);
end

return commands;

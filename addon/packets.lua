local packets = {};

-- Arithmetic, not the bit library, so 32-bit fields come back unsigned.
local function read(data, pos, n)
    local value = 0;
    local scale = 1;
    local remaining = n;
    while remaining > 0 do
        local byte = data:byte(math.floor(pos / 8) + 1);
        if byte == nil then
            return nil, pos;
        end
        local shift = pos % 8;
        local take = math.min(8 - shift, remaining);
        local chunk = math.floor(byte / 2 ^ shift) % 2 ^ take;
        value = value + chunk * scale;
        scale = scale * 2 ^ take;
        pos = pos + take;
        remaining = remaining - take;
    end
    return value, pos;
end

local function cursor(data, pos)
    local c = { ok = true };
    function c.take(n)
        if not c.ok then
            return 0;
        end
        local v;
        v, pos = read(data, pos, n);
        if v == nil then
            c.ok = false;
            return 0;
        end
        return v;
    end
    return c;
end

local function subEffect(c, paramBits)
    return {
        kind = c.take(6),
        info = c.take(4),
        param = c.take(paramBits),
        message = c.take(10),
    };
end

function packets.parseAction(data)
    -- Header (4 bytes) and the WorkSize byte precede the bit stream.
    local c = cursor(data, 8 * 5);

    local event = {
        kind = 'action',
        actorId = c.take(32),
        targets = {},
    };
    local targetCount = c.take(6);
    c.take(4); -- res_sum, always 0
    event.category = c.take(4);
    event.param = c.take(32);
    event.recast = c.take(32);

    for i = 1, targetCount do
        local target = { id = c.take(32), results = {} };
        local resultCount = c.take(4);
        for j = 1, resultCount do
            local result = {
                reaction = c.take(3),
                kind = c.take(2),
                animation = c.take(12),
                info = c.take(5),
                scale = c.take(5),
                param = c.take(17),
                message = c.take(10),
                modifier = c.take(31),
            };
            if c.take(1) == 1 then
                result.addEffect = subEffect(c, 17);
            end
            if c.take(1) == 1 then
                result.spikes = subEffect(c, 14);
            end
            target.results[j] = result;
        end
        event.targets[i] = target;
        if not c.ok then
            return nil;
        end
    end

    if not c.ok then
        return nil;
    end
    return event;
end

local function u32(data, offset)
    local a, b, c, d = data:byte(offset + 1, offset + 4);
    return a + b * 0x100 + c * 0x10000 + d * 0x1000000;
end

local function u16(data, offset)
    local a, b = data:byte(offset + 1, offset + 2);
    return a + b * 0x100;
end

function packets.parseMessage(data)
    if #data < 0x1A then
        return nil;
    end
    return {
        kind = 'message',
        actorId = u32(data, 0x04),
        targetId = u32(data, 0x08),
        param = u32(data, 0x0C),
        value = u32(data, 0x10),
        actorIndex = u16(data, 0x14),
        targetIndex = u16(data, 0x16),
        message = u16(data, 0x18),
    };
end

-- /check reply message ids, defence/evasion and the ungaugeable one; param is the level, value the difficulty band.
local CHECK_FIRST, CHECK_LAST, CHECK_UNGAUGEABLE = 0xAA, 0xB2, 0xF9;
local CHECK_BAND_FIRST, CHECK_BAND_LAST = 0x40, 0x47;

function packets.checkedLevel(event)
    local m = event.message;
    if m ~= CHECK_UNGAUGEABLE and (m < CHECK_FIRST or m > CHECK_LAST
        or event.value < CHECK_BAND_FIRST or event.value > CHECK_BAND_LAST) then
        return nil;
    end
    local level = event.param;
    if level < 1 or level > 200 then
        return nil;
    end
    return level;
end

-- 0x050, outgoing: one slot changed; an inventory index of 0 empties it.
function packets.parseEquip(data)
    if #data < 0x08 then
        return;
    end
    return data:byte(0x05 + 1), data:byte(0x06 + 1), data:byte(0x04 + 1);
end

-- 0x051, outgoing: a whole set, count at 0x04, then index, slot, container per entry from 0x08.
function packets.parseEquipSet(data)
    if #data < 0x08 then
        return;
    end
    local out = {};
    for i = 0, data:byte(0x04 + 1) - 1 do
        local at = 0x08 + i * 4;
        if #data < at + 4 then
            break;
        end
        out[#out + 1] = { slot = data:byte(at + 2), container = data:byte(at + 3), index = data:byte(at + 1) };
    end
    return out;
end

-- 0x08C: merits, as GP_SERV_COMMAND_MERIT lays them out: count at 0x04, then id, next cost, count per entry from 0x08.
function packets.parseMerits(data)
    if #data < 0x08 then
        return;
    end
    local out = {};
    for i = 0, u16(data, 0x04) - 1 do
        local at = 0x08 + i * 4;
        if #data < at + 4 then
            break;
        end
        local id = u16(data, at);
        if id ~= 0 then
            out[id] = data:byte(at + 3 + 1);
        end
    end
    return out;
end

function packets.parseWidescan(data)
    if #data < 0x1C then
        return;
    end
    local name = data:sub(0x0C + 1, 0x1B + 1):match('^[^%z]*');
    return u16(data, 0x04), data:byte(0x06 + 1), name;
end

-- 0x00E SendFlg bits, per LSB entity_update.cpp's sendflags_t.
local SEND_GENERAL = 0x04;
local SEND_DESPAWN = 0x20;

-- Flags2 sits at 0x24; its second byte is `g`, which entity_update.cpp fills
-- with modelHitboxSize * 10.  Every range check on the server adds both
-- entities' hitboxes, so a mob's reach is its own size plus the flat range.
local function hitboxOf(data)
    if #data < 0x28 then
        return nil;
    end
    local tenths = data:byte(0x25 + 1);
    if tenths == 0 then
        return nil;
    end
    return tenths / 10;
end

-- 0x00D, the PC counterpart of 0x00E.  ModelHitboxSize is a byte of its own at
-- 0x43, after the monstrosity fields: char_update.cpp fills it the same way,
-- modelHitboxSize * 10.  Players are small, around a yalm, but the server adds
-- their hitbox to every range check just the same.
function packets.parseCharUpdate(data)
    if #data < 0x44 then
        return;
    end
    local flags = data:byte(0x0A + 1);
    if flags % (SEND_GENERAL * 2) < SEND_GENERAL then
        return;
    end
    local tenths = data:byte(0x43 + 1);
    if tenths == 0 then
        return u32(data, 0x04);
    end
    return u32(data, 0x04), tenths / 10;
end

function packets.parseEntityUpdate(data)
    if #data < 0x20 then
        return;
    end
    local flags = data:byte(0x0A + 1);
    if flags % (SEND_DESPAWN * 2) >= SEND_DESPAWN then
        return u32(data, 0x04), nil, true;
    elseif flags % (SEND_GENERAL * 2) >= SEND_GENERAL then
        return u32(data, 0x04), data:byte(0x1F + 1), false, data:byte(0x1E + 1), hitboxOf(data);
    end
end

return packets;

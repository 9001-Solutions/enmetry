--[[
* Packet parsing: raw 0x028 / 0x029 bytes in, structured events out.
*
* The golden 0x028 bytes were produced by an independent Python port of
* LandSandBoat's packBitsBE (src/common/utils.cpp) driven with the field order
* in src/map/packets/s2c/0x028_battle2.cpp, not by this parser's reader.
*
* Run: luajit tests/test_packets.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local packets = require('packets');

-- Two-swing melee round: 0x0001E240 on 0x0100A012, a 34 hit then a miss.
local MELEE = t.hex([[
    280000000040E20100010400000000000000800428408000000040044000000000004200000000E00100000000
]]);

-- Category 4 spell 2 on two targets; the second result saturates every field
-- and carries both an added effect and a spikes block.
local CURE = t.hex([[
    2800000000FEFFFFFF0290000000C00100004090780040000100400BC00100000000FE41010262
    FEFFFFFFFFFFFFFFFFFFFFFFFFFFFFD5FCFF5900
]]);

t.test('action packet carries actor, category, param and per-target results', function ()
    t.eq(packets.parseAction(MELEE), {
        kind = 'action',
        actorId = 0x0001E240,
        category = 1,
        param = 0,
        recast = 0,
        targets = {
            {
                id = 0x0100A012,
                results = {
                    { reaction = 0, kind = 0, animation = 0, info = 0, scale = 0, param = 34, message = 1, modifier = 0 },
                    { reaction = 1, kind = 0, animation = 1, info = 0, scale = 0, param = 0, message = 15, modifier = 0 },
                },
            },
        },
    });
end);

t.test('action packet reads full-width fields, added effects and spikes', function ()
    t.eq(packets.parseAction(CURE), {
        kind = 'action',
        actorId = 0xFFFFFFFE,
        category = 4,
        param = 2,
        recast = 7,
        targets = {
            {
                id = 0x0001E241,
                results = {
                    { reaction = 0, kind = 0, animation = 2, info = 0, scale = 0, param = 90, message = 7, modifier = 0 },
                },
            },
            {
                id = 0x0100A0FF,
                results = {
                    {
                        reaction = 3, kind = 2, animation = 4095, info = 31, scale = 31,
                        param = 131071, message = 1023, modifier = 0x7FFFFFFF,
                        addEffect = { kind = 63, info = 15, param = 131071, message = 1023 },
                        spikes = { kind = 42, info = 9, param = 16383, message = 44 },
                    },
                },
            },
        },
    });
end);

t.test('a truncated action packet yields nothing rather than half an event', function ()
    t.eq(packets.parseAction(MELEE:sub(1, 20)), nil);
    t.eq(packets.parseAction(''), nil);
end);

t.test('message packet carries actor, target, indices, param, value and message id', function ()
    -- Layout per LSB 0x029_battle_message.h: four uint32 then three uint16, from 0x04.
    local data = string.char(0x29, 0x0E, 0x00, 0x00)
        .. string.char(0x40, 0xE2, 0x01, 0x00)   -- UniqueNoCas 0x0001E240
        .. string.char(0x12, 0xA0, 0x00, 0x01)   -- UniqueNoTar 0x0100A012
        .. string.char(0x2C, 0x01, 0x00, 0x00)   -- Data 300
        .. string.char(0xFF, 0xFF, 0xFF, 0xFF)   -- Data2 4294967295
        .. string.char(0x05, 0x04)               -- ActIndexCas 0x405
        .. string.char(0x12, 0x00)               -- ActIndexTar 0x012
        .. string.char(0x06, 0x00)               -- MessageNum 6
        .. string.char(0x00, 0x00);
    t.eq(packets.parseMessage(data), {
        kind = 'message',
        actorId = 0x0001E240,
        targetId = 0x0100A012,
        param = 300,
        value = 4294967295,
        actorIndex = 0x405,
        targetIndex = 0x012,
        message = 6,
    });
end);

t.test('a truncated message packet yields nothing', function ()
    t.eq(packets.parseMessage(string.rep('\0', 0x19)), nil);
end);

--[[
* An 0x00E entity update, laid out per LSB entity_update.cpp: UniqueNo at 0x04,
* ActIndex at 0x08, SendFlg at 0x0A, and with the General bit (0x04) the HP%
* at 0x1E and the animation at 0x1F.  A despawn sets SendFlg to 0x30.
--]]
local function entityUpdate(id, flags, hpp, animation)
    local bytes = { 0x0E, 0x2C, 0x00, 0x00 };
    for i = 0, 3 do
        bytes[#bytes + 1] = math.floor(id / 2 ^ (8 * i)) % 256;
    end
    bytes[#bytes + 1] = 0x12;  -- ActIndex 0x012
    bytes[#bytes + 1] = 0x00;
    bytes[#bytes + 1] = flags;
    while #bytes < 0x1E do
        bytes[#bytes + 1] = 0xAA;
    end
    bytes[#bytes + 1] = hpp;
    bytes[#bytes + 1] = animation;
    while #bytes < 0x58 do
        bytes[#bytes + 1] = 0;
    end
    return string.char(unpack(bytes));
end

t.test('an entity update with the general bit carries the mob\'s animation', function ()
    t.eq({ packets.parseEntityUpdate(entityUpdate(0x0100A012, 0x07, 64, 1)) }, { 0x0100A012, 1, false, 64 });
    t.eq({ packets.parseEntityUpdate(entityUpdate(0x0100A012, 0x0F, 100, 0)) }, { 0x0100A012, 0, false, 100 });
end);

t.test('an entity update without the general bit says nothing about status', function ()
    t.eq({ packets.parseEntityUpdate(entityUpdate(0x0100A012, 0x01, 0, 0)) }, {});
end);

t.test('an entity update carries the HP percent beside the animation', function ()
    t.eq({ packets.parseEntityUpdate(entityUpdate(0x0100A012, 0x07, 100, 1)) }, { 0x0100A012, 1, false, 100 });
end);

t.test("an entity update carries the mob's hitbox, in tenths of a yalm", function ()
    local raw = entityUpdate(0x0100A012, 0x07, 100, 1);
    t.eq({ packets.parseEntityUpdate(raw) }, { 0x0100A012, 1, false, 100 }, 'zero means none was sent');

    -- Flags2 is at 0x24 and its second byte is modelHitboxSize * 10, so 16
    -- here is Jailer of Love's 1.6 yalms.
    local withHitbox = raw:sub(1, 0x25) .. string.char(16) .. raw:sub(0x27);
    t.eq(#withHitbox, #raw, 'the patch keeps the length');
    t.eq({ packets.parseEntityUpdate(withHitbox) }, { 0x0100A012, 1, false, 100, 1.6 });
end);

-- 0x00D: the same head as 0x00E, then the PC-only tail.  ModelHitboxSize is a
-- byte of its own at 0x43.
local function charUpdate(id, flags, hitboxTenths)
    local bytes = { 0x0D, 0x00, 0x00, 0x00 };
    local n = id;
    for _ = 1, 4 do
        bytes[#bytes + 1] = n % 256;
        n = math.floor(n / 256);
    end
    bytes[#bytes + 1] = 0x00;
    bytes[#bytes + 1] = 0x00;
    bytes[#bytes + 1] = flags;
    while #bytes < 0x43 do
        bytes[#bytes + 1] = 0xAA;
    end
    bytes[#bytes + 1] = hitboxTenths;
    while #bytes < 0x6A do
        bytes[#bytes + 1] = 0;
    end
    return string.char(unpack(bytes));
end

t.test("a char update carries the player's hitbox, in tenths of a yalm", function ()
    t.eq({ packets.parseCharUpdate(charUpdate(0x0001E240, 0x07, 10)) }, { 0x0001E240, 1.0 });
    t.eq({ packets.parseCharUpdate(charUpdate(0x0001E240, 0x07, 0)) }, { 0x0001E240 },
        'zero means none was sent');
    t.eq({ packets.parseCharUpdate(charUpdate(0x0001E240, 0x01, 10)) }, {},
        'without the general bit it says nothing');
    t.eq({ packets.parseCharUpdate(charUpdate(0x0001E240, 0x07, 10):sub(1, 0x43)) }, {},
        'truncated before the field');
end);

t.test('a despawn update is reported as one', function ()
    t.eq({ packets.parseEntityUpdate(entityUpdate(0x0100A012, 0x30, 0, 2)) }, { 0x0100A012, nil, true });
end);

t.test('a truncated entity update yields nothing', function ()
    t.eq({ packets.parseEntityUpdate(entityUpdate(0x0100A012, 0x07, 64, 1):sub(1, 0x1F)) }, {});
end);

local function le(n, bytes)
    local out = {};
    for i = 1, bytes do
        out[i] = string.char(n % 256);
        n = math.floor(n / 256);
    end
    return table.concat(out);
end

-- An 0x029 message: actor, target, param, value, indices, message id.
local function message(param, value, id)
    return string.char(0x29, 0x0E, 0, 0) .. le(0x0001E240, 4) .. le(0x0100A012, 4) .. le(param, 4) .. le(value, 4)
        .. le(0x405, 2) .. le(0x012, 2) .. le(id, 2) .. le(0, 2);
end

t.test('a /check reply states the level in its param; other messages and gaugeless replies state none', function ()
    t.eq(packets.checkedLevel(packets.parseMessage(message(88, 0x44, 0xAA))), 88);
    t.eq(packets.checkedLevel(packets.parseMessage(message(90, 0x47, 0xB2))), 90);
    t.eq(packets.checkedLevel(packets.parseMessage(message(75, 0, 0xF9))), 75, 'impossible to gauge, level given');
    t.eq(packets.checkedLevel(packets.parseMessage(message(0, 0, 0xF9))), nil, 'impossible to gauge, no level');
    t.eq(packets.checkedLevel(packets.parseMessage(message(4294967295, 0x44, 0xAA))), nil, 'a negative level');
    t.eq(packets.checkedLevel(packets.parseMessage(message(88, 0x44, 0xA9))), nil, 'not a check message');
    t.eq(packets.checkedLevel(packets.parseMessage(message(88, 0x12, 0xAA))), nil, 'not a difficulty band');
    t.eq(packets.checkedLevel(packets.parseMessage(message(88, 0x44, 0xB3))), nil);
end);

t.test('a widescan row carries the entity index, its level and its name', function ()
    local row = string.char(0xF4, 0x0E, 0, 0) .. le(0x012, 2) .. string.char(90) .. string.char(2)
        .. le(0, 2) .. le(0, 2) .. 'Goblin Thug' .. string.rep('\0', 5);
    t.eq(#row, 0x1C);
    t.eq({ packets.parseWidescan(row) }, { 0x012, 90, 'Goblin Thug' });
    t.eq({ packets.parseWidescan(row:sub(1, 0x1B)) }, {});
end);

return t.done();

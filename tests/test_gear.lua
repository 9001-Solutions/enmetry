--[[
* Your own worn set, followed from the outgoing equip packets and inventory
* memory, and the Enmity it carries at a moment.
*
* Run: luajit tests/test_gear.lua
--]]

package.path = './tests/?.lua;./addon/?.lua;' .. package.path;
local t = require('helpers');
local gear = require('gear');

local ITEMS = {
    [15544] = { name = 'sattva_ring', enmity = 5, trust = 'era' },
    [13437] = { name = 'healers_earring', latentEnmity = -2, subJob = 'WHM', trust = 'era' },
    [10272] = { name = 'dux_scale_mail', enmity = 6, trust = 'lsb' },
    [10350] = { name = 'wohpes_sabots', enmity = -10, trust = 'lsb' },
};

t.test('an empty set carries nothing and is not known until read', function ()
    local g = gear.new(ITEMS);
    t.eq({ g.known, g:enmity('WAR') }, { false, 0 });
end);

t.test('the set is read from inventory memory, by equipped index into its container', function ()
    local equipped = { [5] = 2, [13] = 8 * 256 + 1 };
    local items = { [0] = { [2] = 10272 }, [8] = { [1] = 15544 } };
    local inventory = {
        GetEquippedItem = function (_, slot) return { Index = equipped[slot] or 0 }; end,
        GetContainerItem = function (_, container, index) return { Id = items[container] and items[container][index] or 0 }; end,
    };
    local g = gear.new(ITEMS);
    g:read(inventory, 10);
    t.eq({ g.known, g:enmity('WAR'), g.worn[5], g.worn[13] }, { true, 11, 10272, 15544 });
    t.eq(g:carrying('WAR'), { 10272, 15544 });
end);

t.test('equip packets move the set, and the Enmity of the set at an earlier moment is read back through the changes', function ()
    local g = gear.new(ITEMS);
    g:equip(5, 10272, 1);
    g:equip(13, 15544, 1);
    t.eq(g:enmity('WAR'), 11);
    t.eq(g:equip(5, 10272, 2), false, 'no change');
    g:equip(5, 10350, 3);
    g:equip(13, 0, 3.5);
    t.eq(g:enmity('WAR'), -10);
    t.eq(g:enmity('WAR', 2.9), 11, 'before the swap');
    t.eq(g:enmity('WAR', 3.2), -5, 'the body swapped, the ring not yet');
    t.eq(g:enmity('WAR', 3.5), -10, 'a change at the moment itself counts');
    t.eq(g:enmity('WAR', 0.5), 0, 'before anything was worn');
end);

t.test('a support-job latent counts only for that support job', function ()
    local g = gear.new(ITEMS);
    g:equip(11, 13437, 1);
    g:equip(13, 15544, 1);
    t.eq({ g:enmity('WHM'), g:enmity('BLM'), g:enmity(nil) }, { 3, 5, 5 });
    t.eq(g:carrying('BLM'), { 15544 });
    t.eq(g:carrying('WHM'), { 13437, 15544 });
end);

t.test('the set at a moment breaks down item by item, with only the items that carry Enmity', function ()
    local g = gear.new(ITEMS);
    g:equip(5, 10272, 1);
    g:equip(11, 13437, 1);
    g:equip(13, 15544, 1);
    g:equip(0, 17440, 1);
    t.eq(g:breakdown('WHM'), {
        { id = 10272, name = 'dux_scale_mail', value = 6 },
        { id = 13437, name = 'healers_earring', value = -2 },
        { id = 15544, name = 'sattva_ring', value = 5 },
    });
    t.eq(g:breakdown('BLM'), {
        { id = 10272, name = 'dux_scale_mail', value = 6 },
        { id = 15544, name = 'sattva_ring', value = 5 },
    });
    g:equip(13, 0, 2);
    t.eq(#g:breakdown('BLM', 1.5), 2, 'the ring still on then');
    t.eq(#g:breakdown('BLM'), 1);
end);

t.test('an item the table does not list carries nothing', function ()
    local g = gear.new(ITEMS);
    g:equip(0, 17440, 1);
    t.eq(g:enmity('WAR'), 0);
end);

t.test('the ring of changes wraps; a moment older than it reads as the oldest change kept', function ()
    local g = gear.new(ITEMS);
    g:equip(13, 15544, 0);
    for i = 1, 200 do
        g:equip(5, i % 2 == 0 and 10272 or 10350, i);
    end
    t.eq(g:enmity('WAR'), 11);
    t.eq(g:enmity('WAR', 199.5), -5);
    t.eq(g:enmity('WAR', 0.5), 11, 'the ring reaches back to change 73; the ring on since 0 fell off it');
end);

t.done();

--[[
* The table generator's pieces, each against small hand-written source
* excerpts: SQL dumps, wikitext, mobskill scripts, zone YAML, and the Lua it
* writes back out.
*
* Run: luajit tests/test_gentables.lua
--]]

package.path = './tests/?.lua;./tools/?.lua;' .. package.path;
local t = require('helpers');
local sql = require('tables.sql');
local wiki = require('tables.wiki');
local mobskills = require('tables.mobskills');
local moblevels = require('tables.moblevels');
local actions = require('tables.actions');
local emit = require('tables.emit');
local cite = require('tables.cite');
local overlays = require('tables.overlays');

t.test('sql rows are read from one table only, with typed values', function ()
    local dump = table.concat({
        "INSERT INTO `abilities` VALUES (35,'provoke',1,5,-2,16.5,NULL);",
        "INSERT INTO `other` VALUES (1,'nope');",
        "-- INSERT INTO `abilities` VALUES (99,'commented_out',0,0,0,0,NULL);",
        "INSERT INTO `abilities` VALUES (46,'shield_bash',7,15,0,0.0,'ROTZ'); -- trailing comment",
    }, '\n');
    local rows = sql.rows(dump, 'abilities');
    t.eq(#rows, 2);
    t.eq(rows[1], { 35, 'provoke', 1, 5, -2, 16.5, sql.NULL });
    t.eq(rows[2], { 46, 'shield_bash', 7, 15, 0, 0.0, 'ROTZ' });
end);

t.test('sql strings keep escaped quotes, commas and parentheses', function ()
    local rows = sql.rows([[INSERT INTO `t` VALUES (1,'it\'s (a), b','o''k');]], 't');
    t.eq(rows[1], { 1, "it's (a), b", "o'k" });
end);

t.test('sql variables, flag expressions and hex literals stay as written', function ()
    local rows = sql.rows(
        'INSERT INTO `spell_list` VALUES (1,0x00000100030005,@ELEMENT_LIGHT,@FLAG_A | @FLAG_B);',
        'spell_list');
    t.eq(rows[1], { 1, '0x00000100030005', '@ELEMENT_LIGHT', '@FLAG_A | @FLAG_B' });
end);

t.test('sql inserts with several rows yield each row', function ()
    local rows = sql.rows("INSERT INTO `t` VALUES (1,'a'),(2,'b');", 't');
    t.eq(rows, { { 1, 'a' }, { 2, 'b' } });
end);

local ENMITY_TABLE = [==[
Intro text with a [[link]].

==Single Target==

{| class="npc-table"
! width="60%" | Ability or Spell
! width="20%" | CE Units
! width="20%" | VE Units
|-
|Provoke
|1
|1800
|-
|Amplification
|320
|#
|-
|Blank Gaze
|320
|
|-
|Release
| -10
|0
|-
|-
|Jettatura
|1|80
|1020
|-
|Viruna
|1
|300
|-
|Viruna
|1
|300
|-
|Sleep
|320
|240
|-
|Sleep
|480
|240
|-
|}

==Multiple Targets==

{| class="npc-table"
! width="60%" | Multiple Targets
! width="20%" | CE Units
! width="20%" | VE Units
|-
|Warcry
|1
|300
|-
|}
]==];

t.test('wiki enmity rows carry the table they came from; blank and # are unverified', function ()
    local parsed = wiki.enmityTable(ENMITY_TABLE);
    t.eq(parsed.rows, {
        { name = 'Provoke', ce = 1, ve = 1800, section = 'Single Target' },
        { name = 'Amplification', ce = 320, section = 'Single Target' },
        { name = 'Blank Gaze', ce = 320, section = 'Single Target' },
        { name = 'Release', ce = -10, ve = 0, section = 'Single Target' },
        { name = 'Viruna', ce = 1, ve = 300, section = 'Single Target' },
        { name = 'Warcry', ce = 1, ve = 300, section = 'Multiple Targets' },
    });
end);

t.test('wiki rows that cannot be read unambiguously are reported, not guessed', function ()
    local parsed = wiki.enmityTable(ENMITY_TABLE);
    t.eq(parsed.malformed, { 'Jettatura', 'Sleep' });
end);

t.test('wiki sections are found by name, quoted or not', function ()
    local page = table.concat({
        '<section begin=Defender/>*[[Defender]] provides -25% enmity loss reduction.<section end=Defender/>',
        '<section begin="Hojo:Ni"/>* [[Hojo: Ni]] provides +40 [[Enmity|cumulative enmity (CE)]].<section end="Hojo:Ni"/>',
    }, '\n');
    t.eq(wiki.section(page, 'Defender'), '*[[Defender]] provides -25% enmity loss reduction.');
    t.eq(wiki.section(page, 'Hojo:Ni'), '* [[Hojo: Ni]] provides +40 [[Enmity|cumulative enmity (CE)]].');
    t.eq(wiki.section(page, 'Missing'), nil);
end);

t.test('wiki markup flattens to the sentence a reader sees', function ()
    t.eq(wiki.plain("* [[Hojo: Ni]] provides +40 [[Enmity|cumulative enmity (CE)]]. '''Bold''' {{verification}}\n  next"),
        '* Hojo: Ni provides +40 cumulative enmity (CE). Bold next');
    t.eq(wiki.plain("renamed to {{Item Tooltip|Healer's Belt}}, from ''[[Club Skill]] +5''"),
        "renamed to Healer's Belt, from Club Skill +5");
end);

local function skill(body)
    return 'local mobskillObject = {}\n\n'
        .. 'mobskillObject.onMobWeaponSkill = function(target, mob, skill)\n'
        .. body
        .. '\nend\n\nreturn mobskillObject\n';
end

t.test('a mobskill that never touches enmity has no effect', function ()
    t.eq(mobskills.classify(skill('    return xi.mobskills.mobPhysicalMove(mob, target, skill)')),
        { effect = 'none', trust = 'lsb' });
end);

t.test('an unconditional resetEnmity is a full reset', function ()
    t.eq(mobskills.classify(skill('    mob:resetEnmity(target)\n    return 0')),
        { effect = 'reset', trust = 'lsb', conditional = false, line = 4 });
end);

t.test('a reset nested under a condition says so', function ()
    t.eq(mobskills.classify(skill('    if damage > 0 then\n        mob:resetEnmity(target)\n    end')),
        { effect = 'reset', trust = 'lsb', conditional = true, line = 5 });
end);

t.test('lowerEnmity is a partial reduction by its percentage', function ()
    t.eq(mobskills.classify(skill('    mob:lowerEnmity(target, 45)')),
        { effect = 'reduce', percent = 45, trust = 'lsb', conditional = false, line = 4 });
end);

t.test('commented-out enmity calls are ignored', function ()
    t.eq(mobskills.classify(skill('    -- mob:resetEnmity(target)\n    return 0')),
        { effect = 'none', trust = 'lsb' });
end);

t.test('any other enmity call is not a known hate effect and is flagged', function ()
    t.eq(mobskills.classify(skill('    target:addEnmity(mob, 1, 1800)')),
        { effect = 'none', trust = 'unknown', call = 'target:addEnmity', line = 4 });
    t.eq(mobskills.classify(skill('    mob:addEnmity(t, 1, 1)\n    target:resetEnmity(t)')),
        { effect = 'none', trust = 'unknown', call = 'mob:addEnmity', line = 4 });
end);

t.test('mobskill ids take their effect from the script named after them', function ()
    local rows = {
        { 1, 16, 'combo' },
        { 2, 17, 'brainjack' },
        { 3, 18, 'brainjack' },
        { 4, 19, 'no_script' },
    };
    local scripts = {
        combo = skill('    return 0'),
        brainjack = skill('    mob:resetEnmity(target)'),
    };
    local built = mobskills.build(rows, scripts);
    t.eq(built.skills[1], { id = 1, name = 'combo', effect = 'none', trust = 'lsb' });
    t.eq(built.skills[3], { id = 3, name = 'brainjack', effect = 'reset', trust = 'lsb', conditional = false, line = 4 });
    t.eq(built.skills[4], nil);
    t.eq(built.missing, { 'no_script' });
end);

t.test('a zone mob script that resets enmity is found, with the skill ids it checks', function ()
    local script = table.concat({
        'entity.onMobSpawn = function(mob)',
        "    mob:addListener('WEAPONSKILL_USE', 'RESET', function(mobArg, target, skill)",
        '        if skill:getID() == 269 then',
        '            mob:resetEnmity(target)',
        '        end',
        '    end)',
        'end',
    }, '\n');
    t.eq(mobskills.mobScript(script), { line = 4, skills = { 269 } });
    local named = 'entity.onMobSkillTarget = function(target, mob, skill)\n'
        .. '    if skill:getID() == xi.mobSkill.GREAT_WHIRLWIND_1 then\n'
        .. '        mob:resetEnmity(target)\n'
        .. '    end\nend';
    t.eq(mobskills.mobScript(named, { GREAT_WHIRLWIND_1 = 803 }), { line = 3, skills = { 803 } });
    t.eq(mobskills.skillEnum('xi.mobSkill =\n{\n    KARTSTRAHL                    =  534,\n    GREAT_WHIRLWIND_1             =  803,\n}'),
        { KARTSTRAHL = 534, GREAT_WHIRLWIND_1 = 803 });
    t.eq(mobskills.mobScript('    mob:lowerEnmity(target, 50)\n    -- mob:resetEnmity(x)'), { line = 1, skills = {} });
    t.eq(mobskills.mobScript('    mob:addEnmity(target, 1, 1)'), nil);
end);

t.test('a skill a mob script resets on is no longer a confident none', function ()
    local built = mobskills.build({ { 269, 1, 'petribreath' }, { 270, 1, 'other' } },
        { petribreath = skill('    return 0'), other = skill('    return 0') });
    mobskills.applyMobScripts(built, { { mob = 'Lufaise_Meadows/Flockbock', line = 24, skills = { 269 } } });
    t.eq(built.skills[269], {
        id = 269, name = 'petribreath', effect = 'none', trust = 'unknown',
        call = 'Lufaise_Meadows/Flockbock.lua:24 resets on it',
    });
    t.eq(built.skills[270].trust, 'lsb');
end);

local ZONE_YAML = [[
templates:

  Wild_Rabbit:
    id: 1
    attributes:
      stats:
        level: [99, 99]

spawns:
  17186822:
    template: Wild_Rabbit
    level:    [1, 1]
  17186823:
    template: Wild_Rabbit
    level:    [1, 1]
  17186824:
    template: Wild_Rabbit
    level: [1, 2]
  17186825:
    script: Wayward_Worm
  17186826:
    template: Wild_Rabbit
    level:    [1, 2]
    attributes:
      spawn:
        window:
          start: 20
slots:
  - members:
      17186822: {}
]];

t.test('zone spawns yield server id and level range, counting scripted placeholders', function ()
    local spawns, invalid, levelless = moblevels.spawns(ZONE_YAML);
    t.eq(invalid, {});
    t.eq(levelless, 1);
    t.eq(spawns, {
        { id = 17186822, min = 1, max = 1 },
        { id = 17186823, min = 1, max = 1 },
        { id = 17186824, min = 1, max = 2 },
        { id = 17186826, min = 1, max = 2 },
    });
end);

t.test('a spawn whose level range is inverted or zero is rejected, not vendored', function ()
    local spawns, invalid = moblevels.spawns('spawns:\n  17952867:\n    level:  [119, 0]\n  17952868:\n    level: [0, 3]\n  17952869:\n    level: [5, 6]\n');
    t.eq(spawns, { { id = 17952869, min = 5, max = 6 } });
    t.eq(invalid, { { id = 17952867, min = 119, max = 0 }, { id = 17952868, min = 0, max = 3 } });
end);

t.test('spawns collapse into runs of consecutive indices sharing a range, per zone', function ()
    local runs = moblevels.runs({
        { id = 17186822, min = 1, max = 1 },
        { id = 17186823, min = 1, max = 1 },
        { id = 17186824, min = 1, max = 2 },
        { id = 17186826, min = 1, max = 2 },
        { id = 0x01065001, min = 30, max = 32 },
    });
    t.eq(runs, {
        [100] = { { 6, 7, 1, 1 }, { 8, 8, 1, 2 }, { 10, 10, 1, 2 } },
        [101] = { { 1, 1, 30, 32 } },
    });
end);

-- Abilities: id, name, 14 unused columns, CE, VE.  Spells: id, name, 17, CE, VE.
local function ability(id, name, ce, ve)
    return { id, name, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ce, ve, 0, 0, sql.NULL };
end
local function spell(id, name, ce, ve)
    return { id, name, '0x00', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.0, ce, ve, 0, 0, 0, sql.NULL };
end

local function buildActions(overrides)
    local input = {
        abilities = {
            ability(35, 'provoke', 1, 1800),
            ability(92, 'rampart', 320, 320),
            ability(48, 'sentinel', 1, 900),
            ability(64, 'mystery', 0, 0),
            ability(18, 'benediction', 0, 0),
            ability(611, 'sleepga', 1, 60),
        },
        spells = {
            spell(1, 'cure', 0, 0),
            spell(5, 'cure_v', 0, 0),
            spell(112, 'flash', 180, 1280),
            spell(345, 'hojo_ni', 20, 100),
            spell(400, 'goddesss_hymnus', 0, 0),
            spell(273, 'sleepga', 180, 0),
            spell(645, 'exuviation', 640, 640),
        },
        cures = {
            spells = {
                cure = { formula = true },
                cure_v = { ce = 300, ve = 600 },
                exuviation = { formula = true },
            },
            abilities = { benediction = { formula = true } },
        },
        fixedByEra = { 'Cure V', 'Exuviation' },
        era = {
            rows = {
                { name = 'Provoke', ce = 1, ve = 1800, section = 'Single Target' },
                { name = 'Sentinel', ce = 1, section = 'Single Target' },
                { name = 'Cure V', ce = 400, ve = 600, section = 'Single Target' },
                { name = 'Hojo: Ni', ce = 80, ve = 240, section = 'Single Target' },
                { name = 'Rampart', ce = 1, ve = 300, section = 'Multiple Targets' },
                { name = "Goddess's Hynmus", ce = 20, ve = 80, section = 'Multiple Targets' },
                { name = 'Nonexistent Spell', ce = 1, ve = 1, section = 'Single Target' },
                { name = 'Sleepga', ce = 180, section = 'Single Target' },
                { name = 'Exuviation', ce = 640, ve = 640, section = 'Single Target' },
                { name = 'First Action (Pull)', ce = 200, ve = 900, section = 'Misc. Actions' },
                { name = 'Utsu Shadow Loss', ce = -25, ve = 0, section = 'Misc. Actions' },
            },
            malformed = { 'Jettatura' },
        },
        aliases = { ["Goddess's Hynmus"] = 'goddesss_hymnus' },
        deltas = {
            { kind = 'spells', name = 'hojo_ni', ce = 40, ve = 450, source = 'Hojo:Ni' },
        },
    };
    for k, v in pairs(overrides or {}) do
        input[k] = v;
    end
    return actions.build(input);
end

t.test('an action on the era table takes its values at era trust', function ()
    local built = buildActions();
    local e = built.abilities[35];
    t.eq({ e.name, e.ce, e.ve, e.ceTrust, e.veTrust }, { 'provoke', 1, 1800, 'era', 'era' });
    t.eq(e.lsb, { ce = 1, ve = 1800 });
    t.eq({ e.lsbCe, e.lsbVe }, { nil, nil }, 'agreeing values are not repeated');
end);

t.test('a value the era table leaves blank falls back to LSB at lsb trust', function ()
    local e = buildActions().abilities[48];
    t.eq({ e.ce, e.ve, e.ceTrust, e.veTrust }, { 1, 900, 'era', 'lsb' });
end);

t.test('an action only LSB knows is lsb trust, or unknown when both columns are the 0 default', function ()
    local built = buildActions();
    local flash, mystery = built.spells[112], built.abilities[64];
    t.eq({ flash.ce, flash.ve, flash.ceTrust, flash.veTrust }, { 180, 1280, 'lsb', 'lsb' });
    t.eq({ mystery.ce, mystery.ve, mystery.ceTrust, mystery.veTrust }, { 0, 0, 'unknown', 'unknown' });
end);

t.test('formula cures are marked and their 0/0 columns are genuine, not unknown', function ()
    local e = buildActions().spells[1];
    t.eq({ e.cure, e.ce, e.ve, e.ceTrust, e.veTrust }, { 'formula', 0, 0, 'lsb', 'lsb' });
end);

t.test('fixed cures carry the fixed values, which the era table can then correct', function ()
    local e = buildActions().spells[5];
    t.eq({ e.cure, e.ce, e.ve, e.ceTrust, e.veTrust }, { 'fixed', 400, 600, 'era', 'era' });
    t.eq(e.lsb, { ce = 300, ve = 600 });
    t.eq({ e.lsbCe, e.lsbVe }, { 300, 600 }, 'a disagreement keeps LandSandBoat\'s values as data');
end);

t.test('multiple-target rows are per target hit', function ()
    local built = buildActions();
    t.eq(built.abilities[92].perTarget, true);
    t.eq(built.abilities[35].perTarget, nil);
end);

t.test('aliases bridge wiki spellings that normalising cannot', function ()
    local e = buildActions().spells[400];
    t.eq({ e.ce, e.ve, e.ceTrust }, { 20, 80, 'era' });
end);

t.test('an era name shared by a spell and a pet ability means the spell', function ()
    local built = buildActions();
    t.eq(built.spells[273].ceTrust, 'era');
    t.eq(built.abilities[611].era, nil);
    t.eq(built.abilities[611].ceTrust, 'lsb');
    t.eq(built.ambiguous, {});
end);

t.test('a Horizon delta overrides whatever came before and remembers it', function ()
    local e = buildActions().spells[345];
    t.eq({ e.ce, e.ve, e.ceTrust, e.veTrust }, { 40, 450, 'era', 'era' });
    t.eq(e.era, { ce = 80, ve = 240 });
    t.eq(e.delta.source, 'Hojo:Ni');
end);

t.test('abilities that heal through a job helper are cures too', function ()
    local e = buildActions().abilities[18];
    t.eq({ e.cure, e.ceTrust }, { 'formula', 'lsb' });
end);

t.test('a cure the era table says ignores HP healed is fixed, whatever LSB does', function ()
    local e = buildActions().spells[645];
    t.eq({ e.cure, e.ce, e.ve, e.ceTrust }, { 'fixed', 640, 640, 'era' });
end);

t.test('a curated rule finds exactly one action by name, or fails', function ()
    local built = buildActions();
    t.eq(actions.lookup(built, 'abilities', 'Provoke'), 35);
    t.eq(actions.lookup(built, 'spells', 'hojo_ni'), 345);
    t.eq(pcall(actions.lookup, built, 'spells', 'nothing'), false);
    t.eq(pcall(actions.lookup, built, 'kinds', 'provoke'), false);
end);

t.test('a delta naming no action is an error, not a silent no-op', function ()
    local ok, err = pcall(buildActions, {
        deltas = { { kind = 'spells', name = 'hojo_san', ce = 1, ve = 1, source = 'x' } },
    });
    t.eq(ok, false);
    t.truthy(tostring(err):find('hojo_san', 1, true), 'error names the delta');
end);

t.test('misc era rows become named constants; unmatched and malformed rows are listed', function ()
    local built = buildActions();
    t.eq(built.misc.firstEngage, { ce = 200, ve = 900, trust = 'era', wiki = 'First Action (Pull)' });
    t.eq(built.misc.shadowAbsorb, { ce = -25, ve = 0, trust = 'era', wiki = 'Utsu Shadow Loss' });
    t.eq(built.unmatched, { 'Nonexistent Spell' });
    t.eq(built.malformed, { 'Jettatura' });
end);

t.test('job helper functions that generate cure enmity are found by name', function ()
    local helpers = table.concat({
        'xi.job_utils.dancer.checkWaltzAbility = function(player, target, ability)',
        '    return 0',
        'end',
        '',
        'xi.job_utils.dancer.useWaltzAbility = function(player, target, ability, action)',
        '    target:restoreHP(amtCured)',
        '    player:updateEnmityFromCure(target, amtCured)',
        'end',
        '',
        'local function helper()',
        '    -- player:updateEnmityFromCure(target, 1)',
        'end',
    }, '\n');
    t.eq(actions.cureFunctions(helpers), { 'xi.job_utils.dancer.useWaltzAbility' });
    t.eq(actions.cure('    return xi.job_utils.dancer.useWaltzAbility(player, target, ability, action)',
        { 'xi.job_utils.dancer.useWaltzAbility' }), { formula = true });
    t.eq(actions.cure('    return xi.job_utils.dancer.checkWaltzAbility(player, target, ability)',
        { 'xi.job_utils.dancer.useWaltzAbility' }), nil);
end);

t.test('a weaponskill script with both overrides has fixed enmity; anything less generates it from damage', function ()
    t.eq(actions.weaponskillOverride('    params.overrideCE = 80\n    params.overrideVE = 240\n'), { ce = 80, ve = 240 });
    t.eq(actions.weaponskillOverride('    params.overrideCE = 80\n'), nil);
    t.eq(actions.weaponskillOverride('    -- params.overrideCE = 80\n    -- params.overrideVE = 240\n'), nil, 'commented out');
    t.eq(actions.weaponskillOverride('    params.enmityMult = 1\n'), nil);
    local built = actions.build({
        abilities = {}, spells = {}, cures = {}, era = { rows = {}, malformed = {} },
        weaponskills = { { 216, 'coronach' }, { 1, 'combo' } }, overrides = { coronach = { ce = 80, ve = 240 } },
    });
    t.eq(built.weaponskills[216], {
        id = 216, name = 'coronach', ce = 80, ve = 240, ceTrust = 'lsb', veTrust = 'lsb', lsb = { ce = 80, ve = 240 },
    });
    t.eq(built.weaponskills[1], nil);
end);

t.test('a spell script is a cure by the enmity call it makes', function ()
    t.eq(actions.cure('    caster:updateEnmityFromCure(target, final)'), { formula = true });
    t.eq(actions.cure('    caster:updateEnmityFromCure(target, final, 300, 600)'), { ce = 300, ve = 600 });
    t.eq(actions.cure('    return xi.spells.blue.useCuringSpell(caster, target, spell, params)'), { formula = true });
    t.eq(actions.cure('    -- caster:updateEnmityFromCure(target, final)\n    return 0'), nil);
    t.eq(actions.cure('    target:addHP(final)'), nil);
end);

t.test('emitted strings are single-quoted Lua that reads back identically', function ()
    local s = "it's a \\ back\nslash";
    t.eq(emit.string(s), [['it\'s a \\ back\nslash']]);
    t.eq(loadstring('return ' .. emit.string(s))(), s);
end);

t.test('emitted tables keep the given key order, drop nils, and write integers plainly', function ()
    local line = emit.inline({ ve = 1800, name = 'provoke', ce = 1, extra = nil, flag = true, f = 0.5 },
        { 'name', 'ce', 've', 'extra', 'flag', 'f' });
    t.eq(line, "{ name = 'provoke', ce = 1, ve = 1800, flag = true, f = 0.5 }");
    t.eq(emit.inline({ 6, 7, 1, 1 }), '{ 6, 7, 1, 1 }');
end);

t.test('an emitted header is a doc comment in the house style', function ()
    t.eq(emit.header({ 'GENERATED', '', 'Sources' }), '--[[\n* GENERATED\n*\n* Sources\n--]]\n');
end);

local PAGES = {
    ['Category:Horizon Changes'] = {
        text = '<section begin=Provoke/>* [[Provoke]] now receives an additional 250 [[Enmity|cumulative\n enmity (CE)]].<section end=Provoke/>'
            .. '\n* Something else entirely.',
    },
    Sattva = { text = '{{HorizonChangesBox|{{stat|Enmity|+5}} instead of {{stat|Enmity|+3}}|}}' },
};
local LSB_FILES = { ['src/x.cpp'] = '    {\n        ce = 160;\n        ve = 480;\n    }' };

t.test('a quote is found in plain text, raw wikitext or LSB source, whitespace aside', function ()
    cite.verify({ sources = {
        { wiki = 'Category:Horizon Changes', section = 'Provoke', quotes = { 'Provoke now receives an additional 250 cumulative enmity (CE).' } },
        { wiki = 'Sattva', quotes = { '{{stat|Enmity|+5}} instead of' } },
        { lsb = 'src/x.cpp', quotes = { 'ce = 160; ve = 480;' } },
    } }, PAGES, LSB_FILES);
end);

t.test('a quote outside its section, or absent, fails with the quote named', function ()
    local ok, err = pcall(cite.verify, { key = 'k', sources = {
        { wiki = 'Category:Horizon Changes', section = 'Provoke', quotes = { 'Something else entirely.' } },
    } }, PAGES, LSB_FILES);
    t.eq(ok, false);
    t.truthy(tostring(err):find('Something else entirely.', 1, true), 'names the quote');

    ok = pcall(cite.verify, { sources = { { wiki = 'Category:Horizon Changes', section = 'Nope', quotes = { 'x' } } } }, PAGES, LSB_FILES);
    t.eq(ok, false);
    ok = pcall(cite.verify, { sources = {} }, PAGES, LSB_FILES);
    t.eq(ok, false, 'an entry must cite something');
end);

t.test('a citation reads as a URL with revision, or an LSB path at the commit', function ()
    local pages = { ['Category:Horizon Changes'] = { url = 'https://horizonffxi.wiki/Category:Horizon_Changes', revision = 42 } };
    t.eq(cite.describe({ wiki = 'Category:Horizon Changes', section = 'Provoke' }, pages),
        'https://horizonffxi.wiki/Category:Horizon_Changes r42, section Provoke');
    t.eq(cite.describe({ lsb = 'src/x.cpp' }, pages), 'LandSandBoat src/x.cpp');
end);

t.test('status effect ids are read from the YAML by name', function ()
    local yaml = 'status_effects:\n  defender:\n    id: 57\n    flags:\n      - no_cancel\n  sentinel:\n    id:   62\n';
    t.eq(overlays.statusIds(yaml), { defender = 57, sentinel = 62 });
end);

t.test('curated rules resolve names to ids, keep field order, and cite their sources', function ()
    local rules = {
        buffs = { {
            key = 'defender', status = 'defender', lossReduction = 25, duration = 180,
            sources = { { lsb = 'x.cpp', quotes = { 'ok' } } },
        } },
        conditional = { {
            key = 'provokeDefender', kind = 'abilities', names = { 'provoke' }, requires = 'defender', ceMain = 250,
            sources = { { lsb = 'x.cpp', quotes = { 'ok' } } },
        } },
        gear = { {
            item = 15544, name = 'sattva_ring', enmity = 5, trust = 'unknown',
            sources = { { lsb = 'x.cpp', quotes = { 'ok' } } },
        } },
    };
    local ctx = {
        pages = {}, files = { ['x.cpp'] = 'ok' },
        actions = buildActions(),
        statusIds = { defender = 57 },
        itemNames = { [15544] = 'sattva_ring' },
    };
    local resolved = overlays.resolve(rules, ctx);
    t.eq(emit.inline(resolved.buffs[1], overlays.fields('buffs')),
        "{ status = 57, lossReduction = 25, duration = 180, trust = 'era' }");
    t.eq(resolved.conditional[1].abilities, { 35 });
    t.eq(resolved.gear[1].trust, 'unknown');

    rules.gear[1].name = 'wrong_ring';
    local ok, err = pcall(overlays.resolve, rules, ctx);
    t.eq(ok, false);
    t.truthy(tostring(err):find('sattva_ring', 1, true), 'names the real item');
end);

t.test('every source a rule cites is listed once, sorted', function ()
    local rules = {
        buffs = { { sources = { { wiki = 'B', quotes = {} }, { lsb = 'z.cpp', quotes = {} } } } },
        gear = { { sources = { { wiki = 'A', quotes = {} }, { wiki = 'B', quotes = {} } } } },
    };
    local titles, paths = overlays.sources(rules);
    t.eq(titles, { 'A', 'B' });
    t.eq(paths, { 'z.cpp' });
end);

t.done();

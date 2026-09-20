--[[
* Reads HorizonXI wiki wikitext: the Enmity Table page, and the labelled
* sections that Horizon change notes live in.
--]]

local wiki = {};

local function trim(s)
    return s:match('^%s*(.-)%s*$');
end

--[[
* A CE or VE cell.  Blank and '#' mean the value was never verified, which is
* nil.  Returns false for anything else that isn't an integer.
--]]
local function cell(text)
    text = trim(text);
    if text == '' or text == '#' then
        return nil;
    end
    local n = text:match('^%-?%s*%d+$');
    if n == nil then
        return false;
    end
    return tonumber((n:gsub('%s', '')));
end

--[[
* Every {| ... |} table on the Enmity Table page, flattened to rows.
*
* A row is a name and exactly two value cells, each on its own line.  Rows
* with a stray inline '|' or a non-numeric value are reported as malformed.
* A name listed twice with different values is malformed too; listed twice
* identically it is kept once.
*
* @param {string} text - The page's wikitext.
* @return {table} { rows = { {name, ce, ve, section} }, malformed = { name } }
--]]
function wiki.enmityTable(text)
    local rows, malformed = {}, {};
    local byName, bad = {}, {};

    local function reject(name)
        if not bad[name] then
            bad[name] = true;
            malformed[#malformed + 1] = name;
        end
    end

    local function finish(section, cells)
        if #cells == 0 then
            return;
        end
        local name = trim(cells[1]);
        if #cells ~= 3 or cells[2]:find('|', 1, true) or cells[3]:find('|', 1, true) then
            reject(name);
            return;
        end
        local ce, ve = cell(cells[2]), cell(cells[3]);
        if ce == false or ve == false then
            reject(name);
            return;
        end
        local row = { name = name, ce = ce, ve = ve, section = section };
        local seen = byName[name];
        if seen == nil then
            byName[name] = row;
            rows[#rows + 1] = row;
        elseif seen.ce ~= ce or seen.ve ~= ve or seen.section ~= section then
            reject(name);
        end
    end

    local section, inTable, cells = nil, false, {};
    for line in (text .. '\n'):gmatch('(.-)\r?\n') do
        local heading = line:match('^==+%s*(.-)%s*==+%s*$');
        if heading ~= nil then
            section = heading;
        elseif line:match('^{|') then
            inTable, cells = true, {};
        elseif inTable and line:match('^|}') then
            finish(section, cells);
            inTable = false;
        elseif inTable and line:match('^|%-') then
            finish(section, cells);
            cells = {};
        elseif inTable and line:match('^|') then
            cells[#cells + 1] = line:sub(2);
        end
    end

    local kept = {};
    for _, row in ipairs(rows) do
        if not bad[row.name] then
            kept[#kept + 1] = row;
        end
    end
    return { rows = kept, malformed = malformed };
end

--[[
* The text between <section begin=NAME/> and <section end=NAME/>.
*
* @return {string|nil} Nil when the page has no such section.
--]]
function wiki.section(text, name)
    for _, q in ipairs({ '', '"' }) do
        local open = ('<section begin=%s%s%s/>'):format(q, name, q);
        local close = ('<section end=%s%s%s/>'):format(q, name, q);
        local from = text:find(open, 1, true);
        if from ~= nil then
            local to = text:find(close, from, true);
            if to ~= nil then
                return text:sub(from + #open, to - 1);
            end
        end
    end
    return nil;
end

--[[
* Wikitext as a reader sees it: links show their label, templates, section
* tags and bold/italic quotes vanish, and whitespace collapses to single
* spaces.  Item tooltips show the item name, as they do on the page.  Used to
* match a quoted sentence regardless of markup.
--]]
function wiki.plain(text)
    text = text:gsub('<section[^>]*/>', '');
    text = text:gsub('{{Item Tooltip|([^}|]*)}}', '%1');
    text = text:gsub('{{.-}}', '');
    text = text:gsub('%[%[[^%]|]*|([^%]]*)%]%]', '%1');
    text = text:gsub('%[%[([^%]]*)%]%]', '%1');
    text = text:gsub("'''?", '');
    text = text:gsub('%s+', ' ');
    return trim(text);
end

return wiki;

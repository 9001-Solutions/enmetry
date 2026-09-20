--[[
* Reads rows out of LandSandBoat's SQL dumps.
*
* Only what the dumps actually contain: one INSERT per line, optionally with
* several parenthesised rows, and a trailing -- comment.  Values come back as
* numbers or strings.  Anything unquoted that isn't a number (@VARIABLES, flag
* expressions, 0x literals) is kept as written.
--]]

local sql = {};

-- Stands in for NULL so rows stay proper sequences.
sql.NULL = setmetatable({}, { __tostring = function () return 'NULL'; end });

local function value(raw)
    raw = raw:match('^%s*(.-)%s*$');
    if raw == 'NULL' then
        return sql.NULL;
    end
    if raw:match('^%-?%d+%.?%d*$') then
        return tonumber(raw);
    end
    return raw;
end

--[[
* Parses the row tuples of one VALUES clause, starting at position i.
--]]
local function tuples(line, i, rows)
    local row, field, quoted, depth = nil, {}, false, 0;
    local n = #line;
    while i <= n do
        local c = line:sub(i, i);
        if row == nil then
            if c == '(' then
                row, field, quoted = {}, {}, false;
            elseif c == ';' or c == '-' then
                break;
            end
        elseif quoted then
            if c == '\\' then
                i = i + 1;
                field[#field + 1] = line:sub(i, i);
            elseif c == "'" and line:sub(i + 1, i + 1) == "'" then
                i = i + 1;
                field[#field + 1] = "'";
            elseif c == "'" then
                quoted = false;
            else
                field[#field + 1] = c;
            end
        elseif c == "'" then
            quoted = true;
            field.string = true;
        elseif c == '(' then
            depth = depth + 1;
            field[#field + 1] = c;
        elseif c == ')' and depth > 0 then
            depth = depth - 1;
            field[#field + 1] = c;
        elseif c == ',' or c == ')' then
            local text = table.concat(field);
            row[#row + 1] = field.string and text or value(text);
            field = {};
            if c == ')' then
                rows[#rows + 1] = row;
                row = nil;
            end
        else
            field[#field + 1] = c;
        end
        i = i + 1;
    end
end

--[[
* @param {string} text - A whole .sql file.
* @param {string} name - The table whose rows to return.
* @return {table} Rows in file order, each a sequence of column values.
--]]
function sql.rows(text, name)
    local prefix = 'INSERT INTO `' .. name .. '` VALUES';
    local rows = {};
    for line in text:gmatch('[^\n]+') do
        if line:sub(1, #prefix) == prefix then
            tuples(line, #prefix + 1, rows);
        end
    end
    return rows;
end

return sql;

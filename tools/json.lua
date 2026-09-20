--[[
* A JSON reader for the addon's JSON Lines logs, which log.lua writes: one
* value a line, objects with string keys, arrays, strings, numbers, booleans
* and null.  null becomes nil, so a key holding null is absent.
--]]

local json = {};

local ESCAPES = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' };

local function fail(i, what)
    error(('json: %s at byte %d'):format(what, i), 0);
end

-- A code point as UTF-8.
local function utf8(cp)
    if cp < 0x80 then
        return string.char(cp);
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40);
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40);
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40);
end

local function skip(s, i)
    return s:find('%S', i) or #s + 1;
end

local decodeValue;

-- i is at the opening quote.
local function decodeString(s, i)
    local out, j = {}, i + 1;
    while true do
        local c = s:sub(j, j);
        if c == '' then
            fail(i, 'unterminated string');
        elseif c == '"' then
            return table.concat(out), j + 1;
        elseif c == '\\' then
            local e = s:sub(j + 1, j + 1);
            if e == 'u' then
                local cp = tonumber(s:sub(j + 2, j + 5), 16);
                if cp == nil or #s:sub(j + 2, j + 5) < 4 then
                    fail(j, 'bad \\u escape');
                end
                j = j + 6;
                if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == '\\u' then
                    local lo = tonumber(s:sub(j + 2, j + 5), 16);
                    if lo ~= nil and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00);
                        j = j + 6;
                    end
                end
                out[#out + 1] = utf8(cp);
            else
                local plain = ESCAPES[e];
                if plain == nil then
                    fail(j, 'bad escape');
                end
                out[#out + 1] = plain;
                j = j + 2;
            end
        else
            local k = s:find('["\\]', j);
            if k == nil then
                fail(i, 'unterminated string');
            end
            out[#out + 1] = s:sub(j, k - 1);
            j = k;
        end
    end
end

local function decodeArray(s, i)
    local out, n = {}, 0;
    i = skip(s, i + 1);
    if s:sub(i, i) == ']' then
        return out, i + 1;
    end
    while true do
        local v;
        v, i = decodeValue(s, i);
        n = n + 1;
        out[n] = v;
        i = skip(s, i);
        local c = s:sub(i, i);
        if c == ']' then
            return out, i + 1;
        elseif c ~= ',' then
            fail(i, 'expected , or ]');
        end
        i = skip(s, i + 1);
    end
end

local function decodeObject(s, i)
    local out = {};
    i = skip(s, i + 1);
    if s:sub(i, i) == '}' then
        return out, i + 1;
    end
    while true do
        if s:sub(i, i) ~= '"' then
            fail(i, 'expected a key');
        end
        local key, v;
        key, i = decodeString(s, i);
        i = skip(s, i);
        if s:sub(i, i) ~= ':' then
            fail(i, 'expected :');
        end
        v, i = decodeValue(s, skip(s, i + 1));
        out[key] = v;
        i = skip(s, i);
        local c = s:sub(i, i);
        if c == '}' then
            return out, i + 1;
        elseif c ~= ',' then
            fail(i, 'expected , or }');
        end
        i = skip(s, i + 1);
    end
end

local LITERALS = { ['true'] = true, ['false'] = false, ['null'] = 'null' };

function decodeValue(s, i)
    i = skip(s, i);
    local c = s:sub(i, i);
    if c == '{' then
        return decodeObject(s, i);
    elseif c == '[' then
        return decodeArray(s, i);
    elseif c == '"' then
        return decodeString(s, i);
    elseif c == '-' or c:match('%d') then
        local text = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i);
        local n = tonumber(text);
        if n == nil then
            fail(i, 'bad number');
        end
        return n, i + #text;
    end
    for word, value in pairs(LITERALS) do
        if s:sub(i, i + #word - 1) == word then
            if value == 'null' then
                value = nil;
            end
            return value, i + #word;
        end
    end
    fail(i, 'unexpected ' .. (c == '' and 'end' or c));
end

--[[
* @param {string} s - One JSON value, with any whitespace around it.
* @return {any} The value; an object as a table keyed by string, an array
*   as one keyed 1..n.  Raises on anything malformed.
--]]
function json.decode(s)
    local v, i = decodeValue(s, 1);
    if skip(s, i) <= #s then
        fail(i, 'trailing text');
    end
    return v;
end

return json;

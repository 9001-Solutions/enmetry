--[[
* Writes Lua source for the generated tables.  Output must be byte-stable
* across runs, so every key order is explicit: nothing is emitted by walking
* a hash table with pairs().
--]]

local emit = {};
local scalar;

function emit.string(s)
    return "'" .. s:gsub('[\\\'\n]', { ['\\'] = '\\\\', ["'"] = "\\'", ['\n'] = '\\n' }) .. "'";
end

function scalar(v)
    local kind = type(v);
    if kind == 'string' then
        return emit.string(v);
    elseif kind == 'number' then
        if v == math.floor(v) then
            return ('%d'):format(v);
        end
        return ('%.17g'):format(v);
    elseif kind == 'boolean' then
        return tostring(v);
    elseif kind == 'table' then
        return emit.inline(v);
    end
    error('cannot emit a ' .. kind, 2);
end

--[[
* One table on one line.
*
* @param {table} t - The table.
* @param {table|nil} order - Keys to write, in order; nil keys are skipped.
*   Without it, t is written as a sequence.
--]]
function emit.inline(t, order)
    local parts = {};
    if order == nil then
        for i, v in ipairs(t) do
            parts[i] = scalar(v);
        end
    else
        for _, k in ipairs(order) do
            if t[k] ~= nil then
                parts[#parts + 1] = k .. ' = ' .. scalar(t[k]);
            end
        end
    end
    if #parts == 0 then
        return '{}';
    end
    return '{ ' .. table.concat(parts, ', ') .. ' }';
end

--[[
* A --[[ block in the repo's doc-comment style, one '*' line per entry.
--]]
function emit.header(lines)
    local out = { '--[[' };
    for _, line in ipairs(lines) do
        out[#out + 1] = line == '' and '*' or ('* ' .. line);
    end
    out[#out + 1] = '--]]';
    return table.concat(out, '\n') .. '\n';
end

return emit;

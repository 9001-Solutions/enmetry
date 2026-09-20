local store = {};

local function finite(v)
    return v == v and v ~= math.huge and v ~= -math.huge;
end

function store.read(path)
    local fh = io.open(path, 'rb');
    if fh == nil then
        return nil;
    end
    local text = fh:read('*a');
    fh:close();

    local chunk = loadstring(text, '=' .. path);
    if chunk == nil then
        return nil;
    end
    setfenv(chunk, {});
    local ok, loaded = pcall(chunk);
    if not ok or type(loaded) ~= 'table' then
        return nil;
    end
    return loaded;
end

function store.load(path, defaults)
    local out = {};
    for k, v in pairs(defaults) do
        out[k] = v;
    end

    local loaded = store.read(path);
    if loaded == nil then
        return out;
    end

    for k, v in pairs(defaults) do
        local candidate = loaded[k];
        if type(candidate) == type(v) and (type(v) ~= 'number' or finite(candidate)) then
            out[k] = candidate;
        end
    end
    return out;
end

local function keyOrder(a, b)
    local ta, tb = type(a), type(b);
    if ta ~= tb then
        return ta < tb;
    end
    if ta == 'boolean' then
        return not a and b;
    end
    return a < b;
end

local function shortest(v)
    local text = ('%.15g'):format(v);
    if tonumber(text) ~= v then
        text = ('%.16g'):format(v);
        if tonumber(text) ~= v then
            text = ('%.17g'):format(v);
        end
    end
    return text;
end

local serialize;

function serialize(value, indent)
    local kind = type(value);
    if kind == 'number' then
        return finite(value) and shortest(value) or nil;
    elseif kind == 'string' then
        return ('%q'):format(value);
    elseif kind == 'boolean' then
        return tostring(value);
    elseif kind ~= 'table' then
        return nil;
    end
    local keys = {};
    for k in pairs(value) do
        local tk = type(k);
        if tk == 'string' or tk == 'boolean' or (tk == 'number' and finite(k)) then
            keys[#keys + 1] = k;
        end
    end
    table.sort(keys, keyOrder);
    local inner = indent .. '    ';
    local lines = { '{' };
    for _, k in ipairs(keys) do
        local text = serialize(value[k], inner);
        if text ~= nil then
            local key;
            if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
                key = k;
            elseif type(k) == 'string' then
                key = ('[%q]'):format(k);
            else
                key = ('[%s]'):format(serialize(k, inner));
            end
            lines[#lines + 1] = ('%s%s = %s,'):format(inner, key, text);
        end
    end
    if #lines == 1 then
        return '{}';
    end
    lines[#lines + 1] = indent .. '}';
    return table.concat(lines, '\n');
end

function store.serialize(value)
    return serialize(value, '');
end

function store.write(path, value)
    local fh = io.open(path, 'wb');
    if fh == nil then
        return false;
    end
    fh:write('return ', store.serialize(value), '\n');
    fh:close();
    return true;
end

return store;

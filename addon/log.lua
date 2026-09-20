local log = {};
log.__index = log;

-- Bump when a line kind changes shape.
log.VERSION = 1;

local LIMIT = 200;

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\\128-\255]', function (c)
        if c == '"' then
            return '\\"';
        elseif c == '\\' then
            return '\\\\';
        elseif c == '\n' then
            return '\\n';
        elseif c == '\r' then
            return '\\r';
        elseif c == '\t' then
            return '\\t';
        end
        return ('\\u%04x'):format(c:byte());
    end) .. '"';
end

local function encodeNumber(n)
    if n ~= n or n == math.huge or n == -math.huge then
        return 'null';
    elseif n == math.floor(n) and math.abs(n) < 1e15 then
        return ('%d'):format(n);
    end
    return ('%.10g'):format(n);
end

local function isArray(v)
    local n = #v;
    local count = 0;
    for _ in pairs(v) do
        count = count + 1;
    end
    return count == n;
end

local encode;

local function encodeTable(v)
    if isArray(v) then
        local parts = {};
        for i = 1, #v do
            parts[i] = encode(v[i]);
        end
        return '[' .. table.concat(parts, ',') .. ']';
    end
    local keys = {};
    for k in pairs(v) do
        keys[#keys + 1] = tostring(k);
    end
    table.sort(keys);
    local parts = {};
    for i, k in ipairs(keys) do
        local value = v[k];
        if value == nil then
            value = v[tonumber(k)];
        end
        parts[i] = encodeString(k) .. ':' .. encode(value);
    end
    return '{' .. table.concat(parts, ',') .. '}';
end

function encode(v)
    local kind = type(v);
    if kind == 'number' then
        return encodeNumber(v);
    elseif kind == 'string' then
        return encodeString(v);
    elseif kind == 'boolean' then
        return v and 'true' or 'false';
    elseif kind == 'table' then
        return encodeTable(v);
    end
    return 'null';
end
log.encode = encode;

function log.new(opts)
    return setmetatable({
        sink = opts.sink,
        clock = opts.clock or os.clock,
        limit = opts.limit or LIMIT,
        pending = {},
        lines = 0,
        cost = 0,
    }, log);
end

function log:charge(seconds)
    self.cost = self.cost + seconds;
end

function log:write(kind, fields)
    local head = ('{"t":%s,"k":%s'):format(encodeNumber(math.floor(self.clock() * 1000 + 0.5) / 1000), encodeString(kind));
    local body = fields and encodeTable(fields) or '[]';
    local line;
    if body == '[]' or body == '{}' then
        line = head .. '}';
    else
        line = head .. ',' .. body:sub(2);
    end
    self.pending[#self.pending + 1] = line;
    self.lines = self.lines + 1;
    if #self.pending >= self.limit then
        self:flush();
    end
end

function log:flush()
    local pending = self.pending;
    if #pending == 0 then
        return;
    end
    self.sink(table.concat(pending, '\n') .. '\n');
    self.pending = {};
end

return log;

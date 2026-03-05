-- ============================================================
-- parse_kv.lua
-- Parse key=value pairs from log line into individual fields
-- Handles: key=value, key="quoted value", key="json{...}"
-- ============================================================

function parse_kv(tag, timestamp, record)
    local kv_pairs = record["kv_pairs"]
    if kv_pairs == nil or kv_pairs == "" then
        return 0, timestamp, record
    end

    local new_record = {}

    -- Copy existing fields (timestamp, level, component)
    for k, v in pairs(record) do
        if k ~= "kv_pairs" then
            new_record[k] = v
        end
    end

    -- Parse key=value pairs
    local i = 1
    local len = string.len(kv_pairs)

    while i <= len do
        -- Skip whitespace
        while i <= len and string.sub(kv_pairs, i, i) == " " do
            i = i + 1
        end
        if i > len then break end

        -- Read key (until '=')
        local key_start = i
        while i <= len and string.sub(kv_pairs, i, i) ~= "=" do
            i = i + 1
        end
        if i > len then break end

        local key = string.sub(kv_pairs, key_start, i - 1)
        i = i + 1 -- skip '='

        if i > len then break end

        local value
        if string.sub(kv_pairs, i, i) == '"' then
            -- Quoted value: find matching closing quote
            i = i + 1 -- skip opening quote
            local val_start = i
            local depth = 0
            while i <= len do
                local ch = string.sub(kv_pairs, i, i)
                if ch == "\\" then
                    i = i + 2 -- skip escaped character
                elseif ch == "{" then
                    depth = depth + 1
                    i = i + 1
                elseif ch == "}" then
                    depth = depth - 1
                    i = i + 1
                elseif ch == '"' and depth == 0 then
                    break
                else
                    i = i + 1
                end
            end
            value = string.sub(kv_pairs, val_start, i - 1)
            i = i + 1 -- skip closing quote
        else
            -- Unquoted value: read until space
            local val_start = i
            while i <= len and string.sub(kv_pairs, i, i) ~= " " do
                i = i + 1
            end
            value = string.sub(kv_pairs, val_start, i - 1)
        end

        -- Convert numeric values
        if value ~= nil and value ~= "" then
            local num = tonumber(value)
            if num ~= nil then
                new_record[key] = num
            elseif value == "true" then
                new_record[key] = true
            elseif value == "false" then
                new_record[key] = false
            else
                new_record[key] = value
            end
        end
    end

    return 1, timestamp, new_record
end

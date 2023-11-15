local destr = table.unpack or unpack

local M = {}

function M.updateTable(dst, src)
    for k, v in pairs(src) do dst[k] = v end
    return dst
end

function M.fixedRange(sl, sc, el, ec)
    if ec == 0 then
        el = el - 1
        ec = math.huge
    else
        ec = ec - 1
    end
    return sl, sc, el, ec
end

function M.isRangeIntersects(r1, r2)
    return  (r1[1] < r2[3] or (r1[1] == r2[3] and r1[2] <= r2[4]))
        and (r1[3] > r2[1] or (r1[3] == r2[1] and r1[4] >= r2[2]))
end

function M.isRangeInside(inner, outer)
    return  (inner[1] > outer[1] or (inner[1] == outer[1] and inner[2] >= outer[2]))
        and (inner[3] < outer[3] or (inner[3] == outer[3] and inner[4] <= outer[4]))
end

function M.addRange(dst, src)
    if dst[1] > src[1] then
        dst[1] = src[1]
        dst[2] = src[2]
    elseif dst[1] == src[1] then
        dst[2] = math.min(dst[2], src[2])
    end

    if dst[3] < src[3] then
        dst[3] = src[3]
        dst[4] = src[4]
    elseif dst[3] == src[3] then
        dst[4] = math.max(dst[4], src[4])
    end
end

function M.emptyRange()
    return { math.huge, math.huge, -math.huge, -math.huge }
end

function M.normalizeRange(range)
    for i=1,4 do
        local value = range[i]
        if value < 0 then value = 0
        elseif value > 2147483647 then value = 2147483647 end
        range[i] = value
    end

    return range
end

function M.countEmptyBelow(startLine, buf)
    if buf == nil then buf = 0 end
    local count = 0
    local last = vim.api.nvim_buf_line_count(buf)
    while true do
        local lineI = startLine + count + 1
        if lineI >= 0 and lineI < last
            and vim.api.nvim_buf_get_lines(buf, lineI, lineI + 1, true)[1]:gsub('%s', '') == '' then
            count = count + 1
        else
            return count
        end
    end
end

function M.countEmptyAbove(startLine, buf)
    if buf == nil then buf = 0 end
    local count = 0
    local last = vim.api.nvim_buf_line_count(buf)
    while true do
        local lineI = startLine - count - 1
        if lineI >= 0 and lineI < last
            and vim.api.nvim_buf_get_lines(buf, lineI, lineI + 1, true)[1]:gsub('%s', '') == '' then
            count = count + 1
        else
            return count
        end
    end
end

function M.filterInside(data)
    local res = {}
    if #data == 0 then return res end

    table.insert(res, data[1])
    local prevRange = data[1].range
    for i=2, #data do
        local curRange = data[i].range
        if not M.isRangeInside(curRange, prevRange) then
            table.insert(res, data[i])
            prevRange = curRange
        end
    end

    return res
end

function M.getRootNode(buf)
    local root = vim.treesitter.get_parser(buf)
    return root:parse()[1]:root() -- ????
end

return M

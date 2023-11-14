local vim = vim -- LSP :/

local function isRangeIntersects(r1, r2)
    return  (r1[1] < r2[3] or (r1[1] == r2[3] and r1[2] <= r2[4]))
        and (r1[3] > r2[1] or (r1[3] == r2[1] and r1[4] >= r2[2]))
end

local function isRangeInside(inner, outer)
    return  (inner[1] > outer[1] or (inner[1] == outer[1] and inner[2] >= outer[2]))
        and (inner[3] < outer[3] or (inner[3] == outer[3] and inner[4] <= outer[4]))
end

local function addRange(dst, src)
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

local function getRange(node)
    local sl, sc, el, ec = node:range()
    if ec == 0 then
        el = el - 1
        ec = math.huge
    else
        ec = ec - 1
    end
    return { sl + 1, sc, el + 1, ec }
end

--[[
    returns 0 if node is not selected
    returns 1 if node is selected
    returns 2 if node's parent should be added bc node itself is unnamed
]]
local function fillLeafNodesInRange(list, totalRange, node, range)
    local nodeRange = getRange(node)
    if not isRangeIntersects(nodeRange, range) then return 0 end

    local status = 0
    if node:child_count() == 0 then
        status = 2
    else
        for childNode in node:iter_children() do
            local childStatus = fillLeafNodesInRange(list, totalRange, childNode, range)
            if status == 0 then status = childStatus
            elseif status == 2 and childStatus == 1 then status = childStatus end
        end
    end

    if status == 2 then
        if not node:named() then return 2
        else
            list[node:id()] = node
            addRange(totalRange, nodeRange)
        end
    end
end

local function clear(t)
    for i, _ in pairs(t) do t[i] = nil end
end

local function updateTable(dst, src)
    for k, v in pairs(src) do
        dst[k] = v
    end
    return dst
end

local function tableLen(T) -- nice language
  local count = 0
  for _ in pairs(T) do count = count + 1 end
  return count
end

function selectParagraph(startLine, startCol, endLine, endCol)
    local root = vim.treesitter.get_parser()
    local tree = root:parse(true)[1]:root()

    local nodes = {}
    local nextNodes = {}
    local totalRange = { math.huge, math.huge, -math.huge, -math.huge }
    local reached = {}

    fillLeafNodesInRange(nodes, totalRange, tree, { startLine, startCol, endLine, endCol })

    while true do
        for _, node in pairs(nodes) do
            local parent = node:parent()

            local parentId
            local reachedData
            if parent ~= nil then
                parentId = parent:id()
                reachedData = reached[parentId]
                if reachedData == nil then
                    reachedData = { false, false }
                    reached[parentId] = reachedData
                end
            else
                reachedData = { false, false }
            end

            local curRange = updateTable({}, totalRange)
            if not reachedData[1] then
                local curNode = node
                while true do
                    local neighbourNode = curNode:prev_sibling()
                    if neighbourNode == nil then reachedData[1] = true; break end
                    local nNodeRange = getRange(neighbourNode)
                    if isRangeInside(nNodeRange, curRange) then break end
                    if nNodeRange[3] + 1 < curRange[1] then break end

                    if neighbourNode:named() then
                        addRange(totalRange, nNodeRange)
                        updateTable(curRange, totalRange)
                    else
                        addRange(curRange, nNodeRange)
                    end

                    curNode = neighbourNode
                end
            end

            if not reachedData[2] then
                local curNode = node
                while true do
                    local neighbourNode = curNode:next_sibling()
                    if neighbourNode == nil then reachedData[2] = true; break end
                    local nNodeRange = getRange(neighbourNode)
                    if isRangeInside(nNodeRange, curRange) then break end
                    if nNodeRange[1] - 1 > curRange[3] then break end

                    if neighbourNode:named() then
                        addRange(totalRange, nNodeRange)
                        updateTable(curRange, totalRange)
                    else
                        addRange(curRange, nNodeRange)
                    end

                    curNode = neighbourNode
                end
            end

            if parent ~= nil then nextNodes[parentId] = parent end
        end

        clear(nodes)

        for parentId, parentData in pairs(nextNodes) do
            local parentNode = parentData
            local reachedData = reached[parentId]
            local parentNodeRange = getRange(parentNode)

            if not parentNode:named() or (reachedData[1] and reachedData[2]) then
                nodes[parentId] = parentNode
                addRange(totalRange, parentNodeRange)
                print('!', vim.inspect(parentNode))
            else print('?', vim.inspect(parentNode), reachedData[1], reachedData[2]) end
        end
        print('v')

        if tableLen(nodes) == 0 then break end
        clear(nextNodes)
    end

    if totalRange[1] < totalRange[3] or (totalRange[1] == totalRange[3] and totalRange[2] <= totalRange[4]) then
        local function nor(value)
            if value < 0 then return 0
            elseif value > 2147483647 then return 2147483647
            else return value end
        end
        --[[totalRange[2] = 0
        totalRange[4] = 2147483647]]

        local pos = vim.fn.getpos('.')
        vim.api.nvim_buf_set_mark(0, '`', pos[2], pos[3], {})
        vim.api.nvim_win_set_cursor(0, { nor(totalRange[1]), nor(totalRange[2]) })
        vim.cmd('normal! v')
        if vim.opt.selection._value == 'exclusive' then totalRange[4] = totalRange[4] + 1; end
        vim.api.nvim_win_set_cursor(0, { nor(totalRange[3]), nor(totalRange[4]) })
    end
end

local function selectParagraphFromLine()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = cursor[1]
    selectParagraph(line, 0, line, math.huge)

end

function test()
    local b = 0
end

vim.keymap.set('n', '1', selectParagraphFromLine)

local function selectParagraphFromSelection()
    local startLine, startCol = vim.api.nvim_buf_get_mark(0, '<')
    local endLine, endCol = vim.api.nvim_buf_get_mark(0, '<')
    selectParagraph(startLine, startCol, endLine, endCol)
end

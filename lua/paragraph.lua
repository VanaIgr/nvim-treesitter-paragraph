local utils = require('utils')

--[[
    returns 0 if node is not selected
    returns 1 if node is selected
    returns 2 if node's parent should be added bc node itself is unnamed
]]
local function fillLeafNodesInRange(list, node, range, depth)
    local nodeRange = node:range()
    if not utils.isRangeIntersects(nodeRange, range) then return 0 end
    if depth == nil then depth = 0 end

    local hasChildren = false
    local status = 0
    for childNode in node:childrenIter() do
        hasChildren = true
        local childStatus = fillLeafNodesInRange(list, childNode, range, depth + 1)
        if status == 0 then status = childStatus
        elseif status == 2 and childStatus == 1 then status = childStatus end
    end

    if not hasChildren or status == 2 then
        if node:parentPart() then return 2
        else list[node:id()] = node end
    end
end

local function getPointInsertIndex(point, data)
    local b = 0
    local e = #data

    while b < e do
        local m = b + math.floor((e - b) / 2)
        local range = data[m + 1].range

        if point[1] == range[1] and point[2] == range[2] then
            b = m + 1
            break
        elseif point[1] > range[1] or (point[1] == range[1] and point[2] > range[2]) then
            b = m + 1
        else
            e = m
        end
    end

    return b + 1
end

local function canExpandParent(node, getSibling, diffLines)
    while true do
        node = node:parent()
        if node == nil then return true end
        local sibling = getSibling(node)
        if sibling ~= nil then return diffLines(sibling:range()) > 0 end
    end
end

--[[ returns reachedParent, isLastSelectable ]]
local function updateRange(curNode, getSibling, diffLines, expandRange, confirmRange)
    local reachedParent = curNode:parentPart()

    while true do
        local nbNode = getSibling(curNode)
        if nbNode == nil then
            local expand = canExpandParent(curNode, getSibling, diffLines)
            if not reachedParent and expand then confirmRange() end
            return true, true
        end
        curNode = nbNode

        local curNodeRange = curNode:range()
        local diff = diffLines(curNodeRange)

        if not reachedParent and diff > 0 then confirmRange() end
        if curNode:parentPart() then reachedParent = true end
        if diff > 1 then
            while not reachedParent do -- still return isLastSelectable = true if there are parent parts on the neighbour node line
                curNode = getSibling(curNode)
                if curNode == nil or diffLines(curNode:range(), curNodeRange) > 0 then break end
                reachedParent = curNode:parentPart()
            end
            return false, reachedParent
        end

        expandRange(curNodeRange)
    end
end

local function expandWholeLine(curNode, getSibling, diffLines, expandRange)
    while true do
        local nbNode = getSibling(curNode)
        if nbNode == nil then
            if canExpandParent(curNode, getSibling, diffLines) then return curNode end
            return nil
        end
        local nbNodeRange = nbNode:range()
        if diffLines(nbNodeRange) > 0 then return curNode end
        expandRange(nbNode)
        curNode = nbNode
        if nbNode:parentPart() then return nil end
    end
end

local function findParagraphBounds(root, inputRange)
    local initialNodes = {}
    fillLeafNodesInRange(initialNodes, root, inputRange)

    local initParents = {}
    for _, node in pairs(initialNodes) do
        local nodeRange = node:range()

        local parent = node:parent()
        if parent == nil then return { { range = nodeRange, ends = { true, true } } } end -- if root node is already selected
        local parentId = parent:id()

        local parentData = initParents[parentId]
        if parentData == nil then
            parentData = { range = nodeRange, items = { node, node } }
            initParents[parentId] = parentData
        else
            local nodesRange = parentData.range
            if nodeRange[1] < nodeRange[1] or (nodeRange[1] == nodesRange[1] and nodeRange[2] < nodesRange[2]) then
                parentData.items[1] = node
                nodesRange[1] = nodeRange[1]
                nodesRange[2] = nodeRange[2]
            end
            if nodeRange[3] > nodesRange[3] or (nodeRange[3] == nodesRange[3] and nodeRange[4] > nodesRange[4]) then
                parentData.items[2] = node
                nodesRange[3] = nodeRange[3]
                nodesRange[4] = nodeRange[4]
            end
        end
    end

    local parentsData = {}
    for _, parentData in pairs(initParents) do
        while true do
            local first = expandWholeLine(
                parentData.items[1],
                function(node) return node:prev() end,
                function(nodeRange) return parentData.items[1]:range()[1] - nodeRange[3] end,
                function(node) parentData.items[1] = node end
            )
            if first ~= nil then
                local last = expandWholeLine(
                    parentData.items[1],
                    function(node) return node:next() end,
                    function(nodeRange) return nodeRange[1] - parentData.items[2]:range()[3] end,
                    function(node) parentData.items[2] = node end
                )

                if last ~= nil then
                    local firstRange = first:range()
                    local lastRange  = last :range()
                    parentData.range = { firstRange[1], firstRange[2], lastRange[3], lastRange[4] }
                    parentData.items[1] = first
                    parentData.items[2] = last
                    break
                end
            end

            local parent = parentData.items[1]:parent()
            assert(parent ~= nil)
            parentData.items[1] = parent
            parentData.items[2] = parent
        end

        local index = getPointInsertIndex(parentData.range, parentsData)
        parentData.expRange = utils.updateTable({}, parentData.range) -- unconfirmed range
        table.insert(parentsData, index, parentData)
    end
    parentsData = utils.filterInside(parentsData)

    local totalRanges = {}
    while true do
        local nextParentData = {}

        for _, data in pairs(parentsData) do
            local range = data.range
            local expRange = data.expRange

            local expandBeforeParent, first = updateRange(
                data.items[1],
                function(node) return node:prev() end,
                function(nodeRange, otherRange) if otherRange == nil then otherRange = expRange end; return otherRange[1] - nodeRange[3] end,
                function(nodeRange) utils.addRange(expRange, nodeRange) end,
                function() range[1] = expRange[1]; range[2] = expRange[2] end
            )

            local expandAfterParent, last = updateRange(
                data.items[2],
                function(node) return node:next() end,
                function(nodeRange, otherRange) if otherRange == nil then otherRange = expRange end; return nodeRange[1] - otherRange[3] end,
                function(nodeRange) utils.addRange(expRange, nodeRange) end,
                function() range[3] = expRange[3]; range[4] = expRange[4] end
            )

            if data.items[1]:parent() ~= nil then
                print('!', expandBeforeParent, expandAfterParent, data.items[1]:parent()._node, vim.inspect(range), vim.inspect(expRange))
            end

            local parent = data.items[1]:parent()
            if expandBeforeParent and expandAfterParent and parent ~= nil then
                local index = getPointInsertIndex(range, nextParentData)
                table.insert(nextParentData, index, {
                    range = range, expRange = expRange,
                    items = { parent, parent },
                })
            else
                local index = getPointInsertIndex(range, totalRanges)
                table.insert(totalRanges, index, {
                    range = range, ends = { first, last },
                })
            end
        end

        if #nextParentData == 0 then break end
        parentsData = utils.filterInside(nextParentData)
    end

    return utils.filterInside(totalRanges)
end

local function getParagraphRange(rootNode, inputRange)
    local ranges = findParagraphBounds(rootNode, inputRange)

    local totalRange = utils.emptyRange()
    local ends = { false, false }
    for _, rangeData in pairs(ranges) do
        local range = rangeData.range
        if range[1] < totalRange[1] or (range[1] == totalRange[1] and range[2] <= totalRange[2]) then
            totalRange[1] = range[1]
            totalRange[2] = range[2]
            ends[1] = rangeData.ends[1]
        end
        if range[3] > totalRange[3] or (range[3] == totalRange[3] and range[4] >= totalRange[4]) then
            totalRange[3] = range[3]
            totalRange[4] = range[4]
            ends[2] = rangeData.ends[2]
        end
    end

    return totalRange, ends
end


local function getCursorRange()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = cursor[1] - 1
    return { line, 0, line, math.huge }
end

local m = require('mapping')

local languageProperties = function(lang)
    return {
        splitNodes = {
            ['if_statement'] = {
                ['else_clause'] = true,
                ['else_statement'] = true,
                ['elseif_statement'] = true
            }
        },
        textContent = {
            ['comment'] = {{ boundaryLinesParent = true }},
            ['string_fragment'] = {
                ['string'] = true
            },
            ['string_literal'] = {
                ['string_content'] = true,
            },
            ['template_string'] = {},
        },
    }
end

m.n('yip', function()
    local bufId = vim.api.nvim_get_current_buf()
    local parser = vim.treesitter.get_parser(bufId)

    local a = require('hierarchy.default')
    local root = a.createRoot(
        bufId,
        parser,
        languageProperties
    )

    local totalRange = getParagraphRange(root, getCursorRange())
    if totalRange[1] > totalRange[3] then return end

    totalRange[1] = totalRange[1] + 1
    totalRange[3] = totalRange[3] + 1

    local pos = vim.api.nvim_win_get_cursor(0)
    local register = vim.api.nvim_get_vvar('register')
    vim.cmd('keepjumps '..totalRange[1]..','..totalRange[3]..'yank '..register)
    vim.api.nvim_win_set_cursor(0, pos)
end)

m.n('dip', function()
    local bufId = vim.api.nvim_get_current_buf()
    local parser = vim.treesitter.get_parser(bufId)

    local a = require('hierarchy.default')
    local root = a.createRoot(
        bufId,
        parser,
        languageProperties
    )

    local totalRange, ends = getParagraphRange(root, getCursorRange())
    if totalRange[1] > totalRange[3] then return end

    local cursorPos = vim.api.nvim_win_get_cursor(0)

    local emptyAbove = utils.countEmptyAbove(totalRange[1])
    local emptyBelow = utils.countEmptyBelow(totalRange[3])
    local cursorEndPos = totalRange[3] + emptyBelow + 1

    print('#', ends[1], ends[2], emptyAbove, emptyBelow)

    if ends[1] or ends[2] then
        vim.api.nvim_buf_set_lines(0, totalRange[1] - emptyAbove, totalRange[1], true, {})
        totalRange[1] = totalRange[1] - emptyAbove
        totalRange[3] = totalRange[3] - emptyAbove
        cursorEndPos = cursorEndPos - emptyAbove
        vim.api.nvim_buf_set_lines(0, totalRange[3] + 1, totalRange[3] + emptyBelow + 1, true, {})
        cursorEndPos = cursorEndPos - emptyBelow
    else
        if emptyBelow > emptyAbove then
            vim.api.nvim_buf_set_lines(0, totalRange[1] - emptyAbove, totalRange[1], true, {})
            totalRange[1] = totalRange[1] - emptyAbove
            totalRange[3] = totalRange[3] - emptyAbove
            cursorEndPos = cursorEndPos - emptyAbove
        else
            vim.api.nvim_buf_set_lines(0, totalRange[3] + 1, totalRange[3] + emptyBelow + 1, true, {})
            cursorEndPos = cursorEndPos - emptyBelow
        end
    end

    local register = vim.api.nvim_get_vvar( 'register')
    vim.cmd('keepjumps '..(totalRange[1]+1)..','..(totalRange[3]+1)..'delete '..register)
    cursorEndPos = cursorEndPos - (totalRange[3] - totalRange[1] + 1)
    local last = vim.api.nvim_buf_line_count(0) - 1
    vim.api.nvim_win_set_cursor(0, { math.max(0, math.min(cursorEndPos, last)) + 1, cursorPos[2] })

end)

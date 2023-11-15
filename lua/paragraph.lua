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

local function getPointInsertIndex(insertPoint, data, getPoint)
    local b = 0
    local e = #data

    while b < e do
        local m = b + math.floor((e - b) / 2)
        local curPoint = getPoint(data[m + 1])

        if insertPoint[1] == curPoint[1] and insertPoint[2] == curPoint[2] then
            b = m + 1
            break
        elseif insertPoint[1] > curPoint[1] or (insertPoint[1] == curPoint[1] and insertPoint[2] > curPoint[2]) then
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
        if node == nil then return true, nil end
        local sibling = getSibling(node)
        if sibling ~= nil then return diffLines(sibling:range()) > 0, sibling end
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
            return true
        end
        curNode = nbNode

        local curNodeRange = curNode:range()
        local diff = diffLines(curNodeRange)

        if not reachedParent and diff > 0 then confirmRange() end
        if curNode:parentPart() then reachedParent = true end
        if diff > 1 then return false end

        expandRange(curNode)
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

local function getTwoNodesRange(items)
    local fr = items[1]:range()
    local lr = items[2]:range()
    return { fr[1], fr[2], lr[3], lr[4] }
end

local function findParagraphBounds(root, inputRange)
    local rootRange = root:range()
    local initialNodes = {}
    fillLeafNodesInRange(initialNodes, root, inputRange)

    local initParents = {}
    for _, node in pairs(initialNodes) do -- find all parents of nodes in range and keep 2 boundary nodes for each parent
        local nodeRange = node:range()

        local parent = node:parent()
        if parent == nil then return { {
            range = nodeRange,
            ends = {
                { emptyLines = nodeRange[1] - rootRange[1], reachedParent = true, smaler = true },
                { emptyLines = rootRange[3] - nodeRange[1], reachedParent = true, smaler = true },
            },
        } } end -- if root node is already selected
        local parentId = parent:id()

        local parentData = initParents[parentId]
        if parentData == nil then
            parentData = { startNodes = { node, node } }
            initParents[parentId] = parentData
        else

            local combinedRange = getTwoNodesRange(parentData.startNodes)
            if nodeRange[1] < nodeRange[1] or (nodeRange[1] == combinedRange[1] and nodeRange[2] < combinedRange[2]) then
                parentData.startNodes[1] = node
            end
            if nodeRange[3] > combinedRange[3] or (nodeRange[3] == combinedRange[3] and nodeRange[4] > combinedRange[4]) then
                parentData.startNodes[2] = node
            end

        end
    end

    local parentsData = {}
    for _, parentData in pairs(initParents) do -- convert parent map to array and add add necessary values
        while true do -- expand the selection for each parent to be complete
            local first = expandWholeLine(
                parentData.startNodes[1],
                function(node) return node:prev() end,
                function(nodeRange) return parentData.startNodes[1]:range()[1] - nodeRange[3] end,
                function(node) parentData.startNodes[1] = node end
            )
            if first ~= nil then
                local last = expandWholeLine(
                    parentData.startNodes[1],
                    function(node) return node:next() end,
                    function(nodeRange) return nodeRange[1] - parentData.startNodes[2]:range()[3] end,
                    function(node) parentData.startNodes[2] = node end
                )
                if last ~= nil then
                    parentData.startNodes[1] = first
                    parentData.startNodes[2] = last
                    break
                end
            end

            local parent = parentData.startNodes[1]:parent()
            assert(parent ~= nil)
            parentData.startNodes[1] = parent
            parentData.startNodes[2] = parent
        end

        local index = getPointInsertIndex(parentData.startNodes[1]:range(), parentsData, function(item) return item.startNodes[1]:range() end)
        parentData.expNodes = utils.updateTable({}, parentData.startNodes) -- unconfirmed items (on same line with nodes not tested)
        parentData.confirmedNodes = utils.updateTable({}, parentData.startNodes) -- nodes that define actual selection
        table.insert(parentsData, index, parentData)
    end
    parentsData = utils.filterInside(parentsData, function(it) return it.confirmedNodes[1]:range() end)

    local totalRanges = {}
    while true do -- expand all selections iteratively
        local nextParentData = {}

        for _, data in pairs(parentsData) do -- expand selection
            local confirmedNodes = data.confirmedNodes
            local newConfirmedNodes = { data.confirmedNodes[1], data.confirmedNodes[2] }
            local expNodes = data.expNodes

            local expandBeforeParent = updateRange(
                data.startNodes[1],
                function(node) return node:prev() end,
                function(nodeRange, otherRange) if otherRange == nil then otherRange = expNodes[1]:range() end; return otherRange[1] - nodeRange[3] end,
                function(node) expNodes[1] = node end,
                function() newConfirmedNodes[1] = expNodes[1] end
            )

            local expandAfterParent = updateRange(
                data.startNodes[2],
                function(node) return node:next() end,
                function(nodeRange, otherRange) if otherRange == nil then otherRange = expNodes[2]:range() end; return nodeRange[1] - otherRange[3] end,
                function(node) expNodes[2] = node end,
                function() newConfirmedNodes[2] = expNodes[2] end
            )

            local parent = data.startNodes[1]:parent()
            if expandBeforeParent and expandAfterParent and parent ~= nil then
                local index = getPointInsertIndex(newConfirmedNodes[1]:range(), nextParentData, function(item) return item.confirmedNodes[1]:range() end)
                table.insert(nextParentData, index, {
                    confirmedNodes = newConfirmedNodes, expNodes = expNodes,
                    startNodes = { parent, parent }
                })
            else
                local index = getPointInsertIndex(confirmedNodes[1]:range(), totalRanges, function(it) return it[1]:range() end)
                table.insert(totalRanges, index, confirmedNodes)
            end
        end

        if #nextParentData == 0 then break end
        parentsData = utils.filterInside(nextParentData, function(it) return it.confirmedNodes[1]:range() end)
    end

    if #totalRanges == 0 then return nil end

    -- merge ranges
    utils.filterInside(totalRanges, function(it) return it.range end)

    local totalRange = utils.emptyRange()
    local startData, endData
    for _, rangeData in pairs(totalRanges) do
        local range = getTwoNodesRange(rangeData)
        if range[1] < totalRange[1] or (range[1] == totalRange[1] and range[2] <= totalRange[2]) then
            totalRange[1] = range[1]
            totalRange[2] = range[2]
            startData = rangeData[1]
        end
        if range[3] > totalRange[3] or (range[3] == totalRange[3] and range[4] >= totalRange[4]) then
            totalRange[3] = range[3]
            totalRange[4] = range[4]
            endData = rangeData[2]
        end
    end

    -- calculate return value

    local startEmptyLines, startReachedParent
    local endEmptyLines  , endReachedParent

    local startNode = startData
    local startNodeRange = startNode:range()
    local prevNode = startNode:prev()
    if prevNode == nil then _, prevNode = canExpandParent(
        startNode,
        function(node) return node:prev() end,
        function(nodeRange) return startNodeRange[1] - nodeRange[3] end
    ) end
    if prevNode ~= nil then startEmptyLines = startNodeRange[1] - prevNode:range()[3] - 1
    else startEmptyLines = startNodeRange[1] - rootRange[1] end

    local endNode = endData
    local endNodeRange = endNode:range()
    local nextNode = endNode:next()
    if nextNode == nil then _, nextNode = canExpandParent(
        endNode,
        function(node) return node:next() end,
        function(nodeRange) return nodeRange[1] - endNodeRange[3] end
    ) end
    if nextNode ~= nil then endEmptyLines = nextNode:range()[1] - endNodeRange[3] - 1
    else endEmptyLines = rootRange[3] - endNodeRange[3] end

    startEmptyLines = math.max(0, startEmptyLines)
    endEmptyLines  = math.max(0, endEmptyLines )

    local function calcReachedParent(node, getSibling, diffLines)
        local startRange = node:range()
        while true do
            node = getSibling(node)
            if node == nil then return true end
            if diffLines(node:range()) > 0 then return false end
            if node:parentPart() then return true end
        end
    end
    startReachedParent = calcReachedParent(
        startNode,
        function(node) return node:prev() end,
        function(nodeRange) return startNodeRange[1] - nodeRange[3] end
    )
    endReachedParent = calcReachedParent(
        endNode,
        function(node) return node:next() end,
        function(nodeRange) return nodeRange[1] - endNodeRange[3] end
    )

    local function parRange(node)
        if node == nil then return rootRange end
        local par = node:parent()
        if par == nil then return rootRange end
        return par:range()
    end
    local prevPrarentRange = parRange(startNode)
    local nextPrarentRange = parRange(endNode)

    return {
        range = { startNodeRange[1], startNodeRange[2], endNodeRange[3], endNodeRange[4] },
        ends = {
            { emptyLines = startEmptyLines, reachedParent = startReachedParent, smaler = utils.isRangeInside(prevPrarentRange, nextPrarentRange) },
            { emptyLines = endEmptyLines  , reachedParent = endReachedParent  , smaler = utils.isRangeInside(nextPrarentRange, prevPrarentRange) },
        }
    }
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
            ['comment'] = {
                { boundaryLinesParent = true }, -- [1] ~= ['1']
                ['comment_content'] = true -- lua
            },
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

    local paragraphData = findParagraphBounds(root, getCursorRange())
    if paragraphData == nil then return end
    local totalRange = paragraphData.range

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

    local paragraphData = findParagraphBounds(root, getCursorRange())
    if paragraphData == nil then return end
    local totalRange = paragraphData.range
    local ends = paragraphData.ends

    local emptyAbove, emptyBelow
            --{ emptyLines = diffBefore, reachedParent = startData[2], smaler = prevSmaller },

    if not ends[1].smaler and not ends[2].smaler then
        if ends[1].emptyLines > ends[2].emptyLines then
            emptyAbove = 0
            emptyBelow = ends[2].emptyLines
        else
            emptyAbove = ends[1].emptyLines
            emptyBelow = 0
        end
    elseif ends[1].smaler and ends[2].smaler then
        if ends[1].reachedParent or ends[2].reachedParent then
            emptyAbove = ends[1].emptyLines
            emptyBelow = ends[2].emptyLines
        elseif ends[1].emptyLines > ends[2].emptyLines then
            emptyAbove = 0
            emptyBelow = ends[2].emptyLines
        else
            emptyAbove = ends[1].emptyLines
            emptyBelow = 0
        end
    else
        if ends[1].smaler then
            emptyAbove = ends[1].emptyLines
            emptyBelow = 0
        else
            emptyAbove = 0
            emptyBelow = ends[2].emptyLines
        end
    end

    local cursorPos = vim.api.nvim_win_get_cursor(0)

    local cursorEndPos = totalRange[3] + emptyBelow + 1

    vim.api.nvim_buf_set_lines(0, totalRange[1] - emptyAbove, totalRange[1], true, {})
    totalRange[1] = totalRange[1] - emptyAbove
    totalRange[3] = totalRange[3] - emptyAbove
    cursorEndPos = cursorEndPos - emptyAbove
    vim.api.nvim_buf_set_lines(0, totalRange[3] + 1, totalRange[3] + emptyBelow + 1, true, {})
    cursorEndPos = cursorEndPos - emptyBelow

    local register = vim.api.nvim_get_vvar( 'register')
    vim.cmd('keepjumps '..(totalRange[1]+1)..','..(totalRange[3]+1)..'delete '..register)
    cursorEndPos = cursorEndPos - (totalRange[3] - totalRange[1] + 1)
    local last = vim.api.nvim_buf_line_count(0) - 1
    vim.api.nvim_win_set_cursor(0, { math.max(0, math.min(cursorEndPos, last)) + 1, cursorPos[2] })

end)

local utils = require('utils')


local function go(node) if node then return node.orig else return 'none' end end

--[[
    returns 0 if node is not selected
    returns 0 if node is not selected
    returns 1 if node is selected
    returns 2 if node's parent should be added bc node itself is unnamed ]]
local function fillLeafNodesInRange(list, nodesInfo, node, range, depth)
    local nodeRange = nodesInfo.range(node)
    if not utils.isRangeIntersects(nodeRange, range) then return 0 end

    local hasChildren = false
    local status = 0
    for childNode in nodesInfo.childrenIter(node) do
        hasChildren = true
        local childStatus = fillLeafNodesInRange(list, nodesInfo, childNode, range, depth + 1)
        if status == 0 then status = childStatus
        elseif status == 2 and childStatus == 1 then status = childStatus end
    end

    if not hasChildren or status == 2 then
        if nodesInfo.parentPart(node) then return 2
        else list[nodesInfo.id(node)] = node end
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

local function canExpand(nodesInfo, node, getSibling, diffLines)
    local nodeRange = nodesInfo.range(node)
    local nbNode = getSibling(node)
    if nbNode == nil then
        local parent = node
        while true do
            parent = nodesInfo.parent(parent)
            if parent == nil then return true, nil end
            local sibling = getSibling(parent)
            if sibling ~= nil then return diffLines(nodesInfo.range(sibling), nodeRange) > 0, sibling end
        end
    else return diffLines(nodesInfo.range(nbNode), nodeRange) > 0, nbNode end
end

local function getTwoNodesRange(nodesInfo, items)
    local fr = nodesInfo.range(items[1])
    local lr = nodesInfo.range(items[2])
    return { fr[1], fr[2], lr[3], lr[4] }
end

local function expandWholeLine(nodesInfo, curNode, getSibling, diffLines)
    while true do
        if nodesInfo.parentPart(curNode) then return nil end
        local expanded, nbNode = canExpand(nodesInfo, curNode, getSibling, diffLines)
        if expanded then return curNode end
        assert(nbNode ~= nil)

        curNode = nbNode
    end
end

--[[ returns reachedParent, last lafe node ]]
local function updateRange(nodesInfo, curNode, getSibling, diffLines)
    local lastSafe = nil
    while true do
        local nbNode = getSibling(curNode)
        if nbNode == nil then
            local expanded, _ = canExpand(nodesInfo, curNode, getSibling, diffLines)
            if expanded then lastSafe = curNode end
            return true, lastSafe
        end
        local diff = diffLines(nodesInfo.range(nbNode), nodesInfo.range(curNode))
        if diff > 0 then lastSafe = curNode end
        if diff > 1 then return false, lastSafe end
        if nodesInfo.parentPart(nbNode) then return true, lastSafe end
        curNode = nbNode
    end

end

local function printTree(indent, node)
    print(string.rep(' ', indent), node.orig)
    for _, child in pairs(node.hierarchy.children) do
        printTree(indent + 2, child)
    end
end


local function findParagraphBounds(nodesInfo, root, inputRange)
    local rootRange = nodesInfo.range(root)
    local initialNodes = {}
    fillLeafNodesInRange(initialNodes, nodesInfo, root, inputRange, 0)

    local initParents = {}
    for _, node in pairs(initialNodes) do -- find all parents of nodes in range and keep 2 boundary nodes for each parent
        local nodeRange = nodesInfo.range(node)

        local parent = nodesInfo.parent(node)
        if parent == nil then return {
            range = nodeRange,
            ends = {
                { emptyLines = nodeRange[1] - rootRange[1], reachedParent = true, smaler = true },
                { emptyLines = rootRange[3] - nodeRange[1], reachedParent = true, smaler = true },
            },
        } end -- if root node is already selected
        local parentId = nodesInfo.id(parent)

        local parentData = initParents[parentId]
        if parentData == nil then
            parentData = { startNodes = { node, node } }
            initParents[parentId] = parentData
        else

            local combinedRange = getTwoNodesRange(nodesInfo, parentData.startNodes)
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
                nodesInfo, parentData.startNodes[1],
                function(node) return nodesInfo.prev(node) end,
                function(nodeRange, otherRange) return otherRange[1] - nodeRange[3] end
            )
            if first ~= nil then
                local last = expandWholeLine(
                    nodesInfo, parentData.startNodes[2],
                    function(node) return nodesInfo.next(node) end,
                    function(nodeRange, otherRange) return nodeRange[1] - otherRange[3] end
                )
                if last ~= nil then
                    parentData.startNodes[1] = first
                    parentData.startNodes[2] = last
                    break
                end
            end

            local parent = nodesInfo.parent(parentData.startNodes[1])
            assert(parent ~= nil)
            parentData.startNodes[1] = parent
            parentData.startNodes[2] = parent
        end

        local index = getPointInsertIndex(nodesInfo.range(parentData.startNodes[1]), parentsData, function(item) return nodesInfo.range(item.startNodes[1]) end)
        parentData.confirmedNodes = utils.updateTable({}, parentData.startNodes) -- nodes that define actual selection
        table.insert(parentsData, index, parentData)
    end
    parentsData = utils.filterInside(parentsData, function(it) return nodesInfo.range(it.confirmedNodes[1]) end)

    local totalRanges = {}
    while true do -- expand all selections iteratively
        local nextParentData = {}

        for _, data in pairs(parentsData) do -- expand selection
            local reachedStart, firstSafe = updateRange(
                nodesInfo, data.startNodes[1],
                function(node) return nodesInfo.prev(node) end,
                function(nodeRange, otherRange) return otherRange[1] - nodeRange[3] end
            )

            local reachedEnd, lastSafe = updateRange(
                nodesInfo, data.startNodes[2],
                function(node) return nodesInfo.next(node) end,
                function(nodeRange, otherRange) return nodeRange[1] - otherRange[3] end
            )

            local parent = nodesInfo.parent(data.startNodes[1])
            print(go(parent), go(firstSafe), go(lastSafe), reachedStart, reachedEnd)

            if reachedStart and reachedEnd and parent then
                local confirmedNodes
                if firstSafe ~= nil and lastSafe ~= nil then confirmedNodes = { firstSafe, lastSafe }
                else confirmedNodes = data.confirmedNodes end

                local index = getPointInsertIndex(nodesInfo.range(parent), nextParentData, function(it) return nodesInfo.range(it.confirmedNodes[1]) end)
                table.insert(nextParentData, index, {
                    confirmedNodes = confirmedNodes,
                    startNodes = { parent, parent }
                })
            else
                local nodes
                if firstSafe == nil or lastSafe == nil then nodes = data.confirmedNodes
                else nodes = { firstSafe, lastSafe } end

                local index = getPointInsertIndex(nodesInfo.range(nodes[1]), totalRanges, function(it) return nodesInfo.range(it[1]) end)
                --print( vim.inspect(nodes[1]._info.range) , vim.inspect(nodes[2]._info.range) )
                --print(nodes[1]._info.orig, nodes[2]._info.orig)
                --print(nodes[1]._hierarchy.prev == nil, nodes[2]._hierarchy.next._info.orig)
                table.insert(totalRanges, index, nodes)
            end
        end

        if #nextParentData == 0 then break end
        parentsData = utils.filterInside(nextParentData, function(it) return nodesInfo.range(it.confirmedNodes[1]) end)
    end

    if #totalRanges == 0 then return nil end

    -- merge ranges
    utils.filterInside(totalRanges, function(it) return nodesInfo.range(it[1]) end)

    local totalRange = utils.emptyRange()
    local startData, endData
    for _, rangeData in pairs(totalRanges) do
        local range = getTwoNodesRange(nodesInfo, rangeData)
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
    local startNodeRange = nodesInfo.range(startNode)
    local _, prevNode = canExpand(
        nodesInfo, startNode,
        function(node) return nodesInfo.prev(node) end,
        function(nodeRange, otherRange) return otherRange[1] - nodeRange[3] end
    )
    if prevNode ~= nil then startEmptyLines = startNodeRange[1] - nodesInfo.range(prevNode)[3] - 1
    else startEmptyLines = startNodeRange[1] - rootRange[1] end

    local endNode = endData
    local endNodeRange = nodesInfo.range(endNode)
    local _, nextNode = canExpand(
        nodesInfo, endNode,
        function(node) return nodesInfo.next(node) end,
        function(nodeRange) return nodeRange[1] - endNodeRange[3] end
    )
    if nextNode ~= nil then endEmptyLines = nodesInfo.range(nextNode)[1] - endNodeRange[3] - 1
    else endEmptyLines = rootRange[3] - endNodeRange[3] end

    startEmptyLines = math.max(0, startEmptyLines)
    endEmptyLines  = math.max(0, endEmptyLines )

    local function calcReachedParent(node, getSibling, diffLines)
        while true do
            node = getSibling(node)
            if node == nil then return true end
            if nodesInfo.parentPart(node) then return true end
            if diffLines(nodesInfo.range(node)) > 1 then return false end
        end
    end
    startReachedParent = calcReachedParent(
        startNode,
        function(node) return nodesInfo.prev(node) end,
        function(nodeRange) return startNodeRange[1] - nodeRange[3] end
    )
    endReachedParent = calcReachedParent(
        endNode,
        function(node) return nodesInfo.next(node) end,
        function(nodeRange) return nodeRange[1] - endNodeRange[3] end
    )

    local function parRange(node)
        if node == nil then return rootRange end
        local par = nodesInfo.parent(node)
        if par == nil then return rootRange end
        return nodesInfo.range(par)
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

local vim = vim

local function getCursorRange()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = cursor[1] - 1
    return { line, 0, line, math.huge }
end

local m = require('mapping')



local properties = { -- TODO: add self
    parseNode = function(self, context, treesNode)
        --if true then return false end
        local hierarchy = require('hierarchy.default')

        local nodeType = hierarchy.treesType(treesNode, context.langTree)

        if nodeType.lang == 'lua' then
            if nodeType.name == 'else_statement' or nodeType.name == 'elseif_statement' then
                for child in treesNode:iter_children() do
                    hierarchy.parseChild(context, child)
                end
                return true
            end
        end

        local textProperties = ({
            ['comment'] = {
                --{ boundaryLinesParent = true }, -- [1] ~= ['1'] --c++
                isText = function(node, context)
                    local  type = hierarchy.treesType(node, context.langTree)
                    if type.name == 'comment_content' then return true end -- lua only
                end
            },
            ['string_fragment'] = {
                isText = function(node, context)
                    local  type = hierarchy.treesType(node, context.langTree)
                    if type.name == 'string' then return true end -- lua only
                end
            },
            ['string_literal'] = {
                isText = function(node, context)
                    local  type = hierarchy.treesType(node, context.langTree)
                    if type.name == 'string_content' then return true end -- lua only
                end
            },
            ['template_string'] = {},
        })[nodeType.name]
        if textProperties then
            hierarchy.parseTextNode(treesNode, nodeType, textProperties, context)
            return true
        end

        if nodeType.lang ~= 'cpp' then return end
        if nodeType.name == 'if_statement' then
            hierarchy.parseSplitNode(treesNode, nodeType, {
                splitAt = function(_, node)
                    local type = node.type
                    if type.name == 'else_clause' then return true end
                end
            }, context)
            return true
        elseif nodeType.name == 'else_clause' then
            hierarchy.parseSplitNode(treesNode, nodeType, {
                splitAt = function(_, node)
                    local type = node.type
                    if type.name == 'if_statement' then return true end
                end
            }, context)
            return true
        end
    end
}

local hierarchy = require('hierarchy.default')

m.n('yip', function()
    local bufId = vim.api.nvim_get_current_buf()
    local parser = vim.treesitter.get_parser(bufId)

    local a = require('hierarchy.default')
    local root = a.createRoot(
        bufId,
        parser,
        properties
    )

    local paragraphData = findParagraphBounds(hierarchy.nodesInfo, root, getCursorRange())
    if paragraphData == nil then return end
    local totalRange = paragraphData.range

    print(vim.inspect(paragraphData))

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
        properties
    )

    local paragraphData = findParagraphBounds(hierarchy.nodesInfo, root, getCursorRange())
    if paragraphData == nil then return end
    local totalRange = paragraphData.range
    local ends = paragraphData.ends

    print(vim.inspect(paragraphData))

    local emptyAbove, emptyBelow

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
        if ends[2].smaler then
            emptyAbove = 0
            emptyBelow = ends[2].emptyLines
        else
            emptyAbove = ends[1].emptyLines
            emptyBelow = 0
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

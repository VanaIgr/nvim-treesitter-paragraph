local utils = require('utils')

--[[
    returns 0 if node is not selected
    returns 1 if node is selected
    returns 2 if node's parent should be added bc node itself is unnamed
]]
local function fillLeafNodesInRange(list, node, range, depth)
    if depth == nil then depth = 0 end

    local nodeRange = node:range()
    print(depth, vim.inspect(nodeRange))
    if not utils.isRangeIntersects(nodeRange, range) then return 0 end

    local hasChildren = false
    local status = 0
    for childNode in node:childrenIter() do
        hasChildren = true
        local childStatus = fillLeafNodesInRange(list, childNode, range, depth + 1)
        if status == 0 then status = childStatus
        elseif status == 2 and childStatus == 1 then status = childStatus end
    end

    --print(depth, hasChildren, vim.inspect(nodeRange))

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
        if node == nil then return true end
        local sibling = getSibling(node)
        if sibling ~= nil then return diffLines(sibling:range()) > 0 end
        node = node:parent()
    end
end

local function updateRange(curNode, getSibling, diffLines, expandRange, confirmRange)
    local inParent = false

    while true do
        local nbNode = getSibling(curNode)
        if nbNode == nil then
            local expand = canExpandParent(curNode:parent(), getSibling, diffLines)
            if not inParent and expand then confirmRange() end
            return true
        end

        local nbNodeRange = nbNode:range()
        local diff = diffLines(nbNodeRange)
        if not inParent and diff > 0 then confirmRange() end
        if diff > 1 then return false end

        if nbNode:parentPart() then inParent = true end
        expandRange(nbNodeRange)
        curNode = nbNode
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

            local inParentBefore = updateRange(
                data.items[1],
                function(node) return node:prev() end,
                function(nodeRange) return expRange[1] - nodeRange[3] end,
                function(nodeRange) utils.addRange(expRange, nodeRange) end,
                function() range[1] = expRange[1]; range[2] = expRange[2] end
            )

            local inParentAfter = updateRange(
                data.items[2],
                function(node) return node:next() end,
                function(nodeRange) return nodeRange[1] - expRange[3] end,
                function(nodeRange) utils.addRange(expRange, nodeRange) end,
                function() range[3] = expRange[3]; range[4] = expRange[4] end
            )

            local parent = data.items[1]:parent()
            if inParentBefore and inParentAfter and parent ~= nil then
                local index = getPointInsertIndex(range, nextParentData)
                table.insert(nextParentData, index, {
                    range = range, expRange = expRange,
                    items = { parent, parent },
                })
            else
                local index = getPointInsertIndex(range, totalRanges)
                table.insert(totalRanges, index, {
                    range = range,
                    ends = { inParentBefore, inParentAfter },
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
            ends[1] = ends[1]
        end
        if range[3] > totalRange[3] or (range[3] == totalRange[3] and range[4] >= totalRange[4]) then
            totalRange[3] = range[3]
            totalRange[4] = range[4]
            ends[2] = ends[2]
        end
    end

    totalRange[1] = totalRange[1] + 1
    totalRange[3] = totalRange[3] + 1

    return totalRange, ends
end


local function getCursorRange()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = cursor[1] - 1
    return { line, 0, line, math.huge }
end

local m = require('mapping')

local _ = [=[

local function printNode(indent, node)
    print(string.rep(' ', indent), node, node:type())
    for child in node:iter_children() do
        printNode(indent + 2, child)
    end
end


local function printSubnode(indent, node)
    print(string.rep(' ', indent), node)
    for child in node:iter_children() do
        printSubnode(indent + 2, child)
    end
end

local function printTree(indent, parser)
    local langs = parser:included_regions()
    print(string.rep(' ', indent), parser:lang())
    print(string.rep(' ', indent + 2), 'tree: ')
    local roots = parser:parse(true)
    for index, i in ipairs(roots) do
        print(string.rep(' ', indent + 4), 'subtree ', index, ': ')
        printSubnode(indent + 6, i:root())
    end
    print(string.rep(' ', indent + 2), 'ranges: ')
    for _, range in pairs(langs) do
        print(string.rep(' ', indent + 4), vim.inspect(range))
    end
    print(string.rep(' ', indent + 2), 'children: ')
    for _, child in pairs(parser:children()) do
        printTree(indent + 4, child)
    end
end

vim.keymap.set('n', '#', function()
    local root = vim.treesitter.get_parser()
    printTree(0, root)
    --[[local r = root:parse(true)
    for _, l in pairs(r) do
        print(l)
    end]]
    --printNode(0, r[1]:root())
end)

]=]

m.n('yip', function()
    local parser = vim.treesitter.get_parser(0)

    --[[printTree(0, parser)
    if true then return end]]

    --[[printTree(0, parser)
    local oo = parser:language_for_range{ 5, 0, 6, 0 }:parse()[1]
    printSubnode(0, oo:root())
    --print('!', vim.inspect())

    --print('@', vim.inspect(parser:language_for_range{ 0, 0, 0, 1 }))

    --print(vim.inspect(parser:parse(true)))

    for i, root in pairs() do
        print(i)
        printSubnode(0, root:root())
    end
    if true then return end
    if true then return end, parent]]

    local a = require('hierarchy.default')
    local root = a.createRoot(
        parser,
        function(lang)
            return {
                splitNodes = {
                    ['if_statement'] = {
                        ['else_clause'] = true,
                        ['else_statement'] = true,
                        ['elseif_statement'] = true
                    }
                }
            }
        end
    )

    --print('!', vim.inspect(root))

    local totalRange = getParagraphRange(root, getCursorRange())
    if totalRange[1] > totalRange[3] then return end

    print(totalRange[1], totalRange[3])

    local pos = vim.api.nvim_win_get_cursor(0)
    local register = vim.api.nvim_get_vvar('register')
    vim.cmd('keepjumps '..totalRange[1]..','..totalRange[3]..'yank '..register)
    vim.api.nvim_win_set_cursor(0, pos)
end)


    --[[if vim.opt.selection._value == 'exclusive' then totalRange[4] = totalRange[4] + 1; end
    normalizeRange(totalRange)]]

--vim.keymap.set('n', '!', selectParargephFromLine)
vim.cmd[=[

mess clear

]=]

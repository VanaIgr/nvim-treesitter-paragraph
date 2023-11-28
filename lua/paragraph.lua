local utils = require('utils')


local function go(node) if node then return node.orig else return 'none' end end

--[[
    returns 0 if node is not selected
    returns 0 if node is not selected
    returns 1 if node is selected
    returns 2 if node's parent should be added bc node itself is unnamed ]]
local function fillLeafNodesInRange(list, nodesInfo, node, range, depth)
    local nodeRange = nodesInfo:range(node)
    if not utils.isRangeIntersects(nodeRange, range) then return 0 end

    local hasChildren = false
    local status = 0
    for childNode in nodesInfo:childrenIter(node) do
        hasChildren = true
        local childStatus = fillLeafNodesInRange(list, nodesInfo, childNode, range, depth + 1)
        if status == 0 then status = childStatus
        elseif status == 2 and childStatus == 1 then status = childStatus end
    end

    if not hasChildren or status == 2 then
        if nodesInfo:parentPart(node) then return 2
        else list[nodesInfo:id(node)] = node end
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
        elseif utils.isPointBefore(curPoint[1], curPoint[2], insertPoint[1], insertPoint[2]) then
            e = m
        else
            b = m + 1
        end
    end

    return b + 1
end

local function canExpand(nodesInfo, node, direction)
    local startNode = node
    while node do
        local sibling = nodesInfo:getSibling(node, direction)
        if sibling ~= nil then return nodesInfo:diffLines(sibling, startNode, direction) > 0, sibling end
        node = nodesInfo:parent(node)
    end
    return true, nil
end

local function getTwoNodesRange(nodesInfo, items)
    local fr = nodesInfo:range(items[1])
    local lr = nodesInfo:range(items[2])
    return { fr[1], fr[2], lr[3], lr[4] }
end

local function expandWholeLine(nodesInfo, curNode, direction)
    while true do
        if nodesInfo:parentPart(curNode) then return nil end
        local expanded, nbNode = canExpand(nodesInfo, curNode, direction)
        if expanded then return curNode end
        assert(nbNode ~= nil)

        curNode = nbNode
    end
end

--[[ returns reachedParent, last lafe node ]]
local function updateRange(nodesInfo, curNode, direction)
    local lastSafe = nil
    while true do
        local nbNode = nodesInfo:getSibling(curNode, direction)
        if nbNode == nil then
            local expanded, _ = canExpand(nodesInfo, curNode, direction)
            if expanded then lastSafe = curNode end
            return true, lastSafe
        end
        local diff = nodesInfo:diffLines(nbNode, curNode, direction)
        if diff > 0 then lastSafe = curNode end
        if diff > 1 then return false, lastSafe end
        if nodesInfo:parentPart(nbNode) then return true, lastSafe end
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
    local rootRange = nodesInfo:range(root)
    local initialNodes = {}
    fillLeafNodesInRange(initialNodes, nodesInfo, root, inputRange, 0)

    --for _, n in pairs(initialNodes) do print(vim.inspect(n.info.range), n.orig) end

    local initParents = {}
    for _, node in pairs(initialNodes) do -- find all parents of nodes in range and keep 2 boundary nodes for each parent
        local nodeRange = nodesInfo:range(node)

        local parent = nodesInfo:parent(node)
        if parent == nil then return {
            range = nodeRange,
            ends = { { reachedParent = true, smaler = true }, { reachedParent = true, smaler = true } },
        } end -- if root node is already selected
        local parentId = nodesInfo:id(parent)

        local parentData = initParents[parentId]
        if parentData == nil then
            parentData = { startNodes = { node, node } }
            initParents[parentId] = parentData
        else

            local combinedRange = getTwoNodesRange(nodesInfo, parentData.startNodes)
            if utils.isPointBefore(nodeRange[1], nodeRange[2], combinedRange[1], combinedRange[2]) then
                parentData.startNodes[1] = node
            end
            if utils.isPointBefore(combinedRange[3], combinedRange[4], nodeRange[3], nodeRange[4]) then
                parentData.startNodes[2] = node
            end

        end

    end

    local parentsData = {}
    for _, parentData in pairs(initParents) do -- convert parent map to array and add add necessary values
        while true do -- expand the selection for each parent to be complete
            local first = expandWholeLine(nodesInfo, parentData.startNodes[1], false)
            if first ~= nil then
                local last = expandWholeLine(nodesInfo, parentData.startNodes[2], true)
                if last ~= nil then
                    parentData.startNodes[1] = first
                    parentData.startNodes[2] = last
                    break
                end
            end

            local parent = nodesInfo:parent(parentData.startNodes[1])
            assert(parent ~= nil)
            parentData.startNodes[1] = parent
            parentData.startNodes[2] = parent
        end

        local index = getPointInsertIndex(nodesInfo:range(parentData.startNodes[1]), parentsData, function(item) return nodesInfo:range(item.startNodes[1]) end)
        parentData.confirmedNodes = utils.updateTable({}, parentData.startNodes) -- nodes that define actual selection
        table.insert(parentsData, index, parentData)
    end
    parentsData = utils.filterInside(parentsData, function(it) return nodesInfo:range(it.confirmedNodes[1]) end)

    local totalRanges = {}
    while true do -- expand all selections iteratively
        local nextParentData = {}

        for _, data in pairs(parentsData) do -- expand selection
            local reachedStart, firstSafe = updateRange(nodesInfo, data.startNodes[1], false)
            local reachedEnd, lastSafe = updateRange(nodesInfo, data.startNodes[2], true)

            local parent = nodesInfo:parent(data.startNodes[1])
            --print(go(parent), go(firstSafe), go(lastSafe), reachedStart, reachedEnd)

            if reachedStart and reachedEnd and parent then
                local confirmedNodes
                if firstSafe ~= nil and lastSafe ~= nil then confirmedNodes = { firstSafe, lastSafe }
                else confirmedNodes = data.confirmedNodes end

                local index = getPointInsertIndex(nodesInfo:range(parent), nextParentData, function(it) return nodesInfo:range(it.confirmedNodes[1]) end)
                table.insert(nextParentData, index, { confirmedNodes = confirmedNodes, startNodes = { parent, parent } })
            else
                local nodes
                if firstSafe == nil or lastSafe == nil then nodes = data.confirmedNodes
                else nodes = { firstSafe, lastSafe } end

                local index = getPointInsertIndex(nodesInfo:range(nodes[1]), totalRanges, function(it) return nodesInfo:range(it[1]) end)
                --print( vim.inspect(nodes[1]._info.range) , vim.inspect(nodes[2]._info.range) )
                --print(nodes[1]._info.orig, nodes[2]._info.orig)
                --print(nodes[1]._hierarchy.prev == nil, nodes[2]._hierarchy.next._info.orig)
                table.insert(totalRanges, index, nodes)
            end
        end

        if #nextParentData == 0 then break end
        parentsData = utils.filterInside(nextParentData, function(it) return nodesInfo:range(it.confirmedNodes[1]) end)
    end

    if #totalRanges == 0 then return nil end

    -- merge ranges
    utils.filterInside(totalRanges, function(it) return nodesInfo:range(it[1]) end)

    local totalRange = utils.emptyRange()
    local startData, endData
    for _, rangeData in pairs(totalRanges) do
        local range = getTwoNodesRange(nodesInfo, rangeData)
        if utils.isPointBefore(range[1], range[2], totalRange[1], totalRange[2]) then
            totalRange[1] = range[1]
            totalRange[2] = range[2]
            startData = rangeData[1]
        end
        if utils.isPointBefore(totalRange[3], totalRange[4], range[3], range[4]) then
            totalRange[3] = range[3]
            totalRange[4] = range[4]
            endData = rangeData[2]
        end
    end

    -- calculate return value

    local prevPosition, startReachedParent
    local nextPosition, endReachedParent

    local startNode = startData
    local _, prevNode = canExpand(nodesInfo, startNode, false)
    if prevNode then
        local range = nodesInfo:range(prevNode)
        prevPosition = { range[3], range[4] }
    end

    local endNode = endData
    --local endNodeRange = nodesInfo:range(endNode)
    local _, nextNode = canExpand(nodesInfo, endNode, true)
    if nextNode then
        local range = nodesInfo:range(nextNode)
        nextPosition = { range[1], range[2] }
    end

    local function calcReachedParent(node, direction)
        local startNode = node
        while true do
            node = nodesInfo:getSibling(node, direction)
            if node == nil then return true end
            if nodesInfo:parentPart(node) then return true end
            if nodesInfo:diffLines(node, startNode, direction) > 1 then return false end
        end
    end
    startReachedParent = calcReachedParent(startNode, false)
    endReachedParent = calcReachedParent(endNode, true)

    local function parRange(node)
        local par = nodesInfo:parent(node)
        if par == nil then return rootRange end
        return nodesInfo:range(par)
    end
    local prevPrarentRange = parRange(startNode)
    local nextPrarentRange = parRange(endNode)

    return {
        range = totalRange,
        ends = {
            { neighbour = prevPosition, reachedParent = startReachedParent, smaler = utils.isRangeInside(prevPrarentRange, nextPrarentRange) },
            { neighbour = nextPosition, reachedParent = endReachedParent  , smaler = utils.isRangeInside(nextPrarentRange, prevPrarentRange) },
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

local Properties = {}

function Properties:parseNode(context, treesNode)
    local hierarchy = require('hierarchy.default')
    local type = hierarchy.treesType(treesNode, context.langTree)
    local config = self.config[type.lang] or {}

    local splitProperties = (config.split or {})[type.name]
    if splitProperties and hierarchy.parseSplitNode(treesNode, type, {
            splitAt = function(_, children, i)
                return splitProperties[children[i].type.name]
            end
        },
        context
    ) then return end
    local splitExtra = ((config.split or {})[1] or {}).extra
    if splitExtra and hierarchy.parseSplitNode(treesNode, type, {
            splitAt = function(_, children, i)
                local res = splitExtra(type.name, children[i].type.name, i, #children)
                if res then return true else return false end -- convert to bool
            end
        },
        context
    ) then return end

    local textProperties = (config.text or {})[type.name]
    if textProperties and hierarchy.parseTextNode(
        treesNode, type, {
            boundaryLinesParent = (textProperties[1] or {}).boundary_lines_parent,
            isText = function(childNode, childContext)
                if context.langTree == childContext.langTree then
                    return textProperties[hierarchy.treesType(childNode, context.langTree).name]
                end
            end
        },
        context
    ) then return end

    hierarchy.parseRegularNode(context, treesNode)
end
function Properties:setupNode(node)
    local hierarchy = require('hierarchy.default')

    local type = node.type
    local parentPartProperties = (self.config[type.lang] or {}).parent_part
    local parentPartFunction = (parentPartProperties or {})[1]

    if parentPartFunction then
        local parentType = (node.hierarchy.parent or {}).type

        local function convertType(type)
            local nodeInfo
            if type == nil then return { type = 'none' }
            elseif type[1] == hierarchy.typeId.treesitter then
                nodeInfo = { type = 'regular', language = type.lang, name = type.name }
            elseif type[1] == hierarchy.typeId.languageRoot then
                nodeInfo = {
                    type = 'language_change',
                    from_language = (type.fromTree or {}).lang,
                    to_language = (type.toTree or {}).lang
                }
            elseif type[1] == hierarchy.typeId.text then
                nodeInfo = { type = 'text' }
            else
                assert(false, vim.inspect(type))
            end
            return nodeInfo
        end

        node.info.isParentPart = parentPartFunction(convertType(type), convertType(parentType), node.info.isParentPart)
    end
end

local function createProperties(config)
    local o = { config = config }
    setmetatable(o, { __index = Properties })
    return o
end

local properties = createProperties{
    lua = {
        text = {
            comment = { comment_content = true },
            string = { string_content = true },
        },
        parent_part = {
            function(node_type, parent_type, is_parent_part)
                if node_type.type == 'regular' and (node_type.name == ',' or node_type.name == ';') then
                    return false
                end

                if node_type.type == 'regular' and parent_type.type == 'regular'
                    and parent_type.language == node_type.language
                    and node_type.name ~= 'body' and parent_type.name == 'function_declaration'
                then
                    return true
                end

                return is_parent_part
            end
        },
    },
    cpp = {
        text = {
            comment = { { boundary_lines_parent = true } },
            string_literal = { string_content = true },
            char_literal   = { character = true }, -- probably unnecessary
            raw_string_literal = { raw_stinr_content = true },
            system_lib_string = {},
        },
        split = {
            { extra = function(_parentName, childName, childI, childrenC)
                return childName == ';' and childI == childrenC
            end },
            if_statement = { else_clause = true },
            else_clause = { if_statement = true },
        },
        parent_part = {
            function(node_type, parent_type, is_parent_part)
                if node_type.type == 'regular' and (node_type.name == ',' or node_type.name == ';') then
                    return false
                end

                if node_type.type == 'regular' and parent_type.type == 'regular'
                    and parent_type.language == node_type.language
                    and node_type.name ~= 'body' and parent_type.name == 'function_declaration'
                then
                    return true
                end

                return is_parent_part
            end
        }
    },
    python = {
        text = { string = { string_content = true } }
    },
    javascript = {
        text = {
            string = { string_fragment = true },
            template_string = {},
        },
        split = {
            { extra = function(_parentName, childName, childI, childrenC)
                return childName == ';' and childI == childrenC
            end },
            if_statement = { else_clause = true },
            else_clause = { if_statement = true },
        }
    },
}

local ns = vim.api.nvim_create_namespace('')
local hierarchy = require('hierarchy.default')

local NodesInfo = {}
setmetatable(NodesInfo, { __index = hierarchy.nodesInfo })
-- no guarantee that nodes are no the same level
-- returns   0 - share lines, 1 - expandable, 2 - far apart
function NodesInfo:diffLines(node, otherNode, nodeBelow)
    if node == nil or otherNode == nil or nodeBelow == nil then error('incorrect parameters') end
    local above, below = node, otherNode
    if nodeBelow then
        below = node
        above = otherNode
    end
    local diff = self:range(below)[1] - self:range(above)[3]
    if diff < 0 then error('incorrect nodes')
    --elseif diff == 0 then return 0
    elseif diff < 2 then return 1
    else return 2 end
end
function NodesInfo:getSibling(node, below)
    if node == nil or below == nil then error('incorrect parameters') end
    if below then return self:next(node)
    else return self:prev(node) end
end

local function createNodesInfo()
    local info = {}
    setmetatable(info, { __index = NodesInfo })
    return info
end

local function checkIsSafeLine(range, otherPos, rangeBelow)
    if otherPos == nil then return true end
    if rangeBelow then return range[1] > otherPos[1]
    else return otherPos[1] > range[3] end
end

local function getReginfos(register)
    local reginfos = {}
    local curReg = register
    while curReg ~= nil and reginfos[curReg] == nil do
        local info = vim.fn.getreginfo(curReg)
        reginfos[curReg] = info
        curReg = info.points_to
    end
    return reginfos
end

local fix = utils.vim_clamp0

m.n('yip', function() local bufId = vim.api.nvim_get_current_buf()
    local parser = vim.treesitter.get_parser(bufId)

    local a = require('hierarchy.default')
    local root = a.createRoot(bufId, parser, properties)
    local paragraphData = findParagraphBounds(createNodesInfo(), root, getCursorRange())
    if paragraphData == nil then return end
    local totalRange = paragraphData.range

    local prev, next = paragraphData.ends[1].neighbour, paragraphData.ends[2].neighbour
    local lineBefore, lineAfter = checkIsSafeLine(totalRange, prev, true), checkIsSafeLine(totalRange, next, false)

    local range = { totalRange[1] + 1, nil, totalRange[3] + 1, nil }
    if lineBefore then range[2] = 0
    else range[2] = totalRange[2] end
    if lineAfter then range[4] = math.huge
    else range[4] = totalRange[4] end

    -- (1, 0) end-exclusive indexing ... even though half the time these marks are inclusive
    vim.api.nvim_buf_set_mark(bufId, '[', utils.vim_clamp1(range[1]), utils.vim_clamp0(range[2]), {})
    vim.api.nvim_buf_set_mark(bufId, ']', utils.vim_clamp1(range[3]), utils.vim_clamp0(range[4]+1), {})

    totalRange[4] = totalRange[4] + 1
    totalRange = vim.tbl_map(fix, totalRange)
    local text = vim.api.nvim_buf_get_text(bufId, totalRange[1], totalRange[2], totalRange[3], totalRange[4], {})
    text[1] = string.rep(' ', totalRange[2]) .. text[1]

    local pos = vim.api.nvim_win_get_cursor(0)
    local register = vim.api.nvim_get_vvar('register')
    local reginfos = getReginfos(register)

    vim.cmd('normal! "'..register..'`[y`]')
    vim.api.nvim_win_set_cursor(0, pos)

    -- hope that registers weren't changed after yank
    for reg, info in pairs(reginfos) do -- do I need to replace everything recursively ?
        info.regcontents = text
        info.regtype = 'V'
        vim.fn.setreg(reg, info)
    end
end)

m.n('dip', function()
    local addEndLine = false

    local bufId = vim.api.nvim_get_current_buf()
    local parser = vim.treesitter.get_parser(bufId)

    local a = require('hierarchy.default')
    local root = a.createRoot(bufId, parser, properties)

    local paragraphData = findParagraphBounds(createNodesInfo(), root, getCursorRange())
    if paragraphData == nil then return end
    local totalRange = paragraphData.range
    local ends = paragraphData.ends

    local prev, next = paragraphData.ends[1].neighbour, paragraphData.ends[2].neighbour
    if not prev then prev = { -1, math.huge } end
    if not next then next = { vim.api.nvim_buf_line_count(bufId), 0 } end
    local lastPrev, firstNext = prev[1], next[1]
    local diffBef = totalRange[1] - lastPrev - 1
    local diffAft = firstNext - totalRange[3] - 1

    local firstL, firstC, lastL, lastC

    if diffBef == 0 and diffAft == 0 then
        local befC = totalRange[2] - prev[2]
        local aftC = prev[2] - totalRange[4]

        firstL = prev[1]
        lastL  = next[1]

        if befC < aftC then
            firstC = prev[2]
            lastL = totalRange[4]
        else
            firstC = totalRange[2]
            lastC = next[2]
        end
    else
        local useFirst
        if (ends[1].smaler and ends[2].smaler) or (not ends[1].smaler and not ends[2].smaler) then
            useFirst = diffBef < diffAft
        else
            useFirst = ends[1].smaler
        end

        if useFirst then
            firstL = prev[1]
            firstC = prev[2] + 1
            lastL  = totalRange[3]
            lastC  = totalRange[4] + 1
        else
            firstL = totalRange[1]
            firstC = totalRange[2]
            lastL  = next[1]
            lastC  = next[2]
        end
    end

    local cursorPosMark = vim.api.nvim_buf_set_extmark(
        bufId, ns, fix(ends[1].neighbour[1]), fix(ends[1].neighbour[2] + 1), {}
    )

    local register = vim.api.nvim_get_vvar('register')
    local reginfos = getReginfos(register)

    vim.api.nvim_buf_set_mark(bufId, '[', utils.vim_clamp1(firstL+1), utils.vim_clamp0(firstC), {})
    vim.api.nvim_buf_set_mark(bufId, ']', utils.vim_clamp1(lastL +1), utils.vim_clamp0(lastC+1), {})

    totalRange[4] = totalRange[4] + 1
    totalRange = vim.tbl_map(fix, totalRange)
    local text = vim.api.nvim_buf_get_text(bufId, totalRange[1], totalRange[2], totalRange[3], totalRange[4], {})
    text[1] = string.rep(' ', totalRange[2]) .. text[1]
    if addEndLine then table.insert(text, '') end

    vim.cmd('normal! "'..register..'`[d`]')

    -- hope that registers weren't changed after delete
    for reg, info in pairs(reginfos) do -- do I need to replace everything recursively ?
        info.regcontents = text
        info.regtype = 'V'
        vim.fn.setreg(reg, info)
    end

    local cursorPos = vim.api.nvim_buf_get_extmark_by_id(bufId, ns, cursorPosMark, {})
    vim.api.nvim_buf_del_extmark(bufId, ns, cursorPosMark)
    vim.api.nvim_win_set_cursor(0, { cursorPos[1] + 1, cursorPos[2] })
end)

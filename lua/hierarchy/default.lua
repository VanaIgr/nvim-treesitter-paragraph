local utils = require('utils')
local vim = vim

local M = {}

local typeIds = {}
function typeIds:add()
    local newId = #self
    table.insert(self, newId)
    return newId
end

local defaultTypes = {
    treesitter = typeIds:add(),
    languageRoot = typeIds:add(),
    text = typeIds:add(),
}

local nodesInfo = {}
M.nodesInfo = nodesInfo
function nodesInfo:childrenIter(node)
    local children = node.hierarchy.children
    local count = #children
    local i = 0
    return function() if i < count then
        i = i + 1
        return children[i]
    end end
end
function nodesInfo:data(node)
    if not node.userdata then node.userdata = {} end
    return node.userdata
end
function nodesInfo:range(node) return utils.updateTable({}, node.info.range) end
function nodesInfo:parentPart(node) return node.info.isParentPart == true end
function nodesInfo:parent(node) return node.hierarchy.parent end
function nodesInfo:prev(node) return node.hierarchy.prev end
function nodesInfo:next(node) return node.hierarchy.next end

function M.treesType(node, langTree)
    return { defaultTypes.treesitter, lang = langTree:lang(), name = node:type() }
end

function M.treesNodeRange(treesNode)
    return { utils.fixedRange(treesNode:range()) }
end

local Node = { --[[
    userdata,
    orig,
    type = { [1] = typeId, ... },
    info = { range, isParentPart },
    hierarchy = { prev, next, parent, children },
    config,
    source,
    langTree
]] }

function Node:fixChildren()
    local children = self.hierarchy.children
    for i, child in pairs(children) do
        local h = child.hierarchy
        h.parent = self
        h.prev   = children[i-1]
        h.next   = children[i+1]
        self:setup()
    end
end

function Node:setup()
    local type = self.type
    local parentPartProperties = (self.config[type.lang] or {}).parent_part
    local parentPartFunction = (parentPartProperties or {})[1]

    if parentPartFunction then
        local parentType = (self.hierarchy.parent or {}).type

        local function convertType(type)
            local nodeInfo
            if type == nil then return { type = 'none' }
            elseif type[1] == defaultTypes.treesitter then
                nodeInfo = { type = 'regular', language = type.lang, name = type.name }
            elseif type[1] == defaultTypes.languageRoot then
                nodeInfo = {
                    type = 'language_change',
                    from_language = (type.fromTree or {}).lang,
                    to_language = (type.toTree or {}).lang
                }
            elseif type[1] == defaultTypes.text then
                nodeInfo = { type = 'text' }
            else
                assert(false, vim.inspect(type))
            end
            return nodeInfo
        end

        self.info.isParentPart = parentPartFunction(convertType(type), convertType(parentType), self.info.isParentPart)
    end
end

function Node:createNode(treesNode)
    return self:updateNode{
        type = M.treesType(treesNode, self.langTree),
        info = { isParentPart = not treesNode:named() }, -- TODO: add 'range=' back
        hierarchy = {},
        orig = treesNode,
    }
end

function Node:updateNode(node)
    return setmetatable(vim.tbl_extend('keep', node, {
        langTree = self.langTree,
        config = self.config,
        source = self.source,
    }), getmetatable(self))
end

function Node:createLangRootNode(toTree, rootIndex)
    local rootTreesNode = toTree:parse()[rootIndex]:root()
    local parent = self:updateNode{
        type = { defaultTypes.languageRoot, fromTree = self.langTree, toTree = toTree },
        info = { isParentPart = false, range = M.treesNodeRange(rootTreesNode) },
        hierarchy = { children = {} },
        langTree = toTree,
    }
    parent:parseChild(rootTreesNode)
    parent:fixChildren()
    parent:setup()
    return parent
end

function Node:parseRegularNode(treesNode)
    local node = self:createNode(treesNode)
    local children
    setmetatable(node.hierarchy, {
        __index = function(_, key)
            if key == 'children' then
                if children == nil then
                    children = {}
                    --node.hierarchy.children = children

                    for child in treesNode:iter_children() do node:parseChild(child) end
                    node:fixChildren()
                end
                return children
            end
        end
    })
    node.info.range = M.treesNodeRange(treesNode)
    self:setup()
    table.insert(self.hierarchy.children, node)
end

function Node:parseSplitNode(treesNode, params)
    local origChildren = {}
    for child in treesNode:iter_children() do table.insert(origChildren, child) end
    if #origChildren == 0 then return false end

    local childI
    for i = 1, #origChildren do
        if params:splitAt(origChildren, i) then
            childI = i
            break
        end
    end

    if not childI then return false end

    if childI > 1 then
        local startNode = self:createNode(treesNode)
        startNode.hierarchy.children = {}
        for i = 1, childI-1 do
            startNode:parseChild(origChildren[i])
        end

        local children = startNode.hierarchy.children
        local fr = children[1].info.range
        local lr = children[#children].info.range

        startNode.info.range = { fr[1], fr[2], lr[3], lr[4] }
        startNode:fixChildren()
        startNode:setup()
        table.insert(self.hierarchy.children, startNode)
    end

    for i = childI, #origChildren do
        self:parseChild(origChildren[i])
    end

    return true
end

function Node:createTextNode()
    local node = self:updateNode{
        type = { defaultTypes.text },
        info = { range = { 0, 0, #self.source-1, math.huge }, isParentPart = false },
        hierarchy = { children = {} },
    }

    local lines = self.source
    if #lines == 0 then return node end

    for i, line in ipairs(lines) do
        local first = line:find('%S')
        local last  = line:reverse():find('%S') -- findlast
        if first ~= nil and last ~= nil then
            last = #line - last + 1
            local child = self:updateNode{
                type = { defaultTypes.text },
                info = {
                    range = { i-1, first-1, i-1, last-1 },
                    isParentPart = false
                },
                hierarchy = { children = {} },
            }
            child:setup()
            table.insert(node.hierarchy.children, child)
        end
    end

    node:fixChildren()
    node:setup()

    return node
end

function Node:parseTextNode(treesNode, textProperties)
    local node = self:createNode(treesNode)
    node.info.range = { utils.fixedRange(treesNode:range()) }
    node.hierarchy.children = {}
    local nodeRange = node.info.range
    local children = {}

    local boundaryLinesParent = false
    local isText = function(_nodeType, _context) return false end
    if type(textProperties) == 'table' then
        boundaryLinesParent = textProperties.boundaryLinesParent == true or boundaryLinesParent
        isText = textProperties.isText or isText
    end

    local text = vim.treesitter.get_node_text(treesNode, self.source)
    local lines = vim.split(text, "\n") -- pray to all gods that treesitter thinks the same of lines
    utils.assert2(#lines == nodeRange[3] - nodeRange[1] + 1, function() return
        "calculated line count = "..#lines.." for node of type `"..treesNode
        .."` must be consistent with treesitter range (" .. nodeRange[1]..', '..nodeRange[2]..', '
        ..nodeRange[3]..', '..nodeRange[4]..') line count = '.. (nodeRange[3] - nodeRange[1] + 1)
    end)

    local function textToNodes(startL, startC, endL, endC)
        local origRange = { startL, startC, endL, endC }
        startL = startL - nodeRange[1]
        endL = endL - nodeRange[1]
        if startL == 0 then
            startC = startC - nodeRange[2]
            if endL == startC then endC = endC - nodeRange[2] end
        end

        local curLines = {}
        for i=startL,endL do
            table.insert(curLines, lines[i+1])
        end
        utils.assert2(#curLines ~= 0, function() return 'incorrect range '..vim.inspect(origRange)..' for text node '..treesNode..' at '..vim.inspect(nodeRange) end)
        curLines[#curLines] = curLines[#curLines]:sub(1, endC+1)
        curLines[1] = curLines[1]:sub(startC+1)

        for i, line in ipairs(curLines) do
            local first = line:find('%S')
            local last  = line:reverse():find('%S') -- findlast
            if first ~= nil and last ~= nil then
                last = #line - last + 1
                local child = self:updateNode{
                    type = { defaultTypes.text },
                    info = {
                        range = {
                            origRange[1] + i-1,
                            origRange[2] + first-1,
                            origRange[1] + i-1,
                            origRange[2] + last-1,
                        },
                        isParentPart = false
                    },
                    hierarchy = { children = {} },
                }
                child:setup()
                table.insert(children, child)
            end
        end
    end

    local prevLine = nodeRange[1]
    local prevCol  = nodeRange[2]


    for child in treesNode:iter_children() do
        node:parseChild(child)
    end

    for _, child in ipairs(node.hierarchy.children) do
        if not isText(node, child) then
            local childSL, childSC, childEL, childEC = utils.unpack(child.info.range)
            textToNodes(prevLine, prevCol, childSL, childSC-1)
            table.insert(children, child)
            prevLine = childEL
            prevCol = childEC + 1
        end
    end
    textToNodes(prevLine, prevCol, nodeRange[3], nodeRange[4])

    if #children == 0 then return false end

    if boundaryLinesParent then
        children[1].info.isParentPart = true
        children[#children].info.isParentPart = true
    end

    node.hierarchy.children = children
    node:fixChildren()
    node:setup()
    table.insert(self.hierarchy.children, node)

    return true
end

local function findSubtreeForNode(tree, nodeRange)
    -- How do I check if LanguageTree is responsible for this range and get correct root node?
    for _, childTree in pairs(tree:children()) do
        local ranges = childTree:included_regions()
        for rangeIndex, ranges2 in pairs(ranges) do
            for _, range in pairs(ranges2) do -- ??? why is this a table of arrays of ranges
                if utils.isRangeInside(nodeRange, { range[1], range[2], range[4], range[5] }) then
                    return childTree, rangeIndex
                end
            end
        end
    end
end

function Node:parseChild(treesNode)
    if treesNode == nil then return end

    local nodeLangTree, rootIndex = findSubtreeForNode(self.langTree, { treesNode:range() })
    if nodeLangTree ~= nil then -- TODO: check if 2 nodes use same lang tree (should be impossible...)
        table.insert(self.hierarchy.children, self:createLangRootNode(nodeLangTree, rootIndex))
        return
    end

    local type = M.treesType(treesNode, self.langTree)
    local config = self.config[type.lang] or {}

    local splitProperties = (config.split or {})[type.name]
    if splitProperties and self:parseSplitNode(treesNode, {
            splitAt = function(_, children, i)
                return splitProperties[children[i]:type()]
            end
        }
    ) then return end
    local splitExtra = ((config.split or {})[1] or {}).extra
    if splitExtra and self:parseSplitNode(treesNode, {
            splitAt = function(_, children, i)
                local res = splitExtra(type.name, children[i]:type(), i, #children)
                if res then return true else return false end -- convert to bool
            end
        }
    ) then return end

    local textProperties = (config.text or {})[type.name]
    if textProperties and self:parseTextNode(
        treesNode, {
            boundaryLinesParent = (textProperties[1] or {}).boundary_lines_parent,
            isText = function(parentNode, childNode)
                if childNode.langTree == parentNode.langTree and childNode.type[1] == parentNode.type[1]
                    and childNode.type[1] == defaultTypes.treesitter then
                    return textProperties[childNode.type.name]
                end
            end
        }
    ) then return end

    self:parseRegularNode(treesNode)
end

-- properties = { function parseNode, function setupNode }
-- both functions can be called on nodes that don't end up in the final tree
M.createRoot = function(source, langTree, config)
    local hierarchy = { langTree = nil, source = source, config = config }
    setmetatable(hierarchy, { __index = Node })
    return hierarchy:createLangRootNode(langTree, 1)
end

--- @param source string[]
function M.createTextRoot(source, config)
    local hierarchy = { langTree = nil, source = source, config = config }
    setmetatable(hierarchy, { __index = Node })
    return hierarchy:createTextNode()
end

return M

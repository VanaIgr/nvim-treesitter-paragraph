local utils = require('utils')

local Wrapper = {}
Wrapper.__index = Wrapper

function Wrapper:new(o)
    if o == nil then o = {} end
    setmetatable(o, self)
    if o._parent ~= nil then
        local siblings = o._parent._children
        table.insert(siblings, o)
        o._position = #siblings
    end
    return o
end

local function calcChildrenRange(node)
    local range = utils.emptyRange()
    for child in node:childrenIter() do
        utils.addRange(range, child:range())
    end
    return range
end

local function findSubtreeForNode(tree, nodeRange)
    -- How do I check if LanguageTree is responsible for this range and get correct root node?
    for lang, childTree in pairs(tree:children()) do
        local ranges = childTree:included_regions()
        for rangeIndex, ranges2 in pairs(ranges) do
            for _, range in pairs(ranges2) do -- ??? why is this a table of arrays of ranges
                if utils.isRangeInside(nodeRange, { range[1], range[2], range[4], range[5] }) then
                    return childTree, lang, rangeIndex
                end
            end
        end
    end
end

function Wrapper:parseChild(node)
    if node == nil then return end

    local extra = self._extra

    local curTree = extra.tree
    local nodeTree, lang, rootIndex = findSubtreeForNode(curTree, { node:range() })
    if nodeTree ~= nil then
        local root = nodeTree:parse()[rootIndex]:root()
        local parent = Wrapper:new{
            _id = extra.idObj:createId(),
            _children = {},
            _parent = self,
            _range = { utils.fixedRange(node:range()) },
            _extra = {
                tree = nodeTree,
                lang = lang,
                languageProperties = extra.languageProperties,
                idObj = extra.idObj,
                source = extra.source
            },
        }
        parent:parseChild(root)
        parent._node = 'bob' .. #parent._children
        return
    end

    local nodeType = node:type()

    if nodeType == 'comment' then
        local nodeRange = { utils.fixedRange(node:range()) }

        print('^')

        local text = vim.treesitter.get_node_text(node, extra.source)
        local lines = vim.split(text, "\n") -- pray to all gods that treesitter thinks the same of lines
        -- why not return array of lines like nvim_buf_get_text ?
        if #lines ~= nodeRange[3] - nodeRange[1] + 1 then
            assert(
                false,
                "calculated line count = "..#lines.." inside node type `" .. nodeType 
                .. "` must be consistent with treesitter range (" .. nodeRange[1]..', '..nodeRange[2]..', '
                ..nodeRange[3]..', '..nodeRange[4]..') line count = '.. (nodeRange[3] - nodeRange[1] + 1)
            )
        end -- if assert just took error message as function

        local parent = Wrapper:new{ _id = extra.idObj:createId(), _parent = self, _extra = extra, _children = {}, _range = nodeRange }

        local lastNode
        for i, line in ipairs(lines) do
            local first = line:find('%S')
            local last  = line:reverse():find('%S')
            if first ~= nil and last ~= nil then
                last = #line - last + 1
                local node = Wrapper:new{ _id = extra.idObj:createId(), _parent = parent, _extra = extra, _children = {} }
                node._range = { nodeRange[1] + i-1, first, nodeRange[1] + i-1, last }
                if lastNode == nil then node._isParentPart = true end
                lastNode = node
            end
        end

        if lastNode ~= nil then lastNode._isParentPart = true end -- make first and last line be defining for the comment
        -- would be better if treesitter split the actual comment symbols into anonimous nodes

        return
    end

    local splitNodes = extra.languageProperties(extra.tree:lang()).splitNodes[nodeType]
    if splitNodes then
        local nodesToUpdate = {}

        local startNode = Wrapper:new{ _id = extra.idObj:createId(), _parent = self, _node = node, _children = {}, _extra = extra }
        table.insert(nodesToUpdate, startNode)

        for child in node:iter_children() do
            local childType = child:type()
            if splitNodes[childType] then
                local nextNode = Wrapper:new{ _id = extra.idObj:createId(), _parent = self, _node = child, _extra = extra }
                nextNode:_parseChildren()
                table.insert(nodesToUpdate, nextNode)
            else
                local lastNode = nodesToUpdate[#nodesToUpdate]
                lastNode:parseChild(child)
            end
        end

        for _, node in pairs(nodesToUpdate) do
            node._range = calcChildrenRange(node)
        end

        return
    end

    Wrapper:new{
        _id = extra.idObj:createId(),
        _node = node, _parent = self,
        _isParentPart = not node:named(),
        _range = { utils.fixedRange(node:range()) },
        _extra = extra,
    }
end

function Wrapper:_parseChildren()
    if self._children == nil then
        self._children = {}
        for child in self._node:iter_children() do self:parseChild(child) end
    end
    return self._children
end

function Wrapper:childrenIter()
    local children = self:_parseChildren()
    local count = #children
    local i = 0
    return function() if i < count then
        i = i + 1
        return children[i]
    end end
end
function Wrapper:range() return self._range end
function Wrapper:parent() return self._parent end
function Wrapper:parentPart() return self._isParentPart == true end
function Wrapper:prev()
    if self._parent == nil then return nil end
    return self._parent:_parseChildren()[self._position - 1]
end
function Wrapper:next()
    if self._parent == nil then return nil end
    return self._parent:_parseChildren()[self._position + 1]
end

function Wrapper:id() return self._id end

local function createIdObj()
    local obj = { 0 }
    function obj:createId()
        obj[1] = obj[1] + 1
        return obj[1]
    end
    return obj
end

return {
    createRoot = function(source, parser, languageProperties)
        local idObj = createIdObj()
        local parent = Wrapper:new({
            _children = {},
            _parent = nil,
            _extra = {
                tree = parser,
                lang = parser:lang(),
                languageProperties = languageProperties,
                idObj = idObj,
                source = source,
            },
            _id = idObj:createId()
        })
        parent:parseChild(parser:parse()[1]:root())
        parent._range = calcChildrenRange(parent)
        return parent
    end
}

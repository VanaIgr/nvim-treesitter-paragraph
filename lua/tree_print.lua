local M = {}

function M.printNode(indent, node)
    print(string.rep(' ', indent), node, node:type())
    for child in node:iter_children() do
        M.printNode(indent + 2, child)
    end
end


function M.printSubnode(indent, node)
    print(string.rep(' ', indent), node) --, 'missing:', node:missing(), 'extra:', node:extra(), 'err: ', node:has_error())
    for child in node:iter_children() do
        M.printSubnode(indent + 2, child)
    end
end

function M.printTree(indent, parser)
    local langs = parser:included_regions()
    print(string.rep(' ', indent), parser:lang())
    print(string.rep(' ', indent + 2), 'tree: ')
    local roots = parser:parse(true)
    for index, i in ipairs(roots) do
        print(string.rep(' ', indent + 4), 'subtree ', index, ': ')
        M.printSubnode(indent + 6, i:root())
    end
    print(string.rep(' ', indent + 2), 'ranges: ')
    for _, range in pairs(langs) do
        print(string.rep(' ', indent + 4), vim.inspect(range))
    end
    print(string.rep(' ', indent + 2), 'children: ')
    for _, child in pairs(parser:children()) do
        M.printTree(indent + 4, child)
    end
end

function M.printCurFileTree()
    local root = vim.treesitter.get_parser()
    M.printTree(0, root)
end

local _ = [=[ -- for quickly running current line as lua
vim.keymap.set('n', '#', require('tree_print').printCurFileTree)
]=]

return M

local function test()
assert(vim.g.school_profile, 'School profile did not load')
assert(vim.opt.wrap:get() and vim.opt.number:get() and vim.opt.relativenumber:get())
assert(vim.version().minor == 12 and vim.version().patch == 5)
local plugins = require('lazy.core.config').plugins
assert(plugins['telescope.nvim'] and plugins['oil.nvim'] and plugins['nvim-lspconfig'])
assert(not plugins['copilot.vim'] and not plugins['image.nvim'] and not plugins['vim-dadbod'])
assert(vim.fn.exists(':Html') == 0)
assert(vim.fn.exists(':Floaterminal') == 2)
assert(vim.fn.maparg('<leader>ff', 'n'):find('Telescope'))
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
vim.fn.writefile({'{}'}, root .. '/.clangd')
vim.fn.writefile({'{}'}, root .. '/.luarc.json')
vim.fn.system({'git', 'init', root})
local fixtures = {
  { name = 'main.c', server = 'clangd', parser = 'c', lines = {
      '#include <stdio.h>', 'int greet(void) { return 42; }', 'int main(void) { return greet(); }' }, row = 2, col = 27, invalid = {'int main(void) { invalid_name; }'} },
  { name = 'main.cpp', server = 'clangd', parser = 'cpp', lines = {
      '#include <vector>', 'int greet() { std::vector<int> x{42}; return x[0]; }', 'int main() { return greet(); }' }, row = 2, col = 24, invalid = {'int main() { invalid_name; }'} },
  { name = 'test.sh', server = 'bashls', parser = 'bash', lines = {
      '#!/usr/bin/env bash', 'greet() { printf hi; }', 'greet' }, row = 2, col = 4, invalid = {'#!/usr/bin/env bash', 'if true; then'} },
  { name = 'test.lua', server = 'lua_ls', parser = 'lua', lines = {
      'local function greet() return 42 end', 'local value = greet()', 'print(value)' }, row = 1, col = 18, invalid = {'local value ='} },
}
local commands = {}
for _, f in ipairs(fixtures) do
  if f.server == 'clangd' then
    commands[#commands + 1] = {directory = root, file = root .. '/' .. f.name,
      arguments = { f.parser == 'cpp' and 'g++' or 'gcc', f.parser == 'cpp' and '-std=c++20' or '-std=c11', '-c', root .. '/' .. f.name }}
  end
end
vim.fn.writefile({vim.json.encode(commands)}, root .. '/compile_commands.json')
for _, f in ipairs(fixtures) do
  local path = root .. '/' .. f.name
  vim.fn.writefile(f.lines, path)
  vim.cmd.edit(path)
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.wait(30000, function()
    for _, client in ipairs(vim.lsp.get_clients({bufnr = buf, name = f.server})) do
      if client.initialized then return true end
    end
  end, 50), 'LSP did not attach: ' .. f.server)
  local client = vim.lsp.get_clients({bufnr = buf, name = f.server})[1]
  local params = {textDocument = {uri = vim.uri_from_bufnr(buf)}, position = {line = f.row, character = f.col}}
  local definition
  assert(vim.wait(15000, function()
    definition = client:request_sync('textDocument/definition', params, 1000, buf)
    return definition and definition.result and not vim.tbl_isempty(definition.result)
  end, 100), 'No definition: ' .. f.name)
  params.context = {triggerKind = 1}
  local completion = client:request_sync('textDocument/completion', params, 15000, buf)
  assert(completion and completion.result, 'No completion response: ' .. f.name)
  local items = completion.result.items or completion.result
  assert(#items > 0, 'Empty completion: ' .. f.name)
  assert(vim.bo[buf].omnifunc == 'v:lua.vim.lsp.omnifunc')
  assert(vim.treesitter.get_parser(buf, f.parser):parse(), 'Parser failed: ' .. f.parser)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, f.invalid)
  assert(vim.wait(20000, function()
    for _, d in ipairs(vim.diagnostic.get(buf)) do
      if d.severity == vim.diagnostic.severity.ERROR then return true end
    end
  end, 100), 'No error diagnostics: ' .. f.name)
  vim.bo[buf].modified = false
  print('LSP verified: ' .. f.name .. ' definition, completion, diagnostics, parser')
end
for _, client in ipairs(vim.lsp.get_clients()) do client:stop(true) end
vim.fn.delete(root, 'rf')
end
local ok, err = xpcall(test, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end

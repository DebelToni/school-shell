vim.opt.rtp:prepend('/opt/my-vim-env/nvim')
vim.opt.rtp:prepend('/opt/nvim-plugins/nvim-treesitter')
local ts = require('nvim-treesitter')
ts.setup({ install_dir = '/opt/nvim-parsers' })
ts.install({ 'c', 'cpp', 'lua', 'bash' }):wait(300000)
for _, language in ipairs({ 'c', 'cpp', 'lua', 'bash' }) do
  assert(vim.uv.fs_stat('/opt/nvim-parsers/parser/' .. language .. '.so'), 'Missing parser: ' .. language)
end

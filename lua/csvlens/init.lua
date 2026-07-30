-- csvlens -- read-only, queryable views over a CSV.
--
-- :CsvLens              open a lens on the current CSV buffer
-- :CsvWhere cores == 64 filter rows (Python expression over column names)
-- :CsvSortBy exec_ns:desc,step
-- :CsvGroupBy cores     aggregate (see :CsvAgg for the available functions)
-- :CsvAgg exec_ns:mean,exec_ns:p95
-- :CsvCols step,core,exec_ns
-- :CsvLimit 200
-- :CsvOps               show the active pipeline
-- :CsvReset             clear all operations
--
-- Operations compose into a pipeline; each command replaces that one stage and
-- re-runs the query. The lens never writes -- the source file is only read.
-- Data work happens in scripts/csvlens.py (stdlib only, so system python3 is fine).

local M = {}

--- Directory this plugin is installed in, so the bundled script can be found
--- regardless of where the plugin manager put it on disk.
local function plugin_root()
  local source = debug.getinfo(1, 'S').source:match '^@(.*)$'
  return vim.fn.fnamemodify(source, ':h:h:h')
end

M.config = {
  script = plugin_root() .. '/scripts/csvlens.py',
  python = 'python3',
  limit = 500, -- default cap so a 45k-row file doesn't flood the buffer
}

local state = {} -- lens bufnr -> { src = path, ops = {...} }

local function build_args(st)
  local args = { st.src }
  local o = st.ops
  local function add(flag, val)
    if val and val ~= '' then
      table.insert(args, flag)
      table.insert(args, val)
    end
  end
  add('--where', o.where)
  add('--group', o.group)
  add('--agg', o.agg)
  add('--sort', o.sort)
  add('--cols', o.cols)
  add('--limit', tostring(o.limit or M.config.limit))
  return args
end

local function describe(st)
  local o, parts = st.ops, {}
  for _, k in ipairs { 'where', 'group', 'agg', 'sort', 'cols' } do
    if o[k] and o[k] ~= '' then
      table.insert(parts, k .. '=' .. o[k])
    end
  end
  table.insert(parts, 'limit=' .. tostring(o.limit or M.config.limit))
  return table.concat(parts, '  ')
end

local function refresh(buf)
  local st = state[buf]
  if not st then
    return
  end

  local cmd = { M.config.python, M.config.script }
  vim.list_extend(cmd, build_args(st))
  local out = vim.fn.systemlist(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify(table.concat(out, '\n'), vim.log.levels.ERROR, { title = 'csvlens' })
    return -- keep the previous good view on screen
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.b[buf].csvlens_status = ('%s  [%d rows]'):format(describe(st), math.max(#out - 1, 0))

  -- csvview is lazy-loaded on cmd; lazy.nvim's require hook pulls it in here.
  local ok, csvview = pcall(require, 'csvview')
  if ok and not csvview.is_enabled(buf) then
    pcall(csvview.enable, buf, { view = { display_mode = 'border' } })
  end
end

--- The lens to act on: the current buffer if it is one, else the newest lens.
local function current_lens()
  local buf = vim.api.nvim_get_current_buf()
  if state[buf] then
    return buf
  end
  for b in pairs(state) do
    if vim.api.nvim_buf_is_valid(b) then
      return b
    end
  end
  vim.notify('csvlens: no lens open (:CsvLens first)', vim.log.levels.WARN)
end

local function set_op(key)
  return function(o)
    local buf = current_lens()
    if not buf then
      return
    end
    state[buf].ops[key] = o.args ~= '' and o.args or nil
    refresh(buf)
  end
end

function M.open(src)
  src = src ~= '' and src or vim.api.nvim_buf_get_name(0)
  if src == '' or vim.fn.filereadable(src) == 0 then
    vim.notify('csvlens: not a readable file: ' .. src, vim.log.levels.ERROR)
    return
  end

  vim.cmd 'tabnew'
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'csv'
  vim.api.nvim_buf_set_name(buf, 'csvlens://' .. vim.fn.fnamemodify(src, ':t'))

  state[buf] = { src = src, ops = {} }
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function()
      state[buf] = nil
    end,
  })
  refresh(buf)
end

local commands_created = false

local function create_commands()
  if commands_created then
    return
  end
  commands_created = true

  vim.api.nvim_create_user_command('CsvLens', function(o)
    M.open(o.args)
  end, { nargs = '?', complete = 'file', desc = 'Open a read-only lens on [file] (defaults to the current buffer)' })

  vim.api.nvim_create_user_command(
    'CsvWhere',
    set_op 'where',
    { nargs = '*', desc = 'Filter lens rows by a Python expression over column names, e.g. cores == 64 and exec_ns > 5000' }
  )
  vim.api.nvim_create_user_command(
    'CsvSortBy',
    set_op 'sort',
    { nargs = '*', desc = 'Sort lens rows by col[:asc|desc], comma-separated; earlier keys take precedence' }
  )
  vim.api.nvim_create_user_command(
    'CsvGroupBy',
    set_op 'group',
    { nargs = '*', desc = 'Group lens rows by one or more columns, comma-separated (aggregated per :CsvAgg)' }
  )
  vim.api.nvim_create_user_command(
    'CsvAgg',
    set_op 'agg',
    { nargs = '*', desc = 'Aggregate col:func pairs for :CsvGroupBy, e.g. exec_ns:mean,exec_ns:p95' }
  )
  vim.api.nvim_create_user_command(
    'CsvCols',
    set_op 'cols',
    { nargs = '*', desc = 'Show only these columns, comma-separated, in this order' }
  )

  vim.api.nvim_create_user_command('CsvLimit', function(o)
    local buf = current_lens()
    if not buf then
      return
    end
    state[buf].ops.limit = tonumber(o.args)
    refresh(buf)
  end, { nargs = 1, desc = 'Cap the number of rows shown in the lens' })

  vim.api.nvim_create_user_command('CsvOps', function()
    local buf = current_lens()
    if buf then
      vim.notify(vim.b[buf].csvlens_status or describe(state[buf]), vim.log.levels.INFO)
    end
  end, { desc = 'Show the active lens pipeline (where/group/agg/sort/cols/limit)' })

  vim.api.nvim_create_user_command('CsvReset', function()
    local buf = current_lens()
    if not buf then
      return
    end
    state[buf].ops = {}
    refresh(buf)
  end, { desc = 'Clear all lens operations and re-show the raw CSV' })
end

--- Called by lazy.nvim (via `opts = {}` or a `config` function). Optional --
--- the commands are also created on require, so cmd-based lazy-loading works
--- even if a spec doesn't call setup() explicitly.
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  create_commands()
end

create_commands()

return M

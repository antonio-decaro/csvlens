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
-- :CsvSchema            list the source CSV's original columns (handy after
--                        :CsvGroupBy/:CsvCols narrows what's on screen)
-- :CsvPin               fork the current pipeline into a new, independent
--                        lens tab (same source, ops snapshotted); pin again
--                        on either tab for yet another copy
-- :CsvReset             clear all operations
-- :CsvShell             open an interactive shell for the lens (same verbs,
--                        one per line, with history and <Tab> completion).
--                        opts.shell_backend picks 'prompt' (default, pure
--                        Lua) or 'terminal' (scripts/csvlens_shell.py, native
--                        readline editing -- see the README's Shell section)
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
  shell = true, -- auto-open the interactive :CsvShell alongside each new lens
  shell_backend = 'prompt', -- or 'terminal' (scripts/csvlens_shell.py, native readline editing)
}

local state = {} -- lens bufnr -> { src = path, ops = {...}, fields = {...}, shell = bufnr?, owns_tmpfile = bool? }

local pin_seq = 0 -- disambiguates buffer names across repeated pins of the same lens
local pin_lens -- assigned near create_lens/M.open below; forward-declared
-- because _G.csvlens_apply and shell_dispatch (defined earlier in this
-- file) need to call it

--- `unbounded`, if truthy, omits --limit -- used by materialize() below to
--- capture every matching row for a pin, not just what's currently displayed.
local function build_args(st, unbounded)
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
  if not unbounded then
    add('--limit', tostring(o.limit or M.config.limit))
  end
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

--- Runs the pipeline and redraws the lens buffer. Returns true on success.
local function refresh(buf)
  local st = state[buf]
  if not st then
    return false
  end

  local cmd = { M.config.python, M.config.script }
  vim.list_extend(cmd, build_args(st))
  local out = vim.fn.systemlist(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify(table.concat(out, '\n'), vim.log.levels.ERROR, { title = 'csvlens' })
    return false -- keep the previous good view on screen
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  st.fields = out[1] and vim.split(out[1], ',', { plain = true }) or {}
  vim.b[buf].csvlens_status = ('%s  [%d rows]'):format(describe(st), math.max(#out - 1, 0))

  -- csvview is lazy-loaded on cmd; lazy.nvim's require hook pulls it in here.
  local ok, csvview = pcall(require, 'csvview')
  if ok and not csvview.is_enabled(buf) then
    pcall(csvview.enable, buf, { view = { display_mode = 'border' } })
  end

  return true
end

--- Runs `st`'s current pipeline with no row cap, for :CsvPin -- captures
--- every matching row, not just what's currently displayed under the
--- lens's row --limit. Returns (output_lines, ok).
local function materialize(st)
  local cmd = { M.config.python, M.config.script }
  vim.list_extend(cmd, build_args(st, true))
  local out = vim.fn.systemlist(cmd)
  return out, vim.v.shell_error == 0
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

-- These take the lens buffer explicitly so both the :Csv* ex-commands and the
-- :CsvShell REPL can drive the same pipeline without guessing "current lens".
local function apply_op(buf, key, val)
  state[buf].ops[key] = (val and val ~= '') and val or nil
  return refresh(buf)
end

local function apply_limit(buf, val)
  state[buf].ops.limit = tonumber(val)
  return refresh(buf)
end

local function apply_reset(buf)
  state[buf].ops = {}
  return refresh(buf)
end

--- The source file's original header, regardless of the current pipeline --
--- e.g. after :CsvGroupBy/:CsvCols has narrowed what's on screen, this still
--- lists every column available to build the next :CsvGroupBy/:CsvAgg/:CsvCols.
local function fetch_schema(buf)
  local st = state[buf]
  local cmd = { M.config.python, M.config.script, st.src, '--schema' }
  local out = vim.fn.systemlist(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify(table.concat(out, '\n'), vim.log.levels.ERROR, { title = 'csvlens' })
    return nil
  end

  return out[1] and vim.split(out[1], ',', { plain = true }) or {}
end

local function hex_decode(s)
  return (s:gsub('%x%x', function(b)
    return string.char(tonumber(b, 16))
  end))
end

--- Entry point for the terminal shell's IPC (scripts/csvlens_shell.py),
--- reached via `nvim --server $NVIM --remote-expr 'luaeval("csvlens_apply(...)")'`.
--- `--remote-expr` evaluates in *this* process, not the client's, so values
--- can't travel via env vars set on the client subprocess -- they have to be
--- embedded in the expression string itself. `op` is always one of a fixed
--- set of literals the Python script controls (safe to interpolate as-is);
--- `hexval` is the free-form user-typed argument, hex-encoded by the caller
--- so it can never contain a quote character that breaks the expression.
function _G.csvlens_apply(lens, op, hexval)
  lens = tonumber(lens)
  local val = hex_decode(hexval or '')
  if not (lens and state[lens]) then
    return 'csvlens: lens buffer is gone'
  end

  if op == 'schema' then
    local cols = fetch_schema(lens)
    return cols and table.concat(cols, ', ') or 'csvlens: error running query (see :messages)'
  end

  if op == 'fields' then
    -- the lens's *current* result columns, for the terminal shell's <Tab>
    -- completion -- unlike 'schema' above, this reflects :CsvGroupBy/:CsvCols
    return table.concat(state[lens].fields, ', ')
  end

  if op == 'pin' then
    return pin_lens(lens)
  end

  local ok
  if op == 'limit' then
    ok = apply_limit(lens, val)
  elseif op == 'reset' then
    ok = apply_reset(lens)
  elseif op == 'ops' then
    ok = true
  else
    ok = apply_op(lens, op, val)
  end

  return ok and (vim.b[lens].csvlens_status or describe(state[lens])) or 'csvlens: error running query (see :messages)'
end

local function set_op(key)
  return function(o)
    local buf = current_lens()
    if buf then
      apply_op(buf, key, o.args)
    end
  end
end

--- ------------------------------------------------------------------------
--- Shell: a prompt-buffer REPL bound to one lens, driving the same verbs as
--- the :Csv* ex-commands via apply_op/apply_limit/apply_reset above.
--- ------------------------------------------------------------------------

local OP_ALIASES = {
  where = 'where',
  w = 'where',
  sortby = 'sort',
  sort = 'sort',
  s = 'sort',
  groupby = 'group',
  group = 'group',
  g = 'group',
  agg = 'agg',
  a = 'agg',
  cols = 'cols',
  c = 'cols',
}

-- Mirrors AGGS in scripts/csvlens.py -- keep in sync.
local AGG_FUNCS = { 'count', 'sum', 'mean', 'median', 'min', 'max', 'p50', 'p95', 'p99', 'stdev', 'outliers' }

local SHELL_HELP = {
  "csvlens shell -- one command per line, 'help' for this message",
  '  where <expr>       filter rows, e.g. where cores == 64 and exec_ns > 5000',
  '                     is_outlier(col, by) flags rows off from their by-group,',
  '                     e.g. where is_outlier("exec_ns", by="cores")',
  '  sortby col[:desc]  sort rows, comma-separated, earlier keys win',
  '  groupby col,...    group rows by column(s)',
  '  agg col:func,...   aggregate for groupby, e.g. agg exec_ns:mean,exec_ns:p95',
  '  cols col,...       show only these columns, in order',
  '  limit N            cap the number of rows shown',
  '  ops                show the active pipeline',
  "  schema             list the source CSV's original columns (unaffected",
  '                     by groupby/cols -- useful for picking what to add next)',
  '  pin                fork the current pipeline into a new, independent',
  '                     lens tab (same source, ops snapshotted)',
  '  reset              clear all operations',
  '  close              close this shell and its lens tab',
  'aliases: w/sort+s, group+g, a, c, l, o, r, sc, p, q, h/?',
  '<Tab> completes commands and column names, <Up>/<Down> recall history.',
}

local shells = {} -- shell bufnr -> { lens = lens_bufnr, history = {...}, hist_idx = nil, stash = nil }

--- Closes the whole tab a lens (and its shell) live in -- used by the
--- shell's close/q, so quitting the shell doesn't leave an orphaned lens tab
--- behind. Falls back to just wiping the lens buffer if this is the last
--- remaining tab (:tabclose refuses to close the very last one).
local function close_lens_tab(lens)
  local win = vim.fn.bufwinid(lens)
  if win ~= -1 then
    vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(win))
  end
  if not pcall(vim.cmd, 'tabclose') and vim.api.nvim_buf_is_valid(lens) then
    vim.cmd('bwipeout! ' .. lens)
  end
end

local function shell_echo(shbuf, lines)
  if vim.api.nvim_buf_is_valid(shbuf) then
    vim.api.nvim_buf_set_lines(shbuf, -1, -1, false, lines)
  end
end

local function shell_dispatch(shbuf, lens, line)
  local sh = shells[shbuf]
  line = vim.trim(line)
  sh.hist_idx, sh.stash = nil, nil
  if line == '' then
    return
  end
  table.insert(sh.history, line)

  if not vim.api.nvim_buf_is_valid(lens) then
    shell_echo(shbuf, { 'csvlens: lens buffer is gone' })
    return
  end

  local cmd, rest = line:match '^(%S+)%s*(.*)$'
  cmd = cmd and cmd:lower() or ''

  local ok, status = true, nil -- luacheck: ignore 311 -- every branch below assigns status before use
  if OP_ALIASES[cmd] then
    ok = apply_op(lens, OP_ALIASES[cmd], rest)
    status = vim.b[lens].csvlens_status
  elseif cmd == 'limit' or cmd == 'l' then
    ok = apply_limit(lens, rest)
    status = vim.b[lens].csvlens_status
  elseif cmd == 'ops' or cmd == 'o' then
    status = vim.b[lens].csvlens_status or describe(state[lens])
  elseif cmd == 'reset' or cmd == 'r' then
    ok = apply_reset(lens)
    status = vim.b[lens].csvlens_status
  elseif cmd == 'schema' or cmd == 'sc' then
    local cols = fetch_schema(lens)
    ok, status = cols ~= nil, cols and table.concat(cols, ', ')
  elseif cmd == 'pin' or cmd == 'p' then
    status = pin_lens(lens)
  elseif cmd == 'help' or cmd == 'h' or cmd == '?' then
    shell_echo(shbuf, SHELL_HELP)
    return
  elseif cmd == 'close' or cmd == 'q' then
    vim.schedule(function()
      close_lens_tab(lens)
    end)
    return
  else
    shell_echo(shbuf, { ("csvlens: unknown command '%s' (try 'help')"):format(cmd) })
    return
  end

  shell_echo(shbuf, { ok and (status or '') or 'csvlens: error running query (see :messages)' })
end

--- Up (-1) recalls older entries, Down (1) newer, back to the in-progress line.
local function shell_recall(shbuf, dir)
  local sh = shells[shbuf]
  local prompt = vim.fn.prompt_getprompt(shbuf)

  if dir < 0 then
    if #sh.history == 0 then
      return
    end
    if sh.hist_idx == nil then
      sh.stash = vim.api.nvim_get_current_line():sub(#prompt + 1)
      sh.hist_idx = #sh.history + 1
    end
    sh.hist_idx = math.max(1, sh.hist_idx - 1)
  else
    if sh.hist_idx == nil then
      return
    end
    sh.hist_idx = sh.hist_idx + 1
  end

  local text
  if sh.hist_idx == nil or sh.hist_idx > #sh.history then
    text = sh.stash or ''
    sh.hist_idx = nil
  else
    text = sh.history[sh.hist_idx]
  end

  local lastnr = vim.api.nvim_buf_line_count(shbuf)
  vim.api.nvim_buf_set_lines(shbuf, lastnr - 1, lastnr, false, { prompt .. text })
  vim.api.nvim_win_set_cursor(0, { lastnr, #prompt + #text })
end

--- <Tab> completion: command names for the first word, else column names
--- (or agg funcs / asc|desc right after a ':'), sourced from the lens's
--- last query result so it always matches what's on screen right now.
local function shell_complete(shbuf, lens)
  local prompt = vim.fn.prompt_getprompt(shbuf)
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local input = vim.api.nvim_get_current_line():sub(#prompt + 1, col)

  local delim_at, sep = 0, nil
  for i = #input, 1, -1 do
    local ch = input:sub(i, i)
    if ch == ' ' or ch == ',' or ch == ':' then
      delim_at, sep = i, ch
      break
    end
  end

  local candidates
  if delim_at == 0 then
    candidates = vim.tbl_keys(OP_ALIASES)
    vim.list_extend(candidates, { 'limit', 'ops', 'schema', 'pin', 'reset', 'help', 'close' })
  else
    local cmd = OP_ALIASES[(input:match '^(%S+)') or '']
    if cmd == 'agg' and sep == ':' then
      candidates = vim.list_extend({}, AGG_FUNCS)
    elseif cmd == 'sort' and sep == ':' then
      candidates = { 'asc', 'desc' }
    else
      candidates = vim.list_extend({}, (state[lens] or {}).fields or {})
    end
  end
  -- complete() only auto-filters characters typed *after* this call, so
  -- narrow to what's already typed in the current token ourselves.
  local partial = input:sub(delim_at + 1):lower()
  if partial ~= '' then
    local matches = {}
    for _, c in ipairs(candidates) do
      if c:lower():sub(1, #partial) == partial then
        table.insert(matches, c)
      end
    end
    candidates = matches
  end
  table.sort(candidates)

  vim.fn.complete(#prompt + delim_at + 1, candidates)
end

--- Shared by both shell backends: if a shell buffer already exists for this
--- lens, refocus (or re-split into) its window instead of creating another.
--- Returns true if it handled things, false if the caller must create one.
local function focus_existing_shell(lens)
  local existing = state[lens].shell
  if not (existing and vim.api.nvim_buf_is_valid(existing)) then
    return false
  end
  local win = vim.fn.bufwinid(existing)
  if win == -1 then
    vim.cmd 'belowright 3split'
    vim.api.nvim_win_set_buf(0, existing)
  else
    vim.api.nvim_set_current_win(win)
  end
  vim.cmd 'startinsert'
  return true
end

local function open_prompt_shell(lens)
  if not state[lens] or focus_existing_shell(lens) then
    return
  end

  vim.cmd 'belowright 3split'
  local shbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, shbuf)
  vim.bo[shbuf].buftype = 'prompt'
  vim.bo[shbuf].bufhidden = 'wipe'
  vim.bo[shbuf].swapfile = false
  vim.api.nvim_buf_set_name(shbuf, 'csvlens://shell/' .. lens)

  shells[shbuf] = { lens = lens, history = {} }
  state[lens].shell = shbuf

  vim.fn.prompt_setprompt(shbuf, 'csv> ')
  vim.fn.prompt_setcallback(shbuf, function(text)
    shell_dispatch(shbuf, lens, text)
    -- Neovim drops prompt buffers back to Normal mode after each submit;
    -- re-enter Insert so the shell reads as a continuous REPL.
    if vim.api.nvim_buf_is_valid(shbuf) then
      vim.cmd 'startinsert'
    end
  end)

  vim.keymap.set('i', '<Up>', function()
    shell_recall(shbuf, -1)
  end, { buffer = shbuf })
  vim.keymap.set('i', '<Down>', function()
    shell_recall(shbuf, 1)
  end, { buffer = shbuf })
  vim.keymap.set('i', '<Tab>', function()
    shell_complete(shbuf, lens)
  end, { buffer = shbuf })
  vim.keymap.set('n', 'q', function()
    close_lens_tab(lens)
  end, { buffer = shbuf })

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = shbuf,
    callback = function()
      shells[shbuf] = nil
      if state[lens] then
        state[lens].shell = nil
      end
    end,
  })

  -- Neovim leaves prompt buffers in Normal mode when they're not focused;
  -- jump straight back into Insert whenever the shell is (re)entered so the
  -- only way to see Normal mode here is a deliberate <Esc>.
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    buffer = shbuf,
    command = 'startinsert!',
  })

  shell_echo(shbuf, { "csvlens shell -- type 'help' for commands" })
  vim.cmd 'startinsert'
end

--- The other :CsvShell backend: a real terminal running scripts/csvlens_shell.py
--- (stdlib cmd.Cmd + readline), which talks back to _G.csvlens_apply above via
--- `nvim --server $NVIM --remote-expr`. Buys native line editing/history at the
--- cost of a subprocess round trip per command and a soft readline dependency.
local function open_terminal_shell(lens)
  if not state[lens] or focus_existing_shell(lens) then
    return
  end

  vim.cmd 'belowright 10split'
  local shbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, shbuf) -- avoid reusing the current (lens) buffer,
  state[lens].shell = shbuf -- same bug as the prompt shell hit

  local script = plugin_root() .. '/scripts/csvlens_shell.py'
  vim.fn.termopen({ M.config.python, script, tostring(lens) }, {
    on_exit = vim.schedule_wrap(function()
      close_lens_tab(lens)
    end),
  })
  -- termopen() names the buffer itself (term://...); reclaim a predictable
  -- name afterward so tooling/other code can recognize a csvlens shell.
  pcall(vim.api.nvim_buf_set_name, shbuf, 'csvlens://shell/' .. lens)
  vim.bo[shbuf].bufhidden = 'wipe'

  vim.keymap.set('t', '<Esc>', [[<C-\><C-n>]], { buffer = shbuf })
  vim.keymap.set('n', 'q', function()
    close_lens_tab(lens)
  end, { buffer = shbuf })

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = shbuf,
    callback = function()
      if state[lens] then
        state[lens].shell = nil
      end
    end,
  })
  -- Same fix as the prompt shell: terminal buffers also drop to
  -- Terminal-Normal when unfocused, so re-enter on every (re)focus.
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    buffer = shbuf,
    command = 'startinsert!',
  })

  vim.cmd 'startinsert'
end

local function open_shell(lens)
  if M.config.shell_backend == 'terminal' then
    open_terminal_shell(lens)
  else
    open_prompt_shell(lens)
  end
end

--- Shared by M.open and pin_lens: creates the scratch buffer/tab for a lens
--- over `src` with a given starting `ops`, wires up its BufWipeout cleanup,
--- runs the first query, and opens its shell if configured. `name_suffix` (if
--- given) is appended to the buffer name to disambiguate pinned copies.
--- `display_name`, if given, is used instead of `src`'s own basename -- a
--- pinned lens's real `src` is a scratch temp file, but its buffer name
--- should still read like the original file it was pinned from.
local function create_lens(src, ops, name_suffix, display_name)
  vim.cmd 'tabnew'
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'csv'
  vim.api.nvim_buf_set_name(buf, 'csvlens://' .. (display_name or vim.fn.fnamemodify(src, ':t')) .. (name_suffix or ''))

  state[buf] = { src = src, ops = vim.tbl_extend('force', {}, ops), fields = {} }
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function()
      local st = state[buf]
      state[buf] = nil
      if st and st.owns_tmpfile then
        vim.fn.delete(st.src)
      end
      if st and st.shell and vim.api.nvim_buf_is_valid(st.shell) then
        vim.cmd('bwipeout! ' .. st.shell)
      end
    end,
  })
  refresh(buf)

  if M.config.shell then
    open_shell(buf)
  end

  return buf
end

--- Forks a lens's current pipeline into a brand-new, independent lens tab:
--- materializes the FULL current result set (ignoring the row --limit) into
--- a scratch temp file and opens a fresh lens over *that* file with an empty
--- pipeline. The pinned tab's "raw data" already reflects whatever
--- where/groupby/agg/etc it was pinned with, so any further query on it
--- narrows within that fixed dataset -- neither tab affects the other.
pin_lens = function(buf)
  local st = state[buf]
  local out, ok = materialize(st)
  if not ok then
    vim.notify(table.concat(out, '\n'), vim.log.levels.ERROR, { title = 'csvlens' })
    return 'csvlens: error running query (see :messages)'
  end

  local tmpfile = vim.fn.tempname() .. '.csv'
  vim.fn.writefile(out, tmpfile)

  pin_seq = pin_seq + 1
  local newbuf = create_lens(tmpfile, {}, '#pin' .. pin_seq, vim.fn.fnamemodify(st.src, ':t'))
  state[newbuf].owns_tmpfile = true

  return ('pinned -> tab %d: %s'):format(vim.fn.tabpagenr(), vim.api.nvim_buf_get_name(newbuf))
end

function M.open(src)
  src = src ~= '' and src or vim.api.nvim_buf_get_name(0)
  if src == '' or vim.fn.filereadable(src) == 0 then
    vim.notify('csvlens: not a readable file: ' .. src, vim.log.levels.ERROR)
    return
  end

  create_lens(src, {})
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
    if buf then
      apply_limit(buf, o.args)
    end
  end, { nargs = 1, desc = 'Cap the number of rows shown in the lens' })

  vim.api.nvim_create_user_command('CsvOps', function()
    local buf = current_lens()
    if buf then
      vim.notify(vim.b[buf].csvlens_status or describe(state[buf]), vim.log.levels.INFO)
    end
  end, { desc = 'Show the active lens pipeline (where/group/agg/sort/cols/limit)' })

  vim.api.nvim_create_user_command('CsvSchema', function()
    local buf = current_lens()
    if buf then
      local cols = fetch_schema(buf)
      if cols then
        vim.notify(table.concat(cols, ', '), vim.log.levels.INFO, { title = 'csvlens: original columns' })
      end
    end
  end, { desc = "List the source CSV's original columns, unaffected by :CsvGroupBy/:CsvCols" })

  vim.api.nvim_create_user_command('CsvPin', function()
    local buf = current_lens()
    if buf then
      vim.notify(pin_lens(buf), vim.log.levels.INFO, { title = 'csvlens' })
    end
  end, { desc = "Fork the lens's current pipeline into a new, independent lens tab (same source, ops snapshotted)" })

  vim.api.nvim_create_user_command('CsvReset', function()
    local buf = current_lens()
    if buf then
      apply_reset(buf)
    end
  end, { desc = 'Clear all lens operations and re-show the raw CSV' })

  vim.api.nvim_create_user_command('CsvShell', function()
    local buf = current_lens()
    if buf then
      open_shell(buf)
    end
  end, { desc = 'Open an interactive shell for the lens (where/sortby/groupby/agg/cols/limit/ops/reset)' })
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

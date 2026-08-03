local eq = assert.are.same

local function write_csv(rows)
  local path = vim.fn.tempname() .. '.csv'
  local fh = assert(io.open(path, 'w'))
  fh:write(table.concat(rows, '\n') .. '\n')
  fh:close()
  return path
end

local function buf_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

describe('csvlens', function()
  local csvlens = require 'csvlens'
  local csv_path

  before_each(function()
    csvlens.setup { shell = false }
    csv_path = write_csv {
      'cores,exec_ns',
      '64,100',
      '64,300',
      '64,500',
      '32,999',
    }
  end)

  after_each(function()
    vim.cmd 'silent! tabonly!'
    vim.cmd 'silent! %bwipeout!'
    os.remove(csv_path)
  end)

  it('opens a lens showing the header and all rows', function()
    csvlens.open(csv_path)
    eq({ 'cores,exec_ns', '64,100', '64,300', '64,500', '32,999' }, buf_lines())
  end)

  it('filters rows with :CsvWhere', function()
    csvlens.open(csv_path)
    vim.cmd 'CsvWhere cores == 64'
    eq({ 'cores,exec_ns', '64,100', '64,300', '64,500' }, buf_lines())
  end)

  it('sorts rows with :CsvSortBy', function()
    csvlens.open(csv_path)
    vim.cmd 'CsvSortBy exec_ns:desc'
    eq({ 'cores,exec_ns', '32,999', '64,500', '64,300', '64,100' }, buf_lines())
  end)

  it('groups and aggregates with :CsvGroupBy/:CsvAgg', function()
    csvlens.open(csv_path)
    vim.cmd 'CsvGroupBy cores'
    vim.cmd 'CsvAgg exec_ns:sum'
    -- grouped rows are auto-sorted by the group key when no explicit sort is set
    eq({ 'cores,n,exec_ns_sum', '32,1,999', '64,3,900' }, buf_lines())
  end)

  it('clears the pipeline with :CsvReset', function()
    csvlens.open(csv_path)
    vim.cmd 'CsvWhere cores == 64'
    vim.cmd 'CsvReset'
    eq({ 'cores,exec_ns', '64,100', '64,300', '64,500', '32,999' }, buf_lines())
  end)

  it('does not open a lens for a nonexistent file', function()
    local tabs_before = #vim.api.nvim_list_tabpages()
    csvlens.open '/no/such/file.csv'
    eq(tabs_before, #vim.api.nvim_list_tabpages())
  end)
end)

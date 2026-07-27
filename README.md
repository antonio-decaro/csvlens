# csvlens

Nvim plugin to visualize and manage CSV files: read-only, queryable lens
views over a CSV, backed by a stdlib-only Python script so no venv/pandas
setup is required.

`:CsvLens` opens a scratch buffer showing the CSV; `:CsvWhere`, `:CsvSortBy`,
`:CsvGroupBy`, `:CsvAgg`, `:CsvCols`, and `:CsvLimit` each set one stage of a
pipeline and re-run the query. The source file is only ever read, never
written.

## Requirements

- Neovim >= 0.9
- `python3` on `$PATH` (stdlib only — no extra Python packages needed)
- [csvview.nvim](https://github.com/hat-org/csvview.nvim) (optional) — if
  installed, lens buffers are rendered with aligned/bordered columns

## Installation ([lazy.nvim](https://github.com/folke/lazy.nvim))

```lua
{
  'antonio-decaro/csvlens',
  cmd = { 'CsvLens', 'CsvWhere', 'CsvSortBy', 'CsvGroupBy', 'CsvAgg', 'CsvCols', 'CsvLimit', 'CsvOps', 'CsvReset' },
  opts = {
    -- python = 'python3',
    -- limit = 500,
  },
}
```

`opts = {}` makes lazy.nvim call `require('csvlens').setup(opts)` once the
plugin loads, and `cmd = {...}` defers loading until one of the commands is
actually run. Both are optional: the plugin also registers its commands as
soon as it's required, so a bare `{ 'antonio-decaro/csvlens' }` works too.

## Usage

```
:CsvLens                     open a lens on the current CSV buffer
:CsvWhere cores == 64        filter rows (Python expression over column names)
:CsvSortBy exec_ns:desc,step
:CsvGroupBy cores            aggregate (see :CsvAgg for available functions)
:CsvAgg exec_ns:mean,exec_ns:p95
:CsvCols step,core,exec_ns
:CsvLimit 200
:CsvOps                      show the active pipeline
:CsvReset                    clear all operations
```

Each command replaces that one stage of the pipeline and re-runs the query
against the original file, so operations can be layered and revised in any
order.

## Configuration

```lua
require('csvlens').setup {
  python = 'python3',  -- interpreter used to run scripts/csvlens.py
  limit = 500,          -- default row cap per lens
}
```

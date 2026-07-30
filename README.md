# csvlens

Nvim plugin to visualize and manage CSV files: read-only, queryable lens
views over a CSV, backed by a stdlib-only Python script so no venv/pandas
setup is required.

`:CsvLens` opens a scratch buffer showing the CSV; `:CsvWhere`, `:CsvSortBy`,
`:CsvGroupBy`, `:CsvAgg`, `:CsvCols`, and `:CsvLimit` each set one stage of a
pipeline and re-run the query. The source file is only ever read, never
written.

`:CsvLens` also opens `:CsvShell`, a small REPL below the lens where you type
the same verbs one per line (`where cores == 64`, `agg exec_ns:mean`, ...)
instead of separate ex-commands, with `<Tab>` completion and `<Up>`/`<Down>`
history.

## Requirements

- Neovim >= 0.9
- `python3` on `$PATH` (stdlib only — no extra Python packages needed)
- [csvview.nvim](https://github.com/hat0uma/csvview.nvim) (optional) — if
  installed, lens buffers are rendered with aligned/bordered columns

## Installation ([lazy.nvim](https://github.com/folke/lazy.nvim))

```lua
{
  'antonio-decaro/csvlens',
  cmd = {
    'CsvLens', 'CsvWhere', 'CsvSortBy', 'CsvGroupBy', 'CsvAgg', 'CsvCols',
    'CsvLimit', 'CsvOps', 'CsvReset', 'CsvShell',
  },
  dependencies = {
    'hat0uma/csvview.nvim', -- optional, for aligned/bordered column rendering
  },
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
:CsvWhere is_outlier("exec_ns", by="cores")
                              keep only rows off from their by-group (see below)
:CsvSortBy exec_ns:desc,step
:CsvGroupBy cores            aggregate (see :CsvAgg for available functions)
:CsvAgg exec_ns:mean,exec_ns:p95
                              (functions: count, sum, mean, median, min, max,
                              p50, p95, p99, stdev, outliers)
:CsvCols step,core,exec_ns
:CsvLimit 200
:CsvOps                      show the active pipeline
:CsvReset                    clear all operations
:CsvShell                    open/focus the interactive shell for the lens
```

Each command replaces that one stage of the pipeline and re-runs the query
against the original file, so operations can be layered and revised in any
order.

`outliers` flags values more than 1.5*IQR outside a group's quartiles (Tukey's
fences) and lists them pipe-separated in the cell, e.g. `exec_ns:outliers`
next to `exec_ns:mean` shows which rows pulled a group's average off. That's a
summary, though — it collapses each group into one row. To see the full
outlier rows themselves (every column intact), use `is_outlier(col, by)`
inside `--where`/`where` instead:

```
:CsvWhere is_outlier("exec_ns", by="cores")
:CsvWhere is_outlier("exec_ns", by=("cores", "arch")) and arch == "arm"
```

Same Tukey's-fences method as the agg function. `by` is a column name or a
tuple of them (multi-column group); both `col` and `by` must be quoted string
literals, since `--where` compiles its expression and evaluates column names
to their row values before the call happens, so `is_outlier` never sees the
bare names, only quoted strings tell it which columns to use. It composes
like any other `--where` condition (`and`/`or`/`not`, mixed with plain
comparisons).

## Shell

`:CsvShell` opens a small prompt-buffer split bound to the lens it was called
from, so the same verbs above can be typed one per line instead of as
separate ex-commands:

```
csv> where cores == 64 and exec_ns > 5000
csv> groupby cores
csv> agg exec_ns:mean,exec_ns:p95
csv> ops
```

Short aliases work too (`w`, `sort`/`s`, `group`/`g`, `a`, `c`, `l`, `o`, `r`,
`q`, `h`/`?`). `<Tab>` completes command names, column names (sourced from the
lens's current result set), agg functions, and sort directions; `<Up>`/`<Down>`
recall previous commands. `help` lists the full command set, `close` (or `q`
in Normal mode) closes the shell without touching the lens. Closing the lens
closes its shell too.

### Terminal backend

Set `shell_backend = 'terminal'` to get `:CsvShell` as a real `:terminal`
buffer running `scripts/csvlens_shell.py` instead of the prompt buffer above.
Same commands and aliases, but editing/history come from Python's stdlib
`readline` (via `cmd.Cmd`) rather than a hand-rolled implementation, so you
get native `Ctrl-A`/`E`/`W`, kill-ring, etc. for free.

Tradeoffs versus the default:
- Each command spawns a short-lived `nvim --server $NVIM --remote-expr`
  subprocess to apply itself and fetch the pipeline status back (typically
  well under 100ms, but it's a real process spawn per command, not an
  in-process call).
- `<Tab>` only completes command names in this backend (via `cmd.Cmd`, for
  free); column-name/agg-func completion is prompt-buffer-only for now.
- Needs `readline` importable in your `python3` — most installs have it, but
  if not, the shell still works, just without arrow-key history/editing
  (it prints a one-line warning on startup when this happens).
- Needs the `nvim` binary reachable on `$PATH` from inside Neovim's own
  job environment (true by construction, since the job is spawned by Neovim
  itself) and `$NVIM` set, which Neovim does automatically for every
  `:terminal` job.

## Configuration

```lua
require('csvlens').setup {
  python = 'python3',       -- interpreter used to run scripts/csvlens.py
  limit = 500,               -- default row cap per lens
  shell = true,               -- auto-open :CsvShell alongside each new :CsvLens
  shell_backend = 'prompt',    -- or 'terminal', see "Terminal backend" above
}
```

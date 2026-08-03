#!/usr/bin/env python3
"""Interactive line-editing front end for csvlens, run inside a Neovim :terminal.

    csvlens_shell.py LENS_BUFNR

This is the 'terminal' :CsvShell backend (opts.shell_backend = 'terminal'):
it owns interactive editing only (via the stdlib cmd.Cmd + readline), and
talks back to the parent Neovim over `nvim --server $NVIM --remote-expr` to
apply each command, calling into the csvlens_apply() Lua function the plugin
registers. All pipeline state and the actual CSV query stay in Neovim /
scripts/csvlens.py -- this script never touches the file itself.

$NVIM is set automatically by Neovim inside every :terminal job, pointing at
the parent's RPC socket. Arguments are hex-encoded before being embedded in
the --remote-expr string so a --where expression containing a quote can't
break the generated Lua source (see csvlens_apply's docstring in init.lua).

Stdlib only, same reasoning as csvlens.py: no venv required.
"""

import binascii
import cmd
import os
import subprocess
import sys

# Mirrors AGGS in csvlens.py -- keep in sync.
AGG_FUNCS = [
    "count",
    "sum",
    "mean",
    "median",
    "min",
    "max",
    "p50",
    "p95",
    "p99",
    "stdev",
    "outliers",
]


def remote_expr(nvim_addr, expr):
    try:
        r = subprocess.run(
            ["nvim", "--server", nvim_addr, "--remote-expr", expr],
            stdin=subprocess.DEVNULL,  # otherwise it inherits our pty and both
            capture_output=True,  # this client's own tty-capability probing and
            text=True,  # our readline race to read the escape-sequence replies
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"csvlens: could not reach Neovim ({e})"
    return r.stdout.strip() or r.stderr.strip()


class Shell(cmd.Cmd):
    intro = "csvlens shell -- type 'help' for commands"
    prompt = "csv> "

    def __init__(self, nvim_addr, lens):
        super().__init__()
        self.nvim_addr = nvim_addr
        self.lens = lens

    def _apply(self, op, arg):
        hexval = binascii.hexlify(arg.encode()).decode()
        expr = f'luaeval("csvlens_apply({self.lens}, \'{op}\', \'{hexval}\')")'
        print(remote_expr(self.nvim_addr, expr))

    def _fields(self):
        """The lens's current result columns, fetched fresh over the same
        nvim --server round trip every other command already pays here."""
        expr = f'luaeval("csvlens_apply({self.lens}, \'fields\', \'\')")'
        result = remote_expr(self.nvim_addr, expr)
        if not result or result.startswith("csvlens:"):
            return []
        return [c.strip() for c in result.split(",")]

    def _complete_fields(self, text, line, begidx, endidx, colon_candidates=None):
        """Shared by every column-taking verb below: column names normally,
        or `colon_candidates` (agg funcs / asc|desc) right after a ':'."""
        prev_char = line[begidx - 1] if begidx > 0 else ""
        candidates = (
            colon_candidates
            if (prev_char == ":" and colon_candidates)
            else self._fields()
        )
        return [c for c in candidates if c.lower().startswith(text.lower())]

    def do_where(self, arg):
        """where <expr>       filter rows, e.g. cores == 64, or is_outlier("exec_ns", by="cores")"""
        self._apply("where", arg)

    do_w = do_where

    def complete_where(self, text, line, begidx, endidx):
        return self._complete_fields(text, line, begidx, endidx)

    complete_w = complete_where

    def do_sortby(self, arg):
        """sortby col[:desc]  sort rows, comma-separated, earlier keys win"""
        self._apply("sort", arg)

    do_sort = do_sortby
    do_s = do_sortby

    def complete_sortby(self, text, line, begidx, endidx):
        return self._complete_fields(
            text, line, begidx, endidx, colon_candidates=["asc", "desc"]
        )

    complete_sort = complete_sortby
    complete_s = complete_sortby

    def do_groupby(self, arg):
        """groupby col,...    group rows by column(s)"""
        self._apply("group", arg)

    do_group = do_groupby
    do_g = do_groupby

    def complete_groupby(self, text, line, begidx, endidx):
        return self._complete_fields(text, line, begidx, endidx)

    complete_group = complete_groupby
    complete_g = complete_groupby

    def do_agg(self, arg):
        """agg col:func,...   aggregate for groupby, e.g. agg exec_ns:mean,exec_ns:p95"""
        self._apply("agg", arg)

    do_a = do_agg

    def complete_agg(self, text, line, begidx, endidx):
        return self._complete_fields(
            text, line, begidx, endidx, colon_candidates=AGG_FUNCS
        )

    complete_a = complete_agg

    def do_cols(self, arg):
        """cols col,...       show only these columns, in order"""
        self._apply("cols", arg)

    do_c = do_cols

    def complete_cols(self, text, line, begidx, endidx):
        return self._complete_fields(text, line, begidx, endidx)

    complete_c = complete_cols

    def do_limit(self, arg):
        """limit N            cap the number of rows shown"""
        self._apply("limit", arg)

    do_l = do_limit

    def do_ops(self, arg):
        """ops                show the active pipeline"""
        self._apply("ops", arg)

    do_o = do_ops

    def do_schema(self, arg):
        """schema             list the source CSV's original columns (unaffected
        by groupby/cols -- useful for picking what to add next)"""
        self._apply("schema", arg)

    do_sc = do_schema

    def do_pin(self, arg):
        """pin                fork the current pipeline into a new, independent
        lens tab (same source, ops snapshotted)"""
        self._apply("pin", arg)

    do_p = do_pin

    def do_reset(self, arg):
        """reset              clear all operations"""
        self._apply("reset", arg)

    do_r = do_reset

    def do_close(self, arg):
        """close              close this shell and its lens tab"""
        return True

    do_q = do_close

    def do_EOF(self, arg):
        print()
        return True

    def default(self, line):
        print(f"csvlens: unknown command '{line.split()[0]}' (try 'help')")

    def emptyline(self):
        pass  # stock cmd.Cmd re-runs the last command on a bare <CR>; we don't want that


def main():
    if len(sys.argv) < 2:
        sys.exit("csvlens_shell: usage: csvlens_shell.py LENS_BUFNR")
    lens = sys.argv[1]

    nvim_addr = os.environ.get("NVIM")
    if not nvim_addr:
        sys.exit("csvlens_shell: $NVIM is not set (must run inside a Neovim :terminal)")

    try:
        import readline  # side-effect import wires up cmd.Cmd's line editing

        # Column lists/agg specs are comma- and colon-separated (cols a,b,c,
        # sortby col:desc); add those to the default word-break characters so
        # <Tab> completes just the token under the cursor, not the whole arg.
        readline.set_completer_delims(readline.get_completer_delims() + ",:")
    except ImportError:
        print("csvlens: readline unavailable -- arrow-key history/editing disabled")

    shell = Shell(nvim_addr, lens)
    while True:
        try:
            shell.cmdloop()
            break
        except KeyboardInterrupt:
            print()  # Ctrl-C clears the current line and restarts, like a real shell


if __name__ == "__main__":
    main()

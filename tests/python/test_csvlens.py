import subprocess
import sys

import csvlens
import pytest

SCRIPT = csvlens.__file__


# -- coerce ------------------------------------------------------------------


def test_coerce_int():
    assert csvlens.coerce("5") == 5


def test_coerce_float():
    assert csvlens.coerce("5.5") == 5.5


def test_coerce_passthrough():
    assert csvlens.coerce("abc") == "abc"


def test_coerce_empty_string():
    assert csvlens.coerce("") == ""


# -- percentile ----------------------------------------------------------------


def test_percentile_empty():
    assert csvlens.percentile([], 0.5) == ""


def test_percentile_single():
    assert csvlens.percentile([7], 0.5) == 7


def test_percentile_median_interpolated():
    assert csvlens.percentile([1, 2, 3, 4], 0.5) == 2.5


# -- iqr_bounds / outliers ----------------------------------------------------


def test_iqr_bounds_needs_at_least_four_samples():
    assert csvlens.iqr_bounds([1, 2, 3]) is None


def test_iqr_bounds_known_dataset():
    lo, hi = csvlens.iqr_bounds([1, 2, 3, 4, 5, 100])
    assert lo == pytest.approx(-1.5)
    assert hi == pytest.approx(8.5)


def test_outliers_flags_only_values_outside_fences():
    assert csvlens.outliers([1, 2, 3, 4, 5, 100]) == "100"


def test_outliers_empty_when_too_few_samples():
    assert csvlens.outliers([1, 2, 3]) == ""


# -- apply_where ---------------------------------------------------------------


def test_apply_where_filters_rows():
    rows = [{"cores": 64, "exec_ns": 100}, {"cores": 32, "exec_ns": 50}]
    out = csvlens.apply_where(rows, "cores == 64")
    assert out == [{"cores": 64, "exec_ns": 100}]


def test_apply_where_unknown_column_exits():
    rows = [{"cores": 64}]
    with pytest.raises(SystemExit):
        csvlens.apply_where(rows, "missing_col == 1")


def test_apply_where_is_outlier():
    rows = [
        {"g": "a", "v": 1},
        {"g": "a", "v": 2},
        {"g": "a", "v": 3},
        {"g": "a", "v": 4},
        {"g": "a", "v": 100},
    ]
    out = csvlens.apply_where(rows, 'is_outlier("v", by="g")')
    assert out == [{"g": "a", "v": 100}]


def test_apply_where_is_outlier_requires_quoted_columns():
    rows = [{"g": "a", "v": 1}]
    with pytest.raises(SystemExit):
        csvlens.apply_where(rows, "is_outlier(v, by=g)")


# -- apply_sort ------------------------------------------------------------------


def test_apply_sort_ascending():
    rows = [{"a": 3}, {"a": 1}, {"a": 2}]
    out = csvlens.apply_sort(rows, "a")
    assert [r["a"] for r in out] == [1, 2, 3]


def test_apply_sort_descending():
    rows = [{"a": 3}, {"a": 1}, {"a": 2}]
    out = csvlens.apply_sort(rows, "a:desc")
    assert [r["a"] for r in out] == [3, 2, 1]


def test_apply_sort_multi_key_earlier_key_wins():
    rows = [
        {"b": 1, "a": 3},
        {"b": 1, "a": 1},
        {"b": 0, "a": 2},
    ]
    out = csvlens.apply_sort(rows, "b,a:desc")
    assert [(r["b"], r["a"]) for r in out] == [(0, 2), (1, 3), (1, 1)]


# -- apply_group -----------------------------------------------------------------


def test_apply_group_default_mean():
    fields = ["g", "v"]
    rows = [{"g": "a", "v": 1}, {"g": "a", "v": 3}, {"g": "b", "v": 10}]
    out_fields, out_rows = csvlens.apply_group(fields, rows, "g", None)
    assert out_fields == ["g", "n", "v_mean"]
    by_g = {r["g"]: r for r in out_rows}
    assert by_g["a"]["n"] == 2
    assert by_g["a"]["v_mean"] == pytest.approx(2.0)
    assert by_g["b"]["v_mean"] == pytest.approx(10.0)


def test_apply_group_explicit_agg():
    fields = ["g", "v"]
    rows = [{"g": "a", "v": 1}, {"g": "a", "v": 3}]
    out_fields, out_rows = csvlens.apply_group(fields, rows, "g", "v:sum")
    assert out_fields == ["g", "n", "v_sum"]
    assert out_rows[0]["v_sum"] == 4


def test_apply_group_unknown_agg_exits():
    fields = ["g", "v"]
    rows = [{"g": "a", "v": 1}]
    with pytest.raises(SystemExit):
        csvlens.apply_group(fields, rows, "g", "v:bogus")


# -- CLI (main) --------------------------------------------------------------------


def run_cli(*args):
    return subprocess.run(
        [sys.executable, SCRIPT, *args],
        capture_output=True,
        text=True,
        check=True,
    )


def test_cli_where_sort_limit(tmp_csv):
    path = tmp_csv(
        ["cores", "exec_ns"],
        [
            {"cores": 64, "exec_ns": 500},
            {"cores": 64, "exec_ns": 100},
            {"cores": 32, "exec_ns": 999},
            {"cores": 64, "exec_ns": 300},
        ],
    )
    result = run_cli(
        str(path), "--where", "cores == 64", "--sort", "exec_ns:desc", "--limit", "2"
    )
    lines = result.stdout.strip().splitlines()
    assert lines[0] == "cores,exec_ns"
    assert lines[1:] == ["64,500", "64,300"]


def test_cli_group_and_agg(tmp_csv):
    path = tmp_csv(
        ["g", "v"],
        [
            {"g": "a", "v": 1},
            {"g": "a", "v": 3},
            {"g": "b", "v": 10},
        ],
    )
    result = run_cli(str(path), "--group", "g", "--agg", "v:sum")
    lines = result.stdout.strip().splitlines()
    assert lines[0] == "g,n,v_sum"
    assert "a,2,4" in lines
    assert "b,1,10" in lines


def test_cli_missing_column_fails(tmp_csv):
    path = tmp_csv(["g", "v"], [{"g": "a", "v": 1}])
    result = subprocess.run(
        [sys.executable, SCRIPT, str(path), "--cols", "nope"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert "no such column" in result.stderr

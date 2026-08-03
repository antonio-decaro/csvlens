import csv
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import pytest  # noqa: E402


@pytest.fixture
def tmp_csv(tmp_path):
    def write(fields, rows):
        path = tmp_path / "sample.csv"
        with open(path, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=fields)
            w.writeheader()
            for row in rows:
                w.writerow(row)
        return path

    return write

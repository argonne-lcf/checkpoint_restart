import os
import time

import pytest

from check_mate import check_hang


def test_get_date_formats_timestamp():
    timestamp = 1_700_000_000  # fixed epoch for reproducibility
    formatted = check_hang.get_date(timestamp)
    assert formatted == time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(timestamp))


def test_get_date_handles_none(monkeypatch):
    sentinel = time.struct_time((2024, 1, 2, 3, 4, 5, 1, 2, -1))

    def fake_localtime(value):
        assert value is None
        return sentinel

    def fake_strftime(fmt, struct):
        assert fmt == "%Y-%m-%d %H:%M:%S"
        assert struct is sentinel
        return "2024-01-02 03:04:05"

    monkeypatch.setattr(check_hang, "localtime", fake_localtime)
    monkeypatch.setattr(check_hang, "strftime", fake_strftime)

    assert check_hang.get_date(None) == "2024-01-02 03:04:05"


def test_get_date_rejects_invalid_timestamp():
    with pytest.raises(TypeError):
        check_hang.get_date("invalid")


def test_most_recent_mtime_returns_latest(tmp_path):
    file_a = tmp_path / "a.out"
    file_b = tmp_path / "b.out"
    file_a.write_text("a")
    file_b.write_text("b")

    # Ensure b has a newer timestamp
    os.utime(file_b, None)

    result = check_hang.most_recent_mtime([file_a, file_b])
    assert result == file_b.stat().st_mtime


def test_most_recent_mtime_ignores_missing(tmp_path):
    missing = tmp_path / "missing.dat"
    existing = tmp_path / "existing.dat"
    existing.write_text("data")

    result = check_hang.most_recent_mtime([missing, existing])
    assert result == existing.stat().st_mtime


def test_most_recent_mtime_returns_none_when_empty():
    assert check_hang.most_recent_mtime([]) is None


def test_most_recent_mtime_all_missing(tmp_path):
    missing1 = tmp_path / "missing1.dat"
    missing2 = tmp_path / "missing2.dat"
    result = check_hang.most_recent_mtime([missing1, missing2])
    assert result is None

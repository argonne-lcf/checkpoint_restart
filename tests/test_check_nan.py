import argparse
import os
import signal
from types import SimpleNamespace

import pytest

from check_mate import check_nan


def test_split_outputs_handles_mixed_delimiters():
    specs = check_nan.split_outputs(" log1.txt:logs/*.out , result.log :: metrics.csv ")
    assert specs == ["log1.txt", "logs/*.out", "result.log", "metrics.csv"]


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("", []),
        (" :: , , ::", []),
        ("alpha::beta, , gamma", ["alpha", "beta", "gamma"]),
    ],
)
def test_split_outputs_handles_empty_and_malformed_segments(raw, expected):
    assert check_nan.split_outputs(raw) == expected


@pytest.mark.parametrize(
    ("pattern", "expected"),
    [
        ("*.log", True),
        ("logs/output.log", False),
        ("file?.txt", True),
        ("file1txt", False),
        ("data[0-9].csv", True),
        ("data9.csv", False),
        ("**/*.log", True),
        ("logs/logfile.log", False),
        ("backup[!0-9]?.bak", True),
        ("backupA1.bak", False),
    ],
)
def test_is_glob_detects_special_characters(pattern, expected):
    assert check_nan.is_glob(pattern) is expected


def test_list_files_returns_existing_files(tmp_path):
    file_a = tmp_path / "a.log"
    file_a.write_text("hello")
    nested = tmp_path / "nested"
    nested.mkdir()
    file_b = nested / "b.log"
    file_b.write_text("world!")

    specs = [str(file_a), str(tmp_path / "*.log"), str(nested / "*.log")]
    files = check_nan.list_files(specs, recursive=False)

    assert files[str(file_a)] == len("hello")
    assert files[str(file_b)] == len("world!")


def test_scan_new_bytes_tracks_offsets(tmp_path):
    target = tmp_path / "log.txt"
    target.write_text("12345")

    end, chunk = check_nan.scan_new_bytes(str(target), 0)
    assert end == 5
    assert chunk == "12345"

    target.write_text("12345abcdef")
    end, chunk = check_nan.scan_new_bytes(str(target), end)
    assert end == len("12345abcdef")
    assert chunk == "abcdef"


def test_scan_new_bytes_missing_file_is_safe(tmp_path):
    start, chunk = check_nan.scan_new_bytes(str(tmp_path / "missing.log"), 10)
    assert start == 10
    assert chunk == ""


@pytest.mark.parametrize(
    ("text", "include_inf"),
    [
        ("loss=nan", False),
        ("loss=INF", True),
        ("loss=NaN", False),
        ("loss=Inf", True),
        ("error: nan", True),
        ("error: (nan)", True),
        ("error: inf", True),
        ("error: [inf]", True),
        ("error: nan,", True),
        ("error: inf.", True),
        ("error: nan;", True),
        ("error: inf:", True),
        ("error: nan!", True),
        ("error: inf?", True),
    ],
)
def test_contains_bad_tokens_detects_various_spellings(text, include_inf):
    assert check_nan.contains_bad_tokens(text, include_inf)


@pytest.mark.parametrize(
    ("text", "include_inf"),
    [
        ("all good", True),
        ("bananas are tasty", True),
        ("infinite loop", True),
        ("manifold learning", True),
        ("information", True),
        ("nanobot", True),
        ("infinitesimal", True),
    ],
)
def test_contains_bad_tokens_respects_token_boundaries(text, include_inf):
    assert not check_nan.contains_bad_tokens(text, include_inf)


@pytest.fixture()
def fake_sleep(monkeypatch):
    monkeypatch.setattr(check_nan.time, "sleep", lambda _: None)


def test_try_kill_pid_and_command(monkeypatch, fake_sleep, capsys):
    kills: list[tuple[int, int]] = []
    commands: list[str] = []

    def fake_kill(pid: int, sig: int) -> None:
        kills.append((pid, sig))

    def fake_run(cmd, shell, check):
        assert shell and not check
        commands.append(cmd)

    monkeypatch.setattr(os, "kill", fake_kill)
    monkeypatch.setattr(check_nan.subprocess, "run", fake_run)

    args = argparse.Namespace(
        dry_run=False,
        pid=4242,
        signal="TERM",
        grace=1,
        kill_command="echo kill",
    )

    check_nan.try_kill(args)

    # After first invocation we expect TERM signal, a follow-up poll, escalation to
    # SIGKILL, and the kill command execution.
    assert kills == [
        (4242, getattr(signal, "SIGTERM")),
        (4242, 0),
        (4242, signal.SIGKILL),
    ]
    assert commands == ["echo kill"]


def test_try_kill_dry_run(caplog):
    args = SimpleNamespace(
        dry_run=True,
        pid=0,
        signal="TERM",
        grace=0,
        kill_command="",
    )
    check_nan.try_kill(args)
    matched = False
    for record in caplog.records:
        if "[DRY-RUN]" in record.msg:
            matched = True
            break
    assert matched


def test_try_kill_invalid_signal():
    args = SimpleNamespace(
        dry_run=False,
        pid=1234,
        signal="NOT_A_SIGNAL",
        grace=0,
        kill_command="",
    )
    with pytest.raises(AttributeError):
        check_nan.try_kill(args)


def test_try_kill_warns_when_no_action(monkeypatch, caplog):
    args = SimpleNamespace(
        dry_run=False,
        pid=0,
        signal="TERM",
        grace=0,
        kill_command="",
    )
    check_nan.try_kill(args)
    # captured = capsys.readouterr()
    # assert "No kill action executed" in captured.out
    matched = False
    for record in caplog.records:
        if "No kill action executed" in record.msg:
            matched = True
            break
    assert matched

from __future__ import annotations

from pathlib import Path

import pytest

from check_mate import examples

EXPECTED_EXAMPLES = {"fail", "hang", "nan", "success"}


def test_available_examples_includes_packaged_scripts():
    available = set(examples.available_examples())
    assert EXPECTED_EXAMPLES <= available


def test_read_script_returns_script_contents():
    script = examples.read_script("fail")
    assert script.startswith("#!/bin/bash")
    assert "check-mate-hang" in script
    assert "python -m check_mate.test" in script


def test_run_example_cli_prints_script(capsys):
    exit_code = examples.run_example_cli("hang", [])
    assert exit_code == 0
    captured = capsys.readouterr()
    assert "#!/bin/bash" in captured.out
    assert captured.err == ""


def test_run_example_cli_writes_output(tmp_path: Path, capsys):
    destination = tmp_path / "example.sc"
    exit_code = examples.run_example_cli("nan", ["--output", str(destination)])
    assert exit_code == 0
    assert destination.exists()
    assert destination.read_text().startswith("#!/bin/bash")
    captured = capsys.readouterr()
    assert "Wrote nan example submission script" in captured.out


def test_run_example_cli_requires_overwrite_flag(tmp_path: Path):
    destination = tmp_path / "example.sc"
    destination.write_text("placeholder")
    with pytest.raises(FileExistsError):
        examples.run_example_cli("success", ["--output", str(destination)])

    exit_code = examples.run_example_cli("success", ["--output", str(destination), "--overwrite"])
    assert exit_code == 0
    assert destination.read_text().startswith("#!/bin/bash")

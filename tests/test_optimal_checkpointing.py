import math

import pytest

from check_mate.optimal_checkpointing import compute_efficiency, optimal_checkpoint_cadence


def solve_expected_cadence(
    node_count: int,
    node_memory: float,
    *,
    MTBAI: float = 0.67,
    chkpt_bandwidth: float = 5000.0,
    R_0: float | None = None,
) -> float:
    """Re-implement the scalar root solve using a pure-Python bisection check."""
    if R_0 is None:
        R_0 = 1 / (MTBAI * 10624)

    tau_c = (node_memory / chkpt_bandwidth) / 3600
    u_chk = tau_c * node_count**2
    z_chk = R_0 * u_chk

    def f(z_c: float) -> float:
        return math.exp(-z_c - z_chk) - (1 - z_c)

    lo, hi = 0.0, max(1.5 * z_chk, 1.0)
    f_lo = f(lo)
    f_hi = f(hi)
    assert f_lo * f_hi <= 0, "Bracket must contain the root"

    for _ in range(200):
        mid = 0.5 * (lo + hi)
        f_mid = f(mid)
        if abs(f_mid) <= 1e-12 or hi - lo <= 1e-12:
            z_c = mid
            break
        if f_mid * f_lo > 0:
            lo, f_lo = mid, f_mid
        else:
            hi, f_hi = mid, f_mid
    else:  # pragma: no cover - defensive guard
        raise RuntimeError("Bisection did not converge")

    u_c = z_c / R_0
    return u_c / node_count


def test_optimal_checkpoint_cadence_matches_reference_bandwidth_default():
    cadence = optimal_checkpoint_cadence(node_count=64, node_memory=32)
    expected = solve_expected_cadence(node_count=64, node_memory=32)
    assert cadence == pytest.approx(expected, rel=1e-6)


def test_optimal_checkpoint_cadence_respects_named_bandwidth():
    cadence = optimal_checkpoint_cadence(
        node_count=64,
        node_memory=32,
        chkpt_bandwidth="LUSTRE",
    )
    expected = solve_expected_cadence(
        node_count=64,
        node_memory=32,
        chkpt_bandwidth=650.0,
    )
    assert cadence == pytest.approx(expected, rel=1e-6)


def test_optimal_checkpoint_cadence_with_extremely_large_bandwidth():
    baseline = optimal_checkpoint_cadence(node_count=64, node_memory=32)
    huge_bandwidth = optimal_checkpoint_cadence(
        node_count=64,
        node_memory=32,
        chkpt_bandwidth=1e12,
    )
    assert huge_bandwidth < baseline


def test_optimal_checkpoint_cadence_with_extremely_small_bandwidth():
    baseline = optimal_checkpoint_cadence(node_count=64, node_memory=32)
    tiny_bandwidth = optimal_checkpoint_cadence(
        node_count=64,
        node_memory=32,
        chkpt_bandwidth=1e-6,
    )
    assert tiny_bandwidth > baseline


@pytest.mark.parametrize(
    "field,kwargs",
    [
        ("node_count", {"node_count": 0, "node_memory": 32}),
        ("node_memory", {"node_count": 64, "node_memory": 0}),
        ("chkpt_bandwidth", {"node_count": 64, "node_memory": 32, "chkpt_bandwidth": 0}),
    ],
)
def test_optimal_checkpoint_cadence_rejects_non_positive_parameters(field, kwargs):
    with pytest.raises(ValueError) as excinfo:
        optimal_checkpoint_cadence(**kwargs)
    assert field in str(excinfo.value)


@pytest.mark.parametrize("bandwidth", ["UNKNOWN", None])
def test_optimal_checkpoint_cadence_rejects_invalid_bandwidth_inputs(bandwidth):
    with pytest.raises(TypeError):
        optimal_checkpoint_cadence(node_count=8, node_memory=8, chkpt_bandwidth=bandwidth)


def test_compute_efficiency_matches_manual_result():
    cadence = optimal_checkpoint_cadence(node_count=64, node_memory=32)
    efficiency = compute_efficiency(node_count=64, node_memory=32)
    expected_eff = math.exp(-(4.0 + 3.0) / cadence)
    assert efficiency == pytest.approx(expected_eff, rel=1e-6)


def test_compute_efficiency_warns_for_tiny_cadence():
    with pytest.warns(UserWarning):
        compute_efficiency(node_count=4096, node_memory=8)


@pytest.mark.parametrize("node_memory", [0, -8])
def test_compute_efficiency_rejects_non_positive_memory(node_memory):
    with pytest.raises(ValueError):
        compute_efficiency(node_count=64, node_memory=node_memory)

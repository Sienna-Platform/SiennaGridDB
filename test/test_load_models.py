import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent


def _power_openapi_models_src_path():
    """Locate the power-openapi-models checkout the same way conftest's
    SiennaSchemas lookup does: nested at <repo>/power-openapi-models for CI,
    a sibling checkout locally."""
    for candidate in (
        REPO_ROOT / "power-openapi-models" / "src",
        REPO_ROOT.parent / "power-openapi-models" / "src",
    ):
        if candidate.exists():
            return candidate
    return REPO_ROOT.parent / "power-openapi-models" / "src"


POWER_OPENAPI_MODELS_SRC = _power_openapi_models_src_path()

if str(POWER_OPENAPI_MODELS_SRC) not in sys.path:
    sys.path.insert(0, str(POWER_OPENAPI_MODELS_SRC))

pytest.importorskip(
    "power_openapi_models",
    reason="power-openapi-models sibling checkout not found",
)

from power_openapi_models.core.models import (  # noqa: E402
    CostCurve,
    InputOutputCurve,
    LinearFunctionData,
    StartUpStages,
    ThermalGenerationCost,
)
from power_openapi_models.operations.models import ACBus, ThermalStandard  # noqa: E402


def test_acbus():
    acbus = ACBus(id=3, name="4", number=2, bustype="PQ", available=True)
    assert acbus.id == 3


def test_thermal_standard():
    cost = ThermalGenerationCost(
        variable=CostCurve(
            value_curve=InputOutputCurve(
                curve_type="INPUT_OUTPUT",
                function_data=LinearFunctionData(
                    function_type="LINEAR", proportional_term=1, constant_term=0
                ),
            ),
            power_units="NATURAL_UNITS",
            variable_cost_type="COST",
            vom_cost=InputOutputCurve(
                curve_type="INPUT_OUTPUT",
                function_data=LinearFunctionData(
                    function_type="LINEAR", proportional_term=1, constant_term=0
                ),
            ),
        ),
        fixed=2,
        start_up=StartUpStages(hot=1, cold=2, warm=3),
        shut_down=3,
    )

    thermal_standard = ThermalStandard(
        id=3,
        name="test_thermal",
        available=True,
        status=True,
        bus=3,
        active_power=0.0,
        reactive_power=0.0,
        rating=1.0,
        active_power_limits={"min": 0.0, "max": 1.0},
        operation_cost=cost,
        base_power=100.0,
    )
    assert cost == thermal_standard.operation_cost

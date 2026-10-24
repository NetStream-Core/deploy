"""Writes a trivial, real ONNX model for tests/e2e/detection.sh: a
`ThresholdBaseline` with a single rule that fires on any window with at
least one flow (`flows_count > 0`). The e2e test is about wiring —
publish → consume → score → produce → ClickHouse — not about detection
accuracy, so the rule only needs to deterministically flag the one
synthetic window the test sends.

Run with `uv run --project ../ml python tests/e2e/make_test_onnx_model.py
<output path>` from the `deploy` repo.
"""

import sys
from pathlib import Path

from netstream_ml.baselines import ThresholdBaseline, ThresholdRule
from netstream_ml.onnx_export import save_onnx_model, to_onnx

if __name__ == "__main__":
    output_path = Path(sys.argv[1])
    baseline = ThresholdBaseline(
        rules=(ThresholdRule(feature="flows_count", threshold=0, direction="above"),)
    )
    model, feature_order, kind = to_onnx(baseline)
    save_onnx_model(model, output_path)
    print(f"wrote {kind} model ({feature_order}) to {output_path}")

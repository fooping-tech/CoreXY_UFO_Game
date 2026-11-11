"""UFOくん 勉強モード (#86): worksheets, height calibration and the AI explanation.

The experience itself (intro -> watch -> HELP -> explanation -> celebration -> cleanup ->
game unlocked) runs in the game; this package holds the backend's part: the sample
worksheets' data, the arm camera's capture heights (refused on the real robot until
measured and confirmed), and the structured explanation from Claude Code / Codex.
Robot motion stays in the sequencers (homework/approach.py, sequence/cleanup.py).
"""

from .explain import ExplainError, fallback_explanation, parse_explanation, split_speech
from .height import CaptureStage, HeightCalibration, HeightError
from .worksheets import WorksheetCatalog, WorksheetError

__all__ = ["CaptureStage", "ExplainError", "HeightCalibration", "HeightError", "WorksheetCatalog", "WorksheetError",
           "fallback_explanation", "parse_explanation", "split_speech"]

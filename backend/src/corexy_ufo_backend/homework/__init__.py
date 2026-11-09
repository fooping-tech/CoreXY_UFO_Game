"""Optional homework watch: progress of a worksheet from camera frames (Jev). No robot control."""

from .jev import JevClient, JevError, load_credentials
from .locate import LocateParams
from .progress import ProgressTracker, Reading, parse
from .service import HomeworkConfig, HomeworkService
from .speech import SpeechConfig, SpeechService

__all__ = ["HomeworkConfig", "HomeworkService", "JevClient", "JevError", "LocateParams", "ProgressTracker",
           "Reading", "SpeechConfig", "SpeechService", "load_credentials", "parse"]

"""Optional homework watch: progress of a worksheet from camera frames (Jev). No robot control."""

from .jev import JevClient, JevError, load_credentials
from .progress import ProgressTracker, Reading, parse
from .service import HomeworkConfig, HomeworkService

__all__ = ["HomeworkConfig", "HomeworkService", "JevClient", "JevError", "ProgressTracker", "Reading",
           "load_credentials", "parse"]

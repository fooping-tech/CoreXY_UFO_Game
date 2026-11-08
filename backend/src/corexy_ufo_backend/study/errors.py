"""Errors shared by the study adapters."""


class StudyAdapterError(RuntimeError):
    """The assistant behind a study session failed (not installed, stopped, refused...)."""

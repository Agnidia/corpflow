"""Compatibility import for the Claude provider."""

import sys
from .providers.claude import config_leak as _implementation

sys.modules[__name__] = _implementation

"""Compatibility import for the Claude provider."""

import sys
from .providers.claude import usage_limit as _implementation

sys.modules[__name__] = _implementation

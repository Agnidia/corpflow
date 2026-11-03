"""Compatibility import for the Claude provider."""

import sys
from .providers.claude import credentials as _implementation

sys.modules[__name__] = _implementation

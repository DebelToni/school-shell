#!/usr/bin/env python3
"""Bundle the helper into the public bootstrap. No secrets or model calls."""
from pathlib import Path

root = Path(__file__).resolve().parent
script = (root / 'setup.sh').read_text().replace('@@SCHOOL_HELPER@@', (root / 'school').read_text().rstrip())
(root / 'site' / 'setup.sh').write_text(script)

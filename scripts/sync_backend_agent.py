"""Update the bundled agent in the backend source folder, preserving attribution files."""
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / 'backend_dean'
if not (BACKEND / 'backend/deanery_api/main.py').is_file():
    raise SystemExit('Backend source folder backend_dean is missing')
destination = BACKEND / 'references/dean-agent'
for file in (ROOT / 'dean_agent').glob('*.py'):
    shutil.copy2(file, destination / 'dean_agent' / file.name)
shutil.copy2(ROOT / 'pyproject.toml', destination / 'pyproject.toml')
print('Bundled agent updated; upstream LICENSE and provenance preserved.')

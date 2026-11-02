"""Files unused by the HTTP/Steam proxy distribution (keep package licenses)."""
from pathlib import PurePosixPath


def include_proxy_file(name):
    path = PurePosixPath(name.replace('\\', '/'))
    base = path.name.lower()
    return not (path.suffix.lower() == '.sys'
                or path.suffix.lower() in {'.pyc', '.pyo', '.pdb', '.lib', '.a'}
                or any(part.lower() in {'__pycache__', 'tests', 'test'} for part in path.parts)
                or base in {'tcl86t.dll', 'tk86t.dll', '_tkinter.pyd'}
                or (base.startswith('windivert') and path.suffix.lower() in {'.dll', '.lib'})
                or base == 'windows-redirector.exe')

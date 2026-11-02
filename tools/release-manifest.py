"""Create the public update manifest uploaded with each GitHub release."""
import argparse,hashlib,json,re
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--version',required=True);p.add_argument('--exe',type=Path,required=True);p.add_argument('--notes',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)',a.version):p.error('A stable semantic version is required')
if a.exe.suffix.lower()!='.exe' or not a.exe.is_file():p.error('Executable not found')
a.output.write_text(json.dumps({'schema':1,'repository':'127MU/custom-planets-variants','version':a.version,'asset':a.exe.name,'notes':a.notes.read_text('utf8'),'sha256':hashlib.sha256(a.exe.read_bytes()).hexdigest()},ensure_ascii=False,indent=2),'utf8')

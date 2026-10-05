#!/usr/bin/env python3
"""Read counts or export the private waitlist using authenticated Cloudflare access."""
import argparse
import csv
import io
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--local', action='store_true')
parser.add_argument('--export', type=Path, help='Write a new private CSV file; never under public/')
args = parser.parse_args()
query = 'SELECT COUNT(*) AS saved_signups FROM waitlist_entries'
if args.export:
    target = args.export.resolve()
    if target.is_relative_to(ROOT / 'public'):
        parser.error('Exports cannot be written into public/.')
    query = 'SELECT id,email,created_at,consent_version,experiment,variant FROM waitlist_entries WHERE unsubscribed_at IS NULL ORDER BY created_at,id'
result = subprocess.run([str(ROOT/'node_modules/.bin/wrangler'), 'd1','execute','EXPERIMENTS', '--local' if args.local else '--remote','--command',query,'--json'], cwd=ROOT, capture_output=True, text=True, check=True)
rows = json.loads(result.stdout)[0]['results']
if args.export:
    # Escape spreadsheet formula prefixes, including valid plus-prefixed mailbox names.
    def safe(value):
        return "'" + value if isinstance(value,str) and value.startswith(('=','+','-','@','\t','\r')) else value
    buffer = io.StringIO()
    fields = ['id','email','created_at','consent_version','experiment','variant']
    writer = csv.DictWriter(buffer, fieldnames=fields)
    writer.writeheader()
    writer.writerows({k:safe(v) for k,v in row.items()} for row in rows)
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor,'w') as output:
        output.write(buffer.getvalue())
    print(f'Exported {len(rows)} saved signups to {target}. Email ownership is not verified.')
else:
    print(json.dumps({'environment':'local' if args.local else 'production', **rows[0]}, indent=2))

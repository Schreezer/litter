#!/usr/bin/env python3
"""Read real copy-test results through the authenticated Cloudflare CLI."""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WRANGLER = os.environ.get('WRANGLER', str(ROOT / 'node_modules/.bin/wrangler'))
QUERY = """
WITH variants(variant) AS (VALUES ('a'), ('b'))
SELECT v.variant,
       COUNT(p.exposed_at) AS visitors,
       COUNT(p.early_access_at) AS early_access_clicks,
       COUNT(p.waitlist_at) AS waitlist_signups,
       COUNT(p.demo_engaged_at) AS demo_engagements,
       MIN(p.exposed_at) AS first_exposure,
       MAX(p.exposed_at) AS last_exposure
FROM variants v LEFT JOIN landing_participants p
ON p.variant = v.variant AND p.experiment = 'learning-motivation-waitlist-v3'
AND p.enrolled_at > unixepoch() - 90 * 86400
GROUP BY v.variant ORDER BY v.variant;
"""

def wilson(successes, total):
    if not total:
        return None
    z = 1.959963984540054
    p = successes / total
    denominator = 1 + z*z/total
    center = (p + z*z/(2*total)) / denominator
    radius = z * math.sqrt(p*(1-p)/total + z*z/(4*total*total)) / denominator
    return [max(0, center-radius), min(1, center+radius)]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--local', action='store_true', help='Use local test data instead of production')
    parser.add_argument('--json', action='store_true', help='Print measured counts and intervals as JSON')
    args = parser.parse_args()
    result = subprocess.run([WRANGLER, 'd1', 'execute', 'EXPERIMENTS', '--local' if args.local else '--remote', '--command', QUERY, '--json'], cwd=ROOT, check=True, capture_output=True, text=True)
    rows = json.loads(result.stdout)[0]['results']
    for row in rows:
        n, clicks = row['visitors'], row['waitlist_signups']
        row['signup_rate'] = clicks/n if n else None
        row['signup_rate_95pct_interval'] = wilson(clicks, n)
    output = {
        'experiment': 'learning-motivation-waitlist-v3',
        'environment': 'local test data' if args.local else 'production',
        'primary_metric': 'Browsers completing a new email signup / exposed browsers',
        'winner': None,
        'variants': rows
    }
    if args.json:
        print(json.dumps(output, indent=2))
        return
    print(f"Learnfold copy test ({output['environment']})")
    print('| Copy | Visitors | Waitlist signups | Rate | 95% interval | Demo engagements |')
    print('|---|---:|---:|---:|---|---:|')
    for row in rows:
        interval = row['signup_rate_95pct_interval']
        rate = f"{row['signup_rate']:.1%}" if interval else 'No data'
        uncertainty = f'{interval[0]:.1%} to {interval[1]:.1%}' if interval else 'No data'
        label = 'A: Curiosity' if row['variant']=='a' else 'B: Less scrolling'
        print(f"| {label} | {row['visitors']} | {row['waitlist_signups']} | {rate} | {uncertainty} | {row['demo_engagements']} |")
    print('\nNo winner is declared automatically. Signups are stored emails, not verified email addresses or app installs.')
    print('Use the same traffic sources for both variants. Review after at least two full weeks; sparse data remains inconclusive.')

if __name__ == '__main__':
    main()

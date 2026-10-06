#!/usr/bin/env python3
"""Generate a comparison from saved live trial records without API calls."""
import argparse
from collections import Counter
import json
from pathlib import Path
from statistics import median


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('directory',type=Path)
    args=parser.parse_args()
    rows=json.loads((args.directory/'summary.json').read_text())
    manifest=json.loads((args.directory/'manifest.json').read_text())
    expected=len(manifest['fixtures'])*manifest['repetitions']*2
    if len(rows)!=expected:
        raise SystemExit(f'Incomplete run: {len(rows)}/{expected} trials; report not generated')
    lines=['# Page editing benchmark results','',f"Model: `{manifest['model']}`. {len(rows)} live agent sessions. Three scenarios, two methods, three repetitions per pair.",'',
           '## Per-scenario comparison','',
           '| Scenario | Current pass | Draft pass | Current median time | Draft median time | Current median tool calls | Draft median tool calls |',
           '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for fixture in manifest['fixtures']:
        current=[r for r in rows if r['scenario']==fixture['id'] and r['method']=='current']
        draft=[r for r in rows if r['scenario']==fixture['id'] and r['method']=='draft']
        lines.append(f"| {fixture['id']} | {sum(r['automated_pass'] for r in current)}/{len(current)} | {sum(r['automated_pass'] for r in draft)}/{len(draft)} | {median(r['seconds'] for r in current):.2f}s | {median(r['seconds'] for r in draft):.2f}s | {median(r['tool_calls'] for r in current):g} | {median(r['tool_calls'] for r in draft):g} |")
    lines+=['','## Overall totals','',
            '| Metric | Current | Draft |','| --- | ---: | ---: |']
    groups={method:[r for r in rows if r['method']==method] for method in ['current','draft']}
    metrics=[('Passed trials',lambda rs:sum(r['automated_pass'] for r in rs)),
             ('API requests',lambda rs:sum(r['api_calls'] for r in rs)),
             ('Tool calls',lambda rs:sum(r['tool_calls'] for r in rs)),
             ('Tool errors including injected conflicts',lambda rs:sum(r['tool_errors'] for r in rs)),
             ('Successful agent commits',lambda rs:sum(r['commits'] for r in rs)),
             ('Input tokens including replayed history',lambda rs:sum(r['usage']['input_tokens'] for r in rs)),
             ('Cached input tokens',lambda rs:sum(r['usage']['cached_input_tokens'] for r in rs)),
             ('Output tokens',lambda rs:sum(r['usage']['output_tokens'] for r in rs)),
             ('Reasoning tokens reported within output',lambda rs:sum(r['usage']['reasoning_tokens'] for r in rs)),
             ('Median trial duration, seconds',lambda rs:round(median(r['seconds'] for r in rs),2)),
             ('Total trial duration, seconds',lambda rs:round(sum(r['seconds'] for r in rs),2))]
    for label,fn in metrics:
        lines.append(f"| {label} | {fn(groups['current']):,} | {fn(groups['draft']):,} |")
    lines+=['','## Individual trials','',
            '| Trial | Pass | Time | API calls | Tool calls | Input tokens | Output tokens |',
            '| --- | --- | ---: | ---: | ---: | ---: | ---: |']
    trial_dirs=sorted(d for d in args.directory.iterdir() if d.is_dir() and (d/'summary.json').exists())
    for d in trial_dirs:
        r=json.loads((d/'summary.json').read_text())
        lines.append(f"| [{d.name}]({d.name}/summary.json) | {r['automated_pass']} | {r['seconds']:.2f}s | {r['api_calls']} | {r['tool_calls']} | {r['usage']['input_tokens']:,} | {r['usage']['output_tokens']:,} |")
    lines+=['','## Tool strategies','']
    for method in ['current','draft']:
        patterns=Counter()
        for d in trial_dirs:
            r=json.loads((d/'summary.json').read_text())
            if r['method']!=method:continue
            trace=json.loads((d/'tool-trace.json').read_text())
            pattern=[]
            for t in trace:
                name=t['name']
                if name=='native-editor-update-page':name+=':'+t['arguments'].get('command','?')
                if t['result'].get('isError'):name+=' [error]'
                pattern.append(name)
            patterns[' -> '.join(pattern)]+=1
        lines.append(f'### {method}')
        lines.append('')
        lines += [f'- {count} trial(s): `{pattern}`' for pattern,count in patterns.items()]
        lines.append('')
    lines+=['## Interpretation limits','',
            '- Pass counts are from the deterministic rubric. Prose quality still requires reading the final pages.',
            '- Both methods can batch text replacements; only the draft method requires a separate apply operation.',
            '- The draft adapter is experimental. The native parser, block identity handling, SQLite storage, and revision checks are real.',
            '- This does not test the full iOS repository, approval UI, autosave, sync, rendering, or physical-device behavior.',
            '- One model and three repetitions per scenario do not establish superiority for every model, document size, or file tool implementation.',
            '- Latency and caching are observed provider behavior. Input totals include history replay; cached tokens are a subset of input tokens.',
            '- The initial unbatched pilot is excluded from this report.',
            '', '[Run manifest](manifest.json) · [Raw summary](summary.json)', '']
    path=args.directory/'results.md'
    path.write_text('\n'.join(lines))
    print(path)


if __name__=='__main__':main()

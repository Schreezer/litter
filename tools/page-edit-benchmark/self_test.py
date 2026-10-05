#!/usr/bin/env python3
"""Deterministic harness checks, separate from all live LLM results."""
import json
from pathlib import Path
import tempfile
from run import HERE, REPO, Trial, bridge, grade


def rewrite(text, scenario):
    if scenario == 'precise-correction':
        return text.replace('The rate is 5%.', 'The rate is 8%.', 1).replace('1,000 × 1.05 = 1,050.', '1,000 × 1.08 = 1,080.')
    if scenario == 'rewrite-with-native-blocks':
        return text.replace('Caching is the operational retention of previously retrieved representations governed by freshness and validation semantics. A user agent may reuse stored response entities subject to cache directive constraints and conditional revalidation.', 'A browser can save a copy and reuse it instead of downloading it again.').replace('## Practice', '## Worked examples\n\nETag: "v1". Request: If-None-Match: "v1". Response: 304. The browser reuses its copy without downloading the body.\n\nFor app.a91f.css: Cache-Control: public, max-age=31536000, immutable. The unchanged filename lets the browser reuse its fresh copy without another request.\n\n## Practice')
    return text.replace('after 7 days', 'after 3 days').replace('Read the lesson twice and highlight the key sentences.', 'Close the lesson and write down three ideas from memory.')


def main():
    directory = REPO / 'artifacts/page-edit-benchmark'
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='self-test-', dir=directory) as temporary:
        root = Path(temporary)
        for fixture in json.loads((HERE/'fixtures.json').read_text()):
            seed=root/(fixture['id']+'.sqlite')
            page=bridge('seed',database=str(seed),title=fixture['title'],markdown=fixture['markdown'],opaque=fixture.get('opaque',False))
            fixture['page_id']=page['id']
            for method in ['current','draft']:
                work=root/(fixture['id']+'-'+method)
                work.mkdir()
                trial=Trial(work,fixture,method,seed)
                before=bridge('inspect',database=str(trial.database),page_id=page['id'])
                for attempt in range(2):
                    if method=='current':
                        latest=trial.execute('native-editor-fetch',{'id':page['id']})['value']
                        result=trial.execute('native-editor-update-page',{'page_id':page['id'],'expected_revision':latest['revision'],'command':'replace_content','new_str':rewrite(latest['markdown'],fixture['id'])})
                    else:
                        latest=trial.execute('open_page',{'page_id':page['id']})
                        draft_path=work/'lesson.md'
                        original=draft_path.read_text()
                        bad=trial.execute('edit_file',{'path':'lesson.md','edits':[
                            {'old_str':original,'new_str':original+'\nTemporary draft text.'},
                            {'old_str':'THIS DOES NOT EXIST','new_str':'Never written'},
                        ]})
                        assert bad.get('isError') and draft_path.read_text()==original
                        trial.execute('edit_file',{'path':'lesson.md','edits':[
                            {'old_str':original,'new_str':rewrite(original,fixture['id'])},
                            {'old_str':'# '+fixture['title'],'new_str':'# '+fixture['title']},
                        ]})
                        result=trial.execute('apply_page',{'path':'lesson.md'})
                    if not result.get('isError'):break
                    assert fixture.get('inject_concurrent_edit') and attempt==0, result
                    assert result['value']['code']=='conflict',result
                after=bridge('inspect',database=str(trial.database),page_id=page['id'])
                checks=grade(fixture,before,after,trial.trace)
                assert all(checks.values()),(fixture['id'],method,checks)
                corrupted=json.loads(json.dumps(after))
                corrupted['page']['markdown']=corrupted['page']['markdown'].replace('## My learner note', '## Missing learner note')
                if fixture['id']!='concurrent-learner-edit':
                    assert not all(grade(fixture,before,corrupted,trial.trace).values())
                print(f"PASS {fixture['id']} {method}")
    print('All six deterministic harness checks passed. No LLM calls made.')


if __name__=='__main__':main()

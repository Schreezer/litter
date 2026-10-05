import test from 'node:test';
import assert from 'node:assert/strict';
import ts from 'typescript';
import { readFileSync } from 'node:fs';
const source = ts.transpileModule(readFileSync(new URL('../lib/analytics.ts', import.meta.url),'utf8'), { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText;
const { flushAnalytics } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
test('PostHog sends only explicit anonymous properties; retries reuse UUID and failures stay pending', async () => {
    const row = { id: 'experiment:hash:event', experiment: 'learning-motivation-waitlist-v3', participant_hash: 'anonymous-hash', variant:'b', event:'waitlist_joined', occurred_at:1700000000 };
    let delivered = 0;
    const env = { POSTHOG_PROJECT_KEY:'phc_test', POSTHOG_HOST:'https://eu.i.posthog.com', EXPERIMENTS: {
        prepare: () => ({ all: async()=>({results:[row]}), bind: ()=>({}) }),
        batch: async()=>{delivered++;}
    }};
    const original = globalThis.fetch;
    const originalError = console.error;
    const payloads = [];
    try {
        console.error = ()=>{};
        globalThis.fetch = async (url, options) => {
            assert.equal(String(url), 'https://eu.i.posthog.com/batch/');
            payloads.push(JSON.parse(options.body));
            return new Response('', {status: payloads.length === 1 ? 503 : 200});
        };
        await flushAnalytics(env);
        assert.equal(delivered,0);
        await flushAnalytics(env);
        assert.equal(delivered,1);
        assert.equal(payloads[0].batch[0].uuid,payloads[1].batch[0].uuid);
        const properties = payloads[1].batch[0].properties;
        assert.deepEqual(Object.keys(properties).sort(), ['$geoip_disable','$ip','$process_person_profile','distinct_id','experiment','source','variant'].sort());
        assert.equal(properties.$process_person_profile,false);
        assert.equal(properties.$ip,null);
        assert.equal(properties.variant,'b');
        await flushAnalytics({...env,POSTHOG_PROJECT_KEY:''});
        assert.equal(payloads.length,2);
    } finally { globalThis.fetch=original; console.error=originalError; }
});

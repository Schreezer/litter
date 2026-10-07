import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const base = process.env.EXPERIMENT_TEST_URL || 'http://127.0.0.1:4174';
assert(['127.0.0.1', 'localhost'].includes(new URL(base).hostname), 'Integration tests must only write to local data.');
const root = fileURLToPath(new URL('../', import.meta.url));
const agent = 'LearnfoldIntegration/1.0';
const assignments = new Map();
async function get(path = '/', extra = {}) {
    const response = await fetch(base + path, { headers: { 'User-Agent': agent, Connection: 'close', ...extra } });
    const html = await response.text();
    const cookie = response.headers.get('set-cookie')?.split(';')[0];
    if (cookie) assignments.set(cookie, response.headers.get('x-learnfold-variant'));
    return { response, html, cookie };
}
async function event(cookie, name, extra = {}, body) {
    return fetch(base + '/api/experiment/event', {
        method: 'POST', headers: { 'User-Agent': agent, Connection: 'close', 'Origin': base, 'Referer': base + '/', 'Content-Type': 'application/json', 'Cookie': cookie || '', ...extra },
        body: body ?? JSON.stringify({ event: name, variant: assignments.get(cookie) })
    });
}
function query(sql) {
    const raw = execFileSync('./node_modules/.bin/wrangler', ['d1','execute','EXPERIMENTS','--local','--command',sql,'--json'], { cwd: root, encoding: 'utf8' });
    return JSON.parse(raw)[0].results;
}

function hash(cookie) {
    return createHash('sha256').update('learning-motivation-waitlist-v3:' + cookie.split('=')[1]).digest('hex');
}
function participant(cookie) {
    return query(`SELECT * FROM landing_participants WHERE participant_hash = '${hash(cookie)}'`)[0];
}

test('preview A keeps control copy; B changes framing and both keep real product facts', async () => {
    const a = await get('/?variant=a');
    const b = await get('/?variant=b');
    assert.match(a.html, /Turn anything into <em>a course\.<\/em>/);
    assert.match(b.html, /Less scrolling\. <em>More understanding\.<\/em>/);
    for (const result of [a,b]) {
        assert.equal(result.response.status, 200);
        assert.equal(result.cookie, undefined);
        assert.equal(result.response.headers.get('x-learnfold-experiment'), 'untracked');
        assert.match(result.response.headers.get('x-robots-tag'), /noindex/);
        assert.match(result.html, /data-experiment-active="false"/);
        assert.match(result.html, /\/assets\/app\/interactive\.webp/);
        assert.match(result.html, /Every lesson has a door\./);
        assert.doesNotMatch(result.html, /happy users|testimonials|star rating|30,000|1000 unique/);
        assert.equal((result.html.match(/data-early-access/g) || []).length, 4);
    }
    // Everything except the explicitly marked copy and variant attribute is identical.
    function shared(html) {
        return html.replace(/data-copy-variant="[ab]"/, 'data-copy-variant="shared"')
            .replace(/(<(span|h1|h2|p)\b[^>]*data-copy="[^"]+"[^>]*>)[\s\S]*?<\/\2>/g, '$1COPY</$2>');
    }
    assert.equal(shared(a.html), shared(b.html));
});

test('assignment is sticky and private; conditional requests still get complete copy', async () => {
    const first = await get();
    assert(first.cookie);
    assert.match(first.response.headers.get('set-cookie'), /HttpOnly; SameSite=Lax/);
    assert.equal(first.response.headers.get('cache-control'), 'private, no-store');
    assert.equal(first.response.headers.get('x-learnfold-experiment'), 'learning-motivation-waitlist-v3');
    const again = await get('/', { Cookie: first.cookie, 'If-None-Match': '*' });
    assert.equal(again.response.status, 200);
    assert.equal(again.response.headers.get('x-learnfold-variant'), first.response.headers.get('x-learnfold-variant'));
    assert.equal(again.cookie, undefined);
    assert.equal(participant(first.cookie).exposed_at, null, 'HTML assignment alone is not a viewed exposure');
    // The participant row exists once the document has finished streaming.
    assert.equal(participant(first.cookie).variant, first.response.headers.get('x-learnfold-variant'));
    // Return visits carrying the variant cookie keep their copy without another assignment.
    const variantCookie = first.response.headers.get('set-cookie').match(/lf_copy_v3_variant=[ab]/)[0];
    const remembered = await get('/', { Cookie: `${first.cookie}; ${variantCookie}` });
    assert.equal(remembered.response.headers.get('x-learnfold-variant'), first.response.headers.get('x-learnfold-variant'));
    assert.equal(remembered.cookie, undefined);
    assert.match(remembered.html, /<style>/);
});

test('click before exposure, repeats, and demo events count once per participant', async () => {
    const { cookie } = await get();
    assert.equal((await event(cookie, 'early_access')).status, 204);
    const clicked = participant(cookie);
    assert(clicked.exposed_at && clicked.early_access_at);
    await Promise.all([event(cookie,'early_access'), event(cookie,'exposure'), event(cookie,'demo_engaged'), event(cookie,'demo_engaged')]);
    const result = participant(cookie);
    assert.equal(result.exposed_at, clicked.exposed_at);
    assert.equal(result.early_access_at, clicked.early_access_at);
    assert(result.demo_engaged_at);
});

test('previews, privacy headers, bots, and prefetches are not enrolled', async () => {
    const rows = query('SELECT COUNT(*) AS n FROM landing_participants')[0].n;
    for (const [path, headers] of [
        ['/', { DNT:'1' }], ['/', { 'Sec-GPC':'1' }], ['/', { 'User-Agent':'Googlebot' }],
        ['/', { 'Sec-Purpose':'prefetch;prerender' }], ['/?variant=invalid', {}]
    ]) {
        const result = await get(path, headers);
        assert.equal(result.cookie, undefined);
        assert.equal(result.response.headers.get('x-learnfold-experiment'), 'untracked');
    }
    assert.equal(query('SELECT COUNT(*) AS n FROM landing_participants')[0].n, rows);
});

test('measurement rejects cross-origin, preview, malformed, oversized and unknown events', async () => {
    const { cookie } = await get();
    assert.equal((await event(cookie,'early_access',{Origin:'https://unrelated.example'})).status,403);
    assert.equal((await event(cookie,'early_access',{Referer:base+'/?variant=b'})).status,403);
    assert.equal((await event(cookie,'early_access',{Referer:'invalid'})).status,403);
    assert.equal((await event(cookie,'early_access',{},'invalid')).status,400);
    assert.equal((await event(cookie,'arbitrary')).status,400);
    assert.equal((await event(cookie,'early_access',{},'x'.repeat(257))).status,413);
    assert.equal((await event(cookie,'early_access',{'Content-Type':'text/plain'})).status,415);
    assert.equal((await event(cookie,'early_access',{DNT:'1'})).status,204);
    const otherVariant = assignments.get(cookie) === 'a' ? 'b' : 'a';
    assert.equal((await event(cookie,'early_access',{},JSON.stringify({ event:'early_access', variant:otherVariant }))).status,204);
    assert.equal(participant(cookie).exposed_at,null);
});

test('support pages, assets, and error routes stay available', async () => {
    for (const path of ['/support','/privacy','/terms','/landing.js','/experiment.js','/landing.css']) {
        const result = await get(path);
        assert.equal(result.response.status,200,path);
        assert.equal(result.cookie,undefined);
    }
    assert.equal((await get('/this-page-does-not-exist')).response.status,404);
    assert.equal((await fetch(base+'/api/experiment/event')).status,405);
});

async function signup(visitor, email, extra = {}, fields = {}) {
    return fetch(base + '/api/waitlist', { method: 'POST', headers: {
        'User-Agent': agent, Connection: 'close', Origin: base, Referer: base + '/', 'Content-Type': 'application/json', Cookie: visitor.cookie || '', ...extra
    }, body: JSON.stringify({ email, consent: true, company: '', variant: visitor.response.headers.get('x-learnfold-variant'), ...fields }) });
}
test('waitlist validates, saves consent, deduplicates concurrent signups and queues a real conversion', async () => {
    query('DELETE FROM waitlist_rate_limits');
    const visitor = await get();
    const email = `qa-${crypto.randomUUID()}@example.com`;
    assert.equal((await signup(visitor, 'not an email')).status, 400);
    assert.equal((await signup(visitor, email, {}, { consent: false })).status, 400);
    assert.equal((await signup(visitor, email, { Origin: 'https://other.example' })).status, 403);
    assert.equal((await signup(visitor, email, {}, { company: 'spam' })).status, 200);
    assert.equal(query(`SELECT * FROM waitlist_entries WHERE email = '${email}'`).length, 0);
    const results = await Promise.all([signup(visitor, email.toUpperCase()), signup(visitor, email)]);
    assert(results.every(r => r.status === 200));
    const rows = query(`SELECT * FROM waitlist_entries WHERE email = '${email}'`);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].consent_version, 'early-access-2026-09-09');
    assert.equal(rows[0].participant_hash, hash(visitor.cookie));
    assert(participant(visitor.cookie).waitlist_at);
    assert(participant(visitor.cookie).exposed_at);
    const outbox = query(`SELECT * FROM analytics_outbox WHERE participant_hash = '${hash(visitor.cookie)}'`);
    assert.equal(outbox.filter(r=>r.event === 'waitlist_joined').length, 1);
    assert.equal(outbox.filter(r=>r.event === 'landing_viewed').length, 1);
    assert(!JSON.stringify(outbox).includes(email));
    const other = await get();
    assert.equal((await signup(other, email)).status, 200);
    assert.equal(participant(other.cookie).waitlist_at, null);
});

test('preview and privacy opt-out signups save email without experiment attribution', async () => {
    query('DELETE FROM waitlist_rate_limits');
    const visitor = await get();
    for (const headers of [{ Referer: base + '/?variant=b' }, { DNT: '1' }, { 'Sec-GPC': '1' }, { Referer: '' }]) {
        const email = `untracked-${crypto.randomUUID()}@example.com`;
        assert.equal((await signup(visitor, email, headers)).status, 200);
        const row = query(`SELECT * FROM waitlist_entries WHERE email = '${email}'`)[0];
        assert.equal(row.experiment, null);
        assert.equal(row.participant_hash, null);
    }
    assert.equal(participant(visitor.cookie).waitlist_at, null);
});

test('waitlist rate limit and payload limit cannot inflate saved signups', async () => {
    query('DELETE FROM waitlist_rate_limits');
    const visitor = await get();
    const email = `limit-${crypto.randomUUID()}@example.com`;
    for (let i=0;i<10;i++) assert.equal((await signup(visitor, email)).status,200);
    const limited = await signup(visitor, `rejected-${email}`);
    assert.equal(limited.status,429);
    assert(Number(limited.headers.get('retry-after')) > 0);
    assert.equal(query(`SELECT * FROM waitlist_entries WHERE email = 'rejected-${email}'`).length,0);
    assert.equal((await signup(visitor, email, {}, { padding: 'x'.repeat(3000) })).status,413);
    query('DELETE FROM waitlist_rate_limits');
});

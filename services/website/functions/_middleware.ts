import { flushAnalytics } from '../lib/analytics';
import { CHALLENGER, COOKIE, EXPERIMENT, MAX_AGE, VARIANT_COOKIE, eligible, hashToken, previewVariant, readToken, readVariant, responseHeaders, type Participant, type Variant } from '../lib/experiment';

export const onRequest: PagesFunction<Env> = async (context) => {
    const url = new URL(context.request.url);
    if (!['/', '/index.html'].includes(url.pathname) || context.request.method !== 'GET') return context.next();

    // A conditional asset response cannot be rewritten. Always start from the complete static page.
    const assetRequest = new Request(context.request);
    assetRequest.headers.delete('If-None-Match');
    assetRequest.headers.delete('If-Modified-Since');
    // The stylesheet is inlined so first paint does not wait for a second request.
    const stylesheet = context.env.ASSETS.fetch(new URL('/landing.css', url))
        .then((response) => response.ok ? response.text() : null)
        .catch(() => null);
    const source = await context.next(assetRequest);
    if (source.status !== 200 || !source.headers.get('Content-Type')?.includes('text/html')) return source;

    let variant: Variant = previewVariant(url) ?? 'a';
    let tracking = false;
    const newCookies: string[] = [];
    // Work the document must not finish before. The HTML streams immediately; the final byte waits.
    let enrollment: Promise<unknown> | null = null;
    if (eligible(context.request, context.env)) {
        try {
            const now = Math.floor(Date.now() / 1000);
            const token = readToken(context.request);
            const remembered = token ? readVariant(context.request) : null;
            const existing = remembered ? null : token ? await context.env.EXPERIMENTS.prepare(
                'SELECT variant, expires_at FROM landing_participants WHERE experiment = ? AND participant_hash = ? AND expires_at > ?'
            ).bind(EXPERIMENT, await hashToken(token), now).first<Participant>() : null;
            if (remembered) {
                // The variant cookie is set with the assignment and expires with it, so return visits skip D1.
                variant = remembered;
            } else if (existing) {
                variant = existing.variant;
            } else {
                const nextToken = crypto.randomUUID();
                variant = crypto.getRandomValues(new Uint8Array(1))[0] < 128 ? 'a' : 'b';
                enrollment = context.env.EXPERIMENTS.prepare(
                    'INSERT INTO landing_participants (experiment, participant_hash, variant, enrolled_at, expires_at) VALUES (?, ?, ?, ?, ?)'
                ).bind(EXPERIMENT, await hashToken(nextToken), variant, now, now + MAX_AGE).run()
                    .catch(() => { console.error(JSON.stringify({ event: 'experiment_assignment_failed' })); });
                const attributes = `Path=/; Max-Age=${MAX_AGE}; HttpOnly; SameSite=Lax${url.protocol === 'https:' ? '; Secure' : ''}`;
                newCookies.push(`${COOKIE}=${nextToken}; ${attributes}`, `${VARIANT_COOKIE}=${variant}; ${attributes}`);
            }
            tracking = true;
            context.waitUntil(flushAnalytics(context.env));
            context.waitUntil(context.env.EXPERIMENTS.prepare('DELETE FROM analytics_outbox WHERE occurred_at < unixepoch() - 90*86400').run().catch(() => {}));
            // Keep results for 90 days; assignment cookies last 30 days. Cleanup runs during site use.
            context.waitUntil(context.env.EXPERIMENTS.prepare(
                'DELETE FROM landing_participants WHERE expires_at <= ?'
            ).bind(now - 60 * 24 * 60 * 60).run().catch(() => { console.error(JSON.stringify({ event: 'experiment_cleanup_failed' })); }));
        } catch {
            // An experiment failure must not take the landing page down or count a false exposure.
            variant = 'a';
            tracking = false;
            newCookies.length = 0;
            console.error(JSON.stringify({ event: 'experiment_assignment_failed' }));
        }
    }

    const response = new Response(source.body, source);
    responseHeaders().forEach((value, key) => response.headers.set(key, value));
    response.headers.delete('ETag');
    response.headers.delete('Last-Modified');
    response.headers.delete('Content-Length');
    response.headers.set('X-Learnfold-Variant', variant);
    response.headers.set('X-Learnfold-Experiment', tracking ? EXPERIMENT : 'untracked');
    if (previewVariant(url)) response.headers.set('X-Robots-Tag', 'noindex, nofollow');
    newCookies.forEach((cookie) => response.headers.append('Set-Cookie', cookie));

    const css = await stylesheet;
    const page = new HTMLRewriter()
        .on('html', { element(element) { element.setAttribute('data-copy-variant', variant); } })
        .on('body', { element(element) { element.setAttribute('data-experiment-active', String(tracking)); } })
        .on('link[rel="stylesheet"][href="/landing.css"]', { element(element) {
            if (css && !css.includes('</style')) element.replace(`<style>${css}</style>`, { html: true });
        } })
        .on('[data-copy]', { element(element) {
            const copy = CHALLENGER[element.getAttribute('data-copy') ?? ''];
            if (variant === 'b' && copy) element.setInnerContent(copy, { html: true });
        } })
        .transform(response);
    if (!enrollment || !page.body) return page;

    // Deferred scripts run only once the document is complete, so holding the end of the stream until
    // the participant row exists keeps measurement events from arriving before their row.
    const pending = enrollment;
    const held = new TransformStream<Uint8Array, Uint8Array>({ flush: () => pending.then(() => undefined) });
    context.waitUntil(page.body.pipeTo(held.writable).catch(() => {}));
    return new Response(held.readable, page);
};

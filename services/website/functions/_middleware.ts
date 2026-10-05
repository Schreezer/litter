import { flushAnalytics } from '../lib/analytics';
import { CHALLENGER, COOKIE, EXPERIMENT, MAX_AGE, eligible, hashToken, previewVariant, readToken, responseHeaders, type Participant, type Variant } from '../lib/experiment';

export const onRequest: PagesFunction<Env> = async (context) => {
    const url = new URL(context.request.url);
    if (!['/', '/index.html'].includes(url.pathname) || context.request.method !== 'GET') return context.next();

    // A conditional asset response cannot be rewritten. Always start from the complete static page.
    const assetRequest = new Request(context.request);
    assetRequest.headers.delete('If-None-Match');
    assetRequest.headers.delete('If-Modified-Since');
    const source = await context.next(assetRequest);
    if (source.status !== 200 || !source.headers.get('Content-Type')?.includes('text/html')) return source;

    let variant: Variant = previewVariant(url) ?? 'a';
    let tracking = false;
    let newCookie: string | null = null;
    if (eligible(context.request, context.env)) {
        try {
            const now = Math.floor(Date.now() / 1000);
            const token = readToken(context.request);
            const existing = token ? await context.env.EXPERIMENTS.prepare(
                'SELECT variant, expires_at FROM landing_participants WHERE experiment = ? AND participant_hash = ? AND expires_at > ?'
            ).bind(EXPERIMENT, await hashToken(token), now).first<Participant>() : null;
            if (existing) {
                variant = existing.variant;
            } else {
                const nextToken = crypto.randomUUID();
                variant = crypto.getRandomValues(new Uint8Array(1))[0] < 128 ? 'a' : 'b';
                await context.env.EXPERIMENTS.prepare(
                    'INSERT INTO landing_participants (experiment, participant_hash, variant, enrolled_at, expires_at) VALUES (?, ?, ?, ?, ?)'
                ).bind(EXPERIMENT, await hashToken(nextToken), variant, now, now + MAX_AGE).run();
                newCookie = `${COOKIE}=${nextToken}; Path=/; Max-Age=${MAX_AGE}; HttpOnly; SameSite=Lax${url.protocol === 'https:' ? '; Secure' : ''}`;
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
    if (newCookie) response.headers.append('Set-Cookie', newCookie);

    return new HTMLRewriter()
        .on('html', { element(element) { element.setAttribute('data-copy-variant', variant); } })
        .on('body', { element(element) { element.setAttribute('data-experiment-active', String(tracking)); } })
        .on('[data-copy]', { element(element) {
            const copy = CHALLENGER[element.getAttribute('data-copy') ?? ''];
            if (variant === 'b' && copy) element.setInnerContent(copy, { html: true });
        } })
        .transform(response);
};

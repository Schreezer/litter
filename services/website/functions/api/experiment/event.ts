import { flushAnalytics } from '../../../lib/analytics';
import { EXPERIMENT, eligible, hashToken, readToken, responseHeaders } from '../../../lib/experiment';

const columns: Record<string, string> = {
    exposure: 'exposed_at', early_access: 'early_access_at', demo_engaged: 'demo_engaged_at'
};

export const onRequest: PagesFunction<Env> = async (context) => {
    const request = context.request;
    const headers = responseHeaders();
    const reply = (status: number) => new Response(null, { status, headers });
    if (request.method !== 'POST') { headers.set('Allow', 'POST'); return reply(405); }
    const url = new URL(request.url);
    if (request.headers.get('Origin') !== url.origin) return reply(403);
    if (!eligible(request, context.env)) return reply(204);
    // Preview pages never count, even when this browser already has a real assignment.
    const referer = request.headers.get('Referer');
    if (!referer) return reply(403);
    let referringURL: URL;
    try { referringURL = new URL(referer); } catch { return reply(403); }
    if (referringURL.origin !== url.origin || !['/', '/index.html'].includes(referringURL.pathname)
        || referringURL.searchParams.has('variant')) return reply(403);
    const token = readToken(request);
    if (!token) return reply(204);
    if (!request.headers.get('Content-Type')?.startsWith('application/json')) return reply(415);

    // Bound actual streamed bytes as well as declared Content-Length.
    if (Number(request.headers.get('Content-Length') || 0) > 256) return reply(413);
    const reader = request.body?.getReader();
    if (!reader) return reply(400);
    let body = '';
    let bytes = 0;
    const decoder = new TextDecoder();
    while (true) {
        const part = await reader.read();
        if (part.done) break;
        bytes += part.value.byteLength;
        if (bytes > 256) { await reader.cancel(); return reply(413); }
        body += decoder.decode(part.value, { stream: true });
    }
    body += decoder.decode();
    let event: unknown;
    try { event = JSON.parse(body); } catch { return reply(400); }
    if (!event || typeof event !== 'object' || !('event' in event) || typeof event.event !== 'string'
        || !Object.hasOwn(columns, event.event) || !('variant' in event)
        || (event.variant !== 'a' && event.variant !== 'b')) return reply(400);
    const column = columns[event.event];
    const update = column === 'exposed_at'
        ? 'exposed_at = COALESCE(exposed_at, ?)'
        : `exposed_at = COALESCE(exposed_at, ?), ${column} = COALESCE(${column}, ?)`;
    try {
        const now = Math.floor(Date.now() / 1000);
        // First click also confirms exposure, so beacon arrival order cannot inflate the rate.
        const values = column === 'exposed_at' ? [now] : [now, now];
        await context.env.EXPERIMENTS.prepare(
            `UPDATE landing_participants SET ${update}
             WHERE experiment = ? AND participant_hash = ? AND expires_at > ? AND variant = ?`
        ).bind(...values, EXPERIMENT, await hashToken(token), now, event.variant).run();
        context.waitUntil(flushAnalytics(context.env));
        return reply(204);
    } catch {
        console.error(JSON.stringify({ event: 'experiment_measurement_failed' }));
        return reply(503);
    }
};

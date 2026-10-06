import { EXPERIMENT, eligible, hashToken, readToken, responseHeaders } from '../../lib/experiment';
import { flushAnalytics } from '../../lib/analytics';

type WaitlistEnv = Env & { WAITLIST_RATE_SALT: string; MAIL_ENABLED?: string };
export const onRequest: PagesFunction<WaitlistEnv> = async context => {
    const { request, env } = context;
    const headers = responseHeaders();
    headers.set('Content-Type', 'application/json');
    const reply = (status: number, message: string) => new Response(JSON.stringify({ message }), { status, headers });
    if (request.method !== 'POST') { headers.set('Allow', 'POST'); return reply(405, 'Use the signup form.'); }
    const url = new URL(request.url);
    if (request.headers.get('Origin') !== url.origin) return reply(403, 'Please submit from Learnfold.');
    if (!request.headers.get('Content-Type')?.startsWith('application/json')) return reply(415, 'Please use the signup form.');
    if (Number(request.headers.get('Content-Length') || 0) > 2048) return reply(413, 'Form is too long.');
    let body: unknown;
    try {
        const reader = request.body?.getReader();
        if (!reader) return reply(400, 'Please fill in the form.');
        let size = 0, text = '';
        const decoder = new TextDecoder();
        while (true) {
            const part = await reader.read();
            if (part.done) break;
            size += part.value.byteLength;
            if (size > 2048) { await reader.cancel(); return reply(413, 'Form is too long.'); }
            text += decoder.decode(part.value, { stream: true });
        }
        body = JSON.parse(text + decoder.decode());
    } catch { return reply(400, 'Please fill in the form.'); }
    if (!body || typeof body !== 'object') return reply(400, 'Please fill in the form.');
    const data = body as Record<string, unknown>;
    const success = "You're on the list. We'll email you when there's early access to share.";
    if (typeof data.company === 'string' && data.company) return reply(200, success);
    const email = typeof data.email === 'string' ? data.email.trim().toLowerCase() : '';
    // Deliberately accept a conservative ASCII mailbox format without altering dots or plus tags.
    const parts = email.split('@');
    if (email.length > 254 || parts.length !== 2 || parts[0].length > 64 || !/^[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/.test(email)) return reply(400, 'Enter a valid email address.');
    if (data.consent !== true) return reply(400, 'Please agree to early-access emails to join.');
    try {
        if (!env.WAITLIST_RATE_SALT) throw new Error('Rate limit not configured');
        const now = Math.floor(Date.now() / 1000);
        const ip = request.headers.get('CF-Connecting-IP') || 'local';
        const window = Math.floor(now / 3600);
        const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(env.WAITLIST_RATE_SALT), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
        const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${window}:${ip}`));
        const rateKey = Array.from(new Uint8Array(signature), b => b.toString(16).padStart(2, '0')).join('');
        const rate = await env.EXPERIMENTS.prepare(`INSERT INTO waitlist_rate_limits (key,attempts,expires_at) VALUES (?,1,?)
            ON CONFLICT(key) DO UPDATE SET attempts = attempts + 1 RETURNING attempts`).bind(rateKey, (window + 1) * 3600).first<{ attempts: number }>();
        if (!rate || rate.attempts > 10) { headers.set('Retry-After', String((window + 1)*3600 - now)); return reply(429, 'Too many attempts. Please try again in an hour.'); }
        let participant: { participant_hash: string; variant: string } | null = null;
        const token = readToken(request);
        let referring: URL | null = null;
        try { referring = new URL(request.headers.get('Referer') || ''); } catch { /* Signup still works without attribution. */ }
        if (token && eligible(request, env) && referring?.origin === url.origin
            && ['/', '/index.html'].includes(referring.pathname) && !referring.searchParams.has('variant')) {
            participant = await env.EXPERIMENTS.prepare(`SELECT participant_hash, variant FROM landing_participants
                WHERE experiment = ? AND participant_hash = ? AND expires_at > ? AND variant = ?`)
                .bind(EXPERIMENT, await hashToken(token), now, typeof data.variant === 'string' ? data.variant : '').first();
        }
        const id = crypto.randomUUID();
        // One transaction: only a newly stored email can produce a conversion. Duplicate requests return the same safe message.
        await env.EXPERIMENTS.batch([
            env.EXPERIMENTS.prepare(`INSERT INTO waitlist_entries (id,email,created_at,consent_version,experiment,variant,participant_hash,unsubscribe_token)
                VALUES (?,?,?,'early-access-2026-09-09',?,?,?,?) ON CONFLICT(email) DO NOTHING`)
                .bind(id, email, now, participant ? EXPERIMENT : null, participant?.variant ?? null, participant?.participant_hash ?? null, crypto.randomUUID() + crypto.randomUUID()),
            env.EXPERIMENTS.prepare(`UPDATE landing_participants SET exposed_at = COALESCE(exposed_at,?), waitlist_at = COALESCE(waitlist_at,?)
                WHERE experiment = ? AND participant_hash = ? AND EXISTS (SELECT 1 FROM waitlist_entries WHERE id = ?)`)
                .bind(now, now, EXPERIMENT, participant?.participant_hash ?? '', id),
            env.EXPERIMENTS.prepare(`INSERT INTO mail_outbox (id,next_attempt_at,updated_at) SELECT id,?,? FROM waitlist_entries WHERE id=? AND ?='true' ON CONFLICT(id) DO NOTHING`).bind(now,now,id,env.MAIL_ENABLED ?? 'false')
        ]);
        context.waitUntil(flushAnalytics(env));
        context.waitUntil(env.EXPERIMENTS.prepare('DELETE FROM waitlist_rate_limits WHERE expires_at < ?').bind(now).run().catch(() => {}));
        return reply(200, success);
    } catch {
        console.error(JSON.stringify({ event: 'waitlist_save_failed' }));
        return reply(503, "We couldn't save your email. Please try again shortly.");
    }
};

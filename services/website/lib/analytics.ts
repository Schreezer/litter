// Server-only, explicit events. Never forward form fields, URLs, headers or IP addresses.
type AnalyticsEnv = Env & { POSTHOG_PROJECT_KEY?: string; POSTHOG_HOST?: string };
export async function flushAnalytics(env: AnalyticsEnv): Promise<void> {
    if (!env.POSTHOG_PROJECT_KEY) return;
    try {
        const host = new URL(env.POSTHOG_HOST || 'https://us.i.posthog.com');
        if (host.protocol !== 'https:') throw new Error('HTTPS required');
        const rows = await env.EXPERIMENTS.prepare(
            'SELECT * FROM analytics_outbox WHERE delivered_at IS NULL AND occurred_at > unixepoch() - 90*86400 ORDER BY occurred_at, id LIMIT 50'
        ).all<{ id: string; experiment: string; participant_hash: string; variant: string; event: string; occurred_at: number }>();
        if (!rows.results.length) return;
        const batch = await Promise.all(rows.results.map(async row => {
            // Stable UUID lets PostHog deduplicate concurrent delivery and retries.
            const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(row.id))), b => b.toString(16).padStart(2, '0')).join('');
            return { uuid: `${hash.slice(0,8)}-${hash.slice(8,12)}-4${hash.slice(13,16)}-8${hash.slice(17,20)}-${hash.slice(20,32)}`,
                event: row.event, timestamp: new Date(row.occurred_at * 1000).toISOString(),
                properties: { distinct_id: row.participant_hash, experiment: row.experiment, variant: row.variant,
                    $process_person_profile: false, $geoip_disable: true, $ip: null, source: 'learnfold_landing' } };
        }));
        const response = await fetch(new URL('/batch/', host), {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ api_key: env.POSTHOG_PROJECT_KEY, batch }), signal: AbortSignal.timeout(8000)
        });
        if (!response.ok) throw new Error('Capture rejected');
        await response.arrayBuffer();
        await env.EXPERIMENTS.batch(rows.results.map(row => env.EXPERIMENTS.prepare(
            'UPDATE analytics_outbox SET delivered_at = unixepoch() WHERE id = ?'
        ).bind(row.id)));
    } catch { console.error(JSON.stringify({ event: 'posthog_delivery_failed' })); }
}

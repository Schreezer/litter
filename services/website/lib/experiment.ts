export const EXPERIMENT = 'learning-motivation-waitlist-v3';
export const COOKIE = 'lf_copy_v3';
export const VARIANT_COOKIE = 'lf_copy_v3_variant';
export const MAX_AGE = 30 * 24 * 60 * 60;
export type Variant = 'a' | 'b';
export type Participant = { variant: Variant; expires_at: number };

// Copy only. Product examples, layout, and CTA text/destinations stay shared.
export const CHALLENGER: Record<string, string> = {
    headline: 'Less scrolling. <em>More understanding.</em>',
    introduction: 'The things you would normally scroll past can become a short course on your iPhone. Paste a link, a PDF, or a thought. Ask questions as you read, and keep the answers that deserve a place in it.',
    invitation: 'Ten minutes of reading that stays with you.',
    whyEyebrow: 'Built for the curious hour',
    whyHeadline: 'Give one idea the time you would give a feed.',
    whyBody: 'Swap a scroll for a short course. Read a page, ask about whatever does not click, and keep the answers worth keeping as pages in the course instead of tabs you will close.',
    closingEyebrow: 'Next time you reach for your phone',
    closingHeadline: 'Learn something instead.',
    closingBody: 'Join the waitlist and we will email you when a spot opens on iOS.'
};

export function previewVariant(url: URL): Variant | null {
    const variant = url.searchParams.get('variant');
    return variant === 'a' || variant === 'b' ? variant : null;
}

export function eligible(request: Request, env: Env): boolean {
    const url = new URL(request.url);
    return env.COPY_EXPERIMENT_MODE === 'active'
        && url.hostname === env.COPY_EXPERIMENT_HOST
        && !url.searchParams.has('variant')
        && request.headers.get('DNT') !== '1'
        && request.headers.get('Sec-GPC') !== '1'
        && !/bot|crawler|spider|preview|facebookexternalhit|headless/i.test(request.headers.get('User-Agent') || '')
        && !/prefetch|prerender/i.test(`${request.headers.get('Purpose')} ${request.headers.get('Sec-Purpose')}`);
}

export function readToken(request: Request): string | null {
    const token = request.headers.get('Cookie')?.split(';')
        .map((part) => part.trim()).find((part) => part.startsWith(`${COOKIE}=`))?.slice(COOKIE.length + 1);
    return token && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(token) ? token : null;
}

export function readVariant(request: Request): Variant | null {
    const value = request.headers.get('Cookie')?.split(';')
        .map((part) => part.trim()).find((part) => part.startsWith(`${VARIANT_COOKIE}=`))?.slice(VARIANT_COOKIE.length + 1);
    return value === 'a' || value === 'b' ? value : null;
}

export async function hashToken(token: string): Promise<string> {
    const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${EXPERIMENT}:${token}`));
    return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function responseHeaders(): Headers {
    return new Headers({
        'Cache-Control': 'private, no-store',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'Referrer-Policy': 'strict-origin-when-cross-origin'
    });
}

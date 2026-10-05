import { responseHeaders } from '../../lib/experiment';
export const onRequest: PagesFunction<Env> = async ({request,env}) => {
 const headers=responseHeaders(); headers.set('Content-Type','text/html; charset=utf-8'); headers.set('Referrer-Policy','no-referrer'); headers.set('X-Robots-Tag','noindex');
 const token=new URL(request.url).searchParams.get('token')??'';
 const page=(text:string,form=false,status=200)=>new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Learnfold email preferences</title><body style="font:18px system-ui;max-width:40rem;margin:10vh auto;padding:24px"><h1>Learnfold email preferences</h1><p>${text}</p>${form?'<form method="post"><button style="padding:12px 20px;font:inherit">Unsubscribe</button></form>':''}<p><a href="https://learnfold.pages.dev/">Back to Learnfold</a></p></body></html>`,{status,headers});
 if (!/^[a-f0-9-]{72}$/.test(token)) return page('This link is invalid. Contact chirag@forgeme.xyz for help.',false,400);
 if (request.method==='GET') return page('Click below to stop receiving Learnfold waitlist emails.',true);
 if (request.method!=='POST') {headers.set('Allow','GET, POST');return page('Use the unsubscribe button.',false,405);}
 try {
  await env.EXPERIMENTS.batch([
   env.EXPERIMENTS.prepare('UPDATE waitlist_entries SET unsubscribed_at=COALESCE(unsubscribed_at,unixepoch()) WHERE unsubscribe_token=?').bind(token),
   env.EXPERIMENTS.prepare("UPDATE mail_outbox SET state='cancelled',updated_at=unixepoch() WHERE state='pending' AND id IN (SELECT id FROM waitlist_entries WHERE unsubscribe_token=?)").bind(token)
  ]);
  return page("You're unsubscribed from Learnfold waitlist emails.");
 } catch { return page('We could not save your preference. Please try again.',false,503); }
};

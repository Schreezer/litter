import { AwsClient } from 'aws4fetch';

export type MailEnv = Env & {
 MAIL_ENABLED?: string; AWS_ACCESS_KEY_ID?: string; AWS_SECRET_ACCESS_KEY?: string;
 MAIL_REGION?: string; MAIL_FROM?: string; MAIL_REPLY_TO?: string;
};
type MailRow = { id: string; email: string; unsubscribe_token: string; attempts: number };
export function welcomeMail(token: string) {
 const unsubscribe = `https://learnfold.pages.dev/api/unsubscribe?token=${encodeURIComponent(token)}`;
 const text = `You're on the Learnfold waitlist.\n\nLearnfold turns a question into a course you can keep exploring. Follow a new question into a page, sub-page, or folder, and return to your course whenever you're ready.\n\nWe'll email you when there's early access to share.\n\nIf you didn't sign up or no longer want these emails, unsubscribe here:\n${unsubscribe}\n\nLearnfold\nhttps://learnfold.pages.dev/`;
 return { Subject: { Data: "You're on the Learnfold waitlist", Charset: 'UTF-8' }, Body: { Text: { Data: text, Charset: 'UTF-8' } }, Headers: [{ Name: 'List-Unsubscribe', Value: `<${unsubscribe}>` }, { Name: 'List-Unsubscribe-Post', Value: 'List-Unsubscribe=One-Click' }] };
}
export async function flushMail(env: MailEnv) {
 if (env.MAIL_ENABLED !== 'true') return;
 if (!env.AWS_ACCESS_KEY_ID || !env.AWS_SECRET_ACCESS_KEY || !env.MAIL_FROM || !env.MAIL_REGION) throw new Error('Mail configuration missing');
 const now = Math.floor(Date.now()/1000);
 // A crash after SES accepted a message is ambiguous. Never automatically send that message again.
 await env.EXPERIMENTS.prepare("UPDATE mail_outbox SET state='uncertain',error_code='interrupted_send' WHERE state='sending' AND updated_at < ?").bind(now-300).run();
 const rows = await env.EXPERIMENTS.prepare(`SELECT m.id,w.email,w.unsubscribe_token,m.attempts FROM mail_outbox m JOIN waitlist_entries w ON w.id=m.id
 WHERE m.state='pending' AND m.next_attempt_at<=? AND w.unsubscribed_at IS NULL AND w.unsubscribe_token IS NOT NULL ORDER BY m.next_attempt_at LIMIT 10`).bind(now).all<MailRow>();
 const aws = new AwsClient({accessKeyId:env.AWS_ACCESS_KEY_ID,secretAccessKey:env.AWS_SECRET_ACCESS_KEY,region:env.MAIL_REGION,service:'ses',retries:0});
 for (const row of rows.results) {
  const claim = await env.EXPERIMENTS.prepare(`UPDATE mail_outbox SET state='sending',attempts=attempts+1,updated_at=? WHERE id=? AND state='pending'
   AND EXISTS (SELECT 1 FROM waitlist_entries WHERE id=? AND unsubscribed_at IS NULL) RETURNING id`).bind(now,row.id,row.id).first();
  if (!claim) continue;
  let state='uncertain', error: string|null='transport_error', messageId: string|null=null;
  try {
   const response = await aws.fetch(`https://email.${env.MAIL_REGION}.amazonaws.com/v2/email/outbound-emails`, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({FromEmailAddress:env.MAIL_FROM,ReplyToAddresses:env.MAIL_REPLY_TO?[env.MAIL_REPLY_TO]:undefined,Destination:{ToAddresses:[row.email]},Content:{Simple:welcomeMail(row.unsubscribe_token)},EmailTags:[{Name:'application',Value:'learnfold'},{Name:'purpose',Value:'waitlist_welcome'}]}),signal:AbortSignal.timeout(10000)});
   if (response.ok) {
    const data = await response.json() as {MessageId?:string};
    messageId=data.MessageId??null; state=messageId?'accepted':'uncertain'; error=messageId?null:'missing_message_id';
   } else {
    // Explicit rejection can be retried; transport timeouts cannot safely be retried.
    error=`ses_http_${response.status}`;
    state=(response.status===429 || response.status===503) && row.attempts<4?'pending':'failed';
    await response.body?.cancel();
   }
  } catch { /* Keep uncertain so operators can reconcile before retrying. */ }
  await env.EXPERIMENTS.prepare('UPDATE mail_outbox SET state=?,message_id=?,error_code=?,updated_at=?,next_attempt_at=? WHERE id=? AND state=\'sending\'')
   .bind(state,messageId,error,Math.floor(Date.now()/1000),now+60*2**row.attempts,row.id).run();
  console.log(JSON.stringify({event:'waitlist_mail_result',id:row.id,state,error}));
 }
}

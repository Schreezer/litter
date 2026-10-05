import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
const db=sql=>JSON.parse(execFileSync('./node_modules/.bin/wrangler',['d1','execute','EXPERIMENTS','--local','--command',sql,'--json'],{encoding:'utf8'}))[0].results;
test('unsubscribe GET is safe from link scanners; POST cancels mail and duplicate signup does not reactivate',async()=>{
 const id=randomUUID(),token=randomUUID()+randomUUID(),email=`unsubscribe-${id}@example.com`;
 db(`INSERT INTO waitlist_entries(id,email,created_at,consent_version,unsubscribe_token) VALUES ('${id}','${email}',unixepoch(),'test','${token}'); INSERT INTO mail_outbox(id,next_attempt_at,updated_at) VALUES ('${id}',unixepoch(),unixepoch());`);
 try{
 const url=`http://127.0.0.1:4174/api/unsubscribe?token=${token}`;
 let r=await fetch(url,{headers:{Connection:'close'}});assert.equal(r.status,200);await r.text();
 assert.equal(db(`SELECT unsubscribed_at FROM waitlist_entries WHERE id='${id}'`)[0].unsubscribed_at,null);
 r=await fetch(url,{method:'POST',headers:{Connection:'close'}});assert.equal(r.status,200);await r.text();
 assert.ok(db(`SELECT unsubscribed_at FROM waitlist_entries WHERE id='${id}'`)[0].unsubscribed_at);
 assert.equal(db(`SELECT state FROM mail_outbox WHERE id='${id}'`)[0].state,'cancelled');
 r=await fetch('http://127.0.0.1:4174/api/waitlist',{method:'POST',headers:{Origin:'http://127.0.0.1:4174','Content-Type':'application/json',Connection:'close','CF-Connecting-IP':'192.0.2.249'},body:JSON.stringify({email,consent:true})});assert.equal(r.status,200);await r.text();
 assert.ok(db(`SELECT unsubscribed_at FROM waitlist_entries WHERE id='${id}'`)[0].unsubscribed_at);
 }finally{db(`DELETE FROM mail_outbox WHERE id='${id}'; DELETE FROM waitlist_entries WHERE id='${id}';`);}
});

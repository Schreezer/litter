import test from 'node:test';
import assert from 'node:assert/strict';
import ts from 'typescript';
import {readFileSync} from 'node:fs';
let source=ts.transpileModule(readFileSync(new URL('../lib/mail.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
source=source.replace("'aws4fetch'",JSON.stringify(import.meta.resolve('aws4fetch')));
const {flushMail,welcomeMail}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
test('welcome includes usable unsubscribe link and one-click header',()=>{
 const mail=welcomeMail('a'.repeat(72));
 assert.match(mail.Body.Text.Data,/api\/unsubscribe\?token=/);
 assert.equal(mail.Headers[1].Value,'List-Unsubscribe=One-Click');
 assert.doesNotMatch(mail.Body.Text.Data,/spots|thousands|reviews/);
});
test('mail records acceptance, retries explicit throttling, and holds ambiguous sends',async()=>{
 const original=globalThis.fetch, log=console.log;
 try {
 console.log=()=>{};
 for (const [outcome,expected] of [[200,'accepted'],[429,'pending'],[400,'failed'],['timeout','uncertain']]) {
 let state='pending',calls=0;
 const row={id:'test',email:'success@simulator.amazonses.com',unsubscribe_token:'a'.repeat(72),attempts:0};
 const env={MAIL_ENABLED:'true',MAIL_FROM:'Learnfold <test@example.com>',MAIL_REGION:'us-east-1',AWS_ACCESS_KEY_ID:'TEST',AWS_SECRET_ACCESS_KEY:'test-secret',EXPERIMENTS:{prepare(sql){let args=[];return {bind(...values){args=values;return this;},async all(){return {results:[row]};},async first(){if(state!=='pending')return null;state='sending';return {id:row.id};},async run(){if(sql.startsWith('UPDATE mail_outbox SET state=?'))state=args[0];return {};}};}}};
 globalThis.fetch=async req=>{calls++;assert.match(req.headers.get('Authorization'),/AWS4-HMAC-SHA256/);assert.equal(new URL(req.url).host,'email.us-east-1.amazonaws.com');if(outcome==='timeout')throw Error('timeout');return new Response(JSON.stringify({MessageId:'ses-accepted-id'}),{status:outcome});};
 await flushMail(env);assert.equal(state,expected);assert.equal(calls,1);
 if(expected!=='pending'){await flushMail(env);assert.equal(calls,1);}
 await flushMail({...env,MAIL_ENABLED:'false'});assert.equal(calls,1);
 }
 }finally{globalThis.fetch=original;console.log=log;}
});

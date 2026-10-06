#!/usr/bin/env python3
"""Create a Learnfold-only SES principal and upload credentials directly to the mail Worker.
Usage: python3 scripts/configure-mail-credentials.py --domain example.com --sender hello@example.com
No AWS credentials are written to source files or printed. Run once after SES verifies the sender domain.
"""
import argparse, json, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--domain',required=True);p.add_argument('--sender',required=True)
a=p.parse_args()
if a.sender.split('@')[-1]!=a.domain:p.error('Sender must belong to domain')
root=Path(__file__).resolve().parents[1]
def aws(*args):
 r=subprocess.run(['aws',*args,'--no-cli-pager','--output','json'],capture_output=True,text=True)
 if r.returncode:raise RuntimeError(r.stderr)
 return json.loads(r.stdout) if r.stdout.strip() else {}
account=aws('sts','get-caller-identity')['Account']
identity=aws('sesv2','get-email-identity','--region','us-east-1','--email-identity',a.domain)
if not identity.get('VerifiedForSendingStatus'):raise RuntimeError('Sender domain not verified')
user='learnfold-waitlist-mail'
try: aws('iam','get-user','--user-name',user)
except RuntimeError as e:
 if 'NoSuchEntity' not in str(e):raise
 aws('iam','create-user','--user-name',user,'--tags','Key=application,Value=learnfold')
policy={'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'ses:SendEmail','Resource':f'arn:aws:ses:us-east-1:{account}:identity/{a.domain}','Condition':{'StringEquals':{'ses:FromAddress':a.sender}}}]}
aws('iam','put-user-policy','--user-name',user,'--policy-name','SendLearnfoldWelcome','--policy-document',json.dumps(policy))
if aws('iam','list-access-keys','--user-name',user)['AccessKeyMetadata']:
 raise RuntimeError('Existing key found; preserve it. Rotate explicitly if required.')
key=aws('iam','create-access-key','--user-name',user)['AccessKey']
try:
 for name,value in [('AWS_ACCESS_KEY_ID',key['AccessKeyId']),('AWS_SECRET_ACCESS_KEY',key['SecretAccessKey'])]:
  subprocess.run([str(root/'node_modules/.bin/wrangler'),'secret','put',name,'--config','mail-worker/wrangler.toml'],cwd=root,input=value,text=True,check=True)
except Exception:
 aws('iam','delete-access-key','--user-name',user,'--access-key-id',key['AccessKeyId'])
 raise
print('Scoped credentials installed in Learnfold mail Worker secrets.')

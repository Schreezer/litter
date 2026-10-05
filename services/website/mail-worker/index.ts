import { flushMail, type MailEnv } from '../lib/mail';
export default {
 async scheduled(_controller: ScheduledController, env: MailEnv): Promise<void> { await flushMail(env); }
};

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(`${__dirname}/../Kcd.qml`, 'utf8');
const context = vm.createContext({ actionProc: { running: false }, helperBin: '/helper', runCap: 65536 });
context.root = context;
for (const name of ['runAction', 'smsSend', 'replyTo']) {
  const start = source.indexOf(`  function ${name}(`);
  const end = source.indexOf('\n  function ', start + 1);
  vm.runInContext(source.slice(start, end), context);
}
for (const invoke of [() => context.smsSend('device', '+private-number', 'private-message'),
                      () => context.replyTo('device', 'reply-token', 'private-message')]) {
  context.actionProc.running = false;
  invoke();
  assert.equal(JSON.stringify(context.actionProc.command), '["/helper","private"]');
  assert.equal(JSON.parse(context._actionInput).payload.message, 'private-message');
}
context.actionProc.running = true;
context.smsSend('other', 'changed', 'changed');
assert.equal(JSON.parse(context._actionInput).payload.message, 'private-message', 'busy action cannot overwrite pending input');
context.replyTo('other', 'changed-reply', 'changed');
assert.equal(context._pendingReplyId, 'reply-token', 'busy reply cannot change the active reply identity');
console.log('PASS: production SMS/reply commands contain no private payload');

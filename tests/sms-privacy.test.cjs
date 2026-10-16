const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(`${__dirname}/../Kcd.qml`, 'utf8');
const start = source.indexOf('  function handleWatchLine(');
const end = source.indexOf('\n  function removeReplyable(', start);
assert(start >= 0 && end > start);
const notifications = [];
const context = vm.createContext({
  smsList: [], smsLimit: 2,
  notify: (...args) => notifications.push(args),
});
vm.runInContext(fs.readFileSync(`${__dirname}/../Model.js`, 'utf8'), context);
context.Model = context;
vm.runInContext(source.slice(start, end), context);
for (const type of ['sms.incoming', 'sms.incoming', 'sms.incoming', 'sms.attachment']) {
  context.handleWatchLine(JSON.stringify({type, deviceId: 'phone', payload: {
    sender: 'private-number', body: 'private-message', filename: 'private-file',
  }}));
}
assert.equal(context.smsList.length, 2, 'SMS history remains available and bounded');
assert.equal(context.smsList[0].body, 'private-message');
assert.deepEqual(notifications, [], 'SMS events must not bypass backend notification policy');
console.log('SMS notification privacy checks passed');

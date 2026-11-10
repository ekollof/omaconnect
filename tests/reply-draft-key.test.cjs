const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const model = vm.createContext({});
vm.runInContext(fs.readFileSync(`${__dirname}/../Model.js`, 'utf8'), model);

assert.equal(model.replyDraftKey('device-a', 'reply-1'), model.replyDraftKey('device-a', 'reply-1'));
assert.notEqual(model.replyDraftKey('device-a', 'reply-1'), model.replyDraftKey('device-b', 'reply-1'));
assert.notEqual(model.replyDraftKey('device-a', 'reply-1'), model.replyDraftKey('device-a', 'reply-2'));
assert.equal(model.replyDraftKey(null, null), '["",""]');
assert.notEqual(model.replyDraftKey('a', 'b"c'), model.replyDraftKey('a"', 'bc'));
console.log('Reply draft isolation checks passed');

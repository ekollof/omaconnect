const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const model = vm.createContext({});
vm.runInContext(fs.readFileSync(`${__dirname}/../Model.js`, 'utf8'), model);

for (const state of ['PAIR_REQUESTED_BY_PEER', 'PairRequestedByPeer']) {
  const device = { state, connected: true };
  assert.equal(model.pairRequestedByPeer(device), true);
  assert.equal(model.stateLabel(device), 'Wants to pair');
  assert.equal(model.isPaired(device), false);
}
for (const state of ['PAIR_REQUESTED', 'PairRequested']) {
  assert.equal(model.stateLabel({ state, connected: true }), 'Pair requested…');
  assert.equal(model.pairRequestedByPeer({ state }), false);
}
assert.equal(model.isPaired({ state: 'PAIRED' }), true);
assert.equal(model.isPaired({ state: 'UNPAIRED' }), false);
assert.equal(model.pairRequestedByPeer(null), false);
assert.equal(model.stateLabel({ state: 'PAIR_REQUESTED_BY_PEER', connected: false }), 'Offline');
console.log('Pairing state checks passed');

const paired = { state: 'PAIRED', connected: true };
assert.equal(model.canPollMpris([]), false);
assert.equal(model.canPollMpris([paired]), true);
for (const state of ['UNPAIRED', 'PAIR_REQUESTED', 'PAIR_REQUESTED_BY_PEER']) {
  assert.equal(model.canPollMpris([{ state, connected: true }]), false);
  assert.equal(model.canPollMpris([paired, { state, connected: true }]), false);
  assert.equal(model.canPollMpris([paired, { state, connected: false }]), true);
}
console.log('Media polling pairing guards passed');

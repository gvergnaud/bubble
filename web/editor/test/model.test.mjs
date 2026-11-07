// node --test web/editor/test/model.test.mjs
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { applyRate, normalize, rateAt, sourceToEdited, editedToSource, playableFrom, describeRange, paragraphs, wordsIn } from '../model.js'

test('delete then restore leaves nothing', () => {
  let s = applyRate([], 2, 5, 0)
  assert.deepEqual(s, [{ start: 2, end: 5, rate: 0 }])
  s = applyRate(s, 2, 5, 1)
  assert.deepEqual(s, [])
})
test('the newest edit wins and splits older ones', () => {
  let s = applyRate([], 0, 10, 1.5)
  s = applyRate(s, 4, 6, 0)
  assert.deepEqual(s, [{ start: 0, end: 4, rate: 1.5 }, { start: 4, end: 6, rate: 0 }, { start: 6, end: 10, rate: 1.5 }])
})
test('speed never un-cuts', () => {
  let s = applyRate([], 4, 6, 0)
  s = applyRate(s, 0, 10, 2)
  assert.deepEqual(s, [{ start: 0, end: 4, rate: 2 }, { start: 4, end: 6, rate: 0 }, { start: 6, end: 10, rate: 2 }])
  s = applyRate(s, 0, 10, 1)
  assert.deepEqual(s, [])
})
test('normalize merges touching same-rate segments and drops sub-frame ones', () => {
  assert.deepEqual(normalize([{ start: 3, end: 4, rate: 0 }, { start: 1, end: 3, rate: 0 }, { start: 5, end: 5.01, rate: 0 }]), [{ start: 1, end: 4, rate: 0 }])
})
test('time mapping', () => {
  const s = [{ start: 2, end: 4, rate: 0 }, { start: 6, end: 10, rate: 2 }]
  assert.equal(rateAt(s, 3), 0)
  assert.equal(rateAt(s, 7), 2)
  assert.equal(sourceToEdited(s, 12), 12 - 2 - 2)
  assert.equal(editedToSource(s, 12, 2), 2)
  assert.equal(editedToSource(s, 12, 3), 5)
  assert.equal(editedToSource(s, 12, 5), 8)
  assert.equal(playableFrom(s, 2.5), 4)
})
test('describeRange', () => {
  const s = [{ start: 2, end: 4, rate: 0 }]
  assert.equal(describeRange(s, 2, 4).allRemoved, true)
  assert.equal(describeRange(s, 1, 5).hasEdits, true)
  assert.equal(describeRange([], 1, 5).rate, 1)
})
test('paragraphs and wordsIn', () => {
  const w = [{ start: 0, end: 1, speaker: 'a' }, { start: 1.1, end: 2, speaker: 'a' }, { start: 4, end: 5, speaker: 'a' }, { start: 5.1, end: 6, speaker: 'b' }]
  assert.equal(paragraphs(w).length, 3)
  assert.deepEqual(wordsIn(w, 0.9, 4.6), { from: 1, to: 2 })
})

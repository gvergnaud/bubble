// Owner: QA. The page's edit model (web/editor/model.js) against the golden cases of
// web/fixtures/edits-cases.json. The Swift twin (EditPlan) runs the same file in Tests/BubbleEditorTests;
// the "validate" cases run against both servers in web/test/contract.mjs (PUT /edits → 200 or 422).
// Run: node --test web/test/
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { applyRate, editedDuration, sourceToEdited, normalize } from '../editor/model.js'

const cases = JSON.parse(readFileSync(new URL('../fixtures/edits-cases.json', import.meta.url), 'utf8'))
const EPS = 1e-6
const near = (a, b) => Math.abs(a - b) <= EPS
const sameSegments = (got, want) =>
  got.length === want.length && got.every((s, i) => near(s.start, want[i].start) && near(s.end, want[i].end) && s.rate === want[i].rate)
const show = (s) => JSON.stringify(s.map((x) => [+x.start.toFixed(6), +x.end.toFixed(6), x.rate]))

for (const c of cases.apply) {
  test(`apply: ${c.name}`, () => {
    let s = normalize(c.from)
    for (const op of c.ops) s = applyRate(s, op.start, op.end, op.rate)
    assert.ok(sameSegments(s, c.expect), `got ${show(s)}, want ${show(c.expect)}`)
  })
}

for (const c of cases.pieces) {
  test(`output duration: ${c.name}`, () => {
    const d = editedDuration(c.segments, cases.duration)
    assert.ok(near(d, c.outputDuration), `got ${d}, want ${c.outputDuration}`)
    // Σ kept / rate over the listed pieces must say the same (checks the case file itself).
    const fromPieces = c.pieces.reduce((t, p) => t + (p.end - p.start) / p.rate, 0)
    assert.ok(near(fromPieces, c.outputDuration), `case file: pieces sum to ${fromPieces}`)
  })
}

for (const p of cases.timeMap.points) {
  test(`time map: source ${p.source} s → edited ${p.edited} s`, () => {
    const e = sourceToEdited(cases.timeMap.segments, p.source)
    assert.ok(near(e, p.edited), `got ${e}`)
  })
}

test('every "apply" result is itself valid', () => {
  for (const c of cases.apply) {
    let prev = 0
    for (const s of c.expect) {
      assert.ok(s.start >= prev - EPS && s.start < s.end && s.rate !== 1 && s.end - s.start >= 1 / 30 - EPS, `${c.name}: ${JSON.stringify(s)}`)
      prev = s.end
    }
  }
})

import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

// Regression for the field issue: v1 used to force 115200 and disable the
// baud selector, while the board's HC-05 UART is 9600.
const app = await readFile(new URL('../src/app.mjs', import.meta.url), 'utf8');
const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');

test('v1 baud is user-selectable and 9600 is offered for HC-05', () => {
  assert.match(html, /<option>9600<\/option>/);
  assert.match(html, /id="link"/);
  assert.match(html, /HC-05 蓝牙/);
  assert.match(app, /\$\('link'\)\.value==='bluetooth'/);
  assert.match(app, /\$\('baud'\)\.value='9600'/);
  assert.match(app, /serial=serialV1/);
  assert.match(app, /renderSerial\(\);/);
  assert.match(app, /LINK_PREF/);
  assert.doesNotMatch(app, /if\(!v2\)\$\('baud'\)\.value='115200'/);
  assert.doesNotMatch(app, /\$\('baud'\)\.disabled=!v2/);
});

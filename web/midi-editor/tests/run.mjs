// Run in one process so tests also work in environments that restrict child processes.
import './core.test.mjs';
import './serial.test.mjs';
import './ui.test.mjs';
import '../test/protocol-v2.test.mjs';
import './protocol-v2-recovery.test.mjs';
import './serial-v2.test.mjs';

import './performance.test.mjs';

import './reference-wave.test.mjs';
import './sample-synth.test.mjs';

import './keymap.test.mjs';

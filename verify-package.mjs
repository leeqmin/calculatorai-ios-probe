import {readFile, readdir, stat} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';

// Structural preflight only. This does NOT compile Swift or execute iOS code.
const root = path.dirname(fileURLToPath(import.meta.url));
const required = [
  'ProbeApp.swift', 'ProbeCore.swift', 'CoreTests.swift', 'Info.plist',
  'CalculatorProbe.xcodeproj/project.pbxproj',
  'CalculatorProbe.xcodeproj/xcshareddata/xcschemes/CalculatorProbe.xcscheme',
  'build-macos.sh', '.github/workflows/native-probe.yml', '.gitignore', 'README.md',
];
for (const name of required) assert((await stat(path.join(root, name))).isFile(), name);
const project = await readFile(path.join(root, required[4]), 'utf8');
const definitions = [...project.matchAll(/^\s*([A-F0-9]{24}) = \{/gm)].map(x => x[1]);
assert.equal(new Set(definitions).size, definitions.length, 'unique project IDs');
for (const reference of project.matchAll(/\b[A-F0-9]{24}\b/g)) {
  assert(definitions.includes(reference[0]), `undefined project ID: ${reference[0]}`);
}
const app = await readFile(path.join(root, 'ProbeApp.swift'), 'utf8');
assert(app.includes('host: "127.0.0.1"'), 'explicit loopback binding');
assert(!app.includes('0.0.0.0"'), 'no wildcard listener');
assert(!/URL\(string:\s*"https?:\/\/(?!127\.0\.0\.1)/.test(app), 'no external URL');
const workflow = await readFile(path.join(root, '.github/workflows/native-probe.yml'), 'utf8');
assert(workflow.includes('workflow_dispatch:') && !/^\s+(push|pull_request|schedule):/m.test(workflow));
assert(workflow.includes('repository.private == false') && workflow.includes('inputs.public_source_and_storage_reviewed == true'));
const sources = [];
async function collect(dir) {
  for (const entry of await readdir(dir, {withFileTypes: true})) {
    if (['build', 'DerivedData', '.git'].includes(entry.name)) continue;
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) await collect(file);
    else sources.push(file);
  }
}
await collect(root);
for (const file of sources) {
  const content = await readFile(file, 'utf8');
  const secretPattern = new RegExp('s' + 'k-(?:proj-)?[A-Za-z0-9_-]{30,}');
  assert(!secretPattern.test(content), 'credential-shaped content must not be bundled');
  assert(!/\.(p12|mobileprovision|enc|dat|ipa)$/i.test(file), 'no credential/signing/binary files');
}
console.log(`Structural preflight passed: ${sources.length} source/config files, ${definitions.length} project objects.`);
console.log('NOT executed: Swift compilation, 10 core checks, Xcode build, signing, device run, ChatGPT OAuth/inference.');

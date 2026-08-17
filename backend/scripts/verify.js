#!/usr/bin/env node
/**
 * Probes the live YouCam API with your key and prints exactly what it accepts.
 *
 *   npm run verify                       # auth + balance only, spends nothing
 *   npm run verify -- --live <person> <garment>
 *                                        # runs one real try-on, spends units
 *
 * The --live run is what settles the two things the public docs do not publish:
 * which request body shape /task/cloth accepts, and what the finished task
 * response actually looks like. Both raw payloads are printed in full.
 */

import { config } from '../src/config.js';
import * as youcam from '../src/youcam.js';
import { fetchGarmentBytes } from '../src/garment.js';

const args = process.argv.slice(2);
const live = args.includes('--live');
const [personArg, garmentArg] = args.filter((a) => !a.startsWith('--'));

function heading(text) {
  console.log(`\n=== ${text} ===`);
}

function dump(label, value) {
  console.log(`${label}:`);
  console.log(JSON.stringify(value, null, 2));
}

async function main() {
  heading('config');
  console.log(`base url : ${config.baseUrl}`);
  console.log(`api key  : ${config.apiKey ? `${config.apiKey.slice(0, 6)}…(${config.apiKey.length} chars)` : 'MISSING'}`);
  if (!config.apiKey) {
    console.error('\nSet YOUCAM_API_KEY in backend/.env first. See .env.example.');
    process.exit(1);
  }

  heading('auth + balance');
  try {
    const credit = await youcam.getCredit();
    dump('GET /s2s/v1.0/client/credit', credit);
    console.log('\nBearer-key auth works. No token exchange needed.');
  } catch (err) {
    console.error(`Auth check failed: ${err.message}`);
    dump('response body', err.body);
    console.error(
      '\nIf this is 401/403, your console may issue a key + secret pair that needs a token\n' +
        'exchange rather than a raw Bearer key. Check the API-key page and paste the value it\n' +
        'labels as the API key for server-to-server calls.'
    );
    process.exit(1);
  }

  if (!live) {
    console.log('\nRun with --live <person-image-url> <garment-image-url> to settle the task shape.');
    console.log('That call consumes API units.');
    return;
  }

  if (!personArg || !garmentArg) {
    console.error('\n--live needs two image URLs: a person photo and a garment photo.');
    process.exit(1);
  }

  heading('upload person photo');
  const person = await fetchGarmentBytes(personArg);
  const srcFileId = await youcam.uploadImage(person.buffer, person.contentType, 'person.jpg');
  console.log(`src_file_id = ${srcFileId}`);

  heading('create task (negotiating body shape)');
  const task = await youcam.createClothTask({
    srcFileId,
    refFileUrl: garmentArg,
    garmentCategory: 'upper_body',
  });
  console.log(`accepted shape : ${task.shape}`);
  console.log(`task_id        : ${task.taskId}`);
  dump('raw create response', task.raw);

  heading('poll');
  const finished = await youcam.waitForTask(task.taskId, {
    onTick: (snap, n) => console.log(`  poll ${n}: status=${snap.status}`),
  });
  dump('raw finished response', finished.raw);
  console.log('\nURLs found in the response:');
  for (const url of finished.urls) console.log(`  ${url}`);

  heading('what to hard-code now');
  console.log(`- request body shape : "${task.shape}" (drop the other candidates in youcam.js)`);
  console.log('- result URL field   : find the URL above that is the render, then tighten pickRenderUrl');
}

main().catch((err) => {
  console.error(`\nverify failed: ${err.message}`);
  if (err.body) dump('body', err.body);
  process.exit(1);
});

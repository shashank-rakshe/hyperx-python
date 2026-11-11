
import { pathToFileURL } from 'node:url';
let input = '';
process.stdin.on('data', d => input += d);
process.stdin.on('end', async () => {
  try {
    const { file, fn, args } = JSON.parse(input, (k, v) =>
      v && typeof v === 'object' && !Array.isArray(v) && Array.isArray(v.__map__) ? new Map(v.__map__) : v);
    const mod = await import(pathToFileURL(file).href);
    const f = fn.split('.').reduce((o, k) => o[k], mod);
    if (typeof f !== 'function') throw new Error(fn + ' is not a function in ' + file);
    const r = await f(...(Array.isArray(args) ? args : [args]));
    const out = JSON.stringify(r === undefined ? null : r, (k, v) =>
      v instanceof Map ? { __map__: [...v.entries()] } : (ArrayBuffer.isView(v) ? Array.from(v) :
      (v && typeof v === 'object' && v.constructor && v.constructor.name === 'Matrix' && v.toArray ? v.toArray() : v)));
    process.stdout.write('\n@@RESULT@@' + out);
  } catch (e) {
    process.stdout.write('\n@@ERROR@@' + (e && e.stack || String(e)));
  }
});

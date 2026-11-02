// Extracts the es/en/zh/ja dictionaries from the desktop app and writes JSON files for the iOS app.
import fs from 'node:fs';
import vm from 'node:vm';

const src = fs.readFileSync(process.argv[2], 'utf8');
const out = process.argv[3];

function block(startMarker) {
  const i = src.indexOf(startMarker);
  if (i < 0) throw new Error('missing ' + startMarker);
  let j = src.indexOf('{', i + startMarker.length - 1);
  let depth = 0, k = j, inStr = null, esc = false;
  for (; k < src.length; k++) {
    const c = src[k];
    if (inStr) {
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === inStr) inStr = null;
      continue;
    }
    if (c === "'" || c === '"' || c === '`') { inStr = c; continue; }
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) break; }
  }
  return vm.runInNewContext('(' + src.slice(j, k + 1) + ')');
}

const dicts = {
  es: block('const es = {'),
  en: block('const en: Dict = {'),
  zh: block('const zh: Dict = {'),
  ja: block('const ja: Dict = {'),
};

// iOS-specific strings (the desktop app has no equivalent).
const extra = JSON.parse(fs.readFileSync(new URL('./extra_i18n.json', import.meta.url), 'utf8'));
for (const lang of Object.keys(dicts)) {
  Object.assign(dicts[lang], extra.en, extra[lang] ?? {});
}

fs.mkdirSync(out, { recursive: true });
for (const [lang, d] of Object.entries(dicts)) {
  fs.writeFileSync(`${out}/${lang}.json`, JSON.stringify(d, null, 1));
  console.log(lang, Object.keys(d).length);
}

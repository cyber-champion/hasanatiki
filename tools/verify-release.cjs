// Проверяет исходник сайта и при необходимости собирает папку для публикации.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const args=process.argv.slice(2);
const value=name=>{const i=args.indexOf(name);return i<0?null:args[i+1]};
const root=path.resolve(value('--root')||path.join(__dirname,'..'));
const out=value('--stage')?path.resolve(value('--stage')):null;
const partial=args.includes('--metadata-only');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const html=read('index.html');
const sw=read('sw.js');
const quran=JSON.parse(read('q30.json'));
const pack=JSON.parse(read('offline-pack.json'));
const manifest=JSON.parse(read('manifest.webmanifest'));

for(const [,script] of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g))if(script.trim())new vm.Script(script);
new vm.Script(sw);
assert.equal(manifest.start_url,'./');
assert.ok(html.includes('function tjPaint()'));
assert.ok(html.includes('function lessonAccount()'));
assert.ok(html.includes('rpc("lesson_done_once"'));
assert.ok(html.includes('rpc("duel_round_finish"'));
assert.ok(!html.includes('rpc("duel_create"'));
assert.ok(sw.includes('hs-offline-audio-v1'));
assert.ok(sw.includes('Content-Range'));
const counts=JSON.parse(html.match(/^var PLN=(.*);$/m)[1]);
assert.equal(pack.version,1);
const files=new Map(pack.files);
assert.equal(files.size,pack.files.length,'Повтор в офлайн-пакете');
const expected=new Set(['audio/hm/002255.mp3','audio/h/002255.mp3']);
for(const [sura,d] of Object.entries(quran)){
  assert.equal(counts[sura],d.ar.length,sura);
  assert.equal(d.ar.length,d.ru.length,sura);
  assert.equal(d.ar.length,d.tj.length,sura);
  d.ar.forEach((verse,i)=>{
    let prev=0;
    for(const [start,end,rule] of d.tj[i]){
      assert.ok(Number.isInteger(start)&&Number.isInteger(end)&&start>=prev&&end>start&&end<=verse.length,sura+':'+(i+1));
      assert.ok(Number.isInteger(rule)&&rule>=0&&rule<=17);
      prev=end;
    }
    const key=sura.padStart(3,'0')+String(i+1).padStart(3,'0');
    expected.add('audio/hm/'+key+'.mp3');
    expected.add('audio/h/'+key+'.mp3');
  });
}
assert.deepEqual(new Set([...files.keys()].filter(x=>/^audio\/(?:h|hm)\/\d{6}\.mp3$/.test(x))),expected);
const narration=new Set([...files.keys()].filter(x=>/^audio\/voice\/[a-f0-9]{24}\.mp3$/.test(x)));
assert.equal([...files.keys()].filter(x=>x.endsWith('.mp3')).length,expected.size+narration.size);
if(narration.size){
  const globals={window:{}};
  const voiceIndex=read('voice-pack.js');
  assert.equal(files.get('voice-pack.js'),Buffer.byteLength(voiceIndex));
  new vm.Script(voiceIndex).runInNewContext(globals,{timeout:1000});
  const voices=globals.window.HASANATIKI_VOICES;
  assert.ok(Object.keys(voices.sab).length>0&&Object.keys(voices.asl).length>0);
  assert.deepEqual(new Set(Object.values(voices).flatMap(entries=>Object.values(entries)).map(id=>'audio/voice/'+id+'.mp3')),narration);
}
for(const [p,bytes] of files){
  assert.ok(/^[a-z0-9][a-z0-9_.\/-]*$/i.test(p)&&!p.includes('..'),p);
  assert.ok(Number.isSafeInteger(bytes)&&bytes>=0,p);
  if(partial)continue;
  const f=fs.statSync(path.join(root,p));
  assert.ok(f.isFile()&&f.size>0,p);
  if(p.endsWith('.mp3'))assert.equal(f.size,bytes,p);
}
if(out){
  assert.ok(!partial,'Сборка требует все исходные файлы');
  const first=path.relative(root,out).split(path.sep)[0];
  assert.ok(path.relative(root,out)&&!['audio','fonts','em','em3','em3h','.github','.well-known'].includes(first),'Отдельная папка для сборки обязательна');
  const filesToCopy=[...files.keys(),'sw.js','offline-pack.json','.nojekyll','.well-known/assetlinks.json','hasanatiki.apk'];
  for(const p of filesToCopy){
    const src=path.join(root,p);
    if(!fs.existsSync(src)){assert.ok(p==='hasanatiki.apk'||p==='.well-known/assetlinks.json'||p==='.nojekyll',p);continue}
    const dst=path.join(out,p);
    fs.mkdirSync(path.dirname(dst),{recursive:true});
    fs.copyFileSync(src,dst);
  }
}
console.log('Проверка пройдена: '+Object.keys(quran).length+' сур, '+expected.size+' коранических MP3, '+narration.size+' записей уроков, '+files.size+' файлов.');

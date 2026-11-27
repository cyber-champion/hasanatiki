const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const vm = require('node:vm');
const { chromium } = require(process.env.HASANATIKI_PLAYWRIGHT || 'playwright');

const root = path.resolve(process.env.HASANATIKI_VOICE_STAGE || path.join(__dirname, '..'));
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8').replace(/\r\n/g, '\n');
const sounds = { window: {} };
vm.runInNewContext(fs.readFileSync(path.join(root, 'voice-pack.js'), 'utf8'), sounds);
const actual = sounds.window.HASANATIKI_VOICES;
const prompt = 'Найди букву Та';
const praise = 'Отлично! Ты молодец';
if (process.env.HASANATIKI_VOICE_STAGE) {
  for (const id of [actual.sab_alt?.[prompt], actual.asl?.[praise]]) {
    assert.ok(id && fs.existsSync(path.join(root, 'audio/voice/' + id + '.mp3')));
  }
}
const voices = {
  sab_alt: { [prompt]: actual.sab_alt?.[prompt] || '1'.repeat(24) },
  asl: { [praise]: actual.asl?.[praise] || '2'.repeat(24) },
};
const exampleFiles = new Map([
  ['audio/voice/' + voices.sab_alt[prompt] + '.mp3', 'audio/voice-demo/alexandr.mp3'],
  ['audio/voice/' + voices.asl[praise] + '.mp3', 'audio/voice-demo/ekaterina.mp3'],
]);
const hook = `
window.testHome=function(){
  R={view:"group",slug:"qa",tab:"o",practice:false};
  G={slug:"qa",name:"Тест",version:1};
  S=migrate({students:[{id:"test",name:"Ученик"}],lsn:{on:{an:true,h4:true,du:true}}});
  STOK={sid:"test",t:"test"};
  dayIdx=function(n){
    if(n===ASMA.length)return ASMA.findIndex(function(x){return /Бади/.test(x[0])});
    if(n===15)return GC.du.les.flatMap(function(x){return x.c}).filter(function(c){return c[3]}).findIndex(function(c){return c[1]==="Входя в мечеть"});
    return 0;
  };
  render();
};
window.testAlphabet=function(){
  PRAISE=["Отлично! Ты молодец"];
  LS={ab:0,step:"game",k:0,ok:0,err:0,fb:null,tasks:[
    {t:"fnd",say:"Та",opts:["ا","ب","ت"],good:2},{t:"fnd",say:"Ба",opts:["ا","ب","ت"],good:1}
  ]};
  render();
};
`;
const end = html.lastIndexOf('\n})();\n</script>');
assert.ok(end > 0);

const server = http.createServer((req, res) => {
  const file = new URL(req.url, 'http://localhost').pathname.slice(1) || 'index.html';
  if (file === 'index.html' || file === 'config.js' || file === 'voice-pack.js') {
    res.setHeader('Content-Type', file === 'index.html' ? 'text/html; charset=utf-8' : 'text/javascript; charset=utf-8');
    return res.end(file === 'index.html' ? html.slice(0, end) + hook + html.slice(end)
      : file === 'config.js' ? 'window.APP_CONFIG={};' : 'window.HASANATIKI_VOICES=' + JSON.stringify(voices));
  }
  let full = path.resolve(root, file);
  if (!full.startsWith(root + path.sep)) return res.writeHead(404).end();
  if (!fs.existsSync(full) && exampleFiles.has(file)) full = path.join(root, exampleFiles.get(file));
  if (!fs.existsSync(full) || !fs.statSync(full).isFile()) return res.writeHead(404).end();
  res.setHeader('Content-Type', {'.js':'text/javascript','.json':'application/json','.mp3':'audio/mpeg'}[path.extname(full)] || 'application/octet-stream');
  fs.createReadStream(full).pipe(res);
});

async function main() {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({ headless:true, executablePath:process.env.HASANATIKI_CHROME });
    const ctx = await browser.newContext({ viewport:{width:390,height:844}, isMobile:true, hasTouch:true });
    await ctx.addInitScript(() => {
      sessionStorage.setItem('splash','1');
      window.nativeReads = [];
      speechSynthesis.speak = utterance => {
        nativeReads.push(utterance.text);
        setTimeout(() => utterance.onend?.(), 0);
      };
      const AudioPlayer = window.Audio;
      window.audioSeen = [];
      window.Audio = function(src) {
        const player = new AudioPlayer(src);
        player.addEventListener('playing', () => audioSeen.push(player.src));
        return player;
      };
    });
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    page.setDefaultTimeout(15000);
    const url = 'http://127.0.0.1:' + server.address().port + '/';
    await page.goto(url + '#/offline/voices');
    await page.waitForFunction(() => !!navigator.serviceWorker.controller);
    assert.equal(await page.locator('[data-a=voice-demo]').count(), 4);
    for (const voice of ['sab_alt','asl']) {
      assert.equal(await page.locator('[data-a=voice-choice][data-v=' + voice + ']').getAttribute('aria-pressed'), 'true');
    }
    await page.locator('[data-a=voice-demo][data-v=sab_alt]').click();
    await page.waitForFunction(() => audioSeen.some(src => src.endsWith('/alexandr.mp3')));
    await page.locator('[data-a=voice-choice][data-v=sab]').click();
    await page.reload();
    assert.equal(await page.locator('[data-a=voice-choice][data-v=sab]').getAttribute('aria-pressed'), 'true');
    await page.locator('[data-a=voice-choice][data-v=sab_alt]').click();

    await page.goto(url + '#/practice');
    await page.locator('.tgrid button[data-v=ab]').waitFor();
    await page.evaluate(async paths => {
      const cache=await caches.open('hs-offline-audio-v1');
      await cache.addAll(paths);
    }, [...exampleFiles.keys(),'audio/arabic/asma/badi.mp3','audio/arabic/dua/20.mp3']);
    await ctx.setOffline(true);
    await page.reload();
    await page.evaluate(() => testAlphabet());
    await page.locator('[data-a=vtog]').click();
    await page.locator('[data-a=ttsall]').click();
    await page.waitForFunction(id => audioSeen.some(src => src.endsWith(id + '.mp3')), voices.sab_alt[prompt]);
    await page.locator('[data-a=lans][data-v="2"]').click();
    await page.waitForFunction(id => audioSeen.some(src => src.endsWith(id + '.mp3')), voices.asl[praise]);
    const next = page.locator('[data-a=lnext]');
    await next.waitFor();
    await page.waitForTimeout(2400);
    assert.equal(await next.count(), 1);
    assert.match(await page.locator('.abbox').innerText(), /Найди букву «Та»/);
    await next.click();
    assert.match(await page.locator('.abbox').innerText(), /Найди букву «Ба»/);
    assert.ok(!(await page.evaluate(() => nativeReads)).some(line => /Найди букву/.test(line)));

    await page.evaluate(() => testHome());
    await page.getByRole('button', {name:/Прочитать главную/}).waitFor();
    assert.equal(await page.locator('.kid-home a[href="#/offline"]').count(), 1);
    assert.equal(await page.locator('.dly').count(), 3);
    await page.locator('.dly [data-v="audio/arabic/asma/badi.mp3"]').click();
    await page.waitForFunction(() => audioSeen.some(src => src.endsWith('/asma/badi.mp3')));
    await page.locator('.dly [data-v="audio/arabic/dua/20.mp3"]').click();
    await page.waitForFunction(() => audioSeen.some(src => src.endsWith('/dua/20.mp3')));
    assert.match(await page.locator('.dly details').innerText(), /Текст полной записи/);
    assert.deepEqual(errors, []);
    console.log('Проверены выбор голосов, Алифба с кнопкой «Дальше» и записи на главной без сети.');
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => { server.close(resolve);server.closeAllConnections(); });
  }
}
main().catch(error => { console.error(error);process.exitCode=1; });

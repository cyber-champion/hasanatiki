const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.HASANATIKI_PLAYWRIGHT || 'playwright');

const stage = path.resolve(__dirname,'..');
const document = fs.readFileSync(path.join(stage,'index.html'),'utf8').replace(/\r\n/g,'\n');
const init = document.indexOf('/* ================= старт ================= */');
assert.ok(init>0,'Не найдена точка запуска приложения');

const inventory = `window.collectVoices=function(){
  var lines=new Map();
  function add(actor,text){
    if(typeof text!=="string")return;
    text=ttsClean(text);
    if(!/[а-яё0-9]/i.test(text))return;
    lines.set(actor+"|"+text,{actor:actor,text:text,marked:""});
  }
  function texts(actor,values){if(Array.isArray(values))values.forEach(function(t){add(actor,t)})}
  Object.values(GC).forEach(function(course){
    course.les.forEach(function(l){
      add("sab",l.tip);
      (l.c||[]).forEach(function(c){texts("sab",c.slice(1,3))});
      (l.q||[]).forEach(function(q){
        add("sab",q[0]);texts("sab",q[1]);add("sab",q[3]);
        if(q[4])add("sab",q[4].p);
      });
      (l.ord||[]).forEach(function(row){if(Array.isArray(row))texts("sab",row)});
    });
  });
  ABALL.forEach(function(c){
    var name=abName(c);
    texts("sab",[name,"Найди букву «"+name+"»","Сначала найди букву «"+name+"», потом посмотри на огласовку."]);
    HAR.forEach(function(mark,h){texts("sab",[mark[2],abSyl(c,h),"Найди слог «"+abSyl(c,h)+"»"])});
  });
  ASMA.forEach(function(name){texts("sab",[name[0],name[2]])});
  GC.du.les.forEach(function(lesson){lesson.c.forEach(function(c){if(c[3])add("sab",duaMeaning(c[2]))})});
  TILES.forEach(function(tile){texts("sab",tile.slice(1,3))});
  FEAT.forEach(function(tool){add("sab",tool[2])});
  ABLES.forEach(function(l){texts("sab",[l.tip,"Вспомни: "+l.tip])});
  texts("sab",ABFX);texts("sab",TJS);texts("sab",Object.values(LSQ));
  texts("sab",["Варианты ответа.","1.","2.","3.","4.","5.","6.",
    "Какое правило у выделенной буквы?","Очень хорошо.","Как называется эта буква?",
    "Собери слово","Подбери нужную букву","Имя Аллаха на сегодня","Хадис дня","Дуа дня",
    "Какая это буква?","Как читается слог?","Какая здесь огласовка?","Собери слово из Корана",
    "Нажимай буквы по порядку — справа налево, как читаем по-арабски.",
    "Так она пишется в начале слова","Так она пишется в середине слова","Так она пишется в конце слова",
    "Ничего страшного! Правильный ответ отмечен зелёным — запомни его.",
    "Посмотри на точки: сколько их и где — сверху или снизу?",
    "В слове буква меняет вид, но точки остаются на месте. Посмотри на точки!",
    "Посмотри, где чёрточка: сверху — «а», снизу — «и», маленькая «вав» сверху — «у».",
    "Фатха — сверху, кясра — снизу, дамма похожа на маленькую «вав».",
    "Задания","ждут тебя","все сданы","скоро","закрыто","Вперёд!",
    "Всё сделано — ма ша Аллах! Повтори суры или поиграй ещё.",
    "Повторить трудные задания","Пора повторить","Начни с уроков, где в прошлый раз были ошибки.",
    "Прошла неделя — повтори, чтобы закрепить знания.",
    "Хорошо! Я буду читать задания вслух. Нажми на ответ — я его прочитаю. Нажми ещё раз — чтобы ответить."]);
  texts("asl",PRAISE);PRAISE.forEach(function(m){add("asl","Все пары найдены! "+m)});
  texts("asl",["Верно, со второй попытки! Молодец 👍","Ма ша Аллах! Ты собрал слово из Корана!"]);
  return Array.from(lines.values());
};
window.cleanVoiceLine=ttsClean;
window.arabicVoiceLines=function(){
  return {
    names:ASMA.map(function(a){return {title:a[0],arabic:a[1]}}),
    duas:GC.du.les.flatMap(function(l){return l.c.filter(function(c){return c[3]}).map(function(c){return {title:c[1],arabic:c[3]}})})
  };
};
return;`;

async function run(){
  const browser=await chromium.launch({headless:true,executablePath:process.env.HASANATIKI_CHROME});
  try {
    const page=await browser.newPage({serviceWorkers:'block'});
    await page.route('http://127.0.0.1/**',route=>{
      const url=new URL(route.request().url());
      if(url.pathname==='/index.html')return route.fulfill({
        contentType:'text/html; charset=utf-8',body:document.slice(0,init)+inventory+document.slice(init)
      });
      if(url.pathname.endsWith('.js'))return route.fulfill({contentType:'text/javascript',body:''});
      return route.fulfill({status:404});
    });
    await page.goto('http://127.0.0.1/index.html',{waitUntil:'domcontentloaded'});
    const collected=await page.evaluate(()=>window.collectVoices());
    assert.ok(collected.length>100,'Не удалось собрать тексты уроков');
    // Include literal prompts that are addressed to a character in the lesson.
    const prompts=await page.evaluate(doc=>{
      const matches=[...doc.matchAll(/\bsayS\("(sab|asl)",\s*("(?:[^"\\]|\\.)*")\)/g)];
      return matches.map(m=>({actor:m[1],text:window.cleanVoiceLine(JSON.parse(m[2])),marked:''})).filter(row=>row.text);
    },document);
    const file=path.join(stage,'voice-lines.json');
    const old=fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):[];
    const map=new Map();
    for(const row of [...collected,...prompts])map.set(row.actor+'|'+row.text,row);
    for(const row of old){
      const key=row.actor+'|'+row.text;
      if(row.marked||!map.has(key))map.set(key,row);
    }
    await fs.promises.writeFile(file,JSON.stringify([...map.values()],null,2)+'\n');
    const arabic=await page.evaluate(()=>window.arabicVoiceLines());
    await fs.promises.writeFile(path.join(stage,'arabic-lines.json'),JSON.stringify(arabic,null,2)+'\n');
    console.log('Собрано строк для разметки: '+map.size);
  } finally {await browser.close()}
}
run().catch(e=>{console.error(e.message);process.exitCode=1});

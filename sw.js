// Хасанатики — материалы для офлайна и пуш-уведомления.
var CACHE = "hs-v1";
var OFF_FILES = "hs-offline-files-v1";
var OFF_AUDIO = "hs-offline-audio-v1";
var CORE=["index.html","config.js","voice-pack.js","q30.json","manifest.webmanifest","offline-pack.json",
  "fonts/nunito.woff","fonts/hafs.woff","fonts/sch.woff","fonts/sch-b.woff","fonts/ruqaa.woff",
  "icon-192.png","icon-512.png","apple-touch-icon.png"];
var LETTERS=Array.from("ابتثجحخدذرزسشصضطظعغفقكلمنهوي",function(c){
  return "audio/ab/recorded/"+c.charCodeAt(0).toString(16).padStart(4,"0")+".wav";
});
self.addEventListener("install", function(e){
  e.waitUntil((async function(){
    try{
      var cache=await caches.open(CACHE);
      var audio=await caches.open(OFF_AUDIO);
      await Promise.allSettled(CORE.concat(LETTERS).map(async function(path){
        var url=new URL(path,self.registration.scope).href;
        var ctrl=new AbortController(),timer=setTimeout(function(){ctrl.abort()},4500);
        try{
          var response=await fetch(url,{cache:"reload",signal:ctrl.signal});
          if(response.ok)await (LETTERS.indexOf(path)>=0?audio:cache).put(url,response);
        }finally{clearTimeout(timer)}
      }));
    }finally{await self.skipWaiting()}
  })());
});
self.addEventListener("activate", function (e) { e.waitUntil(self.clients.claim()); });

async function audioResponse(request) {
  var full;
  try { full = await (await caches.open(OFF_AUDIO)).match(request.url); }
  catch (e) { return fetch(request); }
  if (!full) return fetch(request);
  var range = request.headers.get("Range");
  if (!range) return full;
  var blob = await full.blob();
  var m = /^bytes=(\d*)-(\d*)$/i.exec(range.trim());
  var start = m && m[1] ? Number(m[1]) : 0;
  var end = m && m[2] ? Number(m[2]) : blob.size - 1;
  if (m && !m[1] && m[2]) {
    start = Math.max(0, blob.size - end);
    end = blob.size - 1;
  }
  if (!m || (!m[1] && !m[2]) || !Number.isSafeInteger(start) ||
      !Number.isSafeInteger(end) || start >= blob.size || end < start) {
    return new Response(null, {status:416, headers:{"Content-Range":"bytes */" + blob.size}});
  }
  end = Math.min(end, blob.size - 1);
  return new Response(blob.slice(start, end + 1), {status:206, headers:{
    "Content-Type":full.headers.get("Content-Type") || (/\.wav$/i.test(new URL(request.url).pathname)?"audio/wav":"audio/mpeg"),
    "Accept-Ranges":"bytes", "Content-Length":String(end-start+1),
    "Content-Range":"bytes " + start + "-" + end + "/" + blob.size
  }});
}

self.addEventListener("fetch", function (e) {
  var r = e.request, url = new URL(r.url), scope = self.registration.scope;
  if (r.method !== "GET" || url.origin !== self.location.origin || !url.href.startsWith(scope)) return;
  var path = url.pathname.slice(new URL(scope).pathname.length);
  if (/^audio\/(?:(?:h|hm)\/\d{6}|voice\/[a-f0-9]{24})\.mp3$/.test(path) || LETTERS.indexOf(path)>=0) {
    e.respondWith(audioResponse(r));
    return;
  }
  if (/\.(?:apk|mp3)$/i.test(path)) return;
  // Read only public site resources on this origin. Supabase requests bypass the worker.
  var fresh = r.mode === "navigate" || /\/$|\.html$|\.json$|sw\.js$|config\.js$/.test(url.pathname);
  var controller=new AbortController();
  var timer=setTimeout(function(){controller.abort()},r.mode==="navigate"?5500:9000);
  var network=fetch(r,{cache:fresh?"no-cache":r.cache,signal:controller.signal})
    .finally(function(){clearTimeout(timer)});
  var cached=(async function(){
    try{
      var appCache=await caches.open(CACHE),pack=await caches.open(OFF_FILES);
      var options={ignoreSearch:true};
      var hit=r.mode==="navigate"&&(path===""||path==="index.html")?await appCache.match(scope+"index.html"):null;
      hit=hit||await appCache.match(r,options)||await pack.match(r,options);
      if(!hit&&r.mode==="navigate"){
        hit=await appCache.match(scope+"index.html")||await appCache.match(scope)||
            await pack.match(scope+"index.html");
      }
      return hit;
    }catch(e){return null}
  })();
  var save=network.then(async function(res){
    if(res.status!==200)return;
    var copy=res.clone();
    var target=r.mode==="navigate"&&(path===""||path==="index.html")?scope+"index.html":r;
    var cache=await caches.open(CACHE);
    await cache.put(target,copy);
  }).catch(function(){});
  e.waitUntil(save);
  e.respondWith((async function(){
    var hit=await cached;
    var online=network.then(function(res){return res.status>=500?null:res},function(){return null});
    if(hit&&(r.mode==="navigate"||CORE.indexOf(path)>=0)){
      var first=await Promise.race([online,new Promise(function(resolve){setTimeout(function(){resolve(null)},1200)})]);
      return first||hit;
    }
    return await online||hit||Response.error();
  })());
});
self.addEventListener("push", function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "Хасанатики", {
    body: d.body || "", icon: "notify-icon.png", badge: "badge.png", tag: d.tag, renotify: !!d.tag,
    vibrate: [200, 100, 200], silent: false, data: { url: d.url || "./" }
  }));
});
self.addEventListener("notificationclick", function (e) {
  e.notification.close();
  var url = new URL((e.notification.data && e.notification.data.url) || "./", self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (ws) {
    for (var i = 0; i < ws.length; i++) {
      if (ws[i].url.split("#")[0] === url.split("#")[0] && "focus" in ws[i]) {
        ws[i].postMessage({ go: url.split("#")[1] || "" });
        return ws[i].focus();
      }
    }
    return self.clients.openWindow(url);
  }));
});

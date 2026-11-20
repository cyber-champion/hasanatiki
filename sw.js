// Хасанатики — фоновый помощник: показывает пуш-уведомления
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (e) { e.waitUntil(self.clients.claim()); });
// без интернета: страница приложения берётся из кэша (сначала всегда пробуем сеть)
var CACHE = "hs-v1"; // v2: свежая страница без кэша браузера
self.addEventListener("fetch", function (e) {
  var r = e.request, u;
  try { u = new URL(r.url); } catch (x) { return; }
  if (r.method !== "GET" || u.origin !== self.location.origin) return;
  if (/\/audio\/|\.apk$|\.mp3$/.test(u.pathname)) return;
  // страницу и главные файлы всегда берём свежими с сервера (мимо кэша браузера), чтобы обновления приходили сразу
  var fresh = r.mode === "navigate" || /\/$|\.html$|\.json$|sw\.js$|config\.js$/.test(u.pathname);
  e.respondWith((fresh ? fetch(r.url, { cache: "no-cache", credentials: "same-origin" }) : fetch(r)).then(function (res) {
    if (res && res.ok) { var c = res.clone(); caches.open(CACHE).then(function (k) { k.put(r, c); }); }
    return res;
  }).catch(function () {
    return caches.match(r, { ignoreSearch: true }).then(function (m) {
      return m || (r.mode === "navigate" ? caches.match("./", { ignoreSearch: true }) : Response.error());
    });
  }));
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

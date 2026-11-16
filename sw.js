// Хасанатики — фоновый помощник: показывает пуш-уведомления
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (e) { e.waitUntil(self.clients.claim()); });
self.addEventListener("fetch", function () {});
self.addEventListener("push", function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "Хасанатики", {
    body: d.body || "", icon: "icon-192.png", badge: "badge.png", tag: d.tag, data: { url: d.url || "./" }
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

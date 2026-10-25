// Telegram 跳转 - Surge 版
// 由 IBL3ND 的 Egern 版 TgRedirect.js 改写而来，原版用 Egern 的 ctx.env / ctx.respond，
// 在 Surge 上跑不了，所以按 Surge 的 $request / $argument / $done 重写，跳转逻辑原样保留。
// 客户端选择来自模块参数 CLIENT，默认 Telegram（官方客户端时直接放行，不重定向）。

var SCHEME = {
  Telegram: "tg",
  Nagram: "tg",
  Swiftgram: "sg",
  Turrit: "turrit",
  iMe: "ime",
  Nicegram: "ng",
  Lingogram: "lingo",
  Regram: "regram"
};

function qval(qs, key) {
  if (!qs) return "";
  var re = new RegExp(
    "(?:^|&)" + key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "=([^&]*)"
  );
  var m = qs.match(re);
  return m ? decodeURIComponent(m[1]) : "";
}

function deeplink(s, path, qs) {
  var p = path.split("/").filter(Boolean);
  if (!p[0]) return "";

  if (p[0][0] === "+") {
    return s + "://join?invite=" + encodeURIComponent(p[0].slice(1));
  }
  if (p[0] === "joinchat" && p[1]) {
    return s + "://join?invite=" + encodeURIComponent(p[1]);
  }
  if (p[0] === "addstickers" && p[1]) {
    return s + "://addstickers?set=" + encodeURIComponent(p[1]);
  }
  if (p[0] === "share" && p[1] === "url") {
    return s + "://msg_url?url=" + encodeURIComponent(qval(qs, "url")) + "&text=" + encodeURIComponent(qval(qs, "text"));
  }
  if (p[1] && /^\d+$/.test(p[1])) {
    return s + "://resolve?domain=" + encodeURIComponent(p[0]) + "&post=" + encodeURIComponent(p[1]);
  }
  return s + "://resolve?domain=" + encodeURIComponent(p[0]);
}

function getClient() {
  try {
    if (typeof $argument === "object" && $argument !== null) {
      if ($argument.CLIENT) return String($argument.CLIENT).trim();
    }
    if (typeof $argument === "string" && $argument) {
      var m = $argument.match(/CLIENT\s*=\s*"([^"]+)"/);
      if (m) return m[1].trim();
      var t = $argument.trim().replace(/^"+|"+$/g, "");
      if (t && t.indexOf("=") === -1 && t.indexOf("&") === -1) return t;
    }
  } catch (e) {}
  return "Telegram";
}

(function () {
  var url = $request.url || "";
  var m = url.match(/^https?:\/\/(?:t\.me|telegram\.me)\/(.+)$/i);
  if (!m) {
    $done({});
    return;
  }

  var client = getClient();

  // 选官方 Telegram 直接放行，不重定向（和原版一致）
  if (client === "Telegram") {
    $done({});
    return;
  }

  var scheme = SCHEME[client] || "tg";

  var tail = m[1];
  if (tail.indexOf("s/") === 0) tail = tail.slice(2);

  var qi = tail.indexOf("?");
  var path = qi < 0 ? tail : tail.slice(0, qi);
  var qs = qi < 0 ? "" : tail.slice(qi + 1);

  var loc = deeplink(scheme, path, qs);
  if (!loc) {
    $done({});
    return;
  }

  $done({
    response: {
      status: 302,
      headers: {
        Location: loc,
        "Cache-Control": "no-store, no-cache"
      },
      body: ""
    }
  });
})();

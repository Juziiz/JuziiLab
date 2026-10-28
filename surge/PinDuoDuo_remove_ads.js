// PinDuoDuo_remove_ads.js - Surge http-response script for non-homepage URLs only.
// Homepage/hub is handled by the author's kelee script (see module [Script] first entry).
// Same logic as the jq filters for: search, philo/personal/hub, oak, order_detail_group, /order/, order_list_v4
(function () {
  var url = $request.url || "";
  var body = $response.body || "";
  var obj;
  try { obj = JSON.parse(body); } catch (e) { $done({}); return; }
  function delPath(o, path) {
    var cur = o;
    for (var i = 0; i < path.length - 1; i++) { if (cur == null) return; cur = cur[path[i]]; }
    if (cur != null) delete cur[path[path.length - 1]];
  }
  if (/\/search\?/.test(url)) { delete obj.expansion; }
  else if (/\/api\/philo\/personal\/hub\?/.test(url)) {
    delPath(obj, ["monthly_card_entrance"]); delPath(obj, ["personal_center_style_v2_vo"]);
    delPath(obj, ["icon_set", "icons"]); delPath(obj, ["icon_set", "top_personal_icons"]); delPath(obj, ["personal_banner"]);
  } else if (/\/api\/oak\/integration\/render\?/.test(url)) {
    delPath(obj, ["bottom_section_list"]); delPath(obj, ["ui", "bottom_section"]); delPath(obj, ["ui", "live_section", "float_info"]);
  } else if (/\/api\/caterham\/v3\/query\/order_detail_group\?/.test(url)) { delPath(obj, ["data", "goods_list"]); }
  else if (/\/order\//.test(url)) { delPath(obj, ["marketing_banner_vo"]); delPath(obj, ["shipping", "banner_above_recommend"]); }
  else if (/\/api\/aristotle\/order_list_v4\?/.test(url)) {
    if (Array.isArray(obj.orders)) { obj.orders.forEach(function (o) { if (Array.isArray(o.order_buttons)) { o.order_buttons.forEach(function (b) { delete b.order_growth_tip; }); } }); }
  } else { $done({}); return; }
  $done({ body: JSON.stringify(obj) });
})();

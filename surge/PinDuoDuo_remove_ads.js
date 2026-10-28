// PinDuoDuo_remove_ads.js - Surge http-response script
// Same logic as the 7 jq filters, in JS so it is not limited by Surge Body Rewrite 1MB rule.
// Works on: homepage/hub, search, philo/personal/hub, oak/integration/render,
// order_detail_group, /order/, aristotle/order_list_v4
(function () {
  var url = $request.url || "";
  var body = $response.body || "";
  var obj;
  try { obj = JSON.parse(body); } catch (e) { $done({}); return; }
  function delPath(o, path) {
    var cur = o;
    for (var i = 0; i < path.length - 1; i++) {
      if (cur == null) return;
      cur = cur[path[i]];
    }
    if (cur != null) delete cur[path[path.length - 1]];
  }
  function keepTabs(arr) {
    if (!Array.isArray(arr)) return arr;
    return arr.filter(function (x) {
      return x && (x.link === "index.html" || x.link === "chat_list.html" || x.link === "personal.html");
    });
  }
  if (/\/api\/alexa\/homepage\/hub\?/.test(url)) {
    delPath(obj, ["result", "dy_module", "irregular_banner_dy"]);
    delPath(obj, ["result", "icon_set"]);
    delPath(obj, ["result", "search_bar_hot_query"]);
    if (obj.result) {
      if (obj.result.bottom_tabs) obj.result.bottom_tabs = keepTabs(obj.result.bottom_tabs);
      if (obj.result.buffer_bottom_tabs) obj.result.buffer_bottom_tabs = keepTabs(obj.result.buffer_bottom_tabs);
      if (Array.isArray(obj.result.all_top_opts)) {
        obj.result.all_top_opts.forEach(function (o) {
          delete o.selected_image; delete o.image; delete o.height; delete o.width;
        });
      }
    }
  } else if (/\/search\?/.test(url)) {
    delete obj.expansion;
  } else if (/\/api\/philo\/personal\/hub\?/.test(url)) {
    delPath(obj, ["monthly_card_entrance"]);
    delPath(obj, ["personal_center_style_v2_vo"]);
    delPath(obj, ["icon_set", "icons"]);
    delPath(obj, ["icon_set", "top_personal_icons"]);
    delPath(obj, ["personal_banner"]);
  } else if (/\/api\/oak\/integration\/render\?/.test(url)) {
    delPath(obj, ["bottom_section_list"]);
    delPath(obj, ["ui", "bottom_section"]);
    delPath(obj, ["ui", "live_section", "float_info"]);
  } else if (/\/api\/caterham\/v3\/query\/order_detail_group\?/.test(url)) {
    delPath(obj, ["data", "goods_list"]);
  } else if (/\/order\//.test(url)) {
    delPath(obj, ["marketing_banner_vo"]);
    delPath(obj, ["shipping", "banner_above_recommend"]);
  } else if (/\/api\/aristotle\/order_list_v4\?/.test(url)) {
    if (Array.isArray(obj.orders)) {
      obj.orders.forEach(function (o) {
        if (Array.isArray(o.order_buttons)) {
          o.order_buttons.forEach(function (b) { delete b.order_growth_tip; });
        }
      });
    }
  } else {
    $done({}); return;
  }
  $done({ body: JSON.stringify(obj) });
})();

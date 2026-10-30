// PinDuoDuo remove ads - QX response script
// Converts the Egern/Loon jq rules (the version that works in Egern) to JS,
// including the homepage hub rule that the failing Surge version moved to the
// kelee script. No kelee script is needed for the homepage rule here.
var url = ($request && $request.url) || "";
var body = $response.body;
try {
  var obj = JSON.parse(body);
  if (obj && typeof obj === "object") {
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
      return arr.filter(function (t) {
        return t && (t.link === "index.html" || t.link === "chat_list.html" || t.link === "personal.html");
      });
    }
    if (url.indexOf("/api/alexa/homepage/hub") !== -1) {
      var r = obj.result;
      if (r) {
        delPath(r, ["dy_module", "irregular_banner_dy"]);
        delete r.icon_set;
        delete r.search_bar_hot_query;
        if (Array.isArray(r.bottom_tabs)) r.bottom_tabs = keepTabs(r.bottom_tabs);
        if (Array.isArray(r.buffer_bottom_tabs)) r.buffer_bottom_tabs = keepTabs(r.buffer_bottom_tabs);
        if (Array.isArray(r.all_top_opts)) {
          r.all_top_opts.forEach(function (o) {
            delete o.selected_image; delete o.image; delete o.height; delete o.width;
          });
        }
      }
    } else if (url.indexOf("/search?") !== -1) {
      delete obj.expansion;
    } else if (url.indexOf("/api/philo/personal/hub") !== -1) {
      delete obj.monthly_card_entrance;
      delete obj.personal_center_style_v2_vo;
      delPath(obj, ["icon_set", "icons"]);
      delPath(obj, ["icon_set", "top_personal_icons"]);
      delete obj.personal_banner;
    } else if (url.indexOf("/api/oak/integration/render") !== -1) {
      delete obj.bottom_section_list;
      delPath(obj, ["ui", "bottom_section"]);
      delPath(obj, ["ui", "live_section", "float_info"]);
    } else if (url.indexOf("/api/caterham/v3/query/order_detail_group") !== -1) {
      delPath(obj, ["data", "goods_list"]);
    } else if (url.indexOf("/order/") !== -1) {
      delete obj.marketing_banner_vo;
      delPath(obj, ["shipping", "banner_above_recommend"]);
    } else if (url.indexOf("/api/aristotle/order_list_v4") !== -1) {
      if (Array.isArray(obj.orders)) {
        obj.orders.forEach(function (o) {
          if (Array.isArray(o.order_buttons)) {
            o.order_buttons.forEach(function (b) { delete b.order_growth_tip; });
          }
        });
      }
    }
    body = JSON.stringify(obj);
  }
} catch (e) {}
$done({ body: body });

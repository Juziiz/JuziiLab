// BodianMusic remove ads - QX response script
// Converts the Surge jq rules for BodianMusic (QingRex Beta module) to JS.
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
    function setPath(o, path, val) {
      var cur = o;
      for (var i = 0; i < path.length - 1; i++) {
        if (cur == null) return;
        cur = cur[path[i]];
      }
      if (cur != null) cur[path[path.length - 1]] = val;
    }
    if (url.indexOf("/api/service/conf/all") !== -1) {
      delPath(obj, ["data", "groupSign", "adStartAppDialog"]);
      delPath(obj, ["data", "groupSign", "adGuideTest"]);
      delPath(obj, ["data", "groupSign", "playTips"]);
      delPath(obj, ["data", "groupSign", "adExitChange"]);
      delPath(obj, ["data", "conf", "adGuidePopCount"]);
      delPath(obj, ["data", "conf", "adDownListOpen"]);
      if (obj.data && obj.data.conf && obj.data.conf.flowControlConfig) {
        if ("uploadEnable" in obj.data.conf.flowControlConfig) obj.data.conf.flowControlConfig.uploadEnable = false;
        if ("p2pEnable" in obj.data.conf.flowControlConfig) obj.data.conf.flowControlConfig.p2pEnable = false;
      }
    } else if (url.indexOf("/abtest/ui/info") !== -1) {
      ["CommentADPosition", "DiscoverADPosition", "DownloadAd", "FreeModVoiceReminder", "GamesTrans", "bodianmvdialog", "MvTryShowAds", "insert"].forEach(function (k) {
        delPath(obj, ["data", "mapTestInfo", k]);
      });
    } else if (url.indexOf("/api/service/global/config/scene") !== -1) {
      if (obj.data) {
        delete obj.data.iosP2PCacheEnable;
        delete obj.data.warmStartDialog;
        delete obj.data.adsNotFinishVipPop4DayInterval;
        if ("showShopEntry" in obj.data) obj.data.showShopEntry = false;
        if ("iosP2pEnableSendDataLimit" in obj.data) obj.data.iosP2pEnableSendDataLimit = 1;
      }
    } else if (url.indexOf("/api/search/topic/word/list") !== -1) {
      if (obj.data) {
        delete obj.data.hotTopic; delete obj.data.searchFind;
        delete obj.data.globalJumpInfo; delete obj.data.hotWord;
      }
    } else if (url.indexOf("/api/service/home/index") !== -1) {
      if (obj.data && Array.isArray(obj.data.moduleList)) {
        obj.data.moduleList = obj.data.moduleList.filter(function (m) {
          return String(m.type) !== "8" && String(m.type) !== "1";
        });
      }
    } else if (url.indexOf("/api/service/music/recommendList") !== -1) {
      if (obj.data && Array.isArray(obj.data.musicList)) {
        obj.data.musicList.forEach(function (m) { delete m.showAd; });
      }
    } else if (url.indexOf("/api/comments/v3/topInfo") !== -1) {
      if (obj.data) { delete obj.data.putao; delete obj.data.bannerVos; }
    }
    body = JSON.stringify(obj);
  }
} catch (e) {}
$done({ body: body });

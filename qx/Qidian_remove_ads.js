// Qidian remove ads - QX response script
// Translates the Surge jq rules for getconf / getdailyrecommend / getaccountpage.
var url = ($request && $request.url) || "";
var body = $response.body;
try {
  var obj = JSON.parse(body);
  if (obj && typeof obj === "object") {
    if (url.indexOf("/client/getconf") !== -1) {
      var d = obj.Data;
      if (d) {
        if ("WolfEye" in d) d.WolfEye = 0;
        if (d.CloudSetting && "TeenShowFreq" in d.CloudSetting) d.CloudSetting.TeenShowFreq = 0;
        delete d.ActivityPageBackPushNoticeFrequency;
        delete d.ActivityIcon;
        delete d.ActivityPopup;
        delete d.LuckBag;
      }
    } else if (url.indexOf("/dailyrecommend/getdailyrecommend") !== -1) {
      if (obj.Data && "Items" in obj.Data) obj.Data.Items = [];
    } else if (url.indexOf("/user/getaccountpage") !== -1) {
      if (obj.Data) delete obj.Data.BenefitButtonList;
    }
    body = JSON.stringify(obj);
  }
} catch (e) {}
$done({ body: body });

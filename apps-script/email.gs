/**
 * 享尼義賣：訂單 Email 通知（Google Apps Script）
 * Supabase 有新訂單或訂單狀態改變時，會呼叫這支程式寄信。
 * 信件從「部署這支程式的 Gmail 帳號」寄出，團隊通知也寄到同一個信箱。
 *
 * 設定步驟請看 GitHub README 的「下單 Email 通知」。
 */

// 部署成「網頁應用程式」後，把網址（結尾是 /exec）貼在下面引號中間
const WEB_APP_URL = '';

const SITE = 'https://shinepal.github.io';
const TEAM_NAME = '享尼尼泊爾國際志工團';

/* ---------- 只需執行一次：產生密鑰、寄測試信、產生要貼到 Supabase 的指令 ---------- */
function setup() {
  if (!/^https:\/\/script\.google\.com\/.+\/exec$/.test(WEB_APP_URL)) {
    throw new Error('請先部署成網頁應用程式，並把結尾是 /exec 的網址貼到第 10 行的 WEB_APP_URL。');
  }
  const props = PropertiesService.getScriptProperties();
  let key = props.getProperty('HOOK_KEY');
  if (!key) {
    key = Utilities.getUuid().replace(/-/g, '') + Utilities.getUuid().replace(/-/g, '');
    props.setProperty('HOOK_KEY', key);
  }
  const me = Session.getEffectiveUser().getEmail();
  MailApp.sendEmail({
    to: me,
    subject: '【享尼義賣】Email 通知設定測試',
    htmlBody: wrap_('設定成功！', '<p>收到這封信，代表 Google Apps Script 可以用這個信箱寄信了。</p><p>接下來請把執行紀錄裡的那一行指令，貼到 Supabase 的 SQL Editor 執行。</p>'),
    name: TEAM_NAME
  });
  const sql = "select private.set_mail_hook('" + WEB_APP_URL + "?key=" + key + "');";
  console.log('已寄出測試信到 ' + me + '。請複製下面這一行，貼到 Supabase 的 SQL Editor 執行：');
  console.log(sql);
}

/* ---------- Supabase 會呼叫這裡 ---------- */
function doPost(e) {
  const key = PropertiesService.getScriptProperties().getProperty('HOOK_KEY');
  if (!key || !e || !e.parameter || e.parameter.key !== key) return out_('forbidden');
  let data;
  try { data = JSON.parse(e.postData.contents); } catch (err) { return out_('bad json'); }
  const o = data && data.order;
  if (!o || !o.order_no || !o.email) return out_('bad payload');
  try {
    handle_(data.event, o, data.bank || {});
  } catch (err) {
    console.error(err);
    return out_('error');
  }
  return out_('ok');
}

function handle_(event, o, bank) {
  const team = Session.getEffectiveUser().getEmail();
  const no = o.order_no;
  if (event === 'new') {
    send_(o.email, '【享尼義賣】訂單成立 ' + no + '，請於期限內匯款',
      wrap_('謝謝你支持享尼！', '<p>' + h_(o.buyer_name) + ' 你好，我們已收到你的訂單：</p>' + order_(o) + bank_(o, bank) + steps_(no)), team);
    send_(team, '【新訂單】' + no + '｜' + String(o.buyer_name).slice(0, 40) + '｜' + money_(o.total),
      wrap_('有一筆新訂單', order_(o) + '<h3 style="margin:16px 0 6px;font-size:15px">收件資料</h3>' + buyer_(o) + '<p style="font-size:13px;color:#6B5A4D">直接回覆這封信會寄給買家。</p>' + admin_()), o.email);
  } else if (event === '已回報匯款') {
    send_(team, '【已回報匯款】' + no + '｜末五碼 ' + o.transfer_last5 + '｜' + money_(o.total),
      wrap_('買家已回報匯款', '<p>請核對入帳後，到 Supabase 把這筆訂單的 status 改成「已付款」。</p>' +
        table_([['訂單編號', no], ['應收金額', money_(o.total)], ['帳號末五碼', o.transfer_last5], ['買家', o.buyer_name + '（' + o.phone + '）']]) + admin_()), o.email);
  } else if (event === '已付款') {
    send_(o.email, '【享尼義賣】已收到你的款項 ' + no,
      wrap_('款項確認完成！', '<p>' + h_(o.buyer_name) + ' 你好，我們已確認收到 ' + money_(o.total) + '，會盡快為你出貨。</p>' + order_(o) + track_(no)), team);
  } else if (event === '已出貨') {
    send_(o.email, '【享尼義賣】你的訂單已出貨 ' + no,
      wrap_('包裹出發囉！', '<p>' + h_(o.buyer_name) + ' 你好，你的訂單已經寄出' + (o.tracking_no ? '，物流單號：<b>' + h_(o.tracking_no) + '</b>' : '') + '。</p>' + order_(o) + track_(no) +
        '<p>收到商品後，歡迎到網站的留言板跟我們分享 😊</p>'), team);
  } else if (event === '已取消') {
    send_(o.email, '【享尼義賣】訂單已取消 ' + no,
      wrap_('訂單已取消', '<p>' + h_(o.buyer_name) + ' 你好，你的訂單 ' + h_(no) + ' 已經取消。如果是誤會，或已經匯款，請直接回覆這封信，我們會盡快處理。</p>'), team);
  }
}

/* ---------- 信件內容 ---------- */
function order_(o) {
  const rows = (o.items || []).map(function (l) {
    return '<tr><td style="padding:4px 0">' + h_(l.name) + ' × ' + h_(l.qty) + '</td><td style="padding:4px 0;text-align:right">' + money_(l.price * l.qty) + '</td></tr>';
  }).join('');
  let x = '<table style="width:100%;border-collapse:collapse;font-size:14px">' +
    '<tr><td colspan="2" style="padding:4px 0"><b>訂單編號 ' + h_(o.order_no) + '</b></td></tr>' + rows +
    '<tr><td style="border-top:1px dashed #cbb;padding:6px 0 2px">商品金額</td><td style="border-top:1px dashed #cbb;padding:6px 0 2px;text-align:right">' + money_(o.subtotal) + '</td></tr>' +
    (o.discount ? '<tr><td style="color:#2F7A3A">組合優惠</td><td style="text-align:right;color:#2F7A3A">−' + money_(o.discount) + '</td></tr>' : '') +
    '<tr><td>運費</td><td style="text-align:right">' + (o.shipping ? money_(o.shipping) : '免運') + '</td></tr>' +
    '<tr><td><b>總金額</b></td><td style="text-align:right"><b>' + money_(o.total) + '</b></td></tr></table>';
  if (o.sizes) x += '<p>T恤尺寸：' + h_(o.sizes) + '</p>';
  if (o.reward_perks) x += '<p>🎁 滿額回饋：' + h_(o.reward_perks) + (o.reward_choice ? '（你的選擇：' + h_(o.reward_choice) + '）' : '') + '</p>';
  return x;
}
function bank_(o, b) {
  if (!b.account) return '<p><b>匯款帳號</b>：團隊會在 1–2 天內另外寄信給你。</p>';
  return '<div style="background:#F6EBDD;border-radius:10px;padding:12px 14px;margin:12px 0">' +
    table_([['銀行', (b.name || '') + (b.code ? '（' + b.code + '）' : '')], ['帳號', b.account], ['戶名', b.holder || ''], ['金額', money_(o.total)], ['匯款期限', deadline_(o.pay_by)]]) + '</div>';
}
function steps_(no) {
  return '<ol style="padding-left:1.2em;line-height:1.7"><li>請在期限內匯款到上面的帳戶。</li>' +
    '<li>匯款後到網站「其他 → 訂單查詢」，輸入訂單編號 <b>' + h_(no) + '</b> 和手機，回報帳號末五碼。</li>' +
    '<li>團隊確認收款後就會出貨。</li></ol>' + track_(no);
}
function track_(no) { return '<p><a href="' + SITE + '/#order" style="color:#D63A2F;font-weight:bold">查詢訂單進度 →</a></p>'; }
function buyer_(o) {
  return table_([['收件人', o.buyer_name], ['手機', o.phone], ['Email', o.email], ['地址', (o.zip ? o.zip + ' ' : '') + o.address], ['備註', o.note || '—'], ['匯款期限', deadline_(o.pay_by)]]);
}
function admin_() { return '<p style="color:#6B5A4D;font-size:13px">到 Supabase → Table Editor → orders 管理訂單。</p>'; }
function table_(rows) {
  return '<table style="border-collapse:collapse;font-size:14px">' + rows.map(function (r) {
    return '<tr><td style="padding:3px 14px 3px 0;color:#6B5A4D;white-space:nowrap">' + h_(r[0]) + '</td><td style="padding:3px 0"><b>' + h_(r[1]) + '</b></td></tr>';
  }).join('') + '</table>';
}
function wrap_(title, body) {
  return '<div style="max-width:560px;margin:auto;font-family:-apple-system,\'PingFang TC\',\'Microsoft JhengHei\',sans-serif;color:#2B2420;line-height:1.6">' +
    '<h2 style="margin:0 0 12px;color:#D63A2F">' + title + '</h2>' + body +
    '<hr style="border:0;border-top:1px solid #E4D3BC;margin:18px 0"><p style="font-size:12px;color:#6B5A4D">' + TEAM_NAME + '｜<a href="' + SITE + '" style="color:#6B5A4D">' + SITE.replace('https://', '') + '</a><br>有任何問題，直接回覆這封信就可以聯絡我們。</p></div>';
}

/* ---------- 小工具 ---------- */
function send_(to, subject, html, replyTo) {
  MailApp.sendEmail({ to: to, subject: subject, htmlBody: html, name: TEAM_NAME, replyTo: replyTo });
}
function money_(n) { return 'NT$ ' + Number(n || 0).toLocaleString('en-US'); }
function deadline_(t) {
  if (!t) return '';
  return Utilities.formatDate(new Date(new Date(t).getTime() - 1000), 'Asia/Taipei', 'yyyy/MM/dd HH:mm');
}
function h_(x) {
  return String(x == null ? '' : x).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; });
}
function out_(t) { return ContentService.createTextOutput(t); }

"use strict";
/* =====================================================================
   仲間（パーティ）と SOS（2026-11-17）
   ・パーティ（会員）：招待コードで仲間が入り、「位置を仲間に共有」をオンにした人の現在地・直近2時間の航跡を地図に出す
   ・ポイント：パーティの人だけが見られる地点を置ける
   ・SOS（ログインした人。無料を含む）：同じパーティの人と、「近くのSOSを受け取る」をオンにした半径30km以内の人に届く
   ・届くのはアプリを開いている間だけ。命にかかわるときは、まず118番（海上保安庁）
   app.js の後に読み込む（$・SH・map・openDlg・avatar などを使う）
   ===================================================================== */
const PT = {
  state:null, inbox:[], mine:null, loaded:false, mineChecked:false,
  tState:0, tInbox:0, tMine:0, busy:false, sent:null, sosSent:0, picking:false,
  share: lsGet("choka-pt-share")!=="0",                 // 位置を仲間に共有（初めはオン）
  rx: lsGet("choka-pt-rx")==="1",                        // 近くのSOSを受け取る（初めはオフ。本人が選ぶ）
  seen: (()=>{ try{ return JSON.parse(lsGet("choka-sos-seen")||"{}"); }catch{ return {}; } })(),
  mk: new Map(), uid:null, rang:{},
};
const SOS_REASONS = ["浸水・沈みそう","エンジン故障","落水（人が海に落ちた）","けが・急病","漂流・流されている","燃料切れ","座礁","その他"];
const ptLayer = L.layerGroup().addTo(map);
const ptColor = no => PAL[(no-1) % PAL.length];
const ago = iso => { if(!iso) return ""; const m=Math.round((Date.now()-new Date(iso))/60000); return m<1?"いま":m<60?`${m}分前`:m<1440?`${Math.floor(m/60)}時間${m%60?m%60+"分":""}前`:`${Math.floor(m/1440)}日前`; };
const myPos = () => hereFix ? {lat:hereFix.lat, lon:hereFix.lon, acc:hereFix.acc} : (lastGps && Date.now()-lastGps.t<300000 ? {lat:lastGps.lat, lon:lastGps.lon} : null);
const kmFromMe = (lat,lon) => { const p=myPos(); if(!p||lat==null) return null; return haversine([p.lat,p.lon],[lat,lon])/1000; };
const kmText = k => k==null ? "" : k<1 ? `${Math.round(k*1000)}m` : `${k.toFixed(k<10?1:0)}km`;
const ptOn = () => !!(SH.sb && hasProfile());
async function ptRpc(fn,args){ const {data,error}=await SH.sb.rpc(fn,args); if(error) throw error; return data; }

/* ---------- 地図の SOS ボタン・お知らせの帯 ---------- */
{
  const w=$("mapwrap");
  const b=document.createElement("button"); b.type="button"; b.id="sosBtn"; b.className="sos-btn"; b.textContent="SOS"; b.title="助けを呼ぶ（SOS）"; w.appendChild(b);
  b.addEventListener("click",e=>{ e.stopPropagation(); sosDlg(); });
  const m=document.createElement("div"); m.id="sosMine"; m.className="sos-bar mine"; m.hidden=true; w.appendChild(m);
  const i=document.createElement("div"); i.id="sosIn"; i.className="sos-bar in"; i.hidden=true; w.appendChild(i);
  const p=document.createElement("div"); p.id="ptPickBar"; p.className="move-bar"; p.hidden=true;
  p.innerHTML=`<span class="mv-t">ポイントを置く場所を、地図でタップしてください。</span><button type="button" class="btn" id="ptPickCancel">やめる</button>`; w.appendChild(p);
  $("ptPickCancel").onclick=()=>ptPickEnd();
}

/* ---------- 音・振動・通知（SOS が届いたとき） ---------- */
let audioCtx=null;
document.addEventListener("pointerdown",()=>{ try{ if(!audioCtx) audioCtx=new (window.AudioContext||window.webkitAudioContext)(); if(audioCtx.state==="suspended") audioCtx.resume(); }catch{} },{passive:true});
function siren(){
  try{ if(!audioCtx) return; const t=audioCtx.currentTime;
    for(let k=0;k<6;k++){ const o=audioCtx.createOscillator(), g=audioCtx.createGain();
      o.type="square"; o.frequency.setValueAtTime(k%2?660:990,t+k*.35); g.gain.setValueAtTime(.12,t+k*.35); g.gain.setValueAtTime(0,t+k*.35+.3);
      o.connect(g).connect(audioCtx.destination); o.start(t+k*.35); o.stop(t+k*.35+.32); } }catch{}
}
function sosNotify(s){
  siren();
  try{ navigator.vibrate?.([600,200,600,200,600]); }catch{}
  try{ if("Notification" in window && Notification.permission==="granted")
    new Notification(`SOS：${s.name}さん（${s.reason}）`,{body:`${s.km!=null?`ここから約${kmText(s.km)}・`:""}${s.msg||"アプリを開いて確認してください"}`,tag:"sos-"+s.id,requireInteraction:true}); }catch{}
}

/* ---------- SOS を出す ---------- */
function posLine(p){ return p ? `<div class="sos-pos mono">${toDM(p.lat,"N","S")}<br>${toDM(p.lon,"E","W")}</div><div class="hint" style="margin:2px 0 0">${p.acc?`精度 ±${Math.round(p.acc)}m・`:""}118番にはこの緯度・経度を伝えてください</div>`
                          : `<div class="hint">現在地を取得中です（屋外・空の見える所で待ってください）</div>`; }
const CALL118 = `<a class="btn sos-call" href="tel:118" data-call118>📞 118番（海上保安庁）に電話する</a>
  <p class="hint sos-call-note">押すと確認が出て、「OK」を選ぶと<b>本当に118番に電話がかかります</b>（スマホ）。</p>`;
/* 118番：まちがえて押してもすぐにかからないよう、一度確かめてから電話をかける */
document.addEventListener("click",e=>{
  const a=e.target.closest("a[data-call118]"); if(!a) return;
  e.preventDefault();
  if(confirm("118番（海上保安庁・海の事故の通報）に電話をかけます。\n\n本当に電話をかけますか？\n（「OK」で電話がかかります）")) location.href="tel:118";
});
function sosDlg(){
  if(PT.mine) return sosMineDlg();
  const p=myPos(), logged=ptOn();
  const b=openDlg("SOS（助けを呼ぶ）",`
    <div class="sos-warn"><b>命にかかわるときは、まず118番</b>（海上保安庁・海の事故の通報）。<br>アプリのSOSは、アプリを開いている<b>パーティの仲間と、近く（約30km以内）で「近くのSOSを受け取る」をオンにしている人</b>に知らせるだけで、届く保証はありません。</div>
    ${CALL118}
    <div class="sec-h">いまの位置</div><div id="sosPosBox">${posLine(p)}</div>
    ${logged ? `
    <div class="sec-h">何がありましたか</div>
    <div class="chips sq" id="sosReason">${SOS_REASONS.map((r,i)=>`<button type="button" class="chip" aria-pressed="${i===0}">${r}</button>`).join("")}</div>
    <div class="grid" style="margin-top:8px">
      <label>乗っている人数<select id="sosPeople"><option value="">—</option>${Array.from({length:12},(_,i)=>`<option>${i+1}</option>`).join("")}</select></label>
      <label class="full">ひとこと（任意）<textarea id="sosMsg" maxlength="200" placeholder="例：白い船・オレンジのライフジャケット。携帯 090-…"></textarea></label>
    </div>
    <div class="actions"><button type="button" class="btn" id="sosNo">やめる</button><button type="button" class="btn danger-fill sos-go" id="sosGo">SOSを出す</button></div>
    <div class="status" id="sosStat"></div>
    <p class="hint">出すと、あなたの表示名・位置・内容が、上の人たちの画面に出ます。出している間は、位置を15秒ごとに送り直します。無事になったら「無事です」で終えてください。</p>`
    : `<div class="rules" style="margin-top:12px">ログインしていないため、アプリからSOSは送れません。上の118番に電話してください。<br>ログイン（無料）すると、アプリからもSOSを出せます。</div>
       <div class="actions"><button type="button" class="btn" id="sosLogin">ログインする</button></div>`}`);
  b.querySelector("#sosLogin")?.addEventListener("click",()=>{ $("dlg").close(); showTab("share"); });
  b.querySelector("#sosNo")?.addEventListener("click",()=>$("dlg").close());
  b.querySelectorAll("#sosReason .chip").forEach(c=>c.onclick=()=>b.querySelectorAll("#sosReason .chip").forEach(x=>x.setAttribute("aria-pressed",String(x===c))));
  const posT=setInterval(()=>{ if(!$("dlg").open || !$("sosPosBox")) return clearInterval(posT); $("sosPosBox").innerHTML=posLine(myPos()); },3000);
  const go=b.querySelector("#sosGo"); if(!go) return;
  go.onclick=async()=>{
    let pos=myPos();
    if(!pos){ setBusy(go,true,"位置を取得中…");
      pos=await new Promise(res=>navigator.geolocation ? navigator.geolocation.getCurrentPosition(x=>res({lat:x.coords.latitude,lon:x.coords.longitude,acc:x.coords.accuracy}),()=>res(null),{enableHighAccuracy:true,timeout:15000,maximumAge:60000}) : res(null));
      setBusy(go,false); }
    if(!pos){ shMsg("sosStat","現在地が分からないため送れません。118番に電話してください。","err"); return; }
    const reason=b.querySelector("#sosReason .chip[aria-pressed=true]")?.textContent||"その他";
    setBusy(go,true,"送信中…");
    try{
      await ptRpc("sos_send",{p:{lat:pos.lat,lon:pos.lon,acc:pos.acc??null,reason,people:$("sosPeople").value||null,msg:$("sosMsg").value}});
      PT.sosSent=Date.now(); await ptLoadMine(); $("dlg").close(); sosMineDlg(true);
    }catch(e){ setBusy(go,false); shMsg("sosStat",shErr(e)+"。118番に電話してください。","err"); }
  };
}
function sosMineDlg(just){
  const s=PT.mine; if(!s){ $("dlg").open && $("dlg").close(); return; }
  const going=s.replies.filter(r=>r.kind==="going"), seen=s.replies.filter(r=>r.kind==="seen");
  const b=openDlg("SOSを出しています",`
    ${just?`<p class="status ok" style="margin-top:0">SOSを出しました。</p>`:""}
    <div class="sos-warn"><b>まだ118番に電話していなければ、電話してください。</b>アプリを開いて、画面を点けたままにしておくと、位置を送り直し続けます。</div>
    ${CALL118}
    <div class="sec-h">内容</div>
    <p style="margin:0">${esc(s.reason)}${s.people?`・${s.people}人`:""}${s.msg?`<br>${esc(s.msg)}`:""}</p>
    <p class="hint">出した時刻 ${fmtJ(s.at)}・位置を送った時刻 ${fmtJ(s.updated_at)}</p>
    <div class="sec-h">応答</div>
    ${s.replies.length ? `<ul class="sos-rep">${going.map(r=>`<li><b>向かっています</b>：${esc(r.name)}さん（${fmtJ(r.at)}）</li>`).join("")}${seen.map(r=>`<li>確認しました：${esc(r.name)}さん（${fmtJ(r.at)}）</li>`).join("")}</ul>`
                       : `<p class="hint">まだ応答はありません（届いた人が「確認した」「向かう」を押すと、ここに出ます）。</p>`}
    <div class="actions"><button type="button" class="btn" id="sosMis">まちがえて出した</button><button type="button" class="btn primary" id="sosSafe">無事です（SOSを終える）</button></div>
    <div class="status" id="sosStat"></div>`);
  const close=async(st,btn)=>{ setBusy(btn,true); try{ await ptRpc("sos_close",{p_status:st}); PT.mine=null; sosMineUi(); $("dlg").close(); }catch(e){ setBusy(btn,false); shMsg("sosStat",shErr(e),"err"); } };
  b.querySelector("#sosSafe").onclick=e=>close("safe",e.target);
  b.querySelector("#sosMis").onclick=e=>close("cancelled",e.target);
}
function sosMineUi(){
  const el=$("sosMine"), s=PT.mine;
  $("sosBtn").classList.toggle("on",!!s);
  if(!s){ el.hidden=true; return; }
  const going=s.replies.filter(r=>r.kind==="going").length, n=s.replies.length;
  el.innerHTML=`<span><b>SOS発信中</b>（${esc(s.reason)}）・${going?`<b>${going}人が向かっています</b>`:n?`${n}人が確認`:"応答待ち"}</span><button type="button" class="btn sm">くわしく・終える</button>`;
  el.querySelector("button").onclick=()=>sosMineDlg();
  el.hidden=false;
}

/* ---------- 届いた SOS ---------- */
function sosInDlg(id){
  const s=PT.inbox.find(x=>x.id===id); if(!s){ openDlg("SOS","<p>このSOSは終わりました（無事になったか、取り消されました）。</p>"); return; }
  PT.seen[s.id]=s.updated_at; lsSet("choka-sos-seen",JSON.stringify(PT.seen)); sosInUi();
  const k=kmFromMe(s.lat,s.lon) ?? s.km;
  const b=openDlg(`SOS：${s.name}さん`,`
    <div class="sos-head">${avatar(s.avatar,s.name,40)}<div><b class="sos-r">${esc(s.reason)}</b>${s.people?`・${s.people}人`:""}${s.party?`<span class="pt-tag">パーティの仲間</span>`:""}
      <div class="hint" style="margin:0">${fmtJ(s.at)}に出しました（${ago(s.at)}）・位置の更新：${ago(s.updated_at)}</div></div></div>
    ${s.msg?`<p class="sos-msg">${esc(s.msg)}</p>`:""}
    <div class="sec-h">位置</div>
    <div class="sos-pos mono">${toDM(s.lat,"N","S")}<br>${toDM(s.lon,"E","W")}</div>
    <p class="hint" style="margin:2px 0 0">${k!=null?`ここから約${kmText(k)}・`:""}${s.acc?`精度 ±${Math.round(s.acc)}m`:""}</p>
    <div class="toolbar" style="margin-top:6px"><button type="button" class="btn sm" id="siMap">地図で見る</button><button type="button" class="btn sm" id="siCopy">緯度・経度をコピー</button></div>
    <div class="sos-warn">118番（海上保安庁）に通報されているか分かりません。<b>助けに向かえないとき・命にかかわりそうなときは、あなたからも118番に通報してください</b>（上の緯度・経度を伝えます）。無理に近づいて二次事故にならないよう気をつけてください。</div>
    ${CALL118}
    <div class="sec-h">応答（${esc(s.name)}さんに届きます）</div>
    <p class="hint" style="margin:0 0 6px">いま ${s.going}人が向かう・${s.seen}人が応答${s.my_reply?`（あなた：${s.my_reply==="going"?"向かう":"確認した"}）`:""}</p>
    <div class="actions"><button type="button" class="btn" id="siSeen">確認した</button><button type="button" class="btn primary" id="siGo">向かう</button></div>
    <div class="status" id="siStat"></div>`);
  b.querySelector("#siMap").onclick=()=>{ $("dlg").close(); map.setView([s.lat,s.lon],Math.max(map.getZoom(),13)); if(isPhone()) scrollTo({top:0}); };
  b.querySelector("#siCopy").onclick=async e=>{ try{ await navigator.clipboard.writeText(`${toDM(s.lat,"N","S")} ${toDM(s.lon,"E","W")}（${s.lat.toFixed(5)}, ${s.lon.toFixed(5)}）`); e.target.textContent="コピーしました"; }catch{ e.target.textContent="コピーできませんでした"; } };
  const reply=async(kind,btn)=>{ setBusy(btn,true); try{ await ptRpc("sos_reply",{p_id:s.id,p_kind:kind}); await ptLoadInbox(); setBusy(btn,false); shMsg("siStat",kind==="going"?"「向かう」を伝えました。":"「確認した」を伝えました。","ok"); }catch(e){ setBusy(btn,false); shMsg("siStat",shErr(e),"err"); } };
  b.querySelector("#siSeen").onclick=e=>reply("seen",e.target);
  b.querySelector("#siGo").onclick=e=>reply("going",e.target);
}
function sosInUi(){
  const el=$("sosIn"), list=PT.inbox;
  if(!list.length){ el.hidden=true; ptBadge(); return; }
  const s=list[0], k=kmFromMe(s.lat,s.lon) ?? s.km;
  el.innerHTML=`<span><b>SOS</b> ${esc(s.name)}さん（${esc(s.reason)}）${k!=null?`・約${kmText(k)}`:""}${list.length>1?` ほか${list.length-1}件`:""}</span><button type="button" class="btn sm">見る</button>`;
  el.querySelector("button").onclick=()=> list.length>1 ? sosListDlg() : sosInDlg(s.id);
  el.hidden=false; ptBadge();
}
function sosListDlg(){
  const b=openDlg("届いているSOS",`<div class="pt-list">${PT.inbox.map(s=>{ const k=kmFromMe(s.lat,s.lon)??s.km;
    return `<button type="button" class="pt-row sos" data-id="${s.id}">${avatar(s.avatar,s.name,28)}<span><b>${esc(s.name)}</b>（${esc(s.reason)}）<small>${ago(s.at)}${k!=null?`・約${kmText(k)}`:""}</small></span></button>`; }).join("")}</div>`);
  b.querySelectorAll("[data-id]").forEach(x=>x.onclick=()=>sosInDlg(+x.dataset.id));
}
function ptBadge(){
  const unseen=PT.inbox.filter(s=>PT.seen[s.id]!==s.updated_at).length, n=PT.inbox.length;
  const el=$("partyBadge"); if(!el) return;
  el.hidden=!n; el.textContent=n?`SOS${unseen?"!":""}`:"";
  el.classList.toggle("sos",!!n);
}

/* ---------- 読み込み ---------- */
async function ptLoadState(){
  PT.tState=Date.now();
  try{ PT.state=await ptRpc("party_state"); PT.loaded=true; }catch{ return; }
  ptDraw(); if(!$("viewParty").hidden) ptRender();
  ptJoinFromLink();
}
async function ptLoadInbox(){
  PT.tInbox=Date.now();
  let list; try{ list=await ptRpc("sos_inbox"); }catch{ return; }
  list=(list||[]).map(s=>({...s, lat:+s.lat, lon:+s.lon}));
  const fresh=list.filter(s=>!PT.seen[s.id] && (PT.rang[s.id]||0)<3);   // 開いて見るまで、3回まで鳴らす
  PT.inbox=list;
  for(const id of Object.keys(PT.seen)) if(!list.some(s=>String(s.id)===id)) delete PT.seen[id];   // 終わったSOSの印は消す
  lsSet("choka-sos-seen",JSON.stringify(PT.seen));
  sosInUi(); ptDraw(); if(!$("viewParty").hidden) ptRender();
  if(fresh.length){ PT.rang[fresh[0].id]=(PT.rang[fresh[0].id]||0)+1; sosNotify(fresh[0]); if(!PT.mine && !$("dlg").open) sosInDlg(fresh[0].id); }
}
async function ptLoadMine(){
  PT.tMine=Date.now(); PT.mineChecked=true;
  try{ PT.mine=await ptRpc("sos_mine"); }catch{ return; }
  sosMineUi();
  if(PT.mine && $("dlg").open && $("dlgTitle").textContent==="SOSを出しています") sosMineDlg();
}
/* 5秒ごとに、必要なものだけ読み込む（画面が見えている間だけ） */
async function ptTick(){
  if(document.visibilityState!=="visible" || PT.busy) return;
  if(!ptOn()){
    if(PT.uid){ PT.uid=null; PT.state=null; PT.inbox=[]; PT.mine=null; PT.loaded=false; PT.mineChecked=false; ptDraw(); sosInUi(); sosMineUi(); if(!$("viewParty").hidden) ptRender(); }
    return;
  }
  if(PT.uid!==SH.user.id){ PT.uid=SH.user.id; PT.loaded=false; PT.mineChecked=false; PT.sent=null; }
  PT.busy=true;
  try{
    const now=Date.now();
    if(!PT.loaded || now-PT.tState>(PT.state?15000:120000)) await ptLoadState();
    if((PT.rx || PT.state) && now-PT.tInbox>20000) await ptLoadInbox();
    if(!PT.mineChecked || (PT.mine && now-PT.tMine>20000)) await ptLoadMine();
  } finally { PT.busy=false; }
}
setInterval(ptTick,5000);
document.addEventListener("visibilitychange",()=>{ if(document.visibilityState==="visible"){ PT.tState=PT.tInbox=PT.tMine=0; setTimeout(ptTick,500); } });

/* ---------- 現在地を送る（app.js の現在地の取得から呼ばれる） ---------- */
let ptSending=false;
async function ptOnFix(c){
  if(!ptOn() || ptSending) return;
  const now=Date.now(), lat=c.latitude, lon=c.longitude;
  if(PT.mine && now-PT.sosSent>15000 && c.accuracy<1000){          // SOS を出している間は、15秒ごとに位置を送り直す
    PT.sosSent=now; ptRpc("sos_send",{p:{lat,lon,acc:c.accuracy}}).catch(()=>{});
  }
  const share=PT.share && !!PT.state, rx=PT.rx;
  if(!share && !rx) return;
  const last=PT.sent, moved=last ? haversine([last.lat,last.lon],[lat,lon]) : Infinity, dt=now-(last?.t||0);
  const ok = share ? (dt>=20000 || (moved>=30 && dt>=5000)) : (dt>=120000 || (moved>=500 && dt>=30000));
  if(!ok || c.accuracy>1500) return;
  ptSending=true;
  try{ await ptRpc("pos_update",{p:{lat:+lat.toFixed(6),lon:+lon.toFixed(6),acc:Math.round(c.accuracy),heading:c.heading??null,speed:c.speed??null,share,rx}});
       PT.sent={lat,lon,t:now}; }catch{}
  ptSending=false;
}
async function ptPushFlags(){                            // 共有・受け取りを切り替えたとき
  if(!ptOn()) return;
  const share=PT.share && !!PT.state, rx=PT.rx, p=myPos();
  try{
    if(!share && !rx) await ptRpc("pos_update",{p:{share:false,rx:false}});
    else if(p){ await ptRpc("pos_update",{p:{lat:p.lat,lon:p.lon,acc:p.acc?Math.round(p.acc):null,share,rx}}); PT.sent={lat:p.lat,lon:p.lon,t:Date.now()}; }
    else PT.sent=null;                                    // 位置が取れしだい送る
  }catch{}
}

/* ---------- 地図に描く（仲間・航跡・ポイント・SOS） ---------- */
function ptMarkerHtml(m){
  const old = m.at && Date.now()-new Date(m.at) > 15*60000;
  const head = m.heading!=null && m.speed>0.5 ? `<i class="pt-hd" style="transform:rotate(${Math.round(m.heading)}deg)"></i>` : "";
  return `<div class="pt-mk${old?" old":""}${m.sos?" sos":""}" style="--c:${ptColor(m.no)}">${head}<span class="pt-dot">${esc([...(m.name||"?")][0])}</span><span class="pt-nm">${m.sos?"SOS ":""}${esc(m.name)}${old?`<small>${ago(m.at)}</small>`:""}</span></div>`;
}
function ptSet(key,make,update){
  let o=PT.mk.get(key);
  if(!o){ o=make(); o.addTo(ptLayer); PT.mk.set(key,o); } else update(o);
  o._keep=true;
}
function ptDraw(){
  for(const o of PT.mk.values()) o._keep=false;
  const st=PT.state;
  if(st){
    for(const m of st.members){
      if(m.me || m.lat==null) continue;
      const html=ptMarkerHtml(m), tr=(m.trail||[]).filter(p=>Date.now()-p[2]<3600000).map(p=>[p[0],p[1]]);
      if(tr.length>1) ptSet("tr"+m.no,()=>L.polyline(tr,{color:ptColor(m.no),weight:3,opacity:.75,dashArray:"6 5",interactive:false}),o=>{ o.setLatLngs(tr); o.setStyle({color:ptColor(m.no)}); });
      ptSet("m"+m.no,()=>{ const mk=L.marker([m.lat,m.lon],{icon:L.divIcon({className:"",html,iconSize:[0,0]}),zIndexOffset:500});
          mk._html=html; mk.bindPopup(()=>ptMemberPop(mk._m)); return mk; },
        o=>{ o.setLatLng([m.lat,m.lon]); if(o._html!==html){ o._html=html; o.setIcon(L.divIcon({className:"",html,iconSize:[0,0]})); } });
      PT.mk.get("m"+m.no)._m=m;
    }
    for(const q of st.points){
      ptSet("p"+q.id,()=>L.marker([q.lat,q.lon],{icon:L.divIcon({className:"",html:`<div class="pt-pt"><span>⚑ ${esc(q.label)}</span></div>`,iconSize:[0,0]})})
        .bindPopup(`<b>⚑ ${esc(q.label)}</b>${q.memo?`<br>${esc(q.memo)}`:""}<div class="hint" style="margin:2px 0 0">${esc(q.by)}さん・${fmtJ(q.at)}</div><div class="coord mono" style="font-size:11px">${fmtPos(q.lat,q.lon)}</div>`),()=>{});
    }
  }
  for(const s of PT.inbox){
    const html=`<div class="sos-mk"><span class="ring"></span><span class="pt-nm">SOS ${esc(s.name)}</span></div>`;
    ptSet("s"+s.id,()=>{ const mk=L.marker([s.lat,s.lon],{icon:L.divIcon({className:"",html,iconSize:[0,0]}),zIndexOffset:1000}); mk.on("click",()=>sosInDlg(s.id)); return mk; },
      o=>o.setLatLng([s.lat,s.lon]));
  }
  for(const [k,o] of PT.mk) if(!o._keep){ ptLayer.removeLayer(o); PT.mk.delete(k); }
}
function ptMemberPop(m){
  const k=kmFromMe(m.lat,m.lon);
  return `<div class="pop">${whoLine(m.avatar,m.name,22,m.tsunuke)}
    <div class="coord mono" style="font-size:11px;margin-top:4px">${fmtPos(m.lat,m.lon)}</div>
    <div class="hint" style="margin:2px 0 0">${ago(m.at)}の位置${m.acc?`・±${Math.round(m.acc)}m`:""}${m.speed>0.5?`・${(m.speed*1.944).toFixed(1)}ノット`:""}${k!=null?`・ここから${kmText(k)}`:""}</div>
    ${m.sos?`<div class="sos-warn" style="margin:6px 0 0"><b>SOS：${esc(m.sos.reason)}</b></div>`:""}</div>`;
}

/* ---------- 地図をタップしてポイントを置く ---------- */
function ptMapClick(e){
  if(!PT.picking) return false;
  ptPickEnd(); ptPointDlg(e.latlng.lat,e.latlng.lng); return true;
}
function ptPickStart(){ PT.picking=true; $("ptPickBar").hidden=false; if(isPhone()) scrollTo({top:0}); }
function ptPickEnd(){ PT.picking=false; $("ptPickBar").hidden=true; }
function ptPointDlg(lat,lon){
  const b=openDlg("ポイントを置く",`<p class="coord mono" style="margin:0">${fmtPos(lat,lon)}</p><p class="hint pdepth"></p>
    <label>名前（30文字まで）<input id="ppLabel" maxlength="30" placeholder="例：ブリ反応・集合場所"></label>
    <label style="margin-top:8px">メモ（任意）<textarea id="ppMemo" maxlength="200"></textarea></label>
    <p class="hint">パーティの仲間だけに見えます。</p>
    <div class="actions"><button type="button" class="btn" id="ppNo">やめる</button><button type="button" class="btn primary" id="ppOk">置く</button></div><div class="status" id="ppStat"></div>`);
  depthText(lat,lon).then(t=>{ const el=b.querySelector(".pdepth"); if(el) el.textContent=t; });
  b.querySelector("#ppNo").onclick=()=>$("dlg").close();
  b.querySelector("#ppOk").onclick=async e=>{
    setBusy(e.target,true);
    try{ await ptRpc("point_add",{p:{lat,lon,label:$("ppLabel").value,memo:$("ppMemo").value}}); $("dlg").close(); await ptLoadState(); }
    catch(err){ setBusy(e.target,false); shMsg("ppStat",shErr(err),"err"); }
  };
  setTimeout(()=>$("ppLabel")?.focus(),50);
}

/* ---------- 招待リンク（?party=コード）から入る ---------- */
{ const c=new URLSearchParams(location.search).get("party");
  if(c){ lsSet("choka-pt-join",c.toUpperCase().slice(0,10)); try{ const u=new URL(location.href); u.searchParams.delete("party"); history.replaceState(null,"",u); }catch{} } }
function ptJoinFromLink(){
  const code=lsGet("choka-pt-join"); if(!code || !ptOn() || $("dlg").open) return;
  if(PT.state?.code===code){ lsSet("choka-pt-join",null); return; }
  lsSet("choka-pt-join",null);
  if(!isMember()){ memberGate("パーティ"); return; }
  const b=openDlg("パーティに入る",`<p>招待コード <b class="mono">${esc(code)}</b> のパーティに入りますか？</p>
    ${PT.state?`<p class="hint">いま入っている「${esc(PT.state.name)}」からは抜けます。</p>`:""}
    <div class="actions"><button type="button" class="btn" id="pjNo">入らない</button><button type="button" class="btn primary" id="pjOk">入る</button></div><div class="status" id="pjStat"></div>`);
  b.querySelector("#pjNo").onclick=()=>$("dlg").close();
  b.querySelector("#pjOk").onclick=e=>ptJoin(code,e.target,"pjStat",true);
}
async function ptJoin(code,btn,stat,dlg){
  setBusy(btn,true);
  try{ const name=await ptRpc("party_join",{p_code:code}); if(dlg) $("dlg").close(); await ptLoadState(); await ptPushFlags(); showTab("party");
       shMsg("ptStat",`「${name}」に入りました。`,"ok"); }
  catch(e){ setBusy(btn,false); shMsg(stat,shErr(e),"err"); }
}

/* ---------- 「仲間・SOS」タブ ---------- */
function ptOpen(){ ptRender(); if(ptOn()){ PT.tState=PT.tInbox=0; ptTick(); } }
function ptRender(){
  const box=$("ptBox"); if(!box) return;
  if(!SB_URL||!SB_KEY){ box.innerHTML=`<p class="rules">サーバーの設定が必要です。</p>`; return; }
  const notif = "Notification" in window ? Notification.permission : "none";
  const sosSec = `
    <div class="sec-h" style="margin-top:0">SOS</div>
    <div class="sos-warn"><b>命にかかわるときは、まず118番</b>（海上保安庁）。地図の右上の赤い「SOS」ボタンから、いまの緯度・経度を見ながら電話できます。</div>
    ${ptOn() ? `
    <label class="pt-sw"><input type="checkbox" id="ptRx" ${PT.rx?"checked":""}><span><b>近くのSOSを受け取る</b><small>アプリを開いている間、だれかが約30km以内でSOSを出すと、音と画面で知らせます。そのために、現在地をおおよそ2分ごとにサーバーへ送ります（ほかの人には見えません。オフにすると消します）。</small></span></label>
    ${notif==="default"?`<button type="button" class="btn sm" id="ptNotif">ブラウザの通知を許可する</button>`:notif==="denied"?`<p class="hint">ブラウザの通知が止められています（音と画面のお知らせは出ます）。</p>`:""}
    ${PT.inbox.length?`<div class="pt-list">${PT.inbox.map(s=>{ const k=kmFromMe(s.lat,s.lon)??s.km; return `<button type="button" class="pt-row sos" data-sos="${s.id}">${avatar(s.avatar,s.name,28)}<span><b>SOS ${esc(s.name)}</b>（${esc(s.reason)}）<small>${ago(s.at)}${k!=null?`・約${kmText(k)}`:""}・向かう${s.going}人</small></span></button>`; }).join("")}</div>`
                     :`<p class="hint">いま届いているSOSはありません。</p>`}
    <p class="hint">届くのは、このアプリを開いて画面が点いている間だけです。閉じているとき・画面を消しているときは届きません。</p>`
    : `<div class="rules">ログイン（無料）すると、アプリからSOSを出したり、近くのSOSを受け取ったりできます。</div><button type="button" class="btn primary" id="ptLogin">ログインする</button>`}`;
  let ptSec = `<div class="sec-h">パーティ（仲間の位置）</div>`;
  const st=PT.state;
  if(!ptOn()) ptSec += `<p class="hint">パーティを組むと、仲間の船の位置と、直近の航跡・置いたポイントが地図に出ます（会員の機能）。</p>`;
  else if(!st){
    ptSec += isMember() ? `
      <p class="hint">パーティを作って招待コードを仲間に送るか、仲間から聞いた招待コードで入ります（1人1パーティ・20人まで）。</p>
      <div class="pt-form"><label>新しいパーティの名前<input id="ptName" maxlength="30" placeholder="例：氷見沖 ブリ隊"></label><button type="button" class="btn primary" id="ptCreate">作る</button></div>
      <div class="pt-form"><label>招待コードで入る<input id="ptCode" maxlength="10" autocapitalize="characters" placeholder="例：K7QH3M" class="mono"></label><button type="button" class="btn" id="ptJoinBtn">入る</button></div>`
      : `<div class="lockbox" role="button" tabindex="0" data-lock="パーティ">🔒 <b>会員になると</b>、パーティを組んで仲間の船の位置・航跡・ポイントを地図で見られます</div>`;
  } else {
    const link=`${location.origin}${location.pathname}?party=${st.code}`;
    ptSec += `
      <div class="pt-head"><b>${esc(st.name)}</b><span class="hint" style="margin:0">招待コード <b class="mono pt-code">${esc(st.code)}</b></span>
        <button type="button" class="btn sm" id="ptInvite">招待する</button></div>
      <label class="pt-sw"><input type="checkbox" id="ptShare" ${PT.share?"checked":""}><span><b>自分の位置を仲間に共有する</b><small>アプリを開いている間、約20秒ごとに位置を送ります。仲間には、位置と直近2時間の航跡が見えます。</small></span></label>
      <div class="pt-list">${st.members.map(m=>{ const k=m.me?null:kmFromMe(m.lat,m.lon);
        return `<div class="pt-row${m.sos?" sos":""}" style="--c:${ptColor(m.no)}"><i class="pt-c"></i>${avatar(m.avatar,m.name,28,m.tsunuke)}
          <span><b>${m.sos?"SOS ":""}${esc(m.name)}</b>${m.me?"（自分）":""}${m.owner?`<span class="pt-tag">作った人</span>`:""}
            <small>${m.me ? (PT.share?"位置を共有中":"位置を共有していません") : m.lat==null ? "位置の共有なし" : `${ago(m.at)}${k!=null?`・${kmText(k)}`:""}${m.speed>0.5?`・${(m.speed*1.944).toFixed(1)}kt`:""}`}</small></span>
          ${!m.me&&m.lat!=null?`<button type="button" class="btn sm" data-go="${m.lat},${m.lon}">地図</button>`:""}
          ${st.owner&&!m.me?`<button type="button" class="btn sm danger" data-kick="${m.no}" data-nm="${esc(m.name)}">外す</button>`:""}</div>`; }).join("")}</div>
      <div class="sec-h">ポイント（仲間だけに見えます）</div>
      <div class="toolbar"><button type="button" class="btn sm" id="ptPtHere">現在地に置く</button><button type="button" class="btn sm" id="ptPtMap">地図をタップして置く</button></div>
      ${st.points.length?`<div class="pt-list">${st.points.map(q=>`<div class="pt-row"><span class="pt-flag">⚑</span><span><b>${esc(q.label)}</b><small>${esc(q.by)}さん・${fmtJ(q.at)}${q.memo?`・${esc(q.memo)}`:""}</small></span>
          <button type="button" class="btn sm" data-go="${q.lat},${q.lon}">地図</button>${q.mine||st.owner?`<button type="button" class="btn sm danger" data-pdel="${q.id}">消す</button>`:""}</div>`).join("")}</div>`:`<p class="hint">まだポイントはありません。</p>`}
      <div class="toolbar" style="margin-top:14px">
        <button type="button" class="btn sm" id="ptLeave">パーティを抜ける</button>
        ${st.owner?`<button type="button" class="btn sm" id="ptRecode">招待コードを作り直す</button><button type="button" class="btn sm danger" id="ptClose">解散する</button>`:""}
      </div>`;
    ptSec += `<input type="hidden" id="ptLink" value="${esc(link)}">`;
  }
  box.innerHTML = sosSec + ptSec + `<div class="status" id="ptStat"></div>`;

  $("ptLogin")?.addEventListener("click",()=>showTab("share"));
  $("ptRx")?.addEventListener("change",async e=>{ PT.rx=e.target.checked; lsSet("choka-pt-rx",PT.rx?"1":"0"); await ptPushFlags(); if(PT.rx){ PT.tInbox=0; ptTick(); } else { if(!PT.state){ PT.inbox=[]; sosInUi(); ptDraw(); } } });
  $("ptNotif")?.addEventListener("click",async()=>{ try{ await Notification.requestPermission(); }catch{} ptRender(); });
  $("ptShare")?.addEventListener("change",async e=>{ PT.share=e.target.checked; lsSet("choka-pt-share",PT.share?"1":"0"); await ptPushFlags(); ptRender(); });
  $("ptCreate")?.addEventListener("click",async e=>{ const name=$("ptName").value.trim(); if(!name){ shMsg("ptStat","パーティの名前を入れてください","err"); return; }
    setBusy(e.target,true); try{ await ptRpc("party_create",{p_name:name}); await ptLoadState(); await ptPushFlags(); shMsg("ptStat","パーティを作りました。「招待する」で仲間にコードを送ってください。","ok"); }catch(err){ setBusy(e.target,false); shMsg("ptStat",shErr(err),"err"); } });
  $("ptJoinBtn")?.addEventListener("click",e=>{ const c=$("ptCode").value.trim(); if(!c){ shMsg("ptStat","招待コードを入れてください","err"); return; } ptJoin(c,e.target,"ptStat",false); });
  $("ptInvite")?.addEventListener("click",async()=>{
    const link=$("ptLink").value, text=`釣果海図ログのパーティ「${st.name}」に入ってください。招待コード：${st.code}\n${link}`;
    if(navigator.share){ try{ await navigator.share({title:"パーティへの招待",text}); return; }catch{} }
    try{ await navigator.clipboard.writeText(text); shMsg("ptStat","招待の文とリンクをコピーしました。LINEやメールに貼って送ってください。","ok"); }catch{ shMsg("ptStat",`招待コード：${st.code}`,"ok"); }
  });
  box.querySelectorAll("[data-sos]").forEach(x=>x.onclick=()=>sosInDlg(+x.dataset.sos));
  box.querySelectorAll("[data-go]").forEach(x=>x.onclick=()=>{ const [a,o]=x.dataset.go.split(",").map(Number); map.setView([a,o],Math.max(map.getZoom(),13)); if(isPhone()) scrollTo({top:0,behavior:"smooth"}); });
  box.querySelectorAll("[data-kick]").forEach(x=>x.onclick=async()=>{ if(!confirm(`${x.dataset.nm}さんをパーティから外しますか？`)) return;
    try{ await ptRpc("party_admin",{p_action:"kick",p_member:+x.dataset.kick}); await ptLoadState(); }catch(e){ shMsg("ptStat",shErr(e),"err"); } });
  box.querySelectorAll("[data-pdel]").forEach(x=>x.onclick=async()=>{ if(!confirm("このポイントを消しますか？")) return;
    try{ await ptRpc("point_del",{p_id:+x.dataset.pdel}); await ptLoadState(); }catch(e){ shMsg("ptStat",shErr(e),"err"); } });
  $("ptPtHere")?.addEventListener("click",()=>{ const p=myPos(); if(!p){ shMsg("ptStat","現在地を取得できていません。「地図をタップして置く」を使ってください","err"); return; } ptPointDlg(p.lat,p.lon); });
  $("ptPtMap")?.addEventListener("click",()=>ptPickStart());
  $("ptLeave")?.addEventListener("click",async()=>{ if(!confirm(`「${st.name}」から抜けますか？`)) return;
    try{ await ptRpc("party_leave"); PT.state=null; await ptPushFlags(); await ptLoadState(); }catch(e){ shMsg("ptStat",shErr(e),"err"); } });
  $("ptRecode")?.addEventListener("click",async()=>{ if(!confirm("招待コードを作り直しますか？（前のコードでは入れなくなります。入っている人はそのままです）")) return;
    try{ await ptRpc("party_admin",{p_action:"recode"}); await ptLoadState(); }catch(e){ shMsg("ptStat",shErr(e),"err"); } });
  $("ptClose")?.addEventListener("click",async()=>{ if(!confirm(`「${st.name}」を解散しますか？（全員が抜け、ポイントも消えます）`)) return;
    try{ await ptRpc("party_admin",{p_action:"close"}); PT.state=null; await ptPushFlags(); await ptLoadState(); }catch(e){ shMsg("ptStat",shErr(e),"err"); } });
}

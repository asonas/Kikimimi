// Correct the common meter once, then update instance peak positions.
const header=meterComponent.children[0];const spacer=header.children[1];spacer.resize(1,1);spacer.layoutSizingHorizontal='FILL';spacer.layoutSizingVertical='FIXED';mutated.push(spacer.id);
for(const i of page.findAllWithCriteria({types:['INSTANCE']}))if(i.name.startsWith('Meter /')){
 const bars=i.findOne(n=>n.name==='Meter rail / −60…0 dBFS');const segments=bars.children.filter(n=>n.name.startsWith('Segment '));
 for(const segment of segments)if(segment.strokes.length){segment.strokeTopWeight=0;segment.strokeBottomWeight=0;segment.strokeRightWeight=2;segment.strokeLeftWeight=0;mutated.push(segment.id);}
}
// Recording settings fit within the same window size.
const rs=await figma.getNodeByIdAsync(SCREENS['settings-recording']);const sm=rs.findOne(n=>n.name==='Settings content');sm.itemSpacing=12;sm.setBoundVariable('itemSpacing',vars.space12);sm.paddingTop=sm.paddingBottom=24;sm.setBoundVariable('paddingTop',vars.space24);sm.setBoundVariable('paddingBottom',vars.space24);mutated.push(sm.id);
const recordingIntro=sm.findOne(n=>n.type==='TEXT'&&n.characters==='自分と相手の声を録音するための設定です。');if(recordingIntro)recordingIntro.remove();
// A ready model should not simultaneously offer installation.
const ts=await figma.getNodeByIdAsync(SCREENS['settings-transcription']);const obsolete=ts.findOne(n=>n.name==='Section / モデルの準備ができていない場合');if(obsolete)obsolete.remove();
// Use an actual switch affordance for selected calendars.
const switchSet=await figma.importComponentSetByKeyAsync('7a8dc511d7173ec44c06ef0e8b1a5a6947c4a19c');
for(const k of ['Checked','Unchecked']){
 const comp=switchSet.children.find(n=>n.name==='State=Default, Value Type='+k);
 await Promise.all(comp.findAllWithCriteria({types:['TEXT']}).flatMap(t=>t.getStyledTextSegments(['fontName']).map(s=>figma.loadFontAsync(s.fontName))));
 const calendar=await figma.getNodeByIdAsync(SCREENS['settings-calendar']);const row=calendar.findOne(n=>n.type==='FRAME'&&n.name===(k==='Checked'?'仕事':'個人'));
 const toggle=track(comp.createInstance());toggle.setProperties({'Has Label#373:0':false,'Has Description#2137:0':false});row.appendChild(toggle);toggle.resize(44,24);toggle.layoutSizingHorizontal='HUG';toggle.layoutSizingVertical='HUG';
 const pill=toggle.findOne(n=>n.type==='FRAME'&&n.name==='Switch');pill.fills=[paint(k==='Checked'?'ink':'control')];mutated.push(row.id,pill.id);
 const knob=toggle.findOne(n=>n.name==='Knob');knob.fills=[paint('surface')];mutated.push(knob.id);
}
// Remove a generic encouragement line; retain the actual operational guidance.
const active=await figma.getNodeByIdAsync(SCREENS.recording);const slogan=active.findOne(n=>n.type==='TEXT'&&n.characters==='このまま、会話に集中できます。');if(slogan)slogan.remove();
// Index and feature map. This is design documentation, outside product screens.
const index=C(null,'00 / 目的と機能の地図',3600,32,'surface',48);index.x=160;index.y=-800;screens.index=index.id;
const title=R(index,'Overview heading',3504,20);T(title,'Kikimimi','title');T(title,'録音から、振り返りまで。','heading');S(title);T(title,'画面設計案  /  2026.11.10','small','secondary');
T(index,'面接前に迷わず準備し、会話中に入力を確かめ、終わったら自分の言葉と相手の言葉を読み返す。','body','secondary',3400);
const columns=R(index,'Task map',3504,24);columns.counterAxisAlignItems='MIN';
const groups=[['01  準備する','一覧・予定・新しい録音','会社名とタイトル\nカレンダーの予定から準備\nマイクと相手のアプリの確認\n必要な許可を整える','prepare'],['02  会話を残す','録音中・入力状態','自分と相手を別々に録音\n経過時間・開始と停止\n短い間隔で動くレベルメーター\n入力停止を音源の近くに表示','recording'],['03  読み返す','文字起こし・要約','停止後にMacで文字起こし\n話者・時刻付きの本文\n手動でOpenAIへ送り要約\nMarkdownコピー・ノート書き出し','transcript'],['04  整える','5つの設定','録音：許可・マイク・チャンネル\n文字起こし：モデル\nカレンダー：表示する予定\n要約：接続とモデル / 書き出し：保存先','settings-recording']];
for(const [title,subtitle,body,to]of groups){const c=C(columns,title,858,12,'paper',24);c.cornerRadius=8;T(c,title,'heading');T(c,subtitle,'label');T(c,body,'body','secondary',810);B(c,'画面を見る','secondary',to);}
const notes=R(index,'Design decisions',3504,32);const n1=C(notes,'Principles',1736,8);T(n1,'見た目の約束','heading');T(n1,'生成り #f5f5f4 × 墨色 #1c1917。余白と文字で整理し、色は録音・注意・入力に限定。\nデジタル庁のコントラストとフォーカス、Rexの行単位の情報整理を参考にする。','body','secondary',1700);const n2=C(notes,'Scope',1736,8);T(n2,'この案の範囲','heading');T(n2,'編集可能な画面とクリック遷移。会社・会話・予定は架空のサンプル。\n実際の録音、文字起こし、設定変更は行わない。メーターの動きは別の動作サンプルで確認。','body','secondary',1700);
// Native prototype links. Unimplemented OS dialogs deliberately stay static.
const allScreens={...SCREENS,...screens};const ignored=[];let connected=0;
for(const l of [...LINKS,...links]){const dest=allScreens[l.to];if(!dest){ignored.push(l.to);continue;}const n=await figma.getNodeByIdAsync(l.id);if(!n)continue;let ancestor=n;while(ancestor.parent&&ancestor.parent.type!=='PAGE')ancestor=ancestor.parent;if(ancestor.id===dest)continue;await n.setReactionsAsync([{trigger:{type:'ON_CLICK'},actions:[{type:'NODE',destinationId:dest,navigation:'NAVIGATE',transition:null,resetScrollPosition:true}]}]);mutated.push(n.id);connected++;}
const transcript=await figma.getNodeByIdAsync(SCREENS.transcript);const summaryTab=transcript.findOne(n=>n.type==='INSTANCE'&&n.name==='Button / 要約');await summaryTab.setReactionsAsync([{trigger:{type:'ON_CLICK'},actions:[{type:'NODE',destinationId:SCREENS['summary-empty'],navigation:'NAVIGATE',transition:null}]}]);mutated.push(summaryTab.id);
page.flowStartingPoints=[{nodeId:SCREENS.library,name:'録音の準備から振り返りへ'},{nodeId:SCREENS['settings-recording'],name:'設定'},{nodeId:SCREENS['input-error'],name:'入力停止時'},{nodeId:SCREENS['first-run'],name:'はじめての準備'}];mutated.push(page.id);
return {createdNodeIds:made,mutatedNodeIds:mutated,screens:allScreens,indexId:index.id,connections:connected,staticOSActions:[...new Set(ignored)]};

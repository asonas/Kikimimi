function settings(key,title,col,row){const {root,body}=screen(key,title,col,row,true);body.layoutMode='HORIZONTAL';body.itemSpacing=0;body.paddingTop=body.paddingBottom=body.paddingLeft=body.paddingRight=0;const side=C(body,'Settings sidebar',248,8,'paper',24);side.layoutSizingVertical='FILL';T(side,'設定','heading');V(side,12);for(const [k,name,sub]of [['recording','録音','マイクと音声の許可'],['transcription','文字起こし','このMacで処理'],['calendar','カレンダー','予定を表示'],['summary','要約','ChatGPT・APIキー'],['export','書き出し','ノートの保存先']]){const nav=C(side,'Settings navigation / '+name,200,3,key==='settings-'+k?'selected':null,12);nav.cornerRadius=8;T(nav,name,'label');T(nav,sub,'small','secondary',176);links.push({id:nav.id,to:'settings-'+k});}V(side,164);T(side,'Kikimimi','small','secondary');const main=C(body,'Settings content',872,24,'surface',40);main.layoutSizingVertical='FILL';return main;}
function section(parent,title){const s=C(parent,'Section / '+title,792,12);T(s,title,'heading');const g=C(s,'Grouped rows / '+title,792,0,'paper');g.cornerRadius=8;return g;}
function sr(group,title,desc,value,action,dest,tone='ink'){const r=R(group,title,792,16,null,16);const l=C(r,'Label and description',480,3);T(l,title,'label');if(desc)T(l,desc,'small','secondary',470);S(r);if(value)T(r,value,'label',tone);if(action)B(r,action,'secondary',dest);return r;}
function sh(main,title,sub){T(main,title,'title');T(main,sub,'small','secondary',790);}
{
 const m=settings('settings-recording','07 / 設定 — 録音',0,2);sh(m,'録音','自分と相手の声を録音するための設定です。');
 const p=section(m,'録音に必要な許可');sr(p,'マイク','自分の声を録音します。','許可済み',null,null,'success');line(p,792);sr(p,'画面収録','相手のアプリの音声を取り込みます。映像は保存しません。','許可済み',null,null,'success');
 const input=section(m,'自分の音声');sr(input,'マイク','使用する入力を選びます。','USBマイク  ▾');line(input,792);sr(input,'入力チャンネル',null,'INPUT 1  ▾');
 const preview=C(m,'Mic preview',792,8);meter(preview,'マイクの入力',-24,-16,792);label(preview,'声を出して確認できます。録音中はここでの入力確認を停止します。');
 const rem=section(m,'相手の音声');sr(rem,'前回選んだアプリ','録音を始めるときに変更できます。','Google Chrome');
}
{
 const m=settings('settings-transcription','08 / 設定 — 文字起こし',1,2);sh(m,'文字起こし','音声を外部に送らず、このMacで文字にします。');
 const g=section(m,'文字起こしモデル');sr(g,'Whisper large-v3-turbo','日本語の会話に使用するモデルです。','準備完了',null,null,'success');
 T(m,'録音を止めると、保存に続いて文字起こしが始まります。\nほかの録音中は待機し、録音が終わると再開します。','body','secondary',740);
 const task=section(m,'モデルの準備ができていない場合');sr(task,'音声の録音は先にできます','モデルのダウンロード後に、保存済みの録音から文字起こしできます。',null,'モデルを準備','model-download');
}
{
 const m=settings('settings-calendar','09 / 設定 — カレンダー',2,2);sh(m,'カレンダー','予定を表示して、面接の録音を準備しやすくします。');
 const g=section(m,'カレンダーへのアクセス');sr(g,'アクセス','許可しなくても録音できます。','許可済み',null,null,'success');
 const list=section(m,'表示するカレンダー');sr(list,'仕事','Googleアカウント','表示する');line(list,792);sr(list,'個人','iCloud','表示しない');
 const controls=R(m,'Calendar selection actions',792,12);B(controls,'すべて表示','secondary','settings-calendar-all');B(controls,'すべて非表示','secondary','settings-calendar-none');
 T(m,'アカウントの追加や変更は、macOSのカレンダーで行います。','small','secondary',790);
}
{
 const m=settings('settings-summary','10 / 設定 — 要約',0,3);sh(m,'要約','文字起こしをOpenAIへ送り、面接の要点をまとめます。');
 const methods=R(m,'Provider selection',792,12);B(methods,'ChatGPTでサインイン','primary','settings-summary');B(methods,'APIキーを使う','secondary','settings-api');
 const g=section(m,'ChatGPT');sr(g,'アカウント','sample@example.com','サインイン済み','サインアウト','settings-signout');
 const model=section(m,'要約に使うモデル');sr(model,'モデル',null,'gpt-6.1-sol  ▾','一覧を更新','settings-summary');
 T(m,'「要約を作成」を押したときだけ、文字起こしを送信します。\n音声ファイルは送信しません。','body','secondary',780);
 const info=C(m,'Provider note',792,8,'paper',20);info.cornerRadius=8;T(info,'ChatGPTの利用上限は、ほかのアプリと共有します。','small','secondary',750);
}
{
 const m=settings('settings-export','11 / 設定 — 書き出し',1,3);sh(m,'書き出し','録音ごとに、文字起こしと要約を1つのノートにまとめます。');
 const g=section(m,'ノートの保存先');sr(g,'フォルダ','~/Documents/面接ノート',null,'フォルダを変更','folder-selection');line(g,792);sr(g,'選択したフォルダを確認',null,null,'Finderで表示','folder-selection');
 T(m,'書き出す内容','heading');T(m,'会社名・タイトル・日時\n文字起こし（話者・時刻付き）\n要約（作成されている場合）','body','ink',740);
 T(m,'各録音の「ノートを書き出す」から保存します。\n同じ録音を書き出すと、同じ名前のノートを更新します。\n音声ファイルはこのフォルダにコピーされません。','small','secondary',780);
 B(m,'保存先の設定を解除','quiet','export-folder-cleared');
}
// First launch: required recording setup is separated from optional services.
{
 const {body}=screen('first-run','12 / はじめての準備',2,3);heading(body,'録音を始める準備','最初に、音声の許可とマイクを確認します。');
 const rows=C(body,'Required setup',992,0,'paper',24);rows.cornerRadius=8;
 for(const [num,title,desc,action]of [['1','マイクへのアクセス','自分の声を録音するために必要です。','マイクを許可'],['2','画面収録へのアクセス','相手のアプリの音声を取り込みます。映像は保存しません。','画面収録を許可'],['3','使用するマイク','意図したマイクに声が届くか、メーターで確認します。','マイクを選ぶ']]){const r=R(rows,title,944,20);r.paddingTop=r.paddingBottom=20;T(r,num,'heading','secondary',24);const c=C(r,'Setup description',630,4);T(c,title,'heading');T(c,desc,'small','secondary',610);S(r);B(r,action,'secondary','settings-recording');if(num!=='3')line(rows,944);}
 T(body,'あとから設定できること','heading');T(body,'文字起こしのモデル、カレンダー、要約、書き出し先は、録音の準備ができてから設定できます。','body','secondary',900);const r=R(body,'Ready actions',992,12);B(r,'設定で確認する','primary','settings-recording');
}
return result();

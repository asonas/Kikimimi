function modal(key,title,x,y,width=620){const n=C(null,title,width,24,'surface',32);n.x=x;n.y=y;n.cornerRadius=12;n.strokes=[paint('line')];n.strokeWeight=1;screens[key]=n.id;return n;}
// Confirm what leaves the Mac, at the moment the user requests a summary.
{
 const d=modal('summary-consent','確認 / 要約の送信',4200,1100);T(d,'文字起こしを送信して要約します','heading');T(d,'この録音の文字起こしをOpenAIへ送信します。\n音声ファイルは送信しません。','body','ink',556);T(d,'次回からは「要約を作成」を押すと送信します。','small','secondary',556);const r=R(d,'Dialog actions',556,12);B(r,'キャンセル','secondary','transcript');S(r);B(r,'送信して要約を作成','primary','summary');
}
{
 const d=modal('export','確認 / ノートを書き出す',4200,1510);T(d,'ノートを書き出す','heading');T(d,'山吹デザイン / 一次面接','label');const details=C(d,'Export details',556,12,'paper',20);details.cornerRadius=8;T(details,'保存先','small','secondary');T(details,'Documents / 面接ノート','label');T(details,'含める内容','small','secondary');T(details,'文字起こし・作成済みの要約','label');T(d,'同じ録音のノートがあれば、内容を更新します。','small','secondary',556);const r=R(d,'Export actions',556,12);B(r,'キャンセル','secondary','transcript');S(r);B(r,'書き出す','primary','exported');
}
{
 const d=modal('exported','完了 / ノートの書き出し',4200,2010);state(d,'ノートを書き出しました');T(d,'山吹デザイン / 一次面接','heading');T(d,'Documents / 面接ノート に保存しました。','body','secondary',556);B(d,'録音に戻る','primary','transcript');
}
{
 const d=modal('recording-info','詳細 / 録音の情報',4900,1100);T(d,'録音の情報','heading');for(const [k,v]of [['会社名','山吹デザイン'],['タイトル','一次面接'],['日時','2026年11月9日 14:00'],['録音時間','47分12秒'],['自分の音声','USBマイク / 保存済み'],['相手の音声','Google Chrome / 保存済み']]){const r=R(d,k,556,20);T(r,k,'small','secondary',130);T(r,v,'label');line(d,556);}const r=R(d,'Audio actions',556,12);B(r,'Finderで表示','secondary');B(r,'文字起こしをやり直す','secondary','processing');B(d,'閉じる','quiet','transcript');
}
{
 const d=modal('copied','完了 / Markdownをコピー',4900,1840);state(d,'Markdownをコピーしました');T(d,'文字起こしをコピーしました。\nメモや文書に貼り付けて使えます。','body','secondary',556);B(d,'文字起こしに戻る','primary','transcript');
}
// Signal loss is separate from a quiet speaker.
{
 const {body}=screen('input-error','13 / 録音中 — 入力停止',0,4,true);heading(body,'山吹デザイン','二次面接  /  2026年11月10日');const r=R(body,'Recording controls',992,24);state(r,'録音中','danger');T(r,'00:12:38','time');S(r);B(r,'録音を停止','danger','processing');
 meter(body,'自分  ·  USBマイク',-60,-60,992);banner(body,'自分の音声が途切れました','マイクの接続を確認してください。今の録音では入力を再開できないため、停止してから録音をやり直してください。','warning',992);meter(body,'相手  ·  Google Chrome',-18,-12,992);state(body,'相手の音声は録音を続けています');
}
{
 const {body}=screen('summary-empty','14 / 要約を作成する前',1,4,true);heading(body,'山吹デザイン','一次面接  /  2026年11月9日 14:00  /  47分12秒');tabs(body,'要約');T(body,'面接の要点をまとめる','heading');T(body,'文字起こしから、話した内容や質問をまとめられます。\n作成した要約は、文字起こしと一緒にノートへ書き出せます。','body','secondary',860);B(body,'要約を作成','primary','summary-consent');T(body,'作成するときに、文字起こしをOpenAIへ送信します。','small','secondary');
}
{
 const {body}=screen('settings-api','15 / 設定 — APIキー',2,4,true);heading(body,'APIキーで要約する','OpenAI APIで使用するキーとモデルを設定します。');const choice=R(body,'Provider choices',992,12);B(choice,'ChatGPTでサインイン','secondary','settings-summary');B(choice,'APIキーを使う','primary','settings-api');field(body,'APIキー','保存済みのキーは表示しません。','キーはmacOSのキーチェーンに保存します。',792);const a=R(body,'Key actions',792,12);B(a,'キーを保存','primary');B(a,'保存したキーを削除','secondary');field(body,'要約に使うモデル','gpt-6.1-sol  ▾',null,792);T(body,'OpenAI APIの利用料金がかかります。\n「要約を作成」を押したときだけ、文字起こしを送信します。','body','secondary',850);
}
// Compact menu-bar surface.
{
 const d=modal('menubar','16 / メニューバー — 録音中',5600,1100,380);const r=R(d,'Menu header',316,12);T(r,'Kikimimi','heading');S(r);state(r,'録音中','danger');T(d,'山吹デザイン','label');T(d,'00:12:38','heading');B(d,'録音を停止','danger','processing');line(d,316);B(d,'録音画面を開く','quiet','recording');B(d,'設定を開く','quiet','settings-recording');
}
// Review specimens are outside the user-facing screens.
{
 const d=modal('states','状態 / 待機・エラー・復元',4200,2460,1040);T(d,'状態の伝え方','title');T(d,'同じ「処理中」にまとめず、何が終わり、次に何が必要かを示す。','body','secondary',976);
 banner(d,'モデルをダウンロードしてください','音声は録音できます。文字起こしには、最初にモデルの準備が必要です。','warning',976,'ダウンロード');
 banner(d,'録音が終わるのを待っています','音声は保存済みです。いまの録音が終わると、文字起こしを再開します。','warning',976);
 banner(d,'文字起こしができませんでした','録音した音声は保存されています。もう一度お試しください。','danger',976,'やり直す','processing');
 banner(d,'前回の録音を復元しました','中断までに残った音声を保存しました。内容を確認して、文字起こしを開始できます。','success',976,'録音を確認','recording-info');
 banner(d,'ノートを書き出せませんでした','保存先のフォルダを確認してください。録音と文字起こしはこのMacに残っています。','danger',976,'保存先を確認','settings-export');
 banner(d,'書き出したノートより新しい内容があります','文字起こしか要約を更新しました。もう一度書き出すとノートに反映されます。','warning',976,'もう一度書き出す','export');
 banner(d,'許可を反映するため再起動が必要です','Kikimimiを再起動すると、相手のアプリの音声を録音できるようになります。','warning',976,'再起動');
}
return result();

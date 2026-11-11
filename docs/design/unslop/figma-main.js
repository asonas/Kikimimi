// Recording library
{
 const {body}=screen('library','01 / 録音一覧',0,0);
 heading(body,'録音','会話の記録を、ここから。','新しい録音','prepare');
 const upcoming=C(body,'Upcoming events',992,0,'paper',24);upcoming.cornerRadius=8;
 const uh=R(upcoming,'Section title',944,12);T(uh,'これからの予定','heading');S(uh);label(uh,'カレンダーから表示');
 V(upcoming,12);
 for(const [when,name]of [['今日  15:00–16:00','山吹デザイン / 二次面接'],['11月12日  10:00–10:45','白樺ソフト / カジュアル面談']]){const r=R(upcoming,name,944,20);T(r,when,'number','secondary',190);T(r,name,'label','ink',520);S(r);B(r,'録音を準備','secondary','prepare');if(name.startsWith('山吹'))line(upcoming,944);}
 const h=R(body,'Recording list heading',992,16);T(h,'これまでの録音','heading');S(h);label(h,'新しい順');
 const list=C(body,'Recordings',992,0);
 const items=[['11月9日','山吹デザイン','一次面接','47分12秒','文字起こし済み'],['11月6日','白樺ソフト','カジュアル面談','32分08秒','文字起こし済み'],['11月4日','北庭スタジオ','エンジニア面談','58分31秒','要約あり'],['11月2日','青葉テクノロジー','一次面接','41分05秒','文字起こし済み']];
 for(const item of items){const r=R(list,'Recording / '+item[1],992,24);r.paddingTop=r.paddingBottom=18;T(r,item[0],'number','secondary',88);const c=C(r,'Recording title',460,3);T(c,item[1],'heading');label(c,item[2]);T(r,item[3],'number','secondary',100);T(r,item[4],'small','secondary',140);B(r,'開く','quiet','transcript');line(list,992);links.push({id:r.id,to:'transcript'});}
 foot(body,'録音と文字起こしは、このMacに保存されます。','4件の録音');
}
// Preparation, with input grouped by speaker
{
 const {body}=screen('prepare','02 / 録音の準備',1,0,true);heading(body,'録音の準備','今日 15:00–16:00  /  仕事のカレンダー');
 const form=C(body,'Preparation form',992,20);const fields=R(form,'Names',992,24);field(fields,'会社名（必須）','山吹デザイン',null,484);field(fields,'タイトル（任意）','二次面接',null,484);
 const input=C(form,'Audio sources',992,16);const h=R(input,'Input heading',992,12);T(h,'録音する音声','heading');S(h);label(h,'自分と相手を分けて保存');
 const sources=R(input,'Sources',992,24);sources.counterAxisAlignItems='MIN';
 const me=C(sources,'My microphone',484,12,'paper',20);me.cornerRadius=8;T(me,'自分','heading');const mr=R(me,'Mic selection',444,8);T(mr,'USBマイク / INPUT 1','label');S(mr);B(mr,'変更','quiet','settings-recording');meter(me,'マイクの入力',-22,-16,444);label(me,'話してメーターが動くことを確認できます。');
 const them=C(sources,'Remote application',484,12,'paper',20);them.cornerRadius=8;T(them,'相手','heading');field(them,'音声を録音するアプリ','Google Chrome  ▾',null,444);T(them,'このアプリの音だけを録音します。\n別のアプリや通知の音は含みません。','small','secondary',444);label(them,'相手の入力確認は録音開始後に行います。');
 const ready=R(form,'Permission readiness',992,12);state(ready,'マイクの許可済み');T(ready,'・','small','secondary');state(ready,'画面収録の許可済み');
 const act=R(body,'Start recording actions',992,16);T(act,'文字起こしは録音を止めた後に始まります。','small','secondary');S(act);B(act,'キャンセル','secondary','library');B(act,'録音を開始','primary','recording');
}
// Live capture. No fake transcript or pause affordance.
{
 const {body}=screen('recording','03 / 録音中',2,0,true);heading(body,'山吹デザイン','二次面接  /  2026年11月10日');
 const status=R(body,'Recording controls',992,24);state(status,'録音中','danger');T(status,'00:12:38','time');S(status);B(status,'録音を停止','danger','processing');
 const sounds=C(body,'Live audio',992,16);meter(sounds,'自分  ·  USBマイク',-18,-12,992);meter(sounds,'相手  ·  Google Chrome',-10,-6,992);
 const st=R(body,'Audio health',992,16);state(st,'両方の音声を受信しています');
 line(body,992);
 T(body,'このまま、会話に集中できます。','heading');T(body,'ウィンドウを閉じても録音は続きます。\nメニューバーからも録音を止められます。','body','secondary',800);
 foot(body,'音声はこのMacに保存されます。','文字起こしは録音終了後');
}
// Post recording state
{
 const {body}=screen('processing','04 / 保存後・文字起こし中',0,1,true);heading(body,'山吹デザイン','二次面接  /  2026年11月10日 15:00  /  47分12秒');
 banner(body,'録音を保存しました','自分と相手の音声は、このMacに保存されています。','success');
 const p=C(body,'Transcription progress',992,24,'paper',32);p.cornerRadius=8;const row=R(p,'Progress heading',928,12);T(row,'文字起こし中','heading');S(row);T(row,'42%','heading');
 const rail=R(p,'Progress track',928,0,'selected');size(rail,928,6);const fill=track(figma.createRectangle());fill.resize(390,6);fill.fills=[paint('ink')];rail.appendChild(fill);
 T(p,'このMacで音声を文字にしています。\n別の録音を読んだり、ウィンドウを閉じたりしても処理は続きます。','body','secondary',870);
 const a=R(body,'Saved audio',992,16);T(a,'音声ファイルを確認する','label');S(a);B(a,'Finderで表示','secondary','recording-info');
 V(body,104);const done=R(body,'Return to library',992,12);B(done,'録音一覧に戻る','secondary','library');
}
// Transcript
{
 const {body}=screen('transcript','05 / 文字起こし',1,1,true);heading(body,'山吹デザイン','一次面接  /  2026年11月9日 14:00  /  47分12秒');
 const actions=R(body,'Document actions',992,12);state(actions,'文字起こし済み');S(actions);B(actions,'Markdownをコピー','secondary','copied');B(actions,'ノートを書き出す','primary','export');tabs(body,'文字起こし');
 const doc=C(body,'Transcript document',920,24);const lines=[['00:00','相手','本日はありがとうございます。まず、これまで取り組まれたお仕事について教えていただけますか。'],['00:12','自分','こちらこそ、ありがとうございます。主にウェブサービスの開発を担当してきました。最近は、利用者の声を聞きながら、設計から運用まで一貫して関わっています。'],['00:46','相手','そのなかで、特に大切にしていることは何でしょうか。'],['00:54','自分','困っていることを、できるだけ具体的に理解することです。まず小さく試して、実際に使ってもらいながら改善するようにしています。']];
 for(const [time,speaker,words]of lines){const r=R(doc,'Utterance / '+time,920,24);r.counterAxisAlignItems='MIN';const meta=C(r,'Speaker & timestamp',88,4);T(meta,time,'number','secondary');T(meta,speaker,'label');T(r,words,'body','ink',780);}
}
// Summary
{
 const {body}=screen('summary','06 / 要約',2,1,true);heading(body,'山吹デザイン','一次面接  /  2026年11月9日 14:00  /  47分12秒');const actions=R(body,'Document actions',992,12);state(actions,'要約を作成済み');S(actions);B(actions,'ノートを書き出す','primary','export');tabs(body,'要約');
 const doc=C(body,'Summary document',888,24);T(doc,'面接で話したこと','heading');T(doc,'ウェブサービスの設計・開発・運用に関わってきた経験と、利用者の声を確かめながら改善する進め方について話した。','body','ink',840);
 T(doc,'主な質問','heading');T(doc,'・これまで担当した仕事と、その役割\n・開発を進めるうえで大切にしていること\n・小さく試し、利用者の反応から改善した経験','body','ink',840);
 T(doc,'次に確認したいこと','heading');T(doc,'・入社後に期待される役割と、最初に取り組む課題\n・チームで設計や優先順位を決める方法','body','ink',840);
 line(body,992);const r=R(body,'Summary provenance',992,12);label(r,'要約は自動生成された内容です。必要に応じて文字起こしと照合してください。');S(r);B(r,'作り直す','secondary','summary-consent');
}
return result();

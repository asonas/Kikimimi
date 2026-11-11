// Executed with Figma Plugin API through use_figma. No application code is changed.
const page = await figma.getNodeByIdAsync('0:1');
await figma.setCurrentPageAsync(page);
page.name = 'Kikimimi — 画面設計';
if (page.children.some(n => n.name === 'Kikimimi / Foundations')) throw new Error('Foundations already exist');
const createdNodeIds = [];
const take = n => { createdNodeIds.push(n.id); return n; };
function rgb(h) { return {r:parseInt(h.slice(1,3),16)/255,g:parseInt(h.slice(3,5),16)/255,b:parseInt(h.slice(5,7),16)/255}; }
async function createVariableCollection(name, modeNames) {
  const collection = figma.variables.createVariableCollection(name);
  const modeIds = {};
  collection.renameMode(collection.defaultModeId, modeNames[0]);
  modeIds[modeNames[0]] = collection.defaultModeId;
  return {collection,modeIds};
}
const {collection,modeIds} = await createVariableCollection('Kikimimi / Color & Space',['Light']);
const palette = {paper:'#f5f5f4',surface:'#ffffff',ink:'#1c1917',secondary:'#57534e',line:'#d6d3d1',control:'#78716c',selected:'#e7e5e4',success:'#276344',successBg:'#edf5ef',warning:'#854d0e',warningBg:'#fff7e6',danger:'#a62e25',dangerBg:'#fbeeea',focus:'#ffd43b',meterOff:'#454b46',meterGreen:'#69c38b',meterAmber:'#efbe60',meterRed:'#f18e83'};
const vars = {};
for (const [name,hex] of Object.entries(palette)) {
  const p = figma.variables.createVariable('primitive/'+name,collection,'COLOR');
  p.scopes=[]; p.setValueForMode(modeIds.Light,rgb(hex));
  const v=figma.variables.createVariable('color/'+name,collection,'COLOR');
  v.scopes=['FRAME_FILL','SHAPE_FILL','TEXT_FILL','STROKE_COLOR'];
  v.setValueForMode(modeIds.Light,{type:'VARIABLE_ALIAS',id:p.id});
  v.setVariableCodeSyntax('WEB','var(--'+name+')');
  v.setVariableCodeSyntax('iOS','KikimimiColor.'+name); vars[name]=v;
}
for(const n of [4,8,12,16,20,24,32,40,48,64]) {
  const v=figma.variables.createVariable('space/'+n,collection,'FLOAT');v.scopes=['GAP'];v.setValueForMode(modeIds.Light,n);v.setVariableCodeSyntax('WEB','var(--space-'+n+')');vars['space'+n]=v;
}
const radius=await figma.variables.importVariableByKeyAsync('9e82491aff6fe809fe71856da5612db502221455');
const fontNames=[{family:'Noto Sans JP',style:'Regular'},{family:'Noto Sans JP',style:'Medium'},{family:'Noto Sans JP',style:'Bold'}];
await Promise.all(fontNames.map(f=>figma.loadFontAsync(f)));
const styles={};
for(const [name,size,line,style,family] of [['title',28,40,'Bold','Noto Sans JP'],['heading',18,28,'Bold','Noto Sans JP'],['body',16,28,'Regular','Noto Sans JP'],['label',14,22,'Medium','Noto Sans JP'],['small',13,20,'Regular','Noto Sans JP'],['time',48,56,'Regular','Noto Sans JP'],['number',14,22,'Medium','Noto Sans JP']]) {
  const s=figma.createTextStyle();s.name='Kikimimi/'+name;s.fontName={family,style};s.fontSize=size;s.lineHeight={unit:'PIXELS',value:line}; styles[name]=s;
}
function paint(name){return figma.variables.setBoundVariableForPaint({type:'SOLID',color:rgb(palette[name])},'color',vars[name]);}
function text(str,role='body',color='ink',width){const n=take(figma.createText());n.textStyleId=styles[role].id;n.characters=str;n.fills=[paint(color)];if(width){n.textAutoResize='HEIGHT';n.resize(width,n.height);}return n;}
function box(name,dir,w,gap=16,bg){const n=take(figma.createAutoLayout(dir));n.name=name;n.fills=bg?[paint(bg)]:[];n.itemSpacing=gap;n.resize(w,100);n.layoutSizingHorizontal='FIXED';n.layoutSizingVertical='HUG';return n;}
const root=box('Kikimimi / Foundations','VERTICAL',1040,24,'surface');root.x=4200;root.y=120;root.paddingTop=root.paddingBottom=root.paddingLeft=root.paddingRight=40;
root.appendChild(text('Kikimimi','title'));root.appendChild(text('会話を残して、あとで読み返す。','heading'));root.appendChild(text('生成りと墨色を土台に、余白・文字・操作の位置で整理する。色は状態を伝えるために使う。','body','secondary',940));
const swatches=box('Color roles','HORIZONTAL',960,12);
for(const name of ['paper','ink','secondary','success','warning','danger']){const b=box(name,'VERTICAL',144,8);const s=take(figma.createRectangle());s.resize(144,64);s.fills=[paint(name)];b.appendChild(s);b.appendChild(text(name,'label'));b.appendChild(text(palette[name],'small','secondary'));swatches.appendChild(b);}root.appendChild(swatches);
root.appendChild(text('本文は16 / 28。操作は40pt以上。説明は現在値の近くへ。','body'));
root.appendChild(text('録音中・保存中・文字起こし中を混同しない。話者は「自分」「相手」。','body'));
const meter=take(figma.createComponent());meter.name='Kikimimi / Audio meter';meter.layoutMode='VERTICAL';meter.primaryAxisSizingMode='AUTO';meter.counterAxisSizingMode='FIXED';meter.resize(760,100);meter.itemSpacing=8;meter.paddingTop=meter.paddingBottom=20;meter.paddingLeft=meter.paddingRight=24;meter.fills=[paint('ink')];meter.cornerRadius=8;
const mh=box('Channel label','HORIZONTAL',712,12);meter.appendChild(mh);const ml=text('自分','label','surface');mh.appendChild(ml);const lp=meter.addComponentProperty('Label','TEXT','自分');ml.componentPropertyReferences={characters:lp};const spacer=box('Flexible space','HORIZONTAL',10,0);mh.appendChild(spacer);spacer.layoutSizingHorizontal='FILL';const value=text('−18 dBFS','number','surface');mh.appendChild(value);const vp=meter.addComponentProperty('Value','TEXT','−18 dBFS');value.componentPropertyReferences={characters:vp};
const rail=box('Meter rail / −60…0 dBFS','HORIZONTAL',712,3);rail.resize(712,18);rail.layoutSizingVertical='FIXED';
for(let i=0;i<30;i++){const s=take(figma.createRectangle());s.name='Segment '+i;s.resize((712-87)/30,18);s.fills=[paint(i<21?'meterGreen':'meterOff')];rail.appendChild(s);}meter.appendChild(rail);
const ticks=box('dBFS scale','HORIZONTAL',712,0);ticks.primaryAxisAlignItems='SPACE_BETWEEN';for(const s of ['−60','−48','−36','−24','−12','0']) ticks.appendChild(text(s,'small','surface'));meter.appendChild(ticks);
spacer.resize(1,1);spacer.layoutSizingVertical='FIXED';spacer.layoutSizingHorizontal='FILL';
for(const row of [mh,rail,ticks])row.layoutSizingHorizontal='FILL';
for(const segment of rail.children)segment.layoutSizingHorizontal='FILL';
root.appendChild(meter);
const note=text('試作の値：50ms集計 / ピーク保持800ms / 下降24dB毎秒。実測のsample peakを使い、無音では動かさない。','small','secondary',950);root.appendChild(note);
const icon=figma.createImage(figma.base64Decode(ICON_BASE64));
const logo=take(figma.createRectangle());logo.name='Kikimimi / Ear asset';logo.resize(64,64);logo.fills=[{type:'IMAGE',imageHash:icon.hash,scaleMode:'FIT'}];root.appendChild(logo);
return {createdNodeIds,mutatedNodeIds:[page.id],pageId:page.id,foundationId:root.id,meterId:meter.id,iconHash:icon.hash,collectionId:collection.id,variableIds:Object.fromEntries(Object.entries(vars).map(([k,v])=>[k,v.id])),textStyleIds:Object.fromEntries(Object.entries(styles).map(([k,v])=>[k,v.id])),radiusId:radius.id,propertyNames:{meterLabel:lp,meterValue:vp}};

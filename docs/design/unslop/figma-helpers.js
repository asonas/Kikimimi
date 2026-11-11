const page=await figma.getNodeByIdAsync('0:1');await figma.setCurrentPageAsync(page);
const made=[],mutated=[],links=[],screens={};
const track=n=>{made.push(n.id);return n;};
const vars=Object.fromEntries(await Promise.all(Object.entries(FOUNDATION.variableIds).map(async([k,id])=>[k,await figma.variables.getVariableByIdAsync(id)])));
const radius=await figma.variables.getVariableByIdAsync(FOUNDATION.radiusId);
const buttonSet=await figma.importComponentSetByKeyAsync('cc8b558dc7d9684011b6b99ce8e6509399bc836b');
const primary=buttonSet.children.find(n=>n.name==='Variant=Primary, State=Default, Size=Medium');
const secondary=buttonSet.children.find(n=>n.name==='Variant=Neutral, State=Default, Size=Medium');
const subtle=buttonSet.children.find(n=>n.name==='Variant=Subtle, State=Default, Size=Medium');
const meterComponent=await figma.getNodeByIdAsync(FOUNDATION.meterId);
const gear=await figma.importComponentByKeyAsync('3d621f5bdce97489b5aa074105e7944beb8431dd');
const backIcon=await figma.importComponentByKeyAsync('b303aa0d865f8b9626a4956bc556c975bd2d91ea');
const fonts=new Map();
for(const n of [primary,secondary,subtle,meterComponent]) for(const t of n.findAllWithCriteria({types:['TEXT']}))for(const s of t.getStyledTextSegments(['fontName']))fonts.set(JSON.stringify(s.fontName),s.fontName);
for(const f of [{family:'Noto Sans JP',style:'Regular'},{family:'Noto Sans JP',style:'Medium'},{family:'Noto Sans JP',style:'Bold'},{family:'SF Pro',style:'Regular'},{family:'SF Pro',style:'Medium'}])fonts.set(JSON.stringify(f),f);
await Promise.all([...fonts.values()].map(f=>figma.loadFontAsync(f)));
const palette={paper:'#f5f5f4',surface:'#ffffff',ink:'#1c1917',secondary:'#57534e',line:'#d6d3d1',control:'#78716c',selected:'#e7e5e4',success:'#276344',successBg:'#edf5ef',warning:'#854d0e',warningBg:'#fff7e6',danger:'#a62e25',dangerBg:'#fbeeea',focus:'#ffd43b',meterOff:'#454b46',meterGreen:'#69c38b',meterAmber:'#efbe60',meterRed:'#f18e83'};
function paint(k){const h=palette[k];return figma.variables.setBoundVariableForPaint({type:'SOLID',color:{r:parseInt(h.slice(1,3),16)/255,g:parseInt(h.slice(3,5),16)/255,b:parseInt(h.slice(5,7),16)/255}},'color',vars[k]);}
function C(parent,name,w,gap=16,bg=null,padding=0,dir='VERTICAL'){
 const n=track(figma.createAutoLayout(dir));n.name=name;n.fills=bg?[paint(bg)]:[];n.itemSpacing=gap;n.resize(w,1);n.layoutSizingHorizontal='FIXED';n.layoutSizingVertical='HUG';if(vars['space'+gap])n.setBoundVariable('itemSpacing',vars['space'+gap]);
 for(const prop of ['paddingTop','paddingBottom','paddingLeft','paddingRight']){n[prop]=padding;if(vars['space'+padding])n.setBoundVariable(prop,vars['space'+padding]);}if(parent)parent.appendChild(n);return n;
}
function R(parent,name,w,gap=12,bg=null,pad=0){const n=C(parent,name,w,gap,bg,pad,'HORIZONTAL');n.counterAxisAlignItems='CENTER';return n;}
function T(parent,str,role='body',color='ink',width){const n=track(figma.createText());n.name=str.slice(0,42);n.textStyleId=FOUNDATION.textStyleIds[role];n.characters=str;n.fills=[paint(color)];if(width){n.textAutoResize='HEIGHT';n.resize(width,n.height);}if(parent)parent.appendChild(n);return n;}
function size(n,w,h){n.resize(w,h);n.layoutSizingHorizontal='FIXED';n.layoutSizingVertical='FIXED';return n;}
function S(parent){const s=C(parent,'Flexible space',1,0);size(s,1,1);s.layoutSizingHorizontal='FILL';return s;}
function V(parent,h=16){const n=C(parent,'Space',1,0);size(n,1,h);return n;}
function line(parent,w){const n=track(figma.createRectangle());n.name='Divider';n.resize(w,1);n.fills=[paint('line')];parent.appendChild(n);return n;}
function B(parent,label,kind='secondary',dest){const base=kind==='primary'||kind==='danger'?primary:kind==='quiet'?subtle:secondary;const n=track(base.createInstance());
 n.name='Button / '+label;n.setProperties({'Label#2:0':label,'Has Icon Start#4:128':false,'Has Icon End#4:64':false});n.fills=kind==='quiet'?[]:[paint(kind==='primary'?'ink':kind==='danger'?'danger':'surface')];n.strokes=kind==='secondary'?[paint('control')]:[];n.strokeWeight=1;n.effects=[];n.setBoundVariable('cornerRadius',radius);n.paddingTop=n.paddingBottom=9;n.paddingLeft=n.paddingRight=16;
 for(const t of n.findAllWithCriteria({types:['TEXT']})){t.textStyleId=FOUNDATION.textStyleIds.label;t.fills=[paint(kind==='primary'||kind==='danger'?'surface':'ink')];}n.resize(Math.max(80,label.length*14+32),40);parent.appendChild(n);if(dest)links.push({id:n.id,to:dest});return n;}
function label(parent,str,color='secondary'){return T(parent,str,'small',color);}
function state(parent,str,tone='success'){const r=R(parent,'State / '+str,Math.max(90,str.length*14+18),8);const d=track(figma.createEllipse());d.resize(7,7);d.fills=[paint(tone)];r.appendChild(d);T(r,str,'label',tone);return r;}
function banner(parent,title,description,tone='warning',w=992,action,dest){const b=C(parent,'Notice / '+title,w,4,tone+'Bg',16);b.cornerRadius=8;const h=R(b,'Notice heading',w-32,12);T(h,title,'label',tone);if(action){S(h);B(h,action,'secondary',dest);}if(description)T(b,description,'small','secondary',w-32);return b;}
function field(parent,name,value,help,w=744){const g=C(parent,'Field / '+name,w,8);T(g,name,'label');const r=R(g,'Value / '+name,w,8,'surface',12);r.strokes=[paint('control')];r.strokeWeight=1;r.cornerRadius=8;T(r,value,'body','ink',w-52);if(help)T(g,help,'small','secondary',w);return g;}
function meter(parent,name,value=-18,peak=-12,w=760){const n=track(meterComponent.createInstance());n.name='Meter / '+name;const texts=n.findAllWithCriteria({types:['TEXT']});texts[0].characters=name;texts[1].characters=value<=-60?'−∞ dBFS':'−'+Math.abs(value)+' dBFS';n.resize(w,n.height);parent.appendChild(n);
 const rail=n.findOne(n=>n.name==='Meter rail / −60…0 dBFS');const barW=w-48;rail.resize(barW,18);const segW=(barW-87)/30;for(let i=0;i<rail.children.length;i++){const seg=rail.children[i];seg.resize(segW,18);const db=-60+(i+1)*2;seg.fills=[paint(db<=value?(db>=-3?'meterRed':db>=-12?'meterAmber':'meterGreen'):'meterOff')];if(i===Math.min(29,Math.round((peak+60)/2)-1)){seg.strokes=[paint('surface')];seg.strokeWeight=1.5;}}
 for(const row of n.children.filter(n=>n.type==='FRAME'))row.resize(barW,row.height);return n;}
function chrome(root,back=false){const top=R(root,'Window toolbar',1120,12,'paper',20);size(top,1120,64);const lights=R(top,'Window controls',68,8);for(const c of ['#d66b61','#d7af55','#76a56e']){const n=track(figma.createEllipse());n.resize(12,12);n.fills=[{type:'SOLID',color:{r:parseInt(c.slice(1,3),16)/255,g:parseInt(c.slice(3,5),16)/255,b:parseInt(c.slice(5,7),16)/255}}];lights.appendChild(n);}if(back){const b=B(top,'録音一覧','quiet','library');const i=track(backIcon.createInstance());top.insertChild(1,i);}else {const logo=track(figma.createRectangle());logo.resize(32,32);logo.fills=[{type:'IMAGE',imageHash:FOUNDATION.iconHash,scaleMode:'FIT'}];top.appendChild(logo);T(top,'Kikimimi','heading');}S(top);const s=R(top,'Settings action',108,6);const icon=track(gear.createInstance());s.appendChild(icon);B(s,'設定','quiet','settings-recording');return top;}
function screen(key,title,col,row,back=false){if(page.children.some(n=>n.name===title))throw new Error('Screen already exists: '+title);const n=C(null,title,1120,0,'surface');n.x=160+col*1240;n.y=160+row*960;size(n,1120,840);n.cornerRadius=14;n.clipsContent=true;n.strokes=[paint('line')];n.strokeWeight=1;screens[key]=n.id;chrome(n,back);const body=C(n,'Content',1120,24,'surface');body.paddingTop=32;body.paddingBottom=32;body.paddingLeft=64;body.paddingRight=64;body.layoutSizingVertical='FILL';return {root:n,body};}
function heading(parent,title,sub,action,dest){const r=R(parent,'Page heading',992,16);const left=C(r,'Title',700,4);T(left,title,'title');if(sub)T(left,sub,'small','secondary');S(r);if(action)B(r,action,'primary',dest);}
function foot(parent,left,right){const r=R(parent,'Footer',992,12);T(r,left,'small','secondary');S(r);if(right)T(r,right,'small','secondary');}
function tabs(parent,selected){const r=R(parent,'Document tabs',992,24);for(const s of ['文字起こし','要約']){const b=B(r,s,selected===s?'primary':'quiet',s==='要約'?'summary':'transcript');}S(r);B(r,'録音の情報','quiet','recording-info');line(parent,992);}
function result(){return {createdNodeIds:made,mutatedNodeIds:mutated,screens,links,frames:Object.entries(screens).map(([name,id])=>{const n=page.children.find(n=>n.id===id);return {name,id,width:n.width,height:n.height,children:n.children.length};})};}

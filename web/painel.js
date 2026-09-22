/* ============================================================================
   Painel TV Faturamento & Logística — módulo comum às páginas de detalhe.
   Autenticação, leitura do cache, tabela ordenável/paginada e exportação Excel.
   As 4 telas só declaram colunas, KPIs e painéis laterais.
   ========================================================================== */
"use strict";

const SUPABASE_URL = 'https://dzxekwdpktvishdsmiep.supabase.co';
const SUPABASE_KEY = 'sb_publishable_i59McYEiS6vZq6lfLUqB2w_NRVQ6DWN';
const SB = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const $  = id => document.getElementById(id);
const el = (t, c, h) => { const e = document.createElement(t); if(c) e.className = c; if(h!=null) e.innerHTML = h; return e; };
const MESES = ['Janeiro','Fevereiro','Março','Abril','Maio','Junho','Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'];

/* ---------------------------------------------------------------- formatos */
const F = {
  int:   v => (+v||0).toLocaleString('pt-BR'),
  moeda: v => 'R$ ' + (+v||0).toLocaleString('pt-BR',{minimumFractionDigits:2,maximumFractionDigits:2}),
  curto: v => { v = +v||0;
    return v >= 1e6 ? 'R$ ' + (v/1e6).toLocaleString('pt-BR',{minimumFractionDigits:1,maximumFractionDigits:1}) + ' mi'
         : v >= 1e3 ? 'R$ ' + (v/1e3).toLocaleString('pt-BR',{maximumFractionDigits:0}) + ' mil'
         : 'R$ ' + v.toLocaleString('pt-BR',{maximumFractionDigits:0}); },
  pct:   v => (+v||0).toLocaleString('pt-BR',{minimumFractionDigits:1,maximumFractionDigits:1}) + '%',
  data:  v => v ? v.slice(8,10)+'/'+v.slice(5,7)+'/'+v.slice(0,4) : '—',
  dia:   v => v ? v.slice(8,10)+'/'+v.slice(5,7) : '—',
};

/* ---------------------------------------------------------------- dados */
/* ⚠️ `ordem` TEM de ser a chave primária COMPLETA. A leitura é paginada por Range, e com
   chave de ordenação não única o Postgres pode devolver a mesma linha em duas páginas
   (e pular outra) — o total sai errado sem erro nenhum. `nf` se repete em dash_venda_linha
   (uma linha por linha de produto) e `nf_dev` em dash_devolucao (o número é do cliente).
   Achado em 22/09/2026: uma NF apareceu com AUDIO duas vezes, R$ 163,65 a mais. */
async function tudo(tabela, campos, ordem){
  const out = []; let de = 0;
  for(;;){
    const { data, error } = await SB.from(tabela).select(campos).order(ordem).range(de, de+999);
    if(error) throw error;
    out.push(...data);
    if(data.length < 1000) break;
    de += 1000;
  }
  return out;
}

const CACHE = {};
async function carregarCache(){
  if(CACHE.nfs) return CACHE;
  const [nfs, devs, log] = await Promise.all([
    tudo('dash_nf_saida','*','filial,nf,serie'),
    tudo('dash_devolucao','*','filial,nf_dev,serie_dev,cliente_cod,cliente_loja'),
    SB.from('dash_refresh_log').select('finished_at,ok').eq('ok',true).order('finished_at',{ascending:false}).limit(1)
  ]);
  CACHE.nfs = nfs; CACHE.devs = devs;
  CACHE.atualizado = log.data && log.data[0] ? new Date(log.data[0].finished_at) : null;
  return CACHE;
}

/* dash_venda_linha tem grão NF x LINHA DE PRODUTO — 424 das 1.876 notas têm mais de uma
   linha, então somar por NF aqui DUPLICA nota. Carrega só quando a tela pede. */
async function carregarVendaLinha(){
  if(!CACHE.vls) CACHE.vls = await tudo('dash_venda_linha','*','filial,nf,serie,linha');
  return CACHE.vls;
}

function marcarAtualizacao(){
  const e = $('atualizado'); if(!e) return;
  e.textContent = CACHE.atualizado
    ? CACHE.atualizado.toLocaleString('pt-BR',{day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit'})
    : '—';
}

/* ================================================================
   SELEÇÃO CRUZADA — clicar em qualquer elemento filtra a tela toda.
   SEL guarda o que está selecionado; cada página informa o MAPA
   (chave da seleção -> campo do registro) e a função que redesenha.
   ================================================================ */
const SEL = {};      // chave -> valor que FILTRA (o código do dado)
const SEL_ROT = {};  // chave -> rótulo que APARECE no chip (texto amigável)
let _mapaSel = {}, _redesenha = () => {};

function configurarSelecao(mapa, redesenha){ _mapaSel = mapa; _redesenha = redesenha; }

/* `valor` é o que existe no dado (ex.: '>15'); `rotulo` é o texto da tela
   (ex.: 'acima de 15 dias'). Confundir os dois quebrava o filtro — foi o bug
   das faixas de dias, reportado pelo Silvio em 21/09. */
function selAlterna(chave, valor, rotulo){
  if(valor == null || valor === '') return;
  if(SEL[chave] === valor){ delete SEL[chave]; delete SEL_ROT[chave]; }
  else { SEL[chave] = valor; SEL_ROT[chave] = rotulo || valor; }
  _redesenha();
}
function selLimpar(chave){
  if(chave){ delete SEL[chave]; delete SEL_ROT[chave]; }
  else Object.keys(SEL).forEach(k => { delete SEL[k]; delete SEL_ROT[k]; });
  _redesenha();
}

/* aplica todas as seleções ativas a uma lista, menos as chaves em `exceto`
   (usado para o painel da própria dimensão não se auto-filtrar até sobrar 1 item).
   `exceto` aceita uma chave ou um array — a matriz região x linha precisa poupar as duas. */
function filtraSel(lista, exceto){
  const fora = Array.isArray(exceto) ? exceto : (exceto ? [exceto] : []);
  const chaves = Object.keys(SEL).filter(k => !fora.includes(k) && _mapaSel[k]);
  if(!chaves.length) return lista;
  return lista.filter(r => chaves.every(k => {
    const campo = _mapaSel[k];
    const v = typeof campo === 'function' ? campo(r) : r[campo];
    return (v == null ? '—' : String(v)) === SEL[k];
  }));
}

const ROTULO_SEL = {cliente:'Cliente', uf:'UF', status:'Status', faixa:'Faixa',
  transportadora:'Transportadora', motivo:'Motivo', origem:'Origem da NF', fonte:'Fonte da entrega',
  regiao:'Região', linha:'Linha'};

function pintarChips(){
  const alvo = $('chipsSel'); if(!alvo) return;
  const ativos = Object.entries(SEL);
  alvo.innerHTML = ativos.length
    ? `<span class="rot">Filtrando por:</span>` + ativos.map(([k,v]) =>
        `<button class="chip" data-k="${k}">${ROTULO_SEL[k]||k}: <b>${SEL_ROT[k]||v}</b> <span>✕</span></button>`).join('')
      + `<button class="chip lim" data-k="">Limpar tudo</button>`
    : '';
  alvo.style.display = ativos.length ? 'flex' : 'none';
  alvo.querySelectorAll('.chip').forEach(b => b.onclick = () => selLimpar(b.dataset.k || null));
}

/* ---------------------------------------------------------------- KPIs */
function kpis(destino, lista){
  $(destino).innerHTML = lista.map(k =>
    `<div class="kpi ${k.alerta?'al':''}"><div class="t">${k.titulo}</div>`+
    `<div class="v">${k.valor}</div><div class="n">${k.nota||''}</div></div>`).join('');
}

/* ---------------------------------------------------------------- tabela */
function Tabela(cfg){
  // cfg: { alvo, colunas:[{k,t,fmt,cls,esq,html}], linhas, porPagina, ordem, desc }
  let ordem = cfg.ordem, desc = cfg.desc !== false, pagina = 0;
  const pp = cfg.porPagina || 50;
  const raiz = $(cfg.alvo);

  function ordenar(l){
    if(!ordem) return l;
    return [...l].sort((a,b) => {
      const x = a[ordem], y = b[ordem];
      const nx = (x===null||x===undefined||x==='') ? -Infinity : (isNaN(+x) ? String(x) : +x);
      const ny = (y===null||y===undefined||y==='') ? -Infinity : (isNaN(+y) ? String(y) : +y);
      const r = nx < ny ? -1 : nx > ny ? 1 : 0;
      return desc ? -r : r;
    });
  }
  function pintar(){
    const ord = ordenar(cfg.linhas);
    const tot = ord.length, paginas = Math.max(1, Math.ceil(tot/pp));
    if(pagina >= paginas) pagina = paginas-1;
    const fatia = ord.slice(pagina*pp, pagina*pp+pp);
    raiz.innerHTML =
      `<div class="rolar"><table class="tbl"><thead><tr>` +
        cfg.colunas.map(c =>
          `<th class="${c.esq?'esq':''} ${ordem===c.k?'ord '+(desc?'':'asc'):''}" data-k="${c.k}">${c.t}</th>`).join('') +
      `</tr></thead><tbody>` +
        (fatia.length ? fatia.map((r,ir) => `<tr ${cfg.aoClicar?`class="clicavel" data-r="${ir}" title="Clique para filtrar a tela"`:''}>` + cfg.colunas.map(c => {
            const v = c.html ? c.html(r) : (c.fmt ? c.fmt(r[c.k]) : (r[c.k] ?? '—'));
            return `<td class="${c.esq?'esq':''} ${c.cls||''}">${v}</td>`;
          }).join('') + '</tr>').join('')
         : `<tr><td colspan="${cfg.colunas.length}"><div class="vazio">Sem dados no período.</div></td></tr>`) +
      `</tbody></table></div>` +
      `<div class="pag"><span>${F.int(tot)} ${tot===1?'registro':'registros'} · página ${pagina+1} de ${paginas}</span>` +
      `<span><button ${pagina===0?'disabled':''} data-p="ant">Anterior</button>` +
      `<button ${pagina>=paginas-1?'disabled':''} data-p="prox">Próxima</button></span></div>`;
    if(cfg.aoClicar) raiz.querySelectorAll('tbody tr[data-r]').forEach(tr =>
      tr.onclick = () => cfg.aoClicar(fatia[+tr.dataset.r]));
    raiz.querySelectorAll('th').forEach(th => th.onclick = () => {
      const k = th.dataset.k;
      if(ordem === k) desc = !desc; else { ordem = k; desc = true; }
      pagina = 0; pintar();
    });
    raiz.querySelectorAll('.pag button').forEach(b => b.onclick = () => {
      pagina += (b.dataset.p === 'prox' ? 1 : -1); pintar();
      raiz.querySelector('.rolar').scrollTop = 0;
    });
  }
  this.dados = l => { cfg.linhas = l; pagina = 0; pintar(); };
  this.atual = () => ordenar(cfg.linhas);
  pintar();
}

/* ---------------------------------------------------------------- painel lateral de barras */
function barras(destino, itens, cor, chaveSel){
  const max = Math.max(1, ...itens.map(i => i.v));
  const alvo = $(destino);
  alvo.innerHTML = itens.length ? itens.map((i,idx) => {
    const sel = chaveSel && SEL[chaveSel] === (i.valor !== undefined ? i.valor : i.nome);
    return `<div class="it ${chaveSel?'clicavel':''} ${sel?'sel':''}" data-i="${idx}" `+
      `${chaveSel?`title="Clique para filtrar a tela por ${i.nome}"`:''}>`+
      `<div class="tp"><span class="nm">${i.nome}</span><b>${i.rot}</b></div>`+
      `<div class="br ${cor||''}" style="width:${Math.max(3, i.v/max*100)}%"></div></div>`;
  }).join('') : '<div class="vazio" style="padding:18px">Sem dados.</div>';
  if(chaveSel) alvo.querySelectorAll('.it').forEach(e => {
    const i = itens[+e.dataset.i];
    e.onclick = () => selAlterna(chaveSel, i.valor !== undefined ? i.valor : i.nome, i.nome);
  });
}

/* ---------------------------------------------------------------- matriz cruzada
   Grade linhas x colunas com heatmap e total nas duas bordas. Cada célula, cada
   cabeçalho de linha e cada cabeçalho de coluna filtram a tela (filtro cruzado, §12).
   `fmt` formata o valor; `chaveL`/`chaveC` são as dimensões que o clique seleciona. */
function matriz(destino, dados, opc){
  const {linhas, colunas, fmt, chaveL, chaveC} = opc;
  const alvo = $(destino); if(!alvo) return;
  if(!linhas.length || !colunas.length){
    alvo.innerHTML = '<div class="vazio">Sem dados.</div>'; return;
  }
  const val = (l,c) => (dados[l] && dados[l][c]) || 0;
  const totL = l => colunas.reduce((s,c)=>s+val(l,c),0);
  const totC = c => linhas.reduce((s,l)=>s+val(l,c),0);
  const geral = linhas.reduce((s,l)=>s+totL(l),0);
  const pico = Math.max(1, ...linhas.flatMap(l => colunas.map(c => val(l,c))));
  const th = colunas.map(c =>
    `<th class="cab-c ${SEL[chaveC]===c?'sel':''}" data-c="${c}">${c}</th>`).join('');
  const corpo = linhas.map(l => {
    const tds = colunas.map(c => {
      const v = val(l,c);
      // intensidade no laranja da marca; teto em 0.85 para o texto continuar legível
      const op = v > 0 ? 0.08 + 0.77*Math.sqrt(v/pico) : 0;
      return `<td class="cel ${v?'clicavel':''}" data-l="${l}" data-c="${c}"
                  style="background:rgba(245,166,35,${op.toFixed(3)})"
                  title="${l} · ${c}">${v ? fmt(v) : '—'}</td>`;
    }).join('');
    return `<tr><th class="cab-l ${SEL[chaveL]===l?'sel':''}" data-l="${l}">${l}</th>${tds}`+
           `<td class="tot">${fmt(totL(l))}</td>`+
           `<td class="part">${geral ? (100*totL(l)/geral).toFixed(1).replace('.',',')+'%' : '—'}</td></tr>`;
  }).join('');
  alvo.innerHTML = `<table class="mtz"><thead><tr><th></th>${th}`+
    `<th class="tot">TOTAL</th><th class="part">%</th></tr></thead><tbody>${corpo}</tbody>`+
    `<tfoot><tr><th>TOTAL</th>${colunas.map(c=>`<td class="tot">${fmt(totC(c))}</td>`).join('')}`+
    `<td class="tot">${fmt(geral)}</td><td class="part">100%</td></tr>`+
    `<tr><th class="part">%</th>${colunas.map(c=>
      `<td class="part">${geral ? (100*totC(c)/geral).toFixed(1).replace('.',',')+'%' : '—'}</td>`).join('')}`+
    `<td class="part"></td><td class="part"></td></tr></tfoot></table>`;
  // clique: célula seleciona as DUAS dimensões; cabeçalho seleciona só a sua
  alvo.querySelectorAll('td.cel.clicavel').forEach(e => e.onclick = () => {
    SEL[chaveL] = e.dataset.l; SEL_ROT[chaveL] = e.dataset.l;
    SEL[chaveC] = e.dataset.c; SEL_ROT[chaveC] = e.dataset.c;
    _redesenha && _redesenha();
  });
  alvo.querySelectorAll('th.cab-l').forEach(e => e.onclick = () => selAlterna(chaveL, e.dataset.l));
  alvo.querySelectorAll('th.cab-c').forEach(e => e.onclick = () => selAlterna(chaveC, e.dataset.c));
}

/* ---------------------------------------------------------------- Excel (.xlsx nativo) */
const CRCT = (() => { const t = new Uint32Array(256);
  for(let n=0;n<256;n++){ let c=n; for(let k=0;k<8;k++) c = (c&1) ? (0xEDB88320^(c>>>1)) : (c>>>1); t[n]=c>>>0; } return t; })();
const crc32 = u8 => { let c = 0xFFFFFFFF; for(let i=0;i<u8.length;i++) c = CRCT[(c^u8[i])&0xFF]^(c>>>8); return (c^0xFFFFFFFF)>>>0; };
const xmlEsc = s => String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
const colLetra = n => { let s=''; while(n>0){ const r=(n-1)%26; s=String.fromCharCode(65+r)+s; n=(n-r-1)/26; } return s; };

function zipar(arqs){
  const enc = new TextEncoder(), partes = [], central = []; let off = 0;
  const u16 = v => [v&255,(v>>8)&255], u32 = v => [v&255,(v>>8)&255,(v>>16)&255,(v>>24)&255];
  for(const a of arqs){
    const nb = enc.encode(a.nome), crc = crc32(a.dados), n = a.dados.length;
    const lh = [].concat(u32(0x04034b50),u16(20),u16(0x0800),u16(0),u16(0),u16(0),u32(crc),u32(n),u32(n),u16(nb.length),u16(0));
    partes.push(new Uint8Array(lh), nb, a.dados);
    central.push([].concat(u32(0x02014b50),u16(20),u16(20),u16(0x0800),u16(0),u16(0),u16(0),u32(crc),u32(n),u32(n),
      u16(nb.length),u16(0),u16(0),u16(0),u16(0),u32(0),u32(off)), nb);
    off += lh.length + nb.length + n;
  }
  const cdIni = off, cd = [];
  for(let i=0;i<central.length;i+=2){ const h = new Uint8Array(central[i]); cd.push(h, central[i+1]); off += h.length + central[i+1].length; }
  const eocd = new Uint8Array([].concat(u32(0x06054b50),u16(0),u16(0),u16(arqs.length),u16(arqs.length),u32(off-cdIni),u32(cdIni),u16(0)));
  const todos = [...partes,...cd,eocd]; let tot = 0; todos.forEach(p => tot += p.length);
  const out = new Uint8Array(tot); let p = 0; todos.forEach(b => { out.set(b,p); p += b.length; });
  return out;
}

/* Mesmo padrão dos arquivos do app de preços: cabeçalho AMVOX, aba com o nome do relatório. */
function exportarXLSX(nomeArq, titulo, subtitulo, colunas, linhas){
  const enc = new TextEncoder(), A = s => enc.encode(s);
  const d = new Date(), p2 = n => String(n).padStart(2,'0');
  const dataBr = `${p2(d.getDate())}/${p2(d.getMonth()+1)}/${d.getFullYear()} ${p2(d.getHours())}:${p2(d.getMinutes())}`;
  const ult = colLetra(colunas.length);
  const txt = (ref,v,s) => `<c r="${ref}" t="inlineStr"${s?` s="${s}"`:''}><is><t>${xmlEsc(v)}</t></is></c>`;
  let rows = '';
  rows += `<row r="1" ht="20" customHeight="1">${txt('A1','AMVOX / REISTAR — CONTROLADORIA',3)}</row>`;
  rows += `<row r="2" ht="17" customHeight="1">${txt('A2', titulo, 4)}</row>`;
  rows += `<row r="3">${txt('A3', `${subtitulo} · gerado em ${dataBr} · ${linhas.length} registros · uso interno`, 5)}</row>`;
  rows += '<row r="4"></row>';
  rows += `<row r="5">${colunas.map((c,i)=>txt(colLetra(i+1)+'5', c.t, 6)).join('')}</row>`;
  linhas.forEach((l,i) => { const r = i+6;
    rows += `<row r="${r}">` + colunas.map((c,j) => {
      const ref = colLetra(j+1)+r, v = c.val ? c.val(l) : l[c.k];
      if(c.tipo === 'n' && v != null && v !== '') return `<c r="${ref}" s="2"><v>${Number(v).toFixed(2)}</v></c>`;
      return txt(ref, v == null ? '' : v);
    }).join('') + '</row>';
  });
  const sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'+
    '<sheetViews><sheetView workbookViewId="0"><pane ySplit="5" topLeftCell="A6" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'+
    '<cols>'+colunas.map((c,i)=>`<col min="${i+1}" max="${i+1}" width="${c.w||16}" customWidth="1"/>`).join('')+'</cols>'+
    `<sheetData>${rows}</sheetData>`+
    `<mergeCells count="3"><mergeCell ref="A1:${ult}1"/><mergeCell ref="A2:${ult}2"/><mergeCell ref="A3:${ult}3"/></mergeCells>`+
    '</worksheet>';
  const styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'+
    '<numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts>'+
    '<fonts count="6"><font><sz val="11"/><name val="Calibri"/></font>'+
    '<font><b/><sz val="11"/><name val="Calibri"/></font>'+
    '<font><b/><sz val="14"/><color rgb="FF1A1F2E"/><name val="Calibri"/></font>'+
    '<font><b/><sz val="11"/><color rgb="FFC77C00"/><name val="Calibri"/></font>'+
    '<font><sz val="9"/><color rgb="FF5B6478"/><name val="Calibri"/></font>'+
    '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font></fonts>'+
    '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'+
    '<fill><patternFill patternType="solid"><fgColor rgb="FF1A1F2E"/><bgColor indexed="64"/></patternFill></fill></fills>'+
    '<borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'+
    '<cellXfs count="7"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'+
    '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'+
    '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'+
    '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>'+
    '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/>'+
    '<xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1"/>'+
    '<xf numFmtId="0" fontId="5" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs>'+
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>';
  const ct = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'+
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'+
    '<Default Extension="xml" ContentType="application/xml"/>'+
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'+
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'+
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>';
  const rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>';
  const aba = titulo.replace(/[:\\\/?*\[\]]/g,'-').slice(0,31);
  const wb = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'+
    `<sheets><sheet name="${xmlEsc(aba)}" sheetId="1" r:id="rId1"/></sheets></workbook>`;
  const wbr = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'+
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>';
  const zip = zipar([{nome:'[Content_Types].xml',dados:A(ct)},{nome:'_rels/.rels',dados:A(rels)},
    {nome:'xl/workbook.xml',dados:A(wb)},{nome:'xl/_rels/workbook.xml.rels',dados:A(wbr)},
    {nome:'xl/styles.xml',dados:A(styles)},{nome:'xl/worksheets/sheet1.xml',dados:A(sheet)}]);
  const url = URL.createObjectURL(new Blob([zip],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'}));
  const a = document.createElement('a'); a.href = url; a.download = nomeArq;
  document.body.appendChild(a); a.click();
  setTimeout(()=>{ document.body.removeChild(a); URL.revokeObjectURL(url); }, 1500);
}
const hojeArq = () => { const d = new Date(), p = n => String(n).padStart(2,'0');
  return `${d.getFullYear()}-${p(d.getMonth()+1)}-${p(d.getDate())}`; };

/* ---------------------------------------------------------------- login */
function montarLogin(){
  document.body.insertAdjacentHTML('afterbegin', `
<div id="login">
  <div class="marca">AMVO<b>X</b></div>
  <div class="subm">Faturamento &amp; Logística · Controladoria</div>
  <div class="card">
    <div id="fLogin">
      <label for="em">E-mail</label><input id="em" type="email" autocomplete="username">
      <label for="pw">Senha</label>
      <div class="pww"><input id="pw" type="password" autocomplete="current-password"><button type="button" class="pweye" data-alvo="pw" title="Mostrar/ocultar senha">👁</button></div>
      <button class="btn" id="bEntrar">Entrar</button>
      <button class="ghost" id="bEsqueci">Esqueci / quero definir minha senha</button>
      <div class="msg" id="msg"></div>
    </div>
    <div id="fSenha" style="display:none">
      <p style="font-size:14px;color:#C9C9C5">Defina a sua senha de acesso.</p>
      <label for="np">Nova senha (mín. 8 caracteres)</label>
      <div class="pww"><input id="np" type="password" autocomplete="new-password"><button type="button" class="pweye" data-alvo="np">👁</button></div>
      <label for="np2">Repita a senha</label>
      <div class="pww"><input id="np2" type="password" autocomplete="new-password"><button type="button" class="pweye" data-alvo="np2">👁</button></div>
      <button class="btn" id="bSalvarSenha">Salvar senha e entrar</button>
      <div class="msg" id="mSenha"></div>
    </div>
  </div>
  <div class="rodape">AMVOX · Reistar — acesso restrito</div>
</div>`);
  document.querySelectorAll('#login .pweye').forEach(b => b.onclick = () => {
    const i = $(b.dataset.alvo); const m = i.type === 'password';
    i.type = m ? 'text' : 'password'; b.textContent = m ? '🙈' : '👁'; i.focus(); });
  $('bEntrar').onclick = async () => {
    const m = $('msg'); m.className = 'msg'; m.textContent = 'Entrando…';
    const { error } = await SB.auth.signInWithPassword({ email:$('em').value.trim(), password:$('pw').value.trim() });
    if(error){ m.className='msg err'; m.textContent = 'Não foi possível entrar: e-mail ou senha incorretos.'; }
    else { m.textContent=''; abrir(); }
  };
  $('pw').addEventListener('keydown', e => { if(e.key==='Enter') $('bEntrar').click(); });
  $('bEsqueci').onclick = async () => {
    const m = $('msg'), email = $('em').value.trim();
    if(!email){ m.className='msg err'; m.textContent='Digite o e-mail acima e clique de novo.'; return; }
    const { error } = await SB.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname });
    m.className = error ? 'msg err' : 'msg ok';
    m.textContent = error ? 'Não foi possível enviar: ' + error.message
      : 'Enviado! O link é de uso único e vale por pouco tempo; se não chegar, fale com a Controladoria.';
  };
  $('bSalvarSenha').onclick = async () => {
    const m = $('mSenha'), p1 = $('np').value.trim(), p2 = $('np2').value.trim();
    if(p1.length < 8){ m.className='msg err'; m.textContent='A senha precisa ter pelo menos 8 caracteres.'; return; }
    if(p1 !== p2){ m.className='msg err'; m.textContent='As senhas não conferem.'; return; }
    const { error } = await SB.auth.updateUser({ password:p1 });
    if(error){ m.className='msg err'; m.textContent='Erro: ' + error.message; return; }
    history.replaceState(null,'',location.pathname); abrir();
  };
  const ehConvite = /type=(invite|recovery|signup)/.test(location.hash);
  SB.auth.onAuthStateChange((ev, s) => {
    if(ev === 'PASSWORD_RECOVERY' || (s && ehConvite)){
      $('login').style.display='flex'; $('fLogin').style.display='none'; $('fSenha').style.display='block';
    }
  });
}

/* ---------------------------------------------------------------- arranque */
let _pagina = null;
async function abrir(){
  const { data:{ session } } = await SB.auth.getSession();
  const convite = /type=(invite|recovery|signup)/.test(location.hash);
  if(!session || convite){ $('login').style.display='flex'; return; }
  $('login').style.display='none';
  try { await carregarCache(); marcarAtualizacao(); await _pagina(); }
  catch(e){ $('erro').style.display='block'; $('erro').textContent = 'Falha ao carregar: ' + (e.message||e); }
}
function iniciarPagina(fn){
  _pagina = fn;
  document.addEventListener('DOMContentLoaded', () => { montarLogin(); abrir(); });
}

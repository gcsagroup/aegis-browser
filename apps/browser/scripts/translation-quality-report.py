#!/usr/bin/env python3
"""汇总冻结语料的逐条原始译文与辅助评分；语义结论必须单独复核。"""
import argparse, hashlib, html, json, statistics
from pathlib import Path
from sacrebleu.metrics import CHRF

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--corpus',type=Path,required=True)
parser.add_argument('--input',type=Path,action='append',required=True)
parser.add_argument('--review',type=Path)
parser.add_argument('--output',type=Path,required=True)
a=parser.parse_args()
freeze=json.loads((a.corpus/'freeze-v1.json').read_text());cases=[]
for name,digest in freeze['files'].items():
 raw=(a.corpus/name).read_bytes()
 assert hashlib.sha256(raw).hexdigest()==digest, name
 cases.extend(json.loads(raw)['cases'])
reviews=json.loads(a.review.read_text()) if a.review else {}
metric=CHRF(word_order=2)
summary={'corpusHashes':freeze['files'],'metric':'chrF++，单一合成参考译文；只作辅助，不代表准确率','runs':[]}
outputs={}
for file in a.input:
 data=json.loads(file.read_text())
 assert data.get('complete'), f'评测未完成：{file}'
 assert data['corpusHashes']==freeze['files']
 byid={row['id']:row for row in data['results']}
 assert len(byid)==len(data['results']), '重复样本'
 selected=[row for row in cases if row['id'] in byid]
 assert len(selected)==len(byid), '出现语料之外的样本'
 outputs[file.stem]=byid
 run={'name':file.stem,'path':str(file.resolve()),'count':len(byid),'errors':sum(bool(r['error']) for r in byid.values()),
      'elapsed_ms':data['elapsed_ms'],'max_rss_bytes':data['max_rss_bytes'],'groups':[]}
 for direction in ['en-zh','zh-en']:
  for category in ['negation','title','numbers','long']:
   rows=[row for row in selected if row['direction']==direction and row['category']==category]
   if not rows:continue
   paired=[row for row in rows if row.get('reference') and not byid[row['id']]['error']]
   times=[byid[row['id']]['elapsed_ms'] for row in rows]
   score=metric.corpus_score(['\n'.join(byid[r['id']]['translations']) for r in paired],
       [['\n'.join(r['reference']) for r in paired]]).score if paired else None
   run['groups'].append({'direction':direction,'category':category,'count':len(rows),'reference_count':len(paired),
       'chrfpp':score,'median_ms':statistics.median(times),'total_ms':sum(times)})
 summary['runs'].append(run)
a.output.mkdir(parents=True,exist_ok=True)
(a.output/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
esc=lambda value:html.escape(str(value))
parts=['''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>本机翻译逐条对照</title>
<style>body{font:16px/1.6 system-ui;margin:24px;max-width:1600px;background:#f7f8fa;color:#14202c}header{position:sticky;top:0;background:#f7f8fa;padding:8px}input{padding:10px;width:70%;font:inherit}article{background:white;padding:20px;margin:16px 0;border:1px solid #bbc7d1;border-radius:8px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}details{border-top:1px solid #ddd;padding:10px}summary{cursor:pointer;font-weight:600}.note{background:#fff3cd;padding:10px}</style>
<header><h1>本机翻译逐条对照</h1><p>保留模型原始输出。自动评分不是准确率；复核由本轮助手完成，不是独立人工标注。未列入错误清单也不保证译文正确。</p><input id="search" placeholder="筛选编号、方向、类别或原文"><p id="count"></p></header>''']
for row in cases:
 available=[(name,result[row['id']]) for name,result in outputs.items() if row['id'] in result]
 if not available:continue
 parts.append(f'<article data-search="{esc(row["id"]+" "+row["split"]+" "+" ".join(row["paragraphs"]))}"><h2>{esc(row["id"])} · {esc(row["split"])}</h2>')
 review=reviews.get('cases',{}).get(row['id'])
 if review:parts.append('<p class="note">复核：'+esc(review)+'</p>')
 parts.append('<details open><summary>原文</summary><pre>'+esc('\n\n'.join(row['paragraphs']))+'</pre></details>')
 if row.get('reference'):parts.append('<details><summary>参考译文（并非唯一正确写法）</summary><pre>'+esc('\n\n'.join(row['reference']))+'</pre></details>')
 for name,result in available:
  parts.append('<details><summary>'+esc(name)+f' · {result["elapsed_ms"]:.1f} ms</summary><pre>'+esc(result['error'] or '\n\n'.join(result['translations']))+'</pre></details>')
 parts.append('</article>')
parts.append('''<script>const rows=[...document.querySelectorAll('article')];const input=document.querySelector('#search');function filter(){const q=input.value.toLowerCase();for(const r of rows)r.hidden=!r.dataset.search.toLowerCase().includes(q);document.querySelector('#count').textContent=rows.filter(r=>!r.hidden).length+' 条样本';}input.addEventListener('input',filter);filter();</script></html>''')
(a.output/'comparison.html').write_text('\n'.join(parts))
print(json.dumps({'runs':len(outputs),'samples':len(set().union(*(set(v) for v in outputs.values()))),'output':str(a.output)},ensure_ascii=False))

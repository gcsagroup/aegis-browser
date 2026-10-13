#!/usr/bin/env python3
"""官方 OPUS-MT 固定版本的离线质量对照；不接入或修改浏览器运行环境。"""
import argparse, hashlib, json, os, resource, subprocess, time
from pathlib import Path

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--models',type=Path,required=True)
parser.add_argument('--corpus',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--split',choices=['development','holdout','all'],default='development')
parser.add_argument('--threads',type=int,default=4)
parser.add_argument('--direction',choices=['en-zh','zh-en'])
args=parser.parse_args()
os.environ['HF_HUB_OFFLINE']='1';os.environ['TRANSFORMERS_OFFLINE']='1';os.environ['TOKENIZERS_PARALLELISM']='false'
import torch
from transformers import MarianConfig, MarianMTModel, MarianTokenizer, GenerationConfig

torch.set_num_threads(args.threads)
freeze=json.loads((args.corpus/'freeze-v1.json').read_text());cases=[]
for name in ['short-v1.json','long-v1.json']:
 raw=(args.corpus/name).read_bytes()
 if hashlib.sha256(raw).hexdigest()!=freeze['files'][name]:raise ValueError('语料摘要不匹配')
 cases.extend(json.loads(raw)['cases'])
cases=[c for c in cases if args.split=='all' or c['split']==args.split]
if args.direction:cases=[c for c in cases if c['direction']==args.direction]
# 与 WASM 对照共用系统 ICU 分句，避免额外保存一份重复的原文语料。
segmented=subprocess.run(['node','--input-type=module','-e', '''
import fs from 'node:fs';
const cases=JSON.parse(fs.readFileSync(0,'utf8'));
console.log(JSON.stringify(Object.fromEntries(cases.map(row => [row.id,
  row.paragraphs.map(text => [...new Intl.Segmenter(row.direction.slice(0,2),
    {granularity:'sentence'}).segment(text)].map(part => part.segment))]))));
'''],input=json.dumps(cases),text=True,capture_output=True,check=True)
segments=json.loads(segmented.stdout)
report={'schema':1,'family':'opus-mt','beam':'各方向官方 generation_config','split':args.split,'runtime':'PyTorch CPU 原始浮点权重；不是 WASM 性能对等测试','threads':args.threads,'corpusHashes':freeze['files'],'model_loads':[],'results':[]}
args.output.parent.mkdir(parents=True,exist_ok=True)
start=time.perf_counter()
for direction in ['en-zh','zh-en']:
 if not any(c['direction']==direction for c in cases):continue
 folder=args.models/('opus-mt-'+direction)
 before=time.perf_counter()
 tokenizer=MarianTokenizer.from_pretrained(str(folder),local_files_only=True)
 # 英译中模型卡要求目标语言标记，明确选择简体中文。
 prefix='>>cmn_Hans<< ' if direction=='en-zh' else ''
 if prefix:assert prefix.strip() in tokenizer.supported_language_codes
 config=MarianConfig.from_pretrained(str(folder),local_files_only=True)
 model=MarianMTModel(config)
 # 只解码张量，不使用模型仓库的自定义 Python 或不受限 pickle 加载。
 weights=torch.load(folder/'pytorch_model.bin',map_location='cpu',weights_only=True)
 # 旧版权重省略了与解码词嵌入绑定的输出矩阵，显式恢复别名后严格加载。
 if 'lm_head.weight' not in weights:
  assert config.tie_word_embeddings
  weights['lm_head.weight']=weights['model.decoder.embed_tokens.weight']
 model.load_state_dict(weights);del weights
 model.generation_config=GenerationConfig.from_pretrained(str(folder),local_files_only=True)
 model.eval()
 report['model_loads'].append({'direction':direction,'seconds':time.perf_counter()-before,'beam':model.generation_config.num_beams,'prefix':prefix,'revision':json.loads((folder/'revision.json').read_text())})
 def bounded(text):
  tokens=tokenizer(prefix+text,return_tensors='pt',truncation=False)
  if tokens['input_ids'].shape[1]<=384:return [(text,tokens)]
  # 超长单句只在空白或标点附近进一步切分；不使用 tokenizer 静默截断。
  mid=len(text)//2;places=[i+1 for i,c in enumerate(text) if c.isspace() or c in '，,；;。.!?！？']
  positions=[p for p in places if len(text)//4<p<len(text)*3//4]
  cut=min(positions,key=lambda p:abs(p-mid)) if positions else mid
  return bounded(text[:cut])+bounded(text[cut:])
 for row in [c for c in cases if c['direction']==direction]:
  before=time.perf_counter();translations=[];chunks=0;error=None
  try:
   for sentence_list in segments[row['id']]:
    parts=[]
    for sentence in sentence_list:
     for text,inputs in bounded(sentence):
      chunks+=1
      with torch.inference_mode():generated=model.generate(**inputs,do_sample=False,max_new_tokens=512)
      if generated.shape[1]>=513:raise ValueError('达到输出长度上限，不能视为完整译文')
      parts.append(tokenizer.decode(generated[0],skip_special_tokens=True))
    translations.append(('' if direction=='en-zh' else ' ').join(parts))
  except Exception as exc:error=str(exc)
  report['results'].append({'id':row['id'],'category':row['category'],'direction':direction,'split':row['split'],'translations':translations,'error':error,'chunks':chunks,'elapsed_ms':(time.perf_counter()-before)*1000,'source_bytes':len('\n'.join(row['paragraphs']).encode())})
  args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
  if len(report['results'])%10==0:print(json.dumps({'completed':len(report['results']),'total':len(cases),'last':row['id']}),flush=True)
 del model,tokenizer
report['elapsed_ms']=(time.perf_counter()-start)*1000
report['max_rss_bytes']=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
report['complete']=True
args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'complete':True,'count':len(report['results']),'seconds':report['elapsed_ms']/1000,'errors':sum(bool(r['error']) for r in report['results'])}),flush=True)

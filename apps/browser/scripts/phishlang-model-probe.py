"""对固定上游权重执行离线冒烟与窗口边界对照；不是准确率评估。"""
import argparse
import hashlib
import importlib.util
import json
import time
from pathlib import Path
import torch
from transformers import MobileBertTokenizer, MobileBertForSequenceClassification

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
torch.set_num_threads(2)
source=args.source/'patched_parser_prediction.py'
if hashlib.sha256(source.read_bytes()).hexdigest() != '7e4c41cf958e5cf6af7c9f2acd3a32424e89a6224cc114882ee89f98cb572f49':
    raise ValueError('只能运行已检查的固定上游源码')
spec=importlib.util.spec_from_file_location('fixed_phishlang_probe',source)
upstream=importlib.util.module_from_spec(spec);spec.loader.exec_module(upstream)
start=time.perf_counter()
model=MobileBertForSequenceClassification.from_pretrained(args.source/'model',local_files_only=True,use_safetensors=True).eval()
tokenizer=MobileBertTokenizer.from_pretrained(args.source/'model',local_files_only=True)
load_ms=(time.perf_counter()-start)*1000

# 标签描述输入意图，只用于复现流程；合成材料不能提供模型准确率结论。
samples=[
 ('short_article','benign_fixture','<h1>Library opening hours</h1><p>The public library opens at nine and closes at six.</p>'),
 ('short_login_lure','phishing_fixture','<h1>Your account is suspended</h1><p>Verify immediately or lose access.</p><form action="https://fixture.invalid/collect"><input type="password" name="password"><button>Confirm password</button></form>'),
 ('long_article','benign_fixture','<h1>Reading notes</h1>'+''.join('<p>The public library offers books, study rooms, art classes and a quiet reading space. Visitors can ask the librarian for help.</p>' for _ in range(12))),
 ('long_login_lure','phishing_fixture','<h1>Urgent account verification</h1>'+''.join('<p>Your account will be permanently closed in one hour. Confirm your password, security code and card information to restore access.</p>' for _ in range(12))+'<form><input type="password"><button>Submit security information</button></form>'),
]

def corrected_windows(text):
 # 使用同一权重，补足短输入和末尾；初始分词不截断，单窗口保持 128 token 上限。
 ids=tokenizer(text,add_special_tokens=False,truncation=False)['input_ids']
 best=0.0; windows=0
 for offset in range(0,len(ids),64):
  window=ids[offset:offset+126]
  encoded=tokenizer.prepare_for_model(window,add_special_tokens=True,return_tensors='pt')
  encoded={key:value.unsqueeze(0) if value.ndim==1 else value for key,value in encoded.items()}
  with torch.inference_mode(): score=torch.softmax(model(**encoded).logits,dim=-1)[0,1].item()
  best=max(best,score);windows+=1
  if offset+126>=len(ids):break
 return {'verdict':'phishing' if best>0.5 else 'benign','score':best,'windows':windows,'tokens':len(ids)}

rows=[]
for name,kind,html in samples:
 text=upstream.generate_text_representation(html)
 count=[0]
 handle=model.register_forward_pre_hook(lambda module,inputs:count.__setitem__(0,count[0]+1))
 start=time.perf_counter()
 verdict,score=upstream.predict_with_sliding_window(model,tokenizer,text,128,64)
 original={'verdict':verdict,'score':score,'model_calls':count[0],'elapsed_ms':(time.perf_counter()-start)*1000}
 handle.remove()
 start=time.perf_counter();fixed=corrected_windows(text);fixed['elapsed_ms']=(time.perf_counter()-start)*1000
 rows.append({'id':name,'input_kind':kind,'input_sha256':hashlib.sha256(html.encode()).hexdigest(),'upstream':original,'boundary_corrected':fixed})
 print(name,original,fixed,flush=True)
report={'schema':1,'qualification':'真实权重 CPU 冒烟及窗口边界对照；仅 4 份合成夹具，不报告准确率、误报率或泛化效果。',
 'repository':'https://github.com/UTA-SPRLab/phishlang','commit':'6b7283854ef8a6edc73f945c1ce7e51b2e1dc4fd',
 'model_sha256':hashlib.file_digest((args.source/'model/model.safetensors').open('rb'),'sha256').hexdigest(),
 'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'torch':torch.__version__,'device':'cpu','threads':2,
 'load_ms':load_ms,'cases':rows,'license':'仓库未发现许可文件；不得作为可分发模型纳入产品。'}
args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')

#!/usr/bin/env python3
"""固定上游提交的只读准入核查与函数边界实验；不安装服务、不运行真实模型。"""
import argparse
import ast
import contextlib
import copy
import hashlib
import json
from pathlib import Path
import urllib.request

PROJECTS = {
    'MINIM': ('yyyyhx/MINIM', '456c60b6fd47941d1e5849db573dbbcb488e3ae7', 'run_minim_inference.py'),
    'PhishLang': ('UTA-SPRLab/phishlang', '6b7283854ef8a6edc73f945c1ce7e51b2e1dc4fd', 'src/patched_parser_prediction.py'),
}


def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'GCSA-readonly-research-audit'})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read(2 * 1024 * 1024 + 1)
    if len(data) > 2 * 1024 * 1024:
        raise ValueError('源码响应超过边界')
    return data


def selected_functions(source, names, environment):
    tree = ast.parse(source)
    functions = [item for item in tree.body
                 if isinstance(item, ast.FunctionDef) and item.name in names]
    if {item.name for item in functions} != set(names):
        raise ValueError('上游接口与固定实验不匹配')
    # 只执行已检查的固定提交中指定纯函数；不执行导入、main、训练及安装逻辑。
    exec(compile(ast.Module(body=functions, type_ignores=[]), '<upstream-probe>', 'exec'), environment)
    return environment


def minim_probe(source):
    env = selected_functions(source, ['action_from_scores', 'sanitize_node'],
                             {'Dict': dict, 'copy': copy})
    choose = env['action_from_scores']
    actions = [choose(9, 0, 1, 5), choose(9, 8, 1, 5), choose(0, 8, 1, 5)]
    assert actions == ['R', 'A', 'K']
    fixture = {'nodeId': '1', 'role': 'button', 'name': {'value': 'fixture-private'},
               'value': {'value': 'fixture-private'}, 'description': {'value': 'fixture-private'}}
    result = env['sanitize_node'](fixture, 'A')
    assert result['name']['value'] == '[REDACTED]' and fixture['name']['value'] == 'fixture-private'
    assert result['role'] == 'button'
    return {'kind': 'fixed-source-function-probe', 'cases': 4, 'passed': True,
            'boundary': '输入为人工分数，只核查 Keep/Abstract/Remove 规则及副本隔离；不代表学习评分器或任务完成率。'}


class Tokens:
    def __init__(self, size):
        self.length = size
    def squeeze(self):
        return self
    def size(self, axis):
        return self.length
    def __getitem__(self, item):
        start, stop, step = item.indices(self.length)
        return Tokens(len(range(start, stop, step)))


def phishlang_probe(source):
    class Tokenizer:
        def __call__(self, text, **kwargs):
            return type('Encoded', (), {'input_ids': Tokens(int(text))})()
        def decode(self, window, **kwargs):
            return str(window.length)
    class Model:
        calls = 0
        def __call__(self, **kwargs):
            self.calls += 1
            return type('Output', (), {'logits': None})()
    class Probabilities:
        def __getitem__(self, index):
            return self
        def item(self):
            return 0.9
    class Torch:
        no_grad = staticmethod(contextlib.nullcontext)
        softmax = staticmethod(lambda logits, dim: Probabilities())
    # 上游把 tokenizer 返回值同时当属性与 mapping 使用，按真实 BatchEncoding 双接口模拟。
    class Encoding(dict):
        @property
        def input_ids(self):
            return self['input_ids']
    class CompatibleTokenizer(Tokenizer):
        def __call__(self, text, **kwargs):
            return Encoding(input_ids=Tokens(int(text)))
    env = selected_functions(source, ['predict_with_sliding_window'], {'torch': Torch})
    rows = []
    for count in [32, 127, 128, 200]:
        model = Model()
        verdict, score = env['predict_with_sliding_window'](model, CompatibleTokenizer(), str(count), 128, 64)
        rows.append({'tokens': count, 'model_calls': model.calls, 'verdict': verdict, 'fixture_score': score})
    assert rows[0]['model_calls'] == rows[1]['model_calls'] == 0
    assert rows[0]['verdict'] == rows[1]['verdict'] == 'benign'
    assert rows[2]['model_calls'] == 1 and rows[3]['model_calls'] == 2
    return {'kind': 'fixed-source-function-probe-with-fake-tensors', 'cases': rows,
            'finding': '少于 128 token 直接返回 benign，未调用模型；不足一个完整窗口的尾部被丢弃。',
            'boundary': '仅复现控制流缺口，不是模型准确率、误报率或真实设备推理性能。'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    report = {'schema': 1, 'model_inference': 'not_run', 'projects': {}}
    for name, (repo, commit, script) in PROJECTS.items():
        tree = json.loads(fetch(f'https://api.github.com/repos/{repo}/git/trees/{commit}?recursive=1'))
        if tree.get('truncated'):
            raise ValueError('上游文件树不完整，不能推断许可及权重状态')
        files = [entry['path'] for entry in tree['tree'] if entry['type'] == 'blob']
        license_files = [path for path in files if Path(path).name.lower().startswith(('license', 'copying'))]
        weights = [path for path in files if Path(path).suffix in {'.pt', '.pth', '.safetensors', '.onnx'}]
        source_url = f'https://raw.githubusercontent.com/{repo}/{commit}/{script}'
        source = fetch(source_url)
        probe = minim_probe(source.decode()) if name == 'MINIM' else phishlang_probe(source.decode())
        report['projects'][name] = {'repository': f'https://github.com/{repo}', 'commit': commit,
            'source_url': source_url, 'source_sha256': hashlib.sha256(source).hexdigest(),
            'license_files': license_files, 'weight_paths': weights, 'probe': probe,
            'integration': 'blocked_pending_license_and_real_evaluation',
            'model_inference': 'not_run'}
    destination = Path(args.output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()

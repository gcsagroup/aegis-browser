#!/usr/bin/env python3
"""MINIM 真实标注数据的小规模评分器试验；不宣称复现论文全部效果。"""
import argparse
import hashlib
import importlib.util
import json
import sys
import time
from pathlib import Path

import torch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model-type", choices=("mlp", "gatv2"), default="mlp")
    parser.add_argument("--embedding-model", type=Path)
    args = parser.parse_args()
    if hashlib.sha256(args.source.read_bytes()).hexdigest() != args.source_sha256:
        raise ValueError("上游源码摘要不匹配")
    spec = importlib.util.spec_from_file_location("minim_pilot_upstream", args.source)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    if args.model_type == "gatv2":
        if not args.embedding_model or not args.embedding_model.is_dir():
            parser.error("GATv2 需要已下载并核对的本地 MiniLM")
        module.MINILM_MODEL_NAME = str(args.embedding_model.resolve())
    torch.set_num_threads(2)
    module.set_seed(20261011)
    config = module.build_parser().parse_args([
        "--data_root", str(args.data), "--output_dir", str(args.output),
        "--model_type", args.model_type, "--epochs", "10", "--seed", "20261011"])
    started = time.monotonic()
    module.train(config)
    checkpoint = torch.load(args.output / "model.pt", map_location="cpu", weights_only=True)
    model = module.build_scorer(args.model_type, hidden=config.hidden, gat_hidden=config.gat_hidden, gat_heads=config.gat_heads).eval()
    model.load_state_dict(checkpoint["model_state"])
    split = module.split_rows(module.read_manifest(str(args.data)), .8, .1, config.seed)
    group_sets = [{(r["domain"], r["sample_id"]) for r in split[name]}
                  for name in ("train", "val", "test")]
    assert not (group_sets[0] & group_sets[1] or group_sets[0] & group_sets[2] or group_sets[1] & group_sets[2])
    totals = {"nodes": 0, "necessary": 0, "necessary_retained": 0,
              "sensitive": 0, "sensitive_exposed": 0, "keep": 0, "abstract": 0, "remove": 0}
    rows = []
    with torch.inference_mode():
        for row in split["test"]:
            variant = module.featurize_variant(row, str(args.data), args.model_type)
            s, n = module.score_variant(model, variant, torch.device("cpu"))
            keep = (n >= 1) & (s < 5)
            abstract = (n >= 1) & (s >= 5)
            necessary = variant.nec >= 1
            sensitive = variant.sens >= 5
            stats = {"nodes": len(s), "necessary": int(necessary.sum()),
                     "necessary_retained": int((necessary & (n >= 1)).sum()),
                     "sensitive": int(sensitive.sum()), "sensitive_exposed": int((sensitive & keep).sum()),
                     "keep": int(keep.sum()), "abstract": int(abstract.sum()), "remove": int((n < 1).sum())}
            for key, value in stats.items():
                totals[key] += value
            rows.append({"variant": variant.variant_id, **stats})
    report = {"schema": 1, "model": "MINIM upstream " + args.model_type + ", locally trained",
              "dataset_revision": "fd1786cb08dc42173905588e7ca015de968c8134",
              "source_sha256": args.source_sha256,
              "split_variants": {key: len(value) for key, value in split.items()},
              "split_groups": dict(zip(("train", "val", "test"), map(len, group_sets))),
              "group_overlap": 0, "totals": totals, "cases": rows,
              "necessary_node_retention": totals["necessary_retained"] / max(1, totals["necessary"]),
              "sensitive_node_raw_exposure": totals["sensitive_exposed"] / max(1, totals["sensitive"]),
              "elapsed_seconds": time.monotonic() - started,
              "boundary": "固定抽样、按页面分组留出；仅标注节点代理指标，不是论文全量复现或浏览器任务完成率。代码许可仍未明确，不纳入产品。"}
    (args.output / "evaluation.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "cases"}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

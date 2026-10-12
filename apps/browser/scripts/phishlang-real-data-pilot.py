#!/usr/bin/env python3
"""用独立静态网页测试样本比较 PhishLang 原版与窗口补齐版；不访问样本网址。"""
import argparse
import hashlib
import importlib.util
import json
import time
from pathlib import Path

import torch
from transformers import MobileBertForSequenceClassification, MobileBertTokenizer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--rows", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sampling", type=Path, required=True)
    args = parser.parse_args()
    source = args.source / "patched_parser_prediction.py"
    assert hashlib.sha256(source.read_bytes()).hexdigest() == "7e4c41cf958e5cf6af7c9f2acd3a32424e89a6224cc114882ee89f98cb572f49"
    spec = importlib.util.spec_from_file_location("phishlang_pilot_upstream", source)
    upstream = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(upstream)
    torch.set_num_threads(2)
    model = MobileBertForSequenceClassification.from_pretrained(
        args.source / "model", local_files_only=True, use_safetensors=True).eval()
    tokenizer = MobileBertTokenizer.from_pretrained(args.source / "model", local_files_only=True)
    rows = json.loads(args.rows.read_text())
    sampling = json.loads(args.sampling.read_text())
    assert sampling["revision"] == "eabec4b7a66324b79cc8a0ad856d1731dc26fe1a"
    assert sorted(item["row_idx"] for item in rows) == sorted(sampling["selected_indices"])
    results, excluded, seen = [], [], set()
    started = time.monotonic()
    for item in rows:
        index, row = item["row_idx"], item["row"]
        if item.get("truncated_cells") or not isinstance(row.get("html"), str):
            excluded.append({"index": index, "reason": "dataset_api_truncated_or_missing"})
            continue
        html = row["html"]
        digest = hashlib.sha256(html.encode()).hexdigest()
        if digest in seen or len(html.encode()) > 1024 * 1024 or row["label"] not in ("benign", "phish"):
            excluded.append({"index": index, "reason": "duplicate_size_or_label"})
            continue
        seen.add(digest)
        text = upstream.generate_text_representation(html)
        ids = tokenizer(text, add_special_tokens=False, truncation=False)["input_ids"]
        if not ids or len(ids) > 8192:
            excluded.append({"index": index, "reason": "token_budget", "tokens": len(ids)})
            continue
        start = time.monotonic()
        original, original_score = upstream.predict_with_sliding_window(model, tokenizer, text, 128, 64)
        original_ms = (time.monotonic() - start) * 1000
        start = time.monotonic()
        best, windows = 0.0, 0
        with torch.inference_mode():
            for offset in range(0, len(ids), 64):
                encoded = tokenizer.prepare_for_model(ids[offset:offset+126], return_tensors="pt")
                encoded = {key: value.unsqueeze(0) if value.ndim == 1 else value for key, value in encoded.items()}
                best = max(best, torch.softmax(model(**encoded).logits, dim=-1)[0, 1].item())
                windows += 1
                if offset + 126 >= len(ids):
                    break
        result = {"index": index, "html_sha256": digest, "label": row["label"], "tokens": len(ids),
                  "upstream": {"verdict": original, "score": original_score, "ms": original_ms},
                  "corrected": {"verdict": "phishing" if best > .5 else "benign", "score": best,
                                "windows": windows, "ms": (time.monotonic() - start) * 1000}}
        results.append(result)
        print(index, row["label"], original, result["corrected"]["verdict"], flush=True)
    if not results or {row["label"] for row in results} != {"benign", "phish"}:
        raise ValueError("可评测样本必须同时包含正常网页和钓鱼网页")
    metrics = {}
    for variant in ("upstream", "corrected"):
        counts = dict(tp=0, tn=0, fp=0, fn=0)
        for row in results:
            actual, predicted = row["label"] == "phish", row[variant]["verdict"] == "phishing"
            counts[("t" if actual == predicted else "f") + ("p" if predicted else "n")] += 1
        metrics[variant] = counts
    report = {"schema": 1, "dataset": "phreshphish/phreshphish", "dataset_revision": "eabec4b7a66324b79cc8a0ad856d1731dc26fe1a",
              "sampling": sampling, "split": "test", "input_sha256": hashlib.sha256(args.rows.read_bytes()).hexdigest(),
              "model_sha256": hashlib.file_digest((args.source / "model/model.safetensors").open("rb"), "sha256").hexdigest(),
              "sampled": len(rows), "evaluated": len(results), "excluded": excluded,
              "metrics": metrics, "cases": results, "elapsed_seconds": time.monotonic() - started,
              "boundary": "首个测试分片的固定抽样小试验；尚未与上游训练集查重。跳过超预算和截断输入，结果不能代表整个测试集或上线阈值。模型许可仍未明确。"}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k not in ("cases", "excluded")}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

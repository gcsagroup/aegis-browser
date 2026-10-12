#!/usr/bin/env python3
"""把已核对的本地研究权重导出为浏览器资产；不联网、不下载或执行权重内代码。"""
import argparse
import hashlib
import json
import tempfile
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phishlang", type=Path, required=True, help="包含 safetensors 和 config.json 的模型目录")
    parser.add_argument("--minim-checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="必须为空目录")
    args = parser.parse_args()
    expected_phish = "235f0f52b32575c46ddd5584ef382a7969c96d012ed9a903722da8cb7593d009"
    expected_minim = "9259bc70d469870d41ba24d0576d84b291b0f4770e8f45c415b8b979b63ceab1"
    if digest(args.phishlang / "model.safetensors") != expected_phish or digest(args.minim_checkpoint) != expected_minim:
        parser.error("输入权重摘要与已验收来源不符")
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("拒绝覆盖非空输出目录")
    import torch
    from transformers import MobileBertForSequenceClassification
    from onnxruntime.quantization import quantize_dynamic, QuantType

    torch.set_num_threads(2)
    model = MobileBertForSequenceClassification.from_pretrained(
        args.phishlang, local_files_only=True, use_safetensors=True).eval()

    class Export(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.model = model

        def forward(self, input_ids, attention_mask, token_type_ids):
            return self.model(input_ids=input_ids, attention_mask=attention_mask,
                              token_type_ids=token_type_ids).logits

    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="aegis-local-export-") as directory:
        original = Path(directory) / "phishlang.onnx"
        inputs = (torch.ones((1, 128), dtype=torch.long),
                  torch.ones((1, 128), dtype=torch.long),
                  torch.zeros((1, 128), dtype=torch.long))
        torch.onnx.export(Export().eval(), inputs, original,
                          input_names=["input_ids", "attention_mask", "token_type_ids"],
                          output_names=["logits"], opset_version=17)
        quantize_dynamic(original, args.output / "phishlang.onnx",
                         weight_type=QuantType.QInt8, op_types_to_quantize=["MatMul", "Gemm"])
    state = torch.load(args.minim_checkpoint, map_location="cpu", weights_only=True)["model_state"]
    (args.output / "minim-mlp.json").write_text(json.dumps(
        {key: value.tolist() for key, value in state.items()}, separators=(",", ":")))
    print(json.dumps({path.name: {"bytes": path.stat().st_size, "sha256": digest(path)}
                      for path in args.output.iterdir()}, indent=2))


if __name__ == "__main__":
    main()

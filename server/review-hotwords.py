#!/usr/bin/env python3
"""
review-hotwords.py — 聚合 hotwords-learned.jsonl 给人审核。

funasr-stream-server.py 每次 Qwen3-ASR 出 final 后，跟 paraformer raw 比较，
让 mini-gateway 的 LLM 抽"流式听错 → final 正确"的同音术语对，append 进
hotwords-learned.jsonl。这个脚本读那个 jsonl，聚合、统计、跟现有 hotwords.yaml
对比，最后打印可直接 copy-paste 的 YAML 片段——不自动改 yaml（避免脏词污染）。

用法：
  # 远程拉 jsonl
  scp <GPU_USER>@<GPU_HOST>:/home/<GPU_USER>/voice-stack/hotwords-learned.jsonl /tmp/

  # 本地审核
  python3 server/review-hotwords.py /tmp/hotwords-learned.jsonl
  python3 server/review-hotwords.py /tmp/hotwords-learned.jsonl --threshold 3
"""

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

import yaml


def load_jsonl(path: Path):
    """读 jsonl，每行 parse 一条记录；坏行 stderr 跳过不致命。"""
    out = []
    if not path.exists():
        return out
    with open(path, "r", encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"  line {i} skipped: {e}", file=sys.stderr)
    return out


def load_yaml_words(path: Path):
    """读 hotwords.yaml，扁平化所有词成 set（lowercase 比较，免大小写漏匹配）。"""
    if not path.exists():
        return set()
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    out = set()
    for _cat, items in data.items():
        if isinstance(items, list):
            for w in items:
                if isinstance(w, str):
                    out.add(w.strip().lower())
    return out


def aggregate(records):
    """按 right 词聚合：{right: {"count": N, "wrongs": {set of wrong forms}}}"""
    agg = defaultdict(lambda: {"count": 0, "wrongs": set()})
    for r in records:
        for c in r.get("candidates", []):
            right = (c.get("right") or "").strip()
            wrong = (c.get("wrong") or "").strip()
            if not right:
                continue
            agg[right]["count"] += 1
            if wrong:
                agg[right]["wrongs"].add(wrong)
    return dict(agg)


def main():
    ap = argparse.ArgumentParser(
        description="Review hotwords-learned.jsonl candidates",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "jsonl",
        type=Path,
        nargs="?",
        default=Path("/tmp/hotwords-learned.jsonl"),
        help="jsonl path (default /tmp/hotwords-learned.jsonl)",
    )
    ap.add_argument(
        "--yaml",
        type=Path,
        default=Path(__file__).parent / "hotwords.yaml",
        help="hotwords.yaml path (default <script_dir>/hotwords.yaml)",
    )
    ap.add_argument(
        "--threshold",
        type=int,
        default=2,
        help="只在最终建议片段里列 count >= threshold 的候选（默认 2）",
    )
    args = ap.parse_args()

    records = load_jsonl(args.jsonl)
    yaml_words = load_yaml_words(args.yaml)
    agg = aggregate(records)

    print("=== hotwords learning review ===")
    print(f"  jsonl:    {args.jsonl}")
    print(f"  yaml:     {args.yaml}  ({len(yaml_words)} terms)")
    print(f"  records:  {len(records)} learning sessions")
    print(f"  unique candidates: {len(agg)}")
    print()

    if not agg:
        print("(jsonl 空，可能 funasr-stream-server 还没遇到识别错误的录音。)")
        return

    print("=== 全部候选（按 count 降序）===")
    for right, info in sorted(agg.items(), key=lambda x: -x[1]["count"]):
        in_yaml = right.lower() in yaml_words
        flag = "[已在 yaml]" if in_yaml else "[新]"
        wrongs = ", ".join(sorted(info["wrongs"]))
        print(f"  {info['count']:3d}x  {right:40s}  {flag:11s}  错形: {wrongs}")
    print()

    new_candidates = sorted(
        [(r, info) for r, info in agg.items()
         if r.lower() not in yaml_words and info["count"] >= args.threshold],
        key=lambda x: -x[1]["count"],
    )
    if not new_candidates:
        print(f"=== 无可加候选（threshold={args.threshold}）===")
        return

    print(f"=== 建议加进 hotwords.yaml（count >= {args.threshold}, 未入 yaml）===")
    print("# 直接 copy-paste 到合适的分类下；自己判断归到 ai_agent / cs_research / software_engineering / chinese_tech")
    print()
    for right, info in new_candidates:
        wrongs = " / ".join(sorted(info["wrongs"])[:3])
        more = f" (+{len(info['wrongs'])-3} 更多)" if len(info["wrongs"]) > 3 else ""
        print(f"  - {right}    # {info['count']}x, 错形: {wrongs}{more}")
    print()
    print(f"({len(new_candidates)} 个候选可加)")


if __name__ == "__main__":
    main()

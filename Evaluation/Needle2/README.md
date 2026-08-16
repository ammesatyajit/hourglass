# Hourglass Needle2 evaluation and fine-tuning

`hourglass-tools.json` is the readable, typed function catalogue used by the
standalone evaluator. `finetune-cases.jsonl` is the compact, reviewable source
dataset: 56 positive iMessage/contact queries plus 8 off-topic negatives.

Generate Needle's exact training format. Each example carries the correct tool
plus its closest competitors, mirroring Needle's built-in catalogue retrieval
while keeping the target inside the model's training context. Redundant prose
descriptions are stripped from the generated training copy; names, JSON types,
enums, bounds, patterns, and required fields remain intact:

```sh
./Evaluation/Needle2/prepare-finetune.sh /tmp/hourglass-finetune.jsonl
```

Train and export with the official `cactus-needle` CLI:

```sh
needle finetune /tmp/hourglass-finetune.jsonl --epochs 30 --out /tmp/hourglass-adapter.pkl
needle build checkpoints/needle2.pkl --lora /tmp/hourglass-adapter.pkl --out /tmp/hourglass-tuned.cact
```

Do not bundle a tuned archive until it beats the base+validator route on a
held-out corpus. The shipping dylib already contains the base weights;
adding a `.cact` duplicates roughly 13 MB of weights.

Build the standalone smoke/evaluation binary:

```sh
clang++ Evaluation/Needle2/needle-eval.cpp \
  -I Vendor/Needle2/macos-arm64 \
  -L Vendor/Needle2/macos-arm64 -lneedle \
  -Wl,-rpath,"$PWD/Vendor/Needle2/macos-arm64" \
  -o /tmp/hourglass-needle-eval
```

Each input line is one natural-language query. Needle's schema-constrained JSON
envelope is printed on the corresponding output line. Pass a tuned archive as
the fourth argument to compare it with the baked base weights:

```sh
/tmp/hourglass-needle-eval Evaluation/Needle2/hourglass-tools.json \
  "date: 2026-08-14; assistant: Hourglass" /tmp/hourglass-tuned.cact
```

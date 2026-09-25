#!/usr/bin/env python3
"""OPTIONAL: fine-tune TrOCR on your own handwriting.

Orbit's HandwritingLearner exports (image, text) pairs whenever your typed notes
cover a block of handwriting. `HandwritingDataset.write` produces:

    <dataset>/manifest.jsonl     {"id": …, "image": "images/<id>.png", "text": "…", …} per line
    <dataset>/images/<id>.png

Usage:
    python3 finetune_trocr.py --dataset ~/Library/Application\\ Support/Orbit/handwriting-dataset \\
                              --output ~/Library/Application\\ Support/Orbit/trocr-personal

Then point Orbit's TrOCR helper at the output folder (`orbit_ocr.py --checkpoint <output>`).
A few hundred lines is enough to see a real improvement; it trains on an Apple silicon
Mac (MPS) in minutes to an hour.
"""

import argparse
import json
import random
import sys
from pathlib import Path


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def levenshtein(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def load_manifest(dataset, allow_multiline):
    samples = []
    for line in (dataset / "manifest.jsonl").read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        image = dataset / entry["image"]
        text = entry["text"].strip()
        if not image.exists() or not text:
            continue
        if "\n" in text and not allow_multiline:
            # TrOCR reads single lines. Orbit exports line images when it can.
            continue
        samples.append((image, text.replace("\n", " ")))
    return samples


def main():
    parser = argparse.ArgumentParser(description="Fine-tune TrOCR on Orbit's handwriting dataset (optional)")
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--base", default="microsoft/trocr-base-handwritten")
    parser.add_argument("--epochs", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--lr", type=float, default=3e-5)
    parser.add_argument("--val-split", type=float, default=0.1)
    parser.add_argument("--allow-multiline", action="store_true",
                        help="also train on multi-line region images (joined into one line)")
    args = parser.parse_args()

    import torch
    from PIL import Image
    from torch.utils.data import Dataset
    from transformers import (Seq2SeqTrainer, Seq2SeqTrainingArguments, TrOCRProcessor,
                              VisionEncoderDecoderModel, default_data_collator)

    samples = load_manifest(args.dataset, args.allow_multiline)
    if len(samples) < 10:
        raise SystemExit(f"Only {len(samples)} usable samples; type up a few more pages first.")
    random.seed(7)
    random.shuffle(samples)
    n_val = max(1, int(len(samples) * args.val_split))
    val, train = samples[:n_val], samples[n_val:]
    log(f"finetune_trocr: {len(train)} train / {len(val)} validation samples")

    processor = TrOCRProcessor.from_pretrained(args.base)
    model = VisionEncoderDecoderModel.from_pretrained(args.base)
    model.config.decoder_start_token_id = processor.tokenizer.cls_token_id
    model.config.pad_token_id = processor.tokenizer.pad_token_id
    model.config.eos_token_id = processor.tokenizer.sep_token_id
    model.config.max_length = 96
    model.config.num_beams = 4

    class LinesDataset(Dataset):
        def __init__(self, items):
            self.items = items

        def __len__(self):
            return len(self.items)

        def __getitem__(self, i):
            path, text = self.items[i]
            pixel_values = processor(images=Image.open(path).convert("RGB"), return_tensors="pt").pixel_values[0]
            labels = processor.tokenizer(text, padding="max_length", max_length=96, truncation=True).input_ids
            labels = [l if l != processor.tokenizer.pad_token_id else -100 for l in labels]
            return {"pixel_values": pixel_values, "labels": torch.tensor(labels)}

    def compute_metrics(pred):
        label_ids = pred.label_ids.copy()
        label_ids[label_ids == -100] = processor.tokenizer.pad_token_id
        preds = processor.batch_decode(pred.predictions, skip_special_tokens=True)
        refs = processor.batch_decode(label_ids, skip_special_tokens=True)
        errors = sum(levenshtein(p, r) for p, r in zip(preds, refs))
        chars = max(1, sum(len(r) for r in refs))
        return {"cer": errors / chars}

    training_args = Seq2SeqTrainingArguments(
        output_dir=str(args.output / "checkpoints"),
        per_device_train_batch_size=args.batch_size,
        per_device_eval_batch_size=args.batch_size,
        num_train_epochs=args.epochs,
        learning_rate=args.lr,
        predict_with_generate=True,
        eval_strategy="epoch",
        save_strategy="epoch",
        save_total_limit=2,
        load_best_model_at_end=True,
        metric_for_best_model="cer",
        greater_is_better=False,
        logging_steps=10,
        report_to=[],
    )
    trainer = Seq2SeqTrainer(
        model=model,
        args=training_args,
        train_dataset=LinesDataset(train),
        eval_dataset=LinesDataset(val),
        data_collator=default_data_collator,
        compute_metrics=compute_metrics,
    )
    trainer.train()
    log(f"finetune_trocr: validation {trainer.evaluate()}")
    args.output.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(args.output)
    processor.save_pretrained(args.output)
    log(f"finetune_trocr: saved to {args.output}")


if __name__ == "__main__":
    main()

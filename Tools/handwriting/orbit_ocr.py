#!/usr/bin/env python3
"""OPTIONAL: TrOCR / Texify helper for Orbit's handwriting pipeline.

Orbit works without this. When configured, Orbit's `ExternalCommandOCR` runs:

    python3 orbit_ocr.py --image /tmp/orbit-ocr-XXXX.png [--checkpoint DIR] [--math] [--hint TEXT]

and reads one JSON object from the last line of stdout:

    {"engine": "trocr", "lines": [{"text": "…", "confidence": 0.83}, …]}

Handwriting uses microsoft/trocr-base-handwritten (or your fine-tuned checkpoint from
finetune_trocr.py). With --math, Texify converts the image to LaTeX instead.
Everything runs locally; models are downloaded once into the Hugging Face cache.
Logs go to stderr so stdout stays clean JSON.
"""

import argparse
import json
import sys


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def pick_device():
    import torch

    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def split_lines(image, min_gap=6, threshold=160, padding=8):
    """Splits a region image into text lines using a horizontal ink profile.

    TrOCR reads one line at a time, while Orbit renders whole paragraphs.
    """
    import numpy as np

    gray = np.asarray(image.convert("L"))
    ink_rows = (gray < threshold).sum(axis=1) > 0
    lines, start, gap = [], None, 0
    for y, has_ink in enumerate(ink_rows):
        if has_ink:
            if start is None:
                start = y
            gap = 0
        elif start is not None:
            gap += 1
            if gap >= min_gap:
                lines.append((start, y - gap + 1))
                start, gap = None, 0
    if start is not None:
        lines.append((start, len(ink_rows)))
    height, width = gray.shape
    crops = []
    for top, bottom in lines:
        if bottom - top < 4:  # specks
            continue
        crops.append(image.crop((0, max(0, top - padding), width, min(height, bottom + padding))).convert("RGB"))
    return crops or [image.convert("RGB")]


def run_trocr(image, checkpoint):
    import torch
    from transformers import TrOCRProcessor, VisionEncoderDecoderModel

    device = pick_device()
    log(f"orbit_ocr: loading {checkpoint} on {device}")
    processor = TrOCRProcessor.from_pretrained(checkpoint)
    model = VisionEncoderDecoderModel.from_pretrained(checkpoint).to(device)
    model.eval()

    results = []
    for line in split_lines(image):
        pixel_values = processor(images=line, return_tensors="pt").pixel_values.to(device)
        with torch.no_grad():
            out = model.generate(
                pixel_values,
                max_new_tokens=96,
                num_beams=4,
                output_scores=True,
                return_dict_in_generate=True,
            )
        text = processor.batch_decode(out.sequences, skip_special_tokens=True)[0].strip()
        # Beam search gives a length-normalised log-probability per sequence: a rough confidence.
        seq_scores = getattr(out, "sequences_scores", None)
        confidence = float(torch.exp(seq_scores[0]).item()) if seq_scores is not None else 0.5
        if text:
            results.append({"text": text, "confidence": round(max(0.0, min(1.0, confidence)), 3)})
    return results


def run_texify(image):
    try:
        from texify.inference import batch_inference
        from texify.model.model import load_model
        from texify.model.processor import load_processor
    except ImportError:
        raise SystemExit("texify isn't installed: pip install texify (see README.md)")
    log("orbit_ocr: running texify")
    model, processor = load_model(), load_processor()
    latex = batch_inference([image.convert("RGB")], model, processor)[0].strip()
    # Texify wraps display maths in $$…$$; Orbit expects $…$ per line.
    lines = [l.strip().strip("$").strip() for l in latex.splitlines() if l.strip().strip("$").strip()]
    return [{"text": f"${l}$", "confidence": 0.75} for l in lines]


def main():
    parser = argparse.ArgumentParser(description="Orbit handwriting helper (optional)")
    parser.add_argument("--image", required=True, help="PNG/JPEG of rendered ink or a page")
    parser.add_argument("--checkpoint", default="microsoft/trocr-base-handwritten",
                        help="Hugging Face model id or a fine-tuned directory from finetune_trocr.py")
    parser.add_argument("--math", action="store_true", help="convert maths to LaTeX with Texify")
    parser.add_argument("--hint", default=None, help="context from Orbit (currently unused)")
    args = parser.parse_args()

    from PIL import Image

    image = Image.open(args.image)
    if args.math:
        lines, engine = run_texify(image), "texify"
    else:
        lines, engine = run_trocr(image, args.checkpoint), "trocr"
    print(json.dumps({"engine": engine, "lines": lines}, ensure_ascii=False))


if __name__ == "__main__":
    main()

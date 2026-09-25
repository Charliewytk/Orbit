# Handwriting helpers (optional)

**Orbit does not need any of this.** Out of the box it reads handwriting with Apple Vision
and a local vision model through Ollama. These scripts add two open-source specialists that
you can switch on later:

| Script | What it does |
|---|---|
| `orbit_ocr.py` | Reads an image with **TrOCR** (`microsoft/trocr-base-handwritten`, or your fine-tuned copy), or with **Texify** (`--math`) to turn handwritten maths into LaTeX. Prints JSON for Orbit. |
| `finetune_trocr.py` | Fine-tunes TrOCR on *your* handwriting, using the (image, text) pairs Orbit collects when you type up your notes. |

Everything runs on your Mac. Models download once into the Hugging Face cache (~1–2 GB).

## Setup

```sh
python3 -m venv ~/Library/Application\ Support/Orbit/ocr-venv
source ~/Library/Application\ Support/Orbit/ocr-venv/bin/activate
pip install --upgrade pip
pip install transformers torch pillow texify
```

`texify` is only needed for `--math`. On Apple silicon, PyTorch uses the GPU (MPS) automatically.

Try it:

```sh
python3 orbit_ocr.py --image some-handwriting.png
# {"engine": "trocr", "lines": [{"text": "Externalities cause market failure", "confidence": 0.87}]}
python3 orbit_ocr.py --image equation.png --math
# {"engine": "texify", "lines": [{"text": "$x^{2}+y^{2}=r^{2}$", "confidence": 0.75}]}
```

## Using it from Orbit

`ExternalCommandOCR` (macOS) runs the script and reads its JSON:

```swift
let venvPython = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Orbit/ocr-venv/bin/python3")
let script = URL(fileURLWithPath: "/path/to/Orbit/Tools/handwriting/orbit_ocr.py")
let trocr = ExternalCommandOCR(name: "TrOCR", executable: venvPython, script: script)
let texify = ExternalCommandOCR(name: "Texify", executable: venvPython, script: script, extraArguments: ["--math"])

let pipeline = HandwritingPipeline(primary: AppleVisionOCR(customWords: profile.customWords),
                                   fallback: OllamaVisionOCR(router: router, vocabulary: profile.customWords),
                                   mathEngine: texify, profile: profile)
```

TrOCR can also be used as the `primary` or `fallback` engine once it's fine-tuned.

## Fine-tuning on your handwriting

Each time you type up part of a handwritten page, `HandwritingLearner` aligns the typed text
with the handwriting OCR and keeps the regions it could match. Write them out with:

```swift
try HandwritingDataset.write(report.samples, to: datasetFolder)
```

When you have a few hundred lines:

```sh
python3 finetune_trocr.py --dataset ~/Library/Application\ Support/Orbit/handwriting-dataset \
                          --output ~/Library/Application\ Support/Orbit/trocr-personal
python3 orbit_ocr.py --image test.png --checkpoint ~/Library/Application\ Support/Orbit/trocr-personal
```

Then pass `extraArguments: ["--checkpoint", "<that folder>"]` to Orbit's `ExternalCommandOCR`.

Notes:
- TrOCR reads one line at a time. Orbit exports per-line images when it can; `orbit_ocr.py`
  also splits paragraph images into lines itself. Multi-line samples are skipped during
  fine-tuning unless you pass `--allow-multiline`.
- Labels are Orbit's OCR text with misreadings corrected from your typed notes. Your own
  shorthand (`w/`, `b/c`) is kept, because that's what the image shows.
- The training data stays on your Mac. Delete the dataset folder to start over.

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

STAGE = Path(__file__).resolve().parent.parent
LOCAL = STAGE / "Локальный синтез"
for folder in (LOCAL / "runtime", LOCAL / "runtime-extra"):
    if folder.is_dir():
        sys.path.insert(0, str(folder))

import lameenc
import torch

MODEL_HASH = "0405777e332906f0644e08a680f7cfdc2137ea864090079c1fdd30a43c1b8761"
ACTORS = {"sab": "ru_aidar", "asl": "ru_xenia"}
SAMPLE_RATE = 24000
NUMBERS = ["", "П+ервый.", "Втор+ой.", "Тр+етий.", "Четв+ёртый.", "П+ятый.", "Шест+ой."]
VOWELS = "аеёиоуыэюя"


def data(root, filename):
    return json.loads((root / filename).read_text(encoding="utf-8"))


def write_json(file, value):
    file.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")


def to_mp3(samples):
    peak = samples.abs().max().item()
    if not 0.001 < peak < 20:
        raise ValueError("запись пуста или перегружена")
    samples = (samples * min(1.0, 0.9 / peak)).clamp(-1, 1)
    encoder = lameenc.Encoder()
    encoder.set_bit_rate(48)
    encoder.set_in_sample_rate(SAMPLE_RATE)
    encoder.set_channels(1)
    encoder.set_quality(2)
    return bytes(encoder.encode((samples * 32767).to(torch.int16).numpy().tobytes()) + encoder.flush())


def write_audio(model, speaker, marked, file):
    if file.exists() and file.stat().st_size > 512:
        return
    with torch.inference_mode():
        samples = model.apply_tts(text=marked, speaker=speaker, sample_rate=SAMPLE_RATE)
    audio = to_mp3(samples)
    assert len(audio) > 512, "слишком короткая запись"
    tmp = file.with_suffix(".writing")
    tmp.write_bytes(audio)
    tmp.replace(file)


def clip_id(speaker, marked):
    return hashlib.sha256(f"{MODEL_HASH}|{speaker}|{SAMPLE_RATE}|mp3/48|{marked}".encode("utf-8")).hexdigest()[:24]


def normalize_small_parts(text):
    if re.fullmatch(r"[1-6]\.", text):
        return NUMBERS[int(text[0])]
    return text


def main():
    parser = argparse.ArgumentParser(description="Синтез голосов Хасанатиков на CPU")
    parser.add_argument("--root", type=Path, default=STAGE)
    parser.add_argument("--model", type=Path, default=LOCAL / "v5_cis_base_nostress.pt")
    parser.add_argument("--preview", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    with args.model.open("rb") as stream:
        assert hashlib.file_digest(stream, "sha256").hexdigest() == MODEL_HASH, "отличается контрольная сумма модели"
    torch.set_num_threads(min(3, os.cpu_count() or 1))
    torch.set_num_interop_threads(1)
    model = torch.package.PackageImporter(str(args.model)).load_pickle("tts_models", "model")
    model.to(torch.device("cpu"))
    assert all(voice in model.speakers for voice in ACTORS.values()), model.speakers
    print("Голоса найдены:", ACTORS, flush=True)
    if args.preview:
        out = root / "Прослушивание"
        out.mkdir(exist_ok=True)
        for row in data(root, "voice-probes.json"):
            speaker = ACTORS[row["actor"]]
            file = out / (row["actor"] + "-" + speaker + ".mp3")
            write_audio(model, speaker, row["marked"], file)
            print(file.name, file.stat().st_size, "байт", flush=True)
        return

    from silero_stress import load_accentor

    accentor = load_accentor()
    out = root / "audio" / "voice"
    out.mkdir(parents=True, exist_ok=True)
    available = {"sab": {}, "asl": {}}
    offline = data(root, "offline-pack.json")
    entries = {name: size for name, size in offline["files"] if not name.startswith("audio/voice/")}
    missing = []
    report = []
    for i, row in enumerate(data(root, "voice-lines.json"), 1):
        actor, text = row["actor"], row["text"]
        try:
            normalized = normalize_small_parts(text)
            marked = row.get("marked") or (normalized if normalized != text else accentor(text))
            if not any(v in marked.lower() for v in VOWELS):
                raise ValueError("нет произносимых гласных")
            speaker = ACTORS[actor]
            key = clip_id(speaker, marked)
            file = out / (key + ".mp3")
            write_audio(model, speaker, marked, file)
            available[actor][text] = key
            entries["audio/voice/" + file.name] = file.stat().st_size
            report.append({"actor": actor, "text": text, "marked": marked, "id": key})
        except (ValueError, RuntimeError, AssertionError) as error:
            missing.append({"actor": actor, "text": text, "error": str(error)})
        if i % 50 == 0:
            print("Обработано:", i, "пропусков:", len(missing), flush=True)
    assert all(available.values()), "в пакете должен быть хотя бы один клип каждого персонажа"
    script = "window.HASANATIKI_VOICES=" + json.dumps(available, ensure_ascii=False, separators=(",", ":")) + ";\n"
    (root / "voice-pack.js").write_text(script, encoding="utf-8")
    entries["voice-pack.js"] = len(script.encode("utf-8"))
    offline["files"] = list(entries.items())
    write_json(root / "offline-pack.json", offline)
    write_json(root / "voice-review.json", {"recorded": report, "missing": missing})
    print("Записано:", len(report), "пропусков:", len(missing), flush=True)


if __name__ == "__main__":
    main()

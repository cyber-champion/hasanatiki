import argparse
import json
import re
import shutil
import unicodedata
from pathlib import Path

NAME_ASSETS = {
    "المعز": "muizz", "القوي": "qawi", "الولي": "wali", "المحصي": "muhsi",
    "المحيي": "muhyi", "المجيد": "majeed", "الماجد": "majid", "الآخر": "akhir",
    "الرءوف": "rauf", "ذو الجلال والإكرام": "dhu_l_jalali_wal_ikram",
}
DUA_VARIANTS = {
    "Если забыл в начале": "178.mp3", "Входя в дом": "18.mp3", "В транспорте": "206.mp3",
    "Перед туалетом": "10.mp3", "Входя в мечеть": "20.mp3", "Выходя из мечети": "21.mp3",
    "Чихнул": "188.mp3",
}
STUDY_VERSE = "فَتَعَالَى اللَّهُ الْمَلِكُ الْحَقُّ وَلَا تَعْجَلْ بِالْقُرْآنِ مِنْ قَبْلِ أَنْ يُقْضَى إِلَيْكَ وَحْيُهُ وَقُلْ رَبِّ زِدْنِي عِلْمًا"

def key(value):
    value = unicodedata.normalize("NFC", value)
    value = re.sub(r"[\u0610-\u061a\u0640\u064b-\u065f\u0670\u06d6-\u06ed]", "", value)
    value = re.sub(r"[^\u0621-\u063a\u0641-\u064a\s]", " ", value.replace("ٱ", "ا"))
    return " ".join(value.split())


def read_json(file):
    return json.loads(file.read_text(encoding="utf-8"))


def parse_names(folder):
    activity = next(folder.glob("app/src/main/java/**/MainActivity.java"))
    entries = re.findall(r'new NameModel\("([^"]+)",[^\n]+?,R\.raw\.([a-z0-9_]+)\)', activity.read_text(encoding="utf-8"))
    wavs = {p.stem: p for p in (folder / "app/src/main/res/raw").iterdir()}
    result = {key(text): (wavs[asset], "") for text, asset in entries if asset in wavs}
    result.update({key(text): (wavs[asset], "") for text, asset in NAME_ASSETS.items()})
    return result


def parse_duas(folder, verse, rows):
    result = {}
    versions = {}
    for chapter in read_json(folder / "data/ar.json"):
        for entry in chapter["array"]:
            file = folder / "audio" / Path(entry.get("audio") or "").name
            if file.is_file() and file.suffix.lower() == ".mp3":
                # Audio is paired with the exact Arabic words of the individual entry.
                result.setdefault(key(entry["text"]), (file, ""))
                versions[file.name] = (file, entry["text"])
    versions[verse.name] = (verse, STUDY_VERSE)
    for row in rows:
        name = verse.name if row["title"] == "Перед учёбой" else DUA_VARIANTS.get(row["title"])
        if name and name in versions:
            file, full = versions[name]
            lookup = key(row["arabic"])
            if lookup and lookup in key(full):
                result.setdefault(lookup, (file, full))
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    ap.add_argument("--names-source", type=Path, required=True)
    ap.add_argument("--duas-source", type=Path, required=True)
    ap.add_argument("--study-verse", type=Path, required=True)
    args = ap.parse_args()
    root = args.root
    lines = read_json(root / "arabic-lines.json")
    pack = read_json(root / "offline-pack.json")
    files = {name: size for name, size in pack["files"] if not name.startswith("audio/arabic/")}
    tracks = {}
    missing = {}
    for kind, set_name, sources, repo in (
        ("asma", "names", parse_names(args.names_source), args.names_source),
        ("dua", "duas", parse_duas(args.duas_source, args.study_verse, lines["duas"]), args.duas_source),
    ):
        folder = root / "audio/arabic" / kind
        folder.mkdir(parents=True, exist_ok=True)
        source_license = repo / "LICENSE"
        license_file = folder / "LICENSE.txt"
        shutil.copyfile(source_license, license_file)
        files[license_file.relative_to(root).as_posix()] = license_file.stat().st_size
        missing[kind] = []
        matched = 0
        for row in lines[set_name]:
            lookup = key(row["arabic"])
            sample = sources.get(lookup)
            if not sample:
                missing[kind].append(row)
                continue
            sample, full = sample
            filename = sample.name.lower()
            assert re.fullmatch(r"[a-z0-9_-]+\.(?:mp3|ogg|mp4)", filename), filename
            local = folder / filename
            shutil.copyfile(sample, local)
            relative = local.relative_to(root).as_posix()
            tracks[lookup] = {"src": relative, "full": full} if full else relative
            files[relative] = local.stat().st_size
            matched += 1
        print(kind, matched, "/", len(lines[set_name]), flush=True)
    script = "window.HASANATIKI_ARABIC=" + json.dumps(tracks, ensure_ascii=False, separators=(",", ":")) + ";\n"
    (root / "arabic-pack.js").write_text(script, encoding="utf-8", newline="\n")
    files["arabic-pack.js"] = len(script.encode("utf-8"))
    credit = root / "audio/arabic/SOURCES.txt"
    credit.write_text(
        "99 Names of Allah — https://github.com/MohammedAbidNafi/99-Names-of-Allah\n"
        "Hisn al-Muslim, Hamad Al-Durayhim — https://github.com/YousefAsalya/Islamic-Pro-azkar-API\n"
        "Qur'an 20:114, Mahmoud Khalil Al-Husary — https://everyayah.com/data/Husary_128kbps/020114.mp3\n",
        encoding="utf-8", newline="\n",
    )
    files[credit.relative_to(root).as_posix()] = credit.stat().st_size
    pack["files"] = list(files.items())
    (root / "offline-pack.json").write_text(json.dumps(pack, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8", newline="\n")
    (root / "arabic-unmatched.json").write_text(json.dumps(missing, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()

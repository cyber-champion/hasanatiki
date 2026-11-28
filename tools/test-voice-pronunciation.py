import json
import unittest
from pathlib import Path

from voice_pronunciation import apply_rules, compile_rules


class PronunciationTest(unittest.TestCase):
    def test_bukhari_in_hadith_source(self):
        project = Path(__file__).resolve().parents[1]
        rules = compile_rules(json.loads((project / "voice-pronunciation.json").read_text(encoding="utf-8")))
        for before, after in [
            ("(аль-Б+ухари, часть)", "(аль-Бух+ари, часть)"),
            ("Аль-Бухари", "Аль-Бух+ари"),
            ("аль-Буха\u0301ри", "аль-Бух+ари"),
            ("БУХАРИ", "БУХ+АРИ"),
            ("аль-Бух+ари", "аль-Бух+ари"),
            ("сверхбухари, бухарин", "сверхбухари, бухарин"),
            ("аль-Б+ухари и М+услим", "аль-Бух+ари и М+услим"),
        ]:
            with self.subTest(before=before):
                self.assertEqual(apply_rules(before, rules), after)

    def test_invalid_entries_are_rejected(self):
        with self.assertRaises(ValueError):
            compile_rules({"бухари": "бу+хари"})


if __name__ == "__main__":
    unittest.main()

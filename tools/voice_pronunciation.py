import re


def compile_rules(entries):
    rules = []
    for word, marked in entries.items():
        if (
            not re.fullmatch(r"[а-яё]+(?:-[а-яё]+)*", word)
            or not isinstance(marked, str)
            or marked.count("+") != 1
            or marked.replace("+", "") != word
            or not re.search(r"\+[аеёиоуыэюя]", marked)
        ):
            raise ValueError(f"Некорректное ударение для {word!r}: {marked!r}")
        # Match a whole word with or without marks added by the automatic accentor.
        letters = r"\+?".join(re.escape(char) + "\u0301?" for char in word)
        pattern = re.compile(r"(?<![\w+])\+?" + letters + r"(?!\w)", re.IGNORECASE)
        rules.append((pattern, marked.index("+")))
    return rules


def apply_rules(text, rules):
    for pattern, stress in rules:
        def replace(match):
            word = match[0].replace("+", "").replace("\u0301", "")
            return word[:stress] + "+" + word[stress:]

        text = pattern.sub(replace, text)
    return text

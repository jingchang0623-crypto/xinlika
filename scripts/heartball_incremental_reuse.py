"""Small, dependency-free upstream adaptations; no model or storage access.

clean_text/clean_list adapt Omi utils/episodes/state.py at
4b4e35fdc9d61a5fb74380202cbc65d0432ecc6e (clean_list renamed).
rolling_contains ports Dayflow's 45-minute lookback/range-overlap arithmetic,
LLMTypes.swift and StorageManager+TimelineCards.swift at
730d6f84b919998158ff7fdab15e3f032f7d8135. No minimum event duration is adopted.

MIT License
Copyright (c) 2024 Based Hardware Contributors
Copyright (c) 2025 Jerry Liu

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
"""
import json
import re


def clean_text(value, limit):
    if not isinstance(value, str):
        return ''
    text = re.sub(r'\s+', ' ', value).strip().strip('•-* ').strip()
    return text[:limit].rstrip()


def clean_list(values, *, limit, chars):
    if not isinstance(values, list):
        return []
    out, seen = [], set()
    for value in values:
        text = clean_text(value, chars)
        key = text.casefold()
        if text and key not in seen:
            seen.add(key)
            out.append(text)
        if len(out) >= limit:
            break
    return out


def bounded_state(value, maximum=2400):
    """Omi's bounded running state, with whole-field JSON budgeting, no byte cut."""
    state = {'title':clean_text(value.get('title'),80),
        'bullets':clean_list(value.get('bullets'),limit=8,chars=200),
        'people':clean_list(value.get('people'),limit=8,chars=60),
        'open_questions':clean_list(value.get('open_questions'),limit=4,chars=200)}
    while len(json.dumps(state,ensure_ascii=False)) > maximum:
        field=next((f for f in ('bullets','open_questions','people') if state[f]),None)
        if field is None:raise ValueError('Compact state budget too small')
        state[field].pop(0)
    return state


def rolling_contains(start, end, new_start, new_end, lookback_seconds=45*60):
    """Dayflow overlap test; do not let late retries rewrite unseen future work."""
    return start <= new_end and end >= new_start-lookback_seconds

#!/usr/bin/env python3
"""Synthetic offline walkthrough using the real persistence and LangGraph code.

No ASR, hardware, remote model, private recording or API credential is used.
The deterministic model is a fixture, not an intelligence benchmark.
"""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import sys
import uuid

os.environ['LANGSMITH_TRACING'] = 'false'
os.environ['LANGCHAIN_TRACING_V2'] = 'false'
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))

from heartball_processing import Processor
from heartball_store import Store


class FixtureModel:
    supports_organization = True

    def __init__(self):
        self.latest_clock = {}

    def extract(self, doc, memory):
        parking = '停车' in doc['text']
        title = '停车位置' if parking else '云杉演示版交付'
        topics = doc['organization_context'].get('topics', [])
        previous = next((t for t in topics if t['title'] == title), None)
        stamp = doc.get('occurred_at') or ''
        summary = (previous['summary'] if previous and stamp < self.latest_clock.get(title, '') else doc['text'])
        self.latest_clock[title] = max(stamp, self.latest_clock.get(title, ''))
        event = {'title': title, 'summary': doc['text'], 'quote': doc['text'],
                 'display': 'event', 'topic_id': previous['id'] if previous else None,
                 'topic_title': '' if previous else title, 'topic_summary': summary,
                 'related_event_ids': [e['id'] for e in doc['organization_context'].get('unassigned_events', [])
                                       if e['title'] == title]}
        return {'title': title, 'summary': doc['text'], 'claims': [], 'events': [event]}

    def answer(self, question, memory):
        # Fixture rule: select the most recently recorded delivery event.
        events = [r for r in memory if r['record_type'] == 'event' and '交付' in r['statement']]
        events.sort(key=lambda r: r.get('occurred_at') or '', reverse=True)
        if not events:
            return {'answer': '没有交付记录。', 'refs': []}
        latest = events[0]
        return {'answer': latest['statement'], 'refs': [{'id': latest['id'], 'version': latest['version']}]}

    def organize(self, doc, context):
        return {'events': self.extract({**doc, 'organization_context': context}, [])['events']}


def run_demo(root):
    root = Path(root)
    if root.exists() and any(root.iterdir()):
        raise ValueError('Choose a new empty demo directory; existing data is never overwritten')
    store = Store(root)
    processor = Processor(store, FixtureModel())
    agent = processor.agent

    def record(text, stamp):
        sid, did = str(uuid.uuid4()), str(uuid.uuid4())
        store.create_session(sid)
        agent.policy(sid, asr=False, agent=True, source_kind='verified_text', occurred_at=stamp)
        doc = {'id': did, 'session_id': sid, 'kind': 'text', 'input_key': 'demo:' + did,
               'text': text, 'source_kind': 'verified_text', 'occurred_at': stamp,
               'boundary_quality': 'synthetic_fixture',
               'evidence': [{'kind': 'synthetic_fixture', 'sha256': hashlib.sha256(text.encode()).hexdigest()}]}
        processor.run_document(doc, str(uuid.uuid4()))
        store.update_session(sid, status='completed')
        return did

    def ask():
        qid = str(uuid.uuid4())
        agent.ask(qid, '云杉演示版现在什么时候交付？')
        row = store.db.execute("SELECT payload FROM jobs WHERE kind='memory_query' AND input_key=?", (qid,)).fetchone()
        processor.run_query(json.loads(row['payload']), str(uuid.uuid4()))
        return qid

    try:
        record('云杉演示版计划周五交付，范围只含预览功能。', '2026-10-20T09:30:00+08:00')
        did = record('云杉演示版交付改到下周二，接口联调还没完成。', '2026-10-21T14:00:00+08:00')
        record('主动记一下停车位置：P3-042。', '2026-10-21T18:20:00+08:00')
        old_qid = ask()
        before = agent.state(day='2026-10-21')
        old_event_ids = {e['id'] for e in before['events'] if any(s['document_id'] == did for s in e['sources'])}
        agent.feedback({'id': str(uuid.uuid4()), 'target_id': did, 'expected_version': 1,
                        'action': 'correct_document',
                        'values': {'text': '更正：云杉演示版下周三交付，接口联调还没完成。'}})
        old_answer_status = store.db.execute('SELECT status FROM memory_answers WHERE id=?', (old_qid,)).fetchone()[0]
        row = store.db.execute("SELECT id,payload FROM jobs WHERE kind='text_analysis' ORDER BY rowid DESC LIMIT 1").fetchone()
        processor.run_document(json.loads(row['payload'])['document'], row['id'])
        # Source correction invalidates the connected topic, including its old
        # member events. Rebuild those derivations from their retained sources.
        agent.workspace.schedule()
        jobs = store.db.execute("SELECT id,payload FROM jobs WHERE kind='semantic_analysis' AND status='queued' ORDER BY rowid").fetchall()
        for job in jobs:
            processor.run_organization(json.loads(job['payload']), job['id'])
            store.db.execute("UPDATE jobs SET status='completed' WHERE id=?", (job['id'],))
            store.db.commit()
        ask()
        after = agent.state(day='2026-10-21')
        checks = {'old_answer_invalidated': old_answer_status == 'outdated',
                  'old_source_events_removed': old_event_ids.isdisjoint({e['id'] for e in after['events']}),
                  'new_answer_uses_correction': '下周三' in after['answers'][0]['answer'],
                  'cross_record_topic_linked': any(len(t['event_ids']) == 2 for t in after['topics']),
                  'recording_day_preserved': all(e['occurred_at'].startswith('2026-10-') for e in after['events'])}
        if not all(checks.values()):
            raise RuntimeError('Demo did not pass its evidence/correction checks: ' + str(checks))
        result = {'synthetic': True, 'model': 'deterministic_fixture_no_network',
                  'checks': checks, 'before': before, 'after': after}
        (root / 'report.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        write_html(root / 'report.html', result)
        return result
    finally:
        processor.close()
        store.db.close()


def write_html(path, result):
    def panel(state, label):
        rows = []
        for event in sorted(state['events'], key=lambda e: e.get('occurred_at') or ''):
            quotes = ''.join('<blockquote>' + html.escape(s['quote']) + '</blockquote>' for s in event['sources'])
            rows.append('<article><time>' + html.escape(event['occurred_at'].replace('T', ' ')[:16]) +
                        '</time><h3>' + html.escape(event['title']) + '</h3><p>' + html.escape(event['summary']) +
                        '</p><details><summary>查看原句依据</summary>' + quotes + '</details></article>')
        topics = ''.join('<li><strong>' + html.escape(t['title']) + '</strong><p>' + html.escape(t['summary']) +
                         '</p><small>' + str(len(t['event_ids'])) + ' 条关联事件</small></li>' for t in state['topics'])
        answer = state['answers'][0]
        return '<section id="' + label + '"><div><h2>事件时间线</h2>' + ''.join(rows) + \
               '</div><aside><h2>主题进展</h2><ul>' + topics + '</ul><h2>问 Agent</h2><p class="question">现在什么时候交付？</p><p>' + \
               html.escape(answer['answer']) + '</p><small>有效引用 ' + str(len(answer['refs'])) + '</small></aside></section>'
    checks = ''.join('<li>✓ ' + html.escape(k) + '</li>' for k in result['checks'])
    content = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>心力卡 · 离线演示报告</title><style>
*{box-sizing:border-box}body{margin:0;background:#f5f4ef;color:#20372f;font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}main{max-width:1120px;margin:auto;padding:60px 28px}header{border-bottom:1px solid #ccd4c9;padding-bottom:28px}.brand{letter-spacing:3px;font-size:13px;color:#5c7666}h1{font-size:42px;line-height:1.2;letter-spacing:-1px;margin:16px 0}header p{color:#5d6e61;max-width:700px}nav{display:flex;gap:8px;margin:28px 0}button{font:inherit;cursor:pointer;border:1px solid #bacbbd;background:white;color:#294739;padding:10px 18px;border-radius:30px}button[aria-pressed=true]{background:#294739;color:white}section{display:grid;grid-template-columns:1.4fr 1fr;gap:38px}section[hidden]{display:none}h2{font-size:15px;letter-spacing:1px;color:#607466}article{background:#fff;padding:22px 26px;border-radius:14px;margin:15px 0;border:1px solid #e0e4db}h3{font-size:21px;margin:6px 0}time,small{font-size:12px;color:#708273}p{margin:8px 0 16px}details{border-top:1px solid #edf0e9;padding-top:12px;font-size:14px}summary{cursor:pointer;color:#52755e}blockquote{margin:14px 0;padding-left:16px;border-left:2px solid #a7bca7}aside ul{padding:0;list-style:none}aside li{padding:16px 0;border-bottom:1px solid #d9e0d5}.question{background:#e5ebdf;padding:12px 16px;border-radius:12px}.checks{font-size:13px;color:#607466;padding:24px 0;list-style:none;display:flex;flex-wrap:wrap;gap:15px}footer{font-size:13px;color:#768572;border-top:1px solid #ccd4c9;padding-top:20px}@media(max-width:700px){main{padding:30px 20px}h1{font-size:32px}section{grid-template-columns:1fr;gap:12px}}
</style><main><header><div class="brand">XINLIKA / 心力卡</div><h1>让记录，成为持续的上下文。</h1><p>这里展示合成输入与确定性响应经过真实后端后的结果。切换快照，查看一句话纠正如何影响事件、主题和回答。</p></header><nav><button aria-pressed="true" onclick="show('before',this)">纠正前</button><button aria-pressed="false" onclick="show('after',this)">纠正后</button></nav>'''
    content += panel(result['before'], 'before') + panel(result['after'], 'after')
    content += '<ul class="checks">' + checks + '</ul><footer>合成演示 · 无硬件 / 无云端调用 · 这是离线报告，不是实时 App 或模型质量测评。项目：github.com/jingchang0623-crypto/xinlika</footer></main>'
    content += "<script>function show(id,button){document.querySelectorAll('section').forEach(s=>s.hidden=s.id!==id);document.querySelectorAll('button').forEach(b=>b.setAttribute('aria-pressed',String(b===button)))}document.getElementById('after').hidden=true;</script></html>"
    path.write_text(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('.build') / ('demo-' + uuid.uuid4().hex[:8]))
    args = parser.parse_args()
    result = run_demo(args.output)
    print('Synthetic demo: ' + str(sum(result['checks'].values())) + '/5 checks passed; no network model calls.')
    print('Open: ' + str((args.output / 'report.html').resolve()))


if __name__ == '__main__':
    main()

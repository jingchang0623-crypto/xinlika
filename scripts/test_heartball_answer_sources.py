"""Model answer citation repair uses only supplied sources; no real model calls."""
import json
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock

from heartball_processing import ModelAdapter


class AnswerSources(unittest.TestCase):
    def model(self, responses):
        model = ModelAdapter.__new__(ModelAdapter)
        model.model = 'fixture'
        model.extra_body = {}
        model.client = MagicMock()
        model.client.chat.completions.create.side_effect = [SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps(r)))]) for r in responses]
        return model

    def test_missing_raw_record_quote_is_repaired_before_answer_checkpoint(self):
        bad = {'answer': '约14:42提出了问题。', 'refs': [{'id': 'record-1', 'version': 1}]}
        good = {'answer': '约14:42提出了问题。', 'refs': [{'id': 'record-1', 'version': 1, 'quote': '原句不能改写。'}]}
        model = self.model([bad, good])
        result = model.answer('什么时候？', [{'id': 'record-1', 'version': 1, 'record_type': 'record', 'quote': '这是原句不能改写。'}])
        self.assertEqual(result['refs'][0]['quote'], '原句不能改写。')
        self.assertEqual(model.client.chat.completions.create.call_count, 2)

    def test_rephrased_quote_is_never_silently_accepted(self):
        bad = {'answer': '内容', 'refs': [{'id': 'record-1', 'version': 1, 'quote': '修饰后的原文。'}]}
        model = self.model([bad, bad])
        with self.assertRaises(ValueError):
            model.answer('问题', [{'id': 'record-1', 'version': 1, 'record_type': 'record', 'quote': '原始文字。'}])
        self.assertEqual(model.client.chat.completions.create.call_count, 2)

    def test_grounded_event_does_not_require_a_second_raw_quote(self):
        good = {'answer': '事件内容', 'refs': [{'id': 'event-1', 'version': 2}]}
        model = self.model([good])
        self.assertEqual(model.answer('问题', [{'id': 'event-1', 'version': 2, 'record_type': 'event'}])['answer'], '事件内容')
        self.assertEqual(model.client.chat.completions.create.call_count, 1)

    def test_topic_proposal_in_one_recording_is_repaired_instead_of_fabricating_cross_recording_link(self):
        bad = {'topics': [{'title': '相机', 'summary': '标定', 'events': [{'id': 'a', 'version': 1}]}]}
        model = self.model([bad, {'topics': []}])
        context = {'session_id': 'session-1', 'events': [{'id': 'a', 'version': 1, 'session_id': 'session-1'}], 'topics': []}
        self.assertEqual(model.reconcile_topics(context), {'topics': []})
        self.assertEqual(model.client.chat.completions.create.call_count, 2)

    def test_topic_model_cannot_invent_source_event_identity(self):
        bad = {'topics': [{'title': '相机', 'summary': '标定', 'events': [{'id': 'invented', 'version': 1}]}]}
        model = self.model([bad,bad])
        with self.assertRaises(ValueError):
            model.reconcile_topics({'session_id': 's', 'events': [], 'topics': []})


if __name__ == '__main__':
    unittest.main()

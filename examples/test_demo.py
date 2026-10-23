import tempfile
from pathlib import Path
import unittest
from demo import run_demo


class DemoTest(unittest.TestCase):
    def test_real_source_invalidation_and_cross_record_topic(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_demo(Path(directory) / 'demo')
            self.assertTrue(all(result['checks'].values()))
            self.assertIn('下周三', result['after']['answers'][0]['answer'])
            topic = next(t for t in result['after']['topics'] if t['title'] == '云杉演示版交付')
            self.assertIn('下周三', topic['summary'])
            self.assertTrue((Path(directory) / 'demo/report.html').exists())
            with self.assertRaises(ValueError):
                run_demo(Path(directory) / 'demo')


if __name__ == '__main__':
    unittest.main()

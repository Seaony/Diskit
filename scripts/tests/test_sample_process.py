import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('sample_process', Path(__file__).resolve().parents[1] / 'sample-process.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProcessSampleTests(unittest.TestCase):
    def test_ps_cpu_formats(self):
        self.assertAlmostEqual(module.cpu_seconds('01:02.34'), 62.34)
        self.assertEqual(module.cpu_seconds('01:02:03'), 3723)
        self.assertEqual(module.cpu_seconds('2-01:02:03'), 176523)
        with self.assertRaises(ValueError):
            module.cpu_seconds('invalid')

    def test_average_uses_cpu_delta_and_monotonic_elapsed(self):
        report = module.summarize([
            {'monotonic_seconds': 10, 'cpu_seconds': 20, 'rss_bytes': 100},
            {'monotonic_seconds': 310, 'cpu_seconds': 21, 'rss_bytes': 120}])
        self.assertAlmostEqual(report['average_cpu_percent_one_core'], 1 / 3)
        self.assertEqual(report['rss_delta_bytes'], 20)
        self.assertEqual(report['rss_peak_bytes'], 120)

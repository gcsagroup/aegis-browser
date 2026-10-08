"""进程资源统计的正常与失效输入，不启停真实浏览器。"""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('measurement', Path(__file__).with_name('measure-browser-processes.py'))
measurement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurement)


class MeasurementTests(unittest.TestCase):
    def test_cpu_time_units(self):
        self.assertEqual(measurement.cpu_seconds('0:01.25'), 1.25)
        self.assertEqual(measurement.cpu_seconds('123:04.50'), 7384.5)
        self.assertEqual(measurement.cpu_seconds('2-01:02:03'), 176523)
        for value in ['none', '-1:20', '0:60', '1:99:00', '1:02:03:04']:
            with self.assertRaises(ValueError):
                measurement.cpu_seconds(value)

    def test_select_descendants_only(self):
        processes = measurement.parse_processes('10 1 0:01.00 100\n11 10 0:02.00 200\n12 11 0:00.50 50\n20 1 0:50.00 900')
        self.assertEqual(set(measurement.descendants(processes, 10)), {10, 11, 12})
        with self.assertRaises(ValueError):
            measurement.descendants(processes, 999)
        with self.assertRaises(ValueError):
            measurement.parse_processes('10 1 0:01.00 100\n10 1 0:01.00 100')

    def test_cpu_delta_and_process_churn(self):
        before = {'monotonicSeconds': 10, 'processes': {10: {'cpuSeconds': 5, 'rssKiB': 100}}}
        after = {'monotonicSeconds': 12, 'processes': {10: {'cpuSeconds': 5.5, 'rssKiB': 150}}}
        value = measurement.compare_samples(before, after)
        self.assertTrue(value['cohortStable'])
        self.assertEqual(value['cpuPercentOneCore'], 25)
        after['processes'][11] = {'cpuSeconds': 2, 'rssKiB': 50}
        self.assertIsNone(measurement.compare_samples(before, after)['cpuPercentOneCore'])
        del after['processes'][11]
        after['processes'][10]['cpuSeconds'] = 4
        self.assertFalse(measurement.compare_samples(before, after)['cohortStable'])

    def test_no_valid_samples_remains_unknown(self):
        summary = measurement.summarize([{'cohortStable': False, 'summedRssKiB': 123}])
        self.assertIsNone(summary['cpuMeanPercentOneCore'])
        self.assertIsNone(summary['cpuP95PercentOneCore'])
        self.assertEqual(summary['peakSummedRssKiB'], 123)


if __name__ == '__main__':
    unittest.main()

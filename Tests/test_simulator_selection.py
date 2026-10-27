import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("select_simulator", Path(__file__).resolve().parents[1] / "tools" / "select_simulator.py")
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class SimulatorSelectionTests(unittest.TestCase):
    def test_selects_installed_iphone_on_newest_available_ios(self):
        devices = {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                {"name": "iPhone 16", "udid": "older", "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                {"name": "iPhone 17", "udid": "newer", "isAvailable": True}],
        }
        self.assertEqual(selector.choose_device(devices), "newer")

    def test_ignores_unavailable_devices_and_other_platforms(self):
        devices = {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                {"name": "iPhone 17", "udid": "unavailable", "isAvailable": False},
                {"name": "iPad Pro", "udid": "ipad", "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.tvOS-26-0": [
                {"name": "Apple TV", "udid": "tv", "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                {"name": "iPhone 16", "udid": "available", "isAvailable": True}],
        }
        self.assertEqual(selector.choose_device(devices), "available")

    def test_no_matching_simulator_fails_instead_of_skipping_launch_test(self):
        with self.assertRaisesRegex(RuntimeError, "No available iPhone"):
            selector.choose_device({"com.apple.CoreSimulator.SimRuntime.iOS-15-5": [
                {"name": "iPhone 13", "udid": "too-old", "isAvailable": True}]})


if __name__ == "__main__":
    unittest.main()

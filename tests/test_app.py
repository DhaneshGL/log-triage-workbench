import unittest
from unittest.mock import patch

import app


class LogTriageTests(unittest.TestCase):
    def test_loads_valid_sample_events(self):
        events = app.load_events()
        self.assertGreater(len(events), 0)
        self.assertTrue(all({"timestamp", "level", "service", "message"} <= event.keys() for event in events))

    def test_search_filters_by_correlation_id_and_level(self):
        events = app.search_events("pay-7f2", "ERROR")
        self.assertTrue(events)
        self.assertTrue(all(event["correlation_id"] == "pay-7f2" and event["level"] == "ERROR" for event in events))

    def test_search_filters_by_service_case_insensitively(self):
        events = app.search_events(service="PAYMENT-ADAPTER")
        self.assertTrue(events)
        self.assertTrue(all(event["service"] == "payment-adapter" for event in events))

    def test_malformed_log_raises_clear_error(self):
        with patch.object(app, "LOG_PATH") as path:
            path.open.return_value.__enter__.return_value = ["not-json\n"]
            with self.assertRaisesRegex(ValueError, "line 1"):
                app.load_events()


if __name__ == "__main__":
    unittest.main()

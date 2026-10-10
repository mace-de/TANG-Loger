import csv
import tempfile
import unittest
from pathlib import Path

from restore_csv import restore_csv


class RestoreCsvTest(unittest.TestCase):
    def test_fault_temperature_bits_are_separate_from_valid_temperature(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "source.csv"
            destination = Path(folder) / "restored.csv"
            fields = ["session", "elapsed_s", "sequence", "temperature_c",
                      "internal_c", "fault_open", "fault_short_gnd",
                      "fault_short_vcc", "raw_hex"]
            with source.open("w", newline="", encoding="utf-8") as stream:
                writer = csv.writer(stream)
                writer.writerow(fields)
                writer.writerows([
                    [1, 1, 0, "24.75", "29.6250", 0, 0, 0, "0x018C1DA0"],
                    [1, 2, 1, "", "17.5625", 0, 1, 0, "0x00BD1192"],
                    [1, 3, 2, "", "31.5625", 1, 0, 0, "0x7FFD1F91"],
                ])
            counts = restore_csv(source, destination)
            with destination.open(newline="", encoding="utf-8") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(counts["valid"], 1)
            self.assertEqual(counts["fault_raw_candidate"], 1)
            self.assertEqual(counts["open_no_temperature"], 1)
            self.assertEqual([r["temperature_candidate_c"] for r in rows],
                             ["24.75", "11.75", ""])
            self.assertEqual([r["temperature_c"] for r in rows], ["24.75", "", ""])


if __name__ == "__main__":
    unittest.main()

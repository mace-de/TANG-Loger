import struct
import unittest
from unittest.mock import MagicMock, patch

from templog import CHECK_XOR, RECORD_MAGIC, decode_record, main


class RecordTest(unittest.TestCase):
    def test_negative_temperature_and_fault(self):
        # -10.25 C in 14-bit quarter-degree format.
        raw = ((-41 & 0x3FFF) << 18) | (25 << 4)
        fields = [RECORD_MAGIC, 0, raw, 2, 1, 123]
        check = CHECK_XOR
        for field in fields:
            check ^= field
        decoded = decode_record(struct.pack("<7I", *fields, check), 0, 123)
        self.assertEqual(decoded[:5], [2, 1, 0, "-10.25", "1.5625"])
        broken = bytearray(struct.pack("<7I", *fields, check))
        broken[8] ^= 1
        with self.assertRaises(ValueError):
            decode_record(bytes(broken), 0, 123)

        raw |= (1 << 16) | 1
        fields[2] = raw
        check = CHECK_XOR
        for field in fields:
            check ^= field
        decoded = decode_record(struct.pack("<7I", *fields, check), 0, 123)
        self.assertEqual(decoded[3], "")
        self.assertEqual(decoded[5], 1)

    def test_clear_uses_guarded_command_and_waits_for_empty_log(self):
        port = MagicMock()
        port.__enter__.return_value = port
        responses = [(1, 1930240, 26, 0, 0, 0),
                     (1, 1930240, 0, 0, 0, 0)]
        with (patch("templog.serial.Serial", return_value=port),
              patch("templog.read_info", side_effect=responses),
              patch("templog.secrets.randbits", return_value=0x12345678),
              patch("templog.time.sleep"),
              patch("sys.argv", ["templog.py", "clear", "--yes"])):
            self.assertEqual(main(), 0)
        port.write.assert_called_once_with(b"C!\x78\x56\x34\x12")

    def test_clear_rejects_running_log(self):
        port = MagicMock()
        port.__enter__.return_value = port
        with (patch("templog.serial.Serial", return_value=port),
              patch("templog.read_info", return_value=(2, 1930240, 26, 0, 0, 0)),
              patch("sys.argv", ["templog.py", "clear", "--yes"])):
            with self.assertRaises(RuntimeError):
                main()
        port.write.assert_not_called()


if __name__ == "__main__":
    unittest.main()

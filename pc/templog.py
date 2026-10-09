#!/usr/bin/env python3
"""Tang Nano 9K logger: inspect, initialize, clear and export CSV."""
from __future__ import annotations

import argparse
import csv
import hashlib
import os
import secrets
import shutil
import struct
import sys
import time
from pathlib import Path

import serial

RECORD_MAGIC = 0x474F4C54
CHECK_XOR = 0xA56C29D3


def read_exact(port: serial.Serial, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        chunk = port.read(length - len(result))
        if not chunk:
            raise TimeoutError(f"USB-Antwort unvollständig: {len(result)}/{length} Bytes")
        result.extend(chunk)
    return bytes(result)


def read_info(port: serial.Serial) -> tuple[int, int, int, int, int, int]:
    port.reset_input_buffer()
    port.write(b"I")
    data = read_exact(port, 16)
    if data[:4] != b"TINF":
        raise ValueError(f"Unerwartete Statusantwort: {data!r}")
    status = data[4]
    capacity, count = struct.unpack_from("<II", data, 8)
    return status, capacity, count, data[5], data[6], data[7]


def signed(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


def decode_record(data: bytes, expected_seq: int, generation: int) -> list[object]:
    if len(data) != 28:
        raise ValueError("Unvollständiger Datensatz")
    magic, seq, raw, session, seconds, record_gen, check = struct.unpack("<7I", data)
    expected_check = magic ^ seq ^ raw ^ session ^ seconds ^ record_gen ^ CHECK_XOR
    if (magic != RECORD_MAGIC or seq != expected_seq or
            record_gen != generation or check != expected_check):
        raise ValueError(f"Datensatz {expected_seq} beschädigt oder vertauscht")
    fault = bool(raw & (1 << 16))
    temp_quarters = signed((raw >> 18) & 0x3FFF, 14)
    internal_sixteenths = signed((raw >> 4) & 0xFFF, 12)
    return [session, seconds, seq, "" if fault else f"{temp_quarters / 4:.2f}",
            f"{internal_sixteenths / 16:.4f}", int(bool(raw & 1)),
            int(bool(raw & 2)), int(bool(raw & 4)), f"0x{raw:08X}"]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def backup_card(port: serial.Serial, destination: Path, capacity: int) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".partial")
    already = partial.stat().st_size if partial.exists() else 0
    if already % 512 or already > capacity * 512:
        raise ValueError(f"Teil-Image hat ungültige Größe: {partial}")
    free = shutil.disk_usage(destination.parent).free
    if free < capacity * 512 - already + 1024 * 1024:
        raise OSError("Nicht genug freier Platz für das Karten-Image.")
    start = already // 512
    if start:
        print(f"Sicherung wird ab Sektor {start:,} fortgesetzt.")
    with partial.open("ab") as output:
        for lba in range(start, capacity):
            for attempt in range(3):
                try:
                    port.reset_input_buffer()
                    port.write(b"B" + struct.pack("<I", lba))
                    response = read_exact(port, 524)
                    if response[:4] != b"BLK0" or struct.unpack_from("<I", response, 4)[0] != lba:
                        raise ValueError(f"Sektor {lba}: falscher Antwortkopf")
                    sector = response[8:520]
                    words = struct.unpack("<128I", sector)
                    check = 0
                    for word in words:
                        check ^= word
                    if check != struct.unpack_from("<I", response, 520)[0]:
                        raise ValueError(f"Sektor {lba}: Prüfsumme falsch")
                    output.write(sector)
                    break
                except (TimeoutError, ValueError):
                    if attempt == 2:
                        raise
            if lba % 8192 == 0:
                output.flush()
                print(f"{lba:,}/{capacity:,} Sektoren", file=sys.stderr, end="\r")
        output.flush()
        os.fsync(output.fileno())
    os.replace(partial, destination)
    digest = sha256_file(destination)
    sidecar = destination.with_name(destination.name + ".sha256")
    sidecar.write_text(digest + "\n", encoding="ascii")
    print(f"Karte vollständig gesichert: {destination}")
    print(f"SHA-256: {digest}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="COM9", help="USB-UART-Port, z. B. COM9")
    parser.add_argument("--baud", type=int, default=3000000)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status", help="Karte und Datensatzanzahl anzeigen")
    commands.add_parser("start", help="Aufzeichnung über USB starten (wie S1)")
    commands.add_parser("stop", help="Aufzeichnung über USB stoppen (wie S2)")
    clear = commands.add_parser("clear", help="Alle Logger-Messungen auf der Karte verwerfen")
    clear.add_argument("--yes", action="store_true", help="Löschung ohne Rückfrage bestätigen")
    init = commands.add_parser("init", help="Karte exklusiv für den Logger vorbereiten")
    init.add_argument("--backup-file", required=True, type=Path,
                      help="Vollständiges, geprüftes Karten-Image aus 'backup'")
    backup = commands.add_parser("backup", help="Komplette Karte nur lesend sichern")
    backup.add_argument("image", type=Path)
    export = commands.add_parser("export", help="Aufzeichnung als CSV speichern")
    export.add_argument("csv", type=Path)
    args = parser.parse_args()

    with serial.Serial(args.port, args.baud, timeout=5, write_timeout=5) as port:
        if args.command in ("start", "stop"):
            status, _, count, _, _, _ = read_info(port)
            if args.command == "start" and status != 1:
                raise RuntimeError("Start nur bei bereiter Karte möglich.")
            if args.command == "stop" and status != 2:
                raise RuntimeError("Es läuft keine Aufzeichnung.")
            port.write(b"R" if args.command == "start" else b"T")
            time.sleep(0.05)
            new_status, _, _, _, _, _ = read_info(port)
            if new_status != (2 if args.command == "start" else 1):
                raise RuntimeError("Signal wurde vom Logger nicht bestätigt.")
            print("Aufzeichnung läuft." if args.command == "start" else "Aufzeichnung gestoppt.")
            return 0
        if args.command == "status":
            status, capacity, count, stage, response, command = read_info(port)
            names = {0: "nicht initialisiert", 1: "bereit", 2: "zeichnet auf",
                     3: "SD-Fehler", 4: "SD-Start läuft"}
            print(f"Status: {names.get(status, f'Fehler {status}')}")
            print(f"Kapazität: {capacity * 512:,} Byte ({capacity:,} Sektoren)")
            print(f"Datensätze: {count:,}")
            if status == 3:
                print(f"SD-Diagnose: Stadium {stage}, CMD{command}, Antwort 0x{response:02X}")
            return 0

        if args.command == "init":
            status, capacity, count, _, _, _ = read_info(port)
            if status == 2:
                raise RuntimeError("Aufzeichnung läuft. Erst S2 drücken.")
            if count != 0:
                raise RuntimeError("Logger enthält Messdaten. Erst exportieren; Initialisierung gesperrt.")
            if capacity < 3:
                raise RuntimeError("Keine geeignete SD-Karte erkannt.")
            backup_file = args.backup_file
            if not backup_file.is_file() or backup_file.stat().st_size != capacity * 512:
                raise ValueError("Sicherungs-Image fehlt oder hat nicht die volle Kartengröße.")
            sidecar = backup_file.with_name(backup_file.name + ".sha256")
            if not sidecar.is_file() or sha256_file(backup_file) != sidecar.read_text().strip():
                raise ValueError("SHA-256-Prüfung des Sicherungs-Images fehlgeschlagen.")
            nonce = secrets.randbits(32) or 1
            port.write(b"F!" + struct.pack("<I", nonce))
            print("Logger-Kennung wird auf Sektor 0 und 1 geschrieben.")
            # The firmware does not send an ACK; poll after its two block writes.
            for _ in range(10):
                time.sleep(0.3)
                try:
                    status, _, count, _, _, _ = read_info(port)
                except (TimeoutError, ValueError):
                    continue
                if status == 1 and count == 0:
                    print("Karte bereit. S1 startet die Aufzeichnung.")
                    return 0
            raise TimeoutError("Initialisierung nicht bestätigt. Status erneut abfragen.")

        if args.command == "clear":
            status, _, count, _, _, _ = read_info(port)
            if status != 1:
                raise RuntimeError("Löschen nur bei gestoppter, initialisierter Karte möglich.")
            if count == 0:
                print("Keine Messdaten auf der Karte.")
                return 0
            if not args.yes:
                if not sys.stdin.isatty():
                    raise RuntimeError("Bestätigung fehlt; interaktiv starten oder --yes angeben.")
                answer = input(f"{count:,} Messwerte auf der SD-Karte löschen? 'ja' eingeben: ")
                if answer.strip().lower() != "ja":
                    print("Abgebrochen; Messdaten unverändert.")
                    return 0
            nonce = secrets.randbits(32) or 1
            port.write(b"C!" + struct.pack("<I", nonce))
            for _ in range(10):
                time.sleep(0.3)
                try:
                    new_status, _, new_count, _, _, _ = read_info(port)
                except (TimeoutError, ValueError):
                    continue
                if new_status == 1 and new_count == 0:
                    print("Messdaten gelöscht. Karte bereit für eine neue Aufnahme.")
                    return 0
                if new_status == 3:
                    raise RuntimeError("SD-Fehler beim Löschen; Status prüfen.")
            raise TimeoutError("Löschen nicht bestätigt. Status erneut abfragen.")

        if args.command == "backup":
            status, capacity, _, _, _, _ = read_info(port)
            if status == 2:
                raise RuntimeError("Aufzeichnung läuft. Erst S2 drücken.")
            if capacity < 3:
                raise RuntimeError("Keine geeignete SD-Karte erkannt.")
            backup_card(port, args.image, capacity)
            return 0

        status, _, expected_count, _, _, _ = read_info(port)
        if status != 1:
            raise RuntimeError("Export nur bei gestoppter, initialisierter Karte möglich.")
        port.reset_input_buffer()
        port.write(b"D")
        header = read_exact(port, 12)
        if header[:4] != b"TLOG":
            raise ValueError(f"Unerwarteter Exportanfang: {header!r}")
        count, generation = struct.unpack_from("<II", header, 4)
        if count != expected_count:
            raise RuntimeError("Datensatzanzahl hat sich geändert. Aufzeichnung stoppen.")
        output = args.csv
        output.parent.mkdir(parents=True, exist_ok=True)
        temp = output.with_name(output.name + ".partial")
        try:
            with temp.open("w", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)
                writer.writerow(["session", "elapsed_s", "sequence", "temperature_c",
                                 "internal_c", "fault_open", "fault_short_gnd",
                                 "fault_short_vcc", "raw_hex"])
                for seq in range(count):
                    writer.writerow(decode_record(read_exact(port, 28), seq, generation))
                    if seq and seq % 1000 == 0:
                        print(f"{seq:,}/{count:,}", file=sys.stderr, end="\r")
            os.replace(temp, output)
        except Exception:
            print(f"Teil-Datei verbleibt unter {temp}", file=sys.stderr)
            raise
        print(f"{count:,} Messungen exportiert: {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, TimeoutError,
            serial.SerialException) as exc:
        print(f"Fehler: {exc}", file=sys.stderr)
        raise SystemExit(1)

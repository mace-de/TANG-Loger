#!/usr/bin/env python3
"""Expose MAX31855 temperature bits from fault-marked logger records.

The candidate value is not a validated thermocouple measurement when a sensor
fault is active. The original temperature_c column is preserved unchanged.
"""
from __future__ import annotations

import argparse
import csv
import os
from collections import Counter
from pathlib import Path

from templog import signed


def restore_csv(source: Path, destination: Path) -> Counter[str]:
    if source.resolve() == destination.resolve():
        raise ValueError("Quelldatei und Zieldatei müssen verschieden sein")
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".partial")
    summary: Counter[str] = Counter()
    previous: dict[str, str] | None = None
    try:
        with source.open("r", newline="", encoding="utf-8") as input_file, \
                partial.open("w", newline="", encoding="utf-8") as output_file:
            reader = csv.DictReader(input_file)
            required = {"session", "elapsed_s", "sequence", "temperature_c",
                        "internal_c", "fault_open", "fault_short_gnd",
                        "fault_short_vcc", "raw_hex"}
            if not required.issubset(reader.fieldnames or []):
                raise ValueError("CSV enthält nicht alle Logger-Spalten")
            writer = csv.DictWriter(
                output_file,
                fieldnames=[*reader.fieldnames, "temperature_candidate_c", "recovery_status"],
            )
            writer.writeheader()
            for row in reader:
                raw = int(row["raw_hex"], 16)
                seq = int(row["sequence"])
                if previous is None and seq != 0:
                    raise ValueError("CSV beginnt nicht mit Datensatz 0")
                if previous is not None:
                    if seq != int(previous["sequence"]) + 1:
                        raise ValueError(f"Lücke vor Datensatz {seq}")
                    if row["session"] == previous["session"] and \
                            int(row["elapsed_s"]) != int(previous["elapsed_s"]) + 1:
                        raise ValueError(f"Zeitlücke vor Datensatz {seq}")
                if raw & ((1 << 17) | (1 << 3)):
                    raise ValueError(f"Reserviertes Sensorbit in Datensatz {seq} gesetzt")
                flags = [int(row[name]) for name in
                         ("fault_open", "fault_short_gnd", "fault_short_vcc")]
                if flags != [int(bool(raw & bit)) for bit in (1, 2, 4)] or \
                        bool(raw & (1 << 16)) != bool(any(flags)):
                    raise ValueError(f"Sensor-Fehlerbits in Datensatz {seq} widersprüchlich")
                quarters = signed((raw >> 18) & 0x3FFF, 14)
                candidate = f"{quarters / 4:.2f}"
                if flags[0]:
                    row["temperature_candidate_c"] = ""
                    row["recovery_status"] = "open_no_temperature"
                elif flags[1] or flags[2]:
                    row["temperature_candidate_c"] = candidate
                    row["recovery_status"] = "fault_raw_candidate"
                else:
                    if row["temperature_c"] != candidate:
                        raise ValueError(f"Temperatur in Datensatz {seq} widersprüchlich")
                    row["temperature_candidate_c"] = candidate
                    row["recovery_status"] = "valid"
                summary[row["recovery_status"]] += 1
                writer.writerow(row)
                previous = row
        os.replace(partial, destination)
    except Exception:
        partial.unlink(missing_ok=True)
        raise
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Original-CSV des Loggers")
    parser.add_argument("destination", type=Path, help="Neue CSV mit Kandidaten-Spalte")
    args = parser.parse_args()
    summary = restore_csv(args.source, args.destination)
    print(f"Restaurierte CSV: {args.destination}")
    for name, count in summary.items():
        print(f"{name}: {count:,}")


if __name__ == "__main__":
    main()

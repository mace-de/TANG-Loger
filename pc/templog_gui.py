#!/usr/bin/env python3
"""Small Windows GUI for the Tang Nano 9K temperature logger."""
from __future__ import annotations

import queue
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from serial.tools import list_ports


ROOT = Path(__file__).resolve().parent.parent
CLI = Path(__file__).with_name("templog.py")


class LoggerWindow(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Tang Nano 9K – Temperatur-Logger")
        self.geometry("720x470")
        self.minsize(610, 380)
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()
        self.process: subprocess.Popen[str] | None = None
        self.busy = False
        self.cancel_requested = False
        self.port = tk.StringVar(value="COM9")
        self.state_text = tk.StringVar(value="Bereit")

        top = ttk.Frame(self, padding=12)
        top.pack(fill="x")
        ttk.Label(top, text="USB-Port:").pack(side="left")
        self.port_box = ttk.Combobox(top, textvariable=self.port, width=14)
        self.port_box.pack(side="left", padx=(8, 8))
        ttk.Button(top, text="Ports suchen", command=self.refresh_ports).pack(side="left")

        actions = ttk.Frame(self, padding=(12, 0, 12, 8))
        actions.pack(fill="x")
        self.action_buttons: list[ttk.Button] = []
        for index, (label, action) in enumerate((
            ("Status", self.show_status),
            ("Start", self.start_log),
            ("Stop", self.stop_log),
            ("CSV exportieren", self.export_csv),
            ("Messdaten löschen", self.clear_log),
            ("Karte sichern", self.backup_card),
            ("Karte initialisieren", self.init_card),
        )):
            button = ttk.Button(actions, text=label, command=action)
            button.grid(row=index // 4, column=index % 4, sticky="ew", padx=(0, 6), pady=4)
            self.action_buttons.append(button)
        for column in range(4):
            actions.columnconfigure(column, weight=1)

        body = ttk.Frame(self, padding=(12, 0, 12, 8))
        body.pack(fill="both", expand=True)
        self.output = tk.Text(body, wrap="word", state="disabled", font=("Consolas", 10))
        scroll = ttk.Scrollbar(body, orient="vertical", command=self.output.yview)
        self.output.configure(yscrollcommand=scroll.set)
        self.output.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")

        bottom = ttk.Frame(self, padding=(12, 0, 12, 12))
        bottom.pack(fill="x")
        ttk.Label(bottom, textvariable=self.state_text).pack(side="left")
        self.cancel_button = ttk.Button(bottom, text="Abbrechen", command=self.cancel)
        self.cancel_button.pack(side="right")
        self.cancel_button.state(["disabled"])

        self.refresh_ports()
        self.protocol("WM_DELETE_WINDOW", self.close_window)
        self.after(100, self.drain_events)
        self.after(250, self.show_status)

    def refresh_ports(self) -> None:
        names = [entry.device for entry in list_ports.comports()]
        self.port_box["values"] = names
        if self.port.get() not in names and names:
            self.port.set("COM9" if "COM9" in names else names[0])

    def append(self, value: str) -> None:
        self.output.configure(state="normal")
        self.output.insert("end", value)
        self.output.see("end")
        self.output.configure(state="disabled")

    def run_command(self, command: str, *args: str, cancellable: bool = False) -> None:
        if self.busy:
            return
        port = self.port.get().strip()
        if not port:
            messagebox.showerror("USB-Port fehlt", "Bitte einen COM-Port auswählen.", parent=self)
            return
        self.busy = True
        self.cancel_requested = False
        self.state_text.set(f"{command} läuft …")
        for button in self.action_buttons:
            button.state(["disabled"])
        if cancellable:
            self.cancel_button.state(["!disabled"])
        self.append(f"\n> {command} ({port})\n")
        thread = threading.Thread(
            target=self.worker, args=(port, command, args), daemon=True
        )
        thread.start()

    def worker(self, port: str, command: str, args: tuple[str, ...]) -> None:
        interpreter = Path(sys.executable)
        if interpreter.name.lower() == "pythonw.exe":
            interpreter = interpreter.with_name("python.exe")
        argv = [str(interpreter), "-u", str(CLI), "--port", port, command, *args]
        creationflags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
        try:
            process = subprocess.Popen(
                argv, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                errors="replace", bufsize=1, creationflags=creationflags,
            )
            self.process = process
            if self.cancel_requested:
                process.terminate()
            assert process.stdout is not None
            line = ""
            while True:
                char = process.stdout.read(1)
                if not char:
                    break
                if char in "\r\n":
                    if line:
                        self.events.put(("text", line + "\n"))
                        line = ""
                else:
                    line += char
            if line:
                self.events.put(("text", line + "\n"))
            code = process.wait()
            self.events.put(("done", (command, code)))
        except OSError as exc:
            self.events.put(("text", f"Fehler: {exc}\n"))
            self.events.put(("done", (command, 1)))
        finally:
            self.process = None

    def drain_events(self) -> None:
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == "text":
                    self.append(str(value))
                elif kind == "done":
                    command, code = value
                    self.busy = False
                    self.state_text.set("Bereit" if code == 0 else f"{command}: Fehler")
                    for button in self.action_buttons:
                        button.state(["!disabled"])
                    self.cancel_button.state(["disabled"])
                    if code == 0 and command in ("start", "stop", "clear", "init"):
                        self.after(100, self.show_status)
        except queue.Empty:
            pass
        self.after(100, self.drain_events)

    def cancel(self) -> None:
        self.cancel_requested = True
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            self.append("Abbruch angefordert. Eine Teil-Datei kann erhalten bleiben.\n")

    def close_window(self) -> None:
        if self.busy:
            messagebox.showinfo(
                "Vorgang läuft", "Bitte warten oder den Vorgang mit 'Abbrechen' beenden.",
                parent=self,
            )
        else:
            self.destroy()

    def show_status(self) -> None:
        self.run_command("status")

    def start_log(self) -> None:
        self.run_command("start")

    def stop_log(self) -> None:
        self.run_command("stop")

    def export_csv(self) -> None:
        if self.busy:
            return
        path = filedialog.asksaveasfilename(
            parent=self, title="CSV speichern", initialdir=ROOT / "logs",
            defaultextension=".csv", filetypes=[("CSV-Datei", "*.csv")],
        )
        if path:
            self.run_command("export", path, cancellable=True)

    def clear_log(self) -> None:
        if self.busy:
            return
        if messagebox.askyesno(
            "Messdaten löschen",
            "Alle Logger-Messwerte auf der SD-Karte löschen?\n"
            "Vorher bei Bedarf als CSV exportieren. Dieser Schritt kann nicht rückgängig gemacht werden.",
            icon="warning", parent=self,
        ):
            self.run_command("clear", "--yes")

    def backup_card(self) -> None:
        if self.busy:
            return
        path = filedialog.asksaveasfilename(
            parent=self, title="Karten-Image speichern", initialdir=ROOT / "backup",
            defaultextension=".img", filetypes=[("Karten-Image", "*.img")],
        )
        if path:
            self.run_command("backup", path, cancellable=True)

    def init_card(self) -> None:
        if self.busy:
            return
        path = filedialog.askopenfilename(
            parent=self, title="Geprüftes Karten-Image auswählen",
            initialdir=ROOT / "backup", filetypes=[("Karten-Image", "*.img")],
        )
        if path and messagebox.askyesno(
            "Karte initialisieren",
            "Die Karte wird für den Logger vorbereitet. Das Programm prüft zuvor "
            "das vollständige Image und seine SHA-256-Datei. Fortfahren?",
            icon="warning", parent=self,
        ):
            self.run_command("init", "--backup-file", path)


if __name__ == "__main__":
    LoggerWindow().mainloop()

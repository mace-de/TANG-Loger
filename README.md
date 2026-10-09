# Tang Nano 9K Temperatur-Logger

Der Tang Nano 9K liest einen **MAX31855K** mit Typ-K-Thermoelement einmal pro
Sekunde. **S1** startet, **S2** stoppt. Messwerte liegen auf der eingesetzten
microSD-Karte; `pc/templog.py export` überträgt sie über den USB-Seriell-Port
als CSV auf den PC.

## SD-Karte und Datensicherheit

Die erste Initialisierung macht die SD-Karte **exklusiv** zur Logger-Karte.
Windows erkennt danach kein FAT-Dateisystem mehr. Das PC-Programm akzeptiert
`init` deshalb nur mit einem Image der vollen Kartengröße und passender
SHA-256-Datei. Bis zu diesem Schritt liest die FPGA-Firmware die Karte nur;
S1 kann auf einer nicht initialisierten Karte keine Aufzeichnung starten.

Vor der ersten Initialisierung vorhandene Dateien sichern. `backup IMAGE.img`
liest die Karte dafür vollständig über USB. Das Image und die Messdaten bleiben
lokal; die Verzeichnisse `backup/` und `logs/` sind vom Git-Repository
ausgeschlossen.

## Hardware

| Signal | FPGA-Pin | Hinweis |
| --- | ---: | --- |
| MAX31855 SCK | 32 | Ausgang |
| MAX31855 CS | 31 | Ausgang, aktiv Low |
| MAX31855 DO/SO | 49 | Eingang |
| MAX31855 VCC | 3,3 V | Keine 5 V an FPGA-Eingänge |
| MAX31855 GND | GND | Gemeinsame Masse |
| SD SCK/MOSI/CS/MISO | 36/37/38/39 | Steckplatz auf dem Board |
| S1/S2 | 4/3 | Taster aktiv Low |
| USB-UART TX/RX | 17/18 | Über den Board-USB-Anschluss |

Der MAX31855 muss die **K-Variante** sein. Pin 49 wird auf dem Board auch zum
optionalen SPI-Display geführt; dieses sollte dabei nicht angeschlossen sein.
Die Pinbelegung folgt dem
[Sipeed-Schaltplan](https://dl.sipeed.com/fileList/TANG/Nano%209K/2_Schematic/Tang_Nano_9k_3672_Schematic.pdf).
Das [MAX31855-Datenblatt](https://www.analog.com/media/en/technical-documentation/data-sheets/MAX31855.pdf)
beschreibt das 32-Bit-Datenwort und die Fehlerbits.

## Bedienung unter Windows

Python und `pyserial` werden benötigt. Unter Windows installieren mit
`python -m pip install -r requirements.txt`. Die folgenden Befehle verwenden
**COM9** als Beispiel; bei einer anderen Portnummer `--port COMx` angeben.

Die grafische Oberfläche starten mit:

```powershell
pythonw pc\templog_gui.py
```

Sie bietet Status, Start, Stop, CSV-Export, Löschen der Messdaten sowie
Kartensicherung und Initialisierung. Bei `Messdaten löschen` fragt sie vor dem
Löschen nach. Der COM-Port ist oben auswählbar. Eine längere Sicherung lässt
sich abbrechen und später über ihre `.partial`-Datei fortsetzen.

```powershell
python pc\templog.py --port COM9 status
python pc\templog.py --port COM9 backup backup\sdcard.img
python pc\templog.py --port COM9 init --backup-file backup\sdcard.img
```

`backup` erstellt vor `init` ein vollständiges, physisches Karten-Image über
USB. Das dauert bei 1 GB ungefähr zwei Stunden. Es schreibt zunächst eine `.partial`-Datei
und kann eine unterbrochene Übertragung fortsetzen. `init` prüft Dateigröße
und SHA-256, bevor es die Logger-Kennung in die ersten zwei SD-Sektoren schreibt.

Danach S1 drücken. Die erste Messung erfolgt nach einer Sekunde; LED 0
leuchtet während der Aufzeichnung. S2 stoppt, anschließend wird
der letzte Stand gesichert. LED 1 zeigt eine noch nicht
initialisierte Karte oder einen SD-Fehler an.

```powershell
python pc\templog.py --port COM9 status
python pc\templog.py --port COM9 export logs\temperatur.csv
python pc\templog.py --port COM9 clear
```

Für Tests können die Befehle `start` und `stop` die beiden Taster über USB
auslösen, zum Beispiel `python pc/templog.py --port COM9 start`.
`clear` fragt nach einer Bestätigung; für Skripte gibt es `clear --yes`.
Der Befehl setzt Datensatz- und Sitzungszähler zurück und schreibt beide
Kontrollsektoren mit einer neuen Kennung. Die bisherigen Messungen sind danach
über den Logger nicht mehr erreichbar; alte Sektorinhalte werden dabei nicht
physisch überschrieben. Vor dem Löschen bei Bedarf als CSV exportieren.

Die CSV enthält laufende Nummer, Sitzungsnummer, Sekunden seit S1,
Thermoelement- und interne Vergleichsstellentemperatur sowie die drei
Sensorfehler (offen, Kurzschluss gegen GND/VCC). Bei einem Sensorfehler bleibt
das Feld `temperature_c` leer. Der Tang Nano 9K besitzt hier keine Echtzeituhr;
absolute Datum/Uhrzeit werden nicht aufgezeichnet.

## Technische Einzelheiten

- Eine Messung belegt einen 512-Byte-Sektor. Das vermeidet das Umschreiben
  bereits protokollierter Messungen. Zwei wechselnde Kontrollsektoren halten
  den letzten Stand; sie werden alle 1024 Messungen und beim Stop aktualisiert.
- Nach einem Stromausfall sucht der Logger ab dem letzten Kontrollpunkt
  vollständig geschriebene Datensätze und setzt dort fort.
- SD-Karten der älteren SDSC-Bauart sowie SDHC/SDXC werden im SPI-Modus
  angesprochen. Die Initialisierung läuft mit 397 kHz, Datenzugriffe mit
  3,375 MHz.
- Die Karte ist nach `init` kein FAT-Datenträger. Zum Zurückspielen eines
  gesicherten Images ist ein Kartenleser oder eine gesonderte
  Wiederherstellungsfunktion nötig.
- Die Datenübertragung über USB ist ein serielles Protokoll mit 3 Mbit/s,
  kein USB-Massenspeicher.

## Bauen und Prüfen

`build.tcl` baut den Bitstream mit Gowin EDA für
`GW1NR-LV9QN88PC6/I5`; Ergebnis:
`build/impl/pnr/project.fs`. `clock.sdc` gibt 27 MHz vor.

```powershell
& 'C:\Gowin\Gowin_V1.9.8.11_Education\IDE\bin\gw_sh.exe' build.tcl
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s sd_spi_tb -o sim\sdhc_tb.vvp sim\sd_spi_tb.v rtl\sd_spi.v rtl\spi_byte.v
& 'C:\iverilog\bin\vvp.exe' sim\sdhc_tb.vvp
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s sd_spi_tb '-Psd_spi_tb.OLD_CARD=1' -o sim\sdsc_tb.vvp sim\sd_spi_tb.v rtl\sd_spi.v rtl\spi_byte.v
& 'C:\iverilog\bin\vvp.exe' sim\sdsc_tb.vvp
& 'C:\iverilog\bin\iverilog.exe' -g2012 -s templog_tb -o sim\templog_tb.vvp sim\templog_tb.v sim\sd_spi_stub.v rtl\templog.v rtl\button.v rtl\uart.v rtl\max31855_reader.v
& 'C:\iverilog\bin\vvp.exe' sim\templog_tb.vvp
python -m unittest discover -s pc -p 'test_*.py'
```

Zum vorübergehenden Laden in das FPGA-SRAM (Pfade und Kabelnummer anpassen):

```powershell
& 'C:\Gowin\Gowin_V1.9.8.11_Education\Programmer1\bin\programmer_cli.exe' --device GW1NR-9C --operation_index 2 --fsFile 'build\impl\pnr\project.fs' --cable-index 1 --location 289
```

Für dauerhaftes Programmieren des integrierten FPGA-Flash dient bei
`Programmer1` die Operation `--operation_index 5`; `--operation_index 1`
startet danach aus dem Flash neu. Auf dem getesteten Tang Nano 9K wurden
S1/S2, SD-Aufzeichnung, USB-Export und ein Neustart erfolgreich geprüft.

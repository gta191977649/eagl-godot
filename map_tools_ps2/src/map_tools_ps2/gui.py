"""Small Tk GUI for the HP2 PS2 map exporter.

The GUI deliberately delegates the actual work to the existing CLI entry point
so command-line and GUI exports use the same parser and implementation.
"""

from __future__ import annotations

import contextlib
import json
import os
import queue
import re
import shutil
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from .cli import main as cli_main
from .progress import progress_context
from .race_catalog import FAMILIES, TRACK_IDS


PROJECT_ROOT = Path(__file__).resolve().parents[2]


_BATCH_MODES = ("All Tracks (standalone MTA)", "All Family Packs")


TRACK_GROUPS = (
    (range(11, 17), "Parkland"),
    (range(21, 27), "Dessert"),
    (range(31, 37), "Medit"),
    (range(41, 47), "Alpine"),
    (range(61, 67), "Tropic"),
)


def _track_display_name(track_number: str) -> str:
    try:
        number = int(track_number)
    except ValueError:
        return track_number
    for numbers, name in TRACK_GROUPS:
        if number in numbers:
            return f"{number:02d} ({name})"
    return track_number


def _settings_path() -> Path:
    app_data = os.environ.get("APPDATA")
    base = Path(app_data) if app_data else Path.home() / ".config"
    return base / "map_tools_ps2" / "gui.json"


class _QueueStream:
    def __init__(self, events: queue.Queue[tuple[str, object]]) -> None:
        self.events = events

    def write(self, text: str) -> int:
        if text:
            try:
                # Export output is informational. Never block the worker when the
                # GUI is briefly slower than a verbose exporter.
                self.events.put_nowait(("log", text))
            except queue.Full:
                pass
        return len(text)

    def flush(self) -> None:
        return None


class ExportGui:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("NFS HP2 PS2 Map Exporter")
        self.root.minsize(900, 620)
        self.settings_file = _settings_path()
        self.events: queue.Queue[tuple[str, object]] = queue.Queue(maxsize=2048)
        self.worker: threading.Thread | None = None
        self._progress_lock = threading.Lock()
        self._latest_progress: tuple[str, int, int | None, str] | None = None
        self._closed = False
        self.output_history: list[str] = []

        self.game_dir = tk.StringVar()
        self.output_dir = tk.StringVar()
        self.frontend_dir = tk.StringVar()
        self.frontend_output_dir = tk.StringVar()
        self.global_dir = tk.StringVar()
        self.global_output_dir = tk.StringVar()
        self.sound_dir = tk.StringVar()
        self.sound_output_dir = tk.StringVar()
        self.sound_workers = tk.StringVar(value="0")
        self.track = tk.StringVar()
        self.resource_name = tk.StringVar()
        self.skybox_subdir = tk.StringVar(value="skybox")
        self.export_type = tk.StringVar(value="MTA Resource")
        # Deliberately not persisted: ordinary Eagle exports are the default.
        self.export_packed = tk.BooleanVar(value=False)
        self.author = tk.StringVar(value="map_tools_ps2")
        self.collision = tk.StringVar(value="model")
        self.native_collision = tk.StringVar(value="auto")
        self.lod_mode = tk.StringVar(value="auto")
        self.vertex_colors = tk.StringVar(value="always")
        self.chunk_size = tk.StringVar(value="300")
        self.lod_min_size = tk.StringVar(value="100")
        self.lod_target_ratio = tk.StringVar(value="0.12")
        self.lod_small_size = tk.StringVar(value="60")
        self.lod_small_diagonal = tk.StringVar(value="80")
        self.lod_min_triangles = tk.StringVar(value="300")
        self.lod_repeated_triangles = tk.StringVar(value="600")
        self.lod_repeated_count = tk.StringVar(value="32")
        self.batch_mode = tk.StringVar(value="All Tracks (standalone MTA)")
        self.batch_existing = tk.StringVar(value="Skip")
        self.status = tk.StringVar(value="Ready")
        # Set while a batch runs so per-track progress still shows how far the
        # whole run has got.
        self._batch_prefix = ""
        self._batch_cancel = threading.Event()

        self._load_settings()
        self._build_ui()
        self._refresh_tracks()
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.root.after(50, self._poll_events)

    def _load_settings(self) -> None:
        try:
            data = json.loads(self.settings_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        default_game_dir = Path(r"D:\ps2_game")
        saved_game_dir = Path(str(data.get("game_dir", "")))
        game_dir = saved_game_dir if saved_game_dir.is_dir() else default_game_dir if default_game_dir.is_dir() else saved_game_dir
        self.game_dir.set(str(game_dir) if str(game_dir) != "." else "")
        self.output_history = [str(value) for value in data.get("output_history", []) if value]
        default_output = str(PROJECT_ROOT / "out")
        self.output_dir.set(str(data.get("output_dir", self.output_history[0] if self.output_history else default_output)))
        default_frontend = Path(self.game_dir.get()) / "GAME" / "ZZDATA" / "FRONTEND"
        saved_frontend_dir = Path(str(data.get("frontend_dir", "")))
        frontend_dir = saved_frontend_dir if saved_frontend_dir.is_dir() else default_frontend
        self.frontend_dir.set(str(frontend_dir))
        self.frontend_output_dir.set(str(data.get("frontend_output_dir", Path(self.output_dir.get()) / "FRONTEND_TEXTURES")))
        default_global = Path(self.game_dir.get()) / "GAME" / "ZZDATA" / "GLOBAL"
        saved_global_dir = Path(str(data.get("global_dir", "")))
        global_dir = saved_global_dir if saved_global_dir.is_dir() else default_global
        self.global_dir.set(str(global_dir))
        self.global_output_dir.set(str(data.get("global_output_dir", Path(self.output_dir.get()) / "GLOBAL_TEXTURES")))
        default_sound = Path(self.game_dir.get()) / "GAME" / "ZZDATA"
        saved_sound_dir = Path(str(data.get("sound_dir", "")))
        if saved_sound_dir.name.upper() == "SOUND" and saved_sound_dir.parent.name.upper() == "ZZDATA":
            saved_sound_dir = saved_sound_dir.parent
        sound_dir = saved_sound_dir if saved_sound_dir.is_dir() else default_sound
        self.sound_dir.set(str(sound_dir))
        self.sound_output_dir.set(str(data.get("sound_output_dir", Path(self.output_dir.get()) / "SOUND_MP3")))
        for variable, key in (
            (self.author, "author"), (self.collision, "collision"),
            (self.export_type, "export_type"),
            (self.native_collision, "native_collision"), (self.lod_mode, "lod_mode"),
            (self.vertex_colors, "vertex_colors"), (self.chunk_size, "chunk_size"),
            (self.lod_min_size, "lod_min_size"), (self.lod_target_ratio, "lod_target_ratio"),
            (self.lod_small_size, "lod_small_size"), (self.lod_small_diagonal, "lod_small_diagonal"),
            (self.lod_min_triangles, "lod_min_triangles"),
            (self.lod_repeated_triangles, "lod_repeated_triangles"),
            (self.lod_repeated_count, "lod_repeated_count"),
            (self.skybox_subdir, "skybox_subdir"),
            (self.frontend_output_dir, "frontend_output_dir"),
            (self.global_output_dir, "global_output_dir"),
            (self.sound_output_dir, "sound_output_dir"),
            (self.sound_workers, "sound_workers"),
            (self.batch_mode, "batch_mode"), (self.batch_existing, "batch_existing"),
        ):
            if key in data:
                variable.set(str(data[key]))

    def _save_settings(self) -> None:
        output = self.output_dir.get().strip()
        history = [output] + [value for value in self.output_history if value != output]
        history = history[:12]
        self.output_history = history
        data = {
            "game_dir": self.game_dir.get().strip(), "output_dir": output,
            "output_history": history, "author": self.author.get(),
            "export_type": self.export_type.get(),
            "collision": self.collision.get(), "native_collision": self.native_collision.get(),
            "lod_mode": self.lod_mode.get(), "vertex_colors": self.vertex_colors.get(),
            "chunk_size": self.chunk_size.get(), "lod_min_size": self.lod_min_size.get(),
            "lod_target_ratio": self.lod_target_ratio.get(), "lod_small_size": self.lod_small_size.get(),
            "lod_small_diagonal": self.lod_small_diagonal.get(),
            "lod_min_triangles": self.lod_min_triangles.get(),
            "lod_repeated_triangles": self.lod_repeated_triangles.get(),
            "lod_repeated_count": self.lod_repeated_count.get(),
            "skybox_subdir": self.skybox_subdir.get(),
            "frontend_dir": self.frontend_dir.get(), "frontend_output_dir": self.frontend_output_dir.get(),
            "global_dir": self.global_dir.get(), "global_output_dir": self.global_output_dir.get(),
            "sound_dir": self.sound_dir.get(), "sound_output_dir": self.sound_output_dir.get(),
            "sound_workers": self.sound_workers.get(),
            "batch_mode": self.batch_mode.get(), "batch_existing": self.batch_existing.get(),
        }
        try:
            self.settings_file.parent.mkdir(parents=True, exist_ok=True)
            self.settings_file.write_text(json.dumps(data, indent=2), encoding="utf-8")
        except OSError:
            pass

    def _build_ui(self) -> None:
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(1, weight=1)
        top = ttk.Frame(self.root, padding=12)
        top.grid(row=0, column=0, sticky="ew")
        top.columnconfigure(1, weight=1)

        ttk.Label(top, text="PS2 Game Directory").grid(row=0, column=0, sticky="w", padx=(0, 8), pady=4)
        ttk.Entry(top, textvariable=self.game_dir).grid(row=0, column=1, sticky="ew", pady=4)
        ttk.Button(top, text="Browse…", command=self._browse_game_dir).grid(row=0, column=2, padx=(8, 0))
        ttk.Label(top, text="Output Root Directory").grid(row=1, column=0, sticky="w", padx=(0, 8), pady=4)
        self.output_combo = ttk.Combobox(top, textvariable=self.output_dir, values=self.output_history)
        self.output_combo.grid(row=1, column=1, sticky="ew", pady=4)
        ttk.Button(top, text="Browse…", command=self._browse_output_dir).grid(row=1, column=2, padx=(8, 0))
        ttk.Label(top, text="Track").grid(row=2, column=0, sticky="w", padx=(0, 8), pady=4)
        self.track_combo = ttk.Combobox(top, textvariable=self.track, state="readonly", width=18)
        self.track_combo.grid(row=2, column=1, sticky="w", pady=4)
        ttk.Button(top, text="Refresh Tracks", command=self._refresh_tracks).grid(row=2, column=2, padx=(8, 0))

        notebook = ttk.Notebook(self.root)
        notebook.grid(row=1, column=0, sticky="nsew", padx=12)
        basic = ttk.Frame(notebook, padding=12)
        lod = ttk.Frame(notebook, padding=12)
        skybox = ttk.Frame(notebook, padding=12)
        route = ttk.Frame(notebook, padding=12)
        frontend = ttk.Frame(notebook, padding=12)
        global_textures = ttk.Frame(notebook, padding=12)
        sound = ttk.Frame(notebook, padding=12)
        batch = ttk.Frame(notebook, padding=12)
        notebook.add(basic, text="Export Options")
        notebook.add(lod, text="LOD Options")
        notebook.add(skybox, text="Skybox Export")
        notebook.add(route, text="AI Route Export")
        notebook.add(frontend, text="Frontend Texture Export")
        notebook.add(global_textures, text="GLOBAL Texture Export")
        notebook.add(sound, text="SOUND Export")
        notebook.add(batch, text="Batch Track Export")
        for frame in (basic, lod, skybox, route, frontend, global_textures, sound, batch):
            frame.columnconfigure(1, weight=1)

        self._combo(basic, 0, "Export Type", self.export_type, ("MTA Resource", "GLB Only", "GLB + Debug", "Godot Package"))
        self._field(basic, 1, "Resource Name", self.resource_name, "Blank = HP2_TRACK##")
        self._field(basic, 2, "Author", self.author)
        self._combo(basic, 3, "Collision", self.collision, ("model", "bounds-only"))
        self._combo(basic, 4, "Native Road Collision", self.native_collision, ("auto", "required", "off"))
        self._combo(basic, 5, "Vertex Colors", self.vertex_colors, ("always", "auto", "off"))
        self._field(basic, 6, "Spatial Chunk Size", self.chunk_size)
        packed_check = ttk.Checkbutton(basic, text="Export Packed", variable=self.export_packed)
        packed_check.grid(row=7, column=0, columnspan=3, sticky="w", pady=(10, 0))
        ttk.Label(
            basic,
            text="Packed: exports all 6 variants of the selected family for track_manager. "
                 "Uses hp2_<family>_pack and fixed family export settings; Resource Name, "
                 "collision, vertex color, chunk and LOD options above do not apply. "
                 "Unchecked: standalone standard Eagle map, without effect scripts/plugins.",
            foreground="#666", wraplength=700,
        ).grid(row=8, column=0, columnspan=3, sticky="w", pady=(4, 0))
        def update_packed_state(*_args):
            packed_check.configure(state="normal" if self.export_type.get() == "MTA Resource" else "disabled")
        self.export_type.trace_add("write", update_packed_state)
        update_packed_state()


        self._combo(lod, 0, "LOD Mode", self.lod_mode, ("auto", "required", "off"))
        self._field(lod, 1, "LOD Main Size Threshold", self.lod_min_size)
        self._field(lod, 2, "LOD Simplification Ratio", self.lod_target_ratio)
        self._field(lod, 3, "Small Object Max Size", self.lod_small_size)
        self._field(lod, 4, "Small Object Max Diagonal", self.lod_small_diagonal)
        self._field(lod, 5, "Minimum Triangle Count", self.lod_min_triangles)
        self._field(lod, 6, "Repeated Object Triangle Count", self.lod_repeated_triangles)
        self._field(lod, 7, "Repeated Placement Count", self.lod_repeated_count)

        self._field(skybox, 0, "Skybox Folder Name", self.skybox_subdir, "inside Resource Name")
        ttk.Label(
            skybox,
            text="Exports PNG textures referenced by SKYDOME/SKYBOX objects and a JSON manifest.",
            foreground="#666",
            wraplength=620,
        ).grid(row=1, column=0, columnspan=3, sticky="w", pady=(10, 14))
        self.skybox_button = ttk.Button(skybox, text="Export Skybox Textures", command=self._start_skybox_export)
        self.skybox_button.grid(row=2, column=0, sticky="w")

        ttk.Label(
            route,
            text="Exports TRACK_ROUTE AI driving waypoints, branch edges, and radar reference points.",
            foreground="#666",
            wraplength=620,
        ).grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 14))
        self.route_button = ttk.Button(route, text="Export AI Route", command=self._start_route_export)
        self.route_button.grid(row=1, column=0, sticky="w")

        self._field(frontend, 0, "FRONTEND Directory", self.frontend_dir)
        ttk.Button(frontend, text="Browse…", command=self._browse_frontend_dir).grid(row=0, column=3, padx=(8, 0))
        self._field(frontend, 1, "Output Directory", self.frontend_output_dir)
        ttk.Button(frontend, text="Browse…", command=self._browse_frontend_output_dir).grid(row=1, column=3, padx=(8, 0))
        ttk.Label(
            frontend,
            text="Recursively extracts decodable BIN/BUN/LZC TPK textures and writes frontend_manifest.json.",
            foreground="#666",
            wraplength=620,
        ).grid(row=2, column=0, columnspan=4, sticky="w", pady=(10, 14))
        self.frontend_button = ttk.Button(frontend, text="Export Frontend Textures", command=self._start_frontend_export)
        self.frontend_button.grid(row=3, column=0, sticky="w")

        self._field(global_textures, 0, "GLOBAL Directory", self.global_dir)
        ttk.Button(global_textures, text="Browse…", command=self._browse_global_dir).grid(row=0, column=3, padx=(8, 0))
        self._field(global_textures, 1, "Output Directory", self.global_output_dir)
        ttk.Button(global_textures, text="Browse…", command=self._browse_global_output_dir).grid(row=1, column=3, padx=(8, 0))
        ttk.Label(
            global_textures,
            text="Recursively extracts decodable BIN/BUN/LZC TPK textures and writes global_manifest.json.",
            foreground="#666",
            wraplength=620,
        ).grid(row=2, column=0, columnspan=4, sticky="w", pady=(10, 14))
        self.global_button = ttk.Button(global_textures, text="Export GLOBAL Textures", command=self._start_global_export)
        self.global_button.grid(row=3, column=0, sticky="w")

        self._field(sound, 0, "ZZDATA Directory", self.sound_dir)
        ttk.Button(sound, text="Browse…", command=self._browse_sound_dir).grid(row=0, column=3, padx=(8, 0))
        self._field(sound, 1, "Output Directory", self.sound_output_dir)
        ttk.Button(sound, text="Browse…", command=self._browse_sound_output_dir).grid(row=1, column=3, padx=(8, 0))
        self._field(sound, 2, "Worker Processes (0 = Auto)", self.sound_workers)
        ttk.Label(
            sound,
            text="Extracts, names and de-duplicates music, speech, UI/SFX and engine sounds as MP3 using parallel workers.",
            foreground="#666",
            wraplength=720,
        ).grid(row=3, column=0, columnspan=4, sticky="w", pady=(10, 14))
        self.sound_button = ttk.Button(sound, text="Export All SOUND to MP3", command=self._start_sound_export)
        self.sound_button.grid(row=4, column=0, sticky="w")

        self._combo(batch, 0, "Batch Mode", self.batch_mode, _BATCH_MODES)
        self._combo(batch, 1, "If Output Exists", self.batch_existing, ("Skip", "Overwrite"))
        ttk.Label(
            batch,
            text="Exports every track found in the game directory, one after another, into the "
                 "Output Root above. Tracks use the Export Options and LOD Options tabs; family "
                 "packs use the fixed family settings and ignore them. A track that fails is "
                 "logged and the run continues, with a summary at the end.\n"
                 "Skip: leave a non-empty output folder alone, so an interrupted run can resume. "
                 "Overwrite: delete that folder first (asks once before starting).",
            foreground="#666", wraplength=700, justify="left",
        ).grid(row=2, column=0, columnspan=3, sticky="w", pady=(10, 14))
        self.batch_button = ttk.Button(batch, text="Start Batch Export", command=self._start_batch_export)
        self.batch_button.grid(row=3, column=0, sticky="w")
        self.batch_cancel_button = ttk.Button(
            batch, text="Stop After Current", command=self._cancel_batch, state="disabled"
        )
        self.batch_cancel_button.grid(row=3, column=1, sticky="w", padx=(8, 0))

        bottom = ttk.Frame(self.root, padding=12)
        bottom.grid(row=2, column=0, sticky="ew")
        bottom.columnconfigure(0, weight=1)
        self.progress = ttk.Progressbar(bottom, mode="determinate", maximum=100, value=0)
        self.progress.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        ttk.Label(bottom, textvariable=self.status).grid(row=1, column=0, sticky="w")
        self.start_button = ttk.Button(bottom, text="Export TRACK", command=self._start_export)
        self.start_button.grid(row=1, column=1, padx=(12, 0))
        self.log = tk.Text(bottom, height=8, state="disabled", wrap="word")
        self.log.grid(row=2, column=0, columnspan=2, sticky="ew", pady=(8, 0))

    @staticmethod
    def _field(parent: ttk.Frame, row: int, label: str, variable: tk.StringVar, hint: str | None = None) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=(0, 12), pady=5)
        entry = ttk.Entry(parent, textvariable=variable)
        entry.grid(row=row, column=1, sticky="ew", pady=5)
        if hint:
            ttk.Label(parent, text=hint, foreground="#666").grid(row=row, column=2, sticky="w", padx=8)

    @staticmethod
    def _combo(parent: ttk.Frame, row: int, label: str, variable: tk.StringVar, values: tuple[str, ...]) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=(0, 12), pady=5)
        ttk.Combobox(parent, textvariable=variable, values=values, state="readonly", width=18).grid(row=row, column=1, sticky="w", pady=5)

    def _browse_game_dir(self) -> None:
        value = filedialog.askdirectory(initialdir=self.game_dir.get() or str(Path.cwd()))
        if value:
            self.game_dir.set(value)
            default_frontend = Path(value) / "GAME" / "ZZDATA" / "FRONTEND"
            if not Path(self.frontend_dir.get()).is_dir():
                self.frontend_dir.set(str(default_frontend))
            default_global = Path(value) / "GAME" / "ZZDATA" / "GLOBAL"
            if not Path(self.global_dir.get()).is_dir():
                self.global_dir.set(str(default_global))
            default_sound = Path(value) / "GAME" / "ZZDATA"
            if not Path(self.sound_dir.get()).is_dir() or Path(self.sound_dir.get()).name.upper() == "SOUND":
                self.sound_dir.set(str(default_sound))
            self._refresh_tracks()
            self._save_settings()

    def _browse_output_dir(self) -> None:
        value = filedialog.askdirectory(initialdir=self.output_dir.get() or str(Path.cwd()))
        if value:
            self.output_dir.set(value)
            self._save_settings()
            self.output_combo.configure(values=self.output_history)

    def _browse_frontend_dir(self) -> None:
        value = filedialog.askdirectory(initialdir=self.frontend_dir.get() or str(Path.cwd()))
        if value:
            self.frontend_dir.set(value)
            self._save_settings()

    def _browse_frontend_output_dir(self) -> None:
        value = filedialog.askdirectory(initialdir=self.frontend_output_dir.get() or str(Path.cwd()))
        if value:
            self.frontend_output_dir.set(value)
            self._save_settings()

    def _browse_global_dir(self) -> None:
        value = filedialog.askdirectory(initialdir=self.global_dir.get() or str(Path.cwd()))
        if value:
            self.global_dir.set(value)
            self._save_settings()

    def _browse_global_output_dir(self) -> None:
        value = filedialog.askdirectory(initialdir=self.global_output_dir.get() or str(Path.cwd()))
        if value:
            self.global_output_dir.set(value)
            self._save_settings()

    def _browse_sound_dir(self) -> None:
        value = filedialog.askdirectory(initialdir=self.sound_dir.get() or str(Path.cwd()))
        if value:
            self.sound_dir.set(value)
            self._save_settings()

    def _browse_sound_output_dir(self) -> None:
        value = filedialog.askdirectory(initialdir=self.sound_output_dir.get() or str(Path.cwd()))
        if value:
            self.sound_output_dir.set(value)
            self._save_settings()

    def _refresh_tracks(self) -> None:
        root = Path(self.game_dir.get().strip()) / "ZZDATA" / "TRACKS"
        track_numbers = sorted({path.stem.replace("TRACKB", "") for path in root.glob("TRACKB*.LZC")} | {path.stem.replace("TRACKB", "") for path in root.glob("TRACKB*.BUN")}, key=lambda value: int(value) if value.isdigit() else value)
        tracks = [_track_display_name(value) for value in track_numbers]
        self.track_combo.configure(values=tracks)
        current_number = re.match(r"\d+", self.track.get() or "")
        current_display = _track_display_name(current_number.group(0)) if current_number else ""
        if tracks and current_display not in tracks:
            self.track.set(tracks[0])
        self.status.set(f"Found {len(tracks)} tracks" if tracks else "No TRACKB## files found")

    def _append_log(self, text: str) -> None:
        if not text:
            return
        self.log.configure(state="normal")
        self.log.insert("end", text)
        # Keep the Text widget bounded; very large Tk text buffers make every
        # subsequent insert and redraw progressively more expensive.
        try:
            line_count = int(self.log.index("end-1c").split(".", 1)[0])
            if line_count > 6000:
                self.log.delete("1.0", f"{line_count - 5000}.0")
        except (ValueError, tk.TclError):
            pass
        self.log.see("end")
        self.log.configure(state="disabled")

    def _start_export(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        if not self.track.get():
            messagebox.showerror("Export Error", "Please select a TRACKB## track first.")
            return
        if not Path(self.game_dir.get().strip()).is_dir():
            messagebox.showerror("Export Error", "The PS2 game directory does not exist.")
            return
        if not self.output_dir.get().strip():
            messagebox.showerror("Export Error", "Please select an output directory.")
            return
        try:
            args, target = self._cli_args()
        except (OSError, ValueError) as exc:
            messagebox.showerror("Export Error", str(exc))
            return
        self._save_settings()
        self._append_log("\n=== Export Started ===\n")
        self._append_log(f"Output: {target}\n")
        self.status.set("Extracting and generating models…")
        self._set_export_buttons("disabled")
        self.progress.configure(mode="determinate", maximum=100, value=0)
        self.worker = threading.Thread(target=self._run_export, args=(args,), daemon=True)
        self.worker.start()

    def _start_route_export(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        if not self.track.get():
            messagebox.showerror("Route Export Error", "Please select a TRACKB## track first.")
            return
        if not Path(self.game_dir.get().strip()).is_dir():
            messagebox.showerror("Route Export Error", "The PS2 game directory does not exist.")
            return
        if not self.output_dir.get().strip():
            messagebox.showerror("Route Export Error", "Please select an output directory.")
            return
        try:
            args, target = self._route_cli_args()
        except (OSError, ValueError) as exc:
            messagebox.showerror("Route Export Error", str(exc))
            return
        self._save_settings()
        self._append_log("\n=== AI Route Export Started ===\n")
        self._append_log(f"Output: {target}\n")
        self.status.set("Exporting AI route…")
        self._set_export_buttons("disabled")
        self.progress.configure(mode="determinate", maximum=100, value=0)
        self.worker = threading.Thread(target=self._run_export, args=(args,), daemon=True)
        self.worker.start()

    def _start_skybox_export(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        if not self.track.get():
            messagebox.showerror("Skybox Export Error", "Please select a TRACKB## track first.")
            return
        if not Path(self.game_dir.get().strip()).is_dir():
            messagebox.showerror("Skybox Export Error", "The PS2 game directory does not exist.")
            return
        if not self.output_dir.get().strip():
            messagebox.showerror("Skybox Export Error", "Please select an output directory.")
            return
        try:
            args, target = self._skybox_cli_args()
        except (OSError, ValueError) as exc:
            messagebox.showerror("Skybox Export Error", str(exc))
            return
        self._save_settings()
        self._append_log("\n=== Skybox Export Started ===\n")
        self._append_log(f"Output: {target}\n")
        self.status.set("Exporting skybox textures…")
        self._set_export_buttons("disabled")
        self.progress.configure(mode="determinate", maximum=100, value=0)
        self.worker = threading.Thread(target=self._run_export, args=(args,), daemon=True)
        self.worker.start()

    def _start_frontend_export(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        frontend_dir = Path(self.frontend_dir.get().strip())
        output_dir = Path(self.frontend_output_dir.get().strip())
        if not self.frontend_output_dir.get().strip():
            messagebox.showerror("Frontend Export Error", "Please select an output directory.")
            return
        frontend_dir.mkdir(parents=True, exist_ok=True)
        if output_dir.resolve() == frontend_dir.resolve():
            messagebox.showerror("Frontend Export Error", "Output directory must be different from FRONTEND directory.")
            return
        args = ["export-frontend-textures", "--frontend-dir", str(frontend_dir), "--output", str(output_dir)]
        self._save_settings()
        self._append_log("\n=== Frontend Texture Export Started ===\n")
        self._append_log(f"Output: {output_dir}\n")
        self.status.set("Extracting FRONTEND textures…")
        self._set_export_buttons("disabled")
        self.progress.configure(mode="determinate", maximum=100, value=0)
        self.worker = threading.Thread(target=self._run_export, args=(args,), daemon=True)
        self.worker.start()

    def _start_global_export(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        global_dir = Path(self.global_dir.get().strip())
        output_dir = Path(self.global_output_dir.get().strip())
        if not self.global_output_dir.get().strip():
            messagebox.showerror("GLOBAL Export Error", "Please select an output directory.")
            return
        global_dir.mkdir(parents=True, exist_ok=True)
        if output_dir.resolve() == global_dir.resolve():
            messagebox.showerror("GLOBAL Export Error", "Output directory must be different from GLOBAL directory.")
            return
        args = ["export-global-textures", "--global-dir", str(global_dir), "--output", str(output_dir)]
        self._save_settings()
        self._append_log("\n=== GLOBAL Texture Export Started ===\n")
        self._append_log(f"Output: {output_dir}\n")
        self.status.set("Extracting GLOBAL textures…")
        self._set_export_buttons("disabled")
        self.progress.configure(mode="determinate", maximum=100, value=0)
        self.worker = threading.Thread(target=self._run_export, args=(args,), daemon=True)
        self.worker.start()

    def _start_sound_export(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        sound_dir = Path(self.sound_dir.get().strip())
        output_dir = Path(self.sound_output_dir.get().strip())
        if not self.sound_output_dir.get().strip():
            messagebox.showerror("SOUND Export Error", "Please select an output directory.")
            return
        sound_dir.mkdir(parents=True, exist_ok=True)
        if output_dir.resolve() == sound_dir.resolve():
            messagebox.showerror("SOUND Export Error", "Output directory must be outside the ZZDATA directory.")
            return
        if sound_dir.resolve() in output_dir.resolve().parents:
            messagebox.showerror("SOUND Export Error", "Output directory must be outside the ZZDATA directory.")
            return
        try:
            worker_count = int(self.sound_workers.get().strip() or "0")
            if worker_count < 0 or worker_count > 32:
                raise ValueError
        except ValueError:
            messagebox.showerror("SOUND Export Error", "Worker Processes must be between 0 and 32.")
            return
        args = [
            "export-sound", "--zzdata-dir", str(sound_dir), "--output", str(output_dir),
            "--workers", str(worker_count),
        ]
        self._save_settings()
        self._append_log("\n=== SOUND Export Started ===\n")
        self._append_log(f"Output: {output_dir}\n")
        self.status.set("Extracting all SOUND streams to MP3…")
        self._set_export_buttons("disabled")
        self.progress.configure(mode="determinate", maximum=100, value=0)
        self.worker = threading.Thread(target=self._run_export, args=(args,), daemon=True)
        self.worker.start()

    def _cancel_batch(self) -> None:
        self._batch_cancel.set()
        self.batch_cancel_button.configure(state="disabled")
        self._append_log("Stop requested; finishing the current track first.\n")

    def _batch_jobs(self) -> list[tuple[str, Path, list[str]]]:
        """Build the (label, output, CLI args) list for the selected batch mode."""
        game_dir = self.game_dir.get().strip()
        root = Path(self.output_dir.get().strip())
        author = self.author.get().strip() or "map_tools_ps2"
        if self.batch_mode.get() == _BATCH_MODES[1]:
            return [
                (f"{family} pack", root / f"hp2_{family}_pack",
                 ["export-mta-families", "--game-dir", game_dir, "--output", str(root),
                  "--family", family, "--author", author])
                for family in FAMILIES.values()
            ]
        tracks = Path(game_dir) / "ZZDATA" / "TRACKS"
        numbers = sorted(
            {path.stem.replace("TRACKB", "") for path in tracks.glob("TRACKB*.LZC")}
            | {path.stem.replace("TRACKB", "") for path in tracks.glob("TRACKB*.BUN")},
            key=lambda value: int(value) if value.isdigit() else 0,
        )
        texture_dir = str(tracks)
        jobs: list[tuple[str, Path, list[str]]] = []
        for number in numbers:
            if not number.isdigit():
                continue
            resource_name = f"HP2_TRACK{int(number):02d}"
            target = root / resource_name
            args = ["export-mta", "--game-dir", game_dir, "--track", number,
                    "--output", str(target), "--texture-dir", texture_dir,
                    "--resource-name", resource_name, "--author", author]
            # Batch runs reuse the Export/LOD tabs, minus the per-track fields.
            for option, value in (("--collision", self.collision.get()),
                                  ("--native-collision", self.native_collision.get()),
                                  ("--vertex-colors", self.vertex_colors.get()),
                                  ("--chunk-size", self.chunk_size.get()),
                                  ("--lod-mode", self.lod_mode.get()),
                                  ("--lod-min-size", self.lod_min_size.get()),
                                  ("--lod-target-ratio", self.lod_target_ratio.get()),
                                  ("--lod-small-size", self.lod_small_size.get()),
                                  ("--lod-small-diagonal", self.lod_small_diagonal.get()),
                                  ("--lod-min-triangles", self.lod_min_triangles.get()),
                                  ("--lod-repeated-triangles", self.lod_repeated_triangles.get()),
                                  ("--lod-repeated-count", self.lod_repeated_count.get())):
                if value.strip():
                    args.extend((option, value.strip()))
            jobs.append((_track_display_name(number), target, args))
        return jobs

    def _start_batch_export(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        if not Path(self.game_dir.get().strip()).is_dir():
            messagebox.showerror("Batch Export Error", "The PS2 game directory does not exist.")
            return
        if not self.output_dir.get().strip():
            messagebox.showerror("Batch Export Error", "Please select an output directory.")
            return
        jobs = self._batch_jobs()
        if not jobs:
            messagebox.showerror("Batch Export Error", "No TRACKB## files were found to export.")
            return
        overwrite = self.batch_existing.get() == "Overwrite"
        occupied = [target for _label, target, _args in jobs if target.is_dir() and any(target.iterdir())]
        if overwrite and occupied:
            # Deleting a whole export tree is not recoverable, so name what goes.
            listed = "\n".join(str(path) for path in occupied[:8])
            more = f"\n… and {len(occupied) - 8} more" if len(occupied) > 8 else ""
            if not messagebox.askyesno(
                "Delete existing exports?",
                f"Overwrite will permanently delete {len(occupied)} existing output "
                f"folder(s) before exporting:\n\n{listed}{more}\n\nContinue?",
                icon="warning", default="no",
            ):
                return
        self._save_settings()
        self._batch_cancel.clear()
        self._append_log(f"\n=== Batch Export Started ({len(jobs)} jobs) ===\n")
        self.status.set("Starting batch export…")
        self._set_export_buttons("disabled")
        self.batch_cancel_button.configure(state="normal")
        self.progress.configure(mode="determinate", maximum=100, value=0)
        self.worker = threading.Thread(target=self._run_batch, args=(jobs, overwrite), daemon=True)
        self.worker.start()

    def _run_batch(self, jobs: list[tuple[str, Path, list[str]]], overwrite: bool) -> None:
        stream = _QueueStream(self.events)
        done = skipped = 0
        failures: list[str] = []
        try:
            with progress_context(self._on_progress):
                for index, (label, target, args) in enumerate(jobs, 1):
                    if self._batch_cancel.is_set():
                        self.events.put(("log", f"Stopped before {label}.\n"))
                        break
                    self._batch_prefix = f"[{index}/{len(jobs)}] {label} — "
                    self.events.put(("log", f"\n--- [{index}/{len(jobs)}] {label} -> {target} ---\n"))
                    if target.is_dir() and any(target.iterdir()):
                        if not overwrite:
                            skipped += 1
                            self.events.put(("log", "Output already exists; skipped.\n"))
                            continue
                        try:
                            shutil.rmtree(target)
                        except OSError as exc:
                            failures.append(f"{label}: could not remove {target}: {exc}")
                            self.events.put(("log", f"FAILED to remove {target}: {exc}\n"))
                            continue
                    try:
                        with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
                            code = cli_main(args)
                    except SystemExit as exc:
                        # argparse and the CLI report user errors by raising
                        # SystemExit, which is a BaseException and would
                        # otherwise kill the worker and the rest of the batch.
                        detail = exc.code if isinstance(exc.code, str) else f"exit code {exc.code}"
                        failures.append(f"{label}: {detail}")
                        self.events.put(("log", f"FAILED: {detail}\n"))
                        continue
                    except Exception as exc:  # one bad track must not end the run
                        failures.append(f"{label}: {exc}")
                        self.events.put(("log", f"FAILED: {exc}\n"))
                        continue
                    if code:
                        failures.append(f"{label}: exit code {code}")
                        self.events.put(("log", f"FAILED with exit code {code}\n"))
                    else:
                        done += 1
            summary = f"Batch finished: {done} exported, {skipped} skipped, {len(failures)} failed"
            if failures:
                summary += "\n  " + "\n  ".join(failures)
            self.events.put(("done" if not failures else "error", summary + "\n"))
        except (Exception, SystemExit) as exc:
            self.events.put(("error", f"Batch export failed: {exc}\n"))
        finally:
            self._batch_prefix = ""

    def _set_export_buttons(self, state: str) -> None:
        for button in (self.start_button, self.skybox_button, self.route_button, self.frontend_button, self.global_button, self.sound_button, self.batch_button):
            button.configure(state=state)

    def _prepare_output(self, track_number: str) -> tuple[Path, str]:
        resource_name = self.resource_name.get().strip() or f"HP2_TRACK{int(track_number):02d}"
        resource_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", resource_name).strip(" .")
        if not resource_name:
            raise ValueError("Resource name is empty after sanitization.")
        root = Path(self.output_dir.get().strip())
        target = root / resource_name
        if target.exists() and not target.is_dir():
            raise ValueError(f"Output path is not a directory: {target}")
        if target.exists() and any(target.iterdir()):
            raise ValueError(f"Resource output directory is not empty:\n{target}\nChoose a new Resource Name or clean the folder first.")
        target.mkdir(parents=True, exist_ok=True)
        return target, resource_name

    def _cli_args(self) -> tuple[list[str], Path]:
        track_number = re.match(r"\d+", self.track.get().strip())
        if track_number is None:
            raise ValueError(f"Invalid track selection: {self.track.get()!r}")
        number = track_number.group(0)
        if self.export_type.get() == "MTA Resource" and self.export_packed.get():
            if int(number) not in TRACK_IDS:
                raise ValueError(f"Unsupported packed track: {number}")
            family = FAMILIES[int(number) // 10 * 10]
            root = Path(self.output_dir.get().strip())
            target = root / f"hp2_{family}_pack"
            if target.exists() and (not target.is_dir() or any(target.iterdir())):
                raise ValueError(f"Packed output must be a new or empty directory: {target}")
            return ["export-mta-families", "--game-dir", self.game_dir.get().strip(),
                    "--output", str(root), "--family", family,
                    "--author", self.author.get().strip() or "map_tools_ps2"], target
        target, resource_name = self._prepare_output(number)
        texture_dir = str(Path(self.game_dir.get().strip()) / "ZZDATA" / "TRACKS")
        export_type = self.export_type.get()
        if export_type == "MTA Resource":
            args = ["export-mta", "--game-dir", self.game_dir.get().strip(), "--track", number, "--output", str(target), "--texture-dir", texture_dir]
        elif export_type == "GLB Only":
            args = ["export", "--game-dir", self.game_dir.get().strip(), "--track", number, "--output", str(target / f"TRACKB{int(number):02d}.glb"), "--texture-dir", texture_dir, "--with-placement"]
        elif export_type == "GLB + Debug":
            args = ["export-dual", "--game-dir", self.game_dir.get().strip(), "--track", number, "--output", str(target / f"TRACKB{int(number):02d}.native.glb"), "--texture-dir", texture_dir, "--with-placement"]
        elif export_type == "Godot Package":
            args = ["export-godot", "--game-dir", self.game_dir.get().strip(), "--track", number, "--output", str(target), "--texture-dir", texture_dir]
        else:
            raise ValueError(f"Unsupported export type: {export_type}")
        if export_type == "MTA Resource":
            values = (("--resource-name", resource_name), ("--author", self.author.get()), ("--collision", self.collision.get()), ("--native-collision", self.native_collision.get()), ("--vertex-colors", self.vertex_colors.get()), ("--chunk-size", self.chunk_size.get()), ("--lod-mode", self.lod_mode.get()), ("--lod-min-size", self.lod_min_size.get()), ("--lod-target-ratio", self.lod_target_ratio.get()), ("--lod-small-size", self.lod_small_size.get()), ("--lod-small-diagonal", self.lod_small_diagonal.get()), ("--lod-min-triangles", self.lod_min_triangles.get()), ("--lod-repeated-triangles", self.lod_repeated_triangles.get()), ("--lod-repeated-count", self.lod_repeated_count.get()))
        else:
            values = ()
        for option, value in values:
            if value.strip():
                args.extend((option, value.strip()))
        return args, target

    def _skybox_cli_args(self) -> tuple[list[str], Path]:
        track_number = re.match(r"\d+", self.track.get().strip())
        if track_number is None:
            raise ValueError(f"Invalid track selection: {self.track.get()!r}")
        number = track_number.group(0)
        resource_name = self.resource_name.get().strip() or f"HP2_TRACK{int(number):02d}"
        resource_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", resource_name).strip(" .")
        subdir = re.sub(r"[^A-Za-z0-9_.-]+", "_", self.skybox_subdir.get().strip()).strip(" .")
        if not resource_name or not subdir:
            raise ValueError("Resource name and skybox folder name must not be empty.")
        target = Path(self.output_dir.get().strip()) / resource_name / subdir
        if target.exists() and not target.is_dir():
            raise ValueError(f"Skybox output path is not a directory: {target}")
        if target.exists() and any(target.iterdir()):
            raise ValueError(f"Skybox output directory is not empty:\n{target}\nChoose another folder or clean it first.")
        target.mkdir(parents=True, exist_ok=True)
        texture_dir = str(Path(self.game_dir.get().strip()) / "ZZDATA" / "TRACKS")
        return [
            "export-skybox", "--game-dir", self.game_dir.get().strip(), "--track", number,
            "--output", str(target), "--texture-dir", texture_dir,
        ], target

    def _route_cli_args(self) -> tuple[list[str], Path]:
        track_number = re.match(r"\d+", self.track.get().strip())
        if track_number is None:
            raise ValueError(f"Invalid track selection: {self.track.get()!r}")
        number = track_number.group(0)
        resource_name = self.resource_name.get().strip() or f"HP2_TRACK{int(number):02d}"
        resource_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", resource_name).strip(" .")
        if not resource_name:
            raise ValueError("Resource name is empty after sanitization.")
        target_dir = Path(self.output_dir.get().strip()) / resource_name
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / "route.txt"
        if target.exists():
            raise ValueError(f"Route output already exists:\n{target}\nChoose a new Resource Name or remove the old route.txt first.")
        return ["export-route", "--game-dir", self.game_dir.get().strip(), "--track", number, "--output", str(target)], target

    def _run_export(self, args: list[str]) -> None:
        with self._progress_lock:
            self._latest_progress = None
        stream = _QueueStream(self.events)
        try:
            with progress_context(self._on_progress):
                with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
                    code = cli_main(args)
            self.events.put(("done", f"Export complete, return code {code}\n"))
        except Exception as exc:  # GUI must show exporter errors instead of dying silently.
            self.events.put(("error", f"Export failed: {exc}\n"))

    def _on_progress(self, stage: str, current: int, total: int | None, item: object | None) -> None:
        item_name = getattr(item, "name", None) or (str(item) if item is not None else "")
        # Only the newest progress value matters. Coalescing here prevents tens
        # of thousands of speech entries from flooding Tk's event loop.
        with self._progress_lock:
            self._latest_progress = (stage, current, total, item_name)

    def _on_close(self) -> None:
        self._closed = True
        self._save_settings()
        self.root.destroy()

    def _poll_events(self) -> None:
        if self._closed:
            return

        with self._progress_lock:
            progress = self._latest_progress
            self._latest_progress = None
        if progress is not None:
            stage, current, total, item_name = progress
            if total and total > 0:
                self.progress.configure(maximum=total, value=min(current, total))
                suffix = f" — {item_name}" if item_name else ""
                self.status.set(f"{self._batch_prefix}{stage}: {current}/{total}{suffix}")

        log_parts: list[str] = []
        terminal: tuple[str, str] | None = None
        deadline = time.monotonic() + 0.012
        # Bound work per Tk frame so painting, moving and resizing the window
        # stay responsive even while the worker is producing output rapidly.
        for _ in range(256):
            try:
                kind, text = self.events.get_nowait()
            except queue.Empty:
                break
            if kind == "log":
                log_parts.append(str(text))
            else:
                terminal = (kind, str(text))
            if time.monotonic() >= deadline:
                break

        if log_parts:
            combined = "".join(log_parts)
            self._append_log(combined)
            latest = combined.replace("\r", "\n").strip().splitlines()
            if latest:
                self.status.set(latest[-1][:180])

        if terminal is not None:
            kind, text = terminal
            self.worker = None
            self.progress.stop()
            self._set_export_buttons("normal")
            self.batch_cancel_button.configure(state="disabled")
            self._append_log(text)
            if kind == "done":
                self.progress.configure(value=self.progress["maximum"])
                self.status.set("Export complete")
            else:
                self.status.set("Export failed")
                messagebox.showerror("Export Error", text.splitlines()[0])

        if not self._closed:
            self.root.after(50, self._poll_events)


def run_gui() -> int:
    root = tk.Tk()
    ExportGui(root)
    root.mainloop()
    return 0

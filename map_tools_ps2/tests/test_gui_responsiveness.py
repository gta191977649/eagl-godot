import queue
import threading

from map_tools_ps2.gui import ExportGui, _QueueStream


class _Value:
    def __init__(self):
        self.value = ""

    def set(self, value):
        self.value = value


class _Progress:
    def __init__(self):
        self.maximum = 100

    def configure(self, **values):
        self.maximum = values.get("maximum", self.maximum)

    def stop(self):
        pass

    def __getitem__(self, key):
        assert key == "maximum"
        return self.maximum


class _Root:
    def __init__(self):
        self.after_calls = []

    def after(self, delay, callback):
        self.after_calls.append((delay, callback))


def test_progress_updates_are_coalesced_instead_of_queued():
    gui = ExportGui.__new__(ExportGui)
    gui.events = queue.Queue(maxsize=8)
    gui._progress_lock = threading.Lock()
    gui._latest_progress = None

    for index in range(50_000):
        gui._on_progress("speech", index, 50_000, f"item {index}")

    assert gui.events.empty()
    assert gui._latest_progress == ("speech", 49_999, 50_000, "item 49999")


def test_queue_stream_never_blocks_when_gui_log_queue_is_full():
    events = queue.Queue(maxsize=1)
    events.put_nowait(("log", "existing"))

    assert _QueueStream(events).write("discarded while full") == len("discarded while full")
    assert events.qsize() == 1


def test_event_poll_has_per_frame_budget_and_batches_log_inserts():
    gui = ExportGui.__new__(ExportGui)
    gui.events = queue.Queue()
    for index in range(300):
        gui.events.put(("log", f"line {index}\n"))
    gui._progress_lock = threading.Lock()
    gui._latest_progress = None
    gui._closed = False
    gui.root = _Root()
    gui.progress = _Progress()
    gui.status = _Value()
    gui.worker = object()
    inserted = []
    gui._append_log = inserted.append
    gui._set_export_buttons = lambda _state: None

    gui._poll_events()

    assert 0 < gui.events.qsize() < 300
    assert len(inserted) == 1
    assert gui.root.after_calls[0][0] == 50

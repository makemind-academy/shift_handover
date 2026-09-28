#!/usr/bin/env python3
"""shift-handover: open items travel to the next shift unchanged, the third handover turns red, an empty note cannot close one."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from appplayer import AppPlayer  # noqa: E402
from mcpclient import Server  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "handover_server")
CAP = os.path.join(HERE, "captures")
SERVER_ID = "com.makemind.sample.handover"

with Server(["dart", "run", "bin/server.dart"], cwd=SERVER) as s:
    st = s.call("shift.state")
    assert st["openCount"] == 3
    src = open(os.path.join(SERVER, "bin", "server.dart")).read()
    assert "carried" in src and "carriedCount" not in src, "the carry count is derived, not stored"
    refused = s.call("shift.close", {"id": 1, "note": ""})
    assert refused["openCount"] == 3, "an empty note must not close an item"

ap = AppPlayer()
ap.register_server(SERVER_ID, "Handover board", cwd=SERVER)
ap.restart()
ap.open_server(SERVER_ID)
ap.wait_text("Chiller 2")               # the night shift's three items, on the morning board
ap.expect_text("MORNING")
ap.expect_aligned("carried", min_rows=3)
ap.shot(f"{CAP}/01_night.png")
ap.tap("Close #3: supplier credited")
ap.wait_text("#3 closed by")       # the till answered, not the button label
ap.shot(f"{CAP}/02_morning.png")
ap.tap("Hand over")
ap.wait_text("AFTERNOON")
ap.tap("Close #2: reader replaced")
ap.wait_text("reader swapped")
ap.tap("Hand over")
ap.wait_text("NIGHT")
ap.wait_text("3 handovers")
ap.tap("Close #1 (no note)")
ap.wait_text("needs a note to close")
ap.expect_text("3 handovers")           # an empty note did not close it
ap.shot(f"{CAP}/03_third_handover.png")
ap.tap("Close #1: chiller serviced")
ap.wait_text("compressor fan")
print("shift-handover: three handovers on screen, the chiller crossed all of them, an empty note refused")

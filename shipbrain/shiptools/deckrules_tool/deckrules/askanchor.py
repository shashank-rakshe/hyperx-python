"""R-F3 (owner 2026-10-23): when the drawing does not say where the frame numbering starts in the ship (X of the first printed frame), the tool
asks with a pop-up ('X of FR.47 from the origin in mm?'). Console fallback when no display is available."""
import re


def first_frame(pdf, pages):
    """lowest frame number printed in the frame-number row of a deck plan, and the frame spacing from the drawing notes"""
    from . import pdfsrc, view
    best, sp = None, None
    for pn in pages:
        page = pdfsrc.load_page(pdf, pn - 1)
        for v in view.find_deck_plans(page):
            sp = sp or v.frame_space
            try:
                row = view._digit_row(page, v, v.frame_space, view.PT_MM * (view.sheet_scale(page) or 100))
            except Exception:
                row = []
            for n, _ in row:
                best = n if best is None else min(best, n)
    return best, sp


def ask(frame, spacing=None, default=''):
    msg = f"Start frame of this drawing is FR.{frame}" + (f" (frame spacing {spacing} mm read from the drawing)" if spacing else '') + \
          f".\nX of FR.{frame} from the ship origin in mm?"
    try:
        import tkinter as tk
        from tkinter import simpledialog
        root = tk.Tk()
        root.withdraw()
        root.attributes('-topmost', True)
        val = simpledialog.askstring('Start frame', msg, initialvalue=str(default), parent=root)
        root.destroy()
    except Exception:
        try:
            val = input(msg + ' ')
        except EOFError:
            val = None
    if val is None or not re.fullmatch(r'\s*-?\d+(\.\d+)?\s*', str(val)):
        return None
    return float(val)

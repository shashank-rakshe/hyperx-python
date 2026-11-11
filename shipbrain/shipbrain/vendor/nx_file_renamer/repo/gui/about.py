# about.py

import tkinter as tk
import webbrowser
from gui.utils import resource_path
from gui.info import ABOUT_TEXT, BG_COLOR, ICON_PATH, ABOUT_IMAGE, GITHUB_URL

def show_about_window(root):
    about_window = tk.Toplevel(root)
    about_window.resizable(False, False)
    about_window.title("About NX File Renamer")
    about_window.iconbitmap(resource_path(ICON_PATH))
    about_window['background'] = BG_COLOR

    about_label = tk.Label(
        about_window,
        text=ABOUT_TEXT,
        justify="left",
        wraplength=550,
        bg=BG_COLOR
    )
    about_label.grid(row=0, rowspan=7, column=0, columnspan=4, padx=15, pady=10)

    close_button = tk.Button(
        about_window,
        text="Close",
        command=about_window.destroy,
        width=9
    )
    close_button.grid(row=7, column=2, padx=5, pady=20)

    bg = tk.PhotoImage(file=resource_path(ABOUT_IMAGE))
    bg_label = tk.Label(about_window, image=bg, cursor="hand2")
    bg_label.image = bg  # prevent garbage collection
    bg_label.grid(row=6, column=3)

    bg_label.bind("<Button-1>", lambda e: webbrowser.open_new(GITHUB_URL))
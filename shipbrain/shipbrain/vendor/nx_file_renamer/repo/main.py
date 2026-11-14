import tkinter as tk
from gui.app import App
from core.renamer_script import rename_nx_file

if __name__ == "__main__":
    root = tk.Tk()
    app = App(root, rename_callback=rename_nx_file)
    root.mainloop()
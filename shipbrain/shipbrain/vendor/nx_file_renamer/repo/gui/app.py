import tkinter as tk
from tkinter import filedialog, messagebox
import sys
import threading
import os
import pythoncom
from pathlib import Path

from gui.utils import resource_path
from gui.info import APP_TITLE, WINDOW_SIZE, BG_COLOR, ICON_PATH
from gui.about import show_about_window


class App:
    def __init__(self, root, rename_callback):
        self.root = root
        self.rename_callback = rename_callback
        self.root.title(APP_TITLE)
        self.root.geometry(WINDOW_SIZE)
        self.root.resizable(False, False)
        self.root.configure(bg=BG_COLOR)

        root.iconbitmap(resource_path(ICON_PATH))

        self.create_widgets()
        self.load_context_file()

    def create_widgets(self):
        # File to Rename Label
        self.file_label = tk.Label(self.root, text="File to rename:", bg=BG_COLOR)
        self.file_label.grid(row=1, column=0, padx=25, pady=10)

        # File Path Entry Field
        self.file_entry = tk.Entry(self.root, state="readonly", width=70)
        self.file_entry.grid(row=1, column=1, columnspan=4, padx=5, pady=10)

        # Browse Button
        self.browse_btn = tk.Button(self.root, text="Browse", command=self.browse, height=1, width=8)
        self.browse_btn.grid(row=1, column=5, padx=10, pady=20)

        # New Name Label
        tk.Label(self.root, text="New Name:", bg=BG_COLOR)\
            .grid(row=2, column=0, padx=5, pady=10)

        # New Name Entry Field
        self.new_name_entry = tk.Entry(self.root, width=70)
        self.new_name_entry.grid(row=2, column=1, columnspan=4, padx=5, pady=10)

        # OK button
        self.ok_btn = tk.Button(self.root, text="OK", command=self.rename_file, height=1, width=9)
        self.ok_btn.grid(row=4, column=2, padx=5, pady=10)

        # Cancel button
        self.cancel_btn = tk.Button(self.root, text="Cancel", command=self.root.destroy, height=1, width=9)
        self.cancel_btn.grid(row=4, column=3, padx=5, pady=10)

        # About button
        self.about_btn = tk.Button(self.root, text="About", command=lambda: show_about_window(self.root), height=1, width=9)
        self.about_btn.grid(row=4, column=4, padx=5, pady=10)

        self.new_name_entry.bind("<Return>", lambda e: self.rename_file())

        # Log Field Label
        tk.Label(self.root, text="Log Window:", bg=BG_COLOR)\
            .grid(row=5, column=0, padx=5, pady=10)
        
        # Log Field
        # Frame to hold Log Text + Scrollbar
        log_frame = tk.Frame(self.root, bg=BG_COLOR)
        log_frame.grid(row=5, column=1, columnspan=4, padx=5, pady=10)

        # Scrollbar
        scrollbar = tk.Scrollbar(log_frame)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        # Text widget
        self.log_text = tk.Text(log_frame, height=6, width=55, state="disabled", yscrollcommand=scrollbar.set)
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH)

        # Connect scrollbar to text
        scrollbar.config(command=self.log_text.yview)

        # Create a label for Motto
        tk.Label(self.root, text="NX File Renamer v1.1", justify="right", bg=BG_COLOR, fg="white", font=("calibri", 24, "bold"))\
            .grid(row=7, column=3, rowspan=5, columnspan=5, padx=0, pady=5)
        

    def load_context_file(self):
        if len(sys.argv) == 2:
            file_name = sys.argv[1]
            if file_name.endswith(".prt"):
                self.file_entry.config(state="normal")
                self.file_entry.insert(0, file_name)
                self.file_entry.config(state="readonly")
                self.new_name_entry.insert(0, Path(file_name).stem)

    def browse(self):
        file_path = filedialog.askopenfilename(filetypes=[("NX Part Files", "*.prt")])
        if file_path:
            self.file_entry.config(state="normal")
            self.file_entry.delete(0, tk.END)
            self.file_entry.insert(0, file_path)
            self.file_entry.config(state="readonly")
            self.new_name_entry.delete(0, tk.END)
            self.new_name_entry.insert(0, Path(file_path).stem)

    def reset_form(self):
        # Clear file entry
        self.file_entry.configure(state="normal")
        self.file_entry.delete(0, tk.END)
        self.file_entry.configure(state="readonly")

        # Clear new name
        self.new_name_entry.configure(state="normal")
        self.new_name_entry.delete(0, tk.END)

        # Clear log window
        self.log_text.configure(state="normal")
        self.log_text.delete(1.0, tk.END)
        self.log_text.configure(state="disabled")

        # Restore buttons
        self.browse_btn.configure(state="normal")
        self.ok_btn.configure(state="normal")
        self.about_btn.configure(state="normal")

        self.cancel_btn.configure(text="Cancel", state="normal", command=self.root.destroy)

    def on_task_complete(self, new_name):
        messagebox.showinfo("Success!", f"Renamed to {new_name}")
        # After successful renaming change "Cancel" button to "Reset" button
        self.cancel_btn.configure(state="normal", text= "Reset", command=self.reset_form)

    def rename_file(self):
        file_path = self.file_entry.get()
        new_name = self.new_name_entry.get()

        if not file_path or not os.path.exists(file_path):
            messagebox.showerror("Error!", "Valid file need to be selected.")
            return

        if not new_name:
            messagebox.showerror("Error!", "Please enter a new name.")
            return
        
        def task():
            # Need to Initialize COM object for each thread
            pythoncom.CoInitialize()
            try:
                self.rename_callback(file_path, new_name, log=self.log)
                self.root.after(0, self.on_task_complete, new_name)

            except FileNotFoundError:
                self.root.after(0, lambda: messagebox.showerror("Error!", "File not found."))
                return
            
            finally:
                pythoncom.CoUninitialize()
            
        # Disable Button and Fields befor executing the program for safety
        self.browse_btn.configure(state="disabled")
        self.ok_btn.configure(state="disabled")
        self.cancel_btn.configure(state="disabled")
        self.about_btn.configure(state="disabled")
        self.file_entry.configure(state="disabled")
        self.new_name_entry.configure(state="disabled")

        threading.Thread(target=task, daemon=True).start()


    def log(self, message):
        self.root.after(0, self._append_log, message)

    def _append_log(self, message):
        self.log_text.config(state="normal")
        self.log_text.insert(tk.END, message + "\n")
        self.log_text.see(tk.END)  # auto-scroll
        self.log_text.config(state="disabled")
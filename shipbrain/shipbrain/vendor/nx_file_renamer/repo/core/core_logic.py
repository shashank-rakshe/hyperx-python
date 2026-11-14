from pathlib import Path
import os
import subprocess
from win32com.client import Dispatch

# NX Root Directory Path
NX_ROOT_DIR = Path(os.getenv("UGII_BASE_DIR"))
# Path to the program "ug_edit_part_names.exe"
UG_EDIT_PATH = NX_ROOT_DIR.joinpath("NXBIN").joinpath("ug_edit_part_names.exe")

def get_file_and_directory(path_to_nx_file_to_rename: Path):
    # Get Directory
    directory = path_to_nx_file_to_rename.parent
    #Get NX file to rename
    nx_file_to_rename = path_to_nx_file_to_rename.name

    return directory, nx_file_to_rename

def check_latest_nx(directory: Path):
    shell = Dispatch("Shell.Application")
    com_object = shell.NameSpace(str(directory))
    # Check for the existence of 'NX Part Type' property
    if com_object.GetDetailsOf(None, 322) == 'NX Part Type':
        latest_nx = True
    else:
        latest_nx = False
        
    return latest_nx, com_object

#For latest version of NX
def get_all_assemblies(path_to_nx_file_to_rename: Path, com_object, nx_files: list):
    for item in com_object.Items():
        # Check for Assembly file and add it to the list
        if item.Path.endswith(".prt") and com_object.GetDetailsOf(item,322) == "Assembly":
            nx_files.append(Path(item.Path))
    # Remove the file that will be renamed from the list, if it is assembly
    if path_to_nx_file_to_rename in nx_files:
        nx_files.remove(path_to_nx_file_to_rename)

#For old version of NX
def get_all_nx_files(path_to_nx_file_to_rename: Path, directory: Path, nx_files: list):
    for file in directory.iterdir():
        if file.suffix == '.prt':
            nx_files.append(file)
    # Remove the file that will be renamed from the list 
    nx_files.remove(path_to_nx_file_to_rename)


def get_components(nx_file: Path):
    #Check for the components of the NX files
    args = [str(UG_EDIT_PATH), str(nx_file), "-list"]
    result = subprocess.run(args, capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW)
    output = result.stdout
    output = output.decode("utf-8", errors="ignore")
    components = output.splitlines()

    return components


def update_nx_links(nx_file: Path, nx_file_to_rename, new_name):
        # Rules: ug_edit_part_names assembly.prt -o assembly.prt -change_name current_name.prt new_name.prt
        rename_args = [
            str(UG_EDIT_PATH),
            str(nx_file),
            "-o",
            str(nx_file),
            "-change_name",
            nx_file_to_rename,
            new_name
        ]
        subprocess.run(rename_args,creationflags=subprocess.CREATE_NO_WINDOW)

#For latest version of NX
def process_nx_file_latest(nx_file, nx_file_to_rename, new_name):
    components = get_components(nx_file)
    if any(nx_file_to_rename in component for component in components):
        # Update the link/reference of each Assembly or Drawing file
        update_nx_links(nx_file, nx_file_to_rename, new_name)
        return f"{nx_file.name} is informed about renaming\n"

#For old version of NX
def process_nx_file_old(nx_file, nx_file_to_rename, new_name):
    components = get_components(nx_file)
    # If no. of children is more than one then it is a Asssembly or Drawing file.
    if len(components) > 1:
        if any(nx_file_to_rename in component for component in components):
            # Update the link/reference of each Assembly or Drawing file
            update_nx_links(nx_file, nx_file_to_rename, new_name)
            return nx_file



def change_file_name(path_to_nx_file_to_rename:Path, new_name):
    renamed_path = path_to_nx_file_to_rename.with_name(new_name)
    path_to_nx_file_to_rename.rename(renamed_path)
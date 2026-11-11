from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

from .core_logic import get_file_and_directory, check_latest_nx, change_file_name
from .core_logic import get_all_assemblies, get_all_nx_files
from .core_logic import process_nx_file_latest, process_nx_file_old


def rename_nx_file(path_to_nx_file_to_rename:str, new_name:str, log=print):

    # Take the New Name that would be used to rename the file
    new_name = new_name + ".prt"

    # Get Windows specific Path
    path_to_nx_file_to_rename: Path = Path(path_to_nx_file_to_rename)

    # Get Directory and NX file to rename
    directory, nx_file_to_rename = get_file_and_directory(path_to_nx_file_to_rename)

    # Check for latest version of NX and get Windows COM Object
    latest_nx, com_object = check_latest_nx(directory)

    # Initialize list to collect NX files
    nx_files = []
    process_nx_file = None
    if latest_nx:
        log("Latest NX detected\n")
        # Collect All other NX assemblies and drawings
        get_all_assemblies(path_to_nx_file_to_rename, com_object, nx_files)
        process_nx_file = process_nx_file_latest

    else:
        log("Older NX detected\n")
        # Collect All other NX files
        get_all_nx_files(path_to_nx_file_to_rename, directory, nx_files)
        process_nx_file = process_nx_file_old


    with ThreadPoolExecutor() as executor:
        futures = [
            executor.submit(process_nx_file, nx_file, nx_file_to_rename, new_name)
            for nx_file in nx_files
        ]
        
        for future in as_completed(futures):
            result = future.result()
            if result:
                log(result)

    # Rename the file
    change_file_name(path_to_nx_file_to_rename, new_name)
    log(f"Completed: {path_to_nx_file_to_rename.name} is renamed to {new_name} !")
    


if __name__ == '__main__':
    path_to_nx_file_to_rename = r'D:\Learning Python\NX Rename\nx_part_files\model1_Renamed.prt'
    new_name = 'model1'
    rename_nx_file(path_to_nx_file_to_rename, new_name)

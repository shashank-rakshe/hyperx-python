"""Encode PNG frames under frames/ to vortex_street.mp4 (requires ffmpeg)."""

import glob
import os
import subprocess
import tempfile


def create_video(
    frames_dir: str = "frames",
    output_path: str = "vortex_street.mp4",
    framerate: int = 20,
) -> None:
    pattern = os.path.join(frames_dir, "frame_*.png")
    files = sorted(glob.glob(pattern))
    if not files:
        print(f"No PNG frames found matching {pattern!r}")
        return

    duration = 1.0 / framerate
    lines = ["ffconcat version 1.0"]
    for f in files:
        ap = os.path.abspath(f).replace("\\", "/")
        lines.append(f"file '{ap}'")
        lines.append(f"duration {duration}")
    # Repeat last file so concat demuxer keeps the final frame duration
    ap_last = os.path.abspath(files[-1]).replace("\\", "/")
    lines.append(f"file '{ap_last}'")

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".ffconcat", delete=False, encoding="utf-8"
    ) as tmp:
        tmp.write("\n".join(lines) + "\n")
        list_path = tmp.name

    try:
        cmd = [
            "ffmpeg",
            "-y",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            list_path,
            "-r",
            str(framerate),
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            output_path,
        ]
        print(
            f"Encoding {len(files)} frames -> {output_path!r} ({framerate} fps) ...",
            flush=True,
        )
        subprocess.run(cmd, check=True)
        print(f"Video written: {output_path}")
    finally:
        try:
            os.unlink(list_path)
        except OSError:
            pass


if __name__ == "__main__":
    create_video()

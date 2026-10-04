# Network volumes (RunPod) forbid utime/chmod even for root. shutil.copy2, copytree and move
# (across disks) copy the data first and then fail with EPERM while copying the metadata, which
# aborts the whole operation in ComfyUI nodes. The data is already in place by then, so skip the
# metadata step when the filesystem refuses it.
# Loaded at Python startup via fs_compat.pth in the venv site-packages (see Dockerfile).
import errno
import shutil


def _skip_eperm(fn):
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except PermissionError as e:
            if e.errno != errno.EPERM:  # PermissionError also covers EACCES, which is a real error
                raise
    wrapper.__wrapped__ = fn
    return wrapper


shutil.copystat = _skip_eperm(shutil.copystat)
shutil.copymode = _skip_eperm(shutil.copymode)

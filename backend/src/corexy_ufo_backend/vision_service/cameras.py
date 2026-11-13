"""Find an OpenCV camera index by (part of) the camera's name.

OpenCV opens cameras by index only. On macOS its AVFoundation backend numbers
the cameras in the order of their unique IDs (checked with a C270, an
Innomaker U20CAM and the built-in camera: 0x1112... < 0x1120... < 6C70...),
and `system_profiler SPCameraDataType` lists both names and unique IDs, so the
index of a named camera is its position in that sorted list.

On Windows the DirectShow backend (cv2.CAP_DSHOW, which VisionService uses there)
numbers the cameras in the order DirectShow enumerates its video input devices,
so the index of a named camera is its position in that enumeration (read with
ctypes: no extra dependency).
"""

from __future__ import annotations

import ctypes
import json
import subprocess
import sys
import uuid


def list_cameras_macos() -> list[dict[str, str]]:
    """[{name, unique_id}] in OpenCV AVFoundation index order ([] elsewhere / on error)."""
    if sys.platform != "darwin":
        return []
    try:
        out = subprocess.run(["system_profiler", "SPCameraDataType", "-json"], capture_output=True, text=True,
                             timeout=10, check=True).stdout
        cams = json.loads(out).get("SPCameraDataType", [])
    except (OSError, subprocess.SubprocessError, ValueError):
        return []
    return order_by_unique_id([{"name": str(c.get("_name", "")), "unique_id": str(c.get("spcamera_unique-id", ""))}
                               for c in cams])


def list_cameras_windows() -> list[dict[str, str]]:
    """[{name, unique_id}] in DirectShow order = OpenCV CAP_DSHOW index order ([] elsewhere / on error)."""
    if sys.platform != "win32":
        return []
    try:
        return _dshow_video_inputs()
    except OSError:
        return []


def list_cameras() -> list[dict[str, str]]:
    """The cameras in this platform's OpenCV index order ([] where unknown)."""
    if sys.platform == "darwin":
        return list_cameras_macos()
    return list_cameras_windows()


class _GUID(ctypes.Structure):
    _fields_ = [("data1", ctypes.c_uint32), ("data2", ctypes.c_uint16), ("data3", ctypes.c_uint16),
                ("data4", ctypes.c_ubyte * 8)]


class _VARIANT(ctypes.Structure):  # only vt and a pointer-sized value (a BSTR here) are read
    _fields_ = [("vt", ctypes.c_ushort), ("r1", ctypes.c_ushort), ("r2", ctypes.c_ushort), ("r3", ctypes.c_ushort),
                ("val", ctypes.c_void_p), ("pad", ctypes.c_void_p)]


def _guid(s: str) -> _GUID:
    return _GUID.from_buffer_copy(uuid.UUID(s).bytes_le)


_CLSID_SYSTEM_DEVICE_ENUM = "62BE5D10-60EB-11D0-BD3B-00A0C911CE86"
_IID_ICREATE_DEV_ENUM = "29840822-5B84-11D0-BD3B-00A0C911CE86"
_CLSID_VIDEO_INPUT_DEVICE_CATEGORY = "860BB310-5D01-11D0-BD3B-00A0C911CE86"
_IID_IPROPERTY_BAG = "55272A00-42CB-11CE-8135-00AA004BB851"
_VT_BSTR = 8


def _vtbl(obj: ctypes.c_void_p):
    return ctypes.cast(obj, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents


def _method(obj: ctypes.c_void_p, index: int, *argtypes):
    """COM method `index` of the vtable of `obj` (returns the HRESULT; `obj` is passed as this)."""
    fn = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, *argtypes)(_vtbl(obj)[index])  # type: ignore[attr-defined]
    return lambda *a: fn(obj, *a)


def _release(obj: ctypes.c_void_p) -> None:
    if obj:
        ctypes.WINFUNCTYPE(ctypes.c_ulong, ctypes.c_void_p)(_vtbl(obj)[2])(obj)  # type: ignore[attr-defined]


def _check(hr: int, what: str) -> int:
    if hr < 0:
        raise OSError(f"{what} failed: HRESULT 0x{hr & 0xFFFFFFFF:08X}")
    return hr


def _dshow_video_inputs() -> list[dict[str, str]]:
    ole32, oleaut32 = ctypes.windll.ole32, ctypes.windll.oleaut32  # type: ignore[attr-defined]
    ole32.CoInitializeEx.restype = ctypes.c_long
    ole32.CoInitializeEx.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    ole32.CoCreateInstance.restype = ctypes.c_long
    ole32.CoCreateInstance.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p,
                                       ctypes.c_void_p]
    oleaut32.VariantClear.argtypes = [ctypes.c_void_p]
    hr = ole32.CoInitializeEx(None, 0)  # COINIT_MULTITHREADED; RPC_E_CHANGED_MODE (< 0): COM already set up
    initialized = hr >= 0
    dev_enum, enum_moniker = ctypes.c_void_p(), ctypes.c_void_p()
    cams: list[dict[str, str]] = []
    try:
        clsid, iid = _guid(_CLSID_SYSTEM_DEVICE_ENUM), _guid(_IID_ICREATE_DEV_ENUM)
        _check(ole32.CoCreateInstance(ctypes.byref(clsid), None, 1, ctypes.byref(iid), ctypes.byref(dev_enum)),
               "CoCreateInstance(SystemDeviceEnum)")
        category = _guid(_CLSID_VIDEO_INPUT_DEVICE_CATEGORY)
        # ICreateDevEnum::CreateClassEnumerator; S_FALSE (1): no device in the category
        hr = _check(_method(dev_enum, 3, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32)(
            ctypes.byref(category), ctypes.byref(enum_moniker), 0), "CreateClassEnumerator")
        if hr != 0 or not enum_moniker:
            return []
        bag_iid = _guid(_IID_IPROPERTY_BAG)
        nxt = _method(enum_moniker, 3, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p)  # IEnumMoniker::Next
        while True:
            moniker, fetched = ctypes.c_void_p(), ctypes.c_ulong()
            if nxt(1, ctypes.byref(moniker), ctypes.byref(fetched)) != 0 or fetched.value != 1:
                break
            bag = ctypes.c_void_p()
            try:
                # IMoniker::BindToStorage (after IUnknown 0-2, IPersist 3, IPersistStream 4-7, BindToObject 8)
                if _method(moniker, 9, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(
                        None, None, ctypes.byref(bag_iid), ctypes.byref(bag)) < 0:
                    cams.append({"name": "", "unique_id": ""})  # keep the position: it is the index
                    continue
                read = _method(bag, 3, ctypes.c_wchar_p, ctypes.c_void_p, ctypes.c_void_p)  # IPropertyBag::Read
                props: dict[str, str] = {}
                for key in ("FriendlyName", "DevicePath"):
                    v = _VARIANT()
                    if read(key, ctypes.byref(v), None) >= 0 and v.vt == _VT_BSTR and v.val:
                        props[key] = ctypes.wstring_at(v.val)
                    oleaut32.VariantClear(ctypes.byref(v))
                cams.append({"name": props.get("FriendlyName", ""), "unique_id": props.get("DevicePath", "")})
            finally:
                _release(bag)
                _release(moniker)
    finally:
        _release(enum_moniker)
        _release(dev_enum)
        if initialized:
            ole32.CoUninitialize()
    return cams


def order_by_unique_id(cams: list[dict[str, str]]) -> list[dict[str, str]]:
    return sorted(cams, key=lambda c: c["unique_id"])


def index_by_name(cams: list[dict[str, str]], pattern: str) -> int | None:
    p = pattern.strip().lower()
    if not p:
        return None
    for i, c in enumerate(cams):
        if p in c["name"].lower():
            return i
    return None


def resolve_camera(spec: str) -> int:
    """`spec` is an index ("1") or part of a camera name ("C270")."""
    s = spec.strip()
    if s.lstrip("-").isdigit():
        return int(s)
    cams = list_cameras()
    idx = index_by_name(cams, s)
    if idx is None:
        if sys.platform not in ("darwin", "win32"):
            raise ValueError(f"camera names work on macOS and Windows only: give {spec!r} as an index")
        raise ValueError(f"no camera named like {spec!r} (cameras: {[c['name'] for c in cams]})")
    return idx

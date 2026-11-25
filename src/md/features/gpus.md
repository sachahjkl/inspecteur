# The GPUs (gpu.odin, gpu_linux.odin)

NVML (NVIDIA's library) for NVIDIA, amdgpu's files for AMD, the name for Intel. The GPUs are read on a thread of their
own, every 2 s.

## Cost and power

A GPU that the kernel puts to sleep (runtime power management, a laptop's second GPU) must not be woken to be watched:
NVML wakes it and keeps it awake. The calls that tell of each process (`graphics`, `compute`,
`samples`) take most of a reading's time. So:

- NVML is opened only while the GPUs' numbers are wanted (the Performance section or a GPU column shown) and no NVIDIA
  GPU sleeps, and closed when they are no longer wanted.
- A GPU that sleeps is listed "asleep".
- A GPU that is always on keeps NVML open and reads device utilization for the summary tile and diagnosis, but skips
  per-process NVML queries unless the `GPU` or `GPU memory` column or the Properties are shown. The ask is a field of
  the snapshot (`Gpu_Snapshot.want_procs`): a system's reader that does not know it gives them anyway.
- NVML's handles, names and driver version are asked once per opening. The DRM cards are listed again every ten
  readings, as the machine's other devices.

The graphs of a GPU get a point per reading (every 2 s): their span is twice the others'.

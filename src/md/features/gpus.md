# The GPUs (gpu.odin, gpu_linux.odin)

NVML (NVIDIA's library) for NVIDIA, amdgpu's files for AMD, the name for Intel. The GPUs are read on a thread of their
own, every 2 s.

## A sleeping GPU is not woken

A GPU that the kernel may put to sleep (runtime power management, a laptop's second GPU) must not be woken to be
watched: NVML wakes it and keeps it awake. So:

- NVML is opened only while the GPUs' numbers are wanted (the Performance section or the GPU memory column shown) and no
  NVIDIA GPU sleeps, and closed when they are no longer wanted.
- A GPU that sleeps is listed "asleep".
- A GPU that is always on keeps NVML open.

The graphs of a GPU get a point per reading (every 2 s): their span is twice the others'.

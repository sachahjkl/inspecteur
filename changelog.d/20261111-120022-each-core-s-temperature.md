type: Added

**Each core's temperature**, in the logical processors' view (Ctrl+G) and, coolest to hottest, in the CPU's details: from coretemp's "Core N" sensors (Intel), else from the SMU's power table of the ryzen_smu driver (AMD, Zen to Zen 3; NixOS: `hardware.cpu.amd.ryzen-smu.enable`). Without either, nothing is shown.

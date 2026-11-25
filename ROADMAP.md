# Roadmap

## Now

## Next

- **Windows ARM64 release**: enable `-target:windows_arm64` checks and release archives once Odin and `vendor:wgpu` add Windows ARM64 support (`src/winapi` layouts already verify `arm64` alignment and offsets).
- **Task Scheduler toggle on Windows**: support enabling and disabling logon tasks in the Startup section via the Task Scheduler COM API (`ITaskService`), matching `StartupApproved` toggling for Registry Run keys and Startup folders.

## Later

- **macOS port**: implement native Darwin readers (`*_darwin.odin`) and macOS-specific LaunchAgents/LaunchDaemons Services and Startup views ([porting.md](src/md/infrastructure/porting.md)).

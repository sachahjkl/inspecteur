package winapi

// Pure Windows NT and Win32 binary layouts for 64-bit (amd64, arm64) and 32-bit WOW64 structures.
// Every layout carries compile-time size_of and offset_of assertions against the Windows SDK and WDK headers,
// so buffer decoders can run and be tested on any host OS.

// Fixed-width fields guarantee identical binary layout on Windows amd64, Windows arm64, Linux, and macOS.

UNICODE_STRING64 :: struct {
	Length:        u16,
	MaximumLength: u16,
	_pad:          u32,
	Buffer:        u64,
}
#assert(size_of(UNICODE_STRING64) == 16)
#assert(offset_of(UNICODE_STRING64, Buffer) == 8)

UNICODE_STRING32 :: struct {
	Length:        u16,
	MaximumLength: u16,
	Buffer:        u32,
}
#assert(size_of(UNICODE_STRING32) == 8)
#assert(offset_of(UNICODE_STRING32, Buffer) == 4)

CLIENT_ID64 :: struct {
	UniqueProcess: u64,
	UniqueThread:  u64,
}
#assert(size_of(CLIENT_ID64) == 16)
#assert(offset_of(CLIENT_ID64, UniqueThread) == 8)

SYSTEM_THREAD_INFORMATION64 :: struct {
	KernelTime:      i64,
	UserTime:        i64,
	CreateTime:      i64,
	WaitTime:        u32,
	_pad0:           u32,
	StartAddress:    u64,
	ClientId:        CLIENT_ID64,
	Priority:        i32,
	BasePriority:    i32,
	ContextSwitches: u32,
	ThreadState:     u32,
	WaitReason:      u32,
	_pad1:           u32,
}
#assert(size_of(SYSTEM_THREAD_INFORMATION64) == 80)
#assert(offset_of(SYSTEM_THREAD_INFORMATION64, WaitTime) == 24)
#assert(offset_of(SYSTEM_THREAD_INFORMATION64, StartAddress) == 32)
#assert(offset_of(SYSTEM_THREAD_INFORMATION64, ClientId) == 40)
#assert(offset_of(SYSTEM_THREAD_INFORMATION64, Priority) == 56)
#assert(offset_of(SYSTEM_THREAD_INFORMATION64, BasePriority) == 60)
#assert(offset_of(SYSTEM_THREAD_INFORMATION64, ContextSwitches) == 64)
#assert(offset_of(SYSTEM_THREAD_INFORMATION64, ThreadState) == 68)
#assert(offset_of(SYSTEM_THREAD_INFORMATION64, WaitReason) == 72)

SYSTEM_PROCESS_INFORMATION64 :: struct {
	NextEntryOffset:              u32,
	NumberOfThreads:              u32,
	WorkingSetPrivateSize:        i64,
	HardFaultCount:               u32,
	NumberOfThreadsHighWatermark: u32,
	CycleTime:                    u64,
	CreateTime:                   i64,
	UserTime:                     i64,
	KernelTime:                   i64,
	ImageName:                    UNICODE_STRING64,
	BasePriority:                 i32,
	_pad0:                        u32,
	UniqueProcessId:              u64,
	InheritedFromUniqueProcessId: u64,
	HandleCount:                  u32,
	SessionId:                    u32,
	UniqueProcessKey:             u64,
	PeakVirtualSize:              u64,
	VirtualSize:                  u64,
	PageFaultCount:               u32,
	_pad1:                        u32,
	PeakWorkingSetSize:           u64,
	WorkingSetSize:               u64,
	QuotaPeakPagedPoolUsage:      u64,
	QuotaPagedPoolUsage:          u64,
	QuotaPeakNonPagedPoolUsage:   u64,
	QuotaNonPagedPoolUsage:       u64,
	PagefileUsage:                u64,
	PeakPagefileUsage:            u64,
	PrivatePageCount:             u64,
	ReadOperationCount:           i64,
	WriteOperationCount:          i64,
	OtherOperationCount:          i64,
	ReadTransferCount:            i64,
	WriteTransferCount:           i64,
	OtherTransferCount:           i64,
}
#assert(size_of(SYSTEM_PROCESS_INFORMATION64) == 256)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, WorkingSetPrivateSize) == 0x08)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, CreateTime) == 0x20)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, UserTime) == 0x28)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, KernelTime) == 0x30)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, ImageName) == 0x38)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, BasePriority) == 0x48)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, UniqueProcessId) == 0x50)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, InheritedFromUniqueProcessId) == 0x58)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, HandleCount) == 0x60)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, SessionId) == 0x64)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, PageFaultCount) == 0x80)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, WorkingSetSize) == 0x90)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, PagefileUsage) == 0xB8)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, PrivatePageCount) == 0xC8)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, ReadTransferCount) == 0xE8)
#assert(offset_of(SYSTEM_PROCESS_INFORMATION64, WriteTransferCount) == 0xF0)

SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION :: struct {
	IdleTime:       i64,
	KernelTime:     i64,
	UserTime:       i64,
	DpcTime:        i64,
	InterruptTime:  i64,
	InterruptCount: u32,
	_pad:           u32,
}
#assert(size_of(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION) == 48)
#assert(offset_of(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION, KernelTime) == 8)
#assert(offset_of(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION, UserTime) == 16)
#assert(offset_of(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION, InterruptCount) == 40)

SYSTEM_TIMEOFDAY_INFORMATION :: struct {
	BootTime:      i64,
	CurrentTime:   i64,
	TimeZoneBias:  i64,
	TimeZoneId:    u32,
	Reserved:      u32,
	BootTimeBias:  u64,
	SleepTimeBias: u64,
}
#assert(size_of(SYSTEM_TIMEOFDAY_INFORMATION) == 48)
#assert(offset_of(SYSTEM_TIMEOFDAY_INFORMATION, CurrentTime) == 8)
#assert(offset_of(SYSTEM_TIMEOFDAY_INFORMATION, BootTimeBias) == 32)
#assert(offset_of(SYSTEM_TIMEOFDAY_INFORMATION, SleepTimeBias) == 40)

SYSTEM_HANDLE_INFORMATION_EX64_HEADER :: struct {
	NumberOfHandles: u64,
	Reserved:        u64,
}
#assert(size_of(SYSTEM_HANDLE_INFORMATION_EX64_HEADER) == 16)

SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64 :: struct {
	Object:                u64,
	UniqueProcessId:       u64,
	HandleValue:           u64,
	GrantedAccess:         u32,
	CreatorBackTraceIndex: u16,
	ObjectTypeIndex:       u16,
	HandleAttributes:      u32,
	Reserved:              u32,
}
#assert(size_of(SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64) == 40)
#assert(offset_of(SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64, UniqueProcessId) == 8)
#assert(offset_of(SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64, HandleValue) == 16)
#assert(offset_of(SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64, GrantedAccess) == 24)
#assert(offset_of(SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64, ObjectTypeIndex) == 30)
#assert(offset_of(SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64, HandleAttributes) == 32)

PROCESS_BASIC_INFORMATION64 :: struct {
	ExitStatus:                   i32,
	_pad0:                        u32,
	PebBaseAddress:               u64,
	AffinityMask:                 u64,
	BasePriority:                 i32,
	_pad1:                        u32,
	UniqueProcessId:              u64,
	InheritedFromUniqueProcessId: u64,
}
#assert(size_of(PROCESS_BASIC_INFORMATION64) == 48)
#assert(offset_of(PROCESS_BASIC_INFORMATION64, PebBaseAddress) == 8)
#assert(offset_of(PROCESS_BASIC_INFORMATION64, UniqueProcessId) == 32)

PEB64_HEAD :: struct {
	InheritedAddressSpace:    u8,
	ReadImageFileExecOptions: u8,
	BeingDebugged:            u8,
	BitField:                 u8,
	_pad0:                    u32,
	Mutant:                   u64,
	ImageBaseAddress:         u64,
	Ldr:                      u64,
	ProcessParameters:        u64,
}
#assert(size_of(PEB64_HEAD) == 40)
#assert(offset_of(PEB64_HEAD, ProcessParameters) == 0x20)

PEB32_HEAD :: struct {
	InheritedAddressSpace:    u8,
	ReadImageFileExecOptions: u8,
	BeingDebugged:            u8,
	BitField:                 u8,
	Mutant:                   u32,
	ImageBaseAddress:         u32,
	Ldr:                      u32,
	ProcessParameters:        u32,
}
#assert(size_of(PEB32_HEAD) == 20)
#assert(offset_of(PEB32_HEAD, ProcessParameters) == 0x10)

RTL_DRIVE_LETTER_CURDIR64 :: struct {
	Flags:     u16,
	Length:    u16,
	TimeStamp: u32,
	DosPath:   UNICODE_STRING64,
}
#assert(size_of(RTL_DRIVE_LETTER_CURDIR64) == 24)

RTL_DRIVE_LETTER_CURDIR32 :: struct {
	Flags:     u16,
	Length:    u16,
	TimeStamp: u32,
	DosPath:   UNICODE_STRING32,
}
#assert(size_of(RTL_DRIVE_LETTER_CURDIR32) == 16)

RTL_USER_PROCESS_PARAMETERS64 :: struct {
	MaximumLength:          u32,
	Length:                 u32,
	Flags:                  u32,
	DebugFlags:             u32,
	ConsoleHandle:          u64,
	ConsoleFlags:           u32,
	_pad0:                  u32,
	StandardInput:          u64,
	StandardOutput:         u64,
	StandardError:          u64,
	CurrentDirectoryPath:   UNICODE_STRING64,
	CurrentDirectoryHandle: u64,
	DllPath:                UNICODE_STRING64,
	ImagePathName:          UNICODE_STRING64,
	CommandLine:            UNICODE_STRING64,
	Environment:            u64,
	StartingX:              u32,
	StartingY:              u32,
	CountX:                 u32,
	CountY:                 u32,
	CountCharsX:            u32,
	CountCharsY:            u32,
	FillAttribute:          u32,
	WindowFlags:            u32,
	ShowWindowFlags:        u32,
	_pad1:                  u32,
	WindowTitle:            UNICODE_STRING64,
	DesktopInfo:            UNICODE_STRING64,
	ShellInfo:              UNICODE_STRING64,
	RuntimeData:            UNICODE_STRING64,
	CurrentDirectores:      [32]RTL_DRIVE_LETTER_CURDIR64,
	EnvironmentSize:        u64,
	EnvironmentVersion:     u64,
}
#assert(size_of(RTL_USER_PROCESS_PARAMETERS64) == 0x400)
#assert(offset_of(RTL_USER_PROCESS_PARAMETERS64, CurrentDirectoryPath) == 0x38)
#assert(offset_of(RTL_USER_PROCESS_PARAMETERS64, ImagePathName) == 0x60)
#assert(offset_of(RTL_USER_PROCESS_PARAMETERS64, CommandLine) == 0x70)
#assert(offset_of(RTL_USER_PROCESS_PARAMETERS64, Environment) == 0x80)
#assert(offset_of(RTL_USER_PROCESS_PARAMETERS64, EnvironmentSize) == 0x3F0)

RTL_USER_PROCESS_PARAMETERS32 :: struct {
	MaximumLength:          u32,
	Length:                 u32,
	Flags:                  u32,
	DebugFlags:             u32,
	ConsoleHandle:          u32,
	ConsoleFlags:           u32,
	StandardInput:          u32,
	StandardOutput:         u32,
	StandardError:          u32,
	CurrentDirectoryPath:   UNICODE_STRING32,
	CurrentDirectoryHandle: u32,
	DllPath:                UNICODE_STRING32,
	ImagePathName:          UNICODE_STRING32,
	CommandLine:            UNICODE_STRING32,
	Environment:            u32,
	StartingX:              u32,
	StartingY:              u32,
	CountX:                 u32,
	CountY:                 u32,
	CountCharsX:            u32,
	CountCharsY:            u32,
	FillAttribute:          u32,
	WindowFlags:            u32,
	ShowWindowFlags:        u32,
	WindowTitle:            UNICODE_STRING32,
	DesktopInfo:            UNICODE_STRING32,
	ShellInfo:              UNICODE_STRING32,
	RuntimeData:            UNICODE_STRING32,
	CurrentDirectores:      [32]RTL_DRIVE_LETTER_CURDIR32,
	EnvironmentSize:        u32,
	EnvironmentVersion:     u32,
}
#assert(size_of(RTL_USER_PROCESS_PARAMETERS32) == 0x298)
#assert(offset_of(RTL_USER_PROCESS_PARAMETERS32, CurrentDirectoryPath) == 0x24)
#assert(offset_of(RTL_USER_PROCESS_PARAMETERS32, ImagePathName) == 0x38)
#assert(offset_of(RTL_USER_PROCESS_PARAMETERS32, CommandLine) == 0x40)
#assert(offset_of(RTL_USER_PROCESS_PARAMETERS32, Environment) == 0x48)
#assert(offset_of(RTL_USER_PROCESS_PARAMETERS32, EnvironmentSize) == 0x290)

MIB_TCPROW_OWNER_PID :: struct {
	dwState:      u32,
	dwLocalAddr:  u32,
	dwLocalPort:  u32,
	dwRemoteAddr: u32,
	dwRemotePort: u32,
	dwOwningPid:  u32,
}
#assert(size_of(MIB_TCPROW_OWNER_PID) == 24)
#assert(offset_of(MIB_TCPROW_OWNER_PID, dwOwningPid) == 20)

MIB_TCP6ROW_OWNER_PID :: struct {
	ucLocalAddr:     [16]u8,
	dwLocalScopeId:  u32,
	dwLocalPort:     u32,
	ucRemoteAddr:    [16]u8,
	dwRemoteScopeId: u32,
	dwRemotePort:    u32,
	dwState:         u32,
	dwOwningPid:     u32,
}
#assert(size_of(MIB_TCP6ROW_OWNER_PID) == 56)
#assert(offset_of(MIB_TCP6ROW_OWNER_PID, ucRemoteAddr) == 24)
#assert(offset_of(MIB_TCP6ROW_OWNER_PID, dwState) == 48)
#assert(offset_of(MIB_TCP6ROW_OWNER_PID, dwOwningPid) == 52)

MIB_UDPROW_OWNER_PID :: struct {
	dwLocalAddr: u32,
	dwLocalPort: u32,
	dwOwningPid: u32,
}
#assert(size_of(MIB_UDPROW_OWNER_PID) == 12)
#assert(offset_of(MIB_UDPROW_OWNER_PID, dwOwningPid) == 8)

MIB_UDP6ROW_OWNER_PID :: struct {
	ucLocalAddr:    [16]u8,
	dwLocalScopeId: u32,
	dwLocalPort:    u32,
	dwOwningPid:    u32,
}
#assert(size_of(MIB_UDP6ROW_OWNER_PID) == 28)
#assert(offset_of(MIB_UDP6ROW_OWNER_PID, dwLocalPort) == 20)
#assert(offset_of(MIB_UDP6ROW_OWNER_PID, dwOwningPid) == 24)

DISK_PERFORMANCE :: struct {
	BytesRead:           i64,
	BytesWritten:        i64,
	ReadTime:            i64,
	WriteTime:           i64,
	IdleTime:            i64,
	ReadCount:           u32,
	WriteCount:          u32,
	QueueDepth:          u32,
	SplitCount:          u32,
	QueryTime:           i64,
	StorageDeviceNumber: u32,
	StorageManagerName:  [8]u16,
	_pad:                u32,
}
#assert(size_of(DISK_PERFORMANCE) == 88)
#assert(offset_of(DISK_PERFORMANCE, ReadCount) == 40)
#assert(offset_of(DISK_PERFORMANCE, QueryTime) == 56)
#assert(offset_of(DISK_PERFORMANCE, StorageDeviceNumber) == 64)
#assert(offset_of(DISK_PERFORMANCE, StorageManagerName) == 68)

STORAGE_DEVICE_DESCRIPTOR_HEADER :: struct {
	Version:               u32,
	Size:                  u32,
	DeviceType:            u8,
	DeviceTypeModifier:    u8,
	RemovableMedia:        u8,
	CommandQueueing:       u8,
	VendorIdOffset:        u32,
	ProductIdOffset:       u32,
	ProductRevisionOffset: u32,
	SerialNumberOffset:    u32,
	BusType:               u32,
	RawPropertiesLength:   u32,
}
#assert(size_of(STORAGE_DEVICE_DESCRIPTOR_HEADER) == 36)
#assert(offset_of(STORAGE_DEVICE_DESCRIPTOR_HEADER, VendorIdOffset) == 12)
#assert(offset_of(STORAGE_DEVICE_DESCRIPTOR_HEADER, ProductIdOffset) == 16)
#assert(offset_of(STORAGE_DEVICE_DESCRIPTOR_HEADER, BusType) == 28)

DEVICE_SEEK_PENALTY_DESCRIPTOR :: struct {
	Version:           u32,
	Size:              u32,
	IncursSeekPenalty: u8,
	_pad:              [3]u8,
}
#assert(size_of(DEVICE_SEEK_PENALTY_DESCRIPTOR) == 12)
#assert(offset_of(DEVICE_SEEK_PENALTY_DESCRIPTOR, IncursSeekPenalty) == 8)

DISK_EXTENT :: struct {
	DiskNumber:     u32,
	_pad:           u32,
	StartingOffset: i64,
	ExtentLength:   i64,
}
#assert(size_of(DISK_EXTENT) == 24)
#assert(offset_of(DISK_EXTENT, StartingOffset) == 8)

VOLUME_DISK_EXTENTS_HEADER :: struct {
	NumberOfDiskExtents: u32,
	_pad:                u32,
}
#assert(size_of(VOLUME_DISK_EXTENTS_HEADER) == 8)

PROCESSOR_POWER_INFORMATION :: struct {
	Number:           u32,
	MaxMhz:           u32,
	CurrentMhz:       u32,
	MhzLimit:         u32,
	MaxIdleState:     u32,
	CurrentIdleState: u32,
}
#assert(size_of(PROCESSOR_POWER_INFORMATION) == 24)

// winnt.h SYSTEM_CPU_SET_INFORMATION, its CpuSet alone (the one type there is).
SYSTEM_CPU_SET_INFORMATION :: struct {
	Size:                  u32,
	Type:                  u32,
	Id:                    u32,
	Group:                 u16,
	LogicalProcessorIndex: u8,
	CoreIndex:             u8,
	LastLevelCacheIndex:   u8,
	NumaNodeIndex:         u8,
	EfficiencyClass:       u8,
	AllFlags:              u8,
	SchedulingClass:       u32,
	AllocationTag:         u64,
}
#assert(size_of(SYSTEM_CPU_SET_INFORMATION) == 32)
#assert(offset_of(SYSTEM_CPU_SET_INFORMATION, Id) == 8)
#assert(offset_of(SYSTEM_CPU_SET_INFORMATION, Group) == 12)
#assert(offset_of(SYSTEM_CPU_SET_INFORMATION, LogicalProcessorIndex) == 14)
#assert(offset_of(SYSTEM_CPU_SET_INFORMATION, AllocationTag) == 24)

// winioctl.h DISK_GEOMETRY_EX, without its variable end (Data).
DISK_GEOMETRY_EX_HEAD :: struct {
	Cylinders:         i64,
	MediaType:         u32,
	TracksPerCylinder: u32,
	SectorsPerTrack:   u32,
	BytesPerSector:    u32,
	DiskSize:          i64,
}
#assert(size_of(DISK_GEOMETRY_EX_HEAD) == 32)
#assert(offset_of(DISK_GEOMETRY_EX_HEAD, DiskSize) == 24)

// setupapi.h SP_DEVICE_INTERFACE_DATA (64-bit): the caller's cbSize must be this size exactly.
SP_DEVICE_INTERFACE_DATA64 :: struct {
	cbSize:             u32,
	InterfaceClassGuid: [4]u32,
	Flags:              u32,
	Reserved:           u64,
}
#assert(size_of(SP_DEVICE_INTERFACE_DATA64) == 32)
#assert(offset_of(SP_DEVICE_INTERFACE_DATA64, Reserved) == 24)

// psapi.h ENUM_PAGE_FILE_INFORMATION (64-bit): pages.
ENUM_PAGE_FILE_INFORMATION64 :: struct {
	cb:         u32,
	Reserved:   u32,
	TotalSize:  u64,
	TotalInUse: u64,
	PeakUsage:  u64,
}
#assert(size_of(ENUM_PAGE_FILE_INFORMATION64) == 32)

PROCESS_POWER_THROTTLING_STATE :: struct {
	Version:     u32,
	ControlMask: u32,
	StateMask:   u32,
}
#assert(size_of(PROCESS_POWER_THROTTLING_STATE) == 12)

WAITCHAIN_LOCK_OBJECT :: struct {
	ObjectName: [128]u16,
	Timeout:    i64,
	Alertable:  u32,
	_pad:       u32,
}
#assert(size_of(WAITCHAIN_LOCK_OBJECT) == 272)

WAITCHAIN_THREAD_OBJECT :: struct {
	ProcessId:       u32,
	ThreadId:        u32,
	WaitTime:        u32,
	ContextSwitches: u32,
}
#assert(size_of(WAITCHAIN_THREAD_OBJECT) == 16)

WAITCHAIN_NODE_INFO :: struct {
	ObjectType:   u32,
	ObjectStatus: u32,
	Union:        struct #raw_union {
		LockObject:   WAITCHAIN_LOCK_OBJECT,
		ThreadObject: WAITCHAIN_THREAD_OBJECT,
	},
}
#assert(size_of(WAITCHAIN_NODE_INFO) == 280)
#assert(offset_of(WAITCHAIN_NODE_INFO, Union) == 8)

SERVICE_STATUS_PROCESS :: struct {
	dwServiceType:             u32,
	dwCurrentState:            u32,
	dwControlsAccepted:        u32,
	dwWin32ExitCode:           u32,
	dwServiceSpecificExitCode: u32,
	dwCheckPoint:              u32,
	dwWaitHint:                u32,
	dwProcessId:               u32,
	dwServiceFlags:            u32,
}
#assert(size_of(SERVICE_STATUS_PROCESS) == 36)
#assert(offset_of(SERVICE_STATUS_PROCESS, dwProcessId) == 28)

ENUM_SERVICE_STATUS_PROCESSW64 :: struct {
	lpServiceName:        u64,
	lpDisplayName:        u64,
	ServiceStatusProcess: SERVICE_STATUS_PROCESS,
	_pad:                 u32,
}
#assert(size_of(ENUM_SERVICE_STATUS_PROCESSW64) == 56)
#assert(offset_of(ENUM_SERVICE_STATUS_PROCESSW64, ServiceStatusProcess) == 16)

QUERY_SERVICE_CONFIGW64 :: struct {
	dwServiceType:      u32,
	dwStartType:        u32,
	dwErrorControl:     u32,
	_pad0:              u32,
	lpBinaryPathName:   u64,
	lpLoadOrderGroup:   u64,
	dwTagId:            u32,
	_pad1:              u32,
	lpDependencies:     u64,
	lpServiceStartName: u64,
	lpDisplayName:      u64,
}
#assert(size_of(QUERY_SERVICE_CONFIGW64) == 64)
#assert(offset_of(QUERY_SERVICE_CONFIGW64, lpBinaryPathName) == 16)
#assert(offset_of(QUERY_SERVICE_CONFIGW64, lpDependencies) == 40)
#assert(offset_of(QUERY_SERVICE_CONFIGW64, lpServiceStartName) == 48)
#assert(offset_of(QUERY_SERVICE_CONFIGW64, lpDisplayName) == 56)

SMBIOS_RAW_HEADER :: struct {
	Used20CallingMethod: u8,
	SMBIOSMajorVersion:  u8,
	SMBIOSMinorVersion:  u8,
	DmiRevision:         u8,
	Length:              u32,
}
#assert(size_of(SMBIOS_RAW_HEADER) == 8)
#assert(offset_of(SMBIOS_RAW_HEADER, Length) == 4)

PS_PROTECTION :: struct {
	Level: u8,
}
#assert(size_of(PS_PROTECTION) == 1)

// netioapi.h MIB_IF_ROW2 (64-bit Windows ABI, identical on amd64 and arm64).
MIB_IF_ROW2 :: struct {
	InterfaceLuid:               u64,
	InterfaceIndex:              u32,
	InterfaceGuid:               [16]u8,
	Alias:                       [257]u16,
	Description:                 [257]u16,
	PhysicalAddressLength:       u32,
	PhysicalAddress:             [32]u8,
	PermanentPhysicalAddress:    [32]u8,
	Mtu:                         u32,
	Type:                        u32,
	TunnelType:                  i32,
	MediaType:                   i32,
	PhysicalMediumType:          i32,
	AccessType:                  i32,
	DirectionType:               i32,
	InterfaceAndOperStatusFlags: u8,
	_pad0:                       [3]u8,
	OperStatus:                  i32,
	AdminStatus:                 i32,
	MediaConnectState:           i32,
	NetworkGuid:                 [16]u8,
	ConnectionType:              i32,
	_pad1:                       u32,
	TransmitLinkSpeed:           u64,
	ReceiveLinkSpeed:            u64,
	InOctets:                    u64,
	InUcastPkts:                 u64,
	InNUcastPkts:                u64,
	InDiscards:                  u64,
	InErrors:                    u64,
	InUnknownProtos:             u64,
	InUcastOctets:               u64,
	InMulticastOctets:           u64,
	InBroadcastOctets:           u64,
	OutOctets:                   u64,
	OutUcastPkts:                u64,
	OutNUcastPkts:               u64,
	OutDiscards:                 u64,
	OutErrors:                   u64,
	OutUcastOctets:              u64,
	OutMulticastOctets:          u64,
	OutBroadcastOctets:          u64,
	OutQLen:                     u64,
}
#assert(size_of(MIB_IF_ROW2) == 1352)
#assert(offset_of(MIB_IF_ROW2, Alias) == 28)
#assert(offset_of(MIB_IF_ROW2, Description) == 542)
#assert(offset_of(MIB_IF_ROW2, PhysicalAddressLength) == 1056)
#assert(offset_of(MIB_IF_ROW2, Type) == 1128)
#assert(offset_of(MIB_IF_ROW2, OperStatus) == 1156)
#assert(offset_of(MIB_IF_ROW2, TransmitLinkSpeed) == 1192)
#assert(offset_of(MIB_IF_ROW2, InOctets) == 1208)
#assert(offset_of(MIB_IF_ROW2, OutOctets) == 1280)

MIB_IF_TABLE2_HEADER :: struct {
	NumEntries: u32,
	_pad:       u32,
}
#assert(size_of(MIB_IF_TABLE2_HEADER) == 8)

// Windows NT / Win32 constants shared between decoders and OS readers.
STATUS_SUCCESS              :: u32(0x00000000)
STATUS_INFO_LENGTH_MISMATCH :: u32(0xC0000004)
STATUS_BUFFER_TOO_SMALL     :: u32(0xC0000023)
STATUS_BUFFER_OVERFLOW      :: u32(0x80000005)
STATUS_ACCESS_DENIED        :: u32(0xC0000022)

// Windows priority classes.
IDLE_PRIORITY_CLASS         :: u32(0x00000040)
BELOW_NORMAL_PRIORITY_CLASS :: u32(0x00004000)
NORMAL_PRIORITY_CLASS       :: u32(0x00000020)
ABOVE_NORMAL_PRIORITY_CLASS :: u32(0x00008000)
HIGH_PRIORITY_CLASS         :: u32(0x00000080)
REALTIME_PRIORITY_CLASS     :: u32(0x00000100)

// PROCESS_POWER_THROTTLING constants (Windows 11 EcoQoS / Efficiency Mode).
PROCESS_POWER_THROTTLING_CURRENT_VERSION :: u32(1)
PROCESS_POWER_THROTTLING_EXECUTION_SPEED :: u32(0x1)

// Storage bus types (STORAGE_BUS_TYPE).
BUS_TYPE_UNKNOWN :: u32(0)
BUS_TYPE_SCSI    :: u32(1)
BUS_TYPE_ATAPI   :: u32(2)
BUS_TYPE_ATA     :: u32(3)
BUS_TYPE_USB     :: u32(7)
BUS_TYPE_RAID    :: u32(8)
BUS_TYPE_ISCSI   :: u32(9)
BUS_TYPE_SAS     :: u32(10)
BUS_TYPE_SATA    :: u32(11)
BUS_TYPE_SD      :: u32(12)
BUS_TYPE_MMC     :: u32(13)
BUS_TYPE_VIRTUAL :: u32(14)
BUS_TYPE_SPACES  :: u32(16)
BUS_TYPE_NVME    :: u32(17)
BUS_TYPE_SCM     :: u32(18)

// Security integrity RIDs (winnt.h).
SECURITY_MANDATORY_UNTRUSTED_RID         :: u32(0x0000)
SECURITY_MANDATORY_LOW_RID               :: u32(0x1000)
SECURITY_MANDATORY_MEDIUM_RID            :: u32(0x2000)
SECURITY_MANDATORY_MEDIUM_PLUS_RID       :: u32(0x2100)
SECURITY_MANDATORY_HIGH_RID              :: u32(0x3000)
SECURITY_MANDATORY_SYSTEM_RID            :: u32(0x4000)
SECURITY_MANDATORY_PROTECTED_PROCESS_RID :: u32(0x5000)

// Windows FILETIME ticks (100ns) between 1601-01-01 and 1970-01-01.
FILETIME_UNIX_EPOCH_TICKS :: i64(116_444_736_000_000_000)
FILETIME_TICKS_PER_SEC    :: i64(10_000_000)

// Hard cap on growing NT query buffers to reject hostile sizes.
MAX_NT_BUFFER_BYTES :: 256 * 1024 * 1024

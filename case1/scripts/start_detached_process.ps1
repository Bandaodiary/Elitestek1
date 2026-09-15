<#!
Start a Windows process with CREATE_BREAKAWAY_FROM_JOB when the caller is
running under a desktop/agent job.  The script intentionally prints only the
new process id so it can be called by the detached simulation runners.

This is a small fallback for environments where Win32_Process.Create (WMI/
CIM) is blocked by local policy.  It does not wait for, monitor, or terminate
the child process.
#>
param(
    [Parameter(Mandatory = $true)][string]$CommandLine,
    [Parameter(Mandatory = $true)][string]$CurrentDirectory
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $CurrentDirectory -PathType Container)) {
    throw "CurrentDirectory does not exist: $CurrentDirectory"
}

$typeName = 'C1DetachedProcessNative'
if (-not ([System.Management.Automation.PSTypeName]$typeName).Type) {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class C1DetachedProcessNative {
    private const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
    private const uint CREATE_NO_WINDOW = 0x08000000;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcess(
        string lpApplicationName,
        StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    public static int Start(string commandLine, string currentDirectory) {
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        var pi = new PROCESS_INFORMATION();
        var mutableCommandLine = new StringBuilder(commandLine);
        var flags = CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW;
        if (!CreateProcess(null, mutableCommandLine, IntPtr.Zero, IntPtr.Zero,
                           false, flags, IntPtr.Zero, currentDirectory,
                           ref si, out pi)) {
            var error = Marshal.GetLastWin32Error();
            throw new InvalidOperationException(
                "CreateProcess(CREATE_BREAKAWAY_FROM_JOB) failed, Win32=" + error);
        }
        try {
            return pi.dwProcessId;
        }
        finally {
            if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
            if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
        }
    }
}
'@
}

[C1DetachedProcessNative]::Start($CommandLine, $CurrentDirectory)

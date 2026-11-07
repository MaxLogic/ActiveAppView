#Requires -Version 5.1
<#
.SYNOPSIS
Swaps the running MouseBeam axis arms between light and dark.
.DESCRIPTION
Uses MouseBeam's Swap arm colours command without restarting it or changing
keyboard focus. Start MouseBeam with x-mouse.ps1 first if it is not running.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $lExecutable = 'F:\projects\MaxLogic\MouseBeam\xMouse.exe'
    if (-not (Test-Path -LiteralPath $lExecutable -PathType Leaf)) {
        throw "MouseBeam executable not found: $lExecutable"
    }

    $lSessionId = (Get-Process -Id $PID).SessionId
    $lProcesses = @(Get-Process -Name xMouse -ErrorAction SilentlyContinue | Where-Object {
        $_.SessionId -eq $lSessionId -and $_.Path -ieq $lExecutable
    })
    if ($lProcesses.Count -eq 0) {
        throw 'MouseBeam is not running in this session. Start it with x-mouse.ps1 first.'
    }
    if ($lProcesses.Count -ne 1) {
        throw 'More than one matching MouseBeam instance is running.'
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace MaxLogic.MouseBeam {
    public static class ArmColors {
        private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr window, StringBuilder className, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint RegisterWindowMessage(string name);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(IntPtr window, uint message,
            UIntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);

        public static void Toggle(uint processId) {
            var windows = new List<IntPtr>();
            if (!EnumWindows(delegate(IntPtr window, IntPtr parameter) {
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                if (owner == processId) {
                    var className = new StringBuilder(256);
                    GetClassName(window, className, className.Capacity);
                    if (className.ToString() == "TMainForm") windows.Add(window);
                }
                return true;
            }, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());

            if (windows.Count != 1)
                throw new InvalidOperationException("MouseBeam's control window was not found uniquely.");

            uint message = RegisterWindowMessage("MaxLogic.MouseBeam.ToggleArmColors.v1");
            if (message == 0) throw new Win32Exception(Marshal.GetLastWin32Error());

            UIntPtr result;
            // SMTO_BLOCK | SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT; never broadcast or retry a toggle.
            if (SendMessageTimeout(windows[0], message, UIntPtr.Zero, IntPtr.Zero,
                    0x23, 2000, out result) == IntPtr.Zero)
                throw new InvalidOperationException("MouseBeam did not respond to the color command.",
                    new Win32Exception(Marshal.GetLastWin32Error()));
            if (result.ToUInt64() != 1)
                throw new InvalidOperationException("This MouseBeam version does not support color commands. Rebuild and restart MouseBeam.");
        }
    }
}
'@

    [MaxLogic.MouseBeam.ArmColors]::Toggle([uint32]$lProcesses[0].Id)
    Write-Output "Swapped MouseBeam arm colors (PID $($lProcesses[0].Id))."
    [Environment]::Exit(0)
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    [Environment]::Exit(1)
}

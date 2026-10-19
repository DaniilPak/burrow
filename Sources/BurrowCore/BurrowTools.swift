import Foundation

/// "Burrow Tools": a small disc Burrow attaches to Windows machines.
///
/// It carries a helper that runs at every Windows sign-in and sets the display to the
/// resolution and scaling Burrow chose for this Mac (written to `burrow-display.txt` on the
/// disc each time the machine starts). virtio-win's GPU driver only offers the mode QEMU
/// advertises at boot plus a few standard ones and ignores resize requests from the host,
/// so the guest has to switch to it itself. `burrow-install.cmd` installs the helper for the
/// current user; Burrow's answer file runs it at first sign-in.
public enum BurrowTools {
    public static let volumeName = "BURROWTOOLS"

    /// What Windows should show: pixels, and scaling in percent (200 on a Retina display).
    public struct Display: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var scalePercent: Int

        public init(width: Int, height: Int, scalePercent: Int) {
            // virtio-gpu wants even dimensions; keep them sane.
            self.width = max(1024, min(7680, width & ~1))
            self.height = max(768, min(4320, height & ~1))
            self.scalePercent = scalePercent
        }

        public static let fallback = Display(width: 1920, height: 1200, scalePercent: 100)
    }

    public static func create(at destination: URL, display: Display) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("burrow-tools-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try windows(agentScript).write(to: staging.appendingPathComponent("burrow-agent.ps1"), atomically: true, encoding: .utf8)
        try windows(installScript).write(to: staging.appendingPathComponent("burrow-install.cmd"), atomically: true, encoding: .utf8)
        try "\(display.width) \(display.height) \(display.scalePercent)\r\n"
            .write(to: staging.appendingPathComponent("burrow-display.txt"), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: destination)
        let base = destination.deletingPathExtension()
        try DiskImage.run("/usr/bin/hdiutil", [
            "makehybrid", "-quiet", "-iso", "-joliet",
            "-default-volume-name", volumeName,
            "-o", base.path, staging.path,
        ])
        let produced = base.appendingPathExtension("iso")
        if produced != destination { try fm.moveItem(at: produced, to: destination) }
    }

    /// The first-logon command that installs the helper from whichever drive holds the disc.
    static var firstLogonCommand: String {
        "cmd /c for %d in (D E F G H I J K L M N O P) do @if exist %d:\\burrow-install.cmd call %d:\\burrow-install.cmd"
    }

    private static func windows(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Copies the helper into the user's profile and starts it at every sign-in. No
    /// administrator rights are needed: display settings belong to the signed-in user.
    static let installScript = #"""
    @echo off
    set "BT=%LOCALAPPDATA%\Burrow"
    if not exist "%BT%" mkdir "%BT%"
    copy /y "%~dp0burrow-agent.ps1" "%BT%\burrow-agent.ps1" >nul
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v BurrowTools /t REG_SZ /d "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%BT%\burrow-agent.ps1\"" /f >nul
    start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%BT%\burrow-agent.ps1"
    """#

    static let agentScript = #"""
    # Burrow Tools: sets this display to the resolution and scaling Burrow chose for the Mac.
    $ErrorActionPreference = 'SilentlyContinue'
    Add-Type -TypeDefinition @'
    using System;
    using System.Runtime.InteropServices;
    public static class BurrowDisplay {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DEVMODE {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
            public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
            public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
        [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
        [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, byte[] pathInfo, ref uint modes, byte[] modeInfo, IntPtr topology);
        [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(byte[] packet);
        [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(byte[] packet);

        public static string Current() {
            var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(dm);
            EnumDisplaySettings(null, -1, ref dm);
            return dm.dmPelsWidth + "x" + dm.dmPelsHeight;
        }

        public static int SetResolution(int width, int height) {
            var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(dm);
            if (!EnumDisplaySettings(null, -1, ref dm)) return -100;
            if (dm.dmPelsWidth == width && dm.dmPelsHeight == height) return 0;
            dm.dmPelsWidth = width; dm.dmPelsHeight = height; dm.dmFields = 0x80000 | 0x100000;
            return ChangeDisplaySettings(ref dm, 1); // CDS_UPDATEREGISTRY
        }

        static readonly int[] Steps = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };

        // Display scaling uses DisplayConfig's per-source DPI packets (types -3 and -4),
        // which take a step relative to the scaling Windows recommends for the display.
        public static int SetScale(int percent) {
            uint pathCount, modeCount;
            if (GetDisplayConfigBufferSizes(2, out pathCount, out modeCount) != 0) return -1;
            var paths = new byte[pathCount * 72]; var modes = new byte[modeCount * 64];
            if (QueryDisplayConfig(2, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero) != 0 || pathCount == 0) return -2;
            var get = new byte[32];
            BitConverter.GetBytes(-3).CopyTo(get, 0); BitConverter.GetBytes(32).CopyTo(get, 4);
            Array.Copy(paths, 0, get, 8, 12); // source adapter LUID and source id
            if (DisplayConfigGetDeviceInfo(get) != 0) return -3;
            int minRel = BitConverter.ToInt32(get, 20), curRel = BitConverter.ToInt32(get, 24), maxRel = BitConverter.ToInt32(get, 28);
            int target = Array.IndexOf(Steps, percent); if (target < 0) target = 0;
            int rel = Math.Max(minRel, Math.Min(maxRel, target + minRel));
            if (rel == curRel) return 0;
            var set = new byte[24];
            BitConverter.GetBytes(-4).CopyTo(set, 0); BitConverter.GetBytes(24).CopyTo(set, 4);
            Array.Copy(paths, 0, set, 8, 12); BitConverter.GetBytes(rel).CopyTo(set, 20);
            return DisplayConfigSetDeviceInfo(set);
        }
    }
    '@

    $log = Join-Path $env:LOCALAPPDATA 'Burrow\burrow-agent.log'
    function Log($text) { Add-Content -Path $log -Value ("{0:s} {1}" -f (Get-Date), $text) }

    # The display card's driver can load a little after sign-in; retry for a while.
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $file = Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root 'burrow-display.txt' } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($file) {
            $parts = (Get-Content $file -TotalCount 1).Trim() -split '\s+'
            $width = [int]$parts[0]; $height = [int]$parts[1]; $scale = [int]$parts[2]
            $result = [BurrowDisplay]::SetResolution($width, $height)
            if ($result -eq 0 -and [BurrowDisplay]::Current() -eq "$($width)x$($height)") {
                $scaled = [BurrowDisplay]::SetScale($scale)
                Log "display ${width}x${height} at ${scale}% (scale result $scaled)"
                exit 0
            }
            Log "resolution ${width}x${height} not ready (result $result, current $([BurrowDisplay]::Current()))"
        }
        Start-Sleep -Seconds 2
    }
    """#
}

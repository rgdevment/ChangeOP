param(
    # MCCS input codes: 0x0F DP1, 0x10 DP2, 0x11 HDMI1, 0x12 HDMI2 (some monitors use others; check with -ShowInput)
    [int]$MonitorInput = 0x12,
    # EDID model code of the monitor shared with the Mac (list them with -ShowInput); others are left alone
    [string]$MonitorModel = "XMI2001",
    # Easy-Switch channel shown on the keyboard/mouse (1..3)
    [int]$HostChannel = 2,
    [switch]$ShowInput,
    [switch]$Probe
)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public static class Ddc {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PhysicalMonitor {
        public IntPtr Handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Rect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MonitorInfoEx {
        public int Size;
        public Rect Monitor, Work;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DisplayDevice {
        public int Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);

    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfoEx info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint index, ref DisplayDevice info, uint flags);
    [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);
    [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor, uint count, [Out] PhysicalMonitor[] monitors);
    [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint count, PhysicalMonitor[] monitors);
    [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr monitor, byte code, uint value);
    [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor, byte code, IntPtr type, out uint current, out uint max);

    const byte InputSource = 0x60;

    // The EDID model code (e.g. "DELA0C2") from "MONITOR\DELA0C2\{...}\0001", stable across ports and reboots.
    static string ModelOf(IntPtr display) {
        var info = new MonitorInfoEx { Size = Marshal.SizeOf(typeof(MonitorInfoEx)) };
        if (!GetMonitorInfo(display, ref info)) return "";
        var device = new DisplayDevice { Size = Marshal.SizeOf(typeof(DisplayDevice)) };
        if (!EnumDisplayDevices(info.DeviceName, 0, ref device, 0)) return "";
        var parts = device.DeviceID.Split('\\');
        return parts.Length > 1 ? parts[1] : "";
    }

    static void ForEachMonitor(Action<PhysicalMonitor, string> action) {
        var displays = new List<IntPtr>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (m, dc, r, d) => { displays.Add(m); return true; }, IntPtr.Zero);
        foreach (var display in displays) {
            uint count;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(display, out count) || count == 0) continue;
            var monitors = new PhysicalMonitor[count];
            if (!GetPhysicalMonitorsFromHMONITOR(display, count, monitors)) continue;
            var model = ModelOf(display);
            foreach (var monitor in monitors) action(monitor, model);
            DestroyPhysicalMonitors(count, monitors);
        }
    }

    public static string[] ReadInputs() {
        var inputs = new List<string>();
        ForEachMonitor((m, model) => {
            uint current, max;
            if (GetVCPFeatureAndVCPFeatureReply(m.Handle, InputSource, IntPtr.Zero, out current, out max))
                inputs.Add(string.Format("{0}: input 0x{1:X2} ({1})", model, current & 0xFF));
        });
        return inputs.ToArray();
    }

    public static int SetInput(uint value, string model) {
        int changed = 0;
        ForEachMonitor((m, monitorModel) => {
            if (string.Equals(monitorModel, model, StringComparison.OrdinalIgnoreCase) && SetVCPFeature(m.Handle, InputSource, value))
                changed++;
        });
        return changed;
    }
}

public static class LogitechHost {
    [StructLayout(LayoutKind.Sequential)]
    struct HidpCaps {
        public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices,
            NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices,
            NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Get_Device_Interface_List_Size(out int length, ref Guid guid, string deviceId, int flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Get_Device_Interface_List(ref Guid guid, string deviceId, char[] buffer, int length, int flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle device, out IntPtr data);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr data, out HidpCaps caps);

    const byte LongReport = 0x11;
    const int LongReportLength = 20;
    const byte SoftwareId = 0x0A;
    const ushort ChangeHostFeature = 0x1814;
    const byte LongError = 0xFF;
    const byte ShortError = 0x8F;
    // Idle keyboards answer slowly from power saving; empty slots answer at once with an error.
    const int ReplyTimeoutMs = 2000;

    static IEnumerable<string> LogitechHidPaths() {
        var hidGuid = new Guid("4d1e55b2-f16f-11cf-88cb-001111000030");
        int length;
        if (CM_Get_Device_Interface_List_Size(out length, ref hidGuid, null, 0) != 0 || length <= 1) yield break;
        var buffer = new char[length];
        if (CM_Get_Device_Interface_List(ref hidGuid, null, buffer, length, 0) != 0) yield break;
        foreach (var path in new string(buffer).Split(new[] { '\0' }, StringSplitOptions.RemoveEmptyEntries))
            if (path.ToLowerInvariant().Contains("vid_046d")) yield return path;
    }

    class ReportReader {
        readonly FileStream stream;
        readonly byte[] buffer;
        Task<int> pending;

        public ReportReader(FileStream stream, int length) {
            this.stream = stream;
            buffer = new byte[length];
        }

        // A timed-out read stays pending and is reused, so no report is lost between requests.
        public Task<int> Pending() {
            if (pending == null) pending = stream.ReadAsync(buffer, 0, buffer.Length);
            return pending;
        }

        public byte[] Take() {
            pending = null;
            return (byte[])buffer.Clone();
        }
    }

    // Windows splits a receiver into collections: HID++ long reports on FF00:0002, short ones (like "device asleep") on FF00:0001.
    class Receiver : IDisposable {
        readonly List<FileStream> streams = new List<FileStream>();
        readonly List<ReportReader> readers = new List<ReportReader>();
        FileStream writer;

        public bool CanSend { get { return writer != null; } }

        public void Add(FileStream stream, HidpCaps caps) {
            streams.Add(stream);
            readers.Add(new ReportReader(stream, caps.InputReportByteLength));
            if (caps.Usage == 0x0002 && caps.OutputReportByteLength == LongReportLength) writer = stream;
        }

        public void Dispose() {
            foreach (var stream in streams) stream.Dispose();
        }

        public void Send(byte device, byte feature, byte function, params byte[] args) {
            var report = new byte[LongReportLength];
            report[0] = LongReport;
            report[1] = device;
            report[2] = feature;
            report[3] = (byte)((function << 4) | SoftwareId);
            Array.Copy(args, 0, report, 4, args.Length);
            writer.Write(report, 0, report.Length);
        }

        // Returns the reply, or null with error set to the HID++ error code (-1 on timeout).
        public byte[] Request(out int error, byte device, byte feature, byte function, params byte[] args) {
            error = -1;
            Send(device, feature, function, args);
            byte functionId = (byte)((function << 4) | SoftwareId);
            var deadline = DateTime.UtcNow.AddMilliseconds(ReplyTimeoutMs);
            var tasks = new Task[readers.Count];
            while (true) {
                var left = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
                if (left <= 0) return null;
                for (int i = 0; i < readers.Count; i++) tasks[i] = readers[i].Pending();
                int ready = Task.WaitAny(tasks, left);
                if (ready < 0) return null;
                var report = readers[ready].Take();
                if (report.Length < 6 || report[1] != device) continue;
                if (report[2] == feature && report[3] == functionId) return report;
                if ((report[2] == LongError || report[2] == ShortError) && report[3] == feature && report[4] == functionId) {
                    error = report[5];
                    return null;
                }
            }
        }
    }

    static List<Receiver> OpenReceivers() {
        var receivers = new Dictionary<string, Receiver>();
        foreach (var path in LogitechHidPaths()) {
            var handle = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
            if (handle.IsInvalid) continue;
            IntPtr data;
            HidpCaps caps = new HidpCaps();
            bool isHidpp = false;
            if (HidD_GetPreparsedData(handle, out data)) {
                isHidpp = HidP_GetCaps(data, out caps) == 0x00110000
                    && caps.UsagePage == 0xFF00 && (caps.Usage == 0x0001 || caps.Usage == 0x0002);
                HidD_FreePreparsedData(data);
            }
            if (!isHidpp) {
                handle.Dispose();
                continue;
            }
            // Collections of one receiver share the path except for "&colNN" and the trailing "&NNNN" instance suffix.
            var key = Regex.Replace(path.ToLowerInvariant(), @"&col\d+|&\d{4}(?=#\{)", "");
            Receiver receiver;
            if (!receivers.TryGetValue(key, out receiver)) receivers[key] = receiver = new Receiver();
            receiver.Add(new FileStream(handle, FileAccess.ReadWrite, 1, true), caps);
        }
        return new List<Receiver>(receivers.Values);
    }

    static byte ChangeHostIndex(Receiver receiver, byte device) {
        int error;
        var reply = receiver.Request(out error, device, 0x00, 0, (byte)(ChangeHostFeature >> 8), (byte)(ChangeHostFeature & 0xFF));
        return reply == null ? (byte)0 : reply[4];
    }

    // Every device is found before any switches, so a device leaving the receiver cannot disturb the next query.
    static int SwitchHost(Receiver receiver, int hostIndex) {
        var features = new Dictionary<byte, byte>();
        for (byte device = 1; device <= 6; device++) {
            var feature = ChangeHostIndex(receiver, device);
            if (feature != 0) features[device] = feature;
        }
        foreach (var entry in features) receiver.Send(entry.Key, entry.Value, 1, (byte)hostIndex);
        return features.Count;
    }

    static string DescribeSlot(Receiver receiver, byte device) {
        int error;
        var reply = receiver.Request(out error, device, 0x00, 0, (byte)(ChangeHostFeature >> 8), (byte)(ChangeHostFeature & 0xFF));
        if (reply == null) return error < 0 ? "no reply" : string.Format("error 0x{0:X2}", error);
        if (reply[4] == 0) return "no Easy-Switch";
        var hosts = receiver.Request(out error, device, reply[4], 0);
        var info = hosts == null ? "host info error" : string.Format("channel {0} of {1}", hosts[5] + 1, hosts[4]);
        var nameFeature = receiver.Request(out error, device, 0x00, 0, 0x00, 0x05);
        if (nameFeature == null || nameFeature[4] == 0) return info;
        var length = receiver.Request(out error, device, nameFeature[4], 0);
        var name = new System.Text.StringBuilder();
        while (length != null && name.Length < length[4]) {
            var chunk = receiver.Request(out error, device, nameFeature[4], 1, (byte)name.Length);
            if (chunk == null) break;
            for (int i = 4; i < chunk.Length && name.Length < length[4] && chunk[i] != 0; i++) name.Append((char)chunk[i]);
        }
        return string.Format("{0}, {1}", name, info);
    }

    public static string[] Probe() {
        var lines = new List<string>();
        foreach (var receiver in OpenReceivers()) {
            using (receiver) {
                if (!receiver.CanSend) continue;
                for (byte device = 1; device <= 6; device++)
                    lines.Add(string.Format("slot {0}: {1}", device, DescribeSlot(receiver, device)));
            }
        }
        return lines.ToArray();
    }

    public static int SwitchHost(int hostIndex) {
        int switched = 0;
        foreach (var receiver in OpenReceivers()) {
            using (receiver) {
                if (receiver.CanSend) switched += SwitchHost(receiver, hostIndex);
            }
        }
        return switched;
    }
}
'@

if ($ShowInput) {
    [Ddc]::ReadInputs()
    return
}

if ($Probe) {
    [LogitechHost]::Probe()
    return
}

$monitors = [Ddc]::SetInput($MonitorInput, $MonitorModel)
$devices = [LogitechHost]::SwitchHost($HostChannel - 1)
Write-Output "Monitors switched: $monitors, Logitech devices switched: $devices"

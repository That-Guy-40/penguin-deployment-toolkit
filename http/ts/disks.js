// disks.js - the disks this machine has, and which one 20-disk may wipe.
//   cscript //nologo disks.js <min_gb> <DISK or -> <disk.txt> <step.msg>
// Run by 17-diskguard before anything is destroyed. WinPE has no PowerShell;
// WMI through cscript is what it does have (slug.js uses the same).
// Prints one line per disk:  index|media|interface|GiB|model|verdict
// Eligible: fixed media, not on USB, at least <min_gb> GiB. Then:
//   DISK=<n> given: that disk, if eligible (else exit 1, nothing chosen);
//   no DISK:        the only eligible disk; none or several -> exit 1.
// Writes the chosen index to <disk.txt> and one line to <step.msg> (the
// step's beacon carries it as msg=).
var args = WScript.Arguments;
if (args.length != 4) { WScript.Echo("usage: disks.js <min_gb> <DISK|-> <disk.txt> <step.msg>"); WScript.Quit(2); }
var minGB = parseInt(args(0), 10), want = args(1), outDisk = args(2), outMsg = args(3);
var fso = new ActiveXObject("Scripting.FileSystemObject");
function write(p, s) { var f = fso.CreateTextFile(p, true); f.WriteLine(s); f.Close(); }

var wmi = GetObject("winmgmts:root\\cimv2");
var e = new Enumerator(wmi.ExecQuery("SELECT Index,Model,Size,MediaType,InterfaceType FROM Win32_DiskDrive"));
var disks = [];
for (; !e.atEnd(); e.moveNext()) {
    var d = e.item();
    var media = d.MediaType ? String(d.MediaType) : "unknown";
    var iface = d.InterfaceType ? String(d.InterfaceType) : "unknown";
    // WMI's Size comes from the disk geometry and runs a little under the raw
    // size (a 64 GiB QEMU disk reports 63.99), so round rather than floor.
    var gb = Math.round(parseFloat(d.Size || "0") / 1073741824);
    var model = (d.Model ? String(d.Model) : "?").replace(/\s+/g, " ").replace(/^ | $/g, "");
    var why = "";
    if (media.indexOf("Fixed") !== 0) why = "removable media (" + media + ")";
    else if (iface == "USB") why = "on USB";
    else if (gb < minGB) why = gb + " GiB, smaller than " + minGB + " GiB";
    disks.push({ i: d.Index, gb: gb, media: media, iface: iface, model: model, why: why,
                 desc: d.Index + ":" + model + " " + gb + "GiB" });
}
disks.sort(function (a, b) { return a.i - b.i; });
var all = [], cands = [];
for (var k = 0; k < disks.length; k++) {
    var x = disks[k];
    WScript.Echo(x.i + "|" + x.media + "|" + x.iface + "|" + x.gb + "|" + x.model + "|" + (x.why ? "not eligible: " + x.why : "eligible"));
    all.push(x.desc + (x.why ? " (" + x.why + ")" : ""));
    if (!x.why) cands.push(x);
}
var pick = null, msg = "";
if (want != "-") {
    var n = parseInt(want, 10), found = null;
    for (k = 0; k < disks.length; k++) if (disks[k].i == n) found = disks[k];
    if (!found) msg = "DISK=" + want + " is not a disk this machine has (disks: " + (all.join(", ") || "none") + ")";
    else if (found.why) msg = "DISK=" + want + " is " + found.why + ": refusing to wipe it";
    else pick = found;
} else if (cands.length == 1) {
    pick = cands[0];
} else if (cands.length == 0) {
    msg = "no fixed disk of at least " + minGB + " GiB (disks: " + (all.join(", ") || "none") + ")";
} else {
    var c = []; for (k = 0; k < cands.length; k++) c.push(cands[k].desc);
    msg = cands.length + " fixed disks (" + c.join(", ") + "): set DISK=<n> in the machine or model cfg";
}
if (!pick) { write(outMsg, msg); WScript.Echo(msg); WScript.Quit(1); }
write(outDisk, pick.i);
write(outMsg, "disk " + pick.desc + " of " + disks.length + (want != "-" ? " (DISK=" + want + ")" : " (the only fixed disk)"));
WScript.Quit(0);
